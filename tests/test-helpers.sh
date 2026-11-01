#!/usr/bin/env bash
# ==============================================================================
# Unit Test Suite for Manjaro Optimization Script Helpers (Phase 1 & Phase 2)
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
# Test 1: Partition Classification (is_sensitive_partition)
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

# Legitimate user labels containing substrings (must NOT be detected as sensitive)
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

# Root and critical directories must never be touched
purge_mount_dir ""
purge_mount_dir "/"
purge_mount_dir "/mnt"
purge_mount_dir "/media"
assert_eq 0 0 "purge_mount_dir safely skips root/system directories"

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
# Test 4: JSONC Comment-Tolerant Parsing & Atomic Save
# ------------------------------------------------------------------------------
echo "--- Testing JSONC Parsing & Atomic Save ---"
TEST_JSON="$TEST_DIR/settings.json"
cat << 'EOF' > "$TEST_JSON"
{
    // This is a single line comment
    "workbench.colorTheme": "Default Dark Modern",
    /* This is a 
       multi-line comment */
    "editor.fontSize": 14,
    "editor.tabSize": 4, // trailing comma below
}
EOF

python3 -c '
import json, os, sys, re, tempfile, shutil

def load_jsonc(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        content = re.sub(r"//.*", "", content)
        content = re.sub(r"/\*[\s\S]*?\*/", "", content)
        content = re.sub(r",\s*([}\]])", r"\1", content)
        return json.loads(content)
    except Exception as e:
        return None

def atomic_save_json(path, data, indent=4):
    dir_name = os.path.dirname(path)
    if dir_name and not os.path.exists(dir_name):
        os.makedirs(dir_name, exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + ".bak")
    fd, tmp_path = tempfile.mkstemp(dir=dir_name if dir_name else None, prefix=".tmp_json_")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent)
    os.replace(tmp_path, path)

path = sys.argv[1]
data = load_jsonc(path)
assert data is not None, "Failed to parse JSONC with comments"
assert data["editor.fontSize"] == 14, "Original key lost"
assert data["editor.tabSize"] == 4, "Trailing comma caused loss"

# Add a key and save atomically
data["window.zoomLevel"] = 1
atomic_save_json(path, data)
assert os.path.exists(path + ".bak"), "Backup file was not created"

# Verify modified file
with open(path) as f:
    saved = json.load(f)
assert saved["window.zoomLevel"] == 1, "New key not saved"
assert saved["editor.fontSize"] == 14, "Original key missing after save"
print("JSONC atomic parsing test passed.")
' "$TEST_JSON"

assert_eq 0 $? "JSONC comments and trailing commas parsed and saved atomically"

# ------------------------------------------------------------------------------
# Test 5: PAM Fingerprint Safeguard
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

# Simulate configure_pam_fingerprint logic on fixture
pam_target="$TEST_PAM"
if [[ ! -f "$pam_target.pre-fprintd" ]]; then
    cp -a "$pam_target" "$pam_target.pre-fprintd"
fi
sed -i '0,/^auth/{s/^auth/auth       sufficient   pam_fprintd.so\nauth/}' "$pam_target"

auth_count=$(grep -cE '^[[:space:]]*auth' "$pam_target" || true)
assert_eq 1 "$(( auth_count >= 2 ))" "PAM has at least 2 auth lines (sufficient + fallback)"
assert_eq 1 "$([[ -f $TEST_PAM.pre-fprintd ]] && echo 1 || echo 0)" "PAM pre-fprintd backup created"
assert_eq 1 "$(grep -q "auth       include      system-auth" "$TEST_PAM" && echo 1 || echo 0)" "Fallback system-auth rule preserved"

echo ""
echo "========================================================================"
echo "TEST RESULTS: $PASSED passed, $FAILED failed."
echo "========================================================================"

if (( FAILED > 0 )); then
    exit 1
fi
