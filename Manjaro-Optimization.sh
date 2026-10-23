#!/usr/bin/env bash
# ==============================================================================
# Manjaro Modular Optimizer, System Maintainer & Software Hub (v9.5 - Complete)
# Target: Dell Inspiron 7706 | GNOME Wayland | Sunshine | Full AUR & Kernel Sync
# ==============================================================================

set -o pipefail
export TERM="${TERM:-xterm-256color}"

# ------------------------------------------------------------------------------
# 0. ROOT CHECK, USER ENVIRONMENT & LOCAL LOGGING
# ------------------------------------------------------------------------------
if [[ "$EUID" -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m Please run this script with sudo: sudo ./Manjaro-Optimization.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
USER_UID=$(id -u "$REAL_USER")

run_as_user() {
    if [[ "$EUID" -eq 0 ]] && [[ -n "$REAL_USER" ]] && [[ "$REAL_USER" != "root" ]]; then
        sudo -u "$REAL_USER" env \
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
LOG_FILE="${SCRIPT_DIR}/Manjaro-Optimization.log"

touch "$LOG_FILE" 2>/dev/null || true
if [[ -n "$SUDO_USER" ]]; then
    chown "$SUDO_USER:" "$LOG_FILE" 2>/dev/null || true
fi

exec > >(tee -a "$LOG_FILE") 2>&1

POLKIT_RULE="/etc/polkit-1/rules.d/49-temp-Manjaro-Optimization.rules"
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
    sudo -u "$REAL_USER" bash -c "command -v '$1'" &> /dev/null
}

init_downloads() {
    if ! command -v aria2c &> /dev/null; then
        pacman -S --needed --noconfirm aria2 > /dev/null 2>&1 || true
    fi

    local aria_rule="'https::/usr/bin/aria2c -c -m2 -s4 -x4 -k1M --file-allocation=none -o %o %u'"
    local aria_rule_http="'http::/usr/bin/aria2c -c -m2 -s4 -x4 -k1M --file-allocation=none -o %o %u'"

    for conf in /etc/makepkg.conf "$USER_HOME/.makepkg.conf"; do
        if [[ -f "$conf" ]]; then
            sed -i "s|'https::/usr/bin/curl.*'|$aria_rule|" "$conf"
            sed -i "s|'http::/usr/bin/curl.*'|$aria_rule_http|" "$conf"
        fi
    done

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
    log_info "Running post-uninstall cleanup..."
    flatpak uninstall --unused -y > /dev/null 2>&1 || true
    
    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null || true)
    if [[ -n "$orphans" ]]; then
        pacman -Rns --noconfirm $orphans > /dev/null 2>&1 || true
    fi
    log_ok "Orphaned packages and unused runtimes cleared."
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
    local action="$1"
    if [[ "$action" == "enable" ]]; then
        log_info "Enabling Desktop Files (Disabling volume/drive icons on desktop)..."
        if ! is_pkg_installed "gnome-shell-extension-gtk4-desktop-icons-ng" && ! is_pkg_installed "gnome-shell-extension-desktop-icons-ng"; then
            pacman -S --needed --noconfirm gnome-shell-extension-gtk4-desktop-icons-ng > /dev/null 2>&1 || \
            pacman -S --needed --noconfirm gnome-shell-extension-desktop-icons-ng > /dev/null 2>&1 || true
        fi

        run_as_user gsettings set org.gnome.shell disable-user-extensions false 2>/dev/null || true

        run_as_user gsettings set org.gnome.shell.extensions.gtk4-ding show-volumes false 2>/dev/null || true
        run_as_user gsettings set org.gnome.shell.extensions.gtk4-ding show-network-volumes false 2>/dev/null || true
        run_as_user gsettings set org.gnome.shell.extensions.ding show-volumes false 2>/dev/null || true
        run_as_user gsettings set org.gnome.shell.extensions.ding show-network-volumes false 2>/dev/null || true

        local found=false
        for ext in "gtk4-ding@smedius.gitlab.com" "ding@rastersoft.com"; do
            if run_as_user gnome-extensions list 2>/dev/null | grep -q "^${ext}$"; then
                run_as_user gnome-extensions enable "$ext" 2>/dev/null || true
                found=true
                log_ok "Desktop Icons enabled ($ext) without partition clutter."
            fi
        done
        if [[ "$found" != "true" ]]; then
            log_warn "Could not locate a supported Desktop Icons extension."
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
    local action="$1"
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
# 1. SYSTEM OPTIMIZATION ROUTINE (Includes AUR & Kernel Lifecycle Checks)
# ------------------------------------------------------------------------------
optimize_system() {
    echo ""
    log_info "=== STARTING FULL SYSTEM OPTIMIZATION ==="

    log_info "1/13: Checking Timeshift & creating system restore point..."
    if ! is_pkg_installed timeshift; then
        pacman -S --needed --noconfirm timeshift > /dev/null 2>&1 || true
    fi
    timeshift --create --comments "Before System Optimization" --tags O > /dev/null 2>&1 || {
        log_warn "Timeshift snapshot skipped (run Timeshift GUI once to configure disk if needed)."
    }

    log_info "2/13: Ensuring download accelerator and pacman formatting..."
    init_downloads
    sed -i 's/^#*Color/Color/' /etc/pacman.conf
    if ! grep -q "ILoveCandy" /etc/pacman.conf; then
        sed -i '/# Misc options/a ILoveCandy' /etc/pacman.conf 2>/dev/null || true
    fi

    log_info "3/13: Refreshing fastest mirrors & full system upgrade (Official + AUR)..."
    pacman-mirrors --fasttrack 5
    # Upgrades official packages and all AUR packages (VS Code, Chrome, Antigravity, Sunshine)
    sudo -u "$REAL_USER" pamac update --no-confirm --aur

    log_info "4/13: Checking Linux Kernel Lifecycle (EOL Migration)..."
    local running_kver
    running_kver=$(uname -r | cut -d. -f1,2 | tr -d '.') # e.g. 71 for 7.1
    if [[ "$running_kver" -le 71 ]]; then
        log_warn "Active kernel series (linux$running_kver) is End-Of-Life (EOL)."
        if ! mhwd-kernel -li | grep -q "linux72"; then
            log_info "Installing recommended modern Linux 7.2 kernel branch..."
            mhwd-kernel -i linux72 rmc || log_warn "Kernel 7.2 installation deferred. Keep current kernel."
        fi
    fi

    log_info "5/13: Enforcing en_US locale and formatting..."
    if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
        sed -i 's/^#*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        locale-gen > /dev/null 2>&1 || true
    fi
    localectl set-locale LANG=en_US.UTF-8 LC_TIME=en_US.UTF-8 LC_NUMERIC=en_US.UTF-8 LC_MONETARY=en_US.UTF-8 LC_MEASUREMENT=en_US.UTF-8 > /dev/null 2>&1 || true
    localectl set-keymap us > /dev/null 2>&1 || true
    run_as_user gsettings set org.gnome.system.locale region 'en_US.UTF-8' 2>/dev/null || true

    log_info "6/13: Configuring dual-boot GRUB (7s timer for Windows) & LocalRTC..."
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

    log_info "7/13: Applying Btrfs NVMe 'noatime' mount optimization & labeling system partition..."
    if grep -E "btrfs.*compress=zstd" /etc/fstab | grep -qv "noatime"; then
        sed -i 's/defaults,compress=zstd/defaults,noatime,compress=zstd/g' /etc/fstab
        mount -o remount / 2>/dev/null || true
        mount -o remount /home 2>/dev/null || true
        mount -o remount /var/cache 2>/dev/null || true
        mount -o remount /var/log 2>/dev/null || true
        log_ok "Btrfs subvolumes remounted with noatime."
    fi

    local root_src root_dev part_num disk_dev
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null)
    root_dev="${root_src%%\[*}"
    if [[ -n "$root_dev" && -b "$root_dev" ]]; then
        btrfs filesystem label / "Manjaro" 2>/dev/null || btrfs filesystem label "$root_dev" "Manjaro" 2>/dev/null || true
        part_num=$(echo "$root_dev" | grep -o '[0-9]*$')
        disk_dev=$(echo "$root_dev" | sed -E 's/p?[0-9]+$//')
        if [[ -n "$part_num" && -n "$disk_dev" && -b "$disk_dev" ]]; then
            parted "$disk_dev" name "$part_num" "Manjaro" 2>/dev/null || true
        fi
        udevadm trigger -s block -p DEVNAME="$root_dev" -c change 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        log_ok "System partition verified as 'Manjaro'."
    fi

    log_info "8/13: Configuring Windows partitions (protecting sensitive/recovery partitions)..."
    configure_permanent_partitions

    log_info "9/13: Setting up ZRAM (RAM-compressed swap)..."
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
    systemctl daemon-reload
    systemctl restart systemd-zram-setup@zram0.service 2>/dev/null || true

    log_info "10/13: Tuning kernel sysctl parameters for 32GB RAM & TCP BBR..."
    cat << 'EOF' > /etc/sysctl.d/99-dell-perf.conf
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system > /dev/null 2>&1 || true

    log_info "11/13: Enabling Intel GuC/HuC microcontrollers & thermald..."
    cat << 'EOF' > /etc/modprobe.d/i915.conf
options i915 enable_guc=3
EOF
    sed -i 's/^#*RuntimeWatchdogSec=.*/RuntimeWatchdogSec=off/' /etc/systemd/system.conf 2>/dev/null || true

    pacman -S --needed --noconfirm intel-media-driver libva-utils thermald pacman-contrib git base-devel > /dev/null 2>&1 || true
    systemctl enable --now thermald.service > /dev/null 2>&1 || true
    systemctl enable --now fstrim.timer > /dev/null 2>&1 || true
    systemctl enable --now paccache.timer > /dev/null 2>&1 || true

    log_info "12/13: Enabling Desktop Icons (files only) & Disabling Top-Left Hot Corner..."
    configure_desktop_icons enable
    configure_hot_corner disable

    log_info "13/13: Performing Deep System Clutter Cleanup..."
    rm -rf /var/tmp/pamac-build-* /var/tmp/pamac-*
    sudo -u "$REAL_USER" rm -rf "$USER_HOME/.cache/pamac" 2>/dev/null || true
    paccache -r -k 2 > /dev/null 2>&1 || true
    journalctl --vacuum-size=100M --vacuum-time=2weeks > /dev/null 2>&1 || true
    
    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null || true)
    [[ -n "$orphans" ]] && pacman -Rns --noconfirm $orphans > /dev/null 2>&1 || true

    log_info "Executing SSD TRIM pass..."
    fstrim -va > /dev/null 2>&1 || true

    log_ok "Optimization complete! OS, AUR, kernel, and hardware settings are updated."
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
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user enable --now podman.socket 2>/dev/null || true
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
    log_info "Installing Google Antigravity 2.0 Standalone Desktop Platform & 'agy' CLI..."
    pamac enable-aur > /dev/null 2>&1 || true
    sudo -u "$REAL_USER" pamac build --no-confirm antigravity || {
        log_warn "AUR package build had an issue. Falling back to official installer..."
        sudo -u "$REAL_USER" bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' || true
    }
    log_ok "Antigravity 2.0 Platform & CLI ready."
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

install_sunshine() {
    log_info "Installing Sunshine Remote Desktop Server (High-FPS/Low-Latency)..."
    pamac enable-aur > /dev/null 2>&1 || true
    sudo -u "$REAL_USER" pamac build --no-confirm sunshine-bin || sudo -u "$REAL_USER" pamac build --no-confirm sunshine

    # Grant user permission to uinput for virtual mouse/keyboard emulation
    usermod -aG input "$REAL_USER"
    echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' > /etc/udev/rules.d/85-sunshine-uinput.rules
    udevadm control --reload-rules && udevadm trigger

    # Enable systemd user service
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user enable --now sunshine 2>/dev/null || true

    log_ok "Sunshine installed and active! Access dashboard at: https://localhost:47990"
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
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user enable --now podman.socket 2>/dev/null || true
    systemctl enable --now libvirtd.service > /dev/null 2>&1 || true
    usermod -aG libvirt,kvm,input "$REAL_USER"
    virsh net-autostart default > /dev/null 2>&1 || true
    virsh net-start default > /dev/null 2>&1 || true
    echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm-intel.conf

    log_info "2/3. Building AUR packages with multi-stream acceleration..."
    pamac enable-aur > /dev/null 2>&1 || true
    sudo -u "$REAL_USER" pamac build --no-confirm visual-studio-code-bin antigravity-ide antigravity google-chrome sunshine-bin
    sudo -u "$REAL_USER" code --install-extension Google.antigravity > /dev/null 2>&1 || true

    # Configure Sunshine
    echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' > /etc/udev/rules.d/85-sunshine-uinput.rules
    udevadm control --reload-rules && udevadm trigger
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user enable --now sunshine 2>/dev/null || true

    log_info "3/3. Verifying Antigravity CLI..."
    if ! is_bin_installed agy; then
        sudo -u "$REAL_USER" bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' || true
    fi

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
    log_warn "Removing Antigravity 2.0 Standalone..."
    safe_pacman_remove antigravity
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

uninstall_sunshine() {
    log_warn "Removing Sunshine..."
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user disable --now sunshine 2>/dev/null || true
    safe_pacman_remove sunshine-bin sunshine
    rm -f /etc/udev/rules.d/85-sunshine-uinput.rules
    rm -rf "$USER_HOME/.config/sunshine" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_all_apps() {
    log_info "=== STARTING GROUPED REMOVAL OF ALL APPS ==="

    log_info "1/3. Disabling background virtualization, containers & streaming services..."
    systemctl disable --now libvirtd.service 2>/dev/null || true
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user disable --now podman.socket sunshine 2>/dev/null || true

    log_info "2/3. Removing all installed applications in a single clean transaction..."
    safe_pacman_remove \
        podman-docker podman-compose podman \
        virt-manager virt-viewer libguestfs \
        visual-studio-code-bin \
        antigravity-ide \
        antigravity \
        google-chrome \
        libreoffice-fresh \
        vlc celluloid gimp kdenlive \
        sunshine-bin sunshine

    log_info "3/3. Wiping user configuration & cache directories..."
    rm -rf "$USER_HOME/.config/Code" "$USER_HOME/.vscode" \
           "$USER_HOME/.antigravity-ide" "$USER_HOME/.config/antigravity-ide" \
           "$USER_HOME/.local/bin/agy" "$USER_HOME/.antigravity" \
           "$USER_HOME/.config/google-chrome" "$USER_HOME/.cache/google-chrome" \
           "$USER_HOME/.config/libreoffice" \
           "$USER_HOME/.config/GIMP" "$USER_HOME/.config/vlc" \
           "$USER_HOME/.config/sunshine" /etc/udev/rules.d/85-sunshine-uinput.rules 2>/dev/null || true

    post_uninstall_hook
    log_ok "All selected applications uninstalled."
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
        st_ag_app=$( (is_pkg_installed antigravity || is_bin_installed agy) && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_chrome=$(is_pkg_installed google-chrome && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_office=$(is_pkg_installed libreoffice-fresh && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_media=$(is_pkg_installed gimp && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_sunshine=$(is_pkg_installed sunshine-bin || is_bin_installed sunshine && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")

        echo ""
        echo -e "${BOLD}========================================================================${NC}"
        echo -e "${BOLD}                          INSTALL APPLICATIONS                          ${NC}"
        echo -e "${BOLD}========================================================================${NC}"
        echo -e " 1) Podman Engine & Compose      $st_podman ${CYAN}[OFFICIAL]${NC}"
        echo -e " 2) KVM / QEMU Virt-Manager      $st_kvm ${CYAN}[OFFICIAL]${NC}"
        echo -e " 3) VS Code + Antigravity Ext    $st_vscode ${CYAN}[OFFICIAL]${NC}"
        echo -e " 4) Antigravity IDE              $st_ag_ide ${CYAN}[OFFICIAL]${NC}"
        echo -e " 5) Antigravity 2.0 Platform     $st_ag_app ${CYAN}[OFFICIAL AUR: antigravity]${NC}"
        echo -e " 6) Google Chrome Browser        $st_chrome ${CYAN}[OFFICIAL]${NC}"
        echo -e " 7) LibreOffice Fresh Suite      $st_office ${CYAN}[OFFICIAL]${NC}"
        echo -e " 8) Essential Multimedia Suite   $st_media ${CYAN}[OFFICIAL]${NC}"
        echo -e " 9) Sunshine Remote Desktop      $st_sunshine ${CYAN}[LOW-LATENCY STREAMING]${NC}"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " A) Install ALL Applications"
        echo -e " B) Back to Main Menu"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Select an application to install (1-9 / A / B): " choice

        case "$choice" in
            1) install_podman ;;
            2) install_kvm ;;
            3) install_vscode ;;
            4) install_antigravity_ide ;;
            5) install_antigravity_standalone ;;
            6) install_chrome ;;
            7) install_office ;;
            8) install_media ;;
            9) install_sunshine ;;
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
        st_ag_app=$( (is_pkg_installed antigravity || is_bin_installed agy) && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_chrome=$(is_pkg_installed google-chrome && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_office=$(is_pkg_installed libreoffice-fresh && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_media=$(is_pkg_installed gimp && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_sunshine=$(is_pkg_installed sunshine-bin || is_bin_installed sunshine && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")

        echo ""
        echo -e "${BOLD}========================================================================${NC}"
        echo -e "${BOLD}                         UNINSTALL APPLICATIONS                         ${NC}"
        echo -e "${BOLD}========================================================================${NC}"
        echo -e " 1) Podman Engine & Compose      $st_podman"
        echo -e " 2) KVM / QEMU Virt-Manager      $st_kvm"
        echo -e " 3) VS Code + Antigravity Ext    $st_vscode"
        echo -e " 4) Antigravity IDE              $st_ag_ide"
        echo -e " 5) Antigravity 2.0 Platform     $st_ag_app"
        echo -e " 6) Google Chrome Browser        $st_chrome"
        echo -e " 7) LibreOffice Fresh Suite      $st_office"
        echo -e " 8) Essential Multimedia Suite   $st_media"
        echo -e " 9) Sunshine Remote Desktop      $st_sunshine"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " A) Uninstall ALL Applications"
        echo -e " B) Back to Main Menu"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Select an application to remove (1-9 / A / B): " choice

        case "$choice" in
            1) uninstall_podman ;;
            2) uninstall_kvm ;;
            3) uninstall_vscode ;;
            4) uninstall_antigravity_ide ;;
            5) uninstall_antigravity_standalone ;;
            6) uninstall_chrome ;;
            7) uninstall_office ;;
            8) uninstall_media ;;
            9) uninstall_sunshine ;;
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
# 6. STORAGE & PERMANENT WINDOWS DATA PARTITION MANAGEMENT (ACTIVE SCRUBBING)
# ------------------------------------------------------------------------------
configure_permanent_partitions() {
    echo ""
    log_info "=== CONFIGURING DATA PARTITIONS & PURGING RECOVERY/OEM MOUNTS ==="

    local fstab_bak="/etc/fstab.bak.$(date +%Y%m%d_%H%M%S)"
    cp -p /etc/fstab "$fstab_bak"
    log_ok "Created safety backup of /etc/fstab at: $fstab_bak"

    mkdir -p /mnt /media 2>/dev/null || true

    run_as_user gsettings set org.gnome.shell.extensions.gtk4-ding show-volumes false 2>/dev/null || true
    run_as_user gsettings set org.gnome.shell.extensions.gtk4-ding show-network-volumes false 2>/dev/null || true
    run_as_user gsettings set org.gnome.shell.extensions.ding show-volumes false 2>/dev/null || true
    run_as_user gsettings set org.gnome.shell.extensions.ding show-network-volumes false 2>/dev/null || true

    local configured_count=0
    local purged_count=0

    while IFS= read -r dev_pair; do
        local dev_name="" dev_type="" dev_fstype="" dev_label="" dev_uuid="" dev_rm="" dev_parttype="" dev_partlabel=""

        [[ "$dev_pair" =~ NAME=\"([^\"]*)\" ]] && dev_name="${BASH_REMATCH[1]}"
        [[ "$dev_pair" =~ TYPE=\"([^\"]*)\" ]] && dev_type="${BASH_REMATCH[1]}"
        [[ "$dev_pair" =~ FSTYPE=\"([^\"]*)\" ]] && dev_fstype="${BASH_REMATCH[1]}"
        [[ "$dev_pair" =~ LABEL=\"([^\"]*)\" ]] && dev_label="${BASH_REMATCH[1]}"
        [[ "$dev_pair" =~ UUID=\"([^\"]*)\" ]] && dev_uuid="${BASH_REMATCH[1]}"
        [[ "$dev_pair" =~ RM=\"([^\"]*)\" ]] && dev_rm="${BASH_REMATCH[1]}"
        [[ "$dev_pair" =~ PARTTYPE=\"([^\"]*)\" ]] && dev_parttype="${BASH_REMATCH[1]}"
        [[ "$dev_pair" =~ PARTLABEL=\"([^\"]*)\" ]] && dev_partlabel="${BASH_REMATCH[1]}"

        [[ -z "$dev_uuid" ]] && continue
        [[ "$dev_type" != "part" && "$dev_type" != "crypt" ]] && continue
        [[ -z "$dev_fstype" || "$dev_fstype" == "swap" ]] && continue
        [[ "$dev_rm" == "1" ]] && continue

        local combined_tags="${dev_label} ${dev_partlabel}"

        # 1. DETECT SENSITIVE / RECOVERY PARTITIONS
        local is_sensitive=false
        if [[ "${dev_parttype,,}" =~ ^(de94bba4-06d1-4d40-a16a-bfd50179d6ac|e3c9e316-0b5c-4db8-817d-f92df00215ae|c12a7328-f81f-11d2-ba4b-00a0c93ec93b|21686148-6449-6e6f-744e-656564454649)$ ]]; then
            is_sensitive=true
        fi
        if [[ "${combined_tags,,}" =~ (recovery|winre|dell|diag|support|pbr|restore|efi[ _]system|system[ _]reserved|esp|boot|msr) ]]; then
            is_sensitive=true
        fi

        # 2. ACTIVE SCRUBBING: Remove sensitive recovery partitions from fstab & unmount them
        if [[ "$is_sensitive" == "true" ]]; then
            if grep -qi "$dev_uuid" /etc/fstab && grep -E "$dev_uuid" /etc/fstab | grep -q "/boot/efi"; then
                continue
            fi

            if grep -qi "$dev_uuid" /etc/fstab || findmnt -n -S "UUID=$dev_uuid" &>/dev/null; then
                log_warn "Active Scrubbing: Removing sensitive/recovery partition ($dev_name / ${dev_label:-OEM})..."
                umount "UUID=$dev_uuid" 2>/dev/null || true
                sed -i "/$dev_uuid/d" /etc/fstab
                rm -rf "/mnt/${dev_label}" "/media/${dev_label}" 2>/dev/null || true
                ((purged_count++))
            fi
            continue
        fi

        # 3. Protect core Linux system partitions already in fstab (Root, Home, etc.)
        if grep -qi "$dev_uuid" /etc/fstab; then
            continue
        fi

        # 4. CONFIGURE VALID DATA PARTITIONS (e.g. win11, my-data)
        local dev_path="/dev/$dev_name"
        local label="$dev_label"
        [[ -z "$label" || "$label" == "-" ]] && label=$(blkid -s LABEL -o value "$dev_path" 2>/dev/null || true)
        
        if [[ -z "$label" && "$dev_fstype" == "ntfs" ]]; then
            label="Windows-C"
        elif [[ -z "$label" ]]; then
            label="disk-${dev_uuid:0:8}"
        fi

        local clean_label
        clean_label=$(echo "$label" | tr ' /' '_-' | tr -cd '[:alnum:]_.-')
        local mount_point="/mnt/$clean_label"
        local encoded_label
        encoded_label=$(echo "$label" | sed 's/ /%20/g')

        log_info "Configuring permanent data partition: ${BOLD}$dev_name${NC} [Label: ${CYAN}$label${NC}, FS: $dev_fstype]"

        local user_mounts
        user_mounts=$(findmnt -n -l -o TARGET -S "UUID=$dev_uuid" 2>/dev/null | grep -E "^/run/media/" || true)
        if [[ -n "$user_mounts" ]]; then
            while IFS= read -r um_path; do
                [[ -n "$um_path" ]] && umount "$um_path" 2>/dev/null || true
            done <<< "$user_mounts"
        fi

        local fs_driver="$dev_fstype"
        local fs_opts="defaults,noatime,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
        local pass_val=0

        case "$dev_fstype" in
            btrfs)
                fs_opts="defaults,noatime,compress=zstd,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
                ;;
            ntfs)
                if modprobe ntfs3 2>/dev/null || lsmod | grep -q "^ntfs3"; then
                    fs_driver="ntfs3"
                else
                    fs_driver="ntfs-3g"
                fi
                fs_opts="defaults,noatime,uid=${USER_UID},gid=${USER_UID},umask=022,nofail,windows_names,x-gvfs-show,x-gvfs-name=${encoded_label}"
                ;;
            vfat|exfat)
                fs_opts="defaults,noatime,uid=${USER_UID},gid=${USER_UID},umask=022,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
                ;;
            ext[234])
                pass_val=2
                ;;
        esac

        mkdir -p "$mount_point"

        [[ -n "$(tail -c1 /etc/fstab 2>/dev/null)" ]] && echo "" >> /etc/fstab
        printf "UUID=%-36s %-20s %-8s %-75s 0 %d\n" \
            "$dev_uuid" "$mount_point" "$fs_driver" "$fs_opts" "$pass_val" >> /etc/fstab

        if ! findmnt -n "$mount_point" &>/dev/null; then
            mount "$mount_point" 2>/dev/null || mount -t "$fs_driver" -o "$fs_opts" "UUID=$dev_uuid" "$mount_point" 2>/dev/null || true
        fi

        if findmnt -n "$mount_point" &>/dev/null; then
            log_ok "Mounted $dev_name at $mount_point (accessible in Files, hidden from desktop wallpaper)."
        fi

        ((configured_count++))
    done < <(lsblk -Pno NAME,TYPE,FSTYPE,LABEL,UUID,RM,PARTTYPE,PARTLABEL)

    systemctl daemon-reload 2>/dev/null || true
    log_ok "Partition sync complete: $configured_count valid data partition(s) active, $purged_count recovery/OEM partition(s) purged."
}

# ------------------------------------------------------------------------------
# 7. SUBMENU: DESKTOP & GNOME UI SETTINGS
# ------------------------------------------------------------------------------
menu_desktop_settings() {
    while true; do
        local di_raw di_st hc_raw hc_st
        di_raw=$(get_desktop_icons_status)
        hc_raw=$(get_hot_corner_status)

        [[ "$di_raw" == "enabled" ]] && di_st="${GREEN}[Enabled (Files Only)]${NC}" || di_st="${RED}[Disabled]${NC}"
        [[ "$hc_raw" == "enabled" ]] && hc_st="${RED}[Enabled]${NC}" || hc_st="${GREEN}[Disabled (Recommended)]${NC}"

        echo ""
        echo -e "${BOLD}========================================================================${NC}"
        echo -e "${BOLD}                    DESKTOP & GNOME UI SETTINGS                         ${NC}"
        echo -e "${BOLD}========================================================================${NC}"
        echo -e " 1) Desktop Files & Folders      $di_st"
        echo -e " 2) Top-Left Hot Corner          $hc_st"
        echo -e " 3) Apply Recommended Preset (Desktop Files ON, Drive Icons OFF, Hot Corner OFF)"
        echo -e " 4) Configure Windows Partitions (Exclude Recovery/OEM, Mount C:)"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " B) Back to Main Menu"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Select an option (1-4 / B): " choice

        case "$choice" in
            1)
                [[ "$di_raw" == "enabled" ]] && configure_desktop_icons disable || configure_desktop_icons enable
                read -rp "Press [Enter] to continue..."
                ;;
            2)
                [[ "$hc_raw" == "enabled" ]] && configure_hot_corner disable || configure_hot_corner enable
                read -rp "Press [Enter] to continue..."
                ;;
            3)
                configure_desktop_icons enable
                configure_hot_corner disable
                log_ok "Recommended preset applied."
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
    echo -e " ${BOLD}1)${NC} Optimize the system (Timeshift, Kernel Check, Full AUR/Repo Sync, SSD TRIM)"
    echo -e " ${BOLD}2)${NC} Install apps"
    echo -e " ${BOLD}3)${NC} Uninstall apps"
    echo -e " ${BOLD}4)${NC} Desktop UI & Settings"
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
            log_ok "Exiting. Session completed successfully!"
            break
            ;;
        *)
            log_warn "Invalid option. Please enter a number from 1 to 5."
            ;;
    esac
done