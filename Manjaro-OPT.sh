#!/usr/bin/env bash
# ==============================================================================
# Manjaro Modular Optimizer, System Maintainer & Software Hub (v9 - Polished)
# Target: Dell Inspiron 7706 | GNOME Wayland | Podman Engine | Fast aria2c
# ==============================================================================

export TERM="${TERM:-xterm-256color}"

# ------------------------------------------------------------------------------
# 0. ROOT CHECK, USER ENVIRONMENT & LOCAL LOGGING
# ------------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m Please run this script with sudo: sudo ./Manjaro-OPT.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
USER_UID=$(id -u "$REAL_USER")

run_as_user() {
    if [[ "$EUID" -eq 0 ]] && [[ -n "$REAL_USER" ]] && [[ "$REAL_USER" != "root" ]]; then
        sudo -u "$REAL_USER" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
            XDG_RUNTIME_DIR="/run/user/$USER_UID" \
            DISPLAY="${DISPLAY:-:0}" \
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
            "$@"
    else
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
        XDG_RUNTIME_DIR="/run/user/$USER_UID" \
        "$@"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/manjaro_maintain.log"

touch "$LOG_FILE" 2>/dev/null || true
if [[ -n "$SUDO_USER" ]]; then
    chown "$SUDO_USER:" "$LOG_FILE" 2>/dev/null || true
fi

exec > >(tee -a "$LOG_FILE") 2>&1

POLKIT_RULE="/etc/polkit-1/rules.d/49-temp-manjaro-maintain.rules"
cat << 'EOF' > "$POLKIT_RULE"
polkit.addRule(function(action, subject) {
    if ((action.id.indexOf("org.manjaro.pamac") === 0 || 
         action.id.indexOf("org.freedesktop.packagekit") === 0) &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF

cleanup() {
    rm -f "$POLKIT_RULE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
log_info()    { echo -e "[$(timestamp)] ${BLUE}[INFO]${NC} $1"; }
log_ok()      { echo -e "[$(timestamp)] ${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "[$(timestamp)] ${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "[$(timestamp)] ${RED}[ERROR]${NC} $1"; }

is_pkg_installed() { pacman -Qq "$1" &> /dev/null; }
is_bin_installed() { 
    command -v "$1" &> /dev/null || \
    [[ -x "$USER_HOME/.local/bin/$1" ]] || \
    sudo -u "$REAL_USER" command -v "$1" &> /dev/null
}

init_downloads() {
    if ! command -v aria2c &> /dev/null; then
        pacman -S --needed --noconfirm aria2 > /dev/null 2>&1 || true
    fi

    if [[ -f /etc/makepkg.conf ]]; then
        sed -i "s|'https::/usr/bin/curl.*'|'https::/usr/bin/aria2c -c -m2 -s4 -x4 -k1M --file-allocation=none -o %o %u'|" /etc/makepkg.conf
        sed -i "s|'http::/usr/bin/curl.*'|'http::/usr/bin/aria2c -c -m2 -s4 -x4 -k1M --file-allocation=none -o %o %u'|" /etc/makepkg.conf
    fi

    if [[ -f "$USER_HOME/.makepkg.conf" ]]; then
        sed -i "s|'https::/usr/bin/curl.*'|'https::/usr/bin/aria2c -c -m2 -s4 -x4 -k1M --file-allocation=none -o %o %u'|" "$USER_HOME/.makepkg.conf"
        sed -i "s|'http::/usr/bin/curl.*'|'http::/usr/bin/aria2c -c -m2 -s4 -x4 -k1M --file-allocation=none -o %o %u'|" "$USER_HOME/.makepkg.conf"
    fi

    sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 4/' /etc/pacman.conf 2>/dev/null || true
}
init_downloads

safe_pacman_remove() {
    local to_remove=()
    for pkg in "$@"; do
        if is_pkg_installed "$pkg"; then
            to_remove+=("$pkg")
        fi
    done
    if [[ ${#to_remove[@]} -gt 0 ]]; then
        log_info "Removing installed packages: ${to_remove[*]}"
        pacman -Rns --noconfirm "${to_remove[@]}"
    fi
}

post_install_hook() {
    log_info "Running post-install setup (syncing PATH across shells)..."
    for rc in "$USER_HOME/.zshrc" "$USER_HOME/.bashrc"; do
        if [[ -f "$rc" ]] && ! grep -q '\.local/bin' "$rc"; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
            chown "$REAL_USER:" "$rc"
        fi
    done
    log_ok "PATH synced."
}

post_uninstall_hook() {
    log_info "Running single-pass post-uninstall deep cleanup..."
    flatpak uninstall --unused -y > /dev/null 2>&1 || true
    rm -rf "$USER_HOME/.var/app" 2>/dev/null || true
    ORPHANS=$(pacman -Qtdq 2>/dev/null || true)
    [[ -n "$ORPHANS" ]] && pacman -Rns --noconfirm $ORPHANS > /dev/null 2>&1 || true
    log_info "Executing single SSD TRIM pass to reclaim storage..."
    fstrim -va > /dev/null 2>&1 || true
    log_ok "Residual caches purged and SSD blocks trimmed."
}

get_desktop_icons_status() {
    local enabled_exts
    enabled_exts=$(run_as_user gnome-extensions list --enabled 2>/dev/null)
    if echo "$enabled_exts" | grep -qE "^(gtk4-ding@smedius\.gitlab\.com|ding@rastersoft\.com)$"; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

get_hot_corner_status() {
    local status
    status=$(run_as_user gsettings get org.gnome.desktop.interface enable-hot-corners 2>/dev/null)
    if [[ "$status" == "true" ]]; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

configure_desktop_icons() {
    local action="$1" # enable or disable
    if [[ "$action" == "enable" ]]; then
        log_info "Configuring Desktop Icons (ensuring extension is installed & enabled)..."
        if ! is_pkg_installed "gnome-shell-extension-gtk4-desktop-icons-ng" && ! is_pkg_installed "gnome-shell-extension-desktop-icons-ng"; then
            pacman -S --needed --noconfirm gnome-shell-extension-gtk4-desktop-icons-ng > /dev/null 2>&1 || \
            pacman -S --needed --noconfirm gnome-shell-extension-desktop-icons-ng > /dev/null 2>&1 || true
        fi

        run_as_user gsettings set org.gnome.shell disable-user-extensions false 2>/dev/null || true

        local found=false
        for ext in "gtk4-ding@smedius.gitlab.com" "ding@rastersoft.com"; do
            if run_as_user gnome-extensions list 2>/dev/null | grep -q "^${ext}$"; then
                run_as_user gnome-extensions enable "$ext" 2>/dev/null || true
                found=true
                log_ok "Desktop Icons extension ($ext) enabled."
            fi
        done
        if [[ "$found" != "true" ]]; then
            log_warn "Could not locate a supported Desktop Icons extension (gtk4-ding or ding)."
        fi
    else
        log_info "Disabling Desktop Icons extension..."
        for ext in "gtk4-ding@smedius.gitlab.com" "ding@rastersoft.com"; do
            if run_as_user gnome-extensions list 2>/dev/null | grep -q "^${ext}$"; then
                run_as_user gnome-extensions disable "$ext" 2>/dev/null || true
                log_ok "Desktop Icons extension ($ext) disabled."
            fi
        done
    fi
}

configure_hot_corner() {
    local action="$1" # enable or disable
    if [[ "$action" == "disable" ]]; then
        log_info "Disabling Top-Left Hot Corner..."
        run_as_user gsettings set org.gnome.desktop.interface enable-hot-corners false 2>/dev/null || true
        log_ok "Top-Left Hot Corner disabled."
    else
        log_info "Enabling Top-Left Hot Corner..."
        run_as_user gsettings set org.gnome.desktop.interface enable-hot-corners true 2>/dev/null || true
        log_ok "Top-Left Hot Corner enabled."
    fi
}

# ------------------------------------------------------------------------------
# 1. SYSTEM OPTIMIZATION ROUTINE
# ------------------------------------------------------------------------------
optimize_system() {
    echo ""
    log_info "=== STARTING FULL SYSTEM OPTIMIZATION ==="

    log_info "1/11: Checking Timeshift & creating system restore point..."
    if ! is_pkg_installed timeshift; then
        pacman -S --needed --noconfirm timeshift > /dev/null 2>&1 || true
    fi
    timeshift --create --comments "Before System Optimization" --tags O > /dev/null 2>&1 || {
        log_warn "Timeshift snapshot skipped (run Timeshift GUI once to configure disk if needed)."
    }

    log_info "2/11: Ensuring download accelerator and pacman formatting..."
    init_downloads
    sed -i 's/^#*Color/Color/' /etc/pacman.conf
    if ! grep -q "ILoveCandy" /etc/pacman.conf; then
        sed -i '/# Misc options/a ILoveCandy' /etc/pacman.conf 2>/dev/null || true
    fi

    log_info "3/11: Refreshing fastest mirrors & upgrading system..."
    pacman-mirrors --fasttrack 5
    pacman -Syu --noconfirm

    log_info "4/11: Enforcing en_US locale and formatting..."
    if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
        sed -i 's/^#*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        locale-gen > /dev/null 2>&1 || true
    fi
    localectl set-locale LANG=en_US.UTF-8 LC_TIME=en_US.UTF-8 LC_NUMERIC=en_US.UTF-8 LC_MONETARY=en_US.UTF-8 LC_MEASUREMENT=en_US.UTF-8 > /dev/null 2>&1 || true
    localectl set-keymap us > /dev/null 2>&1 || true
    run_as_user gsettings set org.gnome.system.locale region 'en_US.UTF-8' 2>/dev/null || true

    log_info "5/11: Configuring dual-boot GRUB (7s timer for Windows) & LocalRTC..."
    pacman -S --needed --noconfirm os-prober > /dev/null 2>&1 || true
    if grep -q "^#*GRUB_DISABLE_OS_PROBER=true" /etc/default/grub || ! grep -q "GRUB_DISABLE_OS_PROBER=false" /etc/default/grub; then
        sed -i '/GRUB_DISABLE_OS_PROBER/d' /etc/default/grub
        echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=7/' /etc/default/grub
        update-grub > /dev/null 2>&1 || true
    fi
    if [[ $(timedatectl show --property=LocalRTC --value) != "yes" ]]; then
        timedatectl set-local-rtc 1 --adjust-system-clock
    fi

    log_info "6/12: Applying Btrfs NVMe 'noatime' mount optimization..."
    if grep -E "btrfs.*compress=zstd" /etc/fstab | grep -qv "noatime"; then
        sed -i 's/defaults,compress=zstd/defaults,noatime,compress=zstd/g' /etc/fstab
        mount -o remount / 2>/dev/null || true
        mount -o remount /home 2>/dev/null || true
        mount -o remount /var/cache 2>/dev/null || true
        mount -o remount /var/log 2>/dev/null || true
        log_ok "Btrfs subvolumes remounted with noatime."
    fi

    log_info "7/12: Configuring permanent partition mounts (fstab auto-mount, release user sessions, UI labels)..."
    configure_permanent_partitions

    log_info "8/12: Setting up ZRAM (RAM-compressed swap)..."
    pacman -S --needed --noconfirm zram-generator > /dev/null 2>&1 || true
    if [[ ! -f /etc/systemd/zram-generator.conf ]]; then
        cat << 'EOF' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
    fi
    modprobe zram 2>/dev/null || true
    systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true

    log_info "9/12: Tuning kernel sysctl parameters for 32GB RAM & TCP BBR..."
    cat << 'EOF' > /etc/sysctl.d/99-dell-perf.conf
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system > /dev/null 2>&1 || true

    log_info "10/12: Enabling Intel GuC/HuC microcontrollers & thermald..."
    cat << 'EOF' > /etc/modprobe.d/i915.conf
options i915 enable_guc=3
EOF
    sed -i 's/^#*RuntimeWatchdogSec=.*/RuntimeWatchdogSec=off/' /etc/systemd/system.conf 2>/dev/null || true

    pacman -S --needed --noconfirm intel-media-driver libva-utils thermald pacman-contrib git base-devel > /dev/null 2>&1 || true
    systemctl enable --now thermald.service > /dev/null 2>&1 || true
    systemctl enable --now fstrim.timer > /dev/null 2>&1 || true
    systemctl enable --now paccache.timer > /dev/null 2>&1 || true

    log_info "11/12: Enabling Desktop Icons & Disabling Top-Left Hot Corner..."
    configure_desktop_icons enable
    configure_hot_corner disable

    log_info "12/12: Performing Deep System Clutter Cleanup..."
    rm -rf /var/tmp/pamac-build-* /var/tmp/pamac-*
    sudo -u "$REAL_USER" rm -rf "$USER_HOME/.cache/pamac" 2>/dev/null || true
    paccache -r -k 2 > /dev/null 2>&1 || true
    journalctl --vacuum-size=100M --vacuum-time=2weeks > /dev/null 2>&1 || true
    ORPHANS=$(pacman -Qtdq 2>/dev/null || true)
    [[ -n "$ORPHANS" ]] && pacman -Rns --noconfirm $ORPHANS > /dev/null 2>&1 || true

    log_info "Running SSD TRIM..."
    fstrim -va > /dev/null 2>&1 || true

    log_ok "Optimization complete! Desktop icons enabled, permanent partitions mounted, hot corners disabled, and hardware peak tuned."
    read -rp "Press [Enter] to return to the main menu..."
}

# ------------------------------------------------------------------------------
# 2. APP INSTALL FUNCTIONS
# ------------------------------------------------------------------------------
install_podman() {
    log_info "Installing Podman..."
    pacman -S --needed --noconfirm podman podman-compose podman-docker fuse-overlayfs
    if ! grep -q "^${REAL_USER}:" /etc/subuid 2>/dev/null; then
        usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$REAL_USER" || true
    fi
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" systemctl --user enable --now podman.socket 2>/dev/null || true
    log_ok "Podman installed."
    post_install_hook
}

install_kvm() {
    log_info "Installing KVM / QEMU Virt-Manager..."
    pacman -S --needed --noconfirm qemu-desktop virt-manager virt-viewer dnsmasq vde2 iptables-nft libguestfs
    systemctl enable --now libvirtd.service
    usermod -aG libvirt,kvm "$REAL_USER"
    virsh net-autostart default > /dev/null 2>&1 || true
    virsh net-start default > /dev/null 2>&1 || true
    echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm-intel.conf
    log_ok "KVM installed. (Note: Log out/in for group permissions to take effect)"
    post_install_hook
}

install_vscode() {
    log_info "Installing VS Code..."
    pamac enable-aur > /dev/null 2>&1 || true
    sudo -u "$REAL_USER" pamac build --no-confirm visual-studio-code-bin
    sudo -u "$REAL_USER" code --install-extension Google.antigravity > /dev/null 2>&1 || true
    log_ok "VS Code ready."
    post_install_hook
}

install_antigravity_ide() {
    log_info "Installing Antigravity IDE..."
    pamac enable-aur > /dev/null 2>&1 || true
    sudo -u "$REAL_USER" pamac build --no-confirm antigravity-ide || {
        sudo -u "$REAL_USER" bash -c 'curl -fsSL https://antigravity.google/install-ide.sh | bash' || true
    }
    log_ok "Antigravity IDE ready."
    post_install_hook
}

install_antigravity_standalone() {
    log_info "Installing Antigravity Standalone App & 'agy' CLI..."
    sudo -u "$REAL_USER" bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' || true
    log_ok "Antigravity Standalone ready."
    post_install_hook
}

install_chrome() {
    log_info "Installing Google Chrome..."
    pamac enable-aur > /dev/null 2>&1 || true
    sudo -u "$REAL_USER" pamac build --no-confirm google-chrome
    log_ok "Google Chrome installed."
    post_install_hook
}

install_office() {
    log_info "Installing LibreOffice Fresh..."
    pacman -S --needed --noconfirm libreoffice-fresh
    log_ok "LibreOffice installed."
    post_install_hook
}

install_media() {
    log_info "Installing Essential Multimedia Suite..."
    pacman -S --needed --noconfirm vlc celluloid gimp kdenlive
    log_ok "Multimedia suite installed."
    post_install_hook
}

install_all_apps() {
    log_info "=== STARTING GROUPED INSTALLATION OF ALL APPS ==="

    log_info "1/3. Installing all official repository applications in a single pass..."
    pacman -S --needed --noconfirm \
        podman podman-compose podman-docker fuse-overlayfs \
        qemu-desktop virt-manager virt-viewer dnsmasq vde2 iptables-nft libguestfs \
        libreoffice-fresh \
        vlc celluloid gimp kdenlive

    if ! grep -q "^${REAL_USER}:" /etc/subuid 2>/dev/null; then
        usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$REAL_USER" || true
    fi
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" systemctl --user enable --now podman.socket 2>/dev/null || true
    systemctl enable --now libvirtd.service > /dev/null 2>&1 || true
    usermod -aG libvirt,kvm "$REAL_USER"
    virsh net-autostart default > /dev/null 2>&1 || true
    virsh net-start default > /dev/null 2>&1 || true
    echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm-intel.conf

    log_info "2/3. Building AUR packages with multi-stream acceleration..."
    pamac enable-aur > /dev/null 2>&1 || true
    sudo -u "$REAL_USER" pamac build --no-confirm visual-studio-code-bin antigravity-ide google-chrome
    sudo -u "$REAL_USER" code --install-extension Google.antigravity > /dev/null 2>&1 || true

    log_info "3/3. Setting up Antigravity Standalone CLI..."
    sudo -u "$REAL_USER" bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' || true

    post_install_hook
    log_ok "All applications installed and configured successfully!"
}

# ------------------------------------------------------------------------------
# 3. UNINSTALL FUNCTIONS
# ------------------------------------------------------------------------------
uninstall_podman() {
    log_warn "Removing Podman..."
    safe_pacman_remove podman-docker podman-compose podman
    post_uninstall_hook
}

uninstall_kvm() {
    log_warn "Removing KVM Virt-Manager..."
    systemctl disable --now libvirtd.service 2>/dev/null || true
    safe_pacman_remove virt-manager virt-viewer libguestfs
    post_uninstall_hook
}

uninstall_vscode() {
    log_warn "Removing VS Code..."
    safe_pacman_remove visual-studio-code-bin
    rm -rf "$USER_HOME/.config/Code" "$USER_HOME/.vscode" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_antigravity_ide() {
    log_warn "Removing Antigravity IDE..."
    safe_pacman_remove antigravity-ide
    rm -rf "$USER_HOME/.antigravity-ide" "$USER_HOME/.config/antigravity-ide" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_antigravity_standalone() {
    log_warn "Removing Antigravity Standalone..."
    rm -rf "$USER_HOME/.local/bin/agy" "$USER_HOME/.antigravity" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_chrome() {
    log_warn "Removing Google Chrome..."
    safe_pacman_remove google-chrome
    rm -rf "$USER_HOME/.config/google-chrome" "$USER_HOME/.cache/google-chrome" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_office() {
    log_warn "Removing LibreOffice..."
    safe_pacman_remove libreoffice-fresh
    rm -rf "$USER_HOME/.config/libreoffice" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_media() {
    log_warn "Removing Multimedia Suite..."
    safe_pacman_remove vlc celluloid gimp kdenlive
    rm -rf "$USER_HOME/.config/GIMP" "$USER_HOME/.config/vlc" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_all_apps() {
    log_info "=== STARTING GROUPED REMOVAL OF ALL APPS ==="

    log_info "1/3. Disabling background virtualization and container services..."
    systemctl disable --now libvirtd.service 2>/dev/null || true
    sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" systemctl --user disable --now podman.socket 2>/dev/null || true

    log_info "2/3. Removing all installed applications in a single clean transaction..."
    safe_pacman_remove \
        podman-docker podman-compose podman \
        virt-manager virt-viewer libguestfs \
        visual-studio-code-bin \
        antigravity-ide \
        google-chrome \
        libreoffice-fresh \
        vlc celluloid gimp kdenlive

    log_info "3/3. Wiping user configuration & cache directories..."
    rm -rf "$USER_HOME/.config/Code" "$USER_HOME/.vscode" \
           "$USER_HOME/.antigravity-ide" "$USER_HOME/.config/antigravity-ide" \
           "$USER_HOME/.local/bin/agy" "$USER_HOME/.antigravity" \
           "$USER_HOME/.config/google-chrome" "$USER_HOME/.cache/google-chrome" \
           "$USER_HOME/.config/libreoffice" \
           "$USER_HOME/.config/GIMP" "$USER_HOME/.config/vlc" 2>/dev/null || true

    post_uninstall_hook
    log_ok "All selected applications uninstalled in a single clean batch!"
}

# ------------------------------------------------------------------------------
# 4. SUBMENU: INSTALL APPS
# ------------------------------------------------------------------------------
menu_install() {
    while true; do
        st_podman=$(is_bin_installed podman && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_kvm=$(is_pkg_installed virt-manager && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_vscode=$(is_pkg_installed visual-studio-code-bin && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_ag_ide=$(is_pkg_installed antigravity-ide && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_ag_app=$(is_bin_installed agy && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_chrome=$(is_pkg_installed google-chrome && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_office=$(is_pkg_installed libreoffice-fresh && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_media=$(is_pkg_installed gimp && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")

        echo ""
        echo -e "${BOLD}========================================================================${NC}"
        echo -e "${BOLD}                          INSTALL APPLICATIONS                          ${NC}"
        echo -e "${BOLD}========================================================================${NC}"
        echo -e " 1) Podman Engine & Compose      $st_podman ${CYAN}[OFFICIAL]${NC}"
        echo -e "    ${BLUE}↳${NC} Rootless, daemonless container engine (drop-in Docker replacement)."
        echo -e " 2) KVM / QEMU Virt-Manager      $st_kvm ${CYAN}[OFFICIAL]${NC}"
        echo -e "    ${BLUE}↳${NC} Native Type-1 hypervisor for running Windows/Linux VMs at near bare-metal speed."
        echo -e " 3) VS Code + Antigravity Ext    $st_vscode ${CYAN}[OFFICIAL]${NC}"
        echo -e "    ${BLUE}↳${NC} Official Microsoft VS Code IDE paired with Google's Antigravity AI extension."
        echo -e " 4) Antigravity IDE              $st_ag_ide ${CYAN}[OFFICIAL]${NC}"
        echo -e "    ${BLUE}↳${NC} Dedicated AI coding environment with autonomous agent interaction & browser testing."
        echo -e " 5) Antigravity Standalone       $st_ag_app ${CYAN}[OFFICIAL]${NC}"
        echo -e "    ${BLUE}↳${NC} Multi-agent orchestration mission control (non-editor) and 'agy' CLI."
        echo -e " 6) Google Chrome Browser        $st_chrome ${CYAN}[OFFICIAL]${NC}"
        echo -e "    ${BLUE}↳${NC} Proprietary web browser configured for Intel Iris Xe Wayland video decoding."
        echo -e " 7) LibreOffice Fresh Suite      $st_office ${CYAN}[OFFICIAL]${NC}"
        echo -e "    ${BLUE}↳${NC} Open-source office suite (Writer, Calc, Impress, Draw)."
        echo -e " 8) Essential Multimedia Suite   $st_media ${CYAN}[OFFICIAL]${NC}"
        echo -e "    ${BLUE}↳${NC} GIMP (Photo Editing), Kdenlive (Video Editing), VLC & Celluloid (Media Players)."
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " A) Install ALL Applications (Single-Pass Grouped Install)"
        echo -e " B) Back to Main Menu"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Select an application to install (1-8 / A / B): " choice

        case "$choice" in
            1) install_podman ;;
            2) install_kvm ;;
            3) install_vscode ;;
            4) install_antigravity_ide ;;
            5) install_antigravity_standalone ;;
            6) install_chrome ;;
            7) install_office ;;
            8) install_media ;;
            [aA]) install_all_apps ;;
            [bB]) break ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 5. SUBMENU: UNINSTALL APPS
# ------------------------------------------------------------------------------
menu_uninstall() {
    while true; do
        st_podman=$(is_bin_installed podman && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_kvm=$(is_pkg_installed virt-manager && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_vscode=$(is_pkg_installed visual-studio-code-bin && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_ag_ide=$(is_pkg_installed antigravity-ide && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_ag_app=$(is_bin_installed agy && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_chrome=$(is_pkg_installed google-chrome && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_office=$(is_pkg_installed libreoffice-fresh && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_media=$(is_pkg_installed gimp && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")

        echo ""
        echo -e "${BOLD}========================================================================${NC}"
        echo -e "${BOLD}                         UNINSTALL APPLICATIONS                         ${NC}"
        echo -e "${BOLD}========================================================================${NC}"
        echo -e " 1) Podman Engine & Compose      $st_podman"
        echo -e " 2) KVM / QEMU Virt-Manager      $st_kvm"
        echo -e " 3) VS Code + Antigravity Ext    $st_vscode"
        echo -e " 4) Antigravity IDE              $st_ag_ide"
        echo -e " 5) Antigravity Standalone       $st_ag_app"
        echo -e " 6) Google Chrome Browser        $st_chrome"
        echo -e " 7) LibreOffice Fresh Suite      $st_office"
        echo -e " 8) Essential Multimedia Suite   $st_media"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " A) Uninstall ALL Applications (Single-Pass Grouped Removal)"
        echo -e " B) Back to Main Menu"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Select an application to remove (1-8 / A / B): " choice

        case "$choice" in
            1) uninstall_podman ;;
            2) uninstall_kvm ;;
            3) uninstall_vscode ;;
            4) uninstall_antigravity_ide ;;
            5) uninstall_antigravity_standalone ;;
            6) uninstall_chrome ;;
            7) uninstall_office ;;
            8) uninstall_media ;;
            [aA])
                read -rp "Are you sure you want to uninstall ALL applications? (y/N): " conf
                [[ "$conf" =~ ^[Yy]$ ]] && uninstall_all_apps
                ;;
            [bB]) break ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 6. STORAGE & PERMANENT PARTITION MANAGEMENT
# ------------------------------------------------------------------------------
configure_permanent_partitions() {
    echo ""
    log_info "=== CONFIGURING PERMANENT STORAGE MOUNTS & UI LABELS ==="
    log_info "Scanning all disk partitions to eliminate temporary user-session mounts..."

    local root_uuid boot_uuid efi_uuid home_uuid
    root_uuid=$(findmnt -n -o UUID / 2>/dev/null || true)
    boot_uuid=$(findmnt -n -o UUID /boot 2>/dev/null || true)
    efi_uuid=$(findmnt -n -o UUID /boot/efi 2>/dev/null || true)
    home_uuid=$(findmnt -n -o UUID /home 2>/dev/null || true)

    local fstab_bak="/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"
    cp -p /etc/fstab "$fstab_bak"
    log_ok "Created safety backup of /etc/fstab at: $fstab_bak"

    mkdir -p /mnt /media 2>/dev/null || true

    # Ensure desktop volume display is enabled in GNOME desktop icons extensions
    run_as_user gsettings set org.gnome.shell.extensions.gtk4-ding show-volumes true 2>/dev/null || true
    run_as_user gsettings set org.gnome.shell.extensions.ding show-volumes true 2>/dev/null || true

    local configured_count=0
    local skipped_count=0

    while IFS= read -r blk_line; do
        unset NAME TYPE FSTYPE LABEL UUID
        eval "$blk_line"

        # Only process block device partitions and decrypted LUKS volumes
        [[ "$TYPE" != "part" && "$TYPE" != "crypt" ]] && continue
        [[ -z "$FSTYPE" || "$FSTYPE" == "swap" ]] && continue
        [[ -z "$UUID" ]] && continue

        # Skip core OS system partitions
        if [[ "$UUID" == "$root_uuid" || "$UUID" == "$boot_uuid" || "$UUID" == "$efi_uuid" ]]; then
            ((skipped_count++))
            continue
        fi

        # Skip partitions already assigned to system root hierarchies in fstab (e.g., /home, /var, /usr)
        if awk -v u="$UUID" '$1 ~ u && $2 ~ /^\/(boot|efi|home|var|usr|etc)?$/ { found=1 } END { exit !found }' /etc/fstab 2>/dev/null; then
            ((skipped_count++))
            continue
        fi

        local dev_path="/dev/$NAME"

        # Resolve or generate clean label
        if [[ -z "$LABEL" ]]; then
            LABEL=$(blkid -s LABEL -o value "$dev_path" 2>/dev/null || true)
            [[ -z "$LABEL" ]] && LABEL="disk-${UUID:0:8}"
        fi

        # Sanitize directory name for /mnt mount point (replace spaces/slashes with -/_)
        local clean_label
        clean_label=$(echo "$LABEL" | tr ' /' '_-' | tr -cd '[:alnum:]_.-')
        [[ -z "$clean_label" ]] && clean_label="disk-${UUID:0:8}"

        local mount_point="/mnt/$clean_label"
        local encoded_label
        encoded_label=$(echo "$LABEL" | sed 's/ /%20/g')

        log_info "Processing partition: ${BOLD}$NAME${NC} [Label: ${CYAN}$LABEL${NC}, UUID: $UUID, FS: $FSTYPE]"

        # 1. Detect and remove existing user session mounts (e.g. /run/media/$USER/*)
        local user_mounts
        user_mounts=$(findmnt -n -l -o TARGET -S "$dev_path" 2>/dev/null | grep -E "^/run/media/" || true)
        if [[ -z "$user_mounts" ]]; then
            user_mounts=$(findmnt -n -l -o TARGET -S "UUID=$UUID" 2>/dev/null | grep -E "^/run/media/" || true)
        fi

        local was_busy=false
        if [[ -n "$user_mounts" ]]; then
            while IFS= read -r um_path; do
                [[ -z "$um_path" ]] && continue
                log_info "Detected user-session mount for $LABEL at $um_path. Releasing user session..."
                if umount "$um_path" 2>/dev/null; then
                    log_ok "Successfully released user-session mount: $um_path"
                    rmdir "$um_path" 2>/dev/null || true
                else
                    log_warn "Target $um_path is currently in active use (busy). Configured in /etc/fstab for boot mount; will cleanly transition to $mount_point on reboot."
                    was_busy=true
                fi
            done <<< "$user_mounts"
        fi

        # 2. Determine optimal fstab driver and options
        local fs_driver="$FSTYPE"
        local fs_opts="defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
        local dump_val=0
        local pass_val=0

        case "$FSTYPE" in
            btrfs)
                fs_driver="btrfs"
                local existing_subvol
                existing_subvol=$(findmnt -n -o OPTIONS -S "$dev_path" 2>/dev/null | grep -o 'subvol=[^,]*' | head -n1 || true)
                local subvol_opt=""
                if [[ -n "$existing_subvol" && "$existing_subvol" != "subvol=/" ]]; then
                    subvol_opt="${existing_subvol},"
                fi
                fs_opts="defaults,noatime,${subvol_opt}compress=zstd,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
                dump_val=0
                pass_val=0
                ;;
            ntfs)
                if modprobe ntfs3 2>/dev/null || lsmod | grep -q "^ntfs3"; then
                    fs_driver="ntfs3"
                elif command -v ntfs-3g &>/dev/null; then
                    fs_driver="ntfs-3g"
                else
                    fs_driver="ntfs"
                fi
                fs_opts="defaults,noatime,uid=${USER_UID},gid=${USER_UID},umask=022,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
                dump_val=0
                pass_val=0
                ;;
            vfat|exfat)
                fs_driver="$FSTYPE"
                fs_opts="defaults,noatime,uid=${USER_UID},gid=${USER_UID},umask=022,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
                dump_val=0
                pass_val=0
                ;;
            ext4|ext3|ext2)
                fs_driver="$FSTYPE"
                fs_opts="defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
                dump_val=0
                pass_val=2
                ;;
            *)
                fs_driver="$FSTYPE"
                fs_opts="defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
                dump_val=0
                pass_val=0
                ;;
        esac

        mkdir -p "$mount_point"

        # 3. Add or update in /etc/fstab
        if grep -q "UUID=$UUID" /etc/fstab; then
            log_info "Updating existing /etc/fstab entry for $NAME ($LABEL)..."
            sed -i "\|UUID=$UUID|d" /etc/fstab
        else
            log_info "Adding new startup mount for $NAME ($LABEL) to /etc/fstab..."
        fi

        [[ -n "$(tail -c1 /etc/fstab 2>/dev/null)" ]] && echo "" >> /etc/fstab
        printf "UUID=%-36s %-20s %-8s %-65s %d %d\n" \
            "$UUID" "$mount_point" "$fs_driver" "$fs_opts" "$dump_val" "$pass_val" >> /etc/fstab

        # 4. Mount partition now to the permanent mount point
        if ! findmnt -n "$mount_point" &>/dev/null; then
            mount "$mount_point" 2>/dev/null || mount -t "$fs_driver" -o "$fs_opts" "UUID=$UUID" "$mount_point" 2>/dev/null || true
        fi

        if findmnt -n "$mount_point" &>/dev/null; then
            log_ok "Mounted $NAME ($LABEL) at $mount_point"
            # Set directory ownership for non-root user if Linux filesystem
            if [[ "$fs_driver" =~ ^(btrfs|ext[234]|xfs|f2fs)$ ]] && [[ -n "$REAL_USER" ]] && [[ "$REAL_USER" != "root" ]]; then
                chown "$REAL_USER:" "$mount_point" 2>/dev/null || true
                chmod 755 "$mount_point" 2>/dev/null || true
            fi
        else
            log_warn "Partition $NAME ($LABEL) added to /etc/fstab for boot mount (could not mount immediately, possibly Windows hibernation/lock)."
        fi

        # 5. Create symlinks for universal backward compatibility
        ln -sfn "$mount_point" "/media/$clean_label" 2>/dev/null || true
        if [[ -d "/run/media/$REAL_USER" ]] && [[ "$was_busy" != "true" ]]; then
            ln -sfn "$mount_point" "/run/media/$REAL_USER/$clean_label" 2>/dev/null || true
        fi

        ((configured_count++))
    done < <(lsblk -P -o NAME,TYPE,FSTYPE,LABEL,UUID)

    systemctl daemon-reload 2>/dev/null || true

    echo ""
    log_ok "Permanent storage setup complete! ($configured_count partition(s) configured, $skipped_count system partition(s) preserved)"
    echo -e "${BOLD}Summary of Persistent Partitions:${NC}"
    printf "%-12s %-16s %-10s %-22s %-20s\n" "DEVICE" "LABEL" "FILESYSTEM" "STARTUP MOUNT" "UI DISPLAY NAME"
    echo "----------------------------------------------------------------------------------------"
    while IFS= read -r blk_line; do
        unset NAME TYPE FSTYPE LABEL UUID
        eval "$blk_line"
        [[ "$TYPE" != "part" && "$TYPE" != "crypt" ]] && continue
        if grep -q "UUID=$UUID" /etc/fstab && grep "UUID=$UUID" /etc/fstab | grep -q "x-gvfs-show"; then
            local mp gvfs_name
            mp=$(awk -v u="$UUID" '$1 ~ u { print $2 }' /etc/fstab)
            gvfs_name=$(grep "UUID=$UUID" /etc/fstab | grep -o 'x-gvfs-name=[^, ]*' | cut -d= -f2 | sed 's/%20/ /g')
            printf "%-12s %-16s %-10s %-22s %-20s\n" "$NAME" "${LABEL:-N/A}" "$FSTYPE" "$mp" "$gvfs_name"
        fi
    done < <(lsblk -P -o NAME,TYPE,FSTYPE,LABEL,UUID)
    echo "----------------------------------------------------------------------------------------"
    log_info "All partitions are set to mount at system startup and display identified by label in GNOME Files & Desktop."
}

# ------------------------------------------------------------------------------
# 7. SUBMENU: DESKTOP & GNOME UI SETTINGS
# ------------------------------------------------------------------------------
menu_desktop_settings() {
    while true; do
        local di_raw di_st hc_raw hc_st
        di_raw=$(get_desktop_icons_status)
        hc_raw=$(get_hot_corner_status)

        [[ "$di_raw" == "enabled" ]] && di_st="${GREEN}[Enabled]${NC}" || di_st="${RED}[Disabled]${NC}"
        [[ "$hc_raw" == "enabled" ]] && hc_st="${RED}[Enabled]${NC}" || hc_st="${GREEN}[Disabled (Recommended)]${NC}"

        echo ""
        echo -e "${BOLD}========================================================================${NC}"
        echo -e "${BOLD}                    DESKTOP & GNOME UI SETTINGS                         ${NC}"
        echo -e "${BOLD}========================================================================${NC}"
        echo -e " 1) Desktop Files & Icons        $di_st"
        echo -e "    ${BLUE}↳${NC} Toggle displaying files, folders, and drives directly on desktop."
        echo -e " 2) Top-Left Hot Corner          $hc_st"
        echo -e "    ${BLUE}↳${NC} Toggle Activities overview trigger when hitting top-left corner."
        echo -e " 3) Apply Recommended Preset (Desktop Icons ON, Hot Corner OFF)"
        echo -e " 4) Configure Permanent Drive Mounts & UI Labels"
        echo -e "    ${BLUE}↳${NC} Auto-mount all data partitions at boot and display labeled in Files & Desktop."
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " B) Back to Main Menu"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Select an option (1-4 / B): " choice

        case "$choice" in
            1)
                if [[ "$di_raw" == "enabled" ]]; then
                    configure_desktop_icons disable
                else
                    configure_desktop_icons enable
                fi
                read -rp "Press [Enter] to continue..."
                ;;
            2)
                if [[ "$hc_raw" == "enabled" ]]; then
                    configure_hot_corner disable
                else
                    configure_hot_corner enable
                fi
                read -rp "Press [Enter] to continue..."
                ;;
            3)
                configure_desktop_icons enable
                configure_hot_corner disable
                log_ok "Applied recommended preset: Desktop Icons Enabled & Hot Corner Disabled."
                read -rp "Press [Enter] to continue..."
                ;;
            4)
                configure_permanent_partitions
                read -rp "Press [Enter] to continue..."
                ;;
            [bB]) break ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 8. MAIN MENU
# ------------------------------------------------------------------------------
while true; do
    echo ""
    echo -e "${BOLD}========================================================================${NC}"
    echo -e "${BOLD}                     MANJARO CONTROL CENTER                             ${NC}"
    echo -e "${BOLD}========================================================================${NC}"
    echo -e " ${BOLD}1)${NC} Optimize the system (Timeshift, Smart Downloads, GuC/HuC, SSD TRIM)"
    echo -e " ${BOLD}2)${NC} Install apps"
    echo -e " ${BOLD}3)${NC} Uninstall apps"
    echo -e " ${BOLD}4)${NC} Desktop UI Settings (Desktop Icons & Hot Corner)"
    echo -e " ${BOLD}5)${NC} Quit"
    echo -e "${BOLD}------------------------------------------------------------------------${NC}"
    echo -e " 📋 Live log file: ${CYAN}$LOG_FILE${NC}"
    echo -e "${BOLD}========================================================================${NC}"
    read -rp "Please enter your choice (1-5): " main_choice

    case "$main_choice" in
        1) optimize_system ;;
        2) menu_install ;;
        3) menu_uninstall ;;
        4) menu_desktop_settings ;;
        5)
            echo ""
            log_ok "Exiting. Session completed successfully!"
            break
            ;;
        *)
            log_warn "Invalid option. Please enter a number from 1 to 5."
            ;;
    esac
done

