#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export REPO_DIR
source "$REPO_DIR/scripts/common.sh"

# This workflow is intentionally restricted to the official live ISO.
[[ -d /run/archiso ]] ||
    die "Run this installer from the official Arch Linux ISO."

[[ -d /sys/firmware/efi ]] ||
    die "UEFI firmware is required by this installation profile."

[[ "$(uname -m)" == "x86_64" ]] ||
    die "This installation profile requires x86_64."

[[ "$EUID" -eq 0 ]] ||
    die "Run this script as root from the Arch ISO."

for cmd in whiptail lsblk sgdisk wipefs partprobe \
           mkfs.fat mkfs.btrfs mount umount cryptsetup \
           pacstrap genfstab arch-chroot; do
    require_command "$cmd"
done

curl -fsSI --connect-timeout 8 https://archlinux.org/ \
    >/dev/null ||
    die "Network access is required before installation. Nothing was changed."


WORK_MNT=/mnt
mounted=0

fail_cleanup() {
    local rc=$?
    if (( rc != 0 )); then
        log ERROR "Installation failed (exit $rc)."
        printf '\nInstallation failed. Review the log: %s\n' "$LOG_FILE" >&2
        printf 'The target may be partially formatted or installed.\n' >&2
        printf 'Do not reboot until you have reviewed the failure.\n' >&2
    fi
}
trap fail_cleanup EXIT

ask() {
    whiptail --title "$APP_NAME" "$@"
}

# A package-list reader for the ISO installation target.
read_package_list() {
    local file="$1" line
    [[ -f "$file" ]] || die "Missing package list: $file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] || continue

        [[ "$line" =~ ^[a-zA-Z0-9@._+-]+$ ]] ||
            die "Invalid package name in $file: $line"

        printf '%s\n' "$line"
    done < "$file"
}

# Enumerate actual whole-disk block devices.
disk_menu=()
while read -r dev size type model; do
    [[ "$type" == "disk" ]] || continue
    [[ -b "$dev" ]] || continue
    [[ -n "$size" ]] || continue

    description="$size ${model:-Unknown model}"
    disk_menu+=("$dev" "$description")
done < <(lsblk -dpno NAME,SIZE,TYPE,MODEL)

((${#disk_menu[@]} >= 2)) ||
    die "No usable whole-disk devices were detected."

disk="$(
    ask --title "Select installation disk" \
        --menu "ALL DATA ON THE SELECTED DISK WILL BE DESTROYED.\nChoose the target disk carefully." \
        20 78 10 "${disk_menu[@]}" \
        3>&1 1>&2 2>&3
)" || exit 0

[[ -b "$disk" ]] || die "Selected device is not a block device."
[[ "$(lsblk -dnro TYPE "$disk")" == "disk" ]] ||
    die "Selected device is not a whole disk."

# Refuse disks with mounted descendants, including mounted EFI partitions.
if lsblk -nrpo MOUNTPOINT "$disk" |
    awk 'NF { found=1 } END { exit !found }'; then
    die "The selected disk has mounted filesystems. Nothing was changed."
fi

disk_details="$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL "$disk")"

ask --title "Destructive operation confirmation" \
    --msgbox "Review the selected disk:\n\n$disk_details\n\nThis installer erases the entire selected disk. It does not preserve existing partitions or operating systems." \
    20 78

typed_disk="$(
    ask --title "Confirm disk erasure" \
        --inputbox "Type the exact device path to authorize erasure:\n\n$disk" \
        12 72 \
        3>&1 1>&2 2>&3
)" || exit 0

[[ "$typed_disk" == "$disk" ]] ||
    die "Disk confirmation did not match. Nothing was changed."

encrypted=0
desktop=0
autologin=0

if ask --title "Disk encryption" \
    --yesno "Encrypt the Btrfs root partition with LUKS2?\n\nYou will need the passphrase at boot." 12 72; then
    encrypted=1
fi

if ask --title "Desktop environment" \
    --yesno "Install Hyprland and SDDM?" 10 64; then
    desktop=1
fi

if (( desktop && encrypted )); then
    if ask --title "SDDM auto-login" \
        --yesno "Enable SDDM auto-login for the created user after the encrypted disk has been unlocked?\n\nThis removes the second login prompt. Anyone who can unlock the disk may then access the desktop." \
        14 76; then
        autologin=1
    fi
fi

hostname="$(
    ask --title "Hostname" --inputbox "Enter a hostname:" \
        10 64 "archlinux" 3>&1 1>&2 2>&3
)" || exit 0

