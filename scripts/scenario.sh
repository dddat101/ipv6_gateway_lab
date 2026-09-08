#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - MULTI-PHASE AUTOMATED SCENARIO RUNNER
# Executes Phase 0 (Capture) -> Phase 1 (WAN Setup) -> Phase 2 (LAN Setup) ->
# Phase 3 (Verification) -> Phase 4 (Analysis) -> Result Table
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    cat <<'USAGE'
Usage:
  sudo ./scripts/scenario.sh [scenario]

Supported Scenarios:
  dual-stack        (Default) Concurrent IPv4 NAT + IPv6 SLAAC/DHCPv6
  slaac             Stateless SLAAC + RDNSS
  stateful-v6       Stateful DHCPv6 (IA_NA + IA_PD)
  stateless-v6      SLAAC + Stateless DHCPv6 Information-Request
  ipv4-only         IPv4-only WAN (IPv6 disabled on internal LAN)
  ipv6-only-dslite  IPv6-only WAN + DS-Lite AFTR + Multicast DHCPv4
USAGE
}

main() {
    require_root
    load_config

    local scenario="${1:-${DEFAULT_SCENARIO:-dual-stack}}"

    printf '\n============================================================\n'
    printf '        Starting Automated Test Scenario: %s\n' "${scenario}"
    printf '============================================================\n'

    # Phase 0: Start background packet capture
    log_info "=== Phase 0: Starting Packet Capture ==="
    "${SCRIPT_DIR}/capture.sh" start both
    trap '"${SCRIPT_DIR}/capture.sh" stop >/dev/null 2>&1 || true' EXIT INT TERM

    # Phase 1: Activate Upstream WAN Server Scenario
    log_info "=== Phase 1: Activating Upstream WAN Emulator (${scenario}) ==="
    "${SCRIPT_DIR}/wan_server.sh" start "${scenario}"
    sleep 2

    # Phase 2: Client Address Acquisition & Network Configuration
    log_info "=== Phase 2: Client Address Configuration in ${NS_LAN} ==="
    local phase2_result="PASS"
    if ! "${SCRIPT_DIR}/client_dhcp.sh" static; then
        phase2_result="FAIL"
    fi
    sleep 1

    # Phase 3: Traffic & Connectivity Invariant Verification
    log_info "=== Phase 3: Traffic & Routing Verification ==="
    local phase3_ipv4="PASS"
    local phase3_ipv6="PASS"

    if [[ "${scenario}" != "ipv6-only-dslite" && "${scenario}" != "ipv6-only" ]]; then
        if ip netns exec "${NS_LAN}" ping -c "${PING_COUNT:-3}" -W "${PING_TIMEOUT_SEC:-2}" "${WAN_IPV4_ROUTER}" >/dev/null 2>&1; then
            log_info "LAN -> WAN IPv4 connectivity: OK"
        else
            log_warn "LAN -> WAN IPv4 connectivity check failed."
            phase3_ipv4="WARN"
        fi
    fi

    if [[ "${scenario}" != "ipv4-only" ]]; then
        # Install PD return route via DUT neighbor in ns-wan if detected
        local dut_ll
        dut_ll="$(ip netns exec "${NS_WAN}" ip -6 neigh show dev "${NS_IF}" 2>/dev/null | awk '/fe80/ {print $1; exit}')"
        if [[ -n "${dut_ll}" ]]; then
            ip -n "${NS_WAN}" -6 route replace "${PD_PREFIX}/${PD_PREFIX_LEN}" via "${dut_ll}" dev "${NS_IF}" 2>/dev/null || true
        fi

        if ip netns exec "${NS_LAN}" ping -6 -c "${PING_COUNT:-3}" -W "${PING_TIMEOUT_SEC:-2}" "${WAN_IPV6_DNS}" >/dev/null 2>&1; then
            log_info "LAN -> WAN IPv6 connectivity: OK"
        else
            log_warn "LAN -> WAN IPv6 connectivity check failed."
            phase3_ipv6="WARN"
        fi
    fi

    # Phase 4: Stop packet capture and analyze evidence
    log_info "=== Phase 4: Stopping Capture and Verifying Evidence ==="
    "${SCRIPT_DIR}/capture.sh" stop
    trap - EXIT INT TERM

    local phase4_result="PASS"
    if [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture.env"
        if ! "${SCRIPT_DIR}/verify_capture.sh" "${LAST_PCAP_WAN:-${LAST_PCAP:-}}"; then
            phase4_result="FAIL"
        fi
    else
        phase4_result="FAIL"
    fi

    # Phase 5: Output Summary Table
    printf '\n============================================================\n'
    printf '                  SCENARIO RESULTS SUMMARY                  \n'
    printf '============================================================\n'
    printf '  Target Scenario:         %-24s\n' "${scenario}"
    printf '  Phase 1 (WAN Setup):     PASS\n'
    printf '  Phase 2 (LAN Config):    %s\n' "${phase2_result}"
    printf '  Phase 3 (IPv4 Traffic):  %s\n' "${phase3_ipv4}"
    printf '  Phase 3 (IPv6 Traffic):  %s\n' "${phase3_ipv6}"
    printf '  Phase 4 (Evidence Check):%s\n' "${phase4_result}"
    printf '============================================================\n'
}

main "$@"
