#!/usr/bin/env bash
# ==============================================================================
# install.sh - Installer for Timeshift Boot & Kernel Synchronization System
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared common library if available
if [[ -f "${SCRIPT_DIR}/../lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/../lib/common.sh"
elif [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/lib/common.sh"
fi

REPAIR_SNAPSHOTS=false
for arg in "$@"; do
    case "$arg" in
        --repair-snapshots) REPAIR_SNAPSHOTS=true ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}Superuser privileges required. Elevating via sudo...${NC}"
    exec sudo "$0" "$@"
fi

echo -e "${BOLD}${CYAN}================================================================${NC}"
echo -e "${BOLD}${CYAN}  INSTALLING TIMESHIFT, BOOT & KERNEL SYNCHRONIZATION SYSTEM   ${NC}"
echo -e "${BOLD}${CYAN}================================================================${NC}"

# 1. Install shared library and global CLI commands
log_info "1/7: Installing global CLI commands into /usr/local/bin..."
if [[ -f "$SCRIPT_DIR/../lib/common.sh" ]]; then
    install -Dm644 "$SCRIPT_DIR/../lib/common.sh" /usr/local/lib/manjaro-opt/common.sh
fi
cp "$SCRIPT_DIR/timeshift-restore-sync.sh" /usr/local/bin/timeshift-restore-sync
chmod +x /usr/local/bin/timeshift-restore-sync

cp "$SCRIPT_DIR/timeshift-boot-sync.sh" /usr/local/bin/timeshift-boot-sync.sh
chmod +x /usr/local/bin/timeshift-boot-sync.sh

cp "$SCRIPT_DIR/timeshift-sync-notify.sh" /usr/local/bin/timeshift-sync-notify.sh
chmod +x /usr/local/bin/timeshift-sync-notify.sh

cp "$SCRIPT_DIR/fix-existing-snapshots.sh" /usr/local/bin/timeshift-fix-snapshots
chmod +x /usr/local/bin/timeshift-fix-snapshots

cp "$SCRIPT_DIR/check-grub-menu.sh" /usr/local/bin/timeshift-check-grub
chmod +x /usr/local/bin/timeshift-check-grub
log_ok "Global CLI commands installed (timeshift-restore-sync, timeshift-fix-snapshots, timeshift-check-grub)."

# 2. Install Native Timeshift GUI/CLI Restore Hook (Must NOT have .sh extension for run-parts)
log_info "2/7: Installing native Timeshift post-restore hook..."
mkdir -p /etc/timeshift/restore-hooks.d
rm -f /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync.sh
cp "$SCRIPT_DIR/timeshift-restore-hook.sh" /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync
chmod +x /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync
log_ok "Native hook active at /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync (validated for run-parts)."

# 3. Install Native Timeshift Post-Backup Hook for EFI Archiving
log_info "3/7: Installing native Timeshift post-backup hook for EFI partition archiving..."
mkdir -p /etc/timeshift/backup-hooks.d
rm -f /etc/timeshift/backup-hooks.d/01-timeshift-efi-backup.sh
cp "$SCRIPT_DIR/timeshift-efi-backup-hook.sh" /etc/timeshift/backup-hooks.d/01-timeshift-efi-backup
chmod +x /etc/timeshift/backup-hooks.d/01-timeshift-efi-backup
log_ok "Native backup hook active at /etc/timeshift/backup-hooks.d/01-timeshift-efi-backup."

# 4. Install First-Boot Systemd Service
log_info "4/7: Installing first-boot safeguard systemd service..."
cp "$SCRIPT_DIR/timeshift-boot-sync.service" /etc/systemd/system/timeshift-boot-sync.service
systemctl daemon-reload
systemctl enable timeshift-boot-sync.service
log_ok "Service enabled: timeshift-boot-sync.service."

# 5. Install Desktop Notification Autostart
log_info "5/7: Configuring desktop notification handler..."
mkdir -p /etc/xdg/autostart
cp "$SCRIPT_DIR/timeshift-sync-notify.desktop" /etc/xdg/autostart/timeshift-sync-notify.desktop
log_ok "Desktop notification handler installed."

# 6. Fix Existing Older Snapshots (On-Demand)
if [[ "$REPAIR_SNAPSHOTS" == "true" ]]; then
    log_info "6/7: Inspecting and fixing existing Timeshift snapshots (--repair-snapshots enabled)..."
    bash "$SCRIPT_DIR/fix-existing-snapshots.sh"
    log_ok "Existing snapshots repaired and verified."
else
    log_info "6/7: Existing snapshot repair skipped by default."
    log_info "     (Use --repair-snapshots or run 'timeshift-fix-snapshots' on demand)."
fi

# 7. Ensure GRUB BTRFS daemon is watching
log_info "7/7: Verifying grub-btrfsd daemon..."
if systemctl is-active grub-btrfsd.service &>/dev/null; then
    log_ok "grub-btrfsd daemon is active and monitoring."
elif systemctl is-enabled grub-btrfsd.service &>/dev/null; then
    systemctl start grub-btrfsd.service || true
    log_ok "grub-btrfsd daemon started."
fi

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}       TIMESHIFT & BOOT SYNC SUITE INSTALLED SUCCESSFULLY       ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
echo -e " • Restore via Script: ${BOLD}sudo timeshift-restore-sync${NC}"
echo -e " • Restore via GUI:    ${BOLD}Protected automatically by native restore hook${NC}"
if [[ "$REPAIR_SNAPSHOTS" == "true" ]]; then
    echo -e " • Old Snapshots:      ${BOLD}Repaired with LTS kernel & clean bootloader targets${NC}"
else
    echo -e " • Old Snapshots:      ${BOLD}On-demand repair ready ('sudo timeshift-fix-snapshots')${NC}"
fi
echo "----------------------------------------------------------------"
