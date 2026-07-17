#!/bin/sh

# Helpers for loading function definitions from the real scripts into a test
# process without triggering their `main "$@"` entry point.

# strip_entrypoint <script>
# Prints every line of <script> except a bare trailing `main "$@"` call and
# the top-level `set -eu`, so the result can be sourced to get all
# function/variable definitions without actually running the tool and
# without imposing the tool's strict mode on the sourcing test process.
strip_entrypoint() {
  grep -v '^main "\$@"$' "$1" | grep -v '^set -eu$'
}

# load_script_functions <script> <dest-file>
# Writes the entrypoint-stripped script to <dest-file> so it can be sourced.
load_script_functions() {
  strip_entrypoint "$1" >"$2"
}
