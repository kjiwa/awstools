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

TARGET_DIR=""
INSTALL_COMPLETION=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==============================================================================
# User Interface
# ==============================================================================

usage() {
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
  exit 1
}

error_exit() {
  printf "ERROR: %s\n" "$1" >&2
  exit 1
}

# ==============================================================================
# Argument Parsing
# ==============================================================================

parse_options() {
  while getopts "d:c:h" opt; do
    case "$opt" in
    d) TARGET_DIR="$OPTARG" ;;
    c) INSTALL_COMPLETION="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
    esac
  done

  if [ -z "$TARGET_DIR" ]; then
    error_exit "Target directory is required (-d option)"
  fi
}

# ==============================================================================
# Validation
# ==============================================================================

validate_completion_shell() {
  if [ -n "$INSTALL_COMPLETION" ]; then
    case "$INSTALL_COMPLETION" in
    bash | zsh) ;;
    *) error_exit "Completion shell must be: bash or zsh" ;;
    esac
  fi
}

check_source_file() {
  file="$1"
  if [ ! -f "$SCRIPT_DIR/$file" ]; then
    error_exit "Source file not found: $SCRIPT_DIR/$file"
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

# ==============================================================================
# Installation Operations
# ==============================================================================

copy_and_rename() {
  source="$1"
  dest="$2"

  printf "Installing: %s\n" "$dest"
  cp "$SCRIPT_DIR/$source" "$TARGET_DIR/$dest" || error_exit "Failed to copy $source to $TARGET_DIR/$dest"
  chmod +x "$TARGET_DIR/$dest" || error_exit "Failed to set executable permission on $TARGET_DIR/$dest"
}

install_main_scripts() {
  copy_and_rename "awsenv.sh" "awsenv"
  copy_and_rename "ec2client.sh" "ec2client"
  copy_and_rename "rdsclient.sh" "rdsclient"
}

create_wrapper_script() {
  name="$1"
  target="$TARGET_DIR/$name"

  printf "Creating wrapper: %s\n" "$name"
  cat >"$target" <<EOF
#!/bin/sh
exec $TARGET_DIR/awsenv "\$(basename "\$0")" "\$@"
EOF
  chmod +x "$target" || error_exit "Failed to set executable permission on $target"
}

install_wrapper_scripts() {
  create_wrapper_script "aws"
  create_wrapper_script "aws_completer"
  create_wrapper_script "session-manager-plugin"
}

# ==============================================================================
# Shell Completion Setup
# ==============================================================================

get_user_home() {
  if [ -n "${HOME:-}" ]; then
    printf "%s" "$HOME"
  else
    # Get home directory from /etc/passwd
    printf "%s" "$(getent passwd "$(id -u)" | cut -d: -f6)"
  fi
}

get_shell_rc_file() {
  shell="$1"
  user_home=$(get_user_home)

  case "$shell" in
  bash) printf "%s/.bashrc" "$user_home" ;;
  zsh) printf "%s/.zshrc" "$user_home" ;;
  *) return 1 ;;
  esac
}

get_completion_commands() {
  shell="$1"

  case "$shell" in
  bash)
    printf "complete -C aws_completer aws"
    ;;
  zsh)
    printf "autoload -Uz compinit && compinit\ncomplete -C aws_completer aws"
    ;;
  *)
    return 1
    ;;
  esac
}

check_completion_exists() {
  rc_file="$1"

  if [ ! -f "$rc_file" ]; then
    return 1
  fi

  grep -q "complete -C aws_completer aws" "$rc_file" 2>/dev/null
}

append_completion() {
  rc_file="$1"
  commands="$2"

  printf "\n# AWS CLI completion (added by install.sh)\n" >>"$rc_file"
  printf "%s\n" "$commands" >>"$rc_file"
}

install_shell_completion() {
  if [ -z "$INSTALL_COMPLETION" ]; then
    return 0
  fi

  rc_file=$(get_shell_rc_file "$INSTALL_COMPLETION")

  if check_completion_exists "$rc_file"; then
    printf "Completion already configured in: %s\n" "$rc_file"
    return 0
  fi

  commands=$(get_completion_commands "$INSTALL_COMPLETION")

  printf "Installing %s completion to: %s\n" "$INSTALL_COMPLETION" "$rc_file"
  append_completion "$rc_file" "$commands"

  printf "\nTo activate completion, run:\n"
  printf "  source %s\n" "$rc_file"
}

# ==============================================================================
# Output
# ==============================================================================

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

  printf "\nVerify installation:\n"
  printf "  %s/aws --version\n" "$TARGET_DIR"
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
