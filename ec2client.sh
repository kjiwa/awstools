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

AWS_PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
CONNECT_METHOD="ssm"
SSH_USER="ec2-user"
SSH_KEY_FILE=""
TAG_KEYS=""
TAG_VALUES=""
TAG_COUNT=0
SELECTED_ID=""
SSM_COMMAND="sh"

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Optional:
  -t TAG=VALUE      Tag filter (can be specified multiple times for AND logic)
  -p PROFILE        AWS profile
  -r REGION         AWS region (default: us-east-2)
  -c METHOD         Connection method (ssh or ssm, default: ssm)
  -u USER           SSH user (default: ec2-user)
  -k KEYFILE        SSH private key file path
  -s COMMAND        SSM command to execute (default: sh)

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
  $0 -t Environment=prod -t Team=backend
  $0 -t Name=bastion -c ssh -k ~/.ssh/mykey.pem
  $0 -t Environment=staging -s "cd; bash -l"
EOF
  exit 1
}

error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}

trim_whitespace() {
  printf "%s" "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

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

  if [ -z "$key" ]; then
    error_exit "Invalid tag format '$original': must contain '=' character"
  fi

  trimmed_key=$(trim_whitespace "$key")
  if [ -z "$trimmed_key" ]; then
    error_exit "Invalid tag format '$original': key cannot be empty"
  fi

  trimmed_value=$(trim_whitespace "$value")
  if [ -z "$trimmed_value" ]; then
    error_exit "Invalid tag format '$original': value cannot be empty"
  fi

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
    TAG_KEYS="$TAG_KEYS
$key"
    TAG_VALUES="$TAG_VALUES
$value"
  fi

  TAG_COUNT=$((TAG_COUNT + 1))
}

get_tag_at_index() {
  idx="$1"
  TAG_KEY_AT_INDEX=$(printf "%s" "$TAG_KEYS" | sed -n "${idx}p")
  TAG_VALUE_AT_INDEX=$(printf "%s" "$TAG_VALUES" | sed -n "${idx}p")
}

parse_options() {
  while getopts "p:t:r:c:u:k:s:h" opt; do
    case "$opt" in
    p) AWS_PROFILE="$OPTARG" ;;
    t)
      parse_tag_argument "$OPTARG"
      validate_tag_format "$OPTARG" "$PARSED_KEY" "$PARSED_VALUE"
      accumulate_tags "$PARSED_KEY" "$PARSED_VALUE"
      ;;
    r) REGION="$OPTARG" ;;
    c) CONNECT_METHOD="$OPTARG" ;;
    u) SSH_USER="$OPTARG" ;;
    k) SSH_KEY_FILE="$OPTARG" ;;
    s) SSM_COMMAND="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
    esac
  done
  shift $((OPTIND - 1))
}

validate_connect_method() {
  case "$CONNECT_METHOD" in
  ssh | ssm) ;;
  *) error_exit "Connection method must be: ssh or ssm" ;;
  esac
}

validate_ssh_key_file() {
  if [ -n "$SSH_KEY_FILE" ] && [ ! -f "$SSH_KEY_FILE" ]; then
    error_exit "SSH private key file not found: $SSH_KEY_FILE"
  fi
}

validate_parameters() {
  validate_connect_method
  validate_ssh_key_file
}

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
}

build_aws_command() {
  if [ -n "$AWS_PROFILE" ]; then
    AWS_CMD="aws --profile $AWS_PROFILE --region $REGION"
  else
    AWS_CMD="aws --region $REGION"
  fi
}

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

build_tag_filter() {
  idx="$1"
  get_tag_at_index "$idx"
  printf "Name=tag:%s,Values=%s" "$TAG_KEY_AT_INDEX" "$TAG_VALUE_AT_INDEX"
}

build_ec2_tag_filters() {
  if [ "$TAG_COUNT" -eq 0 ]; then
    printf ""
    return
  fi

  filters=""
  i=1
  while [ "$i" -le "$TAG_COUNT" ]; do
    if [ -n "$filters" ]; then
      filters="$filters "
    fi
    filters="$filters$(build_tag_filter "$i")"
    i=$((i + 1))
  done

  printf "%s" "$filters"
}

query_instances() {
  base_filter="Name=instance-state-name,Values=running"
  tag_filters=$(build_ec2_tag_filters)

  if [ -n "$tag_filters" ]; then
    filters="$tag_filters $base_filter"
  else
    filters="$base_filter"
  fi

  message=$(build_tag_display_message)
  printf "Searching for %s...\n" "$message" >&2

  # shellcheck disable=SC2086,SC2016
  AWSENV_TTY=never $AWS_CMD ec2 describe-instances \
    --filters $filters \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],PublicIpAddress]' \
    --output text 2>/dev/null | sort -t"$(printf '\t')" -k2,2 || printf ""
}

parse_instance_list() {
  instance_list="$1"
  printf "%s\n" "$instance_list" | awk '{if (NF > 0) print $1}'
}

count_lines() {
  text="$1"
  if [ -z "$text" ]; then
    printf "0"
    return
  fi

  printf "%s\n" "$text" | grep -c .
}

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

read_user_selection() {
  max="$1"

  while true; do
    printf "Select instance (1-%d): " "$max" >&2
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

get_instance_by_index() {
  instance_ids="$1"
  index="$2"
  printf "%s" "$instance_ids" | sed -n "${index}p"
}

select_instance() {
  instance_list="$1"
  instance_ids=$(parse_instance_list "$instance_list")
  count=$(count_instances "$instance_ids")

  if [ "$count" -eq 0 ]; then
    error_exit "No instances found"
  fi

  if [ "$count" -eq 1 ]; then
    printf "Connecting to instance...\n" >&2
    SELECTED_ID=$(printf "%s" "$instance_ids" | head -n 1)
    return 0
  fi

  display_instances "$instance_list"
  selection=$(read_user_selection "$count")
  SELECTED_ID=$(get_instance_by_index "$instance_ids" "$selection")
}

get_instance_ip() {
  instance_id="$1"
  AWSENV_TTY=never $AWS_CMD ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || printf ""
}

build_ssh_command() {
  ssh_cmd="ssh -A"
  if [ -n "$SSH_KEY_FILE" ]; then
    ssh_cmd="$ssh_cmd -i $SSH_KEY_FILE"
  fi

  ssh_cmd="$ssh_cmd $SSH_USER@$1"
  printf "%s" "$ssh_cmd"
}

connect_ssh() {
  printf "Connecting to %s via SSH...\n" "$SELECTED_ID" >&2

  ip_address=$(get_instance_ip "$SELECTED_ID")
  if [ -z "$ip_address" ] || [ "$ip_address" = "None" ]; then
    error_exit "Instance does not have a public IP address for SSH connection"
  fi

  ssh_cmd=$(build_ssh_command "$ip_address")
  printf "%s\n" "$ssh_cmd" >&2
  exec $ssh_cmd
}

build_ssm_parameters() {
  printf '{"command":["%s"]}' "$SSM_COMMAND" | jq -c .
}

connect_ssm() {
  printf "Connecting to %s via SSM...\n" "$SELECTED_ID" >&2
  command_json=$(build_ssm_parameters)
  AWSENV_TTY=always exec $AWS_CMD ssm start-session \
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

main() {
  parse_options "$@"
  validate_parameters
  check_dependencies
  build_aws_command

  instance_data=$(query_instances)
  select_instance "$instance_data"
  connect
}

main "$@"
