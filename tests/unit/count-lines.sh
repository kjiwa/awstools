#!/bin/sh

# Unit tests for the shared count_lines function, extracted from
# rdsclient.sh (byte-identical to ec2client.sh's copy, verified by
# tests/check-shared.sh).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_DIR/../lib/harness.sh"
# shellcheck source=../lib/extract.sh
. "$SCRIPT_DIR/../lib/extract.sh"

TMP_SCRIPT="$(mktemp)"
cleanup() {
  rm -f "$TMP_SCRIPT"
}
trap cleanup EXIT INT TERM HUP

load_script_functions "$REPO_DIR/rdsclient.sh" "$TMP_SCRIPT"
# shellcheck source=/dev/null
. "$TMP_SCRIPT"

assert_eq "count_lines: empty string is 0" "0" "$(count_lines "")"
assert_eq "count_lines: single line is 1" "1" "$(count_lines "one")"

three_lines="one
two
three"
assert_eq "count_lines: three lines is 3" "3" "$(count_lines "$three_lines")"

test_summary
