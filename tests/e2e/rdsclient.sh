#!/bin/sh

# End-to-end tests for rdsclient.sh against the stubbed aws/docker/jq
# toolchain. Exercises only single-match auto-connect paths, since the
# interactive multi-match prompt reads from /dev/tty (covered instead by
# the function-level unit tests).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/rds"
STUBS_DIR="$SCRIPT_DIR/../stubs"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_DIR/../lib/harness.sh"
# shellcheck source=../lib/extract.sh
. "$SCRIPT_DIR/../lib/extract.sh"

WORK_DIR="$(mktemp -d)"
STUB_LOG="$WORK_DIR/stub.log"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM HUP

export PATH="$STUBS_DIR:$PATH"
export STUB_LOG

count_calls() {
  # count_calls <program>
  grep -c "^=== $1 ===\$" "$STUB_LOG" 2>/dev/null || true
}

# --- query_databases makes exactly 2 aws calls ---

: >"$STUB_LOG"
TMP_SCRIPT="$WORK_DIR/rdsclient_functions.sh"
load_script_functions "$REPO_DIR/rdsclient.sh" "$TMP_SCRIPT"
set +e
(
  # shellcheck source=/dev/null
  . "$TMP_SCRIPT"
  TAG_COUNT=0
  ENDPOINT_TYPE=""
  FIXTURE_DB_INSTANCES="$FIXTURES_DIR/instances_basic.json"
  FIXTURE_DB_CLUSTERS="$FIXTURES_DIR/clusters_mixed.json"
  export FIXTURE_DB_INSTANCES FIXTURE_DB_CLUSTERS TAG_COUNT ENDPOINT_TYPE
  query_databases >"$WORK_DIR/database_list.txt" 2>/dev/null
)
query_status=$?
set -e
assert_true "query_databases: subshell ran without error" "$query_status"
assert_eq "query_databases: exactly 2 aws calls (describe-instances + describe-clusters)" "2" "$(count_calls aws)"

# --- full run, single postgres instance, IAM auth: no extra describe call ---

printf '{"DBClusters":[]}' >"$WORK_DIR/empty_clusters.json"

: >"$STUB_LOG"
set +e
env \
  FIXTURE_DB_INSTANCES="$FIXTURES_DIR/instances_basic.json" \
  FIXTURE_DB_CLUSTERS="$WORK_DIR/empty_clusters.json" \
  FIXTURE_IAM_TOKEN="tok3n-with a space" \
  "$REPO_DIR/rdsclient.sh" -a iam >"$WORK_DIR/out.log" 2>&1
status=$?
set -e
assert_true "rdsclient -a iam (single match): exits successfully" "$status"
assert_eq "rdsclient -a iam: exactly 3 aws calls (2 describes + 1 auth token)" "3" "$(count_calls aws)"

docker_section=$(awk '/^=== docker ===$/{p=1} p' "$STUB_LOG")
assert_contains "rdsclient -a iam: docker argv forwards PGPASSWORD via -e" "$docker_section" "PGPASSWORD"
assert_not_contains "rdsclient -a iam: password never appears in docker argv" "$docker_section" "tok3n-with a space"
assert_contains "rdsclient -a iam: postgres connect defaults DB name" "$docker_section" "/postgres?sslmode=require"

out_content=$(cat "$WORK_DIR/out.log")
assert_contains "rdsclient -a iam: reports found database" "$out_content" "Found database: standalone-postgres"

# --- Oracle without DatabaseName fails with a clear error ---

: >"$STUB_LOG"
cat >"$WORK_DIR/oracle_instance.json" <<'JSON'
{
  "DBInstances": [
    {
      "DBInstanceIdentifier": "ora-nodbname",
      "Engine": "oracle-se2",
      "Endpoint": {"Address": "ora.example.com", "Port": 1521},
      "DBClusterIdentifier": null,
      "MasterUsername": "admin",
      "IAMDatabaseAuthenticationEnabled": true
    }
  ]
}
JSON
set +e
env \
  FIXTURE_DB_INSTANCES="$WORK_DIR/oracle_instance.json" \
  FIXTURE_DB_CLUSTERS="$WORK_DIR/empty_clusters.json" \
  FIXTURE_IAM_TOKEN="oracletoken" \
  "$REPO_DIR/rdsclient.sh" -a iam >"$WORK_DIR/oracle_out.log" 2>&1
oracle_status=$?
set -e
assert_false "rdsclient: Oracle without DatabaseName fails" "$oracle_status"
assert_contains "rdsclient: Oracle error message is specific" "$(cat "$WORK_DIR/oracle_out.log")" "Oracle requires it to connect"

# --- -h exits 0 ---

set +e
"$REPO_DIR/rdsclient.sh" -h >/dev/null 2>&1
h_status=$?
set -e
assert_eq "rdsclient -h exits 0" "0" "$h_status"

# --- unexpected positional argument rejected ---

set +e
"$REPO_DIR/rdsclient.sh" unexpected-arg >/dev/null 2>&1
extra_status=$?
set -e
assert_false "rdsclient: unexpected positional argument is rejected" "$extra_status"

test_summary
