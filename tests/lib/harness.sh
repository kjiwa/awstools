#!/bin/sh

# Minimal test harness sourced by unit/e2e test scripts.
#
# Usage in a test script:
#   #!/bin/sh
#   set -eu
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "$SCRIPT_DIR/../lib/harness.sh"
#   assert_eq "description" "expected" "actual"
#   ...
#   test_summary
#
# assert_* helpers never propagate failure through their own exit status
# (they always return 0), so a test script may keep `set -eu` without a
# failed assertion aborting the rest of the file.

TESTS_RUN=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf "ok - %s\n" "$1"
  return 0
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "not ok - %s\n" "$1"
  [ -n "${2:-}" ] && printf "  # %s\n" "$2"
  return 0
}

assert_eq() {
  desc="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc" "expected [$expected] got [$actual]"
  fi
}

assert_contains() {
  desc="$1"
  haystack="$2"
  needle="$3"
  case "$haystack" in
  *"$needle"*) pass "$desc" ;;
  *) fail "$desc" "expected to find [$needle] in [$haystack]" ;;
  esac
}

assert_not_contains() {
  desc="$1"
  haystack="$2"
  needle="$3"
  case "$haystack" in
  *"$needle"*) fail "$desc" "did not expect to find [$needle] in [$haystack]" ;;
  *) pass "$desc" ;;
  esac
}

assert_status() {
  desc="$1"
  expected="$2"
  actual="$3"
  assert_eq "$desc" "$expected" "$actual"
}

assert_true() {
  desc="$1"
  status="$2"
  assert_eq "$desc" "0" "$status"
}

assert_false() {
  desc="$1"
  status="$2"
  if [ "$status" -ne 0 ]; then
    pass "$desc"
  else
    fail "$desc" "expected non-zero exit status, got 0"
  fi
}

# run_capture <command...>
# Runs a command (which may be a shell function) and captures its combined
# stdout+stderr into RUN_STDOUT and its exit status into RUN_STATUS, without
# ever tripping the caller's `set -e` regardless of the command's outcome.
run_capture() {
  if RUN_STDOUT=$("$@" 2>&1); then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
}

test_summary() {
  printf "\n%d run, %d failed\n" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
