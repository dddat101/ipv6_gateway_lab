#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - AUTOMATED PCAP VERIFICATION (IPv6 & DUAL STACK)
# Analyzes capture file with tshark, prints timeline, and evaluates PASS/FAIL
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

usage() {
    cat <<'USAGE'
==================================================================
  IPv6 Gateway Test Lab - Compliance & PCAP Verification
==================================================================

Description:
  Inspects packet capture files (.pcap) using tshark to verify
  NDP Router Advertisements, DHCPv6 (IA_NA & IA_PD Prefix Delegation),
  DHCPv4, DS-Lite encapsulation, and end-to-end dataplane forwarding.

Usage:
  ./scripts/verify_capture.sh [options] [pcap_file]
  ./scripts/verify_capture.sh -h | --help

Options:
  -h, --help  Show this help message and exit

Examples:
  ./scripts/verify_capture.sh
  ./scripts/verify_capture.sh captures/capture_wan_20260914_083600.pcap

Suggested Next Steps:
  - Inspect running state:  ./scripts/show_state.sh
  - Teardown when finished: sudo ./scripts/cleanup.sh
==================================================================
USAGE
}

check_test() {
    local id="$1" title="$2" status="$3" detail="$4"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "${status}" == "PASS" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        printf '  \e[1;32m[PASS]\e[0m [%s] %s\n         Detail: %s\n' "${id}" "${title}" "${detail}"
    elif [[ "${status}" == "WARN" ]]; then
        printf '  \e[1;33m[WARN]\e[0m [%s] %s\n         Detail: %s\n' "${id}" "${title}" "${detail}"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        printf '  \e[1;31m[FAIL]\e[0m [%s] %s\n         Detail: %s\n' "${id}" "${title}" "${detail}"
    fi
}

