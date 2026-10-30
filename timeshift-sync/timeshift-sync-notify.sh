#!/usr/bin/env bash
# Checks for pending restore notification and notifies the desktop user
FLAG="/run/timeshift-sync/notify-pending"
if [[ -f "$FLAG" ]]; then
    sleep 3 # Allow desktop notification daemon to initialize
    if command -v notify-send &>/dev/null; then
        notify-send -u normal -t 8000 \
            -i timeshift \
            "Timeshift Boot Safeguard" \
            "GRUB bootloader, /boot, and Linux kernels were synchronized successfully."
    fi
    rm -f "$FLAG"
fi
