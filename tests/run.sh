#!/bin/sh

# Single entry point for the test suite: shellcheck, the shared-block drift
# check, function-level unit tests, and stubbed end-to-end tests. Exits
# non-zero if any of these fail. Runnable from any working directory.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SUITES_RUN=0
SUITES_FAILED=0

section() {
  printf '\n== %s ==\n' "$1"
}

record_result() {
  # record_result <label> <status>
  SUITES_RUN=$((SUITES_RUN + 1))
  if [ "$2" -ne 0 ]; then
    SUITES_FAILED=$((SUITES_FAILED + 1))
    printf 'FAILED: %s\n' "$1"
  fi
}

run_script_suite() {
  # run_script_suite <path-to-executable-test-script>
  script="$1"
  section "$(basename "$script")"
  set +e
  "$script"
  status=$?
  set -e
  record_result "$(basename "$script")" "$status"
}

# --- 1. shellcheck on the four standalone tool scripts ---

section "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  set +e
  shellcheck -s sh \
    "$REPO_DIR/awsenv.sh" \
    "$REPO_DIR/ec2client.sh" \
    "$REPO_DIR/rdsclient.sh" \
    "$REPO_DIR/install.sh"
  shellcheck_status=$?
  set -e
  record_result "shellcheck" "$shellcheck_status"
else
  echo "shellcheck not found on PATH; skipping (this is a hard requirement in CI)"
  record_result "shellcheck (missing)" 1
fi

# --- 2. shared-block drift check ---

run_script_suite "$SCRIPT_DIR/check-shared.sh"

# --- 3. function-level unit tests ---

for t in "$SCRIPT_DIR"/unit/*.sh; do
  [ -f "$t" ] || continue
  run_script_suite "$t"
done

# --- 4. stubbed end-to-end tests ---

for t in "$SCRIPT_DIR"/e2e/*.sh; do
  [ -f "$t" ] || continue
  run_script_suite "$t"
done

# --- summary ---

printf '\n===================================\n'
printf '%d suite(s) run, %d failed\n' "$SUITES_RUN" "$SUITES_FAILED"

[ "$SUITES_FAILED" -eq 0 ]