[[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] ||
    die "Invalid hostname."

username="$(
    ask --title "User account" --inputbox "Enter the regular username:" \
        10 64 "user" 3>&1 1>&2 2>&3
)" || exit 0

[[ "$username" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] ||
    die "Invalid username."

timezone="$(
    ask --title "Timezone" --inputbox \
        "Enter a timezone from /usr/share/zoneinfo:" \
        10 72 "UTC" 3>&1 1>&2 2>&3
)" || exit 0

[[ -f "/usr/share/zoneinfo/$timezone" ]] ||
    die "Unknown timezone: $timezone"

user_password="$(
    ask --title "User password" --passwordbox \
        "Set the password for $username:" 10 64 \
        3>&1 1>&2 2>&3
)" || exit 0

[[ -n "$user_password" ]] || die "Empty user passwords are not allowed."

user_password_confirm="$(
    ask --title "Confirm user password" --passwordbox \
        "Re-enter the password:" 10 64 \
        3>&1 1>&2 2>&3
)" || exit 0

[[ "$user_password" == "$user_password_confirm" ]] ||
    die "User passwords do not match."
unset user_password_confirm

luks_password=""
if (( encrypted )); then
    luks_password="$(
        ask --title "LUKS2 passphrase" --passwordbox \
            "Set the disk-unlock passphrase. Do not reuse your user password." \
            10 72 3>&1 1>&2 2>&3
    )" || exit 0

    [[ -n "$luks_password" ]] ||
        die "An empty encryption passphrase is not allowed."

    luks_confirm="$(
        ask --title "Confirm LUKS2 passphrase" --passwordbox \
            "Re-enter the disk-unlock passphrase:" 10 72 \
            3>&1 1>&2 2>&3
    )" || exit 0

    [[ "$luks_password" == "$luks_confirm" ]] ||
        die "LUKS2 passphrases do not match."

    unset luks_confirm
fi

# Final review before any disk writes.
summary="Disk: $disk\nHostname: $hostname\nUser: $username\nTimezone: $timezone\nRoot encryption: $([[ $encrypted == 1 ]] && echo LUKS2 || echo None)\nDesktop: $([[ $desktop == 1 ]] && echo Hyprland/SDDM || echo None)\nSDDM auto-login: $([[ $autologin == 1 ]] && echo Enabled || echo Disabled)\n\nThe entire disk will be repartitioned."

ask --title "Final installation review" \
    --yesno "$summary\n\nProceed with installation?" 20 76 ||
    exit 0

log INFO "Beginning whole-disk installation on $disk"

# Partitioning: GPT, 1 GiB ESP, remaining space for Linux.
wipefs --all --force "$disk"
sgdisk --zap-all "$disk"
sgdisk --clear \
    --new=1:1MiB:+1024MiB --typecode=1:EF00 --change-name=1:EFI \
    --new=2:0:0 --typecode=2:8300 --change-name=2:ARCHROOT \
    "$disk"

partprobe "$disk"
udevadm settle

if [[ "$disk" =~ [0-9]$ ]]; then
    esp="${disk}p1"
    rootpart="${disk}p2"
else
    esp="${disk}1"
    rootpart="${disk}2"
fi

[[ -b "$esp" && -b "$rootpart" ]] ||
    die "Expected partitions were not created."

mkfs.fat -F 32 -n EFI "$esp"

root_device="$rootpart"
if (( encrypted )); then
    printf '%s' "$luks_password" |
        cryptsetup luksFormat --type luks2 --batch-mode \
            --key-file - "$rootpart"

    printf '%s' "$luks_password" |
        cryptsetup open --key-file - "$rootpart" cryptroot

    unset luks_password
    root_device=/dev/mapper/cryptroot
fi

mkfs.btrfs --force --label ARCHROOT "$root_device"

