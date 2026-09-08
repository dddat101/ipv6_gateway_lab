#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - UPSTREAM WAN SERVER EMULATOR
# Controls radvd, Kea DHCPv4/v6, and DS-Lite AFTR in ns-wan (with dnsmasq fallback)
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

prepare_kea_runtime() {
    # 1. Unload AppArmor profiles if active on host (prevents logger_lockfile & pidfile EACCES)
    if command -v apparmor_parser >/dev/null 2>&1; then
        apparmor_parser -R /etc/apparmor.d/usr.sbin.kea-dhcp4 2>/dev/null || true
        apparmor_parser -R /etc/apparmor.d/usr.sbin.kea-dhcp6 2>/dev/null || true
    fi

    # 2. Ensure Kea runtime directories exist with full permissions
    install -d -m 0777 /run/kea /run/lock/kea "${STATE_DIR}/kea"
    chmod 0777 /run/kea /run/lock/kea "${STATE_DIR}/kea" 2>/dev/null || true
    rm -f /run/kea/logger_lockfile /var/run/kea/logger_lockfile /run/lock/kea/logger_lockfile 2>/dev/null || true
    rm -f /run/kea/*.pid /run/lock/kea/*.pid 2>/dev/null || true
}

stop_services() {
    require_root
    log_info "Stopping WAN server daemons in ${NS_WAN}..."

    stop_pidfile "${STATE_DIR}/radvd.pid"
    stop_pidfile "${STATE_DIR}/kea-dhcp4.pid"
    stop_pidfile "${STATE_DIR}/kea-dhcp6.pid"
    stop_pidfile "${STATE_DIR}/dnsmasq-dhcp4.pid"
    stop_pidfile "${STATE_DIR}/dnsmasq-dhcp6.pid"

    if ns_exists "${NS_WAN}"; then
        ip netns exec "${NS_WAN}" pkill -TERM radvd 2>/dev/null || true
        ip netns exec "${NS_WAN}" pkill -TERM kea-dhcp4 2>/dev/null || true
        ip netns exec "${NS_WAN}" pkill -TERM kea-dhcp6 2>/dev/null || true
        ip netns exec "${NS_WAN}" pkill -TERM dnsmasq 2>/dev/null || true
    fi
}

start_radvd() {
    local profile="$1"
    local src="${PROJECT_ROOT}/config/radvd/${profile}.conf.in"
    local dst="${STATE_DIR}/radvd-${profile}.conf"
    local pidfile="${STATE_DIR}/radvd.pid"

    require_command radvd
    render_template "${src}" "${dst}" "${NS_IF}"
    chmod 0644 "${dst}" 2>/dev/null || true

    # Ensure IPv6 forwarding is explicitly enabled on eth0 in ns-wan for radvd
    ip netns exec "${NS_WAN}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
    ip netns exec "${NS_WAN}" sysctl -q -w net.ipv6.conf.default.forwarding=1 2>/dev/null || true
    ip netns exec "${NS_WAN}" sysctl -q -w "net.ipv6.conf.${NS_IF}.forwarding=1" 2>/dev/null || true

    stop_pidfile "${pidfile}"
    ip netns exec "${NS_WAN}" radvd -C "${dst}" -p "${pidfile}" -m logfile -l "${LOG_DIR}/radvd.log"
    log_info "radvd started (${profile}) in ${NS_WAN} [PID: $(cat "${pidfile}" 2>/dev/null || echo '?')]"
}

start_dhcp4_dnsmasq() {
    local pidfile="${STATE_DIR}/dnsmasq-dhcp4.pid"
    local conffile="${STATE_DIR}/dnsmasq-dhcp4.conf"
    local leasefile="${STATE_DIR}/dnsmasq-dhcp4.leases"
    local logfile="${LOG_DIR}/dnsmasq-dhcp4.log"

    require_command dnsmasq
    stop_pidfile "${pidfile}"

    {
        printf 'port=0\n'
        printf 'no-resolv\n'
        printf 'no-hosts\n'
        printf 'bind-interfaces\n'
        printf 'interface=%s\n' "${NS_IF}"
        printf 'dhcp-range=%s,%s,255.255.255.0,%ss\n' "${WAN_IPV4_POOL_START}" "${WAN_IPV4_POOL_END}" "${DHCP_VALID_LIFETIME_SEC}"
        printf 'dhcp-option=option:router,%s\n' "${WAN_IPV4_ROUTER}"
        printf 'dhcp-option=option:dns-server,%s\n' "${WAN_IPV4_DNS}"
        printf 'dhcp-authoritative\n'
        printf 'dhcp-leasefile=%s\n' "${leasefile}"
        printf 'log-facility=%s\n' "${logfile}"
        printf 'log-dhcp\n'
    } > "${conffile}"

    touch "${leasefile}"
    chmod 0666 "${leasefile}" 2>/dev/null || true

    nohup ip netns exec "${NS_WAN}" dnsmasq --conf-file="${conffile}" --pid-file="${pidfile}" > "${logfile}" 2>&1 &
    sleep 0.5

    if ! is_pidfile_running "${pidfile}"; then
        log_error "dnsmasq (IPv4 DHCP) failed to start. Check ${logfile}"
        tail -n 20 "${logfile}" >&2 || true
        die "Failed to start IPv4 DHCP server."
    fi
    log_info "dnsmasq (IPv4 DHCP fallback) started in ${NS_WAN} [PID: $(cat "${pidfile}")]"
}

start_dhcp4() {
    prepare_kea_runtime

    local src="${PROJECT_ROOT}/config/kea/kea-dhcp4.conf.in"
    local dst="${STATE_DIR}/kea-dhcp4.conf"
    local pidfile="${STATE_DIR}/kea-dhcp4.pid"
    local logfile="${LOG_DIR}/kea-dhcp4.log"

    if command -v kea-dhcp4 >/dev/null 2>&1; then
        render_template "${src}" "${dst}" "${NS_IF}"
        stop_pidfile "${pidfile}"

        nohup ip netns exec "${NS_WAN}" \
            env KEA_PIDFILE_DIR="/run/kea" KEA_LOCKFILE_DIR="/run/lock/kea" \
            kea-dhcp4 -c "${dst}" > "${logfile}" 2>&1 &
        printf '%s\n' "$!" > "${pidfile}"
        sleep 0.5

        if is_pidfile_running "${pidfile}"; then
            log_info "kea-dhcp4 started in ${NS_WAN} [PID: $(cat "${pidfile}")]"
            return 0
        fi

        log_warn "kea-dhcp4 failed to start due to host environment/AppArmor. Log excerpt:"
        tail -n 10 "${logfile}" >&2 || true
    fi

    log_info "Activating robust dnsmasq IPv4 DHCP server fallback..."
    start_dhcp4_dnsmasq
}

start_dhcp6_dnsmasq() {
    local pidfile="${STATE_DIR}/dnsmasq-dhcp6.pid"
    local conffile="${STATE_DIR}/dnsmasq-dhcp6.conf"
    local leasefile="${STATE_DIR}/dnsmasq-dhcp6.leases"
    local logfile="${LOG_DIR}/dnsmasq-dhcp6.log"

    require_command dnsmasq
    stop_pidfile "${pidfile}"

    {
        printf 'port=0\n'
        printf 'no-resolv\n'
        printf 'no-hosts\n'
        printf 'bind-interfaces\n'
        printf 'interface=%s\n' "${NS_IF}"
        printf 'enable-ra\n'
        printf 'dhcp-range=2001:db8:10::1000,2001:db8:10::1fff,64,%ss\n' "${DHCP_VALID_LIFETIME_SEC}"
        printf 'dhcp-option=option6:dns-server,[%s]\n' "${WAN_IPV6_DNS}"
        printf 'dhcp-option=option6:64,%s\n' "${AFTR_NAME}"
        printf 'dhcp-authoritative\n'
        printf 'dhcp-leasefile=%s\n' "${leasefile}"
        printf 'log-facility=%s\n' "${logfile}"
        printf 'log-dhcp\n'
    } > "${conffile}"

    touch "${leasefile}"
    chmod 0666 "${leasefile}" 2>/dev/null || true

    nohup ip netns exec "${NS_WAN}" dnsmasq --conf-file="${conffile}" --pid-file="${pidfile}" > "${logfile}" 2>&1 &
    sleep 0.5

    if ! is_pidfile_running "${pidfile}"; then
        log_error "dnsmasq (IPv6 DHCP) failed to start. Check ${logfile}"
        tail -n 20 "${logfile}" >&2 || true
        die "Failed to start IPv6 DHCP server."
    fi
    log_info "dnsmasq (IPv6 DHCP fallback) started in ${NS_WAN} [PID: $(cat "${pidfile}")]"
}

start_dhcp6() {
    prepare_kea_runtime

    local src="${PROJECT_ROOT}/config/kea/kea-dhcp6.conf.in"
    local dst="${STATE_DIR}/kea-dhcp6.conf"
    local pidfile="${STATE_DIR}/kea-dhcp6.pid"
    local logfile="${LOG_DIR}/kea-dhcp6.log"

    if command -v kea-dhcp6 >/dev/null 2>&1; then
        render_template "${src}" "${dst}" "${NS_IF}"
        stop_pidfile "${pidfile}"

        nohup ip netns exec "${NS_WAN}" \
            env KEA_PIDFILE_DIR="/run/kea" KEA_LOCKFILE_DIR="/run/lock/kea" \
            kea-dhcp6 -c "${dst}" > "${logfile}" 2>&1 &
        printf '%s\n' "$!" > "${pidfile}"
        sleep 0.5

        if is_pidfile_running "${pidfile}"; then
            log_info "kea-dhcp6 started in ${NS_WAN} [PID: $(cat "${pidfile}")]"
            return 0
        fi

        log_warn "kea-dhcp6 failed to start due to host environment/AppArmor. Log excerpt:"
        tail -n 10 "${logfile}" >&2 || true
    fi

    log_info "Activating robust dnsmasq IPv6 DHCP server fallback..."
    start_dhcp6_dnsmasq
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
    for daemon in radvd kea-dhcp4 kea-dhcp6 dnsmasq-dhcp4 dnsmasq-dhcp6; do
        pidfile="${STATE_DIR}/${daemon}.pid"
        if is_pidfile_running "${pidfile}"; then
            printf '  %-18s -> RUNNING (PID %s)\n' "${daemon}" "$(cat "${pidfile}")"
        else
            printf '  %-18s -> STOPPED\n' "${daemon}"
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
