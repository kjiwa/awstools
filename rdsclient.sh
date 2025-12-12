#!/bin/sh

# MIT License
#
# Copyright (c) 2025 Kamil Jiwa
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -eu

# ==============================================================================
# Script Setup
# ==============================================================================

AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
ENDPOINT_TYPE=""
AUTH_TYPE=""
TAG_KEYS=""
TAG_VALUES=""
TAG_COUNT=0
DB_USER=""
DB_PASSWORD=""
CONTAINER_NAME=""
SSL_MODE="true"

# ==============================================================================
# User Interface
# ==============================================================================

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Optional:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -e ENDPOINT_TYPE  Aurora endpoint type (reader or writer)
  -a AUTH_TYPE      Authentication type (iam, secret, or manual)
  -u DB_USER        Database user (sets auth to manual)
  -s SSL_MODE       Use SSL connection (true or false, default: true)

Environment Variables:
  AWS_PROFILE              AWS profile (can be overridden with -p)
  AWS_REGION               AWS region (can be overridden with -r)
  AWS_DEFAULT_REGION       AWS region fallback if AWS_REGION not set
  AWS_ACCESS_KEY_ID        AWS access key ID
  AWS_SECRET_ACCESS_KEY    AWS secret access key
  AWS_SESSION_TOKEN        AWS session token for temporary credentials

Examples:
  $0
  $0 -t Environment=prod
  $0 -t Environment=prod -t Application=api -a iam
  $0 -t Environment=staging -e writer
  $0 -u myuser -a manual
  $0 -t Environment=dev -s false
EOF
  exit 1
}

error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}

# ==============================================================================
# Cleanup Handler
# ==============================================================================

