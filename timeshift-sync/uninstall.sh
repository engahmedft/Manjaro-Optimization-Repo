#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh - Uninstaller for Timeshift Boot & Kernel Synchronization Suite
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

echo -e "${BOLD}${CYAN}================================================================${NC}"
echo -e "${BOLD}${CYAN}  UNINSTALLING TIMESHIFT, BOOT & KERNEL SYNCHRONIZATION SUITE  ${NC}"
echo -e "${BOLD}${CYAN}================================================================${NC}"

# 1. Stop and disable first-boot service
log_info "1/5: Disabling and removing systemd services..."
if systemctl is-active timeshift-boot-sync.service &>/dev/null; then
    systemctl stop timeshift-boot-sync.service 2>/dev/null || true
fi
systemctl disable timeshift-boot-sync.service 2>/dev/null || true
rm -f /etc/systemd/system/timeshift-boot-sync.service
systemctl daemon-reload
log_ok "Systemd service removed."

# 2. Remove native Timeshift restore hook
log_info "2/5: Removing Timeshift native restore hook..."
rm -f /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync
rm -f /etc/timeshift/restore-hooks.d/00-timeshift-boot-sync.sh
log_ok "Timeshift restore hook removed."

# 3. Remove desktop notification autostart
log_info "3/5: Removing desktop notification autostart..."
rm -f /etc/xdg/autostart/timeshift-sync-notify.desktop
log_ok "Autostart entry removed."

# 4. Remove CLI binaries
log_info "4/5: Removing CLI binaries from /usr/local/bin..."
rm -f /usr/local/bin/timeshift-restore-sync \
      /usr/local/bin/timeshift-boot-sync.sh \
      /usr/local/bin/timeshift-sync-notify.sh \
      /usr/local/bin/timeshift-fix-snapshots \
      /usr/local/bin/timeshift-check-grub
log_ok "CLI binaries removed."

# 5. Clean runtime and state flags
log_info "5/5: Clearing transient state files..."
rm -rf /run/timeshift-sync /var/lib/timeshift-sync /usr/local/lib/manjaro-opt
log_ok "State and runtime directories cleared."

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}     TIMESHIFT & BOOT SYNC SUITE UNINSTALLED CLEANLY            ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