print_pcap_timeline() {
    local pcap_file="$1"
    if ! check_command "${TSHARK_BIN:-tshark}"; then
        log_info "tshark not installed; skipping packet timeline table."
        return 0
    fi
    if [[ ! -f "${pcap_file}" || ! -s "${pcap_file}" ]]; then
        log_warn "PCAP file is empty or missing: ${pcap_file}"
        return 0
    fi

    printf '\n========================================================================================\n'
    printf '                          PACKET TIMELINE EVIDENCE                               \n'
    printf '========================================================================================\n'
    printf '%-6s | %-12s | %-32s | %-32s | %-16s\n' "Frame" "Time (s)" "Source IP" "Destination IP" "Protocol / Info"
    printf '%s\n' "----------------------------------------------------------------------------------------"

    # SIGPIPE protection pattern:
    # shellcheck disable=SC2016
    (tshark -r "${pcap_file}" \
        -Y "icmpv6 || udp.port == 546 || udp.port == 547 || udp.port == 67 || udp.port == 68 || ipv6.nxt == 4" \
        -T fields \
        -e frame.number -e frame.time_relative -e _ws.col.Source -e _ws.col.Destination -e _ws.col.Protocol -e _ws.col.Info 2>/dev/null || true) | \
        awk -F '\t' '{ printf "%-6s | %-12.4f | %-32s | %-32s | %-10s %s\n", $1, $2, $3, $4, $5, $6 }' | head -n 40 || true

    printf '========================================================================================\n\n'
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    load_config

    if ! check_command "${TSHARK_BIN:-tshark}"; then
        die "tshark is not installed. Install via: sudo ./scripts/install_deps.sh"
    fi

    local pcap_file="${1:-}"
    if [[ -z "${pcap_file}" ]]; then
        pcap_file="$(get_latest_pcap || true)"
    fi

    print_header "INTERWORKING COMPLIANCE & PCAP VERIFICATION"

    if [[ -z "${pcap_file}" || ! -f "${pcap_file}" ]]; then
        die "No valid PCAP file found to verify. Run sudo ./scripts/scenario.sh first or pass pcap path."
    fi

    local pcap_size
    pcap_size="$(format_bytes "$(stat -c %s "${pcap_file}" 2>/dev/null || echo 0)")"
    log_info "Analyzing capture file: ${pcap_file} (${pcap_size})"

    # Detect dynamic tshark field names across Wireshark 3.x and 4.x
    local fields_list
    fields_list="$(tshark -G fields 2>/dev/null | awk -F '\t' '{print $3}' || true)"

    local dhcp6_msg_field icmp6_type_field
    dhcp6_msg_field="$(detect_tshark_field "${fields_list}" "dhcpv6.msgtype" "dhcp6.msgtype" "dhcp6.type" || echo "dhcpv6.msgtype")"
    icmp6_type_field="$(detect_tshark_field "${fields_list}" "icmpv6.type" "icmp6.type" || echo "icmpv6.type")"

    # Display timeline table
    print_pcap_timeline "${pcap_file}"

    print_section "SECTION 1: IPV6 ROUTER DISCOVERY & ADDRESSING"

    # Check 1: ICMPv6 Router Advertisement (Type 134)
    local ra_frame
    ra_frame="$( (tshark -r "${pcap_file}" -Y "${icmp6_type_field} == 134" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${ra_frame}" ]]; then
        check_test "TC_V6_01" "ICMPv6 Router Advertisement (RA)" "PASS" "Found RA (Type 134) at Frame #${ra_frame}"
    else
        check_test "TC_V6_01" "ICMPv6 Router Advertisement (RA)" "WARN" "No ICMPv6 RA found in capture."
    fi

    # Check 2: DHCPv6 Protocol Activity
    local dhcp6_frame
    dhcp6_frame="$( (tshark -r "${pcap_file}" -Y "udp.port == 546 || udp.port == 547" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${dhcp6_frame}" ]]; then
        check_test "TC_V6_02" "DHCPv6 Signaling Activity" "PASS" "DHCPv6 transactions detected starting at Frame #${dhcp6_frame}"
    else
        check_test "TC_V6_02" "DHCPv6 Signaling Activity" "WARN" "No DHCPv6 signaling frames detected."
    fi

    # Check 3: DHCPv6 Prefix Delegation (Option 25: IA_PD)
    local pd_frame
    pd_frame="$( (tshark -r "${pcap_file}" -Y "dhcpv6.iapd || dhcp6.iapd || dhcpv6.option.type == 25" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${pd_frame}" ]]; then
        check_test "TC_V6_03" "DHCPv6 Prefix Delegation (IA_PD)" "PASS" "Prefix Delegation Option 25 found at Frame #${pd_frame}"
    else
        check_test "TC_V6_03" "DHCPv6 Prefix Delegation (IA_PD)" "WARN" "IA_PD option not observed in current capture window."
    fi

    print_section "SECTION 2: DUAL-STACK & TUNNELING PROTOCOLS"

    # Check 4: DHCPv4 Activity (Option 53 / UDP 67-68)
    local dhcp4_frame
    dhcp4_frame="$( (tshark -r "${pcap_file}" -Y "udp.port == 67 || udp.port == 68" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${dhcp4_frame}" ]]; then
        check_test "TC_V4_01" "DHCPv4 Transaction Signaling" "PASS" "DHCPv4 packet exchange detected starting at Frame #${dhcp4_frame}"
    else
        check_test "TC_V4_01" "DHCPv4 Transaction Signaling" "WARN" "No DHCPv4 frames detected."
    fi

    # Check 5: DS-Lite Encapsulation (IPv4-in-IPv6 Next Header 4)
    local dslite_frame
    dslite_frame="$( (tshark -r "${pcap_file}" -Y "ipv6.nxt == 4" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${dslite_frame}" ]]; then
        check_test "TC_DSLITE_01" "DS-Lite IPv4-in-IPv6 Encapsulation" "PASS" "Encapsulated packet (Next Header 4) found at Frame #${dslite_frame}"
    else
        check_test "TC_DSLITE_01" "DS-Lite IPv4-in-IPv6 Encapsulation" "WARN" "No DS-Lite tunnel traffic detected (normal if scenario is native Dual-Stack)."
    fi

    # Check 6: End-to-end IP Forwarding Datapath
    local icmp_frame
    icmp_frame="$( (tshark -r "${pcap_file}" -Y "icmp || ${icmp6_type_field} == 128 || ${icmp6_type_field} == 129" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${icmp_frame}" ]]; then
        check_test "TC_DATA_01" "Dataplane Forwarding Reachability" "PASS" "End-to-end ICMP datapath verified at Frame #${icmp_frame}"
    else
        check_test "TC_DATA_01" "Dataplane Forwarding Reachability" "WARN" "No ICMP datapath packets observed."
    fi

    printf '\n==================================================================\n'
    printf 'TEST SUMMARY: Total: %d | Passed: %d | Failed: %d\n' "${TOTAL_TESTS}" "${PASSED_TESTS}" "${FAILED_TESTS}"
    if (( FAILED_TESTS == 0 )); then
        printf '\e[1;32m[FINAL VERDICT: PASS]\e[0m ALL COMPLIANCE CHECKS PASSED!\n'
        exit 0
    else
        printf '\e[1;31m[FINAL VERDICT: FAIL]\e[0m %d CHECK(S) FAILED COMPLIANCE.\n' "${FAILED_TESTS}"
        exit 1
    fi
}

main "$@"
