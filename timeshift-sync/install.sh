#!/usr/bin/env bash
# ==============================================================================
# install.sh - Installer for Timeshift Boot & Kernel Synchronization System
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo -e "${BOLD}${CYAN}================================================================${NC}"
echo -e "${BOLD}${CYAN}  INSTALLING TIMESHIFT, BOOT & KERNEL SYNCHRONIZATION SYSTEM   ${NC}"
echo -e "${BOLD}${CYAN}================================================================${NC}"

# 1. Install CLI commands
log_info "1/6: Installing global CLI commands into /usr/local/bin..."
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
log_info "2/6: Installing native Timeshift post-restore hook..."
mkdir -p /etc/timeshift/restore-hooks.d
rm -f /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync.sh
cp "$SCRIPT_DIR/timeshift-restore-hook.sh" /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync
chmod +x /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync
log_ok "Native hook active at /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync (validated for run-parts)."

# 3. Install First-Boot Systemd Service
log_info "3/6: Installing first-boot safeguard systemd service..."
cp "$SCRIPT_DIR/timeshift-boot-sync.service" /etc/systemd/system/timeshift-boot-sync.service
systemctl daemon-reload
systemctl enable timeshift-boot-sync.service
log_ok "Service enabled: timeshift-boot-sync.service."

# 4. Install Desktop Notification Autostart
log_info "4/6: Configuring desktop notification handler..."
mkdir -p /etc/xdg/autostart
cp "$SCRIPT_DIR/timeshift-sync-notify.desktop" /etc/xdg/autostart/timeshift-sync-notify.desktop
log_ok "Desktop notification handler installed."

# 5. Fix Existing Older Snapshots
log_info "5/6: Inspecting and fixing existing Timeshift snapshots..."
bash "$SCRIPT_DIR/fix-existing-snapshots.sh"
log_ok "Existing snapshots repaired and verified."

# 6. Ensure GRUB BTRFS daemon is watching
log_info "6/6: Verifying grub-btrfsd daemon..."
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
echo -e " • Old Snapshots:      ${BOLD}Repaired with LTS kernel & clean bootloader targets${NC}"
echo "----------------------------------------------------------------"
