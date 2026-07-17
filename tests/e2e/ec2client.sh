#!/bin/sh

# End-to-end tests for ec2client.sh against the stubbed aws/ssh/jq toolchain.
# Exercises only single-match auto-connect paths (the interactive
# multi-match prompt reads from /dev/tty).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/ec2"
STUBS_DIR="$SCRIPT_DIR/../stubs"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_DIR/../lib/harness.sh"

WORK_DIR="$(mktemp -d)"
STUB_LOG="$WORK_DIR/stub.log"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM HUP

export PATH="$STUBS_DIR:$PATH"
export STUB_LOG

count_calls() {
  grep -c "^=== $1 ===\$" "$STUB_LOG" 2>/dev/null || true
}

# --- single match, SSH: exactly 1 aws call, no eval, ip/user forwarded ---

: >"$STUB_LOG"
set +e
env FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" \
  "$REPO_DIR/ec2client.sh" -c ssh >"$WORK_DIR/ssh_out.log" 2>&1
ssh_status=$?
set -e
assert_true "ec2client -c ssh (single match): exits successfully" "$ssh_status"
assert_eq "ec2client -c ssh: exactly 1 aws call" "1" "$(count_calls aws)"

ssh_section=$(awk '/^=== ssh ===$/{p=1} p' "$STUB_LOG")
assert_contains "ec2client -c ssh: ssh argv targets the instance IP" "$ssh_section" "ec2-user@198.51.100.5"
assert_contains "ec2client -c ssh: agent forwarding requested" "$ssh_section" "-A"

# --- single match, SSM: exactly 1 aws call for the query (session start not logged as aws) ---

: >"$STUB_LOG"
set +e
env FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" \
  "$REPO_DIR/ec2client.sh" -c ssm -s "bash -l" >"$WORK_DIR/ssm_out.log" 2>&1
ssm_status=$?
set -e
assert_true "ec2client -c ssm (single match): exits successfully" "$ssm_status"
assert_eq "ec2client -c ssm: exactly 2 aws calls (describe-instances + ssm start-session)" "2" "$(count_calls aws)"

# --- tag value with spaces is preserved as a single --filters argument ---

: >"$STUB_LOG"
set +e
env FIXTURE_EC2_INSTANCES="$FIXTURES_DIR/instance_single.tsv" \
  "$REPO_DIR/ec2client.sh" -t "Name=Web Server" -c ssm >"$WORK_DIR/space_out.log" 2>&1
space_status=$?
set -e
assert_true "ec2client -t with spaces (single match): exits successfully" "$space_status"
aws_section=$(awk '/^=== aws ===$/{p=1} p' "$STUB_LOG")
assert_contains "ec2client: tag value with spaces stays one filter argument" "$aws_section" "Name=tag:Name,Values=Web Server"

# --- comma in tag value is rejected (EC2 filter syntax treats it as OR) ---

set +e
"$REPO_DIR/ec2client.sh" -t "Name=a,b" -c ssm >"$WORK_DIR/comma_out.log" 2>&1
comma_status=$?
set -e
assert_false "ec2client: comma in tag value is rejected" "$comma_status"
assert_contains "ec2client: comma rejection error message" "$(cat "$WORK_DIR/comma_out.log")" "','"

# --- None fields are normalized: single instance with no name/ip ---

: >"$STUB_LOG"
printf 'i-0noname00000000000\tNone\tNone\n' >"$WORK_DIR/instance_none.tsv"
set +e
env FIXTURE_EC2_INSTANCES="$WORK_DIR/instance_none.tsv" \
  "$REPO_DIR/ec2client.sh" -c ssh >"$WORK_DIR/none_out.log" 2>&1
none_status=$?
set -e
assert_false "ec2client: instance without a public IP fails cleanly over SSH" "$none_status"
none_out=$(cat "$WORK_DIR/none_out.log")
assert_not_contains "ec2client: no literal 'None' leaks into user-facing output" "$none_out" "None"
assert_contains "ec2client: reports missing public IP" "$none_out" "does not have a public IP"

# --- -h exits 0 ---

set +e
"$REPO_DIR/ec2client.sh" -h >/dev/null 2>&1
h_status=$?
set -e
assert_eq "ec2client -h exits 0" "0" "$h_status"

# --- unexpected positional argument rejected ---

set +e
"$REPO_DIR/ec2client.sh" unexpected-arg >/dev/null 2>&1
extra_status=$?
set -e
assert_false "ec2client: unexpected positional argument is rejected" "$extra_status"

test_summary
