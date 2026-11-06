#!/usr/bin/env bash
# ==============================================================================
# 00-timeshift-boot-sync - Native Timeshift GUI/CLI Post-Restore Hook
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/../lib/common.sh"
elif [[ -f "/usr/local/lib/manjaro-opt/common.sh" ]]; then
    source "/usr/local/lib/manjaro-opt/common.sh"
else
    BROKEN_KERNELS=("7.1")
    discover_host_kernels() {
        local boot_dir="${1:-/boot}"
        local k_list=()
        local img
        for img in "$boot_dir"/vmlinuz-*-x86_64; do
            [[ ! -f "$img" ]] && continue
            local k
            k=$(basename "$img" | sed -E 's/^vmlinuz-([0-9]+\.[0-9]+).*/\1/')
            local broken=false
            local b
            for b in "${BROKEN_KERNELS[@]}"; do
                [[ "$k" == "$b" ]] && { broken=true; break; }
            done
            if [[ "$broken" == "false" && -n "$k" && ! " ${k_list[*]:-} " =~ " ${k} " ]]; then
                k_list+=("$k")
            fi
        done
        echo "${k_list[@]:-}"
    }
fi

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

# Ensure working modern kernels from host exist in restored root, and clean obsolete broken 7.1
echo "[INFO] Verifying kernel targets in restored system..."
host_kernels=()
read -r -a host_kernels <<< "$(discover_host_kernels)"
for kver in "${host_kernels[@]}"; do
    [[ -z "$kver" ]] && continue
    if [[ -f "/boot/vmlinuz-${kver}-x86_64" && ! -f "$chroot_dir/boot/vmlinuz-${kver}-x86_64" ]]; then
        echo "[INFO] Copying working kernel ${kver} into restored root..."
        cp -p "/boot/vmlinuz-${kver}-x86_64" "$chroot_dir/boot/"
        cp -p "/boot/initramfs-${kver}-x86_64.img" "$chroot_dir/boot/" 2>/dev/null || true
        cp -p "/boot/initramfs-${kver}-x86_64-fallback.img" "$chroot_dir/boot/" 2>/dev/null || true
        cp -p "/boot/linux${kver//./}-x86_64.kver" "$chroot_dir/boot/" 2>/dev/null || true
    fi
    for mod_dir in /usr/lib/modules/${kver}*; do
        if [[ -d "$mod_dir" ]]; then
            mname=$(basename "$mod_dir")
            if [[ ! -d "$chroot_dir/usr/lib/modules/$mname" ]]; then
                echo "[INFO] Copying modules for ${mname} into restored root..."
                mkdir -p "$chroot_dir/usr/lib/modules"
                cp -a "$mod_dir" "$chroot_dir/usr/lib/modules/"
            fi
        fi
    done
done

# Ensure microcode is present in restored root
if [[ -f /boot/intel-ucode.img && ! -f "$chroot_dir/boot/intel-ucode.img" ]]; then
    cp -p /boot/intel-ucode.img "$chroot_dir/boot/"
fi

# Clean obsolete broken 7.1 kernel & modules ONLY if another valid kernel is present
if declare -F purge_broken_kernels_from_root &>/dev/null; then
    purge_broken_kernels_from_root "$chroot_dir" || true
elif [[ -f "$chroot_dir/boot/vmlinuz-7.1-x86_64" ]]; then
    other_kernels=$(find "$chroot_dir/boot" -maxdepth 1 -name "vmlinuz-*-x86_64" ! -name "vmlinuz-7.1-x86_64" 2>/dev/null || true)
    if [[ -n "$other_kernels" ]]; then
        echo "[INFO] Removing obsolete kernel 7.1 from restored root to avoid hardware freeze..."
        rm -f "$chroot_dir/boot/vmlinuz-7.1-x86_64"*
        rm -f "$chroot_dir/boot/initramfs-7.1-x86_64"*
        rm -f "$chroot_dir/boot/linux71-x86_64.kver"*
        rm -rf "$chroot_dir/usr/lib/modules/7.1".* "$chroot_dir/usr/lib/modules/7.1-"* 2>/dev/null || true
    else
        echo "[WARN] Kernel 7.1 is the only kernel in restored root and no alternative could be copied. Retaining to preserve bootability."
    fi
fi

# Deploy first-boot safeguard service into restored root so it's guaranteed present
if [[ -f /etc/systemd/system/timeshift-boot-sync.service ]]; then
    mkdir -p "$chroot_dir/etc/systemd/system" "$chroot_dir/usr/local/bin"
    cp -p /etc/systemd/system/timeshift-boot-sync.service "$chroot_dir/etc/systemd/system/"
    cp -p /usr/local/bin/timeshift-boot-sync.sh "$chroot_dir/usr/local/bin/"
    chmod +x "$chroot_dir/usr/local/bin/timeshift-boot-sync.sh"
    mkdir -p "$chroot_dir/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/timeshift-boot-sync.service "$chroot_dir/etc/systemd/system/multi-user.target.wants/timeshift-boot-sync.service"
fi

# Fix fontconfig cache mismatch
echo "[INFO] Clearing stale fontconfig cache..."
rm -rf "$chroot_dir/var/cache/fontconfig"/* 2>/dev/null || true

# Mount virtual filesystems for chroot
mounted_efi=false
if [[ -n "$efi_dev" && -b "$efi_dev" ]] && ! mountpoint -q "$chroot_dir/boot/efi"; then
    mkdir -p "$chroot_dir/boot/efi"
    mount "$efi_dev" "$chroot_dir/boot/efi" && mounted_efi=true
fi

# 1:1 Pure Original EFI restore if snapshot contains efi_backup.tar.gz
if [[ -n "${TS_SNAPSHOT_PATH:-}" && -f "$TS_SNAPSHOT_PATH/efi_backup.tar.gz" && -d "$chroot_dir/boot/efi" ]]; then
    echo "[INFO] Restoring 1:1 original EFI partition from $TS_SNAPSHOT_PATH/efi_backup.tar.gz..."
    tar -xzf "$TS_SNAPSHOT_PATH/efi_backup.tar.gz" -C "$chroot_dir/boot/efi"
    echo "[OK] EFI partition restored from snapshot archive."
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

echo "[INFO] Regenerating font cache in chroot..."
chroot "$chroot_dir" fc-cache -r 2>/dev/null || true

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
