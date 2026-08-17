#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - DUT HARDWARE STATE & EVIDENCE COLLECTOR
# Collects CPU load, softirqs, offload/flow-cache, routes, and neighbors via SSH
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    load_config
    require_command ssh

    if [[ -z "${DUT_SSH_HOST:-}" ]]; then
        log_warn "DUT_SSH_HOST is not configured in config.env. Skipping remote collection."
        exit 0
    fi

    local timestamp output_file
    timestamp="$(date +%Y%m%d_%H%M%S)"
    output_file="${STATE_DIR}/dut_evidence_${timestamp}.log"

    log_info "Collecting DUT diagnostic state from ${DUT_SSH_USER}@${DUT_SSH_HOST}..."

    # shellcheck disable=SC2086
    ssh ${DUT_SSH_OPTS:-} "${DUT_SSH_USER}@${DUT_SSH_HOST}" 'bash -s' << 'REMOTE_EOF' > "${output_file}" 2>&1 || true
        echo "=== DUT System Time ==="
        date

        echo -e "\n=== Uptime & Load Average ==="
        uptime 2>/dev/null || cat /proc/loadavg

        echo -e "\n=== Network Interfaces & Addresses ==="
        ip -br addr show 2>/dev/null || ifconfig -a

        echo -e "\n=== IPv4 Routing Table ==="
        ip route show 2>/dev/null || route -n

        echo -e "\n=== IPv6 Routing Table ==="
        ip -6 route show 2>/dev/null || route -A inet6 -n 2>/dev/null

        echo -e "\n=== IPv6 Neighbor Table ==="
        ip -6 neigh show 2>/dev/null

        echo -e "\n=== Hardware Acceleration / Flow-Cache Status ==="
        if command -v fcctl >/dev/null 2>&1; then
            fcctl status 2>/dev/null || true
        elif command -v flow-cache >/dev/null 2>&1; then
            flow-cache status 2>/dev/null || true
        else
            echo "<fcctl / flow-cache command not available on DUT>"
        fi

        echo -e "\n=== CPU SoftIRQs ==="
        cat /proc/softirqs 2>/dev/null || true

        echo -e "\n=== Conntrack Entries ==="
        cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || cat /proc/net/ip_conntrack 2>/dev/null | wc -l || true
REMOTE_EOF

    log_info "DUT evidence saved to: ${output_file}"
}

main "$@"
