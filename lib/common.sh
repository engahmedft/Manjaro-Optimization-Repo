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
log_error() { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[0;31m[ERROR]\033[0m %b\n' -1 "$1"; }

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
is_sensitive_partition() {
    local label="${1:-}"
    local partlabel="${2:-}"
    local parttype="${3:-}"

    if [[ "$parttype" =~ ^(de94bba4-06d1-4d40-a16a-bfd50179d6ac|ebd0a0a2-b9e5-4433-87c0-68b6b72699c7)$ ]]; then
        return 0
    fi

    local sensitive_pattern='(^|[[:punct:][:space:]_])(Recovery|WINRE|WINRE_DRV|DellSupport|SupportAssist|OS_RESTORE|Restore|Backup|DIAGNOSTICS|ESP|System[[:space:]]+Reserved|Image)($|[[:punct:][:space:]_])'
    if [[ "$label" =~ $sensitive_pattern || "$partlabel" =~ $sensitive_pattern ]]; then
        return 0
    fi
    return 1
}

# Safe Mount Directory Cleaner
purge_mount_dir() {
    local target="$1"
    [[ -z "$target" || "$target" == "/" ]] && return 0

    local norm_target
    norm_target=$(realpath -m "$target" 2>/dev/null || echo "$target")

    case "$norm_target" in
        ""|"/"|"/boot"*|"/efi"*|"/etc"*|"/home"*|"/root"*|"/usr"*|"/var"*|"/dev"*|"/proc"*|"/sys"*)
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
