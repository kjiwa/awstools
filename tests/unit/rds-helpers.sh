#!/bin/sh

# Unit tests for rdsclient.sh helper functions: normalize_placeholder,
# determine_client, and the jq-based list assembly functions
# get_standalone_instances/get_cluster_endpoints.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/../fixtures/rds"
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

# --- normalize_placeholder ---

assert_eq "normalize_placeholder: '-' becomes empty" "" "$(normalize_placeholder "-")"
assert_eq "normalize_placeholder: passes through real values" "admin" "$(normalize_placeholder "admin")"

# --- determine_client ---

ENGINE="postgres"
determine_client
assert_eq "determine_client: postgres CLIENT" "psql" "$CLIENT"
assert_eq "determine_client: postgres PASSWORD_ENV" "PGPASSWORD" "$PASSWORD_ENV"

ENGINE="aurora-mysql"
determine_client
assert_eq "determine_client: aurora-mysql CLIENT" "mysql" "$CLIENT"
assert_eq "determine_client: aurora-mysql PASSWORD_ENV" "MYSQL_PWD" "$PASSWORD_ENV"

ENGINE="oracle-se2"
determine_client
assert_eq "determine_client: oracle CLIENT" "sqlplus" "$CLIENT"
assert_eq "determine_client: oracle has no PASSWORD_ENV" "" "$PASSWORD_ENV"

ENGINE="sqlserver-ee"
determine_client
assert_eq "determine_client: sqlserver CLIENT" "sqlcmd" "$CLIENT"
assert_contains "determine_client: sqlserver uses mssql-tools18" "$DOCKER_IMAGE" "mssql-tools18"

ENGINE="docdb"
run_capture determine_client
assert_false "determine_client: unsupported engine fails" "$RUN_STATUS"

# --- get_standalone_instances: single-pass TSV, no separate describe call ---

instances_json=$(cat "$FIXTURES_DIR/instances_basic.json" | jq '.DBInstances')
row=$(get_standalone_instances "$instances_json")
assert_eq "get_standalone_instances: row count" "1" "$(count_lines "$row")"
assert_contains "get_standalone_instances: identifier present" "$row" "standalone-postgres"
assert_contains "get_standalone_instances: type is rds" "$row" "	rds	"
db_name_field=$(printf "%s" "$row" | cut -f6)
assert_eq "get_standalone_instances: missing DBName becomes placeholder '-'" "-" "$db_name_field"

secret_instances_json=$(cat "$FIXTURES_DIR/instances_with_secret.json" | jq '.DBInstances')
secret_row=$(get_standalone_instances "$secret_instances_json")
secret_arn_field=$(printf "%s" "$secret_row" | cut -f9)
assert_contains "get_standalone_instances: MasterUserSecret.SecretArn is captured in the TSV" "$secret_arn_field" "arn:aws:secretsmanager"
iam_field=$(printf "%s" "$secret_row" | cut -f8)
assert_eq "get_standalone_instances: IAMDatabaseAuthenticationEnabled=false is captured" "false" "$iam_field"

# --- get_cluster_endpoints: single jq pass, non-RDS engines filtered ---

clusters_json=$(cat "$FIXTURES_DIR/clusters_mixed.json" | jq '.DBClusters')
rows=$(get_cluster_endpoints "$clusters_json" "")
assert_eq "get_cluster_endpoints: docdb/neptune filtered, aurora writer+reader, multiaz writer" "3" "$(count_lines "$rows")"
assert_not_contains "get_cluster_endpoints: docdb is excluded" "$rows" "docdb"
assert_not_contains "get_cluster_endpoints: neptune is excluded" "$rows" "neptune"
assert_contains "get_cluster_endpoints: aurora writer endpoint present" "$rows" "analytics-cluster.cluster-abc123"
assert_contains "get_cluster_endpoints: aurora reader endpoint present" "$rows" "analytics-cluster.cluster-ro-abc123"
assert_contains "get_cluster_endpoints: multi-az postgres cluster present" "$rows" "multiaz-postgres-cluster"

writer_only=$(get_cluster_endpoints "$clusters_json" "writer")
assert_eq "get_cluster_endpoints: writer-only endpoint_type filters reader rows" "2" "$(count_lines "$writer_only")"
assert_not_contains "get_cluster_endpoints: writer-only excludes reader endpoint" "$writer_only" "cluster-ro-abc123"

reader_only=$(get_cluster_endpoints "$clusters_json" "reader")
assert_eq "get_cluster_endpoints: reader-only skips clusters without a reader" "1" "$(count_lines "$reader_only")"

test_summary
