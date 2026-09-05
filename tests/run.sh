#!/bin/sh

# Single entry point for the test suite: shellcheck, the shared-block drift
# check, function-level unit tests, and stubbed end-to-end tests. Exits
# non-zero if any of these fail. Runnable from any working directory.

set -eu

#!/bin/sh

# Single entry point for the test suite: shellcheck, the shared-block drift
# check, function-level unit tests, and stubbed end-to-end tests. Exits
# non-zero if any of these fail. Runnable from any working directory.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_DIR

SUITES_RUN=0
SUITES_FAILED=0

section() {
  printf '\n== %s ==\n' "$1"
}

record_result() {
  _record_label="$1"
  _record_status="$2"
  SUITES_RUN=$((SUITES_RUN + 1))
  if [ "$_record_status" -ne 0 ]; then
    SUITES_FAILED=$((SUITES_FAILED + 1))
    printf 'FAILED: %s\n' "$_record_label"
  fi
}

run_script_suite() {
  _run_script="$1"
  section "$(basename "$_run_script")"
  set +e
  "$_run_script"
  _run_status=$?
  set -e
  record_result "$(basename "$_run_script")" "$_run_status"
}

run_shellcheck() {
  section "shellcheck"
  if command -v shellcheck >/dev/null 2>&1; then
    set +e
    shellcheck -s sh -x --source-path="$SCRIPT_DIR/lib" \
      "$REPO_DIR"/*.sh \
      "$SCRIPT_DIR"/*.sh \
      "$SCRIPT_DIR"/unit/*.sh \
      "$SCRIPT_DIR"/e2e/*.sh \
      "$SCRIPT_DIR"/lib/*.sh \
      "$SCRIPT_DIR"/stubs/*
    _sc_status=$?
    set -e
    record_result "shellcheck" "$_sc_status"
  else
    echo "shellcheck not found on PATH; skipping (this is a hard requirement in CI)"
    record_result "shellcheck (missing)" 1
  fi
}

main() {
  run_shellcheck
  run_script_suite "$SCRIPT_DIR/check-shared.sh"

  for _main_unit in "$SCRIPT_DIR"/unit/*.sh; do
    [ -f "$_main_unit" ] || continue
    run_script_suite "$_main_unit"
  done

  for _main_e2e in "$SCRIPT_DIR"/e2e/*.sh; do
    [ -f "$_main_e2e" ] || continue
    run_script_suite "$_main_e2e"
  done

  printf '\n===================================\n'
  printf '%d suite(s) run, %d failed\n' "$SUITES_RUN" "$SUITES_FAILED"

  [ "$SUITES_FAILED" -eq 0 ]
}

main "$@"
