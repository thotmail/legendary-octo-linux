#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export REPO_DIR

source "$REPO_DIR/scripts/common.sh"

require_command whiptail

is_archiso() {
    [[ -d /run/archiso ]] ||
        [[ -d /run/archiso/bootmnt ]]
}

show_message() {
    whiptail --title "$APP_NAME" --msgbox "$1" 12 72
}

main_menu() {
    local choice
    local environment="Installed Arch Linux"

    if is_archiso; then
        environment="Arch ISO (live environment)"
    fi

    while true; do
        choice="$(
            whiptail \
                --title "$APP_NAME" \
                --menu "Environment: $environment\n\nSelect an action:" \
                20 76 8 \
                "packages" "Install selected package groups" \
                "dotfiles" "Deploy dotfiles with conflict backups" \
                "check" "Check prerequisites and environment" \
                "iso" "Arch ISO installation (not yet implemented)" \
                "exit" "Exit" \
                3>&1 1>&2 2>&3
        )" || return 0

        case "$choice" in
            packages)
                "$REPO_DIR/scripts/packages.sh"
                ;;
            dotfiles)
                "$REPO_DIR/scripts/dotfiles.sh"
                ;;
            check)
                "$REPO_DIR/scripts/preflight.sh"
                ;;
            iso)
                if ! is_archiso; then
                    show_message "Boot the official Arch ISO first."
                elif [[ "$EUID" -ne 0 ]]; then
                    show_message "Run the installer as root from the Arch ISO."
                else
                    "$REPO_DIR/scripts/install-arch.sh"
                fi
                ;;

            exit)
                return 0
                ;;
        esac
    done
}

main_menu "$@"
