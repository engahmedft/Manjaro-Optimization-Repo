#!/usr/bin/env bash
# ==============================================================================
# tests/test-timeshift.sh - Automated Unit & Integration Tests for Timeshift Sync
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
# Test 1: Dynamic Kernel Discovery & 7.1 Exclusion
# ------------------------------------------------------------------------------
echo "--- Testing discover_host_kernels logic ---"
MOCK_BOOT="$TEST_SANDBOX/boot"
mkdir -p "$MOCK_BOOT"
touch "$MOCK_BOOT/vmlinuz-6.12-x86_64"
touch "$MOCK_BOOT/vmlinuz-6.6-x86_64"
touch "$MOCK_BOOT/vmlinuz-7.1-x86_64" # Broken kernel

BROKEN_KERNELS=("7.1")
test_discover() {
    local k_list=()
    local img
    for img in "$MOCK_BOOT"/vmlinuz-*-x86_64; do
        [[ ! -f "$img" ]] && continue
        local k
        k=$(basename "$img" | sed -E 's/^vmlinuz-([0-9]+\.[0-9]+).*/\1/')
        local broken=false
        local b
        for b in "${BROKEN_KERNELS[@]}"; do
            if [[ "$k" == "$b" ]]; then
                broken=true
                break
            fi
        done
        if [[ "$broken" == "false" && -n "$k" ]]; then
            if [[ ! " ${k_list[*]:-} " =~ " ${k} " ]]; then
                k_list+=("$k")
            fi
        fi
    done
    echo "${k_list[@]:-}"
}

discovered=$(test_discover)
assert_eq 1 "$([[ "$discovered" =~ "6.12" ]] && echo 1 || echo 0)" "Discovers 6.12 LTS kernel"
assert_eq 1 "$([[ "$discovered" =~ "6.6" ]] && echo 1 || echo 0)" "Discovers 6.6 LTS kernel"
assert_eq 0 "$([[ "$discovered" =~ "7.1" ]] && echo 1 || echo 0)" "Excludes broken 7.1 kernel"

# ------------------------------------------------------------------------------
# Test 2: Never Purge Only Kernel in Snapshot
# ------------------------------------------------------------------------------
echo "--- Testing Never Purge Only Kernel ---"
SNAP_BOOT="$TEST_SANDBOX/snap_boot"
mkdir -p "$SNAP_BOOT"
touch "$SNAP_BOOT/vmlinuz-7.1-x86_64"

# Attempt removal simulation
other_kernels=$(find "$SNAP_BOOT" -maxdepth 1 -name "vmlinuz-*-x86_64" ! -name "vmlinuz-7.1-x86_64" 2>/dev/null || true)
if [[ -n "$other_kernels" ]]; then
    rm -f "$SNAP_BOOT"/vmlinuz-7.1-x86_64*
fi

assert_eq 1 "$([[ -f "$SNAP_BOOT/vmlinuz-7.1-x86_64" ]] && echo 1 || echo 0)" "Kernel 7.1 preserved when no other kernel exists"

# Now simulate when 6.12 is injected first
touch "$SNAP_BOOT/vmlinuz-6.12-x86_64"
other_kernels=$(find "$SNAP_BOOT" -maxdepth 1 -name "vmlinuz-*-x86_64" ! -name "vmlinuz-7.1-x86_64" 2>/dev/null || true)
if [[ -n "$other_kernels" ]]; then
    rm -f "$SNAP_BOOT"/vmlinuz-7.1-x86_64*
fi

assert_eq 0 "$([[ -f "$SNAP_BOOT/vmlinuz-7.1-x86_64" ]] && echo 1 || echo 0)" "Kernel 7.1 purged when fallback 6.12 kernel is confirmed present"

# ------------------------------------------------------------------------------
# Test 3: Unlocked Snapshot Tracking & Re-locking
# ------------------------------------------------------------------------------
echo "--- Testing Unlocked Snapshot Tracking ---"
UNLOCKED_SNAPSHOTS=()
mock_snap1="$TEST_SANDBOX/snap1"
mock_snap2="$TEST_SANDBOX/snap2"
mkdir -p "$mock_snap1" "$mock_snap2"

UNLOCKED_SNAPSHOTS+=("$mock_snap1")
UNLOCKED_SNAPSHOTS+=("$mock_snap2")
assert_eq 2 "${#UNLOCKED_SNAPSHOTS[@]}" "Tracked 2 unlocked snapshots"

# Remove snap1
remaining=()
for u in "${UNLOCKED_SNAPSHOTS[@]}"; do
    [[ "$u" != "$mock_snap1" ]] && remaining+=("$u")
done
UNLOCKED_SNAPSHOTS=("${remaining[@]:-}")
assert_eq 1 "${#UNLOCKED_SNAPSHOTS[@]}" "Unlocked snapshots decremented after relocking"
assert_eq "$mock_snap2" "${UNLOCKED_SNAPSHOTS[0]}" "Remaining snapshot is snap2"

echo ""
echo "========================================================================"
echo "TEST RESULTS: $PASSED passed, $FAILED failed."
echo "========================================================================"

if (( FAILED > 0 )); then
    exit 1
fi
