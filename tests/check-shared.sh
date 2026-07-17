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
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP1="$(mktemp)"
TMP2="$(mktemp)"
cleanup() {
  rm -f "$TMP1" "$TMP2"
}
trap cleanup EXIT INT TERM HUP

extract_block() {
  # extract_block <file> <marker-name>
  file="$1"
  marker="$2"
  awk -v m="$marker" '
    index($0, "BEGIN SHARED: " m " ---") { p = 1; next }
    index($0, "END SHARED: " m " ---") { p = 0 }
    p { print }
  ' "$file"
}

list_markers() {
  file="$1"
  grep -o 'BEGIN SHARED: [A-Za-z0-9_-]*' "$file" 2>/dev/null | sed 's/^BEGIN SHARED: //'
}

scripts=""
for f in "$REPO_DIR"/*.sh; do
  [ -f "$f" ] || continue
  scripts="$scripts $f"
done

all_markers=""
for f in $scripts; do
  markers=$(list_markers "$f") || true
  [ -n "$markers" ] && all_markers="$all_markers
$markers"
done

unique_markers=$(printf "%s\n" "$all_markers" | grep -v '^$' | sort -u || true)

failures=0
checked=0

if [ -z "$unique_markers" ]; then
  echo "check-shared.sh: no SHARED markers found"
else
  for marker in $unique_markers; do
    reference_file=""
    for f in $scripts; do
      grep -q "BEGIN SHARED: $marker ---" "$f" 2>/dev/null || continue

      if [ -z "$reference_file" ]; then
        reference_file="$f"
        extract_block "$f" "$marker" >"$TMP1"
        continue
      fi

      extract_block "$f" "$marker" >"$TMP2"
      checked=$((checked + 1))

      if ! diff -q "$TMP1" "$TMP2" >/dev/null 2>&1; then
        echo "DRIFT: shared block '$marker' differs between $reference_file and $f"
        diff "$TMP1" "$TMP2" || true
        failures=$((failures + 1))
      fi
    done
  done
fi

if [ "$failures" -gt 0 ]; then
  echo "check-shared.sh: $failures shared block(s) drifted"
else
  printf "check-shared.sh: %d marker(s) verified byte-identical across copies\n" "$checked"
fi

[ "$failures" -eq 0 ]
