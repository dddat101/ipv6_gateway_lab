#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - DUT-SIDE PACKET CAPTURE VIA SSH
# Captures traffic directly on the DUT interface and pulls pcap to host
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
==================================================================
  IPv6 Gateway Test Lab - DUT-Side Packet Capture
==================================================================

Description:
  Executes remote tcpdump directly on the DUT device via SSH, saves
  the raw capture in DUT /tmp, transfers the resulting PCAP file to
  the local host captures/ directory, and purges the remote temporary file.

Usage:
  ./scripts/dut_capture.sh [duration_seconds]
  ./scripts/dut_capture.sh -h | --help

Options:
  -h, --help  Show this help message and exit

Examples:
  ./scripts/dut_capture.sh -h
  ./scripts/dut_capture.sh 15
  ./scripts/dut_capture.sh 30

Suggested Next Steps:
  - Verify capture:       ./scripts/verify_capture.sh captures/<dut_capture>.pcap
  - Inspect lab state:    ./scripts/show_state.sh
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

    load_config

    if ! check_command ssh || ! check_command scp; then
        die "ssh and scp commands are required. Install via: sudo ./scripts/install_deps.sh"
    fi

    [[ -n "${DUT_SSH_HOST:-}" ]] || die "DUT_SSH_HOST is empty in config.env."
    [[ -n "${DUT_SSH_USER:-}" ]] || die "DUT_SSH_USER is empty in config.env."
    [[ -n "${DUT_CAPTURE_IF:-}" ]] || die "DUT_CAPTURE_IF is empty in config.env."

    local duration="${1:-${DUT_CAPTURE_DURATION_SEC:-30}}"
    local timestamp remote local_file
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    remote="/tmp/dut_capture_${timestamp}.pcap"
    local_file="${CAPTURE_DIR}/dut_${timestamp}.pcap"

    ensure_runtime_dirs
    print_header "DUT REMOTE PACKET CAPTURE"
    log_info "Capturing ${duration}s on DUT interface ${DUT_CAPTURE_IF} (${DUT_SSH_USER}@${DUT_SSH_HOST})..."

    local ssh_opts=(-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR)
    [[ -n "${DUT_SSH_PORT:-}" ]] && ssh_opts+=(-p "${DUT_SSH_PORT}")
    [[ -n "${DUT_SSH_KEY:-}" && -f "${DUT_SSH_KEY}" ]] && ssh_opts+=(-i "${DUT_SSH_KEY}")

    ssh "${ssh_opts[@]}" "${DUT_SSH_USER}@${DUT_SSH_HOST}" \
        "timeout ${duration} tcpdump -ni '${DUT_CAPTURE_IF}' -s 0 -U -w '${remote}'" 2>/dev/null || true

    log_info "Transferring capture file to host..."
    scp "${ssh_opts[@]}" "${DUT_SSH_USER}@${DUT_SSH_HOST}:${remote}" "${local_file}"

    ssh "${ssh_opts[@]}" "${DUT_SSH_USER}@${DUT_SSH_HOST}" "rm -f '${remote}'" 2>/dev/null || true

    log_success "DUT capture saved: ${local_file}"
}

main "$@"
