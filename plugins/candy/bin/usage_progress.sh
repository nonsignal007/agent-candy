#!/bin/bash
set -euo pipefail

JOBS_ROOT="${JOBS_ROOT:-$HOME/jobs}"

SNAPSHOT_TYPE=progress exec "$JOBS_ROOT/bin/usage_snapshot.sh"
