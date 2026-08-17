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

main() {
    require_cmd ssh
    require_cmd scp
    load_config

    [[ -n "${DUT_SSH_HOST:-}" ]] || die "DUT_SSH_HOST is empty in config.env."
    [[ -n "${DUT_SSH_USER:-}" ]] || die "DUT_SSH_USER is empty in config.env."
    [[ -n "${DUT_CAPTURE_IF:-}" ]] || die "DUT_CAPTURE_IF is empty in config.env."

    local timestamp remote local_file duration
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    duration="${DUT_CAPTURE_DURATION_SEC:-30}"
    remote="/tmp/dut_capture_${timestamp}.pcap"
    local_file="${CAPTURE_DIR}/dut_${timestamp}.pcap"

    log_info "Capturing ${duration}s on DUT interface ${DUT_CAPTURE_IF} (${DUT_SSH_USER}@${DUT_SSH_HOST})..."

    # shellcheck disable=SC2086
    ssh ${DUT_SSH_OPTS:-} "${DUT_SSH_USER}@${DUT_SSH_HOST}" \
        "timeout ${duration} tcpdump -ni '${DUT_CAPTURE_IF}' -s 0 -U -w '${remote}'" 2>/dev/null || true

    log_info "Pulling capture file to host..."
    # shellcheck disable=SC2086
    scp ${DUT_SSH_OPTS:-} "${DUT_SSH_USER}@${DUT_SSH_HOST}:${remote}" "${local_file}"

    # shellcheck disable=SC2086
    ssh ${DUT_SSH_OPTS:-} "${DUT_SSH_USER}@${DUT_SSH_HOST}" "rm -f '${remote}'" 2>/dev/null || true

    log_info "DUT capture saved: ${local_file}"
}

main "$@"
