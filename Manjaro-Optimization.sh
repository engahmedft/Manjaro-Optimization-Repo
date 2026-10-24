#!/usr/bin/env bash
# ==============================================================================
# Manjaro Modular Optimizer, System Maintainer & Software Hub (v9.5 - Complete)
# Target: Dell Inspiron 7706 | GNOME Wayland | RustDesk | Full AUR & Kernel Sync
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

# Rotate log file if it exceeds 5MB to keep it performant
if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0) -gt 5000000 ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
fi

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

# Session-wide snapshot guard (ensures only 1 restore point is created per script run)
SESSION_SNAPSHOT_TAKEN=false

timestamp() { printf '%(%Y-%m-%d %H:%M:%S)T' -1; }
log_info()    { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[0;34m[INFO]\033[0m %b\n' -1 "$1"; }
log_ok()      { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[0;32m[OK]\033[0m %b\n' -1 "$1"; }
log_warn()    { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[1;33m[WARN]\033[0m %b\n' -1 "$1"; }
log_error()   { printf '[%(%Y-%m-%d %H:%M:%S)T] \033[0;31m[ERROR]\033[0m %b\n' -1 "$1"; }

check_pacman_lock() {
    if [[ -f /var/lib/pacman/db.lck ]]; then
        if ! fuser /var/lib/pacman/db.lck &>/dev/null; then
            log_warn "Detected stale pacman lock file (/var/lib/pacman/db.lck). Auto-clearing..."
            rm -f /var/lib/pacman/db.lck
        else
            log_error "Another package manager is currently running. Please wait for it to complete."
            return 1
        fi
    fi
    return 0
}

is_pkg_installed() {
    pacman -Q "$1" &>/dev/null
}

is_bin_installed() { 
    command -v "$1" &>/dev/null || \
    [[ -x "$USER_HOME/.local/bin/$1" ]] || \
    [[ -x "/usr/bin/$1" ]] || [[ -x "/usr/local/bin/$1" ]]
}

sync_grub_snapshots() {
    log_info "Synchronizing Timeshift snapshots with GRUB boot menu..."
    # If grub.cfg already contains snapshots submenu hook, regenerating 41_snapshots-btrfs is instantaneous (<0.2s)
    if grep -q "snapshots-btrfs" /boot/grub/grub.cfg 2>/dev/null; then
        if [[ -x /etc/grub.d/41_snapshots-btrfs ]]; then
            /etc/grub.d/41_snapshots-btrfs > /dev/null 2>&1 || true
        fi
    else
        # Full generation needed only once to register submenu in grub.cfg
        if command -v update-grub &>/dev/null; then
            update-grub > /dev/null 2>&1 || true
        elif command -v grub-mkconfig &>/dev/null; then
            grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1 || true
        fi
    fi
    log_ok "GRUB boot menu snapshots synchronized."
}

ensure_session_snapshot() {
    local reason="${1:-Before System Modification}"
    if [[ "$SESSION_SNAPSHOT_TAKEN" == "true" ]]; then
        log_info "Timeshift snapshot already created during this session. Skipping duplicate snapshot."
        return 0
    fi

    log_info "Creating one-time Timeshift system restore point ($reason)..."
    if ! is_pkg_installed timeshift; then
        pacman -S --needed --noconfirm timeshift > /dev/null 2>&1 || true
    fi

    if timeshift --create --comments "$reason" --tags O > /dev/null 2>&1; then
        SESSION_SNAPSHOT_TAKEN=true
        log_ok "Timeshift restore point created successfully."
        sync_grub_snapshots
    else
        SESSION_SNAPSHOT_TAKEN=true
        log_warn "Timeshift snapshot skipped (run Timeshift GUI once to configure disk if needed)."
    fi
}

configure_grub_boot_enhancements() {
    log_info "Configuring GRUB shutdown menu entries & automated snapshot daemon..."

    # 1. Add Shutdown & Reboot entries to /etc/grub.d/40_custom
    local custom_grub="/etc/grub.d/40_custom"
    if [[ -f "$custom_grub" ]]; then
        if ! grep -qiE "menuentry.*(Shutdown|Power Off)" "$custom_grub"; then
            log_info "Adding Shutdown and Restart entries to $custom_grub..."
            cat << 'EOF' >> "$custom_grub"

menuentry "Shutdown / Power Off" --class shutdown --class poweroff {
    echo "Shutting down system..."
    halt
}

menuentry "Restart / Reboot" --class restart --class reboot {
    echo "Restarting system..."
    reboot
}
EOF
            chmod +x "$custom_grub" 2>/dev/null || true
            log_ok "GRUB Shutdown and Restart menu entries installed."
        else
            log_ok "GRUB Shutdown entry already present in $custom_grub."
        fi
    fi

    # 2. Ensure grub-btrfs and inotify-tools are installed for grub-btrfsd daemon
    if ! is_pkg_installed grub-btrfs || ! is_pkg_installed inotify-tools; then
        log_info "Installing grub-btrfs and inotify-tools for real-time GRUB snapshot synchronization..."
        pacman -S --needed --noconfirm grub-btrfs inotify-tools > /dev/null 2>&1 || true
    fi

    # 3. Deploy systemd override for grub-btrfsd to watch Timeshift snapshots
    mkdir -p /etc/systemd/system/grub-btrfsd.service.d
    cat << 'EOF' > /etc/systemd/system/grub-btrfsd.service.d/timeshift-auto.conf
[Service]
ExecStart=
ExecStart=/usr/bin/grub-btrfsd --syslog --timeshift-auto
EOF
    systemctl daemon-reload > /dev/null 2>&1 || true
    systemctl enable --now grub-btrfsd.service > /dev/null 2>&1 || true
    systemctl restart grub-btrfsd.service > /dev/null 2>&1 || true
    log_ok "Timeshift automated snapshot synchronization daemon (grub-btrfsd) active."
}

configure_grub_dual_boot() {
    log_info "Configuring dual-boot GRUB (menu visible, 10s timeout, shutdown menu, snapshot sync)..."
    pacman -S --needed --noconfirm os-prober grub-btrfs inotify-tools > /dev/null 2>&1 || true

    # Unconditionally configure GRUB for dual-boot visibility
    sed -i '/GRUB_DISABLE_OS_PROBER/d' /etc/default/grub
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub

    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=10/' /etc/default/grub
    sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
    sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub

    # Ensure Intel GuC/HuC is enabled on kernel command line for Tiger Lake
    if ! grep -q "i915.enable_guc=3" /etc/default/grub; then
        sed -i -E "s/GRUB_CMDLINE_LINUX_DEFAULT=(['\"])/GRUB_CMDLINE_LINUX_DEFAULT=\1i915.enable_guc=3 /" /etc/default/grub
    fi

    # Configure GRUB boot enhancements (Shutdown & Reboot menu entries, grub-btrfsd daemon with timeshift-auto)
    configure_grub_boot_enhancements

    # Regenerate grub.cfg in a single pass to compile settings, shutdown entries, and snapshots submenu
    if command -v update-grub &>/dev/null; then
        update-grub > /dev/null 2>&1 || true
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg > /dev/null 2>&1 || true
    fi
    log_ok "GRUB dual-boot configuration updated."
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
            # Optimize makepkg to utilize all CPU threads (i7-1165G7 8 threads)
            sed -i 's/^#*MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' "$conf"
            # Enable multi-threaded zstd package compression for rapid AUR building
            sed -i 's/^COMPRESSZST=(zstd -c -z -q -)/COMPRESSZST=(zstd -c -z -q --threads=0 -)/' "$conf"
        fi
    done

    sed -i 's/^#*ParallelDownloads = .*/ParallelDownloads = 5/' /etc/pacman.conf 2>/dev/null || true
}
init_downloads

safe_pacman_remove() {
    check_pacman_lock || return 1
    local to_remove=()
    for pkg in "$@"; do
        if is_pkg_installed "$pkg"; then
            to_remove+=("$pkg")
        fi
    done
    if [[ ${#to_remove[@]} -gt 0 ]]; then
        log_info "Removing installed packages: ${to_remove[*]}"
        if ! pacman -Rns --noconfirm "${to_remove[@]}"; then
            log_warn "Batch removal failed, attempting package-by-package removal..."
            for pkg in "${to_remove[@]}"; do
                if is_pkg_installed "$pkg"; then
                    pacman -Rns --noconfirm "$pkg" || log_warn "Could not remove $pkg (it may have reverse dependencies or already be removed)."
                fi
            done
        fi
    else
        log_info "None of the specified packages are currently installed."
    fi
}

post_install_hook() {
    log_info "Running post-install setup (syncing PATH across shells & environment)..."
    for rc in "$USER_HOME/.zshrc" "$USER_HOME/.bashrc"; do
        if [[ -f "$rc" ]] && ! grep -q '\.local/bin' "$rc"; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
            chown "$REAL_USER:" "$rc"
        fi
    done

    # Ensure system-wide PATH for GUI sessions and all shells
    cat << 'EOF' > /etc/profile.d/user-local-bin.sh
if [ -d "$HOME/.local/bin" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
fi
EOF
    chmod 644 /etc/profile.d/user-local-bin.sh 2>/dev/null || true

    # Synchronize GNOME desktop applications database immediately
    update-desktop-database /usr/share/applications 2>/dev/null || true
    update-desktop-database "$USER_HOME/.local/share/applications" 2>/dev/null || true
    log_ok "PATH and application launcher shortcuts synchronized."
}

post_uninstall_hook() {
    log_info "Running post-uninstall cleanup..."
    flatpak uninstall --unused -y > /dev/null 2>&1 || true
    
    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null || true)
    if [[ -n "$orphans" ]]; then
        pacman -Rns --noconfirm $orphans > /dev/null 2>&1 || true
    fi

    # Refresh desktop database to remove stale application launcher icons immediately
    update-desktop-database /usr/share/applications 2>/dev/null || true
    update-desktop-database "$USER_HOME/.local/share/applications" 2>/dev/null || true
    log_ok "Orphaned packages, desktop icons, and unused runtimes cleared."
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

configure_dock_favorites() {
    log_info "Configuring workflow-sorted GNOME Dock favorites..."
    local sorted_favorites=(
        "org.manjaro.pamac.manager.desktop"
        "timeshift-gtk.desktop"
        "org.gnome.SystemMonitor.desktop"
        "org.gnome.Nautilus.desktop"
        "org.gnome.TextEditor.desktop"
        "org.gnome.Console.desktop"
        "google-chrome.desktop"
        "antigravity.desktop"
        "antigravity-ide.desktop"
        "com.microsoft.VSCode.desktop"
        "rustdesk.desktop"
    )

    local gv_str="["
    for idx in "${!sorted_favorites[@]}"; do
        local app="${sorted_favorites[$idx]}"
        if [[ $idx -gt 0 ]]; then
            gv_str+=", "
        fi
        gv_str+="'${app}'"
    done
    gv_str+="]"

    run_as_user gsettings set org.gnome.shell favorite-apps "$gv_str" 2>/dev/null || true
    log_ok "GNOME Dock favorites updated and sorted by workflow (System -> Productivity -> Dev/AI -> Remote)."
}

# ------------------------------------------------------------------------------
# 1. SYSTEM OPTIMIZATION ROUTINE (Includes AUR & Kernel Lifecycle Checks)
# ------------------------------------------------------------------------------
optimize_system() {
    echo ""
    log_info "=== STARTING FULL SYSTEM OPTIMIZATION ==="

    log_info "1/13: Checking Timeshift & creating system restore point..."
    ensure_session_snapshot "Before System Optimization"

    log_info "2/13: Ensuring download accelerator and pacman formatting..."
    init_downloads
    sed -i 's/^#*Color/Color/' /etc/pacman.conf
    if ! grep -q "ILoveCandy" /etc/pacman.conf; then
        sed -i '/# Misc options/a ILoveCandy' /etc/pacman.conf 2>/dev/null || true
    fi

    log_info "3/13: Refreshing fastest mirrors & full system upgrade (Official + AUR)..."
    pacman-mirrors --fasttrack 5
    # Upgrades official packages and all AUR packages (VS Code, Chrome, Antigravity, RustDesk)
    # Pass SKIP_AUTOSNAP=1 to prevent duplicate ALPM hook snapshot right after step 1
    sudo -u "$REAL_USER" env SKIP_AUTOSNAP=1 pamac update --no-confirm --aur

    log_info "4/13: Checking Linux Kernel Lifecycle & Stability..."
    local running_ver
    running_ver=$(uname -r)
    local k_major k_minor
    k_major=$(echo "$running_ver" | cut -d. -f1)
    k_minor=$(echo "$running_ver" | cut -d. -f2)
    log_info "Active kernel: $running_ver"

    # Check installed kernels and ensure an LTS safety branch (like linux612 or linux66) is available
    local installed_kernels
    installed_kernels=$(mhwd-kernel -li 2>/dev/null || true)
    if ! echo "$installed_kernels" | grep -qE "linux612|linux66"; then
        log_warn "Only rolling kernel branch detected. For dual-boot resilience, an LTS fallback is recommended."
        mhwd-kernel -i linux612 || log_warn "LTS fallback kernel installation deferred. Continuing with $running_ver."
    else
        log_ok "Reliable fallback LTS kernel series verified."
    fi

    # Microcode Hygiene: Remove redundant amd-ucode on this Intel Tiger Lake system
    if is_pkg_installed amd-ucode; then
        log_info "Removing redundant amd-ucode package on Intel hardware..."
        pacman -R --noconfirm amd-ucode 2>/dev/null || true
    fi

    log_info "5/13: Enforcing en_US locale and formatting..."
    if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
        sed -i 's/^#*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        locale-gen > /dev/null 2>&1 || true
    fi
    localectl set-locale LANG=en_US.UTF-8 LC_TIME=en_US.UTF-8 LC_NUMERIC=en_US.UTF-8 LC_MONETARY=en_US.UTF-8 LC_MEASUREMENT=en_US.UTF-8 > /dev/null 2>&1 || true
    localectl set-keymap us > /dev/null 2>&1 || true
    run_as_user gsettings set org.gnome.system.locale region 'en_US.UTF-8' 2>/dev/null || true

    log_info "6/13: Configuring dual-boot GRUB (menu visible, 10s timeout, shutdown menu, snapshot sync) & LocalRTC..."
    configure_grub_dual_boot

    if [[ $(timedatectl show --property=LocalRTC --value) != "yes" ]]; then
        timedatectl set-local-rtc 1 --adjust-system-clock
    fi

    log_info "7/13: Applying Btrfs NVMe 'noatime,discard=async' mount optimization & labeling system partition..."
    if grep -E "btrfs.*compress=zstd" /etc/fstab | grep -qv "discard=async"; then
        sed -i 's/compress=zstd:1/noatime,discard=async,compress=zstd:1/g' /etc/fstab
        sed -i 's/defaults,noatime,noatime/defaults,noatime/g' /etc/fstab
        sed -i 's/defaults,noatime,compress=zstd/defaults,noatime,discard=async,compress=zstd/g' /etc/fstab
        mount -o remount / 2>/dev/null || true
        mount -o remount /home 2>/dev/null || true
        mount -o remount /var/cache 2>/dev/null || true
        mount -o remount /var/log 2>/dev/null || true
        mount -o remount /mnt/my-data 2>/dev/null || true
        log_ok "Btrfs subvolumes remounted with noatime and discard=async."
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

    log_info "10/13: Tuning kernel sysctl parameters for 32GB RAM, DRAM-less SSD, ZRAM & Inotify Watches..."
    cat << 'EOF' > /etc/sysctl.d/99-dell-perf.conf
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.dirty_background_bytes = 134217728
vm.dirty_bytes = 536870912
vm.page-cluster = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
fs.file-max = 2097152
EOF
    sysctl --system > /dev/null 2>&1 || true
    log_ok "Kernel sysctl parameters applied."

    log_info "11/13: Enabling Intel GuC/HuC early KMS, RTKit audio priority, thermald & biometrics..."
    cat << 'EOF' > /etc/modprobe.d/i915.conf
options i915 enable_guc=3
EOF
    sed -i 's/^#*RuntimeWatchdogSec=.*/RuntimeWatchdogSec=off/' /etc/systemd/system.conf 2>/dev/null || true

    # Add i915 to mkinitcpio MODULES for early KMS if not present
    if ! grep -E "^MODULES=.*i915" /etc/mkinitcpio.conf >/dev/null 2>&1; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 i915)/' /etc/mkinitcpio.conf
        sed -i 's/MODULES=( /MODULES=(/' /etc/mkinitcpio.conf
        mkinitcpio -P > /dev/null 2>&1 || true
    fi

    pacman -S --needed --noconfirm intel-media-driver libva-utils thermald rtkit pacman-contrib git base-devel > /dev/null 2>&1 || true
    systemctl enable --now thermald.service > /dev/null 2>&1 || true
    systemctl enable --now rtkit-daemon.service > /dev/null 2>&1 || true
    systemctl enable --now power-profiles-daemon.service > /dev/null 2>&1 || true
    systemctl enable --now fstrim.timer > /dev/null 2>&1 || true
    systemctl enable --now paccache.timer > /dev/null 2>&1 || true

    # Optimize NVMe SSD read-ahead (256KB) for faster sequential reads & project indexing
    echo 'ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/read_ahead_kb}="256"' > /etc/udev/rules.d/60-nvme-readahead.rules
    udevadm control --reload-rules && udevadm trigger --subsystem-match=block 2>/dev/null || true

    # Check and configure Goodix 27c6:538d fingerprint sensor
    if lsusb | grep -qi "27c6:538d"; then
        log_info "Goodix 27c6:538d sensor detected. Ensuring driver & service..."
        configure_goodix_fingerprint noninteractive
    fi

    log_info "12/13: Enabling Desktop Icons, Disabling Top-Left Hot Corner & Sorting Dock Favorites..."
    configure_desktop_icons enable
    configure_hot_corner disable
    configure_dock_favorites

    log_info "13/13: Performing Deep System Clutter Cleanup & SSD Health Maintenance..."
    rm -rf /var/tmp/pamac-build-* /var/tmp/pamac-*
    sudo -u "$REAL_USER" rm -rf "$USER_HOME/.cache/pamac" 2>/dev/null || true
    paccache -r -k 2 > /dev/null 2>&1 || true
    journalctl --vacuum-size=100M --vacuum-time=2weeks > /dev/null 2>&1 || true
    
    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null || true)
    [[ -n "$orphans" ]] && pacman -Rns --noconfirm $orphans > /dev/null 2>&1 || true

    log_info "Executing SSD TRIM pass..."
    local trim_output trim_status=0
    trim_output=$(fstrim -va 2>&1) || trim_status=$?
    if [[ $trim_status -eq 0 ]]; then
        log_ok "SSD TRIM pass completed successfully."
    else
        log_warn "SSD TRIM encountered an issue:\n$trim_output"
        if echo "$trim_output" | grep -qi "FITRIM ioctl failed"; then
            log_warn "Btrfs free space cache discrepancy detected on data partition."
            log_info "Refreshing Btrfs free space tree on /mnt/my-data..."
            btrfs balance start -dusage=0 /mnt/my-data 2>/dev/null || true
        fi
    fi

    log_ok "Optimization complete! OS, AUR, kernel, and hardware settings are updated."
    read -rp "Press [Enter] to return to the main menu..."
}

# ------------------------------------------------------------------------------
# 2. APP INSTALL FUNCTIONS
# ------------------------------------------------------------------------------
install_podman() {
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && is_bin_installed podman; then
        log_ok "Podman is already installed. Skipping package installation."
        return 0
    fi
    ensure_session_snapshot "Before Installing Podman"
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
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && is_pkg_installed virt-manager; then
        log_ok "KVM / QEMU Virt-Manager is already installed. Skipping package installation."
        return 0
    fi
    ensure_session_snapshot "Before Installing KVM Virt-Manager"
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

install_vscode_extensions() {
    if ! is_pkg_installed visual-studio-code-bin && ! is_bin_installed code; then
        log_warn "VS Code is not installed. Please install VS Code first."
        return 1
    fi

    log_info "Installing & verifying VS Code curated developer extension suite..."
    local vscode_extensions=(
        "hediet.vscode-drawio"
        "SimonSiefke.svg-preview"
        "kisstkondoros.vscode-gutter-preview"
        "huachao.audio-player"
        "mkloubert.vs-media-player"
        "usernamehw.errorlens"
        "esbenp.prettier-vscode"
        "mhutchie.git-graph"
        "rangav.vscode-thunder-client"
        "PKief.material-icon-theme"
        "cweijan.vscode-office"
        "Google.google-antigravity"
        "HookyQR.minify"
        "bennycode.sort-everything"
        "heaths.vscode-guid"
        "GitHub.remotehub"
        "ms-dotnettools.csdevkit"
        "moshfeu.compare-folders"
    )

    for ext in "${vscode_extensions[@]}"; do
        log_info "Syncing VS Code extension: ${CYAN}${ext}${NC}..."
        sudo -u "$REAL_USER" code --install-extension "$ext" --force >/dev/null 2>&1 || true
    done
    log_ok "All specified VS Code extensions installed and verified."
}

install_vscode() {
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && (is_pkg_installed visual-studio-code-bin || is_bin_installed code); then
        log_ok "VS Code is already installed. Skipping package build."
    else
        ensure_session_snapshot "Before Installing VS Code"
        log_info "Installing VS Code..."
        pamac enable-aur > /dev/null 2>&1 || true
        sudo -u "$REAL_USER" pamac build --no-confirm visual-studio-code-bin
    fi

    # Install the curated extension suite
    install_vscode_extensions

    # Configure native Wayland and fractional scaling crispness
    mkdir -p "$USER_HOME/.config"
    cat << 'EOF' > "$USER_HOME/.config/code-flags.conf"
--ozone-platform-hint=auto
--enable-features=WaylandWindowDecorations
EOF
    chown "$REAL_USER:" "$USER_HOME/.config/code-flags.conf" 2>/dev/null || true

    log_ok "VS Code ready with native Wayland flags."
    post_install_hook
}

install_antigravity_ide() {
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && is_pkg_installed antigravity-ide; then
        log_ok "Antigravity IDE is already installed. Skipping package build."
        return 0
    fi
    ensure_session_snapshot "Before Installing Antigravity IDE"
    log_info "Installing Antigravity IDE..."
    pamac enable-aur > /dev/null 2>&1 || true
    sudo -u "$REAL_USER" pamac build --no-confirm antigravity-ide || {
        sudo -u "$REAL_USER" bash -c 'curl -fsSL https://antigravity.google/install-ide.sh | bash' || true
    }
    log_ok "Antigravity IDE ready."
    post_install_hook
}

install_antigravity_standalone() {
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && (is_pkg_installed antigravity || is_bin_installed agy); then
        log_ok "Antigravity 2.0 Platform & CLI is already installed. Skipping package build."
        return 0
    fi
    ensure_session_snapshot "Before Installing Antigravity 2.0"
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
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && is_pkg_installed google-chrome; then
        log_ok "Google Chrome is already installed. Skipping package build."
    else
        ensure_session_snapshot "Before Installing Google Chrome"
        log_info "Installing Google Chrome..."
        pamac enable-aur > /dev/null 2>&1 || true
        sudo -u "$REAL_USER" pamac build --no-confirm google-chrome
        [[ -x /usr/bin/google-chrome-stable ]] && ln -sf /usr/bin/google-chrome-stable /usr/bin/google-chrome 2>/dev/null || true
    fi

    # Automatically configure Wayland and Intel Iris Xe VA-API GPU video decoding
    mkdir -p "$USER_HOME/.config"
    cat << 'EOF' > "$USER_HOME/.config/chrome-flags.conf"
--ozone-platform-hint=auto
--enable-features=VaapiVideoDecodeLinuxGL,VaapiVideoEncoder
--ignore-gpu-blocklist
--enable-zero-copy
EOF
    chown "$REAL_USER:" "$USER_HOME/.config/chrome-flags.conf" 2>/dev/null || true

    log_ok "Google Chrome installed with native Wayland & VA-API acceleration flags."
    post_install_hook
}

install_office() {
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && is_pkg_installed libreoffice-fresh; then
        log_ok "LibreOffice Fresh is already installed. Skipping package installation."
        return 0
    fi
    ensure_session_snapshot "Before Installing LibreOffice"
    log_info "Installing LibreOffice Fresh..."
    pacman -S --needed --noconfirm libreoffice-fresh
    log_ok "LibreOffice installed."
    post_install_hook
}

install_media() {
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && is_pkg_installed gimp && is_pkg_installed vlc; then
        log_ok "Multimedia Suite is already installed. Skipping package installation."
        return 0
    fi
    ensure_session_snapshot "Before Installing Multimedia Suite"
    log_info "Installing Essential Multimedia Suite..."
    pacman -S --needed --noconfirm vlc celluloid gimp kdenlive
    log_ok "Multimedia suite installed."
    post_install_hook
}

install_rustdesk() {
    local mode="${1:-install}"
    if [[ "$mode" != "reinstall" ]] && (is_pkg_installed rustdesk-bin || is_pkg_installed rustdesk || is_bin_installed rustdesk); then
        log_ok "RustDesk Remote Desktop is already installed. Skipping package build."
    else
        ensure_session_snapshot "Before Installing RustDesk Remote Desktop"
        log_info "Installing RustDesk Remote Desktop (Wayland / Intel VA-API Optimized)..."

        pamac enable-aur > /dev/null 2>&1 || true
        sudo -u "$REAL_USER" pamac build --no-confirm rustdesk-bin || sudo -u "$REAL_USER" pamac build --no-confirm rustdesk
    fi

    # Grant user permission to uinput & video for Wayland input injection and VA-API hardware acceleration
    usermod -aG input,video "$REAL_USER"
    echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' > /etc/udev/rules.d/85-rustdesk-uinput.rules
    udevadm control --reload-rules && udevadm trigger

    # Optimize RustDesk systemd service for Intel Iris Xe VA-API hardware encoding and Wayland low latency
    mkdir -p /etc/systemd/system/rustdesk.service.d
    cat << 'EOF' > /etc/systemd/system/rustdesk.service.d/intel-vaapi.conf
[Service]
Environment="LIBVA_DRIVER_NAME=iHD"
Environment="MESA_LOADER_DRIVER_OVERRIDE=iris"
Environment="GST_VAAPI_ALL_DRIVERS=1"
EOF

    systemctl daemon-reload
    systemctl enable --now rustdesk.service 2>/dev/null || true

    local r_id
    r_id=$(rustdesk --get-id 2>/dev/null || true)
    if [[ -n "$r_id" ]]; then
        log_ok "RustDesk installed and active! Your RustDesk ID is: ${CYAN}${r_id}${NC}"
    else
        log_ok "RustDesk service is active and listening for incoming connections."
    fi
    post_install_hook
}

install_all_apps() {
    echo ""
    log_info "=== STARTING GROUPED INSTALLATION OF ALL APPS ==="
    ensure_session_snapshot "Before Installing All Applications"

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
    usermod -aG libvirt,kvm,input,video "$REAL_USER"
    virsh net-autostart default > /dev/null 2>&1 || true
    virsh net-start default > /dev/null 2>&1 || true
    echo "options kvm_intel nested=1" > /etc/modprobe.d/kvm-intel.conf

    log_info "2/3. Checking and building required AUR packages..."
    pamac enable-aur > /dev/null 2>&1 || true
    local aur_pkgs=(visual-studio-code-bin antigravity-ide antigravity google-chrome rustdesk-bin)
    local aur_to_build=()
    for pkg in "${aur_pkgs[@]}"; do
        if is_pkg_installed "$pkg"; then
            log_ok "AUR package already installed: $pkg"
        elif [[ "$pkg" == "rustdesk-bin" ]] && is_pkg_installed rustdesk; then
            log_ok "RustDesk already installed (rustdesk)."
        elif [[ "$pkg" == "antigravity" ]] && is_bin_installed agy; then
            log_ok "Antigravity CLI already installed."
        elif [[ "$pkg" == "visual-studio-code-bin" ]] && is_bin_installed code; then
            log_ok "VS Code already installed."
        else
            aur_to_build+=("$pkg")
        fi
    done

    if [[ ${#aur_to_build[@]} -gt 0 ]]; then
        log_info "Building uninstalled AUR packages: ${aur_to_build[*]}..."
        sudo -u "$REAL_USER" pamac build --no-confirm "${aur_to_build[@]}"
    else
        log_ok "All AUR applications are already installed. Skipping package build."
    fi
    install_vscode_extensions
    [[ -x /usr/bin/google-chrome-stable ]] && ln -sf /usr/bin/google-chrome-stable /usr/bin/google-chrome 2>/dev/null || true

    # Configure VS Code native Wayland flags
    mkdir -p "$USER_HOME/.config"
    cat << 'EOF' > "$USER_HOME/.config/code-flags.conf"
--ozone-platform-hint=auto
--enable-features=WaylandWindowDecorations
EOF
    chown "$REAL_USER:" "$USER_HOME/.config/code-flags.conf" 2>/dev/null || true

    # Configure Chrome Wayland & VA-API flags
    mkdir -p "$USER_HOME/.config"
    cat << 'EOF' > "$USER_HOME/.config/chrome-flags.conf"
--ozone-platform-hint=auto
--enable-features=VaapiVideoDecodeLinuxGL,VaapiVideoEncoder
--ignore-gpu-blocklist
--enable-zero-copy
EOF
    chown "$REAL_USER:" "$USER_HOME/.config/chrome-flags.conf" 2>/dev/null || true

    # Configure RustDesk uinput & Intel VA-API hardware encoding
    echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' > /etc/udev/rules.d/85-rustdesk-uinput.rules
    udevadm control --reload-rules && udevadm trigger

    mkdir -p /etc/systemd/system/rustdesk.service.d
    cat << 'EOF' > /etc/systemd/system/rustdesk.service.d/intel-vaapi.conf
[Service]
Environment="LIBVA_DRIVER_NAME=iHD"
Environment="MESA_LOADER_DRIVER_OVERRIDE=iris"
Environment="GST_VAAPI_ALL_DRIVERS=1"
EOF
    systemctl daemon-reload
    systemctl enable --now rustdesk.service 2>/dev/null || true

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
    ensure_session_snapshot "Before Uninstalling Podman"
    log_warn "Removing Podman..."
    safe_pacman_remove podman-docker podman-compose podman
    post_uninstall_hook
}

uninstall_kvm() {
    ensure_session_snapshot "Before Uninstalling KVM Virt-Manager"
    log_warn "Removing KVM Virt-Manager..."
    systemctl disable --now libvirtd.service 2>/dev/null || true
    safe_pacman_remove virt-manager virt-viewer libguestfs
    post_uninstall_hook
}

uninstall_vscode() {
    ensure_session_snapshot "Before Uninstalling VS Code"
    log_warn "Removing VS Code..."
    safe_pacman_remove visual-studio-code-bin
    rm -rf "$USER_HOME/.config/Code" "$USER_HOME/.vscode" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_antigravity_ide() {
    ensure_session_snapshot "Before Uninstalling Antigravity IDE"
    log_warn "Removing Antigravity IDE..."
    safe_pacman_remove antigravity-ide
    rm -rf "$USER_HOME/.antigravity-ide" "$USER_HOME/.config/antigravity-ide" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_antigravity_standalone() {
    ensure_session_snapshot "Before Uninstalling Antigravity 2.0"
    log_warn "Removing Antigravity 2.0 Standalone..."
    safe_pacman_remove antigravity
    rm -rf "$USER_HOME/.local/bin/agy" "$USER_HOME/.antigravity" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_chrome() {
    ensure_session_snapshot "Before Uninstalling Google Chrome"
    log_warn "Removing Google Chrome..."
    safe_pacman_remove google-chrome
    rm -rf "$USER_HOME/.config/google-chrome" "$USER_HOME/.cache/google-chrome" "$USER_HOME/.config/chrome-flags.conf" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_office() {
    ensure_session_snapshot "Before Uninstalling LibreOffice"
    log_warn "Removing LibreOffice..."
    safe_pacman_remove libreoffice-fresh
    rm -rf "$USER_HOME/.config/libreoffice" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_media() {
    ensure_session_snapshot "Before Uninstalling Multimedia Suite"
    log_warn "Removing Multimedia Suite..."
    safe_pacman_remove vlc celluloid gimp kdenlive
    rm -rf "$USER_HOME/.config/GIMP" "$USER_HOME/.config/vlc" 2>/dev/null || true
    post_uninstall_hook
}

uninstall_rustdesk() {
    ensure_session_snapshot "Before Uninstalling RustDesk"
    log_warn "Removing RustDesk Remote Desktop..."
    systemctl disable --now rustdesk.service 2>/dev/null || true
    safe_pacman_remove rustdesk-bin rustdesk
    rm -f /etc/udev/rules.d/85-rustdesk-uinput.rules
    rm -rf /etc/systemd/system/rustdesk.service.d
    rm -rf "$USER_HOME/.config/rustdesk" "$USER_HOME/.local/share/logs/RustDesk" /etc/rustdesk 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    post_uninstall_hook
}

uninstall_all_apps() {
    echo ""
    log_info "=== STARTING GROUPED REMOVAL OF ALL APPS ==="
    ensure_session_snapshot "Before Uninstalling All Applications"

    log_info "1/3. Disabling background virtualization, containers & streaming services..."
    systemctl disable --now libvirtd.service 2>/dev/null || true
    systemctl disable --now rustdesk.service 2>/dev/null || true
    sudo -u "$REAL_USER" env XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user disable --now podman.socket 2>/dev/null || true

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
        rustdesk-bin rustdesk

    log_info "3/3. Wiping user configuration & cache directories..."
    rm -rf "$USER_HOME/.config/Code" "$USER_HOME/.vscode" \
           "$USER_HOME/.antigravity-ide" "$USER_HOME/.config/antigravity-ide" \
           "$USER_HOME/.local/bin/agy" "$USER_HOME/.antigravity" \
           "$USER_HOME/.config/google-chrome" "$USER_HOME/.cache/google-chrome" "$USER_HOME/.config/chrome-flags.conf" \
           "$USER_HOME/.config/libreoffice" \
           "$USER_HOME/.config/GIMP" "$USER_HOME/.config/vlc" \
           "$USER_HOME/.config/rustdesk" \
           "$USER_HOME/.local/share/logs/RustDesk" \
           /etc/rustdesk \
           /etc/udev/rules.d/85-rustdesk-uinput.rules \
           /etc/systemd/system/rustdesk.service.d 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true
    post_uninstall_hook
    log_ok "All selected applications uninstalled."
}

# ------------------------------------------------------------------------------
# 4. SUBMENU: EXTRA APPLICATIONS (INSTALL, REINSTALL & UNINSTALL HUB)
# ------------------------------------------------------------------------------
manage_app_action() {
    local name="$1"
    local is_installed="$2"
    local install_fn="$3"
    local uninstall_fn="$4"

    echo ""
    echo -e "${BOLD}========================================================================${NC}"
    echo -e " Application: ${BOLD}${name}${NC}"
    if [[ "$is_installed" == "true" ]]; then
        echo -e " Status:      ${GREEN}[Installed]${NC}"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " 1) Reinstall / Update Application"
        echo -e " 2) Uninstall Application"
        echo -e " 3) Cancel & Return"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Please select an action (1-3): " act_choice
        case "$act_choice" in
            1)
                $install_fn reinstall
                read -rp "Press [Enter] to continue..."
                ;;
            2)
                $uninstall_fn
                read -rp "Press [Enter] to continue..."
                ;;
            3) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    else
        echo -e " Status:      ${RED}[Not Installed]${NC}"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " 1) Install Application"
        echo -e " 2) Cancel & Return"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Please select an action (1-2): " act_choice
        case "$act_choice" in
            1)
                $install_fn install
                read -rp "Press [Enter] to continue..."
                ;;
            2) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    fi
}

manage_vscode_action() {
    local is_installed="$1"
    echo ""
    echo -e "${BOLD}========================================================================${NC}"
    echo -e " Application: ${BOLD}VS Code (Visual Studio Code)${NC}"
    if [[ "$is_installed" == "true" ]]; then
        echo -e " Status:      ${GREEN}[Installed]${NC}"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " 1) Reinstall / Update VS Code & Full Extension Suite"
        echo -e " 2) Install / Sync Curated Extension Suite Only (18 Extensions)"
        echo -e " 3) Uninstall VS Code"
        echo -e " 4) Cancel & Return"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Please select an action (1-4): " act_choice
        case "$act_choice" in
            1)
                install_vscode reinstall
                read -rp "Press [Enter] to continue..."
                ;;
            2)
                install_vscode_extensions
                read -rp "Press [Enter] to continue..."
                ;;
            3)
                uninstall_vscode
                read -rp "Press [Enter] to continue..."
                ;;
            4) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    else
        echo -e " Status:      ${RED}[Not Installed]${NC}"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " 1) Install VS Code & Full Extension Suite"
        echo -e " 2) Cancel & Return"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Please select an action (1-2): " act_choice
        case "$act_choice" in
            1)
                install_vscode install
                read -rp "Press [Enter] to continue..."
                ;;
            2) return ;;
            *) log_warn "Invalid selection." ;;
        esac
    fi
}

menu_extra_apps() {
    while true; do
        local st_podman st_kvm st_vscode st_ag_ide st_ag_app st_chrome st_office st_media st_rustdesk
        local is_podman=false is_kvm=false is_vscode=false is_ag_ide=false is_ag_app=false
        local is_chrome=false is_office=false is_media=false is_rustdesk=false

        is_bin_installed podman && is_podman=true
        is_pkg_installed virt-manager && is_kvm=true
        is_pkg_installed visual-studio-code-bin && is_vscode=true
        is_pkg_installed antigravity-ide && is_ag_ide=true
        (is_pkg_installed antigravity || is_bin_installed agy) && is_ag_app=true
        is_pkg_installed google-chrome && is_chrome=true
        is_pkg_installed libreoffice-fresh && is_office=true
        (is_pkg_installed gimp || is_pkg_installed vlc) && is_media=true
        (is_pkg_installed rustdesk-bin || is_pkg_installed rustdesk || is_bin_installed rustdesk) && is_rustdesk=true

        st_podman=$([[ "$is_podman" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_kvm=$([[ "$is_kvm" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_vscode=$([[ "$is_vscode" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_ag_ide=$([[ "$is_ag_ide" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_ag_app=$([[ "$is_ag_app" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_chrome=$([[ "$is_chrome" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_office=$([[ "$is_office" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_media=$([[ "$is_media" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")
        st_rustdesk=$([[ "$is_rustdesk" == "true" ]] && echo -e "${GREEN}[Installed]${NC}" || echo -e "${RED}[Not Installed]${NC}")

        echo ""
        echo -e "${BOLD}========================================================================${NC}"
        echo -e "${BOLD}                     EXTRA APPLICATIONS HUB                             ${NC}"
        echo -e "${BOLD}========================================================================${NC}"
        echo -e " 1) Podman Engine & Compose      $st_podman ${CYAN}[OFFICIAL]${NC}"
        echo -e " 2) KVM / QEMU Virt-Manager      $st_kvm ${CYAN}[OFFICIAL]${NC}"
        echo -e " 3) VS Code + Extension Suite   $st_vscode ${CYAN}[OFFICIAL + 18 DEV EXTENSIONS]${NC}"
        echo -e " 4) Antigravity IDE              $st_ag_ide ${CYAN}[OFFICIAL]${NC}"
        echo -e " 5) Antigravity 2.0 Platform     $st_ag_app ${CYAN}[OFFICIAL AUR: antigravity]${NC}"
        echo -e " 6) Google Chrome Browser        $st_chrome ${CYAN}[OFFICIAL]${NC}"
        echo -e " 7) LibreOffice Fresh Suite      $st_office ${CYAN}[OFFICIAL]${NC}"
        echo -e " 8) Essential Multimedia Suite   $st_media ${CYAN}[OFFICIAL]${NC}"
        echo -e " 9) RustDesk Remote Desktop      $st_rustdesk ${CYAN}[WAYLAND / INTEL VA-API]${NC}"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " A) Install ALL Applications"
        echo -e " U) Uninstall ALL Applications"
        echo -e " B) Back to Main Menu"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Select an application (1-9) or action (A / U / B): " choice

        case "$choice" in
            1) manage_app_action "Podman Engine & Compose" "$is_podman" install_podman uninstall_podman ;;
            2) manage_app_action "KVM / QEMU Virt-Manager" "$is_kvm" install_kvm uninstall_kvm ;;
            3) manage_vscode_action "$is_vscode" ;;
            4) manage_app_action "Antigravity IDE" "$is_ag_ide" install_antigravity_ide uninstall_antigravity_ide ;;
            5) manage_app_action "Antigravity 2.0 Platform" "$is_ag_app" install_antigravity_standalone uninstall_antigravity_standalone ;;
            6) manage_app_action "Google Chrome Browser" "$is_chrome" install_chrome uninstall_chrome ;;
            7) manage_app_action "LibreOffice Fresh Suite" "$is_office" install_office uninstall_office ;;
            8) manage_app_action "Essential Multimedia Suite" "$is_media" install_media uninstall_media ;;
            9) manage_app_action "RustDesk Remote Desktop" "$is_rustdesk" install_rustdesk uninstall_rustdesk ;;
            [aA])
                read -rp "Install ALL applications now? (y/N): " a_conf
                if [[ "$a_conf" =~ ^[Yy]$ ]]; then
                    install_all_apps
                    read -rp "Press [Enter] to continue..."
                fi
                ;;
            [uU])
                read -rp "Are you sure you want to uninstall ALL applications? (y/N): " u_conf
                if [[ "$u_conf" =~ ^[Yy]$ ]]; then
                    uninstall_all_apps
                    read -rp "Press [Enter] to continue..."
                fi
                ;;
            [bB]) break ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 5. STORAGE & PERMANENT WINDOWS DATA PARTITION MANAGEMENT (ACTIVE SCRUBBING)
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

        # 3. Protect core Linux system partitions (Root, Home, EFI, etc.)
        local root_uuid
        root_uuid=$(findmnt -n -o UUID / 2>/dev/null || true)
        if [[ "$dev_uuid" == "$root_uuid" ]] || findmnt -n -o TARGET -S "UUID=$dev_uuid" 2>/dev/null | grep -E '^/(home|var|boot|$)' >/dev/null; then
            continue
        fi

        # Upgrade existing NTFS mounts in /etc/fstab from slow FUSE ntfs-3g to fast in-kernel ntfs3
        if grep -qi "$dev_uuid" /etc/fstab; then
            if [[ "$dev_fstype" == "ntfs" ]] && grep -i "$dev_uuid" /etc/fstab | grep -q "ntfs-3g"; then
                if modprobe ntfs3 2>/dev/null || lsmod | grep -q "^ntfs3"; then
                    log_info "Upgrading NTFS partition ($dev_name) in /etc/fstab from FUSE ntfs-3g to fast in-kernel ntfs3..."
                    sed -i "/$dev_uuid/ s/ntfs-3g/ntfs3/" /etc/fstab
                    sed -i "/$dev_uuid/ s/,windows_names/,iocharset=utf8/" /etc/fstab
                    umount "UUID=$dev_uuid" 2>/dev/null || true
                    mount -a 2>/dev/null || true
                    log_ok "Partition $dev_name upgraded to ntfs3."
                fi
            fi
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
                    fs_opts="defaults,noatime,uid=${USER_UID},gid=${USER_UID},umask=022,iocharset=utf8,nofail,x-gvfs-show,x-gvfs-name=${encoded_label}"
                else
                    fs_driver="ntfs-3g"
                    fs_opts="defaults,noatime,uid=${USER_UID},gid=${USER_UID},umask=022,nofail,windows_names,x-gvfs-show,x-gvfs-name=${encoded_label}"
                fi
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

configure_dell_hardware() {
    echo ""
    log_info "=== DELL HARDWARE & FIRMWARE TUNING ==="
    local batt_cfg_path="/sys/class/firmware-attributes/dell-wmi-sysman/attributes/PrimaryBattChargeCfg"
    local custom_start_path="/sys/class/firmware-attributes/dell-wmi-sysman/attributes/CustomChargeStart"
    local custom_stop_path="/sys/class/firmware-attributes/dell-wmi-sysman/attributes/CustomChargeStop"
    local fastboot_path="/sys/class/firmware-attributes/dell-wmi-sysman/attributes/Fastboot"
    local start_thresh
    start_thresh=$(ls /sys/class/power_supply/BAT*/charge_control_start_threshold 2>/dev/null | head -n 1)
    local end_thresh
    end_thresh=$(ls /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null | head -n 1)
    local bat_name="BAT0"
    if [[ -n "$start_thresh" ]]; then
        bat_name=$(basename "$(dirname "$start_thresh")")
    fi

    if [[ -d "$batt_cfg_path" ]]; then
        local cur_batt
        cur_batt=$(cat "$batt_cfg_path/current_value" 2>/dev/null || true)
        echo -e "Current Dell Battery Charging Profile: ${CYAN}${cur_batt:-Unknown}${NC}"
        echo " 1) Primarily AC Use (PrimAcUse) - Best for preserving degraded/AC-connected battery"
        echo " 2) Custom (50% Start, 90% Stop Threshold) - Dell BIOS NVRAM & Sysfs"
        echo " 3) Adaptive / Standard (100% capacity)"
        echo " 4) Keep current setting"
        read -rp "Select battery profile (1-4): " b_choice

        case "$b_choice" in
            1)
                echo "PrimAcUse" > "$batt_cfg_path/current_value" 2>/dev/null || true
                rm -f /etc/tmpfiles.d/battery-threshold.conf 2>/dev/null || true
                log_ok "Dell Battery profile set to Primarily AC Use (PrimAcUse)."
                ;;
            2)
                echo "Custom" > "$batt_cfg_path/current_value" 2>/dev/null || true
                [[ -f "$custom_start_path/current_value" ]] && echo "50" > "$custom_start_path/current_value" 2>/dev/null || true
                [[ -f "$custom_stop_path/current_value" ]] && echo "90" > "$custom_stop_path/current_value" 2>/dev/null || true
                [[ -n "$start_thresh" ]] && echo "50" > "$start_thresh" 2>/dev/null || true
                [[ -n "$end_thresh" ]] && echo "90" > "$end_thresh" 2>/dev/null || true

                # Persist threshold across cold boots via systemd tmpfiles
                mkdir -p /etc/tmpfiles.d
                cat << EOF > /etc/tmpfiles.d/battery-threshold.conf
w /sys/class/power_supply/${bat_name}/charge_control_start_threshold - - - - 50
w /sys/class/power_supply/${bat_name}/charge_control_end_threshold - - - - 90
EOF
                systemd-tmpfiles --create /etc/tmpfiles.d/battery-threshold.conf > /dev/null 2>&1 || true
                log_ok "Battery charge threshold configured: 50% start, 90% stop (Dell BIOS NVRAM & sysfs)."
                ;;
            3)
                echo "Adaptive" > "$batt_cfg_path/current_value" 2>/dev/null || true
                rm -f /etc/tmpfiles.d/battery-threshold.conf 2>/dev/null || true
                log_ok "Dell Battery profile set to Adaptive."
                ;;
            *) log_info "Battery profile unchanged." ;;
        esac
    elif [[ -n "$start_thresh" && -n "$end_thresh" ]]; then
        echo "50" > "$start_thresh" 2>/dev/null || true
        echo "90" > "$end_thresh" 2>/dev/null || true
        mkdir -p /etc/tmpfiles.d
        cat << EOF > /etc/tmpfiles.d/battery-threshold.conf
w /sys/class/power_supply/${bat_name}/charge_control_start_threshold - - - - 50
w /sys/class/power_supply/${bat_name}/charge_control_end_threshold - - - - 90
EOF
        systemd-tmpfiles --create /etc/tmpfiles.d/battery-threshold.conf > /dev/null 2>&1 || true
        log_ok "Battery sysfs threshold configured to 50%-90%."
    else
        log_warn "Dell WMI firmware attributes not exposed on this hardware."
    fi

    if [[ -d "$fastboot_path" ]]; then
        local cur_fb
        cur_fb=$(cat "$fastboot_path/current_value" 2>/dev/null || true)
        echo -e "Current Dell UEFI Fastboot setting: ${CYAN}${cur_fb:-Unknown}${NC}"
        if [[ "$cur_fb" != "Minimal" ]]; then
            echo "Minimal" > "$fastboot_path/current_value" 2>/dev/null || true
            log_ok "Dell Fastboot updated to 'Minimal' to reduce POST boot time."
        else
            log_ok "Dell Fastboot is already set to 'Minimal'."
        fi
    fi
}

update_dell_firmware() {
    echo ""
    log_info "=== DELL UEFI BIOS & HARDWARE FIRMWARE UPDATE ==="

    if ! command -v fwupdmgr &>/dev/null; then
        log_info "Installing fwupd (Linux Vendor Firmware Service manager)..."
        pacman -S --needed --noconfirm fwupd
    fi

    # Check AC power status to protect against flashing on battery
    local on_battery=false
    for ac in /sys/class/power_supply/AC*/online /sys/class/power_supply/ADP*/online; do
        if [[ -f "$ac" ]] && [[ $(cat "$ac" 2>/dev/null) -eq 0 ]]; then
            on_battery=true
        fi
    done

    if [[ "$on_battery" == "true" ]]; then
        log_warn "AC Adapter is currently NOT plugged in!"
        echo -e "${YELLOW}Flashing UEFI BIOS or device firmware requires external AC power to prevent power loss.${NC}"
        read -rp "Please plug in your AC charger, then press [Enter] to continue (or 'q' to cancel): " p_ans
        [[ "$p_ans" =~ ^[Qq]$ ]] && return
    fi

    log_info "Refreshing firmware metadata from LVFS..."
    fwupdmgr refresh --force > /dev/null 2>&1 || true

    log_info "Scanning for available Dell BIOS, TPM, and device firmware updates..."
    local updates_out
    updates_out=$(fwupdmgr get-updates 2>&1 || true)

    if echo "$updates_out" | grep -qiE "No updatable devices|No updates available|No releases found"; then
        log_ok "Your Dell Inspiron 7706 UEFI BIOS & device firmware are fully up to date!"
    else
        echo ""
        echo -e "${CYAN}========================================================================${NC}"
        echo -e "${BOLD}                     AVAILABLE FIRMWARE UPDATES                        ${NC}"
        echo -e "${CYAN}========================================================================${NC}"
        echo "$updates_out" | grep -E "New version|Release ID|Summary|Urgency|Vendor" || echo "$updates_out"
        echo -e "${CYAN}========================================================================${NC}"
        echo ""
        read -rp "Do you want to stage and prepare these firmware updates now? (y/N): " fw_confirm
        if [[ "$fw_confirm" =~ ^[Yy]$ ]]; then
            log_info "Downloading and staging firmware capsule..."
            fwupdmgr update -y
            log_ok "Firmware update staged successfully!"
            log_warn "A system reboot is required to flash the firmware. The Dell logo will show a progress bar during reboot."
        else
            log_info "Firmware update skipped by user."
        fi
    fi
}

maintain_btrfs_storage() {
    echo ""
    log_info "=== BTRFS HEALTH & SSD STORAGE MAINTENANCE ==="
    for mp in "/" "/mnt/my-data"; do
        if findmnt -n -t btrfs "$mp" >/dev/null 2>&1; then
            log_info "Refreshing space allocation on $mp..."
            btrfs filesystem df "$mp" || true
            log_info "Executing block group balance on $mp (usage <= 10%)..."
            btrfs balance start -dusage=10 -musage=10 "$mp" 2>/dev/null || true

            log_info "Auditing NVMe Btrfs hardware health and I/O error stats on $mp..."
            local dev_stats
            dev_stats=$(btrfs device stats "$mp" 2>/dev/null || true)
            if echo "$dev_stats" | grep -v " 0$" | grep -qE "errs"; then
                log_warn "Btrfs detected hardware device errors on $mp:\n$dev_stats"
            else
                log_ok "Btrfs hardware device stats on $mp clean (0 write/read/flush/corruption errors)."
            fi
        fi
    done

    log_info "Executing SSD TRIM pass across all filesystems..."
    local trim_res
    if trim_res=$(fstrim -va 2>&1); then
        log_ok "SSD TRIM completed successfully:\n$trim_res"
    else
        log_warn "SSD TRIM encountered issues:\n$trim_res"
    fi
}

get_fingerprint_status() {
    if ! lsusb | grep -qi "27c6:538d"; then
        echo "not_detected"
        return
    fi
    if is_pkg_installed libfprint-goodix-538d || is_pkg_installed libfprint-goodix-521d || [[ -f /usr/lib/goodix-538d/provision-goodix-538d.py ]]; then
        if find "/var/lib/fprint/$REAL_USER" -type f 2>/dev/null | grep -q . || \
           run_as_user fprintd-list "$REAL_USER" 2>/dev/null | grep -qE "^ - #[0-9]+:"; then
            echo "enrolled"
        else
            echo "installed"
        fi
    else
        echo "uninstalled"
    fi
}

configure_goodix_fingerprint() {
    local mode="${1:-interactive}"
    echo ""
    log_info "=== GOODIX FINGERPRINT SENSOR (27c6:538d) SETUP ==="

    if ! lsusb | grep -qi "27c6:538d"; then
        log_warn "Goodix 27c6:538d sensor not detected on USB bus."
        return 0
    fi
    log_ok "Goodix 27c6:538d sensor verified on USB bus."

    if ! pacman -Qq fprintd &>/dev/null; then
        log_info "Ensuring fprintd daemon is installed..."
        pacman -S --needed --noconfirm fprintd
    fi
    systemctl stop fprintd.service 2>/dev/null || true

    local driver_dir="${SCRIPT_DIR}/drivers/goodix-538d"
    local installed=false

    # Check if driver is already installed (skip rebuild unless explicitly requested)
    if is_pkg_installed libfprint-goodix-538d; then
        log_ok "Goodix 27c6:538d driver (libfprint-goodix-538d) is already installed."
        if [[ "$mode" == "interactive" ]]; then
            echo -e " 1) Manage / Enroll Fingerprints"
            echo -e " 2) Force Reinstall / Recompile Driver"
            echo -e " 3) Return to Menu"
            read -rp "Select an option (1-3): " fp_choice
            case "$fp_choice" in
                1) installed=true ;;
                2) installed=false ;;
                *) return 0 ;;
            esac
        else
            installed=true
        fi
    fi

    # Ensure stock conflicting libfprint is cleanly replaced without breaking fprintd
    clean_stock_libfprint_conflict() {
        if pacman -Qq libfprint &>/dev/null && ! pacman -Qq libfprint-goodix-538d &>/dev/null; then
            log_info "Safely detaching conflicting stock libfprint (preserving fprintd)..."
            pacman -Rdd --noconfirm libfprint 2>/dev/null || true
        fi
    }

    if [[ "$installed" == "false" ]]; then
        # Tier 1: Check precompiled local package cache (.pkg.tar.zst)
        local cached_pkg
        cached_pkg=$(ls -t "$driver_dir"/libfprint-goodix-*.pkg.tar.zst 2>/dev/null | head -n 1 || true)
        if [[ -n "$cached_pkg" && -f "$cached_pkg" ]]; then
            log_info "Tier 1: Installing cached driver package: $(basename "$cached_pkg")..."
            clean_stock_libfprint_conflict
            if pacman -U --overwrite '*' --noconfirm "$cached_pkg" 2>/dev/null; then
                log_ok "Driver installed from local package cache."
                installed=true
            else
                log_warn "Cache installation encountered an issue. Falling back to Tier 2..."
            fi
        fi

        # Tier 2: Makepkg / AUR build fallback
        if [[ "$installed" == "false" && -f "$driver_dir/PKGBUILD" ]]; then
            log_info "Tier 2: Building patched driver from PKGBUILD via makepkg..."
            pacman -S --needed --noconfirm git meson ninja cmake pkg-config libgudev libgusb nss pixman openssl
            if sudo -u "$REAL_USER" bash -c "cd '$driver_dir' && makepkg -fc --nodeps && rm -rf src pkg libfprint" 2>/dev/null; then
                local new_pkg
                new_pkg=$(ls -t "$driver_dir"/libfprint-goodix-*.pkg.tar.zst 2>/dev/null | head -n 1 || true)
                if [[ -n "$new_pkg" && -f "$new_pkg" ]]; then
                    clean_stock_libfprint_conflict
                    if pacman -U --overwrite '*' --noconfirm "$new_pkg" 2>/dev/null; then
                        log_ok "Patched driver compiled and installed successfully."
                        installed=true
                    fi
                fi
            fi
        fi

        # Tier 3: Direct source build fallback
        if [[ "$installed" == "false" ]]; then
            log_warn "Tier 3: Falling back to standalone driver compilation & library override..."
            if [[ -x "$driver_dir/install-goodix-driver.sh" ]]; then
                bash "$driver_dir/install-goodix-driver.sh" --force || true
                installed=true
            fi
        fi
    fi

    # Pin in /etc/pacman.conf to prevent official updates from breaking the driver
    if grep -q "^IgnorePkg" /etc/pacman.conf; then
        if ! grep -E "^IgnorePkg.*libfprint" /etc/pacman.conf; then
            sed -i '/^IgnorePkg/ s/$/ libfprint libfprint-goodix-538d libfprint-goodix-521d/' /etc/pacman.conf
        fi
    else
        sed -i '/\[options\]/a IgnorePkg = libfprint libfprint-goodix-538d libfprint-goodix-521d' /etc/pacman.conf
    fi
    log_ok "Pinned 'libfprint' in /etc/pacman.conf against official update overwrites."

    # Provision sensor TLS-PSK & firmware via IAP bootloader if needed
    if [[ -f "$driver_dir/provision-goodix-538d.py" && -f "$driver_dir/GF5298_GM168SEC_APP_13016.bin" ]]; then
        install -Dm755 "$driver_dir/provision-goodix-538d.py" /usr/lib/goodix-538d/provision-goodix-538d.py
        install -Dm644 "$driver_dir/GF5298_GM168SEC_APP_13016.bin" /usr/lib/goodix-538d/GF5298_GM168SEC_APP_13016.bin

        cat > /etc/systemd/system/goodix-538d-provision.service <<'EOF'
[Unit]
Description=Goodix 27c6:538d Fingerprint Sensor TLS-PSK Provisioner
Before=fprintd.service
PartOf=fprintd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/lib/goodix-538d/provision-goodix-538d.py
EOF

        mkdir -p /etc/systemd/system/fprintd.service.d
        cat > /etc/systemd/system/fprintd.service.d/goodix-538d-provision.conf <<'EOF'
[Unit]
Wants=goodix-538d-provision.service
After=goodix-538d-provision.service
EOF

        log_info "Provisioning Goodix 27c6:538d sensor TLS-PSK & verifying firmware..."
        systemctl stop fprintd.service 2>/dev/null || true
        if python3 /usr/lib/goodix-538d/provision-goodix-538d.py; then
            log_ok "Sensor TLS-PSK and firmware verified."
        else
            log_warn "Sensor TLS-PSK provisioning encountered an issue."
        fi
    fi

    # Configure PAM authentication (fingerprint evaluated first & sufficient on its own)
    configure_pam_fingerprint() {
        local target="$1"
        [[ ! -f "$target" ]] && return 0

        # Remove existing pam_fprintd and any stale trailing fallback rules
        sed -i '/pam_fprintd\.so/d' "$target"
        sed -i '/# Manjaro defaults/d' "$target"
        sed -i '/pam_unix\.so.*likeauth/d' "$target"
        sed -i '/auth.*pam_deny\.so/d' "$target"

        # Insert 'auth sufficient pam_fprintd.so' right before the first 'auth' rule
        if grep -q "^auth" "$target"; then
            sed -i '0,/^auth/{s/^auth/auth       sufficient   pam_fprintd.so\nauth/}' "$target"
        else
            sed -i '1a auth       sufficient   pam_fprintd.so' "$target"
        fi
    }

    if [[ ! -f /etc/pam.d/polkit-1 && -f /usr/lib/pam.d/polkit-1 ]]; then
        cp -a /usr/lib/pam.d/polkit-1 /etc/pam.d/polkit-1
    fi
    for pam_file in /etc/pam.d/sudo /etc/pam.d/polkit-1 /etc/pam.d/system-local-login; do
        if [[ -f "$pam_file" ]]; then
            configure_pam_fingerprint "$pam_file"
            log_ok "Configured fingerprint-first authentication in $pam_file."
        fi
    done

    # Restart fprintd daemon
    udevadm control --reload-rules && udevadm trigger 2>/dev/null || true
    systemctl daemon-reload
    systemctl restart fprintd.service 2>/dev/null || true
    log_ok "Fingerprint daemon service (fprintd) reloaded and active."

    # Interactive enrollment
    if [[ "$mode" == "interactive" ]]; then
        echo ""
        local enrolled_list
        enrolled_list=$(run_as_user fprintd-list "$REAL_USER" 2>/dev/null | grep -E "^ - #[0-9]+:" || true)
        if [[ -n "$enrolled_list" ]]; then
            log_ok "Currently enrolled fingerprint(s) for $REAL_USER:"
            echo "$enrolled_list"
        fi
        read -rp "Would you like to enroll a fingerprint now? (y/N): " enroll_ans
        if [[ "$enroll_ans" =~ ^[Yy]$ ]]; then
            echo -e "${CYAN}Place and press your finger flat on the sensor repeatedly when prompted...${NC}"
            run_as_user fprintd-enroll || log_warn "Enrollment interrupted or deferred. Run 'fprintd-enroll' anytime."
        else
            log_info "Fingerprint enrollment skipped. Run 'fprintd-enroll' anytime to register fingers."
        fi
    fi
}

# ------------------------------------------------------------------------------
# 6. SUBMENU: DESKTOP UI, STORAGE & HARDWARE SETTINGS
# ------------------------------------------------------------------------------
menu_desktop_settings() {
    while true; do
        local di_raw di_st hc_raw hc_st fp_raw fp_st
        di_raw=$(get_desktop_icons_status)
        hc_raw=$(get_hot_corner_status)
        fp_raw=$(get_fingerprint_status)

        [[ "$di_raw" == "enabled" ]] && di_st="${GREEN}[Enabled (Files Only)]${NC}" || di_st="${RED}[Disabled]${NC}"
        [[ "$hc_raw" == "enabled" ]] && hc_st="${RED}[Enabled]${NC}" || hc_st="${GREEN}[Disabled (Recommended)]${NC}"

        case "$fp_raw" in
            enrolled)     fp_st="${GREEN}[Enrolled & Active]${NC}" ;;
            installed)    fp_st="${YELLOW}[Driver Ready (Unenrolled)]${NC}" ;;
            uninstalled)  fp_st="${RED}[Driver Not Installed]${NC}" ;;
            not_detected) fp_st="${RED}[Hardware Not Detected]${NC}" ;;
        esac

        echo ""
        echo -e "${BOLD}========================================================================${NC}"
        echo -e "${BOLD}               DESKTOP UI, STORAGE & HARDWARE SETTINGS                  ${NC}"
        echo -e "${BOLD}========================================================================${NC}"
        echo -e " 1) Desktop Files & Folders                  $di_st"
        echo -e " 2) Top-Left Hot Corner                      $hc_st"
        echo -e " 3) Configure Windows & Data Partitions      ${CYAN}[NTFS3 / Auto-Mount]${NC}"
        echo -e " 4) Btrfs Health & Storage Maintenance       ${CYAN}[Balance & SSD TRIM]${NC}"
        echo -e " 5) Dell Hardware Tuning                     ${CYAN}[Battery Longevity & Fastboot]${NC}"
        echo -e " 6) Dell UEFI BIOS & Firmware Updates        ${CYAN}[LVFS / fwupd]${NC}"
        echo -e " 7) Dual-Boot GRUB & Snapshot Sync           ${CYAN}[10s Timeout, Shutdown Menu, grub-btrfsd]${NC}"
        echo -e " 8) Goodix Fingerprint Sensor (27c6:538d)    $fp_st"
        echo -e " 9) Dock Pinned Apps & Workflow Order        ${CYAN}[11 Apps: Pamac, Files, Dev/AI, RustDesk]${NC}"
        echo -e "${BOLD}------------------------------------------------------------------------${NC}"
        echo -e " A) Run / Apply ALL Settings & Hardware Tuning"
        echo -e " B) Back to Main Menu"
        echo -e "${BOLD}========================================================================${NC}"
        read -rp "Select an option (1-9 / A / B): " choice

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
                configure_permanent_partitions
                read -rp "Press [Enter] to continue..."
                ;;
            4)
                maintain_btrfs_storage
                read -rp "Press [Enter] to continue..."
                ;;
            5)
                configure_dell_hardware
                read -rp "Press [Enter] to continue..."
                ;;
            6)
                update_dell_firmware
                read -rp "Press [Enter] to continue..."
                ;;
            7)
                configure_grub_dual_boot
                read -rp "Press [Enter] to continue..."
                ;;
            8)
                configure_goodix_fingerprint interactive
                read -rp "Press [Enter] to continue..."
                ;;
            9)
                configure_dock_favorites
                read -rp "Press [Enter] to continue..."
                ;;
            [aA])
                log_info "=== APPLYING ALL DESKTOP, STORAGE & HARDWARE SETTINGS ==="
                configure_desktop_icons enable
                configure_hot_corner disable
                configure_dock_favorites
                configure_permanent_partitions
                maintain_btrfs_storage
                configure_dell_hardware
                update_dell_firmware
                configure_grub_dual_boot
                configure_goodix_fingerprint noninteractive
                log_ok "All settings and hardware tuning routines completed."
                read -rp "Press [Enter] to continue..."
                ;;
            [bB]) break ;;
            *) log_warn "Invalid selection." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 7. MAIN MENU
# ------------------------------------------------------------------------------
while true; do
    echo ""
    echo -e "${BOLD}========================================================================${NC}"
    echo -e "${BOLD}                     MANJARO CONTROL CENTER                             ${NC}"
    echo -e "${BOLD}========================================================================${NC}"
    echo -e " ${BOLD}1)${NC} Optimize the system (Timeshift, Kernel Check, Full AUR/Repo Sync, SSD TRIM)"
    echo -e " ${BOLD}2)${NC} Desktop UI, Storage & Hardware Settings"
    echo -e " ${BOLD}3)${NC} Extra Apps (Install, Reinstall & Uninstall Hub)"
    echo -e " ${BOLD}4)${NC} Quit"
    echo -e "${BOLD}------------------------------------------------------------------------${NC}"
    echo -e " 📋 Live log file: ${CYAN}$LOG_FILE${NC}"
    echo -e "${BOLD}========================================================================${NC}"
    read -rp "Please enter your choice (1-4): " main_choice

    case "$main_choice" in
        1) optimize_system ;;
        2) menu_desktop_settings ;;
        3) menu_extra_apps ;;
        4)
            log_ok "Exiting. Session completed successfully!"
            break
            ;;
        *)
            log_warn "Invalid option. Please enter a number from 1 to 4."
            ;;
    esac
done