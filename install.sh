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

TARGET_DIR=""
INSTALL_COMPLETION=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR

usage() {
  _usage_exit_code="${1:-1}"

  cat >&2 <<EOF
Usage: $0 -d DIRECTORY [-c SHELL]

Required:
  -d DIRECTORY      Target installation directory

Optional:
  -c SHELL          Install shell completion (bash or zsh)
  -h                Show this help message

Examples:
  $0 -d /usr/local/bin
  $0 -d ~/.local/bin -c bash
  sudo $0 -d /usr/local/bin -c zsh
EOF
  exit "$_usage_exit_code"
}

# --- BEGIN SHARED: error_exit ---
error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}
# --- END SHARED: error_exit ---

parse_options() {
  while getopts "d:c:h" _parse_opt; do
    case "$_parse_opt" in
    d) TARGET_DIR="$OPTARG" ;;
    c) INSTALL_COMPLETION="$OPTARG" ;;
    h) usage 0 ;;
    *) usage ;;
    esac
  done

  shift $((OPTIND - 1))
  [ $# -gt 0 ] && error_exit "Unexpected argument: $1"

  if [ -z "$TARGET_DIR" ]; then
    error_exit "Target directory is required (-d option)"
  fi
}

validate_completion_shell() {
  if [ -n "$INSTALL_COMPLETION" ]; then
    case "$INSTALL_COMPLETION" in
    bash | zsh) ;;
    *) error_exit "Completion shell must be: bash or zsh" ;;
    esac
  fi
}

check_source_file() {
  _check_file="$1"
  if [ ! -f "$SCRIPT_DIR/$_check_file" ]; then
    error_exit "Source file not found: $SCRIPT_DIR/$_check_file"
  fi
}

validate_source_files() {
  check_source_file "awsenv.sh"
  check_source_file "ec2client.sh"
  check_source_file "rdsclient.sh"
}

create_target_directory() {
  if [ ! -d "$TARGET_DIR" ]; then
    printf "Creating directory: %s\n" "$TARGET_DIR"
    mkdir -p "$TARGET_DIR" || error_exit "Failed to create directory: $TARGET_DIR"
  fi
}

validate_target_writable() {
  if [ ! -w "$TARGET_DIR" ]; then
    error_exit "Target directory is not writable: $TARGET_DIR"
  fi
}

copy_and_rename() {
  _copy_source="$1"
  _copy_dest="$2"

  printf "Installing: %s\n" "$_copy_dest"
  cp "$SCRIPT_DIR/$_copy_source" "$TARGET_DIR/$_copy_dest" || error_exit "Failed to copy $_copy_source to $TARGET_DIR/$_copy_dest"
  chmod +x "$TARGET_DIR/$_copy_dest" || error_exit "Failed to set executable permission on $TARGET_DIR/$_copy_dest"
}

install_main_scripts() {
  copy_and_rename "awsenv.sh" "awsenv"
  copy_and_rename "ec2client.sh" "ec2client"
  copy_and_rename "rdsclient.sh" "rdsclient"
}

create_wrapper_script() {
  _wrapper_name="$1"
  _wrapper_target="$TARGET_DIR/$_wrapper_name"

  printf "Creating wrapper: %s\n" "$_wrapper_name"
  cat >"$_wrapper_target" <<EOF
#!/bin/sh
exec "$TARGET_DIR/awsenv" "\$(basename "\$0")" "\$@"
EOF
  chmod +x "$_wrapper_target" || error_exit "Failed to set executable permission on $_wrapper_target"
}

install_wrapper_scripts() {
  create_wrapper_script "aws"
  create_wrapper_script "aws_completer"
  create_wrapper_script "session-manager-plugin"
}

get_user_home() {
  [ -z "${HOME:-}" ] && error_exit "HOME is not set"
  printf "%s" "$HOME"
}

get_shell_rc_file() {
  _rc_shell="$1"
  _rc_home=$(get_user_home)

  case "$_rc_shell" in
  bash) printf "%s/.bashrc" "$_rc_home" ;;
  zsh) printf "%s/.zshrc" "$_rc_home" ;;
  *) return 1 ;;
  esac
}

get_completion_commands() {
  _comp_shell="$1"

  case "$_comp_shell" in
  bash)
    printf "complete -C aws_completer aws"
    ;;
  zsh)
    printf "autoload -Uz compinit && compinit\nautoload -Uz +X bashcompinit && bashcompinit\ncomplete -C aws_completer aws"
    ;;
  *)
    return 1
    ;;
  esac
}

check_completion_exists() {
  _check_rc_file="$1"

  if [ ! -f "$_check_rc_file" ]; then
    return 1
  fi

  grep -q "complete -C aws_completer aws" "$_check_rc_file" 2>/dev/null
}

append_completion() {
  _append_rc_file="$1"
  _append_commands="$2"

  touch "$_append_rc_file" || error_exit "Failed to create RC file: $_append_rc_file"
  printf "\n# AWS CLI completion (added by install.sh)\n" >>"$_append_rc_file"
  printf "%s\n" "$_append_commands" >>"$_append_rc_file"
}

install_shell_completion() {
  if [ -z "$INSTALL_COMPLETION" ]; then
    return 0
  fi

  _install_rc_file=$(get_shell_rc_file "$INSTALL_COMPLETION")

  if check_completion_exists "$_install_rc_file"; then
    printf "Completion already configured in: %s\n" "$_install_rc_file"
    return 0
  fi

  _install_commands=$(get_completion_commands "$INSTALL_COMPLETION")

  printf "Installing %s completion to: %s\n" "$INSTALL_COMPLETION" "$_install_rc_file"
  append_completion "$_install_rc_file" "$_install_commands"

  printf "\nTo activate completion, run:\n"
  printf "  source %s\n" "$_install_rc_file"
}

print_success() {
  printf "\nInstallation complete!\n"
  printf "\nInstalled to: %s\n" "$TARGET_DIR"
  printf "  - awsenv\n"
  printf "  - ec2client\n"
  printf "  - rdsclient\n"
  printf "  - aws (wrapper)\n"
  printf "  - aws_completer (wrapper)\n"
  printf "  - session-manager-plugin (wrapper)\n"

  if [ -n "$INSTALL_COMPLETION" ]; then
    printf "\nShell completion configured for: %s\n" "$INSTALL_COMPLETION"
  fi

  printf "\nVerifying installation:\n"
  if "$TARGET_DIR/awsenv" aws --version >/dev/null 2>&1; then
    printf "  %s/aws --version ... OK\n" "$TARGET_DIR"
  else
    printf "  %s/aws --version ... WARNING: Verification failed\n" "$TARGET_DIR"
  fi
}

# ==============================================================================
# Main Entry Point
# ==============================================================================

main() {
  parse_options "$@"
  validate_completion_shell
  validate_source_files
  create_target_directory
  validate_target_writable
  install_main_scripts
  install_wrapper_scripts
  install_shell_completion
  print_success
}

main "$@"
