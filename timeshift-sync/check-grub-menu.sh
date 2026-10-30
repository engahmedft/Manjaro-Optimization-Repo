#!/usr/bin/env bash
# ==============================================================================
# check-grub-menu.sh - Verify GRUB Bootloader Menu Structure for Duplicates
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

GRUB_CFG="/boot/grub/grub.cfg"
GRUB_BTRFS_CFG="/boot/grub/grub-btrfs.cfg"

if [[ ! -f "$GRUB_CFG" ]]; then
    log_error "$GRUB_CFG does not exist."
    exit 1
fi

echo -e "\n${BOLD}${CYAN}================================================================${NC}"
echo -e "${BOLD}${CYAN}             GRUB MENU STRUCTURE & DUPLICATION AUDIT            ${NC}"
echo -e "${BOLD}${CYAN}================================================================${NC}"

# Check for stale temporary files
if [[ -f "/boot/grub/grub.cfg.new" ]]; then
    log_warn "Detected stale temporary file: /boot/grub/grub.cfg.new (clearing...)"
    rm -f "/boot/grub/grub.cfg.new"
    log_ok "Stale /boot/grub/grub.cfg.new removed."
fi

# Extract top-level menu entries and submenus
echo -e "\n${BOLD}1. Top-Level GRUB Menu Entries:${NC}"
echo "----------------------------------------------------------------"
declare -a TOP_ENTRIES=()
declare -A ENTRY_COUNTS=()

while IFS= read -r line; do
    if [[ "$line" =~ ^menuentry[[:space:]]+[\'\"]([^\'\"]+)[\'\"] ]]; then
        local entry="${BASH_REMATCH[1]}"
        TOP_ENTRIES+=("$entry")
        ((ENTRY_COUNTS["$entry"]=${ENTRY_COUNTS["$entry"]:-0}+1))
    elif [[ "$line" =~ ^submenu[[:space:]]+[\'\"]([^\'\"]+)[\'\"] ]]; then
        local sub="${BASH_REMATCH[1]}"
        TOP_ENTRIES+=("[SUBMENU] $sub")
        ((ENTRY_COUNTS["[SUBMENU] $sub"]=${ENTRY_COUNTS["[SUBMENU] $sub"]:-0}+1))
    fi
done < <(grep -E "^(menuentry|submenu) " "$GRUB_CFG")

local has_duplicates=false
for entry in "${TOP_ENTRIES[@]}"; do
    local count="${ENTRY_COUNTS["$entry"]}"
    if [[ "$count" -gt 1 ]]; then
        echo -e " ${RED}✖ [DUPLICATE x$count]${NC} $entry"
        has_duplicates=true
    else
        echo -e " ${GREEN}✔${NC} $entry"
    fi
done

echo "----------------------------------------------------------------"
if [[ "$has_duplicates" == "true" ]]; then
    log_warn "Duplicate entries detected in top-level GRUB menu."
else
    log_ok "Zero duplicate entries found in top-level GRUB menu!"
fi

# Inspect Snapshots Submenu in grub-btrfs.cfg
if [[ -f "$GRUB_BTRFS_CFG" ]]; then
    echo -e "\n${BOLD}2. Timeshift Snapshots Submenu (${CYAN}grub-btrfs.cfg${NC}):${NC}"
    echo "----------------------------------------------------------------"
    declare -A SNAP_COUNTS=()
    local snap_duplicates=false
    local snap_total=0

    while IFS= read -r sline; do
        if [[ "$sline" =~ ^submenu[[:space:]]+[\'\"]([^\|]+\|[^\|]+\|[^\|]+\|[^\|]+) ]]; then
            local snap_title="${BASH_REMATCH[1]}"
            # Extract timestamp/path
            local snap_date snap_path
            snap_date=$(echo "$snap_title" | awk -F'|' '{print $2}' | xargs)
            snap_path=$(echo "$snap_title" | awk -F'|' '{print $3}' | xargs)
            local key="$snap_date ($snap_path)"
            ((SNAP_COUNTS["$key"]=${SNAP_COUNTS["$key"]:-0}+1))
            ((snap_total++))
        fi
    done < "$GRUB_BTRFS_CFG"

    for key in "${!SNAP_COUNTS[@]}"; do
        local scount="${SNAP_COUNTS["$key"]}"
        if [[ "$scount" -gt 1 ]]; then
            echo -e " ${RED}✖ [DUPLICATE SNAPSHOT x$scount]${NC} $key"
            snap_duplicates=true
        else
            echo -e " ${GREEN}✔${NC} $key"
        fi
    done

    echo "----------------------------------------------------------------"
    if [[ "$snap_duplicates" == "true" ]]; then
        log_warn "Duplicate snapshot entries detected."
    else
        log_ok "All $snap_total snapshot entries in GRUB are unique and properly indexed."
    fi
fi

# Verify grubenv state
echo -e "\n${BOLD}3. GRUB Environment State (${CYAN}grubenv${NC}):${NC}"
echo "----------------------------------------------------------------"
local saved_entry
saved_entry=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | grep "^saved_entry=" || true)
if [[ -n "$saved_entry" ]]; then
    echo -e " Current saved_entry: ${CYAN}$saved_entry${NC}"
else
    echo -e " Current saved_entry: ${GREEN}[Clean / Not set] (defaults to highest kernel)${NC}"
fi

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}                     GRUB AUDIT COMPLETE                        ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}\n"
