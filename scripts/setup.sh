#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - IPV6 GATEWAY TOPOLOGY SETUP
# Supports Single-PC (Dual-NIC), Distributed 2-PC, and Virtual (No-DUT) Simulation
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SETUP_ACTIVE=0
IS_VIRTUAL=0

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/setup.sh [OPTIONS]

Options:
  --single, -s     Setup Single-PC topology with WAN & LAN bridges (Default)
  --wan            Setup PC1 as WAN Gateway / Server Emulator
  --lan            Setup PC2 as LAN Client Fan-out
  --virtual, -v    Setup 100% Virtual / Simulated DUT topology (No hardware needed)
  -h, --help       Show this help message
USAGE
}

rollback_setup() {
    local exit_code="$1"
    local line_number="$2"
    if (( SETUP_ACTIVE == 0 )); then return; fi

    trap - ERR
    log_error "Setup failed near line ${line_number}; rolling back topology..."
    "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1 || true
    log_error "Rollback complete. Original error code: ${exit_code}"
    exit "${exit_code}"
}

setup_virtual_dut() {
    log_info "Creating simulated DUT router (${NS_DUT}) for offline/virtual testing..."
    ns_create "${NS_DUT}"

    # Veth to WAN bridge
    ip link del dev v-dut-wan-h 2>/dev/null || true
    ip link add v-dut-wan-h type veth peer name dut-wan netns "${NS_DUT}"
    ip link set dev v-dut-wan-h master "${WAN_BRIDGE}"
    ip link set dev v-dut-wan-h up
    ip -n "${NS_DUT}" link set dev dut-wan up
    ip -n "${NS_DUT}" addr add 10.10.0.50/24 dev dut-wan 2>/dev/null || true
    ip -n "${NS_DUT}" -6 addr add 2001:db8:10::50/64 dev dut-wan 2>/dev/null || true

    # Veth to LAN bridge
    ip link del dev v-dut-lan-h 2>/dev/null || true
    ip link add v-dut-lan-h type veth peer name dut-lan netns "${NS_DUT}"
    ip link set dev v-dut-lan-h master "${LAN_BRIDGE}"
    ip link set dev v-dut-lan-h up
    ip -n "${NS_DUT}" link set dev dut-lan up
    ip -n "${NS_DUT}" addr add "${DUT_LAN_IP}/24" dev dut-lan 2>/dev/null || true
    ip -n "${NS_DUT}" -6 addr add 2001:db8:100:1::1/64 dev dut-lan 2>/dev/null || true

    # Enable routing and forwarding inside simulated DUT
    ip netns exec "${NS_DUT}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
    ip netns exec "${NS_DUT}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
    ip netns exec "${NS_DUT}" sysctl -q -w net.ipv6.conf.dut-wan.accept_ra=2 2>/dev/null || true

    # Configure default routes inside simulated DUT pointing to ns-wan
    ip -n "${NS_DUT}" route replace default via "${WAN_IPV4_ROUTER}" dev dut-wan 2>/dev/null || true
    ip -n "${NS_DUT}" -6 route replace default via "${WAN_IPV6_DNS}" dev dut-wan 2>/dev/null || true

    # Configure simulated IPv4 NAT for LAN subnet
    ip netns exec "${NS_DUT}" iptables -t nat -A POSTROUTING -o dut-wan -j MASQUERADE 2>/dev/null || true

    log_info "Simulated DUT (${NS_DUT}) configured: WAN=10.10.0.50 & 2001:db8:10::50, LAN=${DUT_LAN_IP} & 2001:db8:100:1::1"
}

