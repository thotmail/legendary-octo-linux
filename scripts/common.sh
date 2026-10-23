#!/usr/bin/env bash

APP_NAME="Arch Setup"
LOG_DIR="${XDG_STATE_HOME:-${HOME:-/root}/.local/state}/arch-setup"
LOG_FILE="$LOG_DIR/setup.log"

mkdir -p -- "$LOG_DIR" 2>/dev/null || true

log() {
    local level="$1"
    shift
    local message="$*"

    printf '[%s] [%s] %s\n' \
        "$(date '+%F %T')" "$level" "$message" >&2

    printf '[%s] [%s] %s\n' \
        "$(date '+%F %T')" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    log ERROR "$*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

require_not_root() {
    [[ "$EUID" -ne 0 ]] ||
        die "Run this script as your regular user, not as root."
}

confirm_action() {
    local prompt="$1"

    whiptail --title "$APP_NAME" --yesno "$prompt" 12 72
}

repo_root() {
    printf '%s\n' "${REPO_DIR:?REPO_DIR must be set}"
}
