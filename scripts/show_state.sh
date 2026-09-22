#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - RUNTIME OBSERVATION & STATE DISPLAY
# Supports non-root graceful degradation, stale PID detection, and namespace inspection
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
==================================================================
  IPv6 Gateway Test Lab - Runtime State Observer
==================================================================

Description:
  Inspects and reports current runtime state of the network test lab,
  including topology metadata, Linux bridges, network namespaces,
  IP addresses, routes, supervised daemons, and captured PCAP evidence.

Usage:
  ./scripts/show_state.sh [options]
  sudo ./scripts/show_state.sh [options]
  ./scripts/show_state.sh -h | --help

Options:
  -h, --help  Show this help message and exit

Examples:
  ./scripts/show_state.sh
  sudo ./scripts/show_state.sh

Suggested Next Steps:
  - Start WAN servers:     sudo ./scripts/wan_server.sh start dual-stack
  - Run test scenarios:    sudo ./scripts/scenario.sh dual-stack
  - Verify compliance:     ./scripts/verify_capture.sh
  - Teardown when done:    sudo ./scripts/cleanup.sh
==================================================================
USAGE
}

show_ns() {
    local ns="$1"
    if ! ns_exists "${ns}"; then return 0; fi

    print_section "NAMESPACE: ${ns}"

    if is_root; then
        printf '== Interfaces & IP Addresses ==\n'
        ip -n "${ns}" -br addr 2>/dev/null || true

        printf '\n== IPv4 Routes ==\n'
        ip -n "${ns}" route show 2>/dev/null || printf '<none>\n'

        printf '\n== IPv6 Routes ==\n'
        ip -n "${ns}" -6 route show 2>/dev/null || printf '<none>\n'

        printf '\n== IPv6 Neighbors ==\n'
        ip -n "${ns}" -6 neigh show 2>/dev/null || printf '<none>\n'
    else
        printf '  Note: Run with "sudo %s" to view internal IP/route/neighbor tables.\n' "$(basename "$0")"
        ip netns exec "${ns}" ip -br link 2>/dev/null || ip link show 2>/dev/null || true
    fi
}

show_daemons() {
    print_section "SUPERVISED DAEMONS & SERVICES"

    local pids_found=0
    local pidfile
    for pidfile in "${STATE_DIR}"/*.pid; do
        if [[ -f "${pidfile}" ]]; then
            local name pid
            name="$(basename "${pidfile}" .pid)"
            pid="$(cat "${pidfile}" 2>/dev/null || true)"
            if is_pidfile_running "${pidfile}"; then
                printf '  %-24s -> \e[1;32mRUNNING\e[0m (PID: %s)\n' "${name}" "${pid}"
                pids_found=1
            else
                printf '  %-24s -> \e[1;31mSTALE PID FILE\e[0m (Process dead)\n' "${name}"
            fi
        fi
    done

    if (( pids_found == 0 )); then
        printf '  No background test daemons recorded.\n'
    fi
}

show_pcap_files() {
    print_section "CAPTURED PCAP EVIDENCE"
    if [[ -d "${CAPTURE_DIR}" ]]; then
        local count=0
        while IFS= read -r pcap_path; do
            if [[ -f "${pcap_path}" ]]; then
                count=$((count + 1))
                local size
                size="$(du -h "${pcap_path}" 2>/dev/null | cut -f1 || echo '?')"
                printf '  [%s] %s\n' "${size}" "$(basename "${pcap_path}")"
            fi
        done < <(find "${CAPTURE_DIR}" -maxdepth 1 -name '*.pcap*' -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}' | head -n 5)

        if (( count == 0 )); then
            printf '  No PCAP capture files found in %s.\n' "${CAPTURE_DIR}"
        fi
    fi
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config
    print_header "IPV6 GATEWAY TEST LAB RUNTIME STATE"

    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        print_section "TOPOLOGY METADATA"
        cat "${STATE_DIR}/topology_state.env"
    fi

    print_section "LINUX BRIDGES & PORTS"
    local br
    for br in "${WAN_BRIDGE}" "${LAN_BRIDGE}"; do
        if bridge_exists "${br}"; then
            printf '  Bridge %s: \e[1;32mUP\e[0m\n' "${br}"
            ip link show master "${br}" 2>/dev/null | grep -E '^[0-9]+:' | awk '{print "    - Member: "$2}' | tr -d ':' || true
        else
            printf '  Bridge %s: \e[1;33mNOT CREATED\e[0m\n' "${br}"
        fi
    done

    # Namespaces details
    show_ns "${NS_WAN}"
    show_ns "${NS_LAN}"
    show_ns "${NS_DUT}"

    show_daemons

    show_pcap_files

    # Capture Process Status
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        printf '\n'
        "${SCRIPT_DIR}/capture.sh" status
    fi
}

main "$@"
