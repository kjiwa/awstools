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

BASE_IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"
IMAGE_PREFIX="awsenv-cli"
MOUNT_SEPARATOR="$(printf '\036')"

# ==============================================================================
# User Interface
# ==============================================================================

usage() {
  exit_code="${1:-1}"

  cat >&2 <<EOF
Usage: $0 [OPTIONS] <command> [args...]

Optional:
  -p PACKAGE        Additional package to install (can be specified multiple times)
  -f FILE           File containing packages to install (one per line)
  -m MOUNT          Mount path as <local_path>:<docker_dir>[:(ro|rw)]
                    <local_path> may be a directory or a file
                    Default is read-write (rw) if not specified
                    Can be specified multiple times
  -h                Show this help message

Environment Variables:
  AWSENV_TTY            Control TTY allocation (always|never|auto, default: auto)
  AWSENV_AWS_DIR_MODE   Control AWS directory mount (ro|rw|auto, default: auto)
                        'auto' uses read-write for configure/sso commands
  AWSENV_PWD_MODE       Control current directory mount (rw|ro|off, default: rw)

Examples:
  $0 aws s3 ls
  $0 -p vim ./my-script.sh
  $0 -f packages.txt ./rdsclient.sh -t Environment -v prod
  $0 -m \$(pwd)/logs:/logs:ro -m /data:/mnt/data:rw ./process.sh
  AWSENV_TTY=never $0 aws ec2 describe-instances
  $0 aws configure sso
  $0 aws configure sso --use-device-code
  AWSENV_AWS_DIR_MODE=rw $0 aws s3 ls
  AWSENV_PWD_MODE=off $0 aws --version
EOF
  exit "$exit_code"
}

error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

# ==============================================================================
# String & Validation Utilities
# ==============================================================================

is_valid_identifier() {
  case "$1" in
  *[!A-Za-z0-9_]* | [0-9]* | "") return 1 ;;
  *) return 0 ;;
  esac
}

validate_command_name() {
  case "$1" in
  *[\'\"\`\$\&\|\;\<\>\(\)\{\}\[\]]*) error_exit "Command name contains invalid characters" ;;
  "") error_exit "Command name cannot be empty" ;;
  esac
}

validate_docker_path() {
  path="$1"
  case "$path" in
  *..*) error_exit "Docker path '$path' cannot contain '..'" ;;
  esac
}

validate_mount_format() {
  mount="$1"

  OLD_IFS="$IFS"
  IFS=":"

  # shellcheck disable=SC2086
  set -- $mount
  IFS="$OLD_IFS"

  count=$#
  [ "$count" -lt 2 ] && error_exit "Invalid mount format '$mount'"
  [ "$count" -gt 3 ] && error_exit "Invalid mount format '$mount'"

  local_path="$1"
  docker_dir="$2"

  if [ "$count" -eq 3 ]; then
    mode="$3"
    case "$mode" in
    ro | rw) ;;
    *) error_exit "Invalid mount mode '$mode'. Expected 'ro' or 'rw'" ;;
    esac
  fi

  [ ! -e "$local_path" ] && error_exit "Mount path '$local_path' does not exist"
  [ ! -r "$local_path" ] && error_exit "Mount path '$local_path' is not readable"
  validate_docker_path "$docker_dir"

  return 0
}

validate_mounts() {
  [ -z "$MOUNTS" ] && return 0

  OLD_IFS="$IFS"
  IFS="$MOUNT_SEPARATOR"

  # shellcheck disable=SC2086
  set -- $MOUNTS
  IFS="$OLD_IFS"

  for mount in "$@"; do
    [ -n "$mount" ] && validate_mount_format "$mount"
  done
}

validate_aws_dir_mode() {
  mode="${AWSENV_AWS_DIR_MODE:-auto}"
  case "$mode" in
  auto | ro | rw) ;;
  *) error_exit "Invalid AWSENV_AWS_DIR_MODE '$mode'. Expected 'auto', 'ro', or 'rw'" ;;
  esac
}

