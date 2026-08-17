#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - UPSTREAM WAN SERVER EMULATOR
# Controls radvd, Kea DHCPv4, Kea DHCPv6, and DS-Lite AFTR in ns-wan
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/wan_server.sh start [scenario]
  sudo ./scripts/wan_server.sh stop
  ./scripts/wan_server.sh status

Supported Scenarios:
  dual-stack        IPv4 DHCP + IPv6 Stateful DHCPv6 + PD + SLAAC (Default)
  slaac             Stateless SLAAC + RDNSS (RFC 8106)
  stateful-v6       Stateful DHCPv6 (IA_NA + IA_PD) with M=1, O=1
  stateless-v6      SLAAC + Stateless DHCPv6 Information-Request (M=0, O=1)
  ipv4-only         IPv4-only WAN (IPv6 disabled on internal LAN)
  ipv6-only-dslite  IPv6-only WAN + DS-Lite AFTR + Multicast DHCPv4
USAGE
}

stop_services() {
    require_root
    log_info "Stopping WAN server daemons in ${NS_WAN}..."

    stop_pidfile "${STATE_DIR}/radvd.pid"
    stop_pidfile "${STATE_DIR}/kea-dhcp4.pid"
    stop_pidfile "${STATE_DIR}/kea-dhcp6.pid"

    if ns_exists "${NS_WAN}"; then
        ip netns exec "${NS_WAN}" pkill -TERM radvd 2>/dev/null || true
        ip netns exec "${NS_WAN}" pkill -TERM kea-dhcp4 2>/dev/null || true
        ip netns exec "${NS_WAN}" pkill -TERM kea-dhcp6 2>/dev/null || true
    fi
}

start_radvd() {
    local profile="$1"
    local src="${PROJECT_ROOT}/config/radvd/${profile}.conf.in"
    local dst="${STATE_DIR}/radvd-${profile}.conf"
    local pidfile="${STATE_DIR}/radvd.pid"

    require_command radvd
    render_template "${src}" "${dst}" "${NS_IF}"

    stop_pidfile "${pidfile}"
    ip netns exec "${NS_WAN}" radvd -C "${dst}" -p "${pidfile}" -m logfile -l "${LOG_DIR}/radvd.log"
    log_info "radvd started (${profile}) in ${NS_WAN} [PID: $(cat "${pidfile}" 2>/dev/null || echo '?')]"
}

start_dhcp4() {
    local src="${PROJECT_ROOT}/config/kea/kea-dhcp4.conf.in"
    local dst="${STATE_DIR}/kea-dhcp4.conf"
    local pidfile="${STATE_DIR}/kea-dhcp4.pid"
    local logfile="${LOG_DIR}/kea-dhcp4.log"

    require_command kea-dhcp4
    render_template "${src}" "${dst}" "${NS_IF}"

    stop_pidfile "${pidfile}"
    nohup ip netns exec "${NS_WAN}" kea-dhcp4 -c "${dst}" > "${logfile}" 2>&1 &
    printf '%s\n' "$!" > "${pidfile}"
    sleep 0.5

    if ! is_pidfile_running "${pidfile}"; then
        log_error "kea-dhcp4 failed to start. Check ${logfile}"
        tail -n 20 "${logfile}" >&2 || true
        die "kea-dhcp4 failed."
    fi
    log_info "kea-dhcp4 started in ${NS_WAN} [PID: $(cat "${pidfile}")]"
}

start_dhcp6() {
    local src="${PROJECT_ROOT}/config/kea/kea-dhcp6.conf.in"
    local dst="${STATE_DIR}/kea-dhcp6.conf"
    local pidfile="${STATE_DIR}/kea-dhcp6.pid"
    local logfile="${LOG_DIR}/kea-dhcp6.log"

    require_command kea-dhcp6
    render_template "${src}" "${dst}" "${NS_IF}"

    stop_pidfile "${pidfile}"
    nohup ip netns exec "${NS_WAN}" kea-dhcp6 -c "${dst}" > "${logfile}" 2>&1 &
    printf '%s\n' "$!" > "${pidfile}"
    sleep 0.5

    if ! is_pidfile_running "${pidfile}"; then
        log_error "kea-dhcp6 failed to start. Check ${logfile}"
        tail -n 20 "${logfile}" >&2 || true
        die "kea-dhcp6 failed."
    fi
    log_info "kea-dhcp6 started in ${NS_WAN} [PID: $(cat "${pidfile}")]"
}

setup_aftr_endpoint() {
    if ns_exists "${NS_WAN}"; then
        log_info "Configuring DS-Lite AFTR endpoint (${AFTR_IPV6}) in ${NS_WAN}..."
        ip -n "${NS_WAN}" -6 addr replace "${AFTR_IPV6}/128" dev "${NS_IF}" 2>/dev/null || true
    fi
}

start_scenario() {
    local scenario="${1:-${DEFAULT_SCENARIO:-dual-stack}}"
    require_root
    load_config

    if ! ns_exists "${NS_WAN}"; then
        die "Namespace ${NS_WAN} not found. Run ./scripts/setup.sh first."
    fi

    stop_services

    log_info "Activating WAN scenario: ${scenario}"

    case "${scenario}" in
        ipv4-only)
            start_dhcp4
            ;;
        slaac)
            start_radvd "slaac"
            ;;
        stateful-v6)
            start_radvd "stateful"
            start_dhcp6
            ;;
        stateless-v6)
            start_radvd "stateless"
            start_dhcp6
            ;;
        dual-stack)
            start_radvd "stateful"
            start_dhcp4
            start_dhcp6
            ;;
        ipv6-only-dslite|ipv6-only)
            start_radvd "stateful"
            start_dhcp6
            setup_aftr_endpoint
            # In IPv6-only WAN, run DHCPv4 server to supply IPv4 address for Multicast / IPTV!
            start_dhcp4
            ;;
        *)
            die "Unknown scenario: ${scenario}"
            ;;
    esac

    printf 'ACTIVE_SCENARIO=%q\n' "${scenario}" > "${STATE_DIR}/active_scenario.env"
    log_info "WAN Server scenario active: ${scenario}"
}

show_status() {
    load_config

    printf '============================================================\n'
    printf '                  WAN SERVER DAEMONS STATUS                 \n'
    printf '============================================================\n'

    local daemon pidfile
    for daemon in radvd kea-dhcp4 kea-dhcp6; do
        pidfile="${STATE_DIR}/${daemon}.pid"
        if is_pidfile_running "${pidfile}"; then
            printf '  %-12s -> RUNNING (PID %s)\n' "${daemon}" "$(cat "${pidfile}")"
        else
            printf '  %-12s -> STOPPED\n' "${daemon}"
        fi
    done

    if [[ -f "${STATE_DIR}/active_scenario.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/active_scenario.env"
        printf '\nActive Scenario: %s\n' "${ACTIVE_SCENARIO:-<unknown>}"
    fi
    printf '============================================================\n'
}

main() {
    case "${1:-}" in
        start)  shift; start_scenario "${1:-}" ;;
        stop)   stop_services ;;
        status) show_status ;;
        *)      usage; exit 2 ;;
    esac
}

main "$@"
