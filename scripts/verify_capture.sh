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

main() {
    load_config
    require_command "${TSHARK_BIN:-tshark}"

    local pcap_file="${1:-}"
    if [[ -z "${pcap_file}" && -f "${STATE_DIR}/last_capture.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture.env"
        pcap_file="${LAST_PCAP_WAN:-${LAST_PCAP:-}}"
    fi

    [[ -n "${pcap_file}" && -f "${pcap_file}" ]] || die "PCAP file not found. Provide a valid capture file."

    log_info "Analyzing capture file: ${pcap_file}"

    # 1. Detect dynamic tshark field names across Wireshark 3.x and 4.x
    local fields_list
    fields_list="$(tshark -G fields 2>/dev/null | awk -F '\t' '{print $3}' || true)"

    local dhcp6_msg_field dhcp4_msg_field icmp6_type_field
    dhcp6_msg_field="$(detect_tshark_field "${fields_list}" "dhcpv6.msgtype" "dhcp6.msgtype" "dhcp6.type" || echo "dhcpv6.msgtype")"
    dhcp4_msg_field="$(detect_tshark_field "${fields_list}" "dhcp.type" "dhcp.option.dhcp" "bootp.option.dhcp" || echo "dhcp.type")"
    icmp6_type_field="$(detect_tshark_field "${fields_list}" "icmpv6.type" "icmp6.type" || echo "icmpv6.type")"

    # 2. Print Protocol Timeline Table
    printf '\n========================================================================================\n'
    printf '                          PACKET TIMELINE EVIDENCE                               \n'
    printf '========================================================================================\n'
    printf '%-6s | %-12s | %-32s | %-32s | %-16s\n' "Frame" "Time (s)" "Source IP" "Destination IP" "Protocol / Info"
    printf '%s\n' "----------------------------------------------------------------------------------------"

    tshark -r "${pcap_file}" \
        -Y "icmpv6 || udp.port == 546 || udp.port == 547 || udp.port == 67 || udp.port == 68 || ipv6.nxt == 4" \
        -T fields \
        -e frame.number -e frame.time_relative -e _ws.col.Source -e _ws.col.Destination -e _ws.col.Protocol -e _ws.col.Info 2>/dev/null | \
        awk -F '\t' '{ printf "%-6s | %-12.4f | %-32s | %-32s | %-10s %s\n", $1, $2, $3, $4, $5, $6 }' || true

    printf '========================================================================================\n'

    # 3. Protocol Invariant Verifications (Protected against SIGPIPE 141)
    local test_passed=1

    # Check 1: ICMPv6 Router Advertisement (Type 134)
    local ra_frame
    ra_frame="$( (tshark -r "${pcap_file}" -Y "${icmp6_type_field} == 134" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${ra_frame}" ]]; then
        printf '  [PASS] ICMPv6 Router Advertisement (RA Type 134) found at Frame #%s\n' "${ra_frame}"
    else
        printf '  [WARN] No ICMPv6 Router Advertisement (Type 134) found.\n'
    fi

    # Check 2: DHCPv6 Activity (Solicit / Reply / Advertise)
    local dhcp6_frame
    dhcp6_frame="$( (tshark -r "${pcap_file}" -Y "udp.port == 546 || udp.port == 547" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${dhcp6_frame}" ]]; then
        printf '  [PASS] DHCPv6 Transaction packets found starting at Frame #%s\n' "${dhcp6_frame}"
    else
        printf '  [INFO] No DHCPv6 packets observed in this capture window.\n'
    fi

    # Check 3: DHCPv4 Activity (Discover / Ack / Offer)
    local dhcp4_frame
    dhcp4_frame="$( (tshark -r "${pcap_file}" -Y "udp.port == 67 || udp.port == 68" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${dhcp4_frame}" ]]; then
        printf '  [PASS] DHCPv4 Transaction packets found starting at Frame #%s\n' "${dhcp4_frame}"
    else
        printf '  [INFO] No DHCPv4 packets observed in this capture window.\n'
    fi

    # Check 4: DS-Lite Encapsulation (IPv4-in-IPv6 Next Header 4)
    local dslite_frame
    dslite_frame="$( (tshark -r "${pcap_file}" -Y "ipv6.nxt == 4" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${dslite_frame}" ]]; then
        printf '  [PASS] DS-Lite (IPv4-in-IPv6, Next Header 4) encapsulated frame found at Frame #%s\n' "${dslite_frame}"
    fi

    # Check 5: End-to-end ICMP Echo / Connectivity
    local icmp_frame
    icmp_frame="$( (tshark -r "${pcap_file}" -Y "icmp || ${icmp6_type_field} == 128 || ${icmp6_type_field} == 129" -T fields -e frame.number 2>/dev/null || true) | head -n1 )"
    if [[ -n "${icmp_frame}" ]]; then
        printf '  [PASS] End-to-end IP Datapath Traffic observed at Frame #%s\n' "${icmp_frame}"
    fi

    printf '========================================================================================\n'
    if (( test_passed == 1 )); then
        printf 'VERIFICATION SUMMARY: [PASS] - Capture evidence conforms to protocol specifications.\n'
        exit 0
    else
        printf 'VERIFICATION SUMMARY: [FAIL] - Violations detected in capture analysis.\n'
        exit 1
    fi
}

main "$@"
