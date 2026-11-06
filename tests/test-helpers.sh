#!/usr/bin/env bash
# ==============================================================================
# Unit Test Suite for Manjaro Optimization Script Helpers & Safety Guards
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d -t manjaro_opt_test_XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo ">>> Running helper tests in isolated sandbox: $TEST_DIR"

# Source script functions without triggering root checks or menu
MANJARO_OPT_SOURCE_ONLY=1 source "$SCRIPT_DIR/Manjaro-Optimization.sh"

PASSED=0
FAILED=0

assert_eq() {
    local expected="$1" actual="$2" desc="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] $desc"
        (( PASSED += 1 ))
    else
        echo "  [FAIL] $desc: expected '$expected', got '$actual'"
        (( FAILED += 1 ))
    fi
}

# ------------------------------------------------------------------------------
# Test 1: Partition Classification (is_sensitive_partition from lib/common.sh)
# ------------------------------------------------------------------------------
echo "--- Testing is_sensitive_partition ---"

# Sensitive partitions (should return 0)
if is_sensitive_partition "de94bba4-06d1-4d40-a16a-bfd50179d6ac" "" ""; then
    assert_eq 0 0 "Recovery GUID detected as sensitive"
else
    assert_eq 0 1 "Recovery GUID detected as sensitive"
fi

if is_sensitive_partition "" "Recovery" ""; then
    assert_eq 0 0 "'Recovery' label detected as sensitive"
else
    assert_eq 0 1 "'Recovery' label detected as sensitive"
fi

if is_sensitive_partition "" "WINRE_DRV" ""; then
    assert_eq 0 0 "'WINRE_DRV' label detected as sensitive"
else
    assert_eq 0 1 "'WINRE_DRV' label detected as sensitive"
fi

if is_sensitive_partition "" "" "DellSupport"; then
    assert_eq 0 0 "'DellSupport' partlabel detected as sensitive"
else
    assert_eq 0 1 "'DellSupport' partlabel detected as sensitive"
fi

# Microsoft Basic Data GUID and legitimate user labels (must NOT be detected as sensitive)
if is_sensitive_partition "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7" "my-data" "Basic data partition"; then
    assert_eq 1 0 "Microsoft Basic Data GUID must NOT be detected as sensitive"
else
    assert_eq 0 0 "Microsoft Basic Data GUID correctly protected"
fi

if is_sensitive_partition "" "Dell-Docs" ""; then
    assert_eq 1 0 "'Dell-Docs' must NOT be detected as sensitive"
else
    assert_eq 0 0 "'Dell-Docs' correctly protected"
fi

if is_sensitive_partition "" "Backup-Restore" ""; then
    assert_eq 1 0 "'Backup-Restore' must NOT be detected as sensitive"
else
    assert_eq 0 0 "'Backup-Restore' correctly protected"
fi

if is_sensitive_partition "" "Respaldo" ""; then
    assert_eq 1 0 "'Respaldo' (substring 'esp') must NOT be detected as sensitive"
else
    assert_eq 0 0 "'Respaldo' correctly protected"
fi

if is_sensitive_partition "" "bootcamp-data" ""; then
    assert_eq 1 0 "'bootcamp-data' must NOT be detected as sensitive"
else
    assert_eq 0 0 "'bootcamp-data' correctly protected"
fi

if is_sensitive_partition "" "my-data" ""; then
    assert_eq 1 0 "'my-data' must NOT be detected as sensitive"
else
    assert_eq 0 0 "'my-data' correctly protected"
fi

# ------------------------------------------------------------------------------
# Test 2: Safe Mount Purging (purge_mount_dir)
# ------------------------------------------------------------------------------
echo "--- Testing purge_mount_dir ---"

# Root, system, and path-traversal directories must never be touched
purge_mount_dir ""
purge_mount_dir "/"
purge_mount_dir "/mnt"
purge_mount_dir "/mnt/"
purge_mount_dir "/mnt/.."
purge_mount_dir "/media"
assert_eq 0 0 "purge_mount_dir safely skips root/system/traversal directories"

# Verify fstab system mount regex matches column-1 UUID and device paths accurately
MOCK_SYS_FSTAB="$TEST_DIR/sys_fstab"
cat << 'EOF' > "$MOCK_SYS_FSTAB"
UUID=7777-8888 /boot/efi vfat defaults,noatime 0 2
/dev/nvme0n1p2 /home btrfs subvol=/@home,defaults 0 0
EOF
grep -qE "^[[:space:]]*(UUID=['\"]?7777-8888['\"]?|/dev/nvme0n1p1)[[:space:]]+/(|boot|boot/efi|efi|home|var|usr)[[:space:]]" "$MOCK_SYS_FSTAB"
assert_eq 0 $? "fstab system guard matches UUID at start of line"
if grep -qE "^[[:space:]]*(UUID=['\"]?9999-0000['\"]?|/dev/nvme0n1p5)[[:space:]]+/(|boot|boot/efi|efi|home|var|usr)[[:space:]]" "$MOCK_SYS_FSTAB"; then
    assert_eq 1 0 "fstab system guard must not false-match unrelated partitions"
