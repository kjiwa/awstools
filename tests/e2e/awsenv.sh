#!/bin/sh

# End-to-end tests for awsenv.sh against a stubbed docker.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

docker_argv() {
  # Prints the argv of the most recent `docker run` invocation logged, one
  # word per line, stopping before the next "=== docker ===" section.
  awk '
    /^=== docker ===$/ { block = ""; in_block = 1; next }
    in_block && /^=== / { in_block = 0 }
    in_block { block = block $0 ORS }
    END { printf "%s", block }
  ' "$STUB_LOG" | awk 'BEGIN{run=0} $0=="run"{run=1} run{print}'
}

# --- basic passthrough: IMAGE and CMD_PATH reach the final docker run call ---

: >"$STUB_LOG"
set +e
AWSENV_TTY=never "$REPO_DIR/awsenv.sh" aws --version >"$WORK_DIR/out.log" 2>&1
status=$?
set -e
assert_true "awsenv aws --version: exits successfully" "$status"
argv=$(docker_argv)
assert_contains "awsenv: docker run invoked" "$argv" "run"
assert_contains "awsenv: image name passed to docker run" "$argv" "awsenv-cli:base"
assert_contains "awsenv: aws builtin command passed through" "$argv" "aws"
assert_contains "awsenv: trailing --version arg passed through" "$argv" "--version"

# --- AWSENV_TTY=never yields -i, not -it ---

assert_contains "awsenv: AWSENV_TTY=never uses -i" "$argv" "-i"
assert_not_contains "awsenv: AWSENV_TTY=never does not use -it" "$argv" "-it"

# --- AWSENV_TTY=always yields -it even with non-tty stdin ---

: >"$STUB_LOG"
set +e
AWSENV_TTY=always "$REPO_DIR/awsenv.sh" aws --version </dev/null >"$WORK_DIR/out2.log" 2>&1
status2=$?
set -e
assert_true "awsenv AWSENV_TTY=always: exits successfully" "$status2"
assert_contains "awsenv: AWSENV_TTY=always uses -it" "$(docker_argv)" "-it"

# --- mount paths with spaces survive as a single argv word ---

space_dir="$WORK_DIR/dir with space"
mkdir -p "$space_dir"
: >"$STUB_LOG"
set +e
(cd "$space_dir" && AWSENV_TTY=never "$REPO_DIR/awsenv.sh" aws --version) >"$WORK_DIR/out3.log" 2>&1
status3=$?
set -e
assert_true "awsenv: cwd with a space in the path succeeds" "$status3"
assert_contains "awsenv: cwd-with-space mount is one argv word" "$(docker_argv)" "$space_dir:$space_dir:rw"

# --- AWSENV_PWD_MODE=off skips the cwd mount ---

: >"$STUB_LOG"
set +e
AWSENV_TTY=never AWSENV_PWD_MODE=off "$REPO_DIR/awsenv.sh" aws --version >"$WORK_DIR/out4.log" 2>&1
status4=$?
set -e
assert_true "awsenv AWSENV_PWD_MODE=off: exits successfully" "$status4"
assert_not_contains "awsenv: AWSENV_PWD_MODE=off has no rw cwd mount" "$(docker_argv)" ":$REPO_DIR:rw"

# --- first-run image build output never pollutes captured stdout ---

: >"$STUB_LOG"
set +e
captured=$(AWSENV_TTY=never STUB_DOCKER_IMAGE_EXISTS=0 STUB_DOCKER_BUILD_STDOUT_NOISE=1 "$REPO_DIR/awsenv.sh" aws --version 2>"$WORK_DIR/stderr.log")
status5=$?
set -e
assert_true "awsenv first-run build: exits successfully" "$status5"
assert_not_contains "awsenv: build progress noise does not leak into captured stdout" "$captured" "SIMULATED_BUILD_PROGRESS"
assert_contains "awsenv: build progress noise goes to stderr instead" "$(cat "$WORK_DIR/stderr.log")" "SIMULATED_BUILD_PROGRESS"

# --- -h exits 0 ---

set +e
"$REPO_DIR/awsenv.sh" -h >/dev/null 2>&1
h_status=$?
set -e
assert_eq "awsenv -h exits 0" "0" "$h_status"

# --- invalid AWSENV_TTY value is rejected ---

set +e
AWSENV_TTY=bogus "$REPO_DIR/awsenv.sh" aws --version >/dev/null 2>&1
bogus_status=$?
set -e
assert_false "awsenv: invalid AWSENV_TTY is rejected" "$bogus_status"

test_summary
