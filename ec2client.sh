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

CONNECT_METHOD="ssm"
SSH_USER="ec2-user"
SSH_KEY_FILE=""
TAG_KEYS=""
TAG_VALUES=""
TAG_COUNT=0
SELECTED_ID=""
SELECTED_IP=""
SSM_COMMAND="sh"

# ==============================================================================
# User Interface
# ==============================================================================

usage() {
  exit_code="${1:-1}"

  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Optional:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -c METHOD         Connection method (ssh or ssm, default: ssm)
  -u USER           SSH user (default: ec2-user)
  -k KEYFILE        SSH private key file path
  -s COMMAND        SSM command to execute (default: sh)
  -h                Show this help message

Environment Variables:
  AWS_PROFILE              AWS profile
  AWS_REGION               AWS region
  AWS_DEFAULT_REGION       AWS region fallback if AWS_REGION not set
  AWS_ACCESS_KEY_ID        AWS access key ID
  AWS_SECRET_ACCESS_KEY    AWS secret access key
  AWS_SESSION_TOKEN        AWS session token for temporary credentials

Profile and region are resolved by the AWS CLI itself from the environment
variables above or from ~/.aws/config; this tool passes no --profile or
--region flags.

Examples:
  $0
  $0 -t Environment=prod
  $0 -t Environment=prod -t Team=backend
  $0 -t Name=bastion -c ssh -k ~/.ssh/mykey.pem
  $0 -t Environment=staging -s "cd; bash -l"
EOF
  exit "$exit_code"
}

# --- BEGIN SHARED: error_exit ---
error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}
# --- END SHARED: error_exit ---

# ==============================================================================
# String Utilities
# ==============================================================================

