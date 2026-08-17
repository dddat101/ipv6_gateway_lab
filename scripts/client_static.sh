#!/usr/bin/env bash
# Backward compatibility wrapper for client_dhcp.sh static
set -Eeuo pipefail
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/client_dhcp.sh" static "$@"
