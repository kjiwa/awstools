#!/bin/sh

# Drift check for the "fully standalone but deduplicated by convention"
# strategy used by ec2client.sh/rdsclient.sh (and any other script in the
# repo root): functions shared across scripts are kept byte-identical inside
# fenced marker comments:
#
#   # --- BEGIN SHARED: <name> ---
#   ...function body...
#   # --- END SHARED: <name> ---
#
# This script finds every marker name used anywhere in the repo root's *.sh
# files, and for each one that appears in more than one file, verifies all
# copies are byte-identical. It fails (non-zero exit) on any mismatch.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly REPO_DIR

extract_block() {
  _extract_file="$1"
  _extract_marker="$2"
  awk -v m="$_extract_marker" '
    index($0, "BEGIN SHARED: " m " ---") { p = 1; next }
    index($0, "END SHARED: " m " ---") { p = 0 }
    p { print }
  ' "$_extract_file"
}

list_markers() {
  _list_file="$1"
  grep -o 'BEGIN SHARED: [A-Za-z0-9_-]*' "$_list_file" 2>/dev/null | sed 's/^BEGIN SHARED: //'
}

main() {
  _main_tmp1="$(mktemp)"
  _main_tmp2="$(mktemp)"
  trap 'rm -f "$_main_tmp1" "$_main_tmp2"' EXIT INT TERM HUP

  _main_scripts=""
  for _main_f in "$REPO_DIR"/*.sh; do
    [ -f "$_main_f" ] || continue
    _main_scripts="$_main_scripts $_main_f"
  done

  _main_all_markers=""
  for _main_f in $_main_scripts; do
    _main_file_markers=$(list_markers "$_main_f") || true
    [ -n "$_main_file_markers" ] && _main_all_markers="$_main_all_markers
$_main_file_markers"
  done

  _main_unique_markers=$(printf "%s\n" "$_main_all_markers" | grep -v '^$' | sort -u || true)

  _main_failures=0
  _main_checked=0

  if [ -z "$_main_unique_markers" ]; then
    echo "check-shared.sh: no SHARED markers found"
  else
    for _main_marker in $_main_unique_markers; do
      _main_reference_file=""
      for _main_f in $_main_scripts; do
        grep -q "BEGIN SHARED: $_main_marker ---" "$_main_f" 2>/dev/null || continue

        if [ -z "$_main_reference_file" ]; then
          _main_reference_file="$_main_f"
          extract_block "$_main_f" "$_main_marker" >"$_main_tmp1"
          continue
        fi

        extract_block "$_main_f" "$_main_marker" >"$_main_tmp2"
        _main_checked=$((_main_checked + 1))

        if ! diff -q "$_main_tmp1" "$_main_tmp2" >/dev/null 2>&1; then
          echo "DRIFT: shared block '$_main_marker' differs between $_main_reference_file and $_main_f"
          diff "$_main_tmp1" "$_main_tmp2" || true
          _main_failures=$((_main_failures + 1))
        fi
      done
    done
  fi

  if [ "$_main_failures" -gt 0 ]; then
    echo "check-shared.sh: $_main_failures shared block(s) drifted"
  else
    printf "check-shared.sh: %d marker(s) verified byte-identical across copies\n" "$_main_checked"
  fi

  [ "$_main_failures" -eq 0 ]
}

main "$@"
