#!/bin/sh

# Unit tests for awsenv.sh helper functions: should_allocate_tty,
# validate_mount_format, get_positional_args, and
# cmd_mount_shadowed_by_pwd.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_DIR/../lib/harness.sh"
# shellcheck source=../lib/extract.sh
. "$SCRIPT_DIR/../lib/extract.sh"

TMP_SCRIPT="$(mktemp)"
TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -f "$TMP_SCRIPT"
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM HUP

load_script_functions "$REPO_DIR/awsenv.sh" "$TMP_SCRIPT"
# shellcheck source=/dev/null
. "$TMP_SCRIPT"

# --- should_allocate_tty: auto mode must not always allocate ---

AWSENV_TTY=always
run_capture should_allocate_tty
assert_true "should_allocate_tty: always mode allocates" "$RUN_STATUS"

AWSENV_TTY=never
run_capture should_allocate_tty
assert_false "should_allocate_tty: never mode does not allocate" "$RUN_STATUS"

# auto mode with stdin redirected from a non-tty (this test process's stdin
# when run under the test harness is never a real terminal)
AWSENV_TTY=auto
run_capture should_allocate_tty </dev/null
assert_false "should_allocate_tty: auto mode with non-tty stdin does not allocate" "$RUN_STATUS"

# --- validate_mount_format: accept files as well as directories ---

test_dir="$TMP_DIR/mountdir"
mkdir -p "$test_dir"
test_file="$TMP_DIR/mountfile"
: >"$test_file"

run_capture validate_mount_format "$test_dir:/container/dir"
assert_true "validate_mount_format accepts a directory" "$RUN_STATUS"

run_capture validate_mount_format "$test_file:/container/file"
assert_true "validate_mount_format accepts a plain file" "$RUN_STATUS"

run_capture validate_mount_format "$test_dir:/container/dir:ro"
assert_true "validate_mount_format accepts an explicit ro mode" "$RUN_STATUS"

run_capture validate_mount_format "$test_dir:/container/dir:bogus"
assert_false "validate_mount_format rejects an invalid mode" "$RUN_STATUS"

run_capture validate_mount_format "$TMP_DIR/does-not-exist:/container/dir"
assert_false "validate_mount_format rejects a nonexistent path" "$RUN_STATUS"

run_capture validate_mount_format "onlyonefield"
assert_false "validate_mount_format rejects too few fields" "$RUN_STATUS"

# --- get_positional_args: skip values of global AWS CLI options ---

CMD="aws"
CMD_ARGS_START=2
get_positional_args "aws" "sso" "login"
assert_eq "get_positional_args: simple case (first)" "sso" "$FIRST_POS"
assert_eq "get_positional_args: simple case (second)" "login" "$SECOND_POS"

get_positional_args "aws" "--profile" "myprofile" "sso" "login"
assert_eq "get_positional_args: skips --profile VALUE (first)" "sso" "$FIRST_POS"
assert_eq "get_positional_args: skips --profile VALUE (second)" "login" "$SECOND_POS"

get_positional_args "aws" "--profile=myprofile" "sso" "login"
assert_eq "get_positional_args: skips --profile=VALUE (first)" "sso" "$FIRST_POS"
assert_eq "get_positional_args: skips --profile=VALUE (second)" "login" "$SECOND_POS"

get_positional_args "aws" "--region" "us-east-1" "configure" "sso"
assert_eq "get_positional_args: skips --region VALUE (first)" "configure" "$FIRST_POS"
assert_eq "get_positional_args: skips --region VALUE (second)" "sso" "$SECOND_POS"

# --- cmd_mount_shadowed_by_pwd ---

cd "$TMP_DIR"
CMD_MOUNT_DIR="$TMP_DIR"
run_capture cmd_mount_shadowed_by_pwd "rw"
assert_true "cmd_mount_shadowed_by_pwd: exact match with rw pwd is shadowed" "$RUN_STATUS"

mkdir -p "$TMP_DIR/sub"
CMD_MOUNT_DIR="$TMP_DIR/sub"
run_capture cmd_mount_shadowed_by_pwd "rw"
assert_true "cmd_mount_shadowed_by_pwd: subdirectory under rw pwd is shadowed" "$RUN_STATUS"

run_capture cmd_mount_shadowed_by_pwd "ro"
assert_false "cmd_mount_shadowed_by_pwd: subdirectory under ro pwd is not shadowed" "$RUN_STATUS"

run_capture cmd_mount_shadowed_by_pwd "off"
assert_false "cmd_mount_shadowed_by_pwd: pwd mode off never shadows" "$RUN_STATUS"

CMD_MOUNT_DIR="/some/unrelated/dir"
run_capture cmd_mount_shadowed_by_pwd "rw"
assert_false "cmd_mount_shadowed_by_pwd: unrelated directory is not shadowed" "$RUN_STATUS"

test_summary
