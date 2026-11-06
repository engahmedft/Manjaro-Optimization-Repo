#!/usr/bin/env bash
# ==============================================================================
# lib/common.sh - Shared Helper Library for Manjaro Optimization & Control Center
# ==============================================================================

[[ -n "${LIB_MANJARO_OPT_COMMON_LOADED:-}" ]] && return 0
LIB_MANJARO_OPT_COMMON_LOADED=1

# ANSI Color Palettes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Timestamps & Standard Logging
timestamp() { printf '%(%Y-%m-%d %H:%M:%S)T' -1; }
log_info()  { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[0;34m[INFO]\033[0m %b\n' -1 "$1"; }
log_ok()    { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[0;32m[OK]\033[0m %b\n' -1 "$1"; }
log_warn()  { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[1;33m[WARN]\033[0m %b\n' -1 "$1"; }
log_error() { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[0;31m[ERROR]\033[0m %b\n' -1 "$1" >&2; }

# Robust User Input Reader (exits cleanly on EOF / closed stdin)
ask() {
    local __var_name="$1"
    local __prompt="$2"
    local __input=""
    if ! read -rp "$__prompt" __input; then
        echo ""
        log_warn "Standard input closed (EOF). Exiting."
        exit 0
    fi
    printf -v "$__var_name" '%s' "$__input"
}

# Hardware Compatibility Guard
is_supported_hardware() {
    if [[ "${FORCE_HW:-0}" == "1" ]]; then
        return 0
    fi
    local prod_name=""
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        prod_name=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
    fi
    if [[ "$prod_name" =~ Inspiron[[:space:]]+7706 ]]; then
        return 0
    fi
    return 1
}

# Sensitive Partition Protection Filter
# Usage: is_sensitive_partition <parttype_guid> <label> <partlabel>
is_sensitive_partition() {
    local parttype="${1:-}" label="${2:-}" partlabel="${3:-}"
    parttype="${parttype,,}"
    label="${label,,}"
    partlabel="${partlabel,,}"
    if [[ "$parttype" =~ ^(de94bba4-06d1-4d40-a16a-bfd50179d6ac|e3c9e316-0b5c-4db8-817d-f92df00215ae|c12a7328-f81f-11d2-ba4b-00a0c93ec93b|21686148-6449-6e6f-744e-656564454649)$ ]]; then
        return 0
    fi
    local re='(^|[^a-z0-9])(recovery|winre|winre_drv|pbr_drv|dellsupport|dellutility|dellrecovery|diagnostics|system reserved|system_reserved|efi system partition|esp|msr)([^a-z0-9]|$)'
    if [[ "$label" =~ $re || "$partlabel" =~ $re ]]; then
        return 0
    fi
    return 1
}

# Safe Mount Directory Cleaner
purge_mount_dir() {
    local target="$1"
    [[ -z "$target" || "$target" == "/" || "$target" == "/mnt" || "$target" == "/mnt/" || "$target" == "/media" || "$target" == "/media/" ]] && return 0

    local norm_target
    norm_target=$(realpath -m "$target" 2>/dev/null || echo "$target")

    case "$norm_target" in
        ""|"/"|"/mnt"|"/media"|"/boot"*|"/efi"*|"/etc"*|"/home"*|"/root"*|"/usr"*|"/var"*|"/dev"*|"/proc"*|"/sys"*)
            return 0
            ;;
    esac

    if [[ "$norm_target" != /mnt/* && "$norm_target" != /media/* ]]; then
        return 0
    fi

    if mountpoint -q "$norm_target" 2>/dev/null; then
        return 0
    fi

    if [[ -d "$norm_target" ]]; then
        rmdir "$norm_target" 2>/dev/null || true
    fi
}

# Idempotent Btrfs Mount Options Helper for /etc/fstab
fstab_ensure_btrfs_opts() {
    local f="${1:-/etc/fstab}"
    [[ ! -f "$f" ]] && return 1
    shift || true
    local opts_to_add=("noatime" "discard=async")
    [[ $# -gt 0 ]] && opts_to_add=("$@")

    local line out=() modified=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^([^#].*[[:space:]]btrfs[[:space:]]+)([^[:space:]]+)(.*)$ ]]; then
            local prefix="${BASH_REMATCH[1]}"
            local cur_opts="${BASH_REMATCH[2]}"
            local suffix="${BASH_REMATCH[3]}"
            local opt_list=",${cur_opts},"
            local opt_changed=false
            local o

            for o in "${opts_to_add[@]}"; do
                local key="${o%%=*}"
                if [[ "$opt_list" != *",$o,"* && "$opt_list" != *",$key="* ]]; then
                    opt_list+="${o},"
                    opt_changed=true
                fi
            done

            if [[ "$opt_changed" == "true" ]]; then
                opt_list="${opt_list#,}"
                opt_list="${opt_list%,}"
                line="${prefix}${opt_list}${suffix}"
                modified=true
            fi
        fi
        out+=("$line")
    done < "$f"

    if [[ "$modified" == "true" ]]; then
        printf '%s\n' "${out[@]}" > "$f"
        return 0
    fi
    return 1
}

# Idempotent GRUB Configuration Variable Helper
set_grub_var() {
    local key="$1"
    local val="$2"
    local file="${3:-/etc/default/grub}"
    [[ ! -f "$file" ]] && return 1

    local new_entry="${key}=${val}"
    # Check if exact uncommented entry already exists
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        local current_line
        current_line=$(grep -E "^[[:space:]]*${key}=" "$file" | head -n 1)
        if [[ "$current_line" == "$new_entry" ]]; then
            return 0
        fi
    fi

    local escaped_entry="${new_entry//\\/\\\\}"
    escaped_entry="${escaped_entry//&/\\&}"

    if grep -qE "^#?[[:space:]]*${key}=" "$file"; then
        sed -i -E "s|^#?[[:space:]]*${key}=.*|${escaped_entry}|" "$file"
    else
        echo "$new_entry" >> "$file"
    fi
    GRUB_CONFIG_CHANGED=true
    PENDING_GRUB_REBUILD=true
}

# Hardened PAM Fingerprint Configuration
configure_pam_fingerprint() {
    local target="$1"
    [[ ! -f "$target" ]] && return 0

    # Create safety backup before editing
    if [[ ! -f "$target.pre-fprintd" ]]; then
        cp -a "$target" "$target.pre-fprintd" 2>/dev/null || true
    fi

    # If already configured, keep idempotent
    if grep -qE '^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_fprintd\.so' "$target"; then
        return 0
    fi

    # Insert 'auth sufficient pam_fprintd.so' right before the first 'auth' rule
    if grep -q "^auth" "$target"; then
        sed -i '0,/^auth/{s/^auth/auth       sufficient   pam_fprintd.so\nauth/}' "$target"
    else
        sed -i '1a auth       sufficient   pam_fprintd.so' "$target"
    fi

    # Safety check: ensure at least one additional fallback auth rule remains
    local auth_count
    auth_count=$(grep -cE '^[[:space:]]*auth' "$target" || true)
    if (( auth_count < 2 )); then
        log_error "Refused to modify $target: no fallback password auth rule detected. Reverting."
        if [[ -f "$target.pre-fprintd" ]]; then
            cp -a "$target.pre-fprintd" "$target"
        fi
        return 1
    fi
}

# Shared Comment-Tolerant JSONC Parser & Atomic Writer (Preserves URLs inside strings)
_JSONC_PY_HELPERS='
import json, os, sys, re, tempfile, shutil

def strip_jsonc_comments(text):
    pattern = r"(\"(?:\\.|[^\"\\])*\")|//[^\n]*|/\*[\s\S]*?\*/"
    stripped = re.sub(pattern, lambda m: m.group(1) if m.group(1) is not None else "", text)
    return re.sub(r",\s*([}\]])", r"\1", stripped)

def load_jsonc(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        return json.loads(strip_jsonc_comments(content))
    except Exception as e:
        print(f"WARN: Could not parse {path} ({e}). Preserving file.", file=sys.stderr)
        return None

def atomic_save_json(path, data, indent=2):
    dir_name = os.path.dirname(path)
    if dir_name and not os.path.exists(dir_name):
        os.makedirs(dir_name, exist_ok=True)
    if os.path.exists(path):
        try:
            shutil.copy2(path, path + ".bak")
        except Exception:
            pass
    fd, tmp_path = tempfile.mkstemp(dir=dir_name if dir_name else None, prefix=".tmp_json_")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent)
    os.replace(tmp_path, path)
'

# Timeshift Kernel Discovery & Safeguards
BROKEN_KERNELS=("7.1")
declare -ga UNLOCKED_SNAPSHOTS=()

discover_host_kernels() {
    local boot_dir="${1:-/boot}"
    local k_list=()
    local img
    for img in "$boot_dir"/vmlinuz-*-x86_64; do
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

# Safely purge broken kernels from a snapshot or chroot root ONLY if another valid kernel exists
purge_broken_kernels_from_root() {
    local target_root="$1"
    [[ -z "$target_root" || ! -d "$target_root/boot" ]] && return 0

    local bk
    for bk in "${BROKEN_KERNELS[@]}"; do
        if [[ -f "$target_root/boot/vmlinuz-${bk}-x86_64" ]]; then
            local other_kernels
            other_kernels=$(find "$target_root/boot" -maxdepth 1 -name "vmlinuz-*-x86_64" ! -name "vmlinuz-${bk}-x86_64" 2>/dev/null || true)
            if [[ -n "$other_kernels" ]]; then
                log_info "Purging obsolete broken kernel ${bk} from ${target_root}..."
                rm -f "$target_root/boot/vmlinuz-${bk}-x86_64"*
                rm -f "$target_root/boot/initramfs-${bk}-x86_64"*
                rm -f "$target_root/boot/linux${bk//./}-x86_64.kver"*
                rm -rf "$target_root/usr/lib/modules/${bk}".* "$target_root/usr/lib/modules/${bk}-"* 2>/dev/null || true
            else
                log_warn "Kernel ${bk} is the only kernel in ${target_root} and no fallback could be injected. Retaining to preserve bootability."
                return 1
            fi
        fi
    done
    return 0
}

track_unlocked_snapshot() {
    local snap_path="$1"
    [[ -z "$snap_path" ]] && return 0
    local u
    for u in "${UNLOCKED_SNAPSHOTS[@]:-}"; do
        [[ "$u" == "$snap_path" ]] && return 0
    done
    UNLOCKED_SNAPSHOTS+=("$snap_path")
}

untrack_unlocked_snapshot() {
    local snap_path="$1"
    local remaining=()
    local u
    for u in "${UNLOCKED_SNAPSHOTS[@]:-}"; do
        [[ -n "$u" && "$u" != "$snap_path" ]] && remaining+=("$u")
    done
    UNLOCKED_SNAPSHOTS=("${remaining[@]:-}")
}
