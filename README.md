# Manjaro Optimization & Control Center

An enterprise-grade post-installation, storage optimization, dual-boot tuning, and hardware management suite for Manjaro Linux. Features dedicated hardware tuning for the **Dell Inspiron 7706 2-in-1** (Intel Tiger Lake Iris Xe / Goodix 27c6:538d) alongside strict hardware detection guards that ensure safe execution across any machine.

---

## 🏷️ Versioning & Rollback Strategy

- **`v9.5.0` (Stable Baseline Tag)**: Permanent, annotated git tag on the `main` branch. Serves as a known-good rollback point.
  ```bash
  git checkout v9.5.0
  ```
- **`v10.0.0-dev` (Current Development Branch)**: Comprehensive architectural rewrite delivering modular libraries, zero-risk partition scrubbing, dynamic Timeshift snapshot synchronization, and hardened hardware drivers.

---

## 🚀 Quick Start & CLI Options

The script supports fast, early unprivileged argument parsing (`--help`, `--version`) that executes without requiring `sudo` or modifying system state.

```bash
# Launch Interactive Control Center Menu
sudo ./Manjaro-Optimization.sh

# Run All 3 Stages Unattended (Optimize -> Settings -> Extra Apps)
sudo ./Manjaro-Optimization.sh --all

# Run Stage 1: Core System Optimization (Mirrors, AUR Sync, Kernel & ZRAM)
sudo ./Manjaro-Optimization.sh --optimize

# Run Stage 2: Desktop UI, Partition Mounting & Hardware Tuning
sudo ./Manjaro-Optimization.sh --settings

# Run Stage 3: Extra Applications Hub (15 Dev, AI, Container & Media Apps)
sudo ./Manjaro-Optimization.sh --apps

# Launch Timeshift Restore & Boot Synchronization Manager
sudo ./Manjaro-Optimization.sh --timeshift

# Run Test Suite
./tests/run-all-tests.sh

# Hardware Override (for non-Inspiron 7706 machines testing Dell tweaks)
FORCE_HW=1 sudo ./Manjaro-Optimization.sh
```

---

## 🛡️ Architecture & Core Improvements

### 1. Safety & Data Protection (P0)
- **Safe Partition Scrubbing**: Protects essential system mount points (`/`, `/boot`, `/efi`, `/home`, `/var`, `/usr`) *before* sensitive partition classification. Uses exact-word regex matching for recovery labels (`Recovery`, `WINRE`, `DellSupport`, etc.) to prevent false positives on legitimate user partitions (e.g. `my-data`, `bootcamp-data`).
- **Safe Mount Directory Cleanup**: Replaced dangerous `rm -rf` on unmounted directories with `rmdir` scoped exclusively to `/mnt` and `/media`.
- **Comment-Tolerant JSONC Parser**: Preserves comments (`//`, `/* */`) and trailing commas in VS Code / Antigravity IDE `settings.json`, with atomic temporary writes and `.bak` backups.
- **PAM Authentication Guard**: Creates `.pre-fprintd` safety backups, validates that fallback authentication rules (`system-auth`) exist, and rejects changes if fewer than two `auth` rules remain.
- **User Profile Retention**: Application uninstallers preserve user configurations, browser bookmarks, and settings by default (`PURGE_USER_DATA=0`), with an explicit prompt to purge data.

### 2. Functional Correctness (P1)
- **Idempotent Btrfs Mount Options**: Updates `noatime,discard=async` in `/etc/fstab` without accumulating duplicate flags on repeated runs.
- **Unattended Kernel Resilience**: Falls back to non-interactive `pacman -S --needed --noconfirm linux612` if `mhwd-kernel -i` fails in automated runs.
- **Google Clasp Execution**: Injects `export PATH="$NODE_BIN_DIR:$PATH"` into `~/.local/bin/clasp` so that global NPM CLIs execute correctly outside interactive subshells.
- **Batched VS Code Extensions**: Installs missing extensions in a single batch pass, with pipefail grep filtering to cleanly hide Electron Wayland warnings.
- **EOF-Safe Menus**: The `ask()` helper prevents infinite terminal loops when standard input is closed or piped.

### 3. Performance & Cleanups (P2)
- **Consolidated GRUB Regeneration**: Defers GRUB rebuilds across Stage 2 and full runs, reducing `update-grub` invocations from up to 4 down to **1 single pass**.
- **HiDPI Font Generation Caching**: Verifies font existence before executing `grub-mkfont`, saving CPU cycles and disk I/O on repeated runs.
- **Idempotent `set_grub_var`**: Modifies or uncomments variables in `/etc/default/grub` in-place, returning immediately if the variable is already compliant.
- **Batch Uninstall Hook**: Suppresses redundant font and desktop cache rebuilds during batch package removals (`SKIP_POST_HOOK=1`).
- **Narrowed Udev Triggers**: Scopes `udevadm trigger` to specific subsystems (`--subsystem-match=misc` and `--subsystem-match=usb`), eliminating system-wide I/O freezes.
- **Clean Disk Logs**: Strips ANSI escape codes from disk log files (`/var/log/manjaro-optimization-*.log`) while preserving full terminal colors.

