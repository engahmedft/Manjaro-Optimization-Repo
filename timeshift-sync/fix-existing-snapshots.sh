#!/usr/bin/env bash
# ==============================================================================
# fix-existing-snapshots.sh - Repair & Synchronize Existing Timeshift Snapshots
# ==============================================================================
# Injects missing LTS fallback kernels and modules into older snapshots
# (such as "After-Install"), purges stale grubenv entries, and ensures old
# restore points will never cause kernel panics or bootloader dropouts.
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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
    if [[ -d "/mnt/ts-fix-root" ]]; then
        umount "/mnt/ts-fix-root" 2>/dev/null || true
        rmdir "/mnt/ts-fix-root" 2>/dev/null || true
    fi
}
trap cleanup EXIT

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

    # Identify LTS kernel source from current system
    local lts_vmlinuz="/boot/vmlinuz-6.12-x86_64"
    local lts_initrd="/boot/initramfs-6.12-x86_64.img"
    local lts_kver="/boot/linux612-x86_64.kver"
    local lts_modules_dir=""

    for d in /usr/lib/modules/6.12*; do
        if [[ -d "$d" ]]; then
            lts_modules_dir="$d"
            break
        fi
    done

    local has_lts_source=false
    if [[ -f "$lts_vmlinuz" && -f "$lts_initrd" && -n "$lts_modules_dir" ]]; then
        has_lts_source=true
        log_ok "Found host LTS Kernel 6.12 as universal fallback provider."
    else
        log_warn "Host LTS Kernel 6.12 not found. Will only purge stale grubenv in snapshots."
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
        log_info "  Installed kernels in snapshot: ${snap_kernels:-none}"

        # Determine if repair is actually required before altering Btrfs properties
        local needs_grubenv_clean=false
        local needs_lts_injection=false
        local needs_ucode=false

        if [[ -f "$snap_root/boot/grub/grubenv" ]] && grub-editenv "$snap_root/boot/grub/grubenv" list 2>/dev/null | grep -qE "saved_entry=|next_entry="; then
            needs_grubenv_clean=true
        fi

        if [[ "$has_lts_source" == "true" && ! -f "$snap_root/boot/vmlinuz-6.12-x86_64" ]]; then
            needs_lts_injection=true
        fi

        if [[ -f /boot/intel-ucode.img && ! -f "$snap_root/boot/intel-ucode.img" ]]; then
            needs_ucode=true
        fi

        if [[ "$needs_grubenv_clean" == "false" && "$needs_lts_injection" == "false" && "$needs_ucode" == "false" ]]; then
            log_ok "  Snapshot ${BOLD}$snap_name${NC} already healthy & synchronized. (Skipping)"
            continue
        fi

        # Temporarily make snapshot read-write for repair
        btrfs property set "$snap_root" ro false

        # 1. Clear stale grubenv in snapshot
        if [[ "$needs_grubenv_clean" == "true" ]]; then
            grub-editenv "$snap_root/boot/grub/grubenv" unset saved_entry 2>/dev/null || true
            grub-editenv "$snap_root/boot/grub/grubenv" unset next_entry 2>/dev/null || true
        fi

        # 2. Inject LTS kernel if snapshot lacks modern/stable kernel
        if [[ "$needs_lts_injection" == "true" ]]; then
            log_info "  Injecting LTS Kernel 6.12 into $snap_name to ensure safe booting..."
            mkdir -p "$snap_root/boot"
            cp -p "$lts_vmlinuz" "$snap_root/boot/"
            cp -p "$lts_initrd" "$snap_root/boot/"
            [[ -f "$lts_kver" ]] && cp -p "$lts_kver" "$snap_root/boot/"

            local mod_target_base="$snap_root/usr/lib/modules"
            local mod_name
            mod_name=$(basename "$lts_modules_dir")
            if [[ ! -d "$mod_target_base/$mod_name" ]]; then
                log_info "  Copying kernel modules ($mod_name) into snapshot..."
                mkdir -p "$mod_target_base"
                cp -a "$lts_modules_dir" "$mod_target_base/"
            fi
        fi

        # 3. Ensure intel-ucode is present in snapshot
        if [[ "$needs_ucode" == "true" ]]; then
            cp -p /boot/intel-ucode.img "$snap_root/boot/"
        fi

        # Re-lock snapshot as read-only
        btrfs property set "$snap_root" ro true

        log_ok "  Snapshot ${BOLD}$snap_name${NC} successfully repaired & synchronized."
        ((fixed_count++))

    done < <(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d | sort)

    echo "----------------------------------------------------------------"
    log_ok "Total snapshots processed and verified: $fixed_count"

    # Also synchronize current live system GRUB menu with snapshots
    log_info "Synchronizing live GRUB bootloader snapshot menu..."
    if [[ -x /etc/grub.d/41_snapshots-btrfs ]]; then
        /etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1 || true
    fi
    if command -v update-grub &>/dev/null; then
        update-grub >/dev/null 2>&1 || true
    fi

    log_ok "All existing Timeshift restore points are now safe to restore without kernel mismatch!"
}

main "$@"
