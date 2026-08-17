#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - PACKET CAPTURE MANAGER (start | stop | status)
# Prioritizes tcpdump (-s 0 -U) to prevent dumpcap permission dropping issues
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/capture.sh start [wan|lan|both]
  sudo ./scripts/capture.sh stop
  ./scripts/capture.sh status
USAGE
}

start_single_capture() {
    local target="$1"      # wan or lan
    local ns="$2"
    local iface="$3"
    local timestamp="$4"

    local pid_file="${STATE_DIR}/cap_${target}.pid"
    local log_file="${STATE_DIR}/cap_${target}.log"
    local pcap_file="${CAPTURE_DIR}/capture_${target}_${timestamp}.pcap"

    if ! ns_exists "${ns}"; then
        log_warn "Namespace ${ns} does not exist. Skipping ${target} capture."
        return 0
    fi

    stop_pidfile "${pid_file}"

    log_info "Starting ${target} capture on ${ns}/${iface}..."

    # Use tcpdump with -U (packet-buffered) and -s 0 (full payload)
    nohup ip netns exec "${ns}" \
        "${TCPDUMP_BIN:-tcpdump}" -ni "${iface}" -s 0 -U \
        -w "${pcap_file}" "${CAPTURE_FILTER}" > "${log_file}" 2>&1 &

    printf '%s\n' "$!" > "${pid_file}"
    sleep 0.5

    if ! is_pidfile_running "${pid_file}"; then
        log_error "Capture failed to start on ${target}. Log output:"
        tail -n 20 "${log_file}" >&2 || true
        die "Failed to start capture on ${target}."
    fi

    printf 'LAST_PCAP_%s=%q\n' "$(tr '[:lower:]' '[:upper:]' <<< "${target}")" "${pcap_file}" >> "${STATE_DIR}/last_capture.env"
    printf 'LAST_PCAP=%q\n' "${pcap_file}" >> "${STATE_DIR}/last_capture.env"

    log_info "${target^} capture active: ${pcap_file} (PID: $(cat "${pid_file}"))"
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
    stop_pidfile "${STATE_DIR}/cap_wan.pid"
    stop_pidfile "${STATE_DIR}/cap_lan.pid"
    log_info "Captures stopped."
}

show_status() {
    load_config

    printf '============================================================\n'
    printf '                  PACKET CAPTURE STATUS                     \n'
    printf '============================================================\n'

    local target pid_file
    for target in wan lan; do
        pid_file="${STATE_DIR}/cap_${target}.pid"
        if is_pidfile_running "${pid_file}"; then
            printf '  %-6s Capture: RUNNING (PID %s)\n' "${target^^}" "$(cat "${pid_file}")"
        else
            printf '  %-6s Capture: STOPPED\n' "${target^^}"
        fi
    done

    if [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture.env"
        printf '\nLast Capture Files:\n'
        printf '  WAN: %s\n' "${LAST_PCAP_WAN:-<none>}"
        printf '  LAN: %s\n' "${LAST_PCAP_LAN:-<none>}"
    fi
    printf '============================================================\n'
}

main() {
    case "${1:-}" in
        start)  shift; start_capture "${1:-both}" ;;
        stop)   stop_capture ;;
        status) show_status ;;
        *)      usage; exit 2 ;;
    esac
}

main "$@"