mount "$root_device" "$WORK_MNT"
mounted=1

btrfs subvolume create "$WORK_MNT/@"
btrfs subvolume create "$WORK_MNT/@home"
btrfs subvolume create "$WORK_MNT/@log"
btrfs subvolume create "$WORK_MNT/@pkg"
btrfs subvolume create "$WORK_MNT/@snapshots"

umount "$WORK_MNT"

mount -o noatime,compress=zstd:1,subvol=@ \
    "$root_device" "$WORK_MNT"

mkdir -p "$WORK_MNT"/{boot,home,var/log,var/cache/pacman/pkg,.snapshots}

mount -o noatime,compress=zstd:1,subvol=@home \
    "$root_device" "$WORK_MNT/home"
mount -o noatime,compress=zstd:1,subvol=@log \
    "$root_device" "$WORK_MNT/var/log"
mount -o noatime,compress=zstd:1,subvol=@pkg \
    "$root_device" "$WORK_MNT/var/cache/pacman/pkg"
mount -o noatime,compress=zstd:1,subvol=@snapshots \
    "$root_device" "$WORK_MNT/.snapshots"

mount "$esp" "$WORK_MNT/boot"

# Core system and broad x86-64 firmware support.
packages=(
    base linux linux-firmware linux-headers
    btrfs-progs mkinitcpio cryptsetup
    limine efibootmgr dosfstools
    networkmanager sudo git nano
)

# Install CPU microcode for the machine being installed.
vendor="$(awk -F ': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo)"
case "$vendor" in
    GenuineIntel) packages+=(intel-ucode) ;;
    AuthenticAMD) packages+=(amd-ucode) ;;
esac

if (( desktop )); then
    while IFS= read -r pkg; do
        packages+=("$pkg")
    done < <(read_package_list "$REPO_DIR/packages/hyprland.txt")
fi

pacstrap -K "$WORK_MNT" "${packages[@]}"

genfstab -U "$WORK_MNT" > "$WORK_MNT/etc/fstab"

printf '%s\n' "$hostname" > "$WORK_MNT/etc/hostname"

cat > "$WORK_MNT/etc/locale.gen" <<'EOF'
en_US.UTF-8 UTF-8
EOF

arch-chroot "$WORK_MNT" locale-gen

printf 'LANG=en_US.UTF-8\n' > "$WORK_MNT/etc/locale.conf"
printf 'KEYMAP=us\n' > "$WORK_MNT/etc/vconsole.conf"
ln -sf "/usr/share/zoneinfo/$timezone" "$WORK_MNT/etc/localtime"

# Use the traditional encrypt hook for the LUKS2 root profile.
if (( encrypted )); then
    hooks='HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)'
else
    hooks='HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)'
fi

sed -i -E "s|^HOOKS=.*|$hooks|" "$WORK_MNT/etc/mkinitcpio.conf"

arch-chroot "$WORK_MNT" useradd -m -G wheel -s /bin/bash "$username"

printf '%s:%s\n' "$username" "$user_password" |
    arch-chroot "$WORK_MNT" chpasswd

unset user_password

printf '%%wheel ALL=(ALL:ALL) ALL\n' \
    > "$WORK_MNT/etc/sudoers.d/10-wheel"

chmod 0440 "$WORK_MNT/etc/sudoers.d/10-wheel"
arch-chroot "$WORK_MNT" visudo -cf /etc/sudoers

arch-chroot "$WORK_MNT" systemctl enable NetworkManager

# Configure the root UUID and boot command line.
esp_uuid="$(blkid -s UUID -o value "$esp")"
root_uuid="$(blkid -s UUID -o value "$root_device")"

if (( encrypted )); then
    luks_uuid="$(blkid -s UUID -o value "$rootpart")"
    cmdline="cryptdevice=UUID=$luks_uuid:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw"
else
    cmdline="root=UUID=$root_uuid rootflags=subvol=@ rw"
fi

# Ensure kernel and initramfs are generated inside the installed system.
arch-chroot "$WORK_MNT" mkinitcpio -P

# Limine's configuration is stored on the FAT EFI partition.
mkdir -p "$WORK_MNT/boot/EFI/limine" \
         "$WORK_MNT/boot/EFI/BOOT"

