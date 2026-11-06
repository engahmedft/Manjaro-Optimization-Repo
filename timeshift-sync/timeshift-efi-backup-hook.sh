#!/usr/bin/env bash
# ==============================================================================
# 01-timeshift-efi-backup - Native Timeshift Post-Backup Hook
# ==============================================================================
# Executed automatically by Timeshift (GUI and CLI) when any snapshot finishes.
# Archives the active EFI system partition (/boot/efi) into the snapshot folder
# as 'efi_backup.tar.gz' to enable full, exact 1:1 original restores.
# ==============================================================================

set -euo pipefail

LOG_FILE="/var/log/timeshift-sync-efi-backup.log"
exec >> "$LOG_FILE" 2>&1

echo "=================================================================="
echo "Timeshift Post-Backup EFI Archival Hook triggered at: $(date -Iseconds)"
echo "TS_SNAPSHOT_PATH: ${TS_SNAPSHOT_PATH:-undefined}"

TARGET_DIR="${TS_SNAPSHOT_PATH:-${1:-}}"

if [[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
    # Fallback: check active timeshift mount points
    TARGET_DIR=$(find /run/timeshift -type d -path '*/timeshift-btrfs/snapshots/*' -mindepth 4 -maxdepth 4 2>/dev/null | sort -r | head -n 1 || true)
fi

if [[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
    echo "[WARN] Could not determine snapshot directory path. Aborting EFI backup."
    exit 0
fi

echo "[INFO] Target Snapshot Directory: $TARGET_DIR"

EFI_MOUNT="/boot/efi"
if ! mountpoint -q "$EFI_MOUNT"; then
    echo "[WARN] $EFI_MOUNT is not a mountpoint. Checking directory contents..."
fi

if [[ ! -d "$EFI_MOUNT" || -z "$(ls -A "$EFI_MOUNT" 2>/dev/null)" ]]; then
    echo "[WARN] $EFI_MOUNT is empty or missing. Skipping EFI archival."
    exit 0
fi

ARCHIVE_PATH="$TARGET_DIR/efi_backup.tar.gz"
echo "[INFO] Creating EFI partition archive at: $ARCHIVE_PATH..."

tar -czf "$ARCHIVE_PATH" -C "$EFI_MOUNT" .

echo "[OK] EFI partition archived successfully ($(du -h "$ARCHIVE_PATH" 2>/dev/null | cut -f1 || echo "done"))."