validate_pwd_mode() {
  mode="${AWSENV_PWD_MODE:-rw}"
  case "$mode" in
  rw | ro | off) ;;
  *) error_exit "Invalid AWSENV_PWD_MODE '$mode'. Expected 'rw', 'ro', or 'off'" ;;
  esac
}

validate_tty_mode() {
  mode="${AWSENV_TTY:-auto}"
  case "$mode" in
  always | never | auto) ;;
  *) error_exit "Invalid AWSENV_TTY '$mode'. Expected 'always', 'never', or 'auto'" ;;
  esac
}

validate_parameters() {
  validate_command_name "$CMD"
  validate_mounts
  validate_aws_dir_mode
  validate_pwd_mode
  validate_tty_mode
}

# ==============================================================================
# Argument Parsing
# ==============================================================================

parse_arguments() {
  PACKAGES=""
  PACKAGE_FILE=""
  MOUNTS=""

  while getopts "p:f:m:h" opt; do
    case "$opt" in
    p) PACKAGES="$PACKAGES $OPTARG" ;;
    f) PACKAGE_FILE="$OPTARG" ;;
    m)
      if [ -z "$MOUNTS" ]; then
        MOUNTS="$OPTARG"
      else
        MOUNTS="$MOUNTS${MOUNT_SEPARATOR}$OPTARG"
      fi
      ;;
    h) usage 0 ;;
    *) usage ;;
    esac
  done

  shift $((OPTIND - 1))
  if [ $# -eq 0 ]; then
    error_exit "No command specified"
  fi

  CMD="$1"
  shift

  CMD_ARGS_START=$((OPTIND + 1))
}

# ==============================================================================
# Package Management
# ==============================================================================

read_packages_from_file() {
  file="$1"
  [ ! -f "$file" ] && error_exit "Package file '$file' does not exist"
  [ ! -r "$file" ] && error_exit "Package file '$file' is not readable"

  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$line" in
    '' | '#'*) continue ;;
    *) printf "%s " "$line" ;;
    esac
  done <"$file"
}

merge_and_sort_packages() {
  all_packages="$1"
  [ -z "$all_packages" ] && return
  printf "%s" "$all_packages" | tr ' ' '\n' | grep -v '^[[:space:]]*$' | sort -u | tr '\n' ' '
}

hash_packages() {
  packages="$1"
  if command -v cksum >/dev/null 2>&1; then
    printf "%s" "$packages" | cksum | awk '{print $1}'
  elif command -v sum >/dev/null 2>&1; then
    printf "%s" "$packages" | sum | awk '{print $1}'
  else
    printf "%s" "$packages" | wc -c
  fi
}

# ==============================================================================
# Docker Image Operations
# ==============================================================================

compute_image_tag() {
  packages="$1"
  if [ -z "$packages" ]; then
    printf "base"
    return
  fi

  hash_packages "$packages"
}

generate_image_name() {
  printf "%s:%s" "$IMAGE_PREFIX" "$(compute_image_tag "$1")"
}

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

create_dockerfile() {
  sorted_packages="$1"
  install_cmd="yum install -y unzip"
  [ -n "$sorted_packages" ] && install_cmd="$install_cmd $sorted_packages"

  cat <<EOF
FROM $BASE_IMAGE
RUN $install_cmd && \\
    curl -sSL -o /tmp/session-manager-plugin.rpm \\
    https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm && \\
    yum install -y /tmp/session-manager-plugin.rpm && \\
    rm -f /tmp/session-manager-plugin.rpm && \\
    yum clean all
EOF
}

build_custom_image() {
  sorted_packages="$1"

  image_exists "$IMAGE" && return 0

  echo "Building custom image: $IMAGE" >&2
  [ -n "$sorted_packages" ] && echo "Installing packages: $sorted_packages" >&2
  create_dockerfile "$sorted_packages" | docker build -t "$IMAGE" - >&2
}

