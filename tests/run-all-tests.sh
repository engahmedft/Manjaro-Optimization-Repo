#!/usr/bin/env bash
# ==============================================================================
# tests/run-all-tests.sh - Comprehensive Automated Test & Verification Runner
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { printf '[%b] %b\n' "${CYAN}TEST${NC}" "$1"; }
log_ok()    { printf '[%b] %b\n' "${GREEN}PASS${NC}" "$1"; }
log_warn()  { printf '[%b] %b\n' "${YELLOW}WARN${NC}" "$1"; }
log_error() { printf '[%b] %b\n' "${RED}FAIL${NC}" "$1"; }

TOTAL_RUNS=0
TOTAL_FAILURES=0

echo -e "\n${BOLD}${CYAN}========================================================================${NC}"
echo -e "${BOLD}${CYAN}     MANJARO OPTIMIZATION AUTOMATED REGRESSION & TEST SUITE            ${NC}"
echo -e "${BOLD}${CYAN}========================================================================${NC}\n"

# 1. Shell Syntax Validation (bash -n)
log_info "1. Validating bash syntax across all repository shell scripts..."
shell_scripts=(
    "$REPO_DIR/Manjaro-Optimization.sh"
    "$REPO_DIR/lib/common.sh"
    "$REPO_DIR/tests/test-helpers.sh"
    "$REPO_DIR/tests/test-timeshift.sh"
    "$REPO_DIR/tests/run-all-tests.sh"
    "$REPO_DIR/timeshift-sync/check-grub-menu.sh"
    "$REPO_DIR/timeshift-sync/fix-existing-snapshots.sh"
    "$REPO_DIR/timeshift-sync/install.sh"
    "$REPO_DIR/timeshift-sync/uninstall.sh"
    "$REPO_DIR/timeshift-sync/timeshift-boot-sync.sh"
    "$REPO_DIR/timeshift-sync/timeshift-restore-hook.sh"
    "$REPO_DIR/timeshift-sync/timeshift-restore-sync.sh"
    "$REPO_DIR/timeshift-sync/timeshift-sync-notify.sh"
    "$REPO_DIR/drivers/goodix-538d/install-goodix-driver.sh"
)

for script in "${shell_scripts[@]}"; do
    (( TOTAL_RUNS += 1 ))
    if bash -n "$script" 2>/dev/null; then
        log_ok "Syntax valid: $(basename "$script")"
    else
        log_error "Syntax ERROR: $script"
        (( TOTAL_FAILURES += 1 ))
    fi
done

# 2. Python Syntax Validation (py_compile)
log_info "\n2. Validating Python syntax across all repository scripts..."
python_scripts=(
    "$REPO_DIR/drivers/goodix-538d/provision-goodix-538d.py"
)

for script in "${python_scripts[@]}"; do
    (( TOTAL_RUNS += 1 ))
    if python3 -m py_compile "$script" 2>/dev/null; then
        log_ok "Python syntax valid: $(basename "$script")"
    else
        log_error "Python syntax ERROR: $script"
        (( TOTAL_FAILURES += 1 ))
    fi
done

# 3. ShellCheck Linter (if installed)
log_info "\n3. Checking for shellcheck static analysis..."
if command -v shellcheck &>/dev/null; then
    (( TOTAL_RUNS += 1 ))
    if shellcheck -x -P "$REPO_DIR" "$REPO_DIR/lib/common.sh" "$REPO_DIR/tests/test-helpers.sh" "$REPO_DIR/tests/test-timeshift.sh"; then
        log_ok "ShellCheck passed on core library and test fixtures."
    else
        log_warn "ShellCheck reported warnings."
    fi
else
    log_warn "ShellCheck not installed on host. Skipping static linting."
fi

# 4. Helper & Safety Unit Tests
log_info "\n4. Running Unit Tests: tests/test-helpers.sh..."
(( TOTAL_RUNS += 1 ))
if "$REPO_DIR/tests/test-helpers.sh"; then
    log_ok "tests/test-helpers.sh completed with 0 failures."
else
    log_error "tests/test-helpers.sh failed!"
    (( TOTAL_FAILURES += 1 ))
fi

# 5. Timeshift Suite Unit Tests
log_info "\n5. Running Unit Tests: tests/test-timeshift.sh..."
(( TOTAL_RUNS += 1 ))
if "$REPO_DIR/tests/test-timeshift.sh"; then
    log_ok "tests/test-timeshift.sh completed with 0 failures."
else
    log_error "tests/test-timeshift.sh failed!"
    (( TOTAL_FAILURES += 1 ))
fi

echo -e "\n${BOLD}========================================================================${NC}"
if (( TOTAL_FAILURES == 0 )); then
    echo -e "${GREEN}${BOLD}🎉 ALL $TOTAL_RUNS TEST CHECKS PASSED WITH ZERO FAILURES!${NC}"
    echo -e "${BOLD}========================================================================${NC}\n"
    exit 0
else
    echo -e "${RED}${BOLD}❌ TEST SUITE FAILED: $TOTAL_FAILURES out of $TOTAL_RUNS checks failed!${NC}"
    echo -e "${BOLD}========================================================================${NC}\n"
    exit 1
fi