[[ -f "$WORK_MNT/usr/share/limine/BOOTX64.EFI" ]] ||
    die "The installed Limine package did not provide BOOTX64.EFI."

install -m 0644 "$WORK_MNT/usr/share/limine/BOOTX64.EFI" \
    "$WORK_MNT/boot/EFI/limine/BOOTX64.EFI"

# Standard UEFI removable-media fallback path.
install -m 0644 "$WORK_MNT/usr/share/limine/BOOTX64.EFI" \
    "$WORK_MNT/boot/EFI/BOOT/BOOTX64.EFI"

{
    printf 'timeout: 5\n'
    printf 'default_entry: 1\n\n'
    printf '/Arch Linux\n'
    printf '    protocol: linux\n'
    printf '    kernel_path: boot():/vmlinuz-linux\n'
    printf '    kernel_cmdline: %s\n' "$cmdline"

    if [[ -f "$WORK_MNT/boot/intel-ucode.img" ]]; then
        printf '    module_path: boot():/intel-ucode.img\n'
    elif [[ -f "$WORK_MNT/boot/amd-ucode.img" ]]; then
        printf '    module_path: boot():/amd-ucode.img\n'
    fi

    printf '    module_path: boot():/initramfs-linux.img\n'
} > "$WORK_MNT/boot/limine.conf"

# A kernel command line file helps document the intended boot parameters.
mkdir -p "$WORK_MNT/etc/kernel"
printf '%s\n' "$cmdline" > "$WORK_MNT/etc/kernel/cmdline"

if (( desktop )); then
    mkdir -p "$WORK_MNT/etc/sddm.conf.d"
    printf '[Autologin]\n' > "$WORK_MNT/etc/sddm.conf.d/10-autologin.conf"

    if (( autologin )); then
        cat >> "$WORK_MNT/etc/sddm.conf.d/10-autologin.conf" <<EOF
User=$username
Session=hyprland.desktop
EOF
    else
        # Empty [Autologin] section: no auto-login configured.
        :
    fi

    arch-chroot "$WORK_MNT" systemctl enable sddm
fi

# Register a normal firmware entry when possible. The fallback copy above
# remains available if firmware variables or entry creation are unavailable.
if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr --create \
        --disk "$disk" --part 1 \
        --label "Arch Linux Limine" \
        --loader '\EFI\limine\BOOTX64.EFI' ||
        log WARN "Could not create NVRAM entry; use the UEFI fallback entry."
fi

# A pacman hook refreshes the deployed Limine EFI binaries after upgrades.
mkdir -p "$WORK_MNT/usr/local/bin" "$WORK_MNT/etc/pacman.d/hooks"

cat > "$WORK_MNT/usr/local/bin/arch-setup-update-limine" <<'EOF'
#!/usr/bin/bash
set -eu
src=/usr/share/limine/BOOTX64.EFI
[[ -f "$src" ]] || exit 0
install -Dm0644 "$src" /boot/EFI/limine/BOOTX64.EFI
install -Dm0644 "$src" /boot/EFI/BOOT/BOOTX64.EFI
EOF
chmod 0755 "$WORK_MNT/usr/local/bin/arch-setup-update-limine"

cat > "$WORK_MNT/etc/pacman.d/hooks/95-arch-setup-limine.hook" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Refreshing Limine EFI binaries
When = PostTransaction
Exec = /usr/local/bin/arch-setup-update-limine
EOF

# Keep the boot partition mounted until the user can inspect the result.
sync

arch-chroot "$WORK_MNT" passwd --lock root

ask --title "Installation complete" \
    --msgbox "Arch Linux has been installed to $disk.\n\nRoot encryption: $([[ $encrypted == 1 ]] && echo LUKS2 || echo disabled)\nDesktop: $([[ $desktop == 1 ]] && echo Hyprland || echo none)\nBootloader: Limine (UEFI fallback installed)\n\nReview /mnt/boot/limine.conf and /mnt/etc/fstab before rebooting.\n\nThe target is still mounted at /mnt. Exit the installer and unmount cleanly before rebooting." \
    18 76

log INFO "Installation completed for $disk"