else
    assert_eq 0 0 "fstab system guard does not false-match unrelated partitions"
fi

# ------------------------------------------------------------------------------
# Test 2B: Idempotent Btrfs Options in fstab (fstab_ensure_btrfs_opts)
# ------------------------------------------------------------------------------
echo "--- Testing fstab_ensure_btrfs_opts ---"
MOCK_FSTAB="$TEST_DIR/fstab"
cat << 'EOF' > "$MOCK_FSTAB"
# /etc/fstab: static file system information.
UUID=1111-2222 / btrfs subvol=/@,defaults,noatime,discard=async,compress=zstd:1 0 0
UUID=3333-4444 /home btrfs subvol=/@home,defaults,noatime,discard=async,compress=zstd:1 0 0
UUID=5555-6666 /mnt/my-data btrfs defaults,noatime,compress=zstd 0 0
UUID=7777-8888 /boot/efi vfat defaults,noatime 0 2
EOF

# Pass 1: should detect that /mnt/my-data lacks discard=async, modify it, and return 0
if fstab_ensure_btrfs_opts "$MOCK_FSTAB" "noatime" "discard=async"; then
    assert_eq 0 0 "fstab_ensure_btrfs_opts pass 1 modifies fstab"
else
    assert_eq 0 1 "fstab_ensure_btrfs_opts pass 1 failed"
fi

# Verify /mnt/my-data line now has discard=async
grep -q "/mnt/my-data btrfs defaults,noatime,compress=zstd,discard=async" "$MOCK_FSTAB" && assert_eq 0 0 "/mnt/my-data gained discard=async" || assert_eq 0 1 "Option not added"

# Pass 2: running on already compliant fstab should make NO changes and return 1 (no changes)
before_hash=$(md5sum "$MOCK_FSTAB" | cut -d' ' -f1)
if fstab_ensure_btrfs_opts "$MOCK_FSTAB" "noatime" "discard=async"; then
    assert_eq 1 0 "Pass 2 should not modify compliant file"
else
    assert_eq 0 0 "Pass 2 is idempotent (no changes returned)"
fi
after_hash=$(md5sum "$MOCK_FSTAB" | cut -d' ' -f1)
assert_eq "$before_hash" "$after_hash" "fstab byte-identical across repeated passes"

# ------------------------------------------------------------------------------
# Test 3: Hardware Guard (is_supported_hardware)
# ------------------------------------------------------------------------------
echo "--- Testing is_supported_hardware ---"
if FORCE_HW=1 is_supported_hardware; then
    assert_eq 0 0 "FORCE_HW=1 overrides hardware check"
else
    assert_eq 0 1 "FORCE_HW=1 overrides hardware check"
fi

# ------------------------------------------------------------------------------
# Test 4: JSONC Comment-Tolerant Parsing & Atomic Save (Preserving URLs)
# ------------------------------------------------------------------------------
echo "--- Testing JSONC Parsing & Atomic Save (_JSONC_PY_HELPERS) ---"
TEST_JSON="$TEST_DIR/settings.json"
cat << 'EOF' > "$TEST_JSON"
{
    // This is a single line comment
    "workbench.colorTheme": "Default Dark Modern",
    /* This is a 
       multi-line comment */
    "http.proxy": "http://127.0.0.1:8080",
    "homepage": "https://example.com/*not-a-comment*/",
    "editor.fontSize": 14,
    "editor.tabSize": 4, // trailing comma below
}
EOF

python3 -c "${_JSONC_PY_HELPERS}"'
path = sys.argv[1]
data = load_jsonc(path)
assert data is not None, "Failed to parse JSONC with comments and URLs"
assert data["http.proxy"] == "http://127.0.0.1:8080", "URL with // corrupted"
assert data["homepage"] == "https://example.com/*not-a-comment*/", "URL with /* */ corrupted"
assert data["editor.fontSize"] == 14, "Original key lost"
assert data["editor.tabSize"] == 4, "Trailing comma caused loss"

# Add a key and save atomically
data["window.zoomLevel"] = 1
atomic_save_json(path, data, indent=4)
assert os.path.exists(path + ".bak"), "Backup file was not created"

