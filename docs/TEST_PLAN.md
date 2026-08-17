# Detailed Test Plan - IPv6 Gateway & Dual Stack

This document defines the test case matrix, verification scenarios, and PASS/FAIL criteria for Gateway/CPE devices (DUT) based on standard RFC specifications (RFC 8200, RFC 4861, RFC 4862, RFC 8415, RFC 3633, RFC 6333, RFC 8106).

---

## 1. Test Case Traceability Matrix

| Test ID | Scenario | Technical Standard | Prerequisites | PASS Evaluation Criteria |
|---|---|---|---|---|
| **TC01** | **IPv4-Only WAN** | RFC 2131 | WAN offers only IPv4 via DHCPv4 | DUT obtains WAN IPv4; LAN IPv6 is strictly disabled (`IPv6 LAN OFF`). |
| **TC02** | **Stateless SLAAC + RDNSS** | RFC 4862, RFC 8106 | WAN sends RA (`A=1`, `M=0`, `O=0` with RDNSS) | DUT autoconfigures WAN IPv6 from RA prefix; DNS server populated via RDNSS. |
| **TC03** | **Stateful DHCPv6 (IA_NA)** | RFC 8415 | WAN sends RA (`M=1`, `O=1`, `A=0`) | DUT sends DHCPv6 Solicit $\rightarrow$ receives IA_NA Global IPv6 and DNS server. |
| **TC04** | **Stateless DHCPv6** | RFC 8415 | WAN sends RA (`M=0`, `O=1`, `A=1`) | DUT derives IPv6 via SLAAC and transmits DHCPv6 Information-Request for options. |
| **TC05** | **DHCPv6 Prefix Delegation (IA_PD)** | RFC 3633 | Server delegates prefix (`PD_PREFIX/56`) | DUT receives delegated prefix, carves /64 subnets, and advertises via downstream LAN RA. |
| **TC06** | **Concurrent Dual-Stack** | Dual-Stack IPv4/IPv6 | WAN offers both IPv4 DHCP and IPv6 Stateful | DUT operates concurrently: IPv4 NAPT and IPv6 L3 direct routing (no NAT66). |
| **TC07** | **IPv6-Only WAN & DS-Lite Tunneling** | RFC 6333 | WAN is IPv6-only, DHCPv6 provides AFTR name (Opt 64) | DUT establishes B4 tunnel; LAN IPv4 encapsulated in `IPv4-in-IPv6` (`ip6.nxt == 4`) to AFTR; IPv4 DSCP copied to IPv6 Traffic Class. |
| **TC08** | **Multicast/IPTV on IPv6-Only WAN** | RFC 6333 / IGMP | WAN port runs IPv6-only with DS-Lite | DUT initiates dedicated DHCPv4 client on WAN to acquire IPv4 address for IGMP & multicast. |
| **TC09** | **Network Auto-Detection & State Retention** | RFC 4861 / RFC 2131 | WAN network changes between v4 and v6 | DUT sends RS (1, 2, 4, 8s backoff); does NOT send DHCPv6 if no RA is received; falls back to DHCPv4; persists active state. |
| **TC10** | **Address Re-allocation Priority** | Dual-Stack Reassignment | DUT receives IP renewal/reassignment request | DUT prioritizes completing IPv6 address assignment before IPv4 (except on factory reset). |
| **TC11** | **Hardware Acceleration & Throughput** | Fastpath / HW Offloading | iPerf3 bidirectional traffic through DUT | Throughput degradation compared to native IPv4: Wired $< 10\%$, Wireless $< 20\%$. |
| **TC12** | **Link Down / Up Recovery** | Operational Stability | WAN cable unplugged for 5s then restored | DUT reconnects automatically; no duplicate leases or hung clients; traffic recovers in $< 5\text{s}$. |

---

## 2. Packet Capture & Filter Specifications (BPF)

Standard WAN capture filter (`CAPTURE_FILTER`):
```text
icmp6 or (udp port 546 or udp port 547) or (udp port 67 or udp port 68) or (ip6 proto 4) or icmp
```

Protocol breakdown:
- `icmp6`: Captures Neighbor Discovery (RS Type 133, RA Type 134, NS 135, NA 136).
- `udp port 546 or udp port 547`: DHCPv6 protocol traffic (Client port 546, Server port 547).
- `udp port 67 or udp port 68`: DHCPv4 protocol traffic (Server port 67, Client port 68).
- `ip6 proto 4`: DS-Lite encapsulated `IPv4-in-IPv6` traffic (Next Header = 4).

---

## 3. Automated Test Execution Procedure

1. **Initialize Topology**:
   ```bash
   sudo ./scripts/setup.sh --single     # For physical hardware setup
   # Or:
   sudo ./scripts/setup.sh --virtual    # For simulation mode without hardware
   ```
2. **Execute Automated Scenario**:
   ```bash
   sudo ./scripts/scenario.sh dual-stack
   ```
3. **Analyze PCAP Evidence**:
   ```bash
   ./scripts/verify_capture.sh captures/last_capture.pcap
   ```
4. **Tear Down & Cleanup**:
   ```bash
   sudo ./scripts/cleanup.sh
   ```
