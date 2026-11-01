#!/usr/bin/env bash
# Checks for pending restore notification and notifies the desktop user
FLAG="/run/timeshift-sync/notify-pending"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/timeshift-sync"
ACK_FILE="$STATE_DIR/ack"

if [[ -f "$FLAG" ]]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    sleep 3 # Allow desktop notification daemon to initialize
    if command -v notify-send &>/dev/null; then
        notify-send -u normal -t 8000 \
            -i timeshift \
            "Timeshift Boot Safeguard" \
            "GRUB bootloader, /boot, and Linux kernels were synchronized successfully."
    fi
    date -Iseconds > "$ACK_FILE" 2>/dev/null || true
    rm -f "$FLAG" 2>/dev/null || true
fi
