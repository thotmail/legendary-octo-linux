#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_DIR
source "$REPO_DIR/scripts/common.sh"

require_command whiptail

issues=()
info=()

if [[ -d /sys/firmware/efi ]]; then
    info+=("Firmware: UEFI")
else
    issues+=("Firmware: Legacy BIOS or EFI runtime unavailable")
fi

if [[ "$(uname -m)" == "x86_64" ]]; then
    info+=("Architecture: x86_64")
else
    issues+=("Architecture: $(uname -m) (primary target is x86_64)")
fi

if [[ -d /run/archiso ]]; then
    info+=("Environment: Arch ISO")
elif [[ -f /etc/arch-release ]]; then
    info+=("Environment: Installed Arch Linux")
else
    issues+=("Environment: Not detected as Arch Linux")
fi

for command_name in bash pacman whiptail; do
    if command -v "$command_name" >/dev/null 2>&1; then
        info+=("Command available: $command_name")
    else
        issues+=("Missing command: $command_name")
    fi
done

report=""

for item in "${info[@]}"; do
    report+="+ $item"$'\n'
done

for item in "${issues[@]}"; do
    report+="! $item"$'\n'
done

[[ -n "$report" ]] || report="No checks were performed."

whiptail --title "Arch Setup: Preflight" \
    --scrolltext --msgbox "$report" 20 76
