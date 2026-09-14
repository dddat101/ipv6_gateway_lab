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
Description:
  Performs non-destructive pre-flight diagnostics of host physical test adapters,
  default route safety, namespaces, bridges, and required CLI tools.

Usage:
  ./scripts/diagnose.sh [options]

Options:
  -h, --help    Show this help message

Examples:
  ./scripts/diagnose.sh

Suggested Next Steps:
  - If tools are missing:   sudo ./scripts/install_deps.sh
  - Deploy topology:       sudo ./scripts/setup.sh --virtual
USAGE
}

check_command() {
    local cmd="$1"
    if command -v "${cmd}" >/dev/null 2>&1; then
        printf '  %-16s -> OK (%s)\n' "${cmd}" "$(command -v "${cmd}")"
    else
        printf '  %-16s -> MISSING (Install via sudo ./scripts/install_deps.sh)\n' "${cmd}"
    fi
}

check_interface() {
    local iface="$1"
    local desc="$2"

    if [[ -z "${iface}" ]]; then
        printf '  %-16s -> NOT CONFIGURED (%s)\n' "${desc}" "<empty>"
        return
    fi

    if ip link show dev "${iface}" >/dev/null 2>&1; then
        local state
        state="$(ip -br link show dev "${iface}" 2>/dev/null | awk '{print $2}')"
        local ip_addr
        ip_addr="$(ip -4 -br addr show dev "${iface}" 2>/dev/null | awk '{print $3}' || echo '')"
        printf '  %-16s -> FOUND: %s [%s] %s\n' "${desc}" "${iface}" "${state}" "${ip_addr}"
    else
        printf '  %-16s -> NOT FOUND: %s\n' "${desc}" "${iface}"
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

    printf '============================================================\n'
    printf '        IPv6 Gateway Lab Pre-Flight Diagnostics            \n'
    printf '============================================================\n'

    printf '\n== Host Default Route Safety ==\n'
    local def_route
    def_route="$(ip route show default 2>/dev/null || true)"
    if [[ -n "${def_route}" ]]; then
        printf '  Default Route: %s\n' "${def_route}"
    else
        printf '  Default Route: <none detected>\n'
    fi

    printf '\n== Target Physical Interfaces ==\n'
    check_interface "${WAN_IF:-}" "WAN Interface"
    check_interface "${LAN_IF:-}" "LAN Interface"
    if [[ -n "${DUT_IF:-}" && "${DUT_IF}" != "${WAN_IF:-}" && "${DUT_IF}" != "${LAN_IF:-}" ]]; then
        check_interface "${DUT_IF}" "2-PC Test NIC"
    fi

    printf '\n== Existing Network Namespaces ==\n'
    local ns_list
    ns_list="$(ip netns list 2>/dev/null || true)"
    if [[ -n "${ns_list}" ]]; then
        printf '%s\n' "${ns_list}"
    else
        printf '  <none>\n'
    fi

    printf '\n== Linux Bridges ==\n'
    local br_list
    br_list="$(ip -br link show type bridge 2>/dev/null || true)"
    if [[ -n "${br_list}" ]]; then
        printf '%s\n' "${br_list}"
    else
        printf '  <none>\n'
    fi

    printf '\n== Required CLI Tools ==\n'
    local tool
    for tool in ip bridge tcpdump tshark python3 radvd kea-dhcp4 kea-dhcp6 dnsmasq udhcpc dhclient iperf3; do
        check_command "${tool}"
    done

    printf '\n============================================================\n'
    printf 'Diagnostics completed.\n'
}

main "$@"
