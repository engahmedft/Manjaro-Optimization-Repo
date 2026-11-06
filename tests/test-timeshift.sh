#!/usr/bin/env bash
# ==============================================================================
# tests/test-timeshift.sh - Automated Unit & Integration Tests for Timeshift Sync
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source canonical shared library
source "$REPO_DIR/lib/common.sh"

TEST_SANDBOX=$(mktemp -d /tmp/manjaro_opt_ts_test_XXXXXX)
cleanup() {
    rm -rf "$TEST_SANDBOX"
}
trap cleanup EXIT INT TERM

PASSED=0
FAILED=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local desc="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] $desc"
        (( PASSED += 1 ))
    else
        echo "  [FAIL] $desc (Expected: '$expected', Got: '$actual')"
        (( FAILED += 1 ))
    fi
}

echo ">>> Running Timeshift sync tests in sandbox: $TEST_SANDBOX"

# ------------------------------------------------------------------------------
# Test 1: Dynamic Kernel Discovery & 7.1 Exclusion (discover_host_kernels)
# ------------------------------------------------------------------------------
echo "--- Testing discover_host_kernels ---"
MOCK_BOOT="$TEST_SANDBOX/boot"
mkdir -p "$MOCK_BOOT"
touch "$MOCK_BOOT/vmlinuz-6.12-x86_64"
touch "$MOCK_BOOT/vmlinuz-6.6-x86_64"
touch "$MOCK_BOOT/vmlinuz-7.1-x86_64" # Broken kernel

discovered=$(discover_host_kernels "$MOCK_BOOT")
assert_eq 1 "$([[ "$discovered" =~ "6.12" ]] && echo 1 || echo 0)" "Discovers 6.12 LTS kernel"
assert_eq 1 "$([[ "$discovered" =~ "6.6" ]] && echo 1 || echo 0)" "Discovers 6.6 LTS kernel"
assert_eq 0 "$([[ "$discovered" =~ "7.1" ]] && echo 1 || echo 0)" "Excludes broken 7.1 kernel"

# ------------------------------------------------------------------------------
# Test 2: Never Purge Only Kernel in Snapshot (purge_broken_kernels_from_root)
# ------------------------------------------------------------------------------
echo "--- Testing purge_broken_kernels_from_root ---"
SNAP_ROOT="$TEST_SANDBOX/snap_root"
mkdir -p "$SNAP_ROOT/boot" "$SNAP_ROOT/usr/lib/modules/7.1.0-1-MANJARO"
touch "$SNAP_ROOT/boot/vmlinuz-7.1-x86_64"
touch "$SNAP_ROOT/boot/initramfs-7.1-x86_64.img"

# Attempt removal when 7.1 is the ONLY kernel (must return 1 and preserve 7.1)
if purge_broken_kernels_from_root "$SNAP_ROOT" 2>/dev/null; then
    assert_eq 1 0 "purge_broken_kernels_from_root returns non-zero when 7.1 is only kernel"
else
    assert_eq 0 0 "purge_broken_kernels_from_root returns non-zero when 7.1 is only kernel"
fi
assert_eq 1 "$([[ -f "$SNAP_ROOT/boot/vmlinuz-7.1-x86_64" ]] && echo 1 || echo 0)" "Kernel 7.1 preserved when no other kernel exists"
assert_eq 1 "$([[ -d "$SNAP_ROOT/usr/lib/modules/7.1.0-1-MANJARO" ]] && echo 1 || echo 0)" "Kernel 7.1 modules preserved when no other kernel exists"

# Now inject fallback 6.12 kernel and verify 7.1 kernel + modules are purged
touch "$SNAP_ROOT/boot/vmlinuz-6.12-x86_64"
mkdir -p "$SNAP_ROOT/usr/lib/modules/6.12.0-1-MANJARO"
purge_broken_kernels_from_root "$SNAP_ROOT" >/dev/null

assert_eq 0 "$([[ -f "$SNAP_ROOT/boot/vmlinuz-7.1-x86_64" ]] && echo 1 || echo 0)" "Kernel 7.1 purged when fallback 6.12 kernel is confirmed present"
assert_eq 0 "$([[ -d "$SNAP_ROOT/usr/lib/modules/7.1.0-1-MANJARO" ]] && echo 1 || echo 0)" "Orphaned 7.1 kernel modules purged alongside kernel image"
assert_eq 1 "$([[ -d "$SNAP_ROOT/usr/lib/modules/6.12.0-1-MANJARO" ]] && echo 1 || echo 0)" "Valid 6.12 kernel modules preserved"

# ------------------------------------------------------------------------------
# Test 3: Unlocked Snapshot Tracking & Re-locking (track/untrack_unlocked_snapshot)
# ------------------------------------------------------------------------------
echo "--- Testing track_unlocked_snapshot & untrack_unlocked_snapshot ---"
UNLOCKED_SNAPSHOTS=()
mock_snap1="$TEST_SANDBOX/snap1"
mock_snap2="$TEST_SANDBOX/snap2"
mkdir -p "$mock_snap1" "$mock_snap2"

track_unlocked_snapshot "$mock_snap1"
track_unlocked_snapshot "$mock_snap2"
track_unlocked_snapshot "$mock_snap1" # Duplicate add should be ignored
assert_eq 2 "${#UNLOCKED_SNAPSHOTS[@]}" "Tracked 2 unique unlocked snapshots"

untrack_unlocked_snapshot "$mock_snap1"
assert_eq 1 "${#UNLOCKED_SNAPSHOTS[@]}" "Unlocked snapshots decremented after relocking"
assert_eq "$mock_snap2" "${UNLOCKED_SNAPSHOTS[0]}" "Remaining snapshot is snap2"

# ------------------------------------------------------------------------------
# Test 4: EFI Partition Archival & Extraction Hook
# ------------------------------------------------------------------------------
echo "--- Testing EFI partition archival & extraction ---"
MOCK_EFI="$TEST_SANDBOX/mock_efi"
MOCK_SNAP="$TEST_SANDBOX/mock_snap"
MOCK_RESTORE_EFI="$TEST_SANDBOX/mock_restore_efi"
mkdir -p "$MOCK_EFI/EFI/Manjaro" "$MOCK_EFI/EFI/Boot" "$MOCK_SNAP" "$MOCK_RESTORE_EFI"
echo "GRUB_EFI_BINARY_DATA" > "$MOCK_EFI/EFI/Manjaro/grubx64.efi"
echo "BOOT_EFI_BINARY_DATA" > "$MOCK_EFI/EFI/Boot/bootx64.efi"

# Simulate post-backup hook with TS_SNAPSHOT_PATH
tar -czf "$MOCK_SNAP/efi_backup.tar.gz" -C "$MOCK_EFI" .

assert_eq 1 "$([[ -f "$MOCK_SNAP/efi_backup.tar.gz" ]] && echo 1 || echo 0)" "EFI backup archive created in snapshot directory"

# Simulate restore extraction
tar -xzf "$MOCK_SNAP/efi_backup.tar.gz" -C "$MOCK_RESTORE_EFI"
assert_eq 1 "$([[ -f "$MOCK_RESTORE_EFI/EFI/Manjaro/grubx64.efi" ]] && echo 1 || echo 0)" "Manjaro EFI binary restored"
assert_eq "GRUB_EFI_BINARY_DATA" "$(cat "$MOCK_RESTORE_EFI/EFI/Manjaro/grubx64.efi")" "EFI binary content verified intact"

echo ""
echo "========================================================================"
echo "TEST RESULTS: $PASSED passed, $FAILED failed."
echo "========================================================================"

if (( FAILED > 0 )); then
    exit 1
fi
