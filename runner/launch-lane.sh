#!/usr/bin/env bash
# Attach the lane PID before exec; never inherit the supervisor's lease into tools.
set -euo pipefail
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
journal_dir="$1"; run_id="$2"; receipt="$3"; shift 3
node "$RUNNER_DIR/lane-journal.mjs" attach "$journal_dir" "$run_id" "$receipt" "$$"
exec "$@"
