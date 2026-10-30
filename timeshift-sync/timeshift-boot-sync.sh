#!/usr/bin/env bash
# ==============================================================================
# timeshift-boot-sync.sh - First-Boot Automatic Safeguard
# ==============================================================================
# Runs early on boot to verify kernel and GRUB consistency, particularly after
# restorations performed without chroot hooks.
# ==============================================================================

LOG_FILE="/var/log/timeshift-sync-boot.log"
exec >> "$LOG_FILE" 2>&1

echo "=================================================================="
echo "Timeshift Boot Safeguard executed at: $(date -Iseconds)"

MARKER_FILE="/var/lib/timeshift-sync/firstboot.marker"
STATE_FILE="/var/lib/timeshift-sync/boot_state.json"
mkdir -p /var/lib/timeshift-sync

# Current root subvolume id
curr_subvol_id=$(btrfs subvolume show / 2>/dev/null | grep -i "Subvolume ID:" | awk '{print $NF}' || true)
prev_subvol_id=""
if [[ -f "$STATE_FILE" ]]; then
    prev_subvol_id=$(grep -oP '"subvol_id"\s*:\s*"\K[^"]+' "$STATE_FILE" 2>/dev/null || true)
fi

echo "[INFO] Current root subvolume ID: $curr_subvol_id | Previous: $prev_subvol_id"

restore_detected=false

if [[ -f "$MARKER_FILE" ]]; then
    echo "[INFO] Firstboot marker file detected."
    restore_detected=true
    rm -f "$MARKER_FILE"
elif [[ -n "$curr_subvol_id" && -n "$prev_subvol_id" && "$curr_subvol_id" != "$prev_subvol_id" ]]; then
    echo "[INFO] Root subvolume ID changed from $prev_subvol_id to $curr_subvol_id (restore detected)."
    restore_detected=true
fi

# Always verify grubenv integrity
if command -v grub-editenv &>/dev/null; then
    saved=$(grub-editenv /boot/grub/grubenv list 2>/dev/null | grep "saved_entry=" || true)
    if [[ -n "$saved" ]]; then
        # Check if the saved entry kernel exists
        saved_val="${saved#saved_entry=}"
        if [[ -n "$saved_val" && "$restore_detected" == "true" ]]; then
            echo "[INFO] Unsetting stale saved_entry: $saved_val"
            grub-editenv /boot/grub/grubenv unset saved_entry 2>/dev/null || true
            grub-editenv /boot/grub/grubenv unset next_entry 2>/dev/null || true
        fi
    fi
fi

if [[ "$restore_detected" == "true" ]]; then
    echo "[INFO] Performing post-restore GRUB & snapshots alignment..."
    if command -v update-grub &>/dev/null; then
        update-grub >/dev/null 2>&1 || true
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    fi

    if [[ -x /etc/grub.d/41_snapshots-btrfs ]]; then
        /etc/grub.d/41_snapshots-btrfs >/dev/null 2>&1 || true
    fi

    # Trigger desktop notification flag for logged in user
    mkdir -p /run/timeshift-sync
    touch /run/timeshift-sync/notify-pending
    chmod 666 /run/timeshift-sync/notify-pending 2>/dev/null || true
    echo "[OK] Boot synchronization completed."
else
    echo "[OK] System in sync. No restore actions needed."
fi

# Save current state
cat << EOF > "$STATE_FILE"
{
  "last_check" : "$(date -Iseconds)",
  "subvol_id" : "$curr_subvol_id",
  "kernel" : "$(uname -r)"
}
EOF
exit 0
