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
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error(){ echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${BOLD}========================================================================${NC}"
echo -e "${BOLD}     GOODIX FINGERPRINT SENSOR (27c6:538d) DRIVER INSTALLER            ${NC}"
echo -e "${BOLD}========================================================================${NC}"

# 1. Verify USB device presence
log_info "Detecting Goodix fingerprint sensor..."
if ! lsusb | grep -qi "27c6:538d"; then
    log_warn "Goodix 27c6:538d sensor not detected on USB bus."
    read -rp "Do you wish to force driver installation anyway? (y/N): " f_choice
    [[ ! "$f_choice" =~ ^[Yy]$ ]] && exit 0
else
    log_ok "Goodix 27c6:538d fingerprint sensor detected on USB bus!"
fi

# Ensure fprintd is installed
if ! pacman -Qq fprintd &>/dev/null; then
    log_info "Installing fprintd daemon..."
    pacman -S --needed --noconfirm fprintd
fi

INSTALLED=false

# Ensure stock conflicting libfprint is cleanly replaced without breaking fprintd
clean_stock_conflict() {
    if pacman -Qq libfprint &>/dev/null && ! pacman -Qq libfprint-goodix-538d &>/dev/null; then
        log_info "Safely detaching conflicting stock libfprint (preserving fprintd)..."
        pacman -Rdd --noconfirm libfprint 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# TIER 1: Install from precompiled local package cache (.pkg.tar.zst)
# ------------------------------------------------------------------------------
log_info "Checking for precompiled package cache in $SCRIPT_DIR..."
CACHED_PKG=$(ls -t "$SCRIPT_DIR"/libfprint-goodix-*.pkg.tar.zst 2>/dev/null | head -n 1 || true)

if [[ -n "$CACHED_PKG" && -f "$CACHED_PKG" ]]; then
    log_info "Found cached package: $(basename "$CACHED_PKG")"
    clean_stock_conflict
    log_info "Installing via pacman -U..."
    if pacman -U --noconfirm "$CACHED_PKG"; then
        log_ok "Precompiled driver package installed successfully!"
        INSTALLED=true
    else
        log_warn "Failed to install cached package. Proceeding to Tier 2 fallback..."
    fi
fi

# ------------------------------------------------------------------------------
# TIER 2: Build package from PKGBUILD via makepkg
# ------------------------------------------------------------------------------
if [[ "$INSTALLED" == "false" && -f "$SCRIPT_DIR/PKGBUILD" ]]; then
    log_info "Tier 2: Building package from local PKGBUILD using makepkg..."
    pacman -S --needed --noconfirm git meson ninja cmake pkg-config libgudev libgusb nss pixman openssl
    
    # Run makepkg as the regular user
    if sudo -u "$REAL_USER" bash -c "cd '$SCRIPT_DIR' && makepkg -f --nodeps"; then
        NEW_PKG=$(ls -t "$SCRIPT_DIR"/libfprint-goodix-*.pkg.tar.zst 2>/dev/null | head -n 1 || true)
        if [[ -n "$NEW_PKG" && -f "$NEW_PKG" ]]; then
            clean_stock_conflict
            if pacman -U --noconfirm "$NEW_PKG"; then
                log_ok "Built and installed package: $(basename "$NEW_PKG")"
                INSTALLED=true
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# TIER 3: Direct source build & library replacement fallback
# ------------------------------------------------------------------------------
if [[ "$INSTALLED" == "false" ]]; then
    log_warn "Tier 3: Falling back to direct source build & library installation..."
    TMP_BUILD="/tmp/libfprint-goodix-direct"
    rm -rf "$TMP_BUILD"
    mkdir -p "$TMP_BUILD"
    
    if git clone --depth 1 -b goodix-538d-sigfm-gtls https://github.com/lbssousa/libfprint.git "$TMP_BUILD"; then
        cd "$TMP_BUILD"
        # Accept any valid 32-byte hardware PSK from 538d sensor
        sed -i '/if (memcmp(psk, goodix_53xd_psk_0/,+5d' libfprint/drivers/goodixtls/goodix53xd.c
        # Fix meson dict iteration in test suite
        sed -i 's/foreach driver_test: drivers_tests/foreach driver_name, driver_test: drivers_tests/' tests/meson.build
        sed -i 's/test(driver_test,/test(driver_name,/' tests/meson.build
        
        # Build using system or local meson/ninja
        export PATH="/tmp/bin-tools:/tmp:$PATH"
        arch-meson . build -Ddoc=false -Dintrospection=false -Dc_args="-Wno-incompatible-pointer-types -Wno-error" || \
            meson setup build -Ddoc=false -Dintrospection=false -Dc_args="-Wno-incompatible-pointer-types -Wno-error"
        ninja -C build
        
        # Install library and udev rules
        cp -a build/libfprint/libfprint-2.so* /usr/lib/
        if [[ -f build/libfprint/70-libfprint-2.rules ]]; then
            cp build/libfprint/70-libfprint-2.rules /etc/udev/rules.d/70-libfprint-2.rules
            udevadm control --reload-rules && udevadm trigger
        elif [[ -f build/libfprint/udev-rules ]]; then
            cp build/libfprint/udev-rules /etc/udev/rules.d/60-libfprint-2-autosuspend.rules
            udevadm control --reload-rules && udevadm trigger
        fi
        log_ok "Direct library override installed to /usr/lib/libfprint-2.so."
        INSTALLED=true
    else
        log_error "Direct build failed to fetch git repository."
        exit 1
    fi
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
# PAM & SERVICE RESTART
# ------------------------------------------------------------------------------
log_info "Configuring PAM authentication for fingerprint support..."
for pam_file in /etc/pam.d/sudo /etc/pam.d/polkit-1; do
    if [[ -f "$pam_file" ]] && ! grep -q "pam_fprintd.so" "$pam_file"; then
        sed -i '1s/^/auth sufficient pam_fprintd.so\n/' "$pam_file"
        log_ok "Added pam_fprintd to $pam_file."
    fi
done

log_info "Restarting fprintd daemon service..."
systemctl daemon-reload
systemctl restart fprintd.service 2>/dev/null || true

# ------------------------------------------------------------------------------
# INTERACTIVE ENROLLMENT
# ------------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}Fingerprint driver setup completed successfully!${NC}"
read -rp "Would you like to enroll your fingerprint now? (y/N): " enroll_ans
if [[ "$enroll_ans" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Place and press your finger flat against the sensor when prompted...${NC}"
    sudo -u "$REAL_USER" fprintd-enroll || log_warn "Enrollment interrupted or deferred. You can run 'fprintd-enroll' anytime."
else
    log_info "You can enroll your fingerprint anytime by running: fprintd-enroll"
fi
