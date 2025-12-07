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
TAG_KEY=""
TAG_VALUE=""
SELECTED_ID=""
SSM_COMMAND="sh"

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS]

Optional:
  -t TAG_KEY        Tag key to filter instances
  -v TAG_VALUE      Tag value to filter instances
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

Note: If -t is specified, -v must also be specified (and vice versa)

Examples:
  $0
  $0 -t Environment -v prod
  $0 -t Environment -v staging -p myprofile -c ssh -k ~/.ssh/mykey.pem
  $0 -t Team -v backend
  $0 -t Name -v bastion -s "cd; bash -l"
EOF
  exit 1
}

error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

parse_options() {
  while getopts "p:t:v:r:c:u:k:s:h" opt; do
    case "$opt" in
    p) AWS_PROFILE="$OPTARG" ;;
    t) TAG_KEY="$OPTARG" ;;
    v) TAG_VALUE="$OPTARG" ;;
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

validate_tag() {
  if [ -n "$TAG_KEY" ] || [ -n "$TAG_VALUE" ]; then
    if [ -z "$TAG_KEY" ] || [ -z "$TAG_VALUE" ]; then
      error_exit "Both tag key (-t) and tag value (-v) must be provided together"
    fi
  fi
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
  validate_tag
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

query_instances() {
  filters="Name=instance-state-name,Values=running"

  if [ -n "$TAG_KEY" ]; then
    echo "Searching for EC2 instances with $TAG_KEY=$TAG_VALUE..." >&2
    filters="Name=tag:$TAG_KEY,Values=$TAG_VALUE $filters"
  else
    echo "Searching for all running EC2 instances..." >&2
  fi

  $AWS_CMD ec2 describe-instances \
    --filters $filters \
    --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],PublicIpAddress]' \
    --output text 2>/dev/null | sort -t"$(printf '\t')" -k2,2 || echo ""
}

parse_instance_list() {
  instance_list="$1"
  echo "$instance_list" | awk '{if (NF > 0) print $1}'
}

count_instances() {
  instance_ids="$1"
  echo "$instance_ids" | grep -c . || echo "0"
}

display_instances() {
  instance_list="$1"

  echo "" >&2
  i=1
  echo "$instance_list" | while IFS="$(printf '\t')" read -r id name ip; do
    if [ -n "$id" ]; then
      display_name="${name:-$id}"
      display_ip="${ip:-no-public-ip}"
      echo "$i. $display_name ($id): $display_ip" >&2
      i=$((i + 1))
    fi
  done
  echo "" >&2
}

select_instance_number() {
  count="$1"

  while :; do
    printf "Select instance (1-$count): " >&2
    read -r selection </dev/tty || exit 1

    if [ "$selection" -ge 1 ] 2>/dev/null && [ "$selection" -le "$count" ] 2>/dev/null; then
      echo "$selection"
      return 0
    fi

    echo "ERROR: Invalid selection" >&2
  done
}

get_instance_by_index() {
  instance_ids="$1"
  index="$2"
  echo "$instance_ids" | sed -n "${index}p"
}

select_instance() {
  instance_list="$1"
  instance_ids=$(parse_instance_list "$instance_list")
  count=$(count_instances "$instance_ids")

  if [ "$count" -eq 0 ]; then
    error_exit "No instances found"
  elif [ "$count" -eq 1 ]; then
    echo "Connecting to instance..." >&2
    SELECTED_ID=$(echo "$instance_ids" | head -n 1)
    return 0
  fi

  display_instances "$instance_list"
  selection=$(select_instance_number "$count")
  SELECTED_ID=$(get_instance_by_index "$instance_ids" "$selection")
}

get_instance_ip() {
  instance_id="$1"

  $AWS_CMD ec2 describe-instances \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || echo ""
}

connect_ssh() {
  echo "Connecting to $SELECTED_ID via SSH..." >&2

  ip_address=$(get_instance_ip "$SELECTED_ID")
  if [ -z "$ip_address" ] || [ "$ip_address" = "None" ]; then
    error_exit "Instance does not have a public IP address for SSH connection"
  fi

  ssh_cmd="ssh -A"
  if [ -n "$SSH_KEY_FILE" ]; then
    ssh_cmd="$ssh_cmd -i $SSH_KEY_FILE"
  fi
  ssh_cmd="$ssh_cmd $SSH_USER@$ip_address"

  echo "$ssh_cmd" >&2
  exec $ssh_cmd
}

connect_ssm() {
  echo "Connecting to $SELECTED_ID via SSM..." >&2

  command_json=$(printf '{"command":["%s"]}' "$SSM_COMMAND" | jq -c .)

  $AWS_CMD ssm start-session \
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
  if [ -z "$instance_data" ]; then
    error_exit "No instances found"
  fi

  select_instance "$instance_data"
  connect
}

main "$@"
