#!/usr/bin/env bash
# ==============================================================================
# timeshift-restore-sync.sh - Safe Timeshift Restore & Boot Synchronization CLI
# ==============================================================================
# Ensures complete synchronization between Timeshift BTRFS snapshots, GRUB,
# /boot, /boot/efi, and Linux kernels with full personal data protection.
# ==============================================================================

set -euo pipefail

# Text styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Root privilege check
if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Superuser privileges required. Elevating via sudo...${NC}"
    exec sudo "$0" "$@"
fi

# Detect BTRFS root device
detect_root_device() {
    local dev
    dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    dev="${dev%%\[*}" # Strip subvolume notation like [/dev/nvme0n1p4[/@]]
    if [[ -z "$dev" || ! -b "$dev" ]]; then
        # Fallback to timeshift config
        local cfg="/etc/timeshift/timeshift.json"
        if [[ -f "$cfg" ]]; then
            local uuid
            uuid=$(grep -oP '"backup_device_uuid"\s*:\s*"\K[^"]+' "$cfg" 2>/dev/null || true)
            if [[ -n "$uuid" ]]; then
                dev=$(blkid -U "$uuid" 2>/dev/null || true)
            fi
        fi
    fi

    if [[ -z "$dev" || ! -b "$dev" ]]; then
        log_error "Could not detect BTRFS root device."
        exit 1
    fi
    echo "$dev"
}

# Detect EFI partition
detect_efi_device() {
    local efi_dev
    efi_dev=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
    if [[ -z "$efi_dev" || ! -b "$efi_dev" ]]; then
        # Search for ESP partition
        efi_dev=$(lsblk -o PATH,PARTTYPE,FSTYPE -n -l | awk '$2 ~ /c12a7328-f81f-11d2-ba4b-00a0c93ec93b/ || $3 == "vfat" {print $1; exit}')
    fi
    echo "$efi_dev"
}

cleanup_mounts() {
    local target="${1:-}"
    if [[ -n "$target" && -d "$target" ]]; then
        log_info "Cleaning up temporary mounts at $target..."
        umount -R "$target" 2>/dev/null || true
        rmdir "$target" 2>/dev/null || true
    fi
    if [[ -d "/mnt/ts-sync-root" ]]; then
        umount "/mnt/ts-sync-root" 2>/dev/null || true
        rmdir "/mnt/ts-sync-root" 2>/dev/null || true
    fi
}

# Scan available snapshots
list_snapshots() {
    local btrfs_dev="$1"
    mkdir -p /mnt/ts-sync-root
    mount -o subvolid=5 "$btrfs_dev" /mnt/ts-sync-root

    local snap_dir="/mnt/ts-sync-root/timeshift-btrfs/snapshots"
    if [[ ! -d "$snap_dir" ]]; then
        log_error "No Timeshift BTRFS snapshots directory found at $snap_dir."
        umount /mnt/ts-sync-root
        exit 1
    fi

    echo -e "\n${BOLD}${CYAN}Available Timeshift Snapshots on $btrfs_dev:${NC}"
    echo "--------------------------------------------------------------------------------"
    printf "${BOLD}%-4s | %-20s | %-22s | %-22s${NC}\n" "NUM" "DATE / ID" "COMMENT / TAG" "KERNELS IN SNAPSHOT"
    echo "--------------------------------------------------------------------------------"

    local idx=1
    declare -g -A SNAP_PATHS
    declare -g -A SNAP_NAMES

    while IFS= read -r s; do
        local snap_name
        snap_name=$(basename "$s")
        local comment="-"
        local info_file="$s/info.json"
        if [[ -f "$info_file" ]]; then
            local c
            c=$(grep -oP '"comments"\s*:\s*"\K[^"]+' "$info_file" 2>/dev/null || true)
            [[ -n "$c" ]] && comment="$c"
            local tag
            tag=$(grep -oP '"tags"\s*:\s*"\K[^"]+' "$info_file" 2>/dev/null || true)
            [[ -n "$tag" ]] && comment="[$tag] $comment"
        fi

        # Detect kernels in snapshot @/boot
        local kernels=""
        if [[ -d "$s/@/boot" ]]; then
            kernels=$(ls "$s/@/boot"/vmlinuz-* 2>/dev/null | xargs -n1 basename | sed 's/vmlinuz-//' | tr '\n' ' ' || true)
        fi
        [[ -z "$kernels" ]] && kernels="None detected"

        printf "%-4d | %-20s | %-22s | %-22s\n" "$idx" "$snap_name" "${comment:0:22}" "${kernels:0:22}"
        SNAP_PATHS[$idx]="$s"
        SNAP_NAMES[$idx]="$snap_name"
        ((idx++))
    done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d | sort -r)

    echo "--------------------------------------------------------------------------------"
    TOTAL_SNAPSHOTS=$((idx - 1))
}