cleanup() {
  if [ -n "$CONTAINER_NAME" ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

# ==============================================================================
# String Utilities
# ==============================================================================

trim_whitespace() {
  printf "%s" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# ==============================================================================
# User Input
# ==============================================================================

read_password() {
  printf "Enter database password: " >&2
  stty -echo 2>/dev/null || true
  read -r password_input </dev/tty
  stty echo 2>/dev/null || true
  printf "\n" >&2

  [ -z "$password_input" ] && error_exit "Password cannot be empty"
  DB_PASSWORD="$password_input"
}

# ==============================================================================
# Tag Parsing & Validation
# ==============================================================================

parse_tag_argument() {
  arg="$1"

  case "$arg" in
  *=*)
    PARSED_KEY="${arg%%=*}"
    PARSED_VALUE="${arg#*=}"
    ;;
  *)
    PARSED_KEY=""
    PARSED_VALUE=""
    ;;
  esac
}

validate_tag_format() {
  original="$1"
  key="$2"
  value="$3"

  [ -z "$key" ] && error_exit "Invalid tag format '$original': must contain '=' character"

  trimmed_key=$(trim_whitespace "$key")
  [ -z "$trimmed_key" ] &&  error_exit "Invalid tag format '$original': key cannot be empty"

  case "$trimmed_key" in
  *[\$\`\\\"\']*)
    error_exit "Invalid tag format '$original': key contains unsafe characters"
    ;;
  esac

  trimmed_value=$(trim_whitespace "$value")
  [ -z "$trimmed_value" ] && error_exit "Invalid tag format '$original': value cannot be empty"
  case "$trimmed_value" in
  *[\$\`\\\"\']*)
    error_exit "Invalid tag format '$original': value contains unsafe characters"
    ;;
  esac

  PARSED_KEY="$trimmed_key"
  PARSED_VALUE="$trimmed_value"
}

accumulate_tags() {
  key="$1"
  value="$2"

  if [ -z "$TAG_KEYS" ]; then
    TAG_KEYS="$key"
    TAG_VALUES="$value"
  else
    TAG_KEYS="$TAG_KEYS $key"
    TAG_VALUES="$TAG_VALUES $value"
  fi

  TAG_COUNT=$((TAG_COUNT + 1))
}

get_tag_at_index() {
  idx="$1"
  TAG_KEY_AT_INDEX=$(printf "%s" "$TAG_KEYS" | sed -n "${idx}p")
  TAG_VALUE_AT_INDEX=$(printf "%s" "$TAG_VALUES" | sed -n "${idx}p")
}

# ==============================================================================
# Argument Parsing
# ==============================================================================

parse_options() {
  while getopts "p:r:e:a:t:u:s:h" opt; do
    case $opt in
    p) AWS_PROFILE="$OPTARG" ;;
    r) AWS_REGION="$OPTARG" ;;
    e) ENDPOINT_TYPE="$OPTARG" ;;
    a) AUTH_TYPE="$OPTARG" ;;
    t)
      parse_tag_argument "$OPTARG"
      validate_tag_format "$OPTARG" "$PARSED_KEY" "$PARSED_VALUE"
      accumulate_tags "$PARSED_KEY" "$PARSED_VALUE"
      ;;
    u) DB_USER="$OPTARG" ;;
    s) SSL_MODE="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
    esac
  done
}

# ==============================================================================
# Parameter Validation
# ==============================================================================

validate_endpoint_type() {
  [ -n "$ENDPOINT_TYPE" ] || return 0
  case "$ENDPOINT_TYPE" in
  reader | writer) ;;
  *) error_exit "Endpoint type must be: reader or writer" ;;
  esac
}

validate_auth_type() {
  [ -n "$AUTH_TYPE" ] || return 0
  case "$AUTH_TYPE" in
  iam | secret | manual) ;;
  *) error_exit "Authentication type must be: iam, secret, or manual" ;;
  esac
}

validate_ssl_mode() {
  case "$SSL_MODE" in
  true | false) ;;
  *) error_exit "SSL mode must be: true or false" ;;
  esac
}

validate_region() {
  case "$AWS_REGION" in
  *[\$\`\\\"\'\;]*)
    error_exit "Region contains unsafe characters"
    ;;
  esac
}

validate_profile() {
  [ -n "$AWS_PROFILE" ] || return 0
  case "$AWS_PROFILE" in
  *[\$\`\\\"\'\;]*)
    error_exit "Profile contains unsafe characters"
    ;;
  esac
}

validate_parameters() {
  validate_endpoint_type
  validate_auth_type
  validate_ssl_mode
  validate_region
  validate_profile
}

# ==============================================================================
# Dependency Checking
# ==============================================================================

check_dependencies() {
  for tool in aws jq docker; do
    command -v "$tool" >/dev/null 2>&1 || error_exit "'$tool' is required but not found"
  done
}

# ==============================================================================
# AWS Command Building
# ==============================================================================

build_aws_command() {
  if [ -n "$AWS_PROFILE" ]; then
    AWS_CMD="aws --profile $AWS_PROFILE --region $AWS_REGION --output json"
  else
    AWS_CMD="aws --region $AWS_REGION --output json"
  fi
}

# ==============================================================================
# Tag Filtering & Query
# ==============================================================================

build_jq_tag_selector() {
  key="$1"
  value="$2"
  printf 'select(.TagList[]? | select(.Key == "%s" and .Value == "%s"))' "$key" "$value"
}

build_rds_tag_filter() {
  if [ "$TAG_COUNT" -eq 0 ]; then
    printf "."
    return
  fi

  filter=""
  i=1
  while [ "$i" -le "$TAG_COUNT" ]; do
    get_tag_at_index "$i"
    selector=$(build_jq_tag_selector "$TAG_KEY_AT_INDEX" "$TAG_VALUE_AT_INDEX")

    if [ -n "$filter" ]; then
      filter="$filter | "
    fi
    filter="$filter$selector"

    i=$((i + 1))
  done

  printf "[.[] | %s]" "$filter"
}

filter_by_tags() {
  json_data="$1"
  resource_type="$2"

  tag_filter=$(build_rds_tag_filter)
  resource_data=$(printf "%s" "$json_data" | jq ".$resource_type")
  printf "%s" "$resource_data" | jq "$tag_filter"
}

build_tag_display_message() {
  if [ "$TAG_COUNT" -eq 0 ]; then
    printf "all databases"
    return
  fi

  if [ "$TAG_COUNT" -eq 1 ]; then
    get_tag_at_index 1
    printf "databases with %s=%s" "$TAG_KEY_AT_INDEX" "$TAG_VALUE_AT_INDEX"
    return
  fi

  printf "databases with %d tag filters" "$TAG_COUNT"
}

query_databases() {
  message=$(build_tag_display_message)
  printf "Searching for %s...\n" "$message" >&2

  instances_json=$(AWSENV_TTY=never $AWS_CMD rds describe-db-instances 2>/dev/null || printf '{"DBInstances":[]}')
  clusters_json=$(AWSENV_TTY=never $AWS_CMD rds describe-db-clusters 2>/dev/null || printf '{"DBClusters":[]}')

  filtered_instances=$(filter_by_tags "$instances_json" "DBInstances")
  filtered_clusters=$(filter_by_tags "$clusters_json" "DBClusters")

  temp_file=$(create_temp_file)
  trap 'rm -f "$temp_file"' EXIT

  DATABASE_LIST=$(assemble_database_list "$filtered_instances" "$filtered_clusters" "$temp_file")
  rm -f "$temp_file"

  [ -z "$DATABASE_LIST" ] && error_exit "No databases found matching filters"

  return 0
}

# ==============================================================================
# Database List Assembly
# ==============================================================================

get_standalone_instances() {
  instances_json="$1"
  printf "%s" "$instances_json" | jq '[.[] | select(.DBClusterIdentifier == null or .DBClusterIdentifier == "")] | sort_by(.DBInstanceIdentifier)' |
    jq -r '.[] | [.DBInstanceIdentifier, .Engine, .Endpoint.Address, "rds"] | @tsv'
}

get_cluster_endpoints() {
  clusters_json="$1"
  endpoint_type="$2"

  printf "%s" "$clusters_json" | jq -c 'sort_by(.DBClusterIdentifier) | .[]' | while read -r cluster; do
    cluster_id=$(printf "%s" "$cluster" | jq -r '.DBClusterIdentifier')
    engine=$(printf "%s" "$cluster" | jq -r '.Engine')
    writer_endpoint=$(printf "%s" "$cluster" | jq -r '.Endpoint')
    reader_endpoint=$(printf "%s" "$cluster" | jq -r '.ReaderEndpoint // empty')

    if [ -z "$endpoint_type" ]; then
      printf "%s\t%s\t%s\t%s\n" "$cluster_id" "$engine" "$writer_endpoint" "aurora"
      [ -n "$reader_endpoint" ] && printf "%s\t%s\t%s\t%s\n" "$cluster_id" "$engine" "$reader_endpoint" "aurora"
    elif [ "$endpoint_type" = "writer" ]; then
      printf "%s\t%s\t%s\t%s\n" "$cluster_id" "$engine" "$writer_endpoint" "aurora"
    elif [ "$endpoint_type" = "reader" ] && [ -n "$reader_endpoint" ]; then
      printf "%s\t%s\t%s\t%s\n" "$cluster_id" "$engine" "$reader_endpoint" "aurora"
    fi
  done
}

create_temp_file() {
  temp_dir="${TMPDIR:-/tmp}"
  temp_base="rdsclient.$$"
  counter=0

  while true; do
    temp_file="$temp_dir/$temp_base.$counter"
    (
      set -C
      : >"$temp_file"
    ) 2>/dev/null && break

    counter=$((counter + 1))
    [ "$counter" -gt 1000 ] && error_exit "Failed to create temporary file"
  done

  printf "%s" "$temp_file"
}

assemble_database_list() {
  filtered_instances="$1"
  filtered_clusters="$2"
  temp_file="$3"

  get_standalone_instances "$filtered_instances" >"$temp_file"
  get_cluster_endpoints "$filtered_clusters" "$ENDPOINT_TYPE" >>"$temp_file"

  cat "$temp_file"
}

# ==============================================================================
# Database Selection
# ==============================================================================

count_lines() {
  text="$1"
  if [ -z "$text" ]; then
    printf "0"
    return
  fi
  printf "%s\n" "$text" | grep -c .
}

display_databases() {
  printf "\n" >&2
  i=1
  printf "%s\n" "$DATABASE_LIST" | while IFS="$(printf '\t')" read -r id engine endpoint type; do
    if [ -n "$id" ]; then
      if [ "$type" = "aurora" ]; then
        printf "%d. [Aurora] %s (%s): %s\n" "$i" "$id" "$engine" "$endpoint" >&2
      else
        printf "%d. [RDS] %s (%s): %s\n" "$i" "$id" "$engine" "$endpoint" >&2
      fi
      i=$((i + 1))
    fi
  done
  printf "\n" >&2
}

read_user_selection() {
  max="$1"

  while true; do
    printf "Select database (1-%d): " "$max" >&2
    read -r selection </dev/tty || exit 1

    case "$selection" in
    '' | *[!0-9]*)
      printf "ERROR: Invalid selection\n" >&2
      continue
      ;;
    esac

    if [ "$selection" -ge 1 ] && [ "$selection" -le "$max" ]; then
      printf "%s" "$selection"
      return 0
    fi

    printf "ERROR: Selection must be between 1 and %d\n" "$max" >&2
  done
}

select_database() {
  count=$(count_lines "$DATABASE_LIST")

  [ "$count" -eq 0 ] && error_exit "No databases found"
  if [ "$count" -eq 1 ]; then
    printf "Connecting to database...\n" >&2
    selection=1
  else
    display_databases
    selection=$(read_user_selection "$count")
  fi

  SELECTED_LINE=$(printf "%s" "$DATABASE_LIST" | sed -n "${selection}p")
  DB_IDENTIFIER=$(printf "%s" "$SELECTED_LINE" | cut -f1)
  ENGINE=$(printf "%s" "$SELECTED_LINE" | cut -f2)
  ENDPOINT=$(printf "%s" "$SELECTED_LINE" | cut -f3)
  DB_TYPE=$(printf "%s" "$SELECTED_LINE" | cut -f4)
}

# ==============================================================================
# Database Details
# ==============================================================================

extract_db_field() {
  details="$1"
  resource_type="$2"
  field_path="$3"

  value=$(printf "%s" "$details" | jq -r ".${resource_type}[0].${field_path}")

  case "$value" in
  "" | "null") printf "" ;;
  *) printf "%s" "$value" ;;
  esac
}

get_database_details() {
  if [ "$DB_TYPE" = "aurora" ]; then
    details=$(AWSENV_TTY=never $AWS_CMD rds describe-db-clusters --db-cluster-identifier "$DB_IDENTIFIER" 2>/dev/null)
    resource_type="DBClusters"
    field_prefix=""
  else
    details=$(AWSENV_TTY=never $AWS_CMD rds describe-db-instances --db-instance-identifier "$DB_IDENTIFIER" 2>/dev/null)
    resource_type="DBInstances"
    field_prefix="Endpoint."
  fi

  PORT=$(extract_db_field "$details" "$resource_type" "${field_prefix}Port")
  DB_NAME=$(extract_db_field "$details" "$resource_type" "DatabaseName")
  MASTER_USER=$(extract_db_field "$details" "$resource_type" "MasterUsername")
  IAM_ENABLED=$(extract_db_field "$details" "$resource_type" "IAMDatabaseAuthenticationEnabled")
  SECRET_ARN=$(extract_db_field "$details" "$resource_type" "MasterUserSecret.SecretArn // empty")

  [ -z "$PORT" ] && error_exit "Failed to retrieve database port"
  [ -z "$DB_NAME" ] && error_exit "Failed to retrieve database name"

  if [ -z "$MASTER_USER" ]; then
    [ -z "$DB_USER" ] && error_exit "Failed to retrieve master username. Specify username with -u"
  fi

  printf "Found database: %s (%s:%s/%s)\n" "$DB_IDENTIFIER" "$ENDPOINT" "$PORT" "$DB_NAME" >&2
}

determine_client() {
  case "$ENGINE" in
  postgres | aurora-postgresql)
    DOCKER_IMAGE="postgres:alpine"
    PASSWORD_ENV="PGPASSWORD"
    ;;
  mysql | aurora-mysql | mariadb)
    DOCKER_IMAGE="mysql:latest"
    PASSWORD_ENV="MYSQL_PWD"
    ;;
  oracle-ee | oracle-ee-cdb | oracle-se2 | oracle-se2-cdb)
    DOCKER_IMAGE="container-registry.oracle.com/database/instantclient:latest"
    PASSWORD_ENV="ORACLE_PASSWORD"
    ;;
  sqlserver-ee | sqlserver-se | sqlserver-ex | sqlserver-web)
    DOCKER_IMAGE="mcr.microsoft.com/mssql-tools"
    PASSWORD_ENV="SQLCMDPASSWORD"
    ;;
  *)
    error_exit "Unsupported database engine: $ENGINE"
    ;;
  esac
}

# ==============================================================================
# Authentication
# ==============================================================================

authenticate_manual() {
  read_password
  FINAL_USER="${DB_USER:-$MASTER_USER}"
  FINAL_PASSWORD="$DB_PASSWORD"
}

authenticate_iam() {
  printf "Generating IAM authentication token...\n" >&2

  FINAL_USER="$MASTER_USER"
  token=$(AWSENV_TTY=never $AWS_CMD rds generate-db-auth-token \
    --hostname "$ENDPOINT" \
    --port "$PORT" \
    --username "$MASTER_USER" \
    --output text 2>/dev/null || printf "")

  [ -z "$token" ] && error_exit "Failed to generate IAM authentication token"
  FINAL_PASSWORD="$token"
}

authenticate_secret() {
  [ -z "$SECRET_ARN" ] && error_exit "No AWS Secrets Manager secret found for this database"

  printf "Retrieving credentials from AWS Secrets Manager...\n" >&2
  secret_value=$(AWSENV_TTY=never $AWS_CMD secretsmanager get-secret-value \
    --secret-id "$SECRET_ARN" \
    --query SecretString \
    --output text 2>/dev/null || printf "")

  [ -z "$secret_value" ] && error_exit "Failed to retrieve secret from Secrets Manager"

  FINAL_USER=$(printf "%s" "$secret_value" | jq -r '.username // empty')
  FINAL_PASSWORD=$(printf "%s" "$secret_value" | jq -r '.password // empty')
  [ -z "$FINAL_USER" ] || [ -z "$FINAL_PASSWORD" ] && error_exit "Failed to parse credentials from Secrets Manager"

  return 0
}

authenticate_auto() {
  printf "Auto-detecting authentication method...\n" >&2
  if [ "$IAM_ENABLED" = "true" ]; then
    AUTH_TYPE="iam"
  elif [ -n "$SECRET_ARN" ]; then
    AUTH_TYPE="secret"
  else
    AUTH_TYPE="manual"
  fi

  authenticate
}

authenticate() {
  case "$AUTH_TYPE" in
  manual) authenticate_manual ;;
  iam) authenticate_iam ;;
  secret) authenticate_secret ;;
  *) authenticate_auto ;;
  esac
}

# ==============================================================================
# Connection Operations
# ==============================================================================

connect_to_postgresql() {
  ssl_mode=""
  [ "$SSL_MODE" = "true" ] && ssl_mode="?sslmode=require"
  eval "$docker_cmd psql 'postgresql://$FINAL_USER@$ENDPOINT:$PORT/$DB_NAME$ssl_mode'"
}

connect_to_mysql() {
  ssl_arg=""
  [ "$SSL_MODE" = "true" ] && ssl_arg="--ssl-mode=REQUIRED"
  eval "$docker_cmd mysql -h '$ENDPOINT' -P '$PORT' -u '$FINAL_USER' -D '$DB_NAME' $ssl_arg"
}

connect_to_oracle() {
  eval "$docker_cmd sqlplus '$FINAL_USER/\$ORACLE_PASSWORD@//$ENDPOINT:$PORT/$DB_NAME'"
}

connect_to_sqlserver() {
  encrypt_arg=""
  [ "$SSL_MODE" = "true" ] && encrypt_arg="-N"
  eval "$docker_cmd sqlcmd -S '$ENDPOINT,$PORT' -U '$FINAL_USER' -d '$DB_NAME' $encrypt_arg"
}

connect_database() {
  printf "Connecting to %s as %s...\n" "$DB_IDENTIFIER" "$FINAL_USER" >&2

  CONTAINER_NAME="dbclient-$$-$(date +%s%N 2>/dev/null || date +%s)"

  docker_cmd="docker run --rm -it --name '$CONTAINER_NAME' -e $PASSWORD_ENV='$FINAL_PASSWORD' '$DOCKER_IMAGE'"

  case "$ENGINE" in
  postgres | aurora-postgresql) connect_to_postgresql ;;
  mysql | aurora-mysql | mariadb) connect_to_mysql ;;
  oracle-ee | oracle-ee-cdb | oracle-se2 | oracle-se2-cdb) connect_to_oracle ;;
  sqlserver-ee | sqlserver-se | sqlserver-ex | sqlserver-web) connect_to_sqlserver ;;
  esac
}

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
  trap cleanup EXIT INT TERM HUP
  parse_options "$@"
  validate_parameters
  check_dependencies
  build_aws_command
  query_databases
  select_database
  get_database_details
  determine_client
  authenticate
  connect_database
}

main "$@"
