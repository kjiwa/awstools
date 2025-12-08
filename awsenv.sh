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

validate_mount_format() {
  case "$1" in
  *:*) return 0 ;;
  *)
    error_exit "Invalid mount format '$1'. Expected <local_dir>:<docker_dir>[:(ro|rw)]"
    ;;
  esac
}

read_packages_from_file() {
  file="$1"

  if [ ! -f "$file" ]; then
    error_exit "Package file '$file' does not exist"
  fi

  if [ ! -r "$file" ]; then
    error_exit "Package file '$file' is not readable"
  fi

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

  if [ -z "$all_packages" ]; then
    return
  fi

  printf "%s" "$all_packages" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '
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

compute_image_tag() {
  packages="$1"

  if [ -z "$packages" ]; then
    printf "base"
    return
  fi

  hash_packages "$packages"
}

generate_image_name() {
  tag=$(compute_image_tag "$1")
  printf "%s:%s" "$IMAGE_PREFIX" "$tag"
}

parse_arguments() {
  PACKAGES=""
  PACKAGE_FILE=""
  MOUNTS=""

  while getopts "p:f:m:h" opt; do
    case "$opt" in
    p)
      PACKAGES="$PACKAGES $OPTARG"
      ;;
    f)
      PACKAGE_FILE="$OPTARG"
      ;;
    m)
      validate_mount_format "$OPTARG"
      MOUNTS="$MOUNTS $OPTARG"
      ;;
    h)
      usage
      ;;
    *)
      usage
      ;;
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

verify_docker_installed() {
  if ! command -v docker >/dev/null 2>&1; then
    error_exit "docker is not installed or not in PATH"
  fi
}

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

create_dockerfile() {
  sorted_packages="$1"

  install_cmd="yum install -y unzip"

  if [ -n "$sorted_packages" ]; then
    install_cmd="$install_cmd $sorted_packages"
  fi

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
  image_name="$1"
  sorted_packages="$2"

  if image_exists "$image_name"; then
    return 0
  fi

  echo "Building custom image: $image_name" >&2

  if [ -n "$sorted_packages" ]; then
    echo "Installing packages: $sorted_packages" >&2
  fi

  create_dockerfile "$sorted_packages" | docker build -t "$image_name" -
}

determine_image() {
  file_packages=""
  if [ -n "$PACKAGE_FILE" ]; then
    file_packages=$(read_packages_from_file "$PACKAGE_FILE")
  fi

  all_packages="$PACKAGES $file_packages"
  SORTED_PACKAGES=$(merge_and_sort_packages "$all_packages")
  SORTED_PACKAGES=$(printf "%s" "$SORTED_PACKAGES" | sed 's/[[:space:]]*$//')

  IMAGE=$(generate_image_name "$SORTED_PACKAGES")

  build_custom_image "$IMAGE" "$SORTED_PACKAGES"
}

is_aws_cli_builtin() {
  test "$1" = "aws" || test "$1" = "aws_completer" || test "$1" = "session-manager-plugin"
}

try_readlink_f() {
  target="$1"

  if command -v readlink >/dev/null 2>&1; then
    if readlink -f "$target" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

resolve_link_target() {
  current="$1"
  link_target="$2"

  case "$link_target" in
    /*)
      printf "%s" "$link_target"
      ;;
    *)
      printf "%s/%s" "$(dirname "$current")" "$link_target"
      ;;
  esac
}

canonicalize_path() {
  path="$1"

  if [ ! -e "$path" ]; then
    return 1
  fi

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

  resolved=$(try_readlink_f "$target")
  if [ $? -eq 0 ]; then
    printf "%s" "$resolved"
    return 0
  fi

  resolve_symlink_manually "$target"
}

find_command_path() {
  command_name="$1"

  if [ -x "./$command_name" ]; then
    printf "%s" "$(pwd)/$command_name"
    return 0
  fi

  if [ -x "$command_name" ]; then
    printf "%s" "$command_name"
    return 0
  fi

  cmd_location=$(command -v "$command_name" 2>/dev/null || true)
  if [ -n "$cmd_location" ]; then
    printf "%s" "$cmd_location"
    return 0
  fi

  printf "%s" "$command_name"
  return 1
}

create_command_mount() {
  command_path="$1"

  if [ -z "$command_path" ] || [ ! -e "$command_path" ]; then
    return 0
  fi

  cmd_dir="$(dirname "$command_path")"
  printf "%s %s:%s:ro" "-v" "$cmd_dir" "$cmd_dir"
}

resolve_command_location() {
  CMD_PATH=""
  CMD_MOUNT=""

  if is_aws_cli_builtin "$CMD"; then
    CMD_PATH="$CMD"
    return 0
  fi

  found_path=$(find_command_path "$CMD")
  found_exists=$?

  if [ $found_exists -eq 0 ] && [ -e "$found_path" ]; then
    resolved_path=$(resolve_symlink "$found_path")
    if [ -z "$resolved_path" ]; then
      error_exit "Failed to resolve symlink for '$found_path'"
    fi
    CMD_PATH="$resolved_path"
    CMD_MOUNT=$(create_command_mount "$resolved_path")
  else
    CMD_PATH="$CMD"
  fi
}

add_aws_credentials_mount() {
  if [ -d "$HOME/.aws" ]; then
    printf " -v %s:/root/.aws:ro" "$HOME/.aws"
  fi
}

add_aws_environment_variables() {
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
    AWS_DEFAULT_REGION AWS_REGION AWS_PROFILE \
    AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE; do
    eval "val=\${$var:-}"
    if [ -n "$val" ]; then
      printf " -e %s" "$var"
    fi
  done
}

is_stdin_tty() {
  [ -t 0 ]
}

should_allocate_tty() {
  case "${AWSENV_TTY:-auto}" in
  always) return 0 ;;
  never) return 1 ;;
  auto) is_stdin_tty ;;
  *) is_stdin_tty ;;
  esac
}

add_terminal_type() {
  if [ -n "${TERM:-}" ]; then
    printf " -e TERM"
  fi
}

add_terminal_dimensions() {
  if [ -n "${COLUMNS:-}" ]; then
    printf " -e COLUMNS"
  fi
  if [ -n "${LINES:-}" ]; then
    printf " -e LINES"
  fi
}

add_terminal_display() {
  if [ -n "${COLORTERM:-}" ]; then
    printf " -e COLORTERM"
  fi
}

add_pager_variable() {
  if [ -n "${PAGER:-}" ]; then
    printf " -e PAGER"
  fi
  if [ -n "${AWS_PAGER:-}" ]; then
    printf " -e AWS_PAGER"
  fi
}

add_locale_variables() {
  if [ -n "${LANG:-}" ]; then
    printf " -e LANG"
  fi
  for var in $(env | grep '^LC_' | cut -d= -f1); do
    printf " -e %s" "$var"
  done
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

main() {
  parse_arguments "$@"

  shift $((CMD_ARGS_START - 1))

  verify_docker_installed
  determine_image
  resolve_command_location
  build_docker_arguments

  exec docker run $DOCKER_ARGS "$IMAGE" "$CMD_PATH" "$@"
}

main "$@"