main() {
    require_root
    load_config
    require_command ip

    local role="${LAB_ROLE:-single}"

    while (( $# > 0 )); do
        case "$1" in
            --single|-s)   role="single"; shift ;;
            --wan)         role="wan"; shift ;;
            --lan)         role="lan"; shift ;;
            --virtual|-v|--no-dut) IS_VIRTUAL=1; role="single"; shift ;;
            -h|--help)     usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage; exit 2 ;;
        esac
    done

    # If TOPOLOGY_MODE was virtual in config.env
    if [[ "${TOPOLOGY_MODE:-}" == "virtual" ]]; then
        IS_VIRTUAL=1
    fi

    local mode_desc="PHYSICAL"
    if (( IS_VIRTUAL == 1 )); then
        mode_desc="VIRTUAL"
    fi

    log_info "Starting topology setup (Role: ${role}, Mode: ${mode_desc})..."

    # 1. Activate auto-rollback trap
    SETUP_ACTIVE=1
    trap 'rollback_setup $? ${LINENO}' ERR

    # 2. Build topology according to role
    if (( IS_VIRTUAL == 1 )); then
        bridge_create "${WAN_BRIDGE}"
        bridge_create "${LAN_BRIDGE}"

        create_veth_to_ns "${NS_WAN}" "v-wan-h" "${NS_IF}" "${WAN_BRIDGE}" \
            "${WAN_IPV4_CIDR}" "" "${WAN_IPV6_CIDR}" ""

        create_veth_to_ns "${NS_LAN}" "v-lan1-h" "${NS_IF}" "${LAN_BRIDGE}" \
            "${LAN_CLIENT_IPV4}/24" "${DUT_LAN_IP}" "${LAN_CLIENT_IPV6}/64" "2001:db8:100:1::1"

        ip netns exec "${NS_WAN}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
        ip netns exec "${NS_WAN}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true

        # Add return route in ns-wan for LAN prefix in virtual mode
        ip -n "${NS_WAN}" route replace "${LAN_IPV4_SUBNET}" via 10.10.0.50 dev "${NS_IF}" 2>/dev/null || true
        ip -n "${NS_WAN}" -6 route replace "${PD_PREFIX}/${PD_PREFIX_LEN}" via 2001:db8:10::50 dev "${NS_IF}" 2>/dev/null || true

        setup_virtual_dut

    elif [[ "${role}" == "single" ]]; then
        local wan_if="${WAN_IF:-${DUT_IF}}"
        local lan_if="${LAN_IF}"

        assert_safe_test_if "${wan_if}"
        assert_safe_test_if "${lan_if}"

        bridge_create "${WAN_BRIDGE}"
        attach_physical_to_bridge "${wan_if}" "${WAN_BRIDGE}"

        bridge_create "${LAN_BRIDGE}"
        attach_physical_to_bridge "${lan_if}" "${LAN_BRIDGE}"

        create_veth_to_ns "${NS_WAN}" "v-wan-h" "${NS_IF}" "${WAN_BRIDGE}" \
            "${WAN_IPV4_CIDR}" "" "${WAN_IPV6_CIDR}" ""

        create_veth_to_ns "${NS_LAN}" "v-lan1-h" "${NS_IF}" "${LAN_BRIDGE}" \
            "" "" "" ""

        ip netns exec "${NS_WAN}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
        ip netns exec "${NS_WAN}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true

        # Enable RA acceptance on LAN client interface
        ip netns exec "${NS_LAN}" sysctl -q -w "net.ipv6.conf.${NS_IF}.accept_ra=2" 2>/dev/null || true

    elif [[ "${role}" == "wan" ]]; then
        local wan_if="${WAN_IF:-${DUT_IF}}"
        assert_safe_test_if "${wan_if}"

        bridge_create "${WAN_BRIDGE}"
        attach_physical_to_bridge "${wan_if}" "${WAN_BRIDGE}"

        create_veth_to_ns "${NS_WAN}" "v-wan-h" "${NS_IF}" "${WAN_BRIDGE}" \
            "${WAN_IPV4_CIDR}" "" "${WAN_IPV6_CIDR}" ""

        ip netns exec "${NS_WAN}" sysctl -q -w net.ipv4.ip_forward=1 2>/dev/null || true
        ip netns exec "${NS_WAN}" sysctl -q -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true

    elif [[ "${role}" == "lan" ]]; then
        local lan_if="${LAN_IF:-${DUT_IF}}"
        assert_safe_test_if "${lan_if}"

        bridge_create "${LAN_BRIDGE}"
        attach_physical_to_bridge "${lan_if}" "${LAN_BRIDGE}"

        create_veth_to_ns "${NS_LAN}" "v-lan1-h" "${NS_IF}" "${LAN_BRIDGE}" \
            "" "" "" ""

        ip netns exec "${NS_LAN}" sysctl -q -w "net.ipv6.conf.${NS_IF}.accept_ra=2" 2>/dev/null || true
    fi

    # 3. Save runtime topology state
    cat >"${STATE_DIR}/topology_state.env" <<TOPO_EOF
LAB_ROLE='${role}'
IS_VIRTUAL='${IS_VIRTUAL}'
WAN_BRIDGE='${WAN_BRIDGE}'
LAN_BRIDGE='${LAN_BRIDGE}'
NS_WAN='${NS_WAN}'
NS_LAN='${NS_LAN}'
NS_DUT='${NS_DUT}'
SETUP_TIMESTAMP='$(date -Iseconds)'
TOPO_EOF

    # 4. Disable rollback trap on success
    SETUP_ACTIVE=0
    trap - ERR
    log_info "Setup completed successfully (Role: ${role}, Virtual: ${IS_VIRTUAL})."
}

main "$@"
