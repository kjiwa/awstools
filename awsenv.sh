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

BASE_IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"
IMAGE_PREFIX="awsenv-cli"

# ==============================================================================
# Core Utilities & Error Handling
# ==============================================================================

usage() {
  cat >&2 <<EOF
Usage: $0 [OPTIONS] <command> [args...]

Optional:
  -p PACKAGE        Additional package to install (can be specified multiple times)
  -f FILE           File containing packages to install (one per line)
  -m MOUNT          Mount directory as <local_dir>:<docker_dir>[:(ro|rw)]
                    Default is read-write (rw) if not specified
                    Can be specified multiple times
  -h                Show this help message

Environment Variables:
  AWSENV_TTY        Control TTY allocation (always|never|auto, default: auto)

Examples:
  $0 aws s3 ls
  $0 -p vim ./my-script.sh
  $0 -f packages.txt ./rdsclient.sh -t Environment -v prod
  $0 -m \$(pwd)/logs:/logs:ro -m /data:/mnt/data:rw ./process.sh
  AWSENV_TTY=never $0 aws ec2 describe-instances
EOF
  exit 1
}

error_exit() {
  echo "ERROR: $1" >&2
  exit 1
}

is_valid_identifier() {
  case "$1" in
  *[!A-Za-z0-9_]* | [0-9]* | "") return 1 ;;
  *) return 0 ;;
  esac
}

# ==============================================================================
# Input Validation
# ==============================================================================

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

  local_dir="$1"
  docker_dir="$2"

  if [ "$count" -eq 3 ]; then
    mode="$3"
    case "$mode" in
    ro | rw) ;;
    *) error_exit "Invalid mount mode '$mode'. Expected 'ro' or 'rw'" ;;
    esac
  fi

  [ ! -d "$local_dir" ] && error_exit "Mount directory '$local_dir' does not exist"
  [ ! -r "$local_dir" ] && error_exit "Mount directory '$local_dir' is not readable"
  validate_docker_path "$docker_dir"

  return 0
}

validate_mounts() {
  OLD_IFS="$IFS"

  # shellcheck disable=SC2086
  IFS=" " set -- $MOUNTS
  IFS="$OLD_IFS"

  for mount in "$@"; do
    validate_mount_format "$mount"
  done
}

validate_parameters() {
  validate_command_name "$CMD"
  validate_mounts
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
    m) MOUNTS="$MOUNTS $OPTARG" ;;
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
  create_dockerfile "$sorted_packages" | docker build -t "$IMAGE" -
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

create_command_mount() {
  if [ -z "$CMD_PATH" ] || [ ! -e "$CMD_PATH" ]; then
    return 0
  fi

  cmd_dir="$(dirname "$CMD_PATH")"
  printf "%s %s:%s:ro" "-v" "$cmd_dir" "$cmd_dir"
}

resolve_command_location() {
  CMD_PATH=""
  CMD_MOUNT=""

  if is_aws_cli_builtin "$CMD"; then
    CMD_PATH="$CMD"
    return 0
  fi

  found_path=$(find_command_path) || error_exit "Command '$CMD' does not exist or is not an executable file"
  resolved_path=$(resolve_symlink "$found_path") || error_exit "Failed to resolve symlink for '$found_path'"
  CMD_PATH="$resolved_path"
  CMD_MOUNT=$(create_command_mount)
}

# ==============================================================================
# Docker Environment Configuration
# ==============================================================================

add_aws_credentials_mount() {
  [ -d "$HOME/.aws" ] && printf " -v %s:/root/.aws:ro" "$HOME/.aws"
  return 0
}

add_aws_environment_variables() {
  aws_vars="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
    AWS_DEFAULT_REGION AWS_REGION AWS_PROFILE AWS_CONFIG_FILE \
    AWS_SHARED_CREDENTIALS_FILE"
  for var in $aws_vars; do
    is_valid_identifier "$var" || continue
    value=$(printenv "$var" 2>/dev/null || true)
    [ -n "$value" ] && printf " -e %s" "$var"
  done

  return 0
}

should_allocate_tty() {
  case "${AWSENV_TTY:-auto}" in
  always) return 0 ;;
  never) return 1 ;;
  *) [ -t 0 ] ;; # Check if standard input is a terminal
  esac

  return 0
}

add_terminal_type() {
  [ -n "${TERM:-}" ] && printf " -e TERM"
  return 0
}

add_terminal_dimensions() {
  [ -n "${COLUMNS:-}" ] && printf " -e COLUMNS"
  [ -n "${LINES:-}" ] && printf " -e LINES"
  return 0
}

add_terminal_display() {
  [ -n "${COLORTERM:-}" ] && printf " -e COLORTERM"
  return 0
}

add_pager_variable() {
  [ -n "${PAGER:-}" ] && printf " -e PAGER"
  [ -n "${AWS_PAGER:-}" ] && printf " -e AWS_PAGER"
  return 0
}

add_locale_variables() {
  [ -n "${LANG:-}" ] && printf " -e LANG"

  for var in $(printenv | grep '^LC_' | cut -d= -f1); do
    is_valid_identifier "$var" || continue
    printf " -e %s" "$var"
  done

  return 0
}

add_terminal_environment() {
  add_terminal_type
  add_terminal_dimensions
  add_terminal_display
  add_pager_variable
  add_locale_variables
}

add_user_mounts() {
  for mount in $MOUNTS; do
    printf " -v %s" "$mount"
  done
}

add_command_mount() {
  if [ -n "$CMD_MOUNT" ]; then
    printf " %s" "$CMD_MOUNT"
  fi
}

add_working_directory() {
  printf " -w %s" "$(pwd)"
}

determine_docker_tty_flags() {
  if should_allocate_tty; then
    printf "%s" "-it"
  else
    printf "%s" "-i"
  fi
}

build_docker_arguments() {
  tty_flags=$(determine_docker_tty_flags)
  DOCKER_ARGS="$tty_flags --rm --entrypoint="
  DOCKER_ARGS="$DOCKER_ARGS$(add_aws_credentials_mount)"
  DOCKER_ARGS="$DOCKER_ARGS$(add_aws_environment_variables)"
  DOCKER_ARGS="$DOCKER_ARGS$(add_terminal_environment)"
  DOCKER_ARGS="$DOCKER_ARGS$(add_user_mounts)"
  DOCKER_ARGS="$DOCKER_ARGS$(add_command_mount)"
  DOCKER_ARGS="$DOCKER_ARGS$(add_working_directory)"
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

main() {
  parse_arguments "$@"
  validate_parameters
  check_dependencies
  determine_image
  resolve_command_location
  build_docker_arguments

  shift $((CMD_ARGS_START - 1))
  # shellcheck disable=SC2086
  exec docker run $DOCKER_ARGS "$IMAGE" "$CMD_PATH" "$@"
}

main "$@"
