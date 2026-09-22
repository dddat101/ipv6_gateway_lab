#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - PACKET CAPTURE MANAGER (start | stop | status | clean)
# Prioritizes tcpdump (-s 0 -U) to prevent dumpcap permission dropping issues
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
==================================================================
  IPv6 Gateway Test Lab - Packet Capture Manager
==================================================================

Description:
  Manages background packet capture (tcpdump / tshark) on WAN and LAN
  interfaces inside network namespaces. Captures IPv4, IPv6, DHCP,
  ICMPv6, and DS-Lite packets into PCAP files for automated verification.

Usage:
  sudo ./scripts/capture.sh start [wan | lan | both]
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh status
  ./scripts/capture.sh clean
  ./scripts/capture.sh -h | --help

Commands:
  start [target]   Start background packet capture (wan, lan, or both) [Default: both]
  stop             Stop all active packet captures
  status           Show current capture process status, PIDs, and latest files
  clean            Stop captures and purge all capture files in captures/
  -h, --help       Show this help message and exit

Examples:
  ./scripts/capture.sh -h
  sudo ./scripts/capture.sh start both
  sudo ./scripts/capture.sh start wan
  ./scripts/capture.sh status
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh clean

Suggested Next Steps:
  - Run verification:      ./scripts/verify_capture.sh
  - Inspect capture state: ./scripts/capture.sh status
==================================================================
USAGE
}

start_single_capture() {
    local target="$1"      # wan or lan
    local ns="$2"
    local iface="$3"
    local timestamp="$4"

    local pid_file="${STATE_DIR}/cap_${target}.pid"
    local log_file="${LOG_DIR}/cap_${target}_${timestamp}.log"
    local pcap_file="${CAPTURE_DIR}/capture_${target}_${timestamp}.pcap"

    if ! ns_exists "${ns}"; then
        log_warn "Namespace ${ns} does not exist. Skipping ${target} capture."
        return 0
    fi

    stop_pidfile "${pid_file}"

    log_info "Starting ${target} capture on ${ns}/${iface}..."
    ensure_runtime_dirs

    # Use tcpdump with -U (packet-buffered) and -s 0 (full payload)
    nohup ip netns exec "${ns}" \
        "${TCPDUMP_BIN:-tcpdump}" -ni "${iface}" -s 0 -U \
        -w "${pcap_file}" ${CAPTURE_FILTER} > "${log_file}" 2>&1 &

    local cap_pid=$!
    printf '%s\n' "${cap_pid}" > "${pid_file}"
    chmod 0666 "${pid_file}" "${log_file}" 2>/dev/null || true
    sleep 0.5

    if ! is_pidfile_running "${pid_file}"; then
        log_error "Capture failed to start on ${target}. Log output:"
        tail -n 20 "${log_file}" >&2 || true
        die "Failed to start capture on ${target}."
    fi

    printf 'LAST_PCAP_%s=%q\n' "$(tr '[:lower:]' '[:upper:]' <<< "${target}")" "${pcap_file}" >> "${STATE_DIR}/last_capture.env"
    printf 'LAST_PCAP=%q\n' "${pcap_file}" >> "${STATE_DIR}/last_capture.env"
    echo "${pcap_file}" > "${STATE_DIR}/latest_capture.txt"

    log_success "${target^} capture active: ${pcap_file} (PID: ${cap_pid})"
}

start_capture() {
    require_root
    load_config

    local target="${1:-both}"
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"

    # Initialize last capture file
    rm -f "${STATE_DIR}/last_capture.env"
    touch "${STATE_DIR}/last_capture.env"

    case "${target}" in
        wan)
            start_single_capture "wan" "${NS_WAN}" "${NS_IF}" "${timestamp}"
            ;;
        lan)
            start_single_capture "lan" "${NS_LAN}" "${NS_IF}" "${timestamp}"
            ;;
        both)
            start_single_capture "wan" "${NS_WAN}" "${NS_IF}" "${timestamp}"
            start_single_capture "lan" "${NS_LAN}" "${NS_IF}" "${timestamp}"
            ;;
        *)
            usage; exit 2
            ;;
    esac
}

stop_capture() {
    require_root
    load_config

    log_info "Stopping packet captures..."
    stop_pidfile "${STATE_DIR}/cap_wan.pid" "WAN Capture"
    stop_pidfile "${STATE_DIR}/cap_lan.pid" "LAN Capture"
    log_info "Captures stopped."
}

show_status() {
    load_config
    print_header "PACKET CAPTURE STATUS"

    local target pid_file
    for target in wan lan; do
        pid_file="${STATE_DIR}/cap_${target}.pid"
        if is_pidfile_running "${pid_file}"; then
            printf '  %-6s Capture: \e[1;32mRUNNING\e[0m (PID %s)\n' "${target^^}" "$(cat "${pid_file}")"
        else
            printf '  %-6s Capture: \e[1;33mSTOPPED\e[0m\n' "${target^^}"
        fi
    done

    if [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture.env"
        printf '\nLast Capture Files:\n'
        for target in WAN LAN; do
            local var_name="LAST_PCAP_${target}"
            local pcap_path="${!var_name:-}"
            if [[ -n "${pcap_path}" && -f "${pcap_path}" ]]; then
                local size
                size="$(du -h "${pcap_path}" 2>/dev/null | cut -f1 || echo '?')"
                printf '  %-6s: %s (%s)\n' "${target}" "${pcap_path}" "${size}"
            elif [[ -n "${pcap_path}" ]]; then
                printf '  %-6s: %s (not found on disk)\n' "${target}" "${pcap_path}"
            fi
        done
    fi
    printf '==================================================================\n'
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    case "${1:-status}" in
        start)     shift; start_capture "${1:-both}" ;;
        stop)      stop_capture ;;
        status)    show_status ;;
        clean)     stop_capture; clean_captures ;;
        -h|--help) usage; exit 0 ;;
        *)         usage; exit 2 ;;
    esac
}

main "$@"
