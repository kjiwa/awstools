#!/bin/bash

# Prepares a shell for recording demo.gif. Sourced by demo.tape (bash).
#
# Puts the stub `aws` from the test harness plus a demo `docker` (which
# plays a canned psql session) on PATH, points rdsclient at the test
# fixtures, and exposes `rdsclient` as a command. Nothing here touches a
# real AWS account or Docker daemon.

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"
REPO_DIR="$(cd "$DEMO_DIR/.." && pwd)"
DEMO_BIN="$(mktemp -d)"

cp "$REPO_DIR/tests/stubs/aws" "$DEMO_BIN/aws"
cp "$DEMO_DIR/docker-stub" "$DEMO_BIN/docker"

cat >"$DEMO_BIN/rdsclient" <<EOF
#!/bin/sh
exec "$REPO_DIR/rdsclient.sh" "\$@"
EOF

chmod +x "$DEMO_BIN/aws" "$DEMO_BIN/docker" "$DEMO_BIN/rdsclient"

PATH="$DEMO_BIN:$PATH"
export PATH

FIXTURE_DB_INSTANCES="$REPO_DIR/tests/fixtures/rds/instances_basic.json"
FIXTURE_DB_CLUSTERS="$REPO_DIR/tests/fixtures/rds/clusters_mixed.json"
FIXTURE_IAM_TOKEN="demo-token"
export FIXTURE_DB_INSTANCES FIXTURE_DB_CLUSTERS FIXTURE_IAM_TOKEN
