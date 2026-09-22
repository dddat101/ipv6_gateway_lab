#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - PRE-FLIGHT ENVIRONMENT DIAGNOSTICS
# Safe, non-destructive diagnostic script (can run without root/sudo)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
==================================================================
  IPv6 Gateway Test Lab - Pre-Flight Diagnostics
==================================================================

Description:
  Performs non-destructive pre-flight diagnostics of host physical
  test adapters, default route safety, network namespaces, bridges,
  and required toolchain binaries.

Usage:
  ./scripts/diagnose.sh [options]
  ./scripts/diagnose.sh -h | --help

Options:
  -h, --help    Show this help message and exit

Examples:
  ./scripts/diagnose.sh

Suggested Next Steps:
  - If tools are missing:   sudo ./scripts/install_deps.sh
  - Deploy virtual lab:     sudo ./scripts/setup.sh --virtual
  - Deploy physical lab:    sudo ./scripts/setup.sh --single
==================================================================
USAGE
}

check_item() {
    local label="$1" status="$2" note="${3:-}"
    if [[ "${status}" == "PASS" ]]; then
        printf '  \e[1;32m[PASS]\e[0m %-28s %s\n' "${label}" "${note}"
    elif [[ "${status}" == "WARN" ]]; then
        printf '  \e[1;33m[WARN]\e[0m %-28s %s\n' "${label}" "${note}"
    else
        printf '  \e[1;31m[FAIL]\e[0m %-28s %s\n' "${label}" "${note}"
    fi
}

check_interface() {
    local iface="$1"
    local desc="$2"

    if [[ -z "${iface}" ]]; then
        check_item "${desc}" "WARN" "<not configured in config.env>"
        return
    fi

    if ip link show dev "${iface}" >/dev/null 2>&1; then
        local state ip_addr
        state="$(ip -br link show dev "${iface}" 2>/dev/null | awk '{print $2}')"
        ip_addr="$(ip -4 -br addr show dev "${iface}" 2>/dev/null | awk '{print $3}' || echo '')"
        check_item "${desc} (${iface})" "PASS" "[${state}] ${ip_addr}"
    else
        check_item "${desc} (${iface})" "WARN" "Physical NIC not found / unplugged"
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
    print_header "IPV6 GATEWAY LAB PRE-FLIGHT DIAGNOSTICS"

    # 1. Host Network Safety
    print_section "HOST NETWORK SAFETY"
    local def_route default_if
    def_route="$(ip route show default 2>/dev/null || true)"
    default_if="$(awk '/dev/ {print $5}' <<< "${def_route}" | head -n1 || echo "")"

    if [[ -n "${default_if}" ]]; then
        check_item "Host Default Route" "PASS" "Interface: ${default_if}"
    else
        check_item "Host Default Route" "WARN" "No default route detected on host"
    fi

    local iface
    for iface in "${WAN_IF:-}" "${LAN_IF:-}"; do
        if [[ -n "${iface}" && "${iface}" == "${default_if}" ]]; then
            check_item "Safety check: ${iface}" "FAIL" "DANGER: Test NIC carries host default route!"
        elif [[ -n "${iface}" ]]; then
            check_item "Safety check: ${iface}" "PASS" "Isolated from host default route"
        fi
    done

    # 2. Target Physical Interfaces
    print_section "TARGET PHYSICAL INTERFACES"
    check_interface "${WAN_IF:-}" "WAN Interface"
    check_interface "${LAN_IF:-}" "LAN Interface"
    if [[ -n "${DUT_IF:-}" && "${DUT_IF}" != "${WAN_IF:-}" && "${DUT_IF}" != "${LAN_IF:-}" ]]; then
        check_interface "${DUT_IF}" "2-PC Test NIC"
    fi

    # 3. Kernel Capabilities
    print_section "KERNEL CAPABILITIES"
    if [[ -d /sys/class/net ]]; then
        check_item "Linux Network Stack" "PASS" "sysfs net available"
    fi
    if [[ -f /proc/sys/net/ipv4/ip_forward ]]; then
        check_item "Host IPv4 Forwarding" "PASS" "State: $(cat /proc/sys/net/ipv4/ip_forward)"
    fi
    if [[ -f /proc/sys/net/ipv6/conf/all/forwarding ]]; then
        check_item "Host IPv6 Forwarding" "PASS" "State: $(cat /proc/sys/net/ipv6/conf/all/forwarding)"
    fi

    # 4. Required CLI Tools
    print_section "REQUIRED CLI TOOLCHAIN"
    local tool
    for tool in ip bridge tcpdump tshark python3 radvd kea-dhcp4 kea-dhcp6 dnsmasq udhcpc dhclient iperf3; do
        if check_command "${tool}"; then
            check_item "Tool: ${tool}" "PASS" "$(command -v "${tool}")"
        else
            check_item "Tool: ${tool}" "WARN" "Missing (Install via sudo ./scripts/install_deps.sh)"
        fi
    done

    # 5. Runtime Directories
    print_section "RUNTIME DIRECTORIES"
    local dir
    for dir in "${CAPTURE_DIR}" "${LOG_DIR}" "${STATE_DIR}"; do
        if [[ -d "${dir}" ]]; then
            check_item "Directory: $(basename "${dir}")" "PASS" "${dir}"
        else
            check_item "Directory: $(basename "${dir}")" "WARN" "Will be created automatically"
        fi
    done

    printf '==================================================================\n'
    printf 'Diagnostics completed.\n'
}

main "$@"