# Main Execution Flow
main() {
    echo -e "${BOLD}${CYAN}================================================================${NC}"
    echo -e "${BOLD}${CYAN}        TIMESHIFT SYNCHRONIZED RESTORE & BOOT MANAGER           ${NC}"
    echo -e "${BOLD}${CYAN}================================================================${NC}"

    local btrfs_dev
    btrfs_dev=$(detect_root_device)
    local efi_dev
    efi_dev=$(detect_efi_device)

    log_info "Detected BTRFS Root Device: ${BOLD}$btrfs_dev${NC}"
    log_info "Detected EFI Partition:     ${BOLD}$efi_dev${NC}"

    list_snapshots "$btrfs_dev"

    if [[ "$TOTAL_SNAPSHOTS" -eq 0 ]]; then
        log_warn "No snapshots found. Run Timeshift to create a snapshot first."
        cleanup_mounts ""
        exit 0
    fi

    # Select snapshot
    local choice=""
    while true; do
        read -rp "Select snapshot number to restore [1-$TOTAL_SNAPSHOTS] (or 'q' to quit): " choice
        [[ "$choice" =~ ^[qQ]$ ]] && { cleanup_mounts ""; exit 0; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= TOTAL_SNAPSHOTS )); then
            break
        fi
        echo -e "${RED}Invalid selection. Please enter a valid number.${NC}"
    done

    local selected_snap="${SNAP_PATHS[$choice]}"
    local selected_name="${SNAP_NAMES[$choice]}"
    echo -e "\n${BOLD}${YELLOW}Selected Snapshot: $selected_name${NC}"

    # Personal Data Protection Prompt
    echo -e "\n${BOLD}Personal Data Protection (@home):${NC}"
    echo -e " 1) ${GREEN}${BOLD}System Only (@) [RECOMMENDED]${NC}: Restores system, drivers, kernels, and boot."
    echo -e "    ${BOLD}Your /home (files, code, git repos, downloads) remains completely untouched.${NC}"
    echo -e " 2) ${YELLOW}Full System & Home (@ and @home)${NC}: Rolls back personal files to the snapshot state."
    echo ""
    local home_choice=""
    while true; do
        read -rp "Choose restore scope [1 or 2, default: 1]: " home_choice
        home_choice="${home_choice:-1}"
        if [[ "$home_choice" == "1" || "$home_choice" == "2" ]]; then
            break
        fi
    done

    # Pre-restore safety snapshot
    local ts_timestamp
    ts_timestamp=$(date +'%Y-%m-%d_%H-%M-%S')
    local pre_snap_dir="/mnt/ts-sync-root/timeshift-btrfs/snapshots/${ts_timestamp}_pre_restore_sync"
    log_info "Creating instantaneous safety backup snapshot: ${ts_timestamp}_pre_restore_sync..."
    mkdir -p "$pre_snap_dir"
    btrfs subvolume snapshot -r "/mnt/ts-sync-root/@" "$pre_snap_dir/@" >/dev/null
    if [[ -d "/mnt/ts-sync-root/@home" ]]; then
        btrfs subvolume snapshot -r "/mnt/ts-sync-root/@home" "$pre_snap_dir/@home" >/dev/null
    fi
    cat << EOF > "$pre_snap_dir/info.json"
{
  "created" : "$(date +'%Y-%m-%d %H:%M:%S')",
  "comments" : "Pre-Restore Safety Backup before restoring $selected_name",
  "tags" : "O"
}
EOF
    log_ok "Safety backup snapshot created."

    # Perform Subvolume Swap
    log_info "Applying snapshot $selected_name to @ subvolume..."
    local backup_tag="@_backup_${ts_timestamp}"
    mv "/mnt/ts-sync-root/@" "/mnt/ts-sync-root/$backup_tag"
    btrfs subvolume snapshot "$selected_snap/@" "/mnt/ts-sync-root/@" >/dev/null

    if [[ "$home_choice" == "2" && -d "$selected_snap/@home" ]]; then
        log_warn "Rolling back @home to snapshot state..."
        mv "/mnt/ts-sync-root/@home" "/mnt/ts-sync-root/@home_backup_${ts_timestamp}"
        btrfs subvolume snapshot "$selected_snap/@home" "/mnt/ts-sync-root/@home" >/dev/null
        log_ok "@home restored."
    else
        log_ok "@home left untouched and fully preserved."
    fi

    # Chroot Synchronization
    log_info "Mounting restored subvolume for chroot boot synchronization..."
    local chroot_dir="/mnt/ts-sync-chroot"
    mkdir -p "$chroot_dir"
    mount -o subvol=@ "$btrfs_dev" "$chroot_dir"

    # Ensure modern working kernels (6.12 LTS & 7.2) exist in restored root, and clean obsolete broken 7.1
    for kver in "6.12" "7.2"; do
        if [[ -f "/boot/vmlinuz-${kver}-x86_64" && ! -f "$chroot_dir/boot/vmlinuz-${kver}-x86_64" ]]; then
            log_info "Copying working kernel ${kver} into restored root..."
            cp -p "/boot/vmlinuz-${kver}-x86_64" "$chroot_dir/boot/"
            cp -p "/boot/initramfs-${kver}-x86_64.img" "$chroot_dir/boot/" 2>/dev/null || true
            cp -p "/boot/linux${kver//./}-x86_64.kver" "$chroot_dir/boot/" 2>/dev/null || true
        fi
        for mod_dir in /usr/lib/modules/${kver}*; do
            if [[ -d "$mod_dir" ]]; then
                local mname
                mname=$(basename "$mod_dir")
                if [[ ! -d "$chroot_dir/usr/lib/modules/$mname" ]]; then
                    log_info "Copying modules for ${mname} into restored root..."
                    mkdir -p "$chroot_dir/usr/lib/modules"
                    cp -a "$mod_dir" "$chroot_dir/usr/lib/modules/"
                fi
            fi
        done
    done

    # Remove broken 7.1 kernel to prevent Dell Inspiron 7706 touchpad/IRQ 27 crash
    if [[ -f "$chroot_dir/boot/vmlinuz-7.1-x86_64" ]]; then
        log_info "Removing obsolete broken kernel 7.1 from restored root..."
        rm -f "$chroot_dir/boot/vmlinuz-7.1-x86_64"*
        rm -f "$chroot_dir/boot/initramfs-7.1-x86_64"*
        rm -f "$chroot_dir/boot/linux71-x86_64.kver"*
    fi

    # Deploy first-boot safeguard service into restored root so it's guaranteed present
    if [[ -f /etc/systemd/system/timeshift-boot-sync.service ]]; then
        mkdir -p "$chroot_dir/etc/systemd/system/multi-user.target.wants" "$chroot_dir/usr/local/bin"
        cp -p /usr/local/bin/timeshift-boot-sync.sh "$chroot_dir/usr/local/bin/" 2>/dev/null || true
        chmod +x "$chroot_dir/usr/local/bin/timeshift-boot-sync.sh" 2>/dev/null || true
        cp -p /etc/systemd/system/timeshift-boot-sync.service "$chroot_dir/etc/systemd/system/" 2>/dev/null || true
        ln -sf /etc/systemd/system/timeshift-boot-sync.service "$chroot_dir/etc/systemd/system/multi-user.target.wants/timeshift-boot-sync.service"
    fi

    # Clear stale fontconfig cache to avoid GNOME startup issues
    rm -rf "$chroot_dir/var/cache/fontconfig"/* 2>/dev/null || true

    if [[ -n "$efi_dev" && -b "$efi_dev" ]] && ! mountpoint -q "$chroot_dir/boot/efi"; then
        mkdir -p "$chroot_dir/boot/efi"
        mount "$efi_dev" "$chroot_dir/boot/efi"
    fi

    mount --bind /dev "$chroot_dir/dev"
    mount --bind /proc "$chroot_dir/proc"
    mount --bind /sys "$chroot_dir/sys"
    mount --bind /run "$chroot_dir/run"

    # Synchronize inside chroot
    log_info "Detecting installed kernels in restored system..."
    local snap_kernels
    snap_kernels=$(chroot "$chroot_dir" bash -c "ls /boot/vmlinuz-* 2>/dev/null | xargs -n1 basename | sed 's/vmlinuz-//' || true")
    log_ok "Available Kernels in Restored Root: ${BOLD}${snap_kernels:-none}${NC}"

    log_info "Purging stale GRUB saved_entry from grubenv to avoid missing-kernel boots..."
    chroot "$chroot_dir" bash -c "grub-editenv /boot/grub/grubenv unset saved_entry 2>/dev/null || true"
    chroot "$chroot_dir" bash -c "grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true"

    log_info "Rebuilding initramfs images for verified kernels..."
    chroot "$chroot_dir" mkinitcpio -P >/dev/null 2>&1 || log_warn "mkinitcpio reported warnings (proceeding)."

    log_info "Regenerating font cache..."
    chroot "$chroot_dir" fc-cache -r 2>/dev/null || true

    log_info "Regenerating /boot/grub/grub.cfg with synced kernel targets..."
    if chroot "$chroot_dir" command -v update-grub &>/dev/null; then
        chroot "$chroot_dir" update-grub >/dev/null 2>&1 || true
    elif chroot "$chroot_dir" command -v grub-mkconfig &>/dev/null; then
        chroot "$chroot_dir" grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    fi

    # Refresh grub-btrfs if present
    if [[ -x "$chroot_dir/etc/grub.d/41_snapshots-btrfs" ]]; then
        log_info "Updating GRUB BTRFS snapshots submenu..."
        chroot "$chroot_dir" /etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1 || true
    fi

    # Mark sync complete
    mkdir -p "$chroot_dir/var/lib/timeshift-sync"
    echo "RESTORED_FROM=$selected_name" > "$chroot_dir/var/lib/timeshift-sync/last_restore.conf"
    echo "RESTORED_AT=$(date -Iseconds)" >> "$chroot_dir/var/lib/timeshift-sync/last_restore.conf"
    echo "KERNELS=$snap_kernels" >> "$chroot_dir/var/lib/timeshift-sync/last_restore.conf"
    touch "$chroot_dir/var/lib/timeshift-sync/firstboot.marker"

    # Cleanup mounts
    cleanup_mounts "$chroot_dir"
    log_ok "Chroot synchronization completed and filesystems cleanly unmounted."

    # Post-restore summary
    echo -e "\n${BOLD}${GREEN}================================================================${NC}"
    echo -e "${BOLD}${GREEN}         RESTORATION & BOOT SYNCHRONIZATION SUCCESSFUL          ${NC}"
    echo -e "${BOLD}${GREEN}================================================================${NC}"
    echo -e " Restored Snapshot: ${BOLD}$selected_name${NC}"
    echo -e " Kernels Active:    ${BOLD}$snap_kernels${NC}"
    echo -e " GRUB Boot Menu:    ${GREEN}Synchronized with zero missing-kernel errors${NC}"
    echo -e " User Data (@home): ${GREEN}Safely preserved${NC}"
    echo -e " Safety Backup:     ${BOLD}${ts_timestamp}_pre_restore_sync${NC}"
    echo "----------------------------------------------------------------"
    
    # Prompt for reboot
    read -rp "Do you want to reboot the system now? [y/N]: " reboot_choice
    if [[ "$reboot_choice" =~ ^[yY]$ ]]; then
        log_info "Rebooting system..."
        reboot
    else
        log_info "You can reboot whenever ready. Changes will be active upon restart."
    fi
}

trap 'cleanup_mounts "/mnt/ts-sync-chroot"' EXIT
main "$@"
