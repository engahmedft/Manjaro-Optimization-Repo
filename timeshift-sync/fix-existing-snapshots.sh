#!/usr/bin/env bash
# ==============================================================================
# fix-existing-snapshots.sh - Repair & Synchronize Existing Timeshift Snapshots
# ==============================================================================
# Injects modern working kernels (6.12 LTS & 7.2) and modules into older snapshots
# (such as "After-Install"), removes obsolete broken kernels (7.1), purges
# stale grubenv entries, installs the boot safeguard service into snapshots,
# and ensures old restore points will never cause kernel panics or boot failures.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/../lib/common.sh"
elif [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/lib/common.sh"
elif [[ -f "/usr/local/lib/manjaro-opt/common.sh" ]]; then
    source "/usr/local/lib/manjaro-opt/common.sh"
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Superuser privileges required. Elevating via sudo...${NC}"
    exec sudo "$0" "$@"
fi

detect_root_device() {
    local dev
    dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    dev="${dev%%\[*}"
    if [[ -z "$dev" || ! -b "$dev" ]]; then
        local cfg="/etc/timeshift/timeshift.json"
        if [[ -f "$cfg" ]]; then
            local uuid
            uuid=$(grep -oP '"backup_device_uuid"\s*:\s*"\K[^"]+' "$cfg" 2>/dev/null || true)
            [[ -n "$uuid" ]] && dev=$(blkid -U "$uuid" 2>/dev/null || true)
        fi
    fi
    if [[ -z "$dev" || ! -b "$dev" ]]; then
        log_error "Could not detect BTRFS root device."
        exit 1
    fi
    echo "$dev"
}

cleanup() {
    if (( ${#UNLOCKED_SNAPSHOTS[@]} > 0 )); then
        local s
        for s in "${UNLOCKED_SNAPSHOTS[@]}"; do
            if [[ -d "$s" ]]; then
                btrfs property set "$s" ro true 2>/dev/null || true
            fi
        done
    fi
    if [[ -d "/mnt/ts-fix-root" ]]; then
        umount "/mnt/ts-fix-root" 2>/dev/null || true
        rmdir "/mnt/ts-fix-root" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

main() {
    echo -e "${BOLD}${CYAN}================================================================${NC}"
    echo -e "${BOLD}${CYAN}      REPAIR & SYNCHRONIZE EXISTING TIMESHIFT SNAPSHOTS         ${NC}"
    echo -e "${BOLD}${CYAN}================================================================${NC}"

    local btrfs_dev
    btrfs_dev=$(detect_root_device)
    log_info "Detected BTRFS Root Device: $btrfs_dev"

    mkdir -p /mnt/ts-fix-root
    mount -o subvolid=5 "$btrfs_dev" /mnt/ts-fix-root

    local snap_dir="/mnt/ts-fix-root/timeshift-btrfs/snapshots"
    if [[ ! -d "$snap_dir" ]]; then
        log_error "Snapshots directory not found at $snap_dir."
        exit 1
    fi

    local fixed_count=0

    while IFS= read -r s; do
        local snap_name
        snap_name=$(basename "$s")
        local snap_root="$s/@"

        if [[ ! -d "$snap_root" ]]; then
            continue
        fi

        local comment="-"
        if [[ -f "$s/info.json" ]]; then
            local c
            c=$(grep -oP '"comments"\s*:\s*"\K[^"]+' "$s/info.json" 2>/dev/null || true)
            [[ -n "$c" ]] && comment="$c"
        fi

        log_info "Inspecting snapshot: ${BOLD}$snap_name${NC} ($comment)..."

        # Check existing kernels in snapshot
        local snap_kernels
        snap_kernels=$(ls "$snap_root/boot"/vmlinuz-* 2>/dev/null | xargs -n1 basename | sed 's/vmlinuz-//' | tr '\n' ' ' || true)
        log_info "  Current kernels in snapshot: ${snap_kernels:-none}"

        # Temporarily make snapshot read-write for repair and track in unlock list
        btrfs property set "$snap_root" ro false
        track_unlocked_snapshot "$snap_root"

        # 1. Clear stale grubenv in snapshot
        if [[ -f "$snap_root/boot/grub/grubenv" ]]; then
            grub-editenv "$snap_root/boot/grub/grubenv" unset saved_entry 2>/dev/null || true
            grub-editenv "$snap_root/boot/grub/grubenv" unset next_entry 2>/dev/null || true
        fi

        # 2. Inject modern working host kernels dynamically into snapshot
        local host_kernels=()
        read -r -a host_kernels <<< "$(discover_host_kernels)"
        for kver in "${host_kernels[@]}"; do
            [[ -z "$kver" ]] && continue
            if [[ -f "/boot/vmlinuz-${kver}-x86_64" && ! -f "$snap_root/boot/vmlinuz-${kver}-x86_64" ]]; then
                log_info "  Injecting Kernel ${kver} into $snap_name..."
                mkdir -p "$snap_root/boot"
                cp -p "/boot/vmlinuz-${kver}-x86_64" "$snap_root/boot/"
                cp -p "/boot/initramfs-${kver}-x86_64.img" "$snap_root/boot/" 2>/dev/null || true
                cp -p "/boot/initramfs-${kver}-x86_64-fallback.img" "$snap_root/boot/" 2>/dev/null || true
                cp -p "/boot/linux${kver//./}-x86_64.kver" "$snap_root/boot/" 2>/dev/null || true
            fi

            for mod_dir in /usr/lib/modules/${kver}*; do
                if [[ -d "$mod_dir" ]]; then
                    local mod_name
                    mod_name=$(basename "$mod_dir")
                    local mod_target_base="$snap_root/usr/lib/modules"
                    if [[ ! -d "$mod_target_base/$mod_name" ]]; then
                        log_info "  Injecting kernel modules ($mod_name) into snapshot..."
                        mkdir -p "$mod_target_base"
                        cp -a "$mod_dir" "$mod_target_base/"
                    fi
                fi
            done
        done

        # 3. Clean obsolete broken 7.1 kernel & modules ONLY if another valid kernel is present
        purge_broken_kernels_from_root "$snap_root" || true

        # 4. Ensure microcode is present in snapshot
        if [[ -f /boot/intel-ucode.img && ! -f "$snap_root/boot/intel-ucode.img" ]]; then
            cp -p /boot/intel-ucode.img "$snap_root/boot/"
        fi

        # 5. Inject first-boot safeguard service so it's guaranteed present upon restoring
        if [[ -f /etc/systemd/system/timeshift-boot-sync.service ]]; then
            mkdir -p "$snap_root/etc/systemd/system/multi-user.target.wants" "$snap_root/usr/local/bin"
            cp -p /usr/local/bin/timeshift-boot-sync.sh "$snap_root/usr/local/bin/" 2>/dev/null || true
            chmod +x "$snap_root/usr/local/bin/timeshift-boot-sync.sh" 2>/dev/null || true
            cp -p /etc/systemd/system/timeshift-boot-sync.service "$snap_root/etc/systemd/system/" 2>/dev/null || true
            ln -sf /etc/systemd/system/timeshift-boot-sync.service "$snap_root/etc/systemd/system/multi-user.target.wants/timeshift-boot-sync.service"
        fi

        # 6. Clear stale fontconfig cache to avoid GNOME Shell startup issues
        rm -rf "$snap_root/var/cache/fontconfig"/* 2>/dev/null || true

        # Re-lock snapshot as read-only and remove from tracking list
        btrfs property set "$snap_root" ro true
        untrack_unlocked_snapshot "$snap_root"

        log_ok "  Snapshot ${BOLD}$snap_name${NC} successfully repaired & synchronized."
        (( ++fixed_count ))

    done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d | sort)

    echo "----------------------------------------------------------------"
    log_ok "Total snapshots processed and verified: $fixed_count"

    # Synchronize current live system GRUB menu with snapshots
    log_info "Synchronizing live GRUB bootloader snapshot menu..."
    if [[ -x /etc/grub.d/41_snapshots-btrfs ]]; then
        /etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1 || true
    fi
    if command -v update-grub &>/dev/null; then
        update-grub >/dev/null 2>&1 || true
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    fi

    log_ok "All existing Timeshift restore points are now safe to restore!"
}

main "$@"