### 4. Timeshift Boot & Kernel Synchronization Suite (T)
Located in `timeshift-sync/`:
- **Dynamic Kernel Discovery**: Scans `/boot/vmlinuz-*-x86_64` dynamically to inject host kernels into older snapshots, while blacklisting broken rolling kernels (`7.1`).
- **Never-Purge-Only-Kernel Guard**: Refuses to remove broken kernels if no other functional kernel exists in the snapshot, preventing unbootable 0-kernel states.
- **Atomic Snapshot Re-locking**: Uses `EXIT`, `INT`, and `TERM` traps to guarantee snapshots are never left in a read-write state if an operation is interrupted.
- **On-Demand Snapshot Repairs**: `timeshift-sync/install.sh` defaults to `--no-repair`, avoiding unsolicited mutations of historical snapshots.
- **Read-Only Menu Audit**: `check-grub-menu.sh` inspects menu entries without modifying or deleting temporary build files.
- **Clean Uninstallation**: `timeshift-sync/uninstall.sh` disables systemd units, removes hooks, and cleans CLI binaries.

### 5. Goodix 27c6:538d Fingerprint Driver (D)
Located in `drivers/goodix-538d/`:
- **SHA-256 Integrity Verification**: Cryptographically validates driver packages and the firmware blob against `drivers/goodix-538d/SHA256SUMS`.
- **Non-Destructive `--check` Mode**: `provision-goodix-538d.py --check` inspects sensor firmware and TLS-PSK without writing to flash.
- **Systemd Boot Service**: `goodix-538d-provision.service` executes `--check` with `RemainAfterExit=yes` once per boot.
- **Explicit Firmware Flashing**: Requires `--flash` (or interactive user confirmation) before erasing and reflashing sensor flash memory.
- **Aligned PKGBUILD Dependencies**: Lists all required runtime and build dependencies (`glib2`, `libgudev`, `libgusb`, `json-glib`, `nss`, `pixman`, `openssl`, `libusb`, `python`).

### 6. Repo Hygiene & Automated Tests (X)
- **Shared Library (`lib/common.sh`)**: Centralizes colors, logging, hardware detection, input prompts, mount purging, and PAM helpers.
- **Automated Test Runner (`tests/run-all-tests.sh`)**: Validates bash syntax across all scripts, python compilation, and executes all unit test suites.
- **Unit Tests (`tests/test-helpers.sh` & `tests/test-timeshift.sh`)**: 31 comprehensive test cases validating partition safety, fstab idempotency, PAM backups, JSONC atomic parser, `set_grub_var`, kernel discovery, and snapshot tracking.

---

## 📂 Repository Structure

```
.
├── Manjaro-Optimization.sh          # Main interactive Control Center & CLI entrypoint
├── lib/
│   └── common.sh                    # Shared helper library (colors, logging, guards, helpers)
├── tests/
│   ├── run-all-tests.sh             # Master automated regression runner
│   ├── test-helpers.sh              # Unit tests for helper routines & safety filters
│   └── test-timeshift.sh            # Unit tests for Timeshift kernel discovery & safeguards
├── timeshift-sync/
│   ├── check-grub-menu.sh           # Read-only audit for duplicate GRUB entries
│   ├── fix-existing-snapshots.sh    # On-demand snapshot kernel injection & repair
│   ├── install.sh                   # Suite installer (--repair-snapshots optional)
│   ├── uninstall.sh                 # Clean uninstaller for services, hooks, and binaries
│   ├── timeshift-boot-sync.service  # Systemd first-boot safeguard service
│   ├── timeshift-boot-sync.sh       # First-boot kernel & grubenv validation
│   ├── timeshift-restore-hook.sh    # Native Timeshift GUI/CLI post-restore hook
│   ├── timeshift-restore-sync.sh    # Interactive CLI snapshot restore manager
│   ├── timeshift-sync-notify.desktop# Desktop notification autostart entry
│   └── timeshift-sync-notify.sh     # Desktop notification handler with ack tracking
├── drivers/goodix-538d/
│   ├── GF5298_GM168SEC_APP_13016.bin# Sensor firmware binary blob
│   ├── PKGBUILD                     # Arch package build definition
│   ├── SHA256SUMS                   # Cryptographic checksums
│   ├── fix-goodix-538d-tls-psk.patch# Patches for OpenSSL 3.x and TLS-PSK
│   ├── install-goodix-driver.sh     # Standalone driver installer
│   ├── libfprint-goodix-538d-*.pkg  # Precompiled verified driver package
│   └── provision-goodix-538d.py     # TLS-PSK provisioner (--check / --flash)
└── .shellcheckrc                    # ShellCheck configuration
```

---

## 🧪 Running Tests

Ensure all automated tests pass before committing or deploying changes:

```bash
./tests/run-all-tests.sh
```
