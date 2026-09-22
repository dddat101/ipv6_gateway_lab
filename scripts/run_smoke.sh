#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - ONE-TOUCH PRE-FLIGHT SMOKE RUNNER
# Combined diagnostic assertion and runtime state observer (runs without root)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'USAGE'
==================================================================
  IPv6 Gateway Test Lab - One-Touch Smoke Test
==================================================================

Description:
  Executes pre-flight system diagnostics followed by immediate
  runtime state observation. Runs safely without root privileges.

Usage:
  ./scripts/run_smoke.sh [options]
  ./scripts/run_smoke.sh -h | --help

Options:
  -h, --help  Show this help message and exit

Examples:
  ./scripts/run_smoke.sh

Suggested Next Steps:
  - Deploy virtual lab:    sudo ./scripts/setup.sh --virtual
  - Deploy physical lab:   sudo ./scripts/setup.sh --single
==================================================================
USAGE
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    echo "=== 1. Running Pre-flight System & Environment Diagnostics ==="
    "${SCRIPT_DIR}/diagnose.sh"

    echo -e "\n=== 2. Checking Current Runtime State & Services ==="
    "${SCRIPT_DIR}/show_state.sh"
}

main "$@"
