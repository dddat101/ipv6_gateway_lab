#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - IPV6 GATEWAY CLEANUP SCRIPT
# Idempotently tears down netns, veths, bridges, daemons,
# and restores physical interfaces to UP state with DHCP.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/cleanup.sh [options]
  ./scripts/cleanup.sh logs
  ./scripts/cleanup.sh captures
  ./scripts/cleanup.sh data

Options:
  -r, --restore, --dhcp    Restore physical interfaces (WAN_IF, LAN_IF) to UP, re-enable NetworkManager,
                           and trigger DHCP [Default]
  -d, --down, --no-restore Keep physical interfaces DOWN and flushed (isolated test mode)
  --logs                   Purge all test logs in logs/
  --captures               Purge all PCAP captures in captures/
  -a, --all                Teardown topology and purge state, logs, and captures
  -h, --help               Show this help message

Subcommands (Non-destructive to running topology):
  logs                     Purge logs/ without tearing down lab
  captures                 Purge captures/ without tearing down lab
  data                     Purge both logs/ and captures/ without tearing down lab
USAGE
}

main() {
    local arg
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config

    # Non-destructive subcommands
    case "${1:-}" in
        logs)
            clean_logs
            exit 0
            ;;
        captures)
            clean_captures
            exit 0
            ;;
        data)
            clean_logs
            clean_captures
            exit 0
            ;;
    esac

    require_root
    require_command ip

    local restore="${RESTORE_INTERFACES_ON_CLEANUP:-1}"
    local clean_logs_flag=0
    local clean_captures_flag=0

    while (( $# > 0 )); do
        case "$1" in
            -r|--restore|--dhcp)    restore=1; shift ;;
            -d|--down|--no-restore) restore=0; shift ;;
            --logs)                 clean_logs_flag=1; shift ;;
            --captures)             clean_captures_flag=1; shift ;;
            -a|--all)               clean_logs_flag=1; clean_captures_flag=1; shift ;;
            *)                      usage; exit 2 ;;
        esac
    done

    log_info "Initiating cleanup of IPv6 Gateway Lab (restore_interfaces=${restore})..."

    # 1. Stop capture and client processes
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" stop 2>/dev/null || true
    fi

    if [[ -x "${SCRIPT_DIR}/client_dhcp.sh" ]]; then
        "${SCRIPT_DIR}/client_dhcp.sh" release 2>/dev/null || true
    fi

    if [[ -x "${SCRIPT_DIR}/wan_server.sh" ]]; then
        "${SCRIPT_DIR}/wan_server.sh" stop 2>/dev/null || true
    fi

    # Stop recorded PID files
    local pidfile
    for pidfile in "${STATE_DIR}"/*.pid; do
        if [[ -f "${pidfile}" ]]; then
            stop_pidfile "${pidfile}"
        fi
    done

    # Stop daemons in namespaces
    local ns
    for ns in "${NS_WAN}" "${NS_LAN}" "${NS_DUT}"; do
        if ns_exists "${ns}"; then
            ip netns exec "${ns}" pkill -TERM radvd 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM kea-dhcp4 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM kea-dhcp6 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM dnsmasq 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM iperf3 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM tcpdump 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM tshark 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM udhcpc 2>/dev/null || true
            ip netns exec "${ns}" pkill -TERM dhclient 2>/dev/null || true
        fi
    done

    # 2. Delete virtual interfaces
    local veth
    for veth in v-wan-h v-lan1-h v-dut-wan-h v-dut-lan-h; do
        if ip link show dev "${veth}" >/dev/null 2>&1; then
            ip link del dev "${veth}" 2>/dev/null || true
        fi
    done

    # 3. Delete network namespaces
    for ns in "${NS_WAN}" "${NS_LAN}" "${NS_DUT}"; do
        if ns_exists "${ns}"; then
            ip netns del "${ns}" 2>/dev/null || true
        fi
    done

    # 4. Delete test bridges before restoring physical NICs
    local br
    for br in "${WAN_BRIDGE}" "${LAN_BRIDGE}"; do
        if bridge_exists "${br}"; then
            ip link set dev "${br}" down 2>/dev/null || true
            ip link del dev "${br}" 2>/dev/null || true
        fi
    done

    # 5. Restore physical interfaces to UP + DHCP (or keep them DOWN if requested)
    local ifaces=()
    local ifname
    for ifname in "${WAN_IF:-}" "${LAN_IF:-}" "${DUT_IF:-}"; do
        if [[ -n "${ifname}" ]] && iface_exists_root "${ifname}"; then
            if [[ ! " ${ifaces[*]:-} " =~ [[:space:]]${ifname}[[:space:]] ]]; then
                ifaces+=("${ifname}")
            fi
        fi
    done

    for ifname in "${ifaces[@]:-}"; do
        if (( restore == 1 )); then
            restore_physical_interface "${ifname}"
        else
            tear_down_physical_interface "${ifname}"
        fi
    done

    # 6. Clean runtime state files
    rm -f "${STATE_DIR}/topology_state.env" "${STATE_DIR}/last_capture.env" 2>/dev/null || true
    rm -f "${STATE_DIR}"/*.pid "${STATE_DIR}"/*.leases "${STATE_DIR}"/*.conf "${STATE_DIR}"/*.log "${STATE_DIR}"/*.state 2>/dev/null || true

    if (( clean_logs_flag == 1 )); then
        clean_logs
    fi
    if (( clean_captures_flag == 1 )); then
        clean_captures
    fi

    log_info "Cleanup completed successfully. All test resources released."
}

main "$@"
