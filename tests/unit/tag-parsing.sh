#!/bin/sh

# Unit tests for the shared tag-parsing functions (parse_tag_argument,
# validate_tag_format), extracted from ec2client.sh. These are byte-identical
# to rdsclient.sh's copies per tests/check-shared.sh, so testing one copy
# covers both.

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

load_script_functions "$REPO_DIR/ec2client.sh" "$TMP_SCRIPT"
# shellcheck source=/dev/null
. "$TMP_SCRIPT"

# --- parse_tag_argument ---

parse_tag_argument "Environment=prod"
assert_eq "parse_tag_argument splits simple key=value" "Environment" "$PARSED_KEY"
assert_eq "parse_tag_argument splits simple key=value (value)" "prod" "$PARSED_VALUE"

parse_tag_argument "Config=key=value"
assert_eq "parse_tag_argument keeps embedded = in value (key)" "Config" "$PARSED_KEY"
assert_eq "parse_tag_argument keeps embedded = in value (value)" "key=value" "$PARSED_VALUE"

parse_tag_argument "NoEqualsSign"
assert_eq "parse_tag_argument with no '=' yields empty key" "" "$PARSED_KEY"
assert_eq "parse_tag_argument with no '=' yields empty value" "" "$PARSED_VALUE"

# --- validate_tag_format ---

parse_tag_argument "Name=Web Server"
validate_tag_format "Name=Web Server" "$PARSED_KEY" "$PARSED_VALUE"
assert_eq "validate_tag_format preserves spaces in value" "Web Server" "$PARSED_VALUE"

run_capture validate_tag_format "Bad'Key=value" "Bad'Key" "value"
assert_false "validate_tag_format rejects a quote in the key" "$RUN_STATUS"
assert_contains "validate_tag_format quote-in-key error message" "$RUN_STDOUT" "unsafe characters"

run_capture validate_tag_format "key=Bad\"Value" "key" "Bad\"Value"
assert_false "validate_tag_format rejects a quote in the value" "$RUN_STATUS"

run_capture validate_tag_format "=value" "" "value"
assert_false "validate_tag_format rejects an empty key" "$RUN_STATUS"

run_capture validate_tag_format "key=" "key" ""
assert_false "validate_tag_format rejects an empty value" "$RUN_STATUS"

run_capture validate_tag_format "  key  =  value  " "  key  " "  value  "
assert_true "validate_tag_format accepts surrounding whitespace (trimmed)" "$RUN_STATUS"

test_summary
