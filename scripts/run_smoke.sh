#!/usr/bin/env bash
# Quick smoke test runner
set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "=== Running Pre-flight Diagnostics ==="
"${SCRIPT_DIR}/diagnose.sh"
echo -e "\n=== Checking Runtime State ==="
"${SCRIPT_DIR}/show_state.sh"