# --- BEGIN SHARED: trim_whitespace ---
trim_whitespace() {
  printf "%s" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
# --- END SHARED: trim_whitespace ---

# ==============================================================================
# Tag Parsing & Validation
# ==============================================================================

# --- BEGIN SHARED: parse_tag_argument ---
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
# --- END SHARED: parse_tag_argument ---

# --- BEGIN SHARED: validate_tag_format ---
validate_tag_format() {
  original="$1"
  key="$2"
  value="$3"

  [ -z "$key" ] && error_exit "Invalid tag format '$original': must contain '=' character"

  trimmed_key=$(trim_whitespace "$key")
  [ -z "$trimmed_key" ] && error_exit "Invalid tag format '$original': key cannot be empty"
  case "$trimmed_key" in
  *[\$\`\\\"\']*) error_exit "Invalid tag format '$original': key contains unsafe characters" ;;
  esac

  trimmed_value=$(trim_whitespace "$value")
  [ -z "$trimmed_value" ] && error_exit "Invalid tag format '$original': value cannot be empty"
  case "$trimmed_value" in
  *[\$\`\\\"\']*) error_exit "Invalid tag format '$original': value contains unsafe characters" ;;
  esac

  PARSED_KEY="$trimmed_key"
  PARSED_VALUE="$trimmed_value"
}
# --- END SHARED: validate_tag_format ---

reject_comma_in_tag_value() {
  # EC2 filters treat ',' as a value-list separator (logical OR), which would
  # silently contradict the documented exact-match AND semantics of -t.
  value="$1"
  case "$value" in
  *,*) error_exit "Invalid tag value '$value': ',' is not supported (EC2 filters treat it as a value separator)" ;;
  esac
}

# --- BEGIN SHARED: accumulate_tags ---
accumulate_tags() {
  key="$1"
  value="$2"

  if [ -z "$TAG_KEYS" ]; then
    TAG_KEYS="$key"
    TAG_VALUES="$value"
  else
    TAG_KEYS="$TAG_KEYS
$key"
    TAG_VALUES="$TAG_VALUES
$value"
  fi

  TAG_COUNT=$((TAG_COUNT + 1))
}
# --- END SHARED: accumulate_tags ---

# --- BEGIN SHARED: get_tag_at_index ---
get_tag_at_index() {
  idx="$1"
  TAG_KEY_AT_INDEX=$(printf "%s" "$TAG_KEYS" | sed -n "${idx}p")
  TAG_VALUE_AT_INDEX=$(printf "%s" "$TAG_VALUES" | sed -n "${idx}p")
}
# --- END SHARED: get_tag_at_index ---

# ==============================================================================
# Argument Parsing
# ==============================================================================

parse_options() {
  while getopts "t:c:u:k:s:h" opt; do
    case "$opt" in
    t)
      parse_tag_argument "$OPTARG"
      validate_tag_format "$OPTARG" "$PARSED_KEY" "$PARSED_VALUE"
      reject_comma_in_tag_value "$PARSED_VALUE"
      accumulate_tags "$PARSED_KEY" "$PARSED_VALUE"
      ;;
    c) CONNECT_METHOD="$OPTARG" ;;
    u) SSH_USER="$OPTARG" ;;
    k) SSH_KEY_FILE="$OPTARG" ;;
    s) SSM_COMMAND="$OPTARG" ;;
    h) usage 0 ;;
    *) usage ;;
    esac
  done

  shift $((OPTIND - 1))
  [ $# -gt 0 ] && error_exit "Unexpected argument: $1"

  return 0
}

# ==============================================================================
# Parameter Validation
# ==============================================================================

validate_connect_method() {
  case "$CONNECT_METHOD" in
  ssh | ssm) ;;
  *) error_exit "Connection method must be: ssh or ssm" ;;
  esac
}

validate_ssh_key_file() {
  [ -n "$SSH_KEY_FILE" ] || return 0
  [ -f "$SSH_KEY_FILE" ] || error_exit "SSH private key file not found: $SSH_KEY_FILE"
  case "$SSH_KEY_FILE" in
  *[\$\`\\\"\'\ ]*) error_exit "SSH key file path contains unsafe characters" ;;
  esac
}

validate_ssh_user() {
  case "$SSH_USER" in
  *[\$\`\\\"\'\;\ ]*) error_exit "SSH user contains unsafe characters" ;;
  "") error_exit "SSH user cannot be empty" ;;
  esac
}

validate_parameters() {
  validate_connect_method
  validate_ssh_key_file
  validate_ssh_user
}

# ==============================================================================
# Dependency Checking
# ==============================================================================

check_dependencies() {
  for tool in aws jq; do
    command -v "$tool" >/dev/null 2>&1 || error_exit "'$tool' is required but not found"
  done

  if [ "$CONNECT_METHOD" = "ssm" ]; then
    command -v session-manager-plugin >/dev/null 2>&1 || error_exit "'session-manager-plugin' is required but not found"
  fi

  if [ "$CONNECT_METHOD" = "ssh" ]; then
    command -v ssh >/dev/null 2>&1 || error_exit "'ssh' is required but not found"
  fi

  return 0
}

# ==============================================================================
# Tag Filtering & Query
# ==============================================================================

build_tag_display_message() {
  if [ "$TAG_COUNT" -eq 0 ]; then
    printf "all running EC2 instances"
    return
  fi

  if [ "$TAG_COUNT" -eq 1 ]; then
    get_tag_at_index 1
    printf "EC2 instances with %s=%s" "$TAG_KEY_AT_INDEX" "$TAG_VALUE_AT_INDEX"
    return
  fi

  printf "EC2 instances with %d tag filters" "$TAG_COUNT"
}

normalize_none_fields() {
  awk -F'\t' 'BEGIN { OFS = "\t" }
    { for (i = 1; i <= NF; i++) { if ($i == "None" || $i == "null") $i = "" }; print }'
}

query_instances() {
  set -- "Name=instance-state-name,Values=running"

  i=1
  while [ "$i" -le "$TAG_COUNT" ]; do
    get_tag_at_index "$i"
    set -- "$@" "Name=tag:$TAG_KEY_AT_INDEX,Values=$TAG_VALUE_AT_INDEX"
    i=$((i + 1))
  done

  message=$(build_tag_display_message)
  printf "Searching for %s...\n" "$message" >&2

  # shellcheck disable=SC2016
  result=$(AWSENV_TTY=never aws ec2 describe-instances \
    --filters "$@" \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],PublicIpAddress]' \
    --output text) || error_exit "Failed to query EC2 instances"

  printf "%s" "$result" | normalize_none_fields | sort -t"$(printf '\t')" -k2,2
}

# ==============================================================================
# Instance Selection
# ==============================================================================

parse_instance_list() {
  instance_list="$1"
  printf "%s\n" "$instance_list" | awk '{if (NF > 0) print $1}'
}

# --- BEGIN SHARED: count_lines ---
count_lines() {
  text="$1"
  if [ -z "$text" ]; then
    printf "0"
    return
  fi

  printf "%s\n" "$text" | grep -c .
}
# --- END SHARED: count_lines ---

count_instances() {
  instance_ids="$1"
  count_lines "$instance_ids"
}

display_instance_line() {
  index="$1"
  id="$2"
  name="$3"
  ip="$4"

  display_name="${name:-$id}"
  display_ip="${ip:-no-public-ip}"
  printf "%d. %s (%s): %s\n" "$index" "$display_name" "$id" "$display_ip" >&2
}

display_instances() {
  instance_list="$1"

  printf "\n" >&2
  i=1
  printf "%s\n" "$instance_list" | while IFS="$(printf '\t')" read -r id name ip; do
    if [ -n "$id" ]; then
      display_instance_line "$i" "$id" "$name" "$ip"
      i=$((i + 1))
    fi
  done

  printf "\n" >&2
}

# --- BEGIN SHARED: read_user_selection ---
read_user_selection() {
  max="$1"
  noun="$2"

  while true; do
    printf "Select %s (1-%d): " "$noun" "$max" >&2
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
# --- END SHARED: read_user_selection ---

select_instance() {
  instance_list="$1"
  instance_ids=$(parse_instance_list "$instance_list")
  count=$(count_instances "$instance_ids")

  [ "$count" -eq 0 ] && error_exit "No instances found"

  if [ "$count" -eq 1 ]; then
    printf "Connecting to instance...\n" >&2
    selection=1
  else
    display_instances "$instance_list"
    selection=$(read_user_selection "$count" "instance")
  fi

  SELECTED_LINE=$(printf "%s\n" "$instance_list" | sed -n "${selection}p")
  SELECTED_ID=$(printf "%s" "$SELECTED_LINE" | cut -f1)
  SELECTED_IP=$(printf "%s" "$SELECTED_LINE" | cut -f3)
}

# ==============================================================================
# Connection Operations
# ==============================================================================

connect_ssh() {
  printf "Connecting to %s via SSH...\n" "$SELECTED_ID" >&2
  [ -z "$SELECTED_IP" ] && error_exit "Instance does not have a public IP address for SSH connection"

  if [ -n "$SSH_KEY_FILE" ]; then
    printf "ssh -A -i %s %s@%s\n" "$SSH_KEY_FILE" "$SSH_USER" "$SELECTED_IP" >&2
    exec ssh -A -i "$SSH_KEY_FILE" "$SSH_USER@$SELECTED_IP"
  fi

  printf "ssh -A %s@%s\n" "$SSH_USER" "$SELECTED_IP" >&2
  exec ssh -A "$SSH_USER@$SELECTED_IP"
}

build_ssm_parameters() {
  jq -nc --arg cmd "$SSM_COMMAND" '{"command":[$cmd]}'
}

connect_ssm() {
  printf "Connecting to %s via SSM...\n" "$SELECTED_ID" >&2
  command_json=$(build_ssm_parameters)
  AWSENV_TTY=always exec aws ssm start-session \
    --target "$SELECTED_ID" \
    --document-name "AWS-StartInteractiveCommand" \
    --parameters "$command_json"
}

connect() {
  case "$CONNECT_METHOD" in
  ssh) connect_ssh ;;
  ssm) connect_ssm ;;
  *) error_exit "Connection method must be: ssh or ssm" ;;
  esac
}

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
  parse_options "$@"
  validate_parameters
  check_dependencies

  instance_data=$(query_instances)
  select_instance "$instance_data"
  connect
}

main "$@"
