#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - LAN CLIENT IP MANAGEMENT
# Manages DHCPv4 (udhcpc Option 12/60), IPv6 SLAAC/DHCPv6, or Static IP in ns-lan1
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/client_dhcp.sh [request-v4 | request-v6 | static | release | status]

Commands:
  request-v4     Obtain IPv4 address from DUT via udhcpc (Option 12 Hostname & Option 60)
  request-v6     Trigger IPv6 configuration (SLAAC / DHCPv6 client)
  static         Assign fast deterministic static IPv4 & IPv6 test addresses
  release        Release all leases and flush IP addresses on client interface
  status         Show current LAN client IP, routes, and ping DUT gateway
USAGE
}

request_v4() {
    require_root
    load_config
    validate_namespace_ready "${NS_LAN}" "${NS_IF}"
    require_command udhcpc

    local pidfile="${STATE_DIR}/udhcpc-${NS_LAN}.pid"
    stop_pidfile "${pidfile}"

    log_info "Requesting IPv4 lease in ${NS_LAN} (Hostname: ${LAN_CLIENT_HOSTNAME}, Vendor: ${LAN_CLIENT_VENDOR})..."

    if ip netns exec "${NS_LAN}" udhcpc -i "${NS_IF}" -n -q -t 5 -T 2 \
        -s "${SCRIPT_LIB_DIR}/udhcpc.script" \
        -p "${pidfile}" \
        -x "hostname:${LAN_CLIENT_HOSTNAME}" -F "${LAN_CLIENT_HOSTNAME}" \
        -V "${LAN_CLIENT_VENDOR}"; then
        log_info "IPv4 lease obtained successfully: $(namespace_ip "${NS_LAN}" "${NS_IF}")"
    else
        log_warn "udhcpc failed to obtain IPv4 lease from DUT within timeout."
        return 1
    fi
}

request_v6() {
    require_root
    load_config
    validate_namespace_ready "${NS_LAN}" "${NS_IF}"

    log_info "Triggering IPv6 configuration in ${NS_LAN}..."

    # Ensure accept_ra is set
    ip netns exec "${NS_LAN}" sysctl -q -w "net.ipv6.conf.${NS_IF}.accept_ra=2" 2>/dev/null || true

    # Send Router Solicitation (multicast to all-routers ff02::2)
    ip netns exec "${NS_LAN}" ping -6 -c 2 -W 1 ff02::2%"${NS_IF}" >/dev/null 2>&1 || true

    # Try stateful DHCPv6 client if dhclient is installed
    if command -v dhclient >/dev/null 2>&1; then
        local pidfile="${STATE_DIR}/dhclient6-${NS_LAN}.pid"
        local leasefile="${STATE_DIR}/dhclient6-${NS_LAN}.leases"
        stop_pidfile "${pidfile}"
        ip netns exec "${NS_LAN}" dhclient -6 -1 -N -v \
            -pf "${pidfile}" -lf "${leasefile}" "${NS_IF}" >/dev/null 2>&1 || true
    fi

    sleep 1
    local v6_ip
    v6_ip="$(namespace_ipv6 "${NS_LAN}" "${NS_IF}")"
    if [[ -n "${v6_ip}" ]]; then
        log_info "IPv6 address obtained: ${v6_ip}"
    else
        log_warn "No global IPv6 address detected on ${NS_LAN}/${NS_IF} yet."
    fi
}

assign_static() {
    require_root
    load_config
    validate_namespace_ready "${NS_LAN}" "${NS_IF}"

    log_info "Assigning static test addresses in ${NS_LAN}..."

    ip -n "${NS_LAN}" addr flush dev "${NS_IF}" 2>/dev/null || true
    ip -n "${NS_LAN}" addr add "${LAN_CLIENT_IPV4}/24" dev "${NS_IF}"
    ip -n "${NS_LAN}" route replace default via "${DUT_LAN_IP}" dev "${NS_IF}" 2>/dev/null || true

    ip -n "${NS_LAN}" -6 addr add "${LAN_CLIENT_IPV6}/64" dev "${NS_IF}" 2>/dev/null || true
    ip -n "${NS_LAN}" -6 route replace default via "2001:db8:100:1::1" dev "${NS_IF}" 2>/dev/null || true

    log_info "Static configuration applied: IPv4=${LAN_CLIENT_IPV4}, IPv6=${LAN_CLIENT_IPV6}"
}

release_all() {
    require_root
    load_config

    log_info "Releasing client IP addresses in ${NS_LAN}..."
    stop_pidfile "${STATE_DIR}/udhcpc-${NS_LAN}.pid"
    stop_pidfile "${STATE_DIR}/dhclient6-${NS_LAN}.pid"

    if ns_exists "${NS_LAN}" && iface_exists_ns "${NS_LAN}" "${NS_IF}"; then
        ip -n "${NS_LAN}" addr flush dev "${NS_IF}" 2>/dev/null || true
        ip -n "${NS_LAN}" -6 addr flush dev "${NS_IF}" scope global 2>/dev/null || true
    fi
    log_info "Client addresses released."
}

show_status() {
    load_config

    printf '============================================================\n'
    printf '                  LAN CLIENT STATUS (%s)                    \n' "${NS_LAN}"
    printf '============================================================\n'

    if ! ns_exists "${NS_LAN}"; then
        printf 'Namespace %s does not exist. Run scripts/setup.sh first.\n' "${NS_LAN}"
        return 0
    fi

    printf '== Interface IP Addresses ==\n'
    ip -n "${NS_LAN}" -br addr show dev "${NS_IF}" 2>/dev/null || printf '<interface not found>\n'

    printf '\n== Default Routes ==\n'
    printf '  IPv4: %s\n' "$(ip -n "${NS_LAN}" route show default 2>/dev/null || echo '<none>')"
    printf '  IPv6: %s\n' "$(ip -n "${NS_LAN}" -6 route show default 2>/dev/null || echo '<none>')"

    printf '\n== Connectivity Smoke Check ==\n'
    if ip netns exec "${NS_LAN}" ping -c 1 -W 1 "${DUT_LAN_IP}" >/dev/null 2>&1; then
        printf '  Ping DUT LAN Gateway (%s): OK\n' "${DUT_LAN_IP}"
    else
        printf '  Ping DUT LAN Gateway (%s): UNREACHABLE\n' "${DUT_LAN_IP}"
    fi

    if ip netns exec "${NS_LAN}" ping -6 -c 1 -W 1 "${WAN_IPV6_DNS}" >/dev/null 2>&1; then
        printf '  Ping WAN Server IPv6 (%s): OK\n' "${WAN_IPV6_DNS}"
    else
        printf '  Ping WAN Server IPv6 (%s): UNREACHABLE\n' "${WAN_IPV6_DNS}"
    fi
    printf '============================================================\n'
}

main() {
    case "${1:-}" in
        request-v4) request_v4 ;;
        request-v6) request_v6 ;;
        static)     assign_static ;;
        release)    release_all ;;
        status)     show_status ;;
        *)          usage; exit 2 ;;
    esac
}

main "$@"
