#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - IPV6 GATEWAY CLEANUP SCRIPT
# Idempotent cleanup: stops daemons, deletes bridges/veths/netns, restores NICs
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

stop_all_daemons() {
    log_info "Stopping background processes and test daemons..."

    # 1. Stop recorded PID files
    local pidfile
    for pidfile in "${STATE_DIR}"/*.pid; do
        if [[ -f "${pidfile}" ]]; then
            stop_pidfile "${pidfile}"
        fi
    done

    # 2. Stop daemons in namespaces
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
}

cleanup_namespaces() {
    log_info "Cleaning network namespaces..."
    local ns
    for ns in "${NS_WAN}" "${NS_LAN}" "${NS_DUT}"; do
        if ns_exists "${ns}"; then
            ip netns del "${ns}" 2>/dev/null || true
        fi
    done
}

cleanup_bridges_and_links() {
    log_info "Cleaning bridges, virtual ethernet pairs, and restoring physical NICs..."

    # Delete host-side veth ends
    local veth
    for veth in v-wan-h v-lan1-h v-dut-wan-h v-dut-lan-h; do
        if ip link show dev "${veth}" >/dev/null 2>&1; then
            ip link del dev "${veth}" 2>/dev/null || true
        fi
    done

    # Cleanup physical adapters and bridges
    local wan_if="${WAN_IF:-${DUT_IF:-}}"
    local lan_if="${LAN_IF:-}"

    cleanup_bridge_and_nic "${WAN_BRIDGE}" "${wan_if}"
    cleanup_bridge_and_nic "${LAN_BRIDGE}" "${lan_if}"
}

cleanup_runtime_files() {
    rm -f "${STATE_DIR}/topology_state.env" 2>/dev/null || true
    rm -f "${STATE_DIR}"/*.pid 2>/dev/null || true
    rm -f "${STATE_DIR}"/*.leases 2>/dev/null || true
    rm -f "${STATE_DIR}"/*.conf 2>/dev/null || true
}

main() {
    require_root
    load_config
    require_command ip

    log_info "Starting lab cleanup..."

    stop_all_daemons
    cleanup_namespaces
    cleanup_bridges_and_links
    cleanup_runtime_files

    log_info "Cleanup complete. All test resources released."
}

main "$@"
