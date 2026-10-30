#!/usr/bin/env bash
# ==============================================================================
# 00-timeshift-boot-sync.sh - Native Timeshift GUI/CLI Post-Restore Hook
# ==============================================================================
# Executed automatically by Timeshift (GUI and CLI) when any restore finishes.
# Intercepts the restore, chroots into the target root, and synchronizes GRUB,
# initramfs, and kernel targets before rebooting.
# ==============================================================================

LOG_FILE="/var/log/timeshift-sync-hook.log"
exec >> "$LOG_FILE" 2>&1

echo "=================================================================="
echo "Timeshift Post-Restore Hook triggered at: $(date -Iseconds)"
echo "TS_SNAPSHOT_PATH: ${TS_SNAPSHOT_PATH:-undefined}"

# Detect root device
root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
root_dev="${root_dev%%\[*}"
if [[ -z "$root_dev" || ! -b "$root_dev" ]]; then
    cfg="/etc/timeshift/timeshift.json"
    if [[ -f "$cfg" ]]; then
        uuid=$(grep -oP '"backup_device_uuid"\s*:\s*"\K[^"]+' "$cfg" 2>/dev/null || true)
        [[ -n "$uuid" ]] && root_dev=$(blkid -U "$uuid" 2>/dev/null || true)
    fi
fi

if [[ -z "$root_dev" || ! -b "$root_dev" ]]; then
    echo "[ERROR] Failed to locate BTRFS root device."
    exit 0
fi

echo "[INFO] Root device: $root_dev"

# Detect EFI partition
efi_dev=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
if [[ -z "$efi_dev" || ! -b "$efi_dev" ]]; then
    efi_dev=$(lsblk -o PATH,PARTTYPE,FSTYPE -n -l | awk '$2 ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ || $3 == "vfat" {print $1; exit}')
fi

echo "[INFO] EFI partition: $efi_dev"

# Locate the restored subvolume path
chroot_dir=""
# Check if Timeshift currently has the target backup mounted in /run/timeshift/*/backup/@
ts_mounted_root=$(find /run/timeshift -maxdepth 3 -type d -name "@" 2>/dev/null | head -n1 || true)
if [[ -n "$ts_mounted_root" && -d "$ts_mounted_root/boot" ]]; then
    chroot_dir="$ts_mounted_root"
    echo "[INFO] Using existing Timeshift mount: $chroot_dir"
else
    chroot_dir="/tmp/ts-hook-chroot"
    mkdir -p "$chroot_dir"
    echo "[INFO] Mounting subvol=@ from $root_dev to $chroot_dir..."
    mount -o subvol=@ "$root_dev" "$chroot_dir"
fi

if [[ ! -d "$chroot_dir/boot" ]]; then
    echo "[ERROR] Restored root subvolume does not contain /boot. Aborting hook."
    [[ "$chroot_dir" == "/tmp/ts-hook-chroot" ]] && { umount "$chroot_dir" 2>/dev/null || true; rmdir "$chroot_dir" 2>/dev/null || true; }
    exit 0
fi

# Mount virtual filesystems for chroot
mounted_efi=false
if [[ -n "$efi_dev" && -b "$efi_dev" && ! -d "$chroot_dir/boot/efi/EFI" ]]; then
    mkdir -p "$chroot_dir/boot/efi"
    mount "$efi_dev" "$chroot_dir/boot/efi" && mounted_efi=true
fi

mount --bind /dev "$chroot_dir/dev"
mount --bind /proc "$chroot_dir/proc"
mount --bind /sys "$chroot_dir/sys"
mount --bind /run "$chroot_dir/run"

echo "[INFO] Purging stale grubenv saved_entry..."
chroot "$chroot_dir" bash -c "grub-editenv /boot/grub/grubenv unset saved_entry 2>/dev/null || true"
chroot "$chroot_dir" bash -c "grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true"

echo "[INFO] Rebuilding initramfs..."
chroot "$chroot_dir" mkinitcpio -P || true

echo "[INFO] Regenerating grub.cfg..."
if chroot "$chroot_dir" command -v update-grub &>/dev/null; then
    chroot "$chroot_dir" update-grub || true
elif chroot "$chroot_dir" command -v grub-mkconfig &>/dev/null; then
    chroot "$chroot_dir" grub-mkconfig -o /boot/grub/grub.cfg || true
fi

if [[ -x "$chroot_dir/etc/grub.d/41_snapshots-btrfs" ]]; then
    echo "[INFO] Synchronizing snapshots menu..."
    chroot "$chroot_dir" /etc/grub.d/41_snapshots-btrfs || true
fi

# Set first-boot marker
mkdir -p "$chroot_dir/var/lib/timeshift-sync"
echo "RESTORED_BY=timeshift-gui-hook" > "$chroot_dir/var/lib/timeshift-sync/last_restore.conf"
echo "TS_SNAPSHOT_PATH=${TS_SNAPSHOT_PATH:-unknown}" >> "$chroot_dir/var/lib/timeshift-sync/last_restore.conf"
echo "RESTORED_AT=$(date -Iseconds)" >> "$chroot_dir/var/lib/timeshift-sync/last_restore.conf"
touch "$chroot_dir/var/lib/timeshift-sync/firstboot.marker"

# Unmount
umount "$chroot_dir/run" 2>/dev/null || true
umount "$chroot_dir/sys" 2>/dev/null || true
umount "$chroot_dir/proc" 2>/dev/null || true
umount "$chroot_dir/dev" 2>/dev/null || true
if [[ "$mounted_efi" == "true" ]]; then
    umount "$chroot_dir/boot/efi" 2>/dev/null || true
fi

if [[ "$chroot_dir" == "/tmp/ts-hook-chroot" ]]; then
    umount "$chroot_dir" 2>/dev/null || true
    rmdir "$chroot_dir" 2>/dev/null || true
fi

echo "[OK] Post-restore hook completed successfully."
exit 0
