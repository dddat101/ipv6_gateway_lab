#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - RUNTIME OBSERVATION & STATE DISPLAY
# Supports non-root graceful degradation and comprehensive namespace inspection
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

show_ns() {
    local ns="$1"
    if ! ns_exists "${ns}"; then return 0; fi

    printf '\n------------------------------------------------------------\n'
    printf '  Namespace: %s\n' "${ns}"
    printf '------------------------------------------------------------\n'

    if (( EUID == 0 )); then
        printf '== Interfaces & IP Addresses ==\n'
        ip -n "${ns}" -br addr 2>/dev/null || true

        printf '\n== IPv4 Routes ==\n'
        ip -n "${ns}" route show 2>/dev/null || printf '<none>\n'

        printf '\n== IPv6 Routes ==\n'
        ip -n "${ns}" -6 route show 2>/dev/null || printf '<none>\n'

        printf '\n== IPv6 Neighbors ==\n'
        ip -n "${ns}" -6 neigh show 2>/dev/null || printf '<none>\n'
    else
        printf '  <Run "sudo %s" to view internal IP/route/neighbor tables>\n' "$0"
    fi
}

show_daemons() {
    printf '\n============================================================\n'
    printf '                  ACTIVE TEST DAEMONS                       \n'
    printf '============================================================\n'

    local pids_found=0
    local pidfile
    for pidfile in "${STATE_DIR}"/*.pid; do
        if [[ -f "${pidfile}" ]]; then
            local name
            name="$(basename "${pidfile}" .pid)"
            if is_pidfile_running "${pidfile}"; then
                printf '  %-20s -> RUNNING (PID %s)\n' "${name}" "$(cat "${pidfile}")"
                pids_found=1
            else
                printf '  %-20s -> STALE PID FILE (Process not running)\n' "${name}"
            fi
        fi
    done

    if (( pids_found == 0 )); then
        printf '  No background test daemons recorded.\n'
    fi
}

main() {
    load_config

    printf '============================================================\n'
    printf '        IPv6 Gateway Lab - Current Runtime State           \n'
    printf '============================================================\n'

    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        printf '\n== Topology State ==\n'
        cat "${STATE_DIR}/topology_state.env"
    fi

    printf '\n== Linux Bridges & Ports ==\n'
    local br
    for br in "${WAN_BRIDGE}" "${LAN_BRIDGE}"; do
        if bridge_exists "${br}"; then
            printf '  Bridge %s: UP\n' "${br}"
            ip link show master "${br}" 2>/dev/null | grep -E '^[0-9]+:' | awk '{print "    - "$2}' | tr -d ':' || true
        else
            printf '  Bridge %s: NOT CREATED\n' "${br}"
        fi
    done

    # Namespaces details
    show_ns "${NS_WAN}"
    show_ns "${NS_LAN}"
    show_ns "${NS_DUT}"

    show_daemons

    # Capture Status
    printf '\n'
    "${SCRIPT_DIR}/capture.sh" status

    printf '\n============================================================\n'
}

main "$@"