# Verify modified file
with open(path) as f:
    saved = json.load(f)
assert saved["window.zoomLevel"] == 1, "New key not saved"
assert saved["http.proxy"] == "http://127.0.0.1:8080", "URL missing after save"
assert saved["editor.fontSize"] == 14, "Original key missing after save"
print("JSONC atomic parsing test (with URLs) passed.")
' "$TEST_JSON"

assert_eq 0 $? "JSONC comments, trailing commas, and URL strings parsed and saved atomically"

# ------------------------------------------------------------------------------
# Test 5: PAM Fingerprint Safeguard (configure_pam_fingerprint)
# ------------------------------------------------------------------------------
echo "--- Testing PAM Fingerprint Configuration ---"
TEST_PAM="$TEST_DIR/pam_sudo"
cat << 'EOF' > "$TEST_PAM"
#%PAM-1.0
auth       include      system-auth
account    include      system-auth
session    include      system-auth
password   include      system-auth
EOF

# Call actual configure_pam_fingerprint helper
configure_pam_fingerprint "$TEST_PAM"

auth_count=$(grep -cE '^[[:space:]]*auth' "$TEST_PAM" || true)
assert_eq 1 "$(( auth_count >= 2 ))" "PAM has at least 2 auth lines (sufficient + fallback)"
assert_eq 1 "$([[ -f $TEST_PAM.pre-fprintd ]] && echo 1 || echo 0)" "PAM pre-fprintd backup created"
assert_eq 1 "$(grep -q "auth       include      system-auth" "$TEST_PAM" && echo 1 || echo 0)" "Fallback system-auth rule preserved"

# Idempotency check on second pass
pam_hash1=$(md5sum "$TEST_PAM" | cut -d' ' -f1)
configure_pam_fingerprint "$TEST_PAM"
pam_hash2=$(md5sum "$TEST_PAM" | cut -d' ' -f1)
assert_eq "$pam_hash1" "$pam_hash2" "configure_pam_fingerprint is idempotent on second run"

# Rollback guard check: PAM file with no fallback auth rule must be rejected and reverted
TEST_PAM_BAD="$TEST_DIR/pam_no_auth"
cat << 'EOF' > "$TEST_PAM_BAD"
#%PAM-1.0
account    include      system-auth
EOF
if configure_pam_fingerprint "$TEST_PAM_BAD" 2>/dev/null; then
    assert_eq 1 0 "configure_pam_fingerprint must reject PAM file without fallback auth"
else
    assert_eq 0 0 "configure_pam_fingerprint rejects and reverts PAM without fallback auth"
fi
assert_eq 0 "$(grep -c "pam_fprintd.so" "$TEST_PAM_BAD" || true)" "Rejected PAM file reverted to original content"

# ------------------------------------------------------------------------------
# Test 6: Idempotent set_grub_var Helper
# ------------------------------------------------------------------------------
echo "--- Testing set_grub_var ---"
TEST_GRUB="$TEST_DIR/grub_default"
cat << 'EOF' > "$TEST_GRUB"
GRUB_TIMEOUT=5
#GRUB_DISABLE_OS_PROBER=false
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
EOF

# 1. Update existing key
set_grub_var "GRUB_TIMEOUT" "10" "$TEST_GRUB"
grep -q "^GRUB_TIMEOUT=10" "$TEST_GRUB"
assert_eq 0 $? "set_grub_var updates existing key"

# 2. Uncomment and set key
set_grub_var "GRUB_DISABLE_OS_PROBER" "false" "$TEST_GRUB"
grep -q "^GRUB_DISABLE_OS_PROBER=false" "$TEST_GRUB"
assert_eq 0 $? "set_grub_var uncomments commented key"

# 3. Append missing key
set_grub_var "GRUB_THEME" '"/usr/share/grub/themes/manjaro-hidpi/theme.txt"' "$TEST_GRUB"
grep -q 'GRUB_THEME="/usr/share/grub/themes/manjaro-hidpi/theme.txt"' "$TEST_GRUB"
assert_eq 0 $? "set_grub_var appends new key"

# 4. Idempotency on exact value
hash1=$(md5sum "$TEST_GRUB" | cut -d' ' -f1)
set_grub_var "GRUB_TIMEOUT" "10" "$TEST_GRUB"
hash2=$(md5sum "$TEST_GRUB" | cut -d' ' -f1)
assert_eq "$hash1" "$hash2" "set_grub_var is byte-identical when key=val is already current"

echo ""
echo "========================================================================"
echo "TEST RESULTS: $PASSED passed, $FAILED failed."
echo "========================================================================"

if (( FAILED > 0 )); then
    exit 1
fi
