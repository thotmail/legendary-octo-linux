#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_DIR
source "$REPO_DIR/scripts/common.sh"

require_command whiptail
require_command pacman
require_not_root

PACKAGE_DIR="$REPO_DIR/packages"

declare -A GROUP_FILES=(
    [base]="base.txt"
    [cli]="cli.txt"
    [development]="development.txt"
    [hyprland]="hyprland.txt"
    [graphics]="graphics.txt"
    [laptop]="laptop.txt"
)

declare -A GROUP_LABELS=(
    [base]="Base utilities"
    [cli]="CLI tools"
    [development]="Development tools"
    [hyprland]="Hyprland desktop"
    [graphics]="Graphics and media"
    [laptop]="Laptop utilities"
)

menu_items=()

for group in base cli development hyprland graphics laptop; do
    menu_items+=(
        "$group"
        "${GROUP_LABELS[$group]}"
        "OFF"
    )
done

selected="$(
    whiptail \
        --title "Package groups" \
        --checklist "Select package groups to install:" \
        20 76 10 \
        "${menu_items[@]}" \
        --separate-output \
        3>&1 1>&2 2>&3
)" || exit 0

[[ -n "$selected" ]] || exit 0

declare -A seen=()
packages=()
selected_groups=()

while IFS= read -r group; do
    [[ -n "$group" ]] || continue

    file="${GROUP_FILES[$group]:-}"
    [[ -n "$file" ]] || die "Unknown package group: $group"

    package_file="$PACKAGE_DIR/$file"
    [[ -f "$package_file" ]] ||
        die "Package list not found: $package_file"

    selected_groups+=("$group")

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"

        [[ -n "$line" ]] || continue

        # Reject malformed package names instead of passing arbitrary input
        # to pacman.
        [[ "$line" =~ ^[a-zA-Z0-9@._+-]+$ ]] ||
            die "Invalid package entry in $file: $line"

        if [[ -z "${seen[$line]:-}" ]]; then
            seen["$line"]=1
            packages+=("$line")
        fi
    done < "$package_file"
done <<< "$selected"

[[ "${#packages[@]}" -gt 0 ]] || {
    whiptail --title "Package groups" \
        --msgbox "The selected groups contain no packages." 10 60
    exit 0
}

summary="Groups: ${selected_groups[*]}\n\nPackages to install:\n"
for package in "${packages[@]}"; do
    summary+="- $package"$'\n'
done

whiptail --title "Confirm package installation" \
    --yesno "$summary" 22 76 || exit 0

sudo -v

log INFO "Installing package groups: ${selected_groups[*]}"

sudo pacman -S --needed -- "${packages[@]}"

log INFO "Package installation completed."
