#!/usr/bin/env bash
# ==============================================================================
# Goodix 27c6:538d Fingerprint Driver Installer for Dell Inspiron 7706
# Strategy: Precompiled package -> Makepkg/AUR -> Direct library fallback
# ==============================================================================

set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m Please run with sudo: sudo ./install-goodix-driver.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared common library if available
if [[ -f "${SCRIPT_DIR}/../../lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/../../lib/common.sh"
elif [[ -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
    source "${SCRIPT_DIR}/lib/common.sh"
elif [[ -f "/usr/local/lib/manjaro-opt/common.sh" ]]; then
    source "/usr/local/lib/manjaro-opt/common.sh"
fi

echo -e "${BOLD}========================================================================${NC}"
echo -e "${BOLD}     GOODIX FINGERPRINT SENSOR (27c6:538d) DRIVER INSTALLER            ${NC}"
echo -e "${BOLD}========================================================================${NC}"

# 1. Verify USB device presence
log_info "Detecting Goodix fingerprint sensor..."
if ! lsusb | grep -qi "27c6:538d"; then
    log_warn "Goodix 27c6:538d sensor not detected on USB bus."
    ask f_choice "Do you wish to force driver installation anyway? (y/N): "
    [[ ! "$f_choice" =~ ^[Yy]$ ]] && exit 0
else
    log_ok "Goodix 27c6:538d fingerprint sensor detected on USB bus!"
fi

# Ensure fprintd is installed and stopped before touching USB device or libraries
if ! pacman -Qq fprintd &>/dev/null; then
    log_info "Installing fprintd daemon..."
    pacman -S --needed --noconfirm fprintd
fi
systemctl stop fprintd.service 2>/dev/null || true

INSTALLED=false

# Check if driver package is already installed (skip rebuild unless explicitly requested)
if pacman -Qq libfprint-goodix-538d &>/dev/null && [[ "${1:-}" != "--reinstall" && "${1:-}" != "--force" ]]; then
    log_ok "Goodix 27c6:538d driver (libfprint-goodix-538d) is already installed. Skipping package build."
    INSTALLED=true
fi

# Ensure stock conflicting libfprint is cleanly replaced without breaking fprintd
clean_stock_conflict() {
    if pacman -Qq libfprint &>/dev/null && ! pacman -Qq libfprint-goodix-538d &>/dev/null; then
        log_info "Safely detaching conflicting stock libfprint (preserving fprintd)..."
        pacman -Rdd --noconfirm libfprint 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# STEP 1: Always try existing precompiled package cache (.pkg.tar.zst) FIRST
# ------------------------------------------------------------------------------
if [[ "$INSTALLED" == "false" ]]; then
    log_info "Checking for existing driver package cache in $SCRIPT_DIR..."
    CACHED_PKG=$(ls -t "$SCRIPT_DIR"/libfprint-goodix-*.pkg.tar.zst "$SCRIPT_DIR"/*.pkg.tar.zst 2>/dev/null | head -n 1 || true)

    if [[ -n "$CACHED_PKG" && -f "$CACHED_PKG" ]]; then
        log_info "Found existing driver package: $(basename "$CACHED_PKG")"
        if [[ -f "$SCRIPT_DIR/SHA256SUMS" ]]; then
            expected_hash=$(grep "$(basename "$CACHED_PKG")" "$SCRIPT_DIR/SHA256SUMS" 2>/dev/null | awk '{print $1}')
            actual_hash=$(sha256sum "$CACHED_PKG" | awk '{print $1}')
            if [[ -n "$expected_hash" && "$expected_hash" != "$actual_hash" ]]; then
                log_warn "Checksum difference detected on $(basename "$CACHED_PKG")!"
                log_warn "  Expected (from SHA256SUMS): $expected_hash"
                log_warn "  Calculated (actual file):   $actual_hash"
                if [[ -t 0 ]]; then
                    echo -e " What would you like to do?"
                    echo -e "  1) (Recommended / Secure) Clean build from source via PKGBUILD"
                    echo -e "  2) Install existing package anyway (Use only if you intentionally modified/replaced it)"
                    echo -e "  3) Cancel driver installation"
                    ask hash_choice "Select an option (1-3) [1]: "
                    hash_choice="${hash_choice:-1}"
                    case "$hash_choice" in
                        2)
                            log_info "User override: proceeding to install existing package despite checksum difference..."
                            ;;
                        3)
                            log_info "Driver installation cancelled by user."
                            exit 0
                            ;;
                        *)
                            log_info "Secure choice selected: proceeding to compile fresh from source via makepkg..."
                            CACHED_PKG=""
                            ;;
                    esac
                else
                    log_warn "Non-interactive shell: Checksum difference detected. Attempting secure build from source..."
                    CACHED_PKG=""
                fi
            elif [[ -z "$expected_hash" ]]; then
                log_info "Package $(basename "$CACHED_PKG") not listed in SHA256SUMS (custom or newer package). Trying first..."
            else
                log_ok "Cryptographic SHA-256 integrity verified for $(basename "$CACHED_PKG")."
            fi
        fi

        if [[ -n "$CACHED_PKG" ]]; then
            clean_stock_conflict
            log_info "Installing via pacman -U (with --overwrite to prevent file collisions)..."
            if pacman -U --overwrite '*' --noconfirm "$CACHED_PKG"; then
                log_ok "Driver package installed successfully from package cache!"
                INSTALLED=true
            else
                log_warn "Installation of $(basename "$CACHED_PKG") encountered an error. Proceeding to Step 2 build fallback..."
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# STEP 2: Build package from PKGBUILD via makepkg (only if Step 1 unavailable or failed)
# ------------------------------------------------------------------------------
if [[ "$INSTALLED" == "false" && -f "$SCRIPT_DIR/PKGBUILD" ]]; then
    log_info "Step 2: Building package from local PKGBUILD using makepkg..."
    pacman -S --needed --noconfirm git meson ninja cmake pkg-config libgudev libgusb nss pixman openssl
    
    # Run makepkg as the regular user and clean up intermediate build directories
    if sudo -u "$REAL_USER" bash -c "cd '$SCRIPT_DIR' && makepkg -fc --nodeps && rm -rf src pkg libfprint"; then
        NEW_PKG=$(ls -t "$SCRIPT_DIR"/libfprint-goodix-*.pkg.tar.zst "$SCRIPT_DIR"/*.pkg.tar.zst 2>/dev/null | head -n 1 || true)
        if [[ -n "$NEW_PKG" && -f "$NEW_PKG" ]]; then
            clean_stock_conflict
            if pacman -U --overwrite '*' --noconfirm "$NEW_PKG"; then
                log_ok "Built and installed package: $(basename "$NEW_PKG")"
                INSTALLED=true
            fi
        fi
    else
        log_warn "Makepkg build failed or encountered an incompatible package during build."
    fi
fi

# ------------------------------------------------------------------------------
# STEP 3: Fallback recovery — if build failed, give full chance to install existing package
# ------------------------------------------------------------------------------
if [[ "$INSTALLED" == "false" ]]; then
    FALLBACK_PKG=$(ls -t "$SCRIPT_DIR"/libfprint-goodix-*.pkg.tar.zst "$SCRIPT_DIR"/*.pkg.tar.zst 2>/dev/null | head -n 1 || true)
    if [[ -n "$FALLBACK_PKG" && -f "$FALLBACK_PKG" ]]; then
        log_warn "Makepkg build failed or encountered incompatibility."
        log_warn "An existing precompiled driver package is available: $(basename "$FALLBACK_PKG")"
        RECOVER=true
        if [[ -t 0 ]]; then
            ask rec_ans "Recover by installing the existing precompiled driver package? (Y/n): "
            [[ "$rec_ans" =~ ^[Nn]$ ]] && RECOVER=false
        fi
        if [[ "$RECOVER" == "true" ]]; then
            log_info "Installing fallback driver package: $(basename "$FALLBACK_PKG")..."
            clean_stock_conflict
            if pacman -U --overwrite '*' --noconfirm "$FALLBACK_PKG"; then
                log_ok "Successfully recovered and installed driver from existing package: $(basename "$FALLBACK_PKG")!"
                INSTALLED=true
            else
                log_error "Failed to install fallback package $(basename "$FALLBACK_PKG")."
            fi
        else
            log_info "Fallback recovery declined by user."
        fi
    fi
fi

if [[ "$INSTALLED" == "false" ]]; then
    log_error "Failed to install Goodix driver package. Please ensure build dependencies or package cache are present."
    exit 1
fi

# ------------------------------------------------------------------------------
# PINNING: Add IgnorePkg = libfprint to /etc/pacman.conf to prevent overwrite
# ------------------------------------------------------------------------------
log_info "Pinning libfprint in /etc/pacman.conf to protect against system updates..."
if grep -q "^IgnorePkg" /etc/pacman.conf; then
    if ! grep -E "^IgnorePkg.*libfprint" /etc/pacman.conf; then
        sed -i '/^IgnorePkg/ s/$/ libfprint libfprint-goodix-521d libfprint-goodix-538d/' /etc/pacman.conf
    fi
else
    sed -i '/\[options\]/a IgnorePkg = libfprint libfprint-goodix-521d libfprint-goodix-538d' /etc/pacman.conf
fi
log_ok "libfprint pinned in /etc/pacman.conf."

# ------------------------------------------------------------------------------
# TLS-PSK & FIRMWARE PROVISIONING (IAP Bootloader Provisioner)
# ------------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/provision-goodix-538d.py" && -f "$SCRIPT_DIR/GF5298_GM168SEC_APP_13016.bin" ]]; then
    # Verify cryptographic integrity of firmware binary
    if [[ -f "$SCRIPT_DIR/SHA256SUMS" ]]; then
        expected_fw_hash=$(grep "GF5298_GM168SEC_APP_13016.bin" "$SCRIPT_DIR/SHA256SUMS" | awk '{print $1}')
        actual_fw_hash=$(sha256sum "$SCRIPT_DIR/GF5298_GM168SEC_APP_13016.bin" | awk '{print $1}')
        if [[ "$expected_fw_hash" != "$actual_fw_hash" ]]; then
            log_error "Cryptographic checksum mismatch on firmware binary! Aborting."
            exit 1
        fi
        log_ok "Cryptographic SHA-256 integrity verified for GF5298_GM168SEC_APP_13016.bin."
    fi

    log_info "Installing Goodix 27c6:538d TLS-PSK provisioner to /usr/lib/goodix-538d/..."
    install -Dm755 "$SCRIPT_DIR/provision-goodix-538d.py" /usr/lib/goodix-538d/provision-goodix-538d.py
    install -Dm644 "$SCRIPT_DIR/GF5298_GM168SEC_APP_13016.bin" /usr/lib/goodix-538d/GF5298_GM168SEC_APP_13016.bin

    cat > /etc/systemd/system/goodix-538d-provision.service <<'EOF'
[Unit]
Description=Goodix 27c6:538d Fingerprint Sensor TLS-PSK Provisioner Check
Before=fprintd.service
PartOf=fprintd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 /usr/lib/goodix-538d/provision-goodix-538d.py --check
EOF

    mkdir -p /etc/systemd/system/fprintd.service.d
    cat > /etc/systemd/system/fprintd.service.d/goodix-538d-provision.conf <<'EOF'
[Unit]
Wants=goodix-538d-provision.service
After=goodix-538d-provision.service
EOF

    log_info "Provisioning Goodix 27c6:538d sensor TLS-PSK & verifying firmware..."
    systemctl stop fprintd.service 2>/dev/null || true
    if python3 /usr/lib/goodix-538d/provision-goodix-538d.py --flash; then
        log_ok "Sensor TLS-PSK and firmware verified!"
    else
        log_error "Sensor TLS-PSK provisioning failed."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# PAM & SERVICE RESTART
# ------------------------------------------------------------------------------
log_info "Configuring PAM authentication for fingerprint support (fingerprint first & sufficient)..."
if [[ ! -f /etc/pam.d/polkit-1 && -f /usr/lib/pam.d/polkit-1 ]]; then
    cp -a /usr/lib/pam.d/polkit-1 /etc/pam.d/polkit-1
fi
for pam_file in /etc/pam.d/sudo /etc/pam.d/polkit-1 /etc/pam.d/system-local-login; do
    if [[ -f "$pam_file" ]]; then
        configure_pam_fingerprint "$pam_file"
        log_ok "Configured fingerprint-first authentication in $pam_file."
    fi
done

log_info "Restarting fprintd daemon service..."
udevadm control --reload-rules && udevadm trigger --subsystem-match=usb --action=change 2>/dev/null || true
systemctl daemon-reload
systemctl restart fprintd.service 2>/dev/null || true

# ------------------------------------------------------------------------------
# INTERACTIVE ENROLLMENT
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}Fingerprint driver setup completed successfully!${NC}"
enrolled_list=$(sudo -u "$REAL_USER" fprintd-list "$REAL_USER" 2>/dev/null | grep -E "^ - #[0-9]+:" || true)
if [[ -n "$enrolled_list" ]]; then
    log_ok "Currently enrolled fingerprint(s) for $REAL_USER:"
    echo "$enrolled_list"
fi
ask enroll_ans "Would you like to enroll your fingerprint now? (y/N): "
if [[ "$enroll_ans" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Place and press your finger flat against the sensor when prompted...${NC}"
    sudo -u "$REAL_USER" fprintd-enroll || log_warn "Enrollment interrupted or deferred. You can run 'fprintd-enroll' anytime."
else
    log_info "You can enroll your fingerprint anytime by running: fprintd-enroll"
fi