determine_image() {
  file_packages=""
  [ -n "$PACKAGE_FILE" ] && file_packages=$(read_packages_from_file "$PACKAGE_FILE")
  all_packages="$PACKAGES $file_packages"
  sorted_packages=$(merge_and_sort_packages "$all_packages")
  sorted_packages=$(printf "%s" "$sorted_packages" | sed 's/[[:space:]]*$//')
  IMAGE=$(generate_image_name "$sorted_packages")
  build_custom_image "$sorted_packages"
}

# ==============================================================================
# Command & Path Resolution
# ==============================================================================

is_aws_cli_builtin() {
  test "$1" = "aws" || test "$1" = "aws_completer" || test "$1" = "session-manager-plugin"
}

try_readlink_f() {
  target="$1"
  command -v readlink >/dev/null 2>&1 || return 1
  readlink -f "$target" 2>/dev/null
}

resolve_link_target() {
  current="$1"
  link_target="$2"

  case "$link_target" in
  /*) printf "%s" "$link_target" ;;
  *) printf "%s/%s" "$(dirname "$current")" "$link_target" ;;
  esac
}

canonicalize_path() {
  path="$1"
  [ ! -e "$path" ] && return 1

  cd -P "$(dirname "$path")" >/dev/null 2>&1 || return 1
  printf "%s/%s" "$(pwd -P)" "$(basename "$path")"
  cd - >/dev/null 2>&1 || true
}

resolve_symlink_manually() {
  current="$1"
  max_depth=40

  while [ $max_depth -gt 0 ]; do
    if [ ! -L "$current" ]; then
      canonicalize_path "$current"
      return $?
    fi

    link_target=$(readlink "$current")
    current=$(resolve_link_target "$current" "$link_target")
    max_depth=$((max_depth - 1))
  done

  return 1
}

resolve_symlink() {
  target="$1"
  if resolved=$(try_readlink_f "$target"); then
    printf "%s" "$resolved"
    return 0
  fi

  resolve_symlink_manually "$target"
}

find_command_path() {
  [ -d "$CMD" ] && return 1

  if [ -f "./$CMD" ] && [ -x "./$CMD" ]; then
    printf "%s" "$(pwd)/$CMD"
    return 0
  fi

  cmd_location=$(command -v "$CMD" 2>/dev/null || true)
  if [ -n "$cmd_location" ]; then
    printf "%s" "$cmd_location"
    return 0
  fi

  return 1
}

resolve_command_location() {
  CMD_PATH=""
  CMD_MOUNT_DIR=""

  if is_aws_cli_builtin "$CMD"; then
    CMD_PATH="$CMD"
    return 0
  fi

  found_path=$(find_command_path) || error_exit "Command '$CMD' does not exist or is not an executable file"
  resolved_path=$(resolve_symlink "$found_path") || error_exit "Failed to resolve symlink for '$found_path'"
  CMD_PATH="$resolved_path"
  [ -e "$CMD_PATH" ] && CMD_MOUNT_DIR="$(dirname "$CMD_PATH")"
}

# ==============================================================================
# AWS Command Detection
# ==============================================================================

GLOBAL_OPTS_WITH_VALUE=" --profile --region --output --endpoint-url --ca-bundle --cli-read-timeout --cli-connect-timeout --color --query --cli-binary-format "

get_positional_args() {
  shift $((CMD_ARGS_START - 1))

  FIRST_POS=""
  SECOND_POS=""
  skip_next=0

  for arg in "$@"; do
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi

    case "$arg" in
    --*=*) continue ;;
    --*)
      case "$GLOBAL_OPTS_WITH_VALUE" in
      *" $arg "*) skip_next=1 ;;
      esac
      continue
      ;;
    -*) continue ;;
    *)
      if [ -z "$FIRST_POS" ]; then
        FIRST_POS="$arg"
      elif [ -z "$SECOND_POS" ]; then
        SECOND_POS="$arg"
        break
      fi
      ;;
    esac
  done
}

has_device_code_flag() {
  shift $((CMD_ARGS_START - 1))
  for arg in "$@"; do
    case "$arg" in
    --use-device-code) return 0 ;;
    esac
  done
  return 1
}

profile_needs_write_access() {
  [ "$CMD" != "aws" ] && return 1
  [ ! -d "$HOME/.aws" ] && return 1

  profile=""

  shift $((CMD_ARGS_START - 1))
  while [ $# -gt 0 ]; do
    case "$1" in
    --profile)
      shift
      profile="${1:-}"
      break
      ;;
    --profile=*)
      profile="${1#--profile=}"
      break
      ;;
    esac
    shift
  done

  [ -z "$profile" ] && profile="${AWS_PROFILE:-default}"

  config_file="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
  [ ! -f "$config_file" ] && return 1

  if grep -q "^\[profile $profile\]" "$config_file" 2>/dev/null; then
    sed -n "/^\[profile $profile\]/,/^\[/p" "$config_file" | grep -Eq "^(sso_|role_arn)" && return 0
  elif grep -q "^\[$profile\]" "$config_file" 2>/dev/null; then
    sed -n "/^\[$profile\]/,/^\[/p" "$config_file" | grep -Eq "^(sso_|role_arn)" && return 0
  fi

  return 1
}

needs_aws_dir_writable() {
  [ "$CMD" != "aws" ] && return 1

  get_positional_args "$@"

  case "$FIRST_POS" in
  configure)
    case "$SECOND_POS" in
    "" | set | sso | sso-session | import) return 0 ;;
    esac
    ;;
  sso)
    case "$SECOND_POS" in
    login | logout) return 0 ;;
    esac
    ;;
  esac

  profile_needs_write_access "$@" && return 0

  return 1
}

needs_host_network() {
  [ "$CMD" != "aws" ] && return 1

  has_device_code_flag "$@" && return 1

  get_positional_args "$@"

  case "$FIRST_POS" in
  configure)
    test "$SECOND_POS" = "sso" && return 0
    ;;
  sso)
    test "$SECOND_POS" = "login" && return 0
    ;;
  esac

  return 1
}

# ==============================================================================
# Docker Environment Configuration
# ==============================================================================

should_allocate_tty() {
  case "${AWSENV_TTY:-auto}" in
  always) return 0 ;;
  never) return 1 ;;
  *) [ -t 0 ] ;;
  esac
}

determine_docker_tty_flags() {
  if should_allocate_tty; then
    printf "%s" "-it"
  else
    printf "%s" "-i"
  fi
}

determine_aws_dir_mode() {
  mode="${AWSENV_AWS_DIR_MODE:-auto}"

  case "$mode" in
  ro | rw)
    printf "%s" "$mode"
    return 0
    ;;
  esac

  if needs_aws_dir_writable "$@"; then
    printf "rw"
  else
    printf "ro"
  fi
}

determine_pwd_mode() {
  printf "%s" "${AWSENV_PWD_MODE:-rw}"
}

aws_credentials_mount_value() {
  mount_mode="$1"
  [ -d "$HOME/.aws" ] && printf "%s:/root/.aws:%s" "$HOME/.aws" "$mount_mode"
  return 0
}

count_mounts() {
  if [ -z "$MOUNTS" ]; then
    printf "0"
    return
  fi

  printf "%s" "$MOUNTS" | tr "$MOUNT_SEPARATOR" '\n' | grep -c .
}

get_mount_at_index() {
  idx="$1"
  printf "%s" "$MOUNTS" | tr "$MOUNT_SEPARATOR" '\n' | sed -n "${idx}p"
}

cmd_mount_shadowed_by_pwd() {
  pwd_mode="$1"

  [ -z "$CMD_MOUNT_DIR" ] && return 1
  [ "$pwd_mode" = "off" ] && return 1

  # Mounting the command's directory again at the same target docker rejects
  # as a duplicate mount point regardless of mode.
  [ "$CMD_MOUNT_DIR" = "$(pwd)" ] && return 0

  # A read-write cwd mount always wins over a nested read-only command mount;
  # skip the latter so it doesn't collide with (or shadow) the former.
  if [ "$pwd_mode" = "rw" ]; then
    case "$CMD_MOUNT_DIR" in
    "$(pwd)"/*) return 0 ;;
    esac
  fi

  return 1
}

# ==============================================================================
# Dependency Checking
# ==============================================================================

check_dependencies() {
  command -v docker >/dev/null 2>&1 || error_exit "docker is required but not found"
}

# ==============================================================================
# Main Entry Point
# ==============================================================================

run_container() {
  aws_dir_mode=$(determine_aws_dir_mode "$@")
  pwd_mode=$(determine_pwd_mode)
  tty_flags=$(determine_docker_tty_flags)

  host_network=0
  needs_host_network "$@" && host_network=1

  skip_cmd_mount=0
  cmd_mount_shadowed_by_pwd "$pwd_mode" && skip_cmd_mount=1

  shift $((CMD_ARGS_START - 1))
  # "$@" is now the trailing arguments to pass to CMD_PATH inside the
  # container. Every docker flag below is prepended in front of "$@" via
  # `set --`; docker does not care about the relative order of its own
  # flags, only that they precede IMAGE, which precedes CMD_PATH, which
  # precedes the command's own arguments.

  set -- "$IMAGE" "$CMD_PATH" "$@"
  set -- -w "$(pwd)" "$@"

  if [ "$pwd_mode" != "off" ]; then
    set -- -v "$(pwd):$(pwd):$pwd_mode" "$@"
  fi

  if [ "$skip_cmd_mount" -eq 0 ] && [ -n "$CMD_MOUNT_DIR" ]; then
    set -- -v "$CMD_MOUNT_DIR:$CMD_MOUNT_DIR:ro" "$@"
  fi

  mount_count=$(count_mounts)
  i=1
  while [ "$i" -le "$mount_count" ]; do
    mount=$(get_mount_at_index "$i")
    [ -n "$mount" ] && set -- -v "$mount" "$@"
    i=$((i + 1))
  done

  aws_mount=$(aws_credentials_mount_value "$aws_dir_mode")
  [ -n "$aws_mount" ] && set -- -v "$aws_mount" "$@"

  [ "$host_network" -eq 1 ] && set -- --network host "$@"

  for var in $(printenv | grep '^AWS_' | cut -d= -f1); do
    is_valid_identifier "$var" || continue
    value=$(printenv "$var" 2>/dev/null || true)
    [ -n "$value" ] && set -- -e "$var" "$@"
  done

  [ -n "${TERM:-}" ] && set -- -e TERM "$@"
  [ -n "${COLUMNS:-}" ] && set -- -e COLUMNS "$@"
  [ -n "${LINES:-}" ] && set -- -e LINES "$@"
  [ -n "${COLORTERM:-}" ] && set -- -e COLORTERM "$@"
  [ -n "${PAGER:-}" ] && set -- -e PAGER "$@"
  [ -n "${LANG:-}" ] && set -- -e LANG "$@"

  for var in $(printenv | grep '^LC_' | cut -d= -f1); do
    is_valid_identifier "$var" || continue
    set -- -e "$var" "$@"
  done

  set -- "$tty_flags" --rm --entrypoint= "$@"

  exec docker run "$@"
}

main() {
  parse_arguments "$@"
  validate_parameters
  check_dependencies
  determine_image
  resolve_command_location
  run_container "$@"
}

main "$@"
