#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_DIR
source "$REPO_DIR/scripts/common.sh"

require_command whiptail
require_not_root

MANIFEST="$REPO_DIR/config/dotfiles.conf"
TARGET_HOME="${HOME:?HOME is not set}"

[[ -f "$MANIFEST" ]] || die "Missing manifest: $MANIFEST"

if ! whiptail --title "Dotfiles" \
    --yesno "Deploy dotfiles to:\n\n$TARGET_HOME\n\nExisting conflicting paths will be backed up before linking." \
    12 72; then
    exit 0
fi

timestamp="$(date '+%Y%m%d-%H%M%S')"
backup_root="$TARGET_HOME/.local/state/arch-setup/backups/$timestamp"

deployed=0
backed_up=0
skipped=0

while IFS=$'\t' read -r source_rel target_rel || [[ -n "${source_rel:-}" ]]; do
    # Ignore blank lines and comments.
    [[ -n "${source_rel:-}" ]] || continue
    [[ "$source_rel" == \#* ]] && continue

    source_path="$REPO_DIR/$source_rel"
    target_path="$TARGET_HOME/$target_rel"

    [[ -e "$source_path" || -L "$source_path" ]] || {
        log WARN "Source missing; skipped: $source_rel"
        ((skipped+=1))
        continue
    }

    # Prevent manifest entries from escaping the target home.
    case "$target_rel" in
        /*|..|../*|*/../*|*/..)
            die "Unsafe target path in manifest: $target_rel"
            ;;
    esac

    mkdir -p -- "$(dirname -- "$target_path")"

    if [[ -L "$target_path" ]] &&
       [[ "$(readlink -- "$target_path")" == "$source_path" ]]; then
        log INFO "Already linked: $target_rel"
        continue
    fi

    if [[ -e "$target_path" || -L "$target_path" ]]; then
        backup_path="$backup_root/$target_rel"
        mkdir -p -- "$(dirname -- "$backup_path")"

        if [[ -e "$backup_path" || -L "$backup_path" ]]; then
            die "Backup path already exists: $backup_path"
        fi

        mv -- "$target_path" "$backup_path"
        ((backed_up+=1))
        log INFO "Backed up: $target_rel"
    fi

    ln -s -- "$source_path" "$target_path"
    ((deployed+=1))
    log INFO "Linked: $target_rel -> $source_path"

done < "$MANIFEST"

summary="Symlinks created: $deployed\nConflicts backed up: $backed_up\nMissing sources skipped: $skipped"

if (( backed_up > 0 )); then
    summary+="\n\nBackup location:\n$backup_root"
fi

whiptail --title "Dotfiles complete" --msgbox "$summary" 16 72
