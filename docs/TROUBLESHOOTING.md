# Troubleshooting & Operational Guide

This document outlines common issues encountered on Linux host machines and DUT devices during test execution, along with standard remediations defined by the **Network Test Lab Framework**.

---

## 1. Physical Interface & NetworkManager Issues

### Symptom: Error `Interface carries host default route!`
- **Root Cause**: On Ubuntu/Debian desktop systems, NetworkManager automatically attempts DHCP configuration and installs default routes when USB Ethernet adapters are connected.
- **Resolution**:
  The `assert_safe_test_if` helper in `scripts/lib/common.sh` automatically unmanages and flushes test adapters:
  ```bash
  nmcli device set <IFACE> managed no
  ip addr flush dev <IFACE>
  ```
  If conflicts persist, inspect host default routes:
  ```bash
  ip route show default
  ```
  Ensure the adapter selected for testing is not the host's primary Internet interface.

---

## 2. Capture Permissions & Wireshark / TShark

### Symptom: `dumpcap: Permission denied` during background capture
- **Root Cause**: On Debian/Ubuntu Linux, Wireshark's `dumpcap` binary drops root privileges to an unprivileged user/group (`nobody` or `wireshark`). When writing to restricted directories, permission errors occur.
- **Resolution**:
  1. `scripts/capture.sh` **prioritizes `tcpdump`** (with `-U` packet-buffered mode and `-s 0` full payload) for background captures.
  2. The `ensure_runtime_dirs` helper sets `chmod 0777` permissions on `captures/` and `state/`.
  3. `tshark` is reserved strictly for post-capture analysis in `scripts/verify_capture.sh`.

---

## 3. Bash Pipe Break (`SIGPIPE` / Exit Code 141)

### Symptom: Script abruptly terminates during `tshark` pipeline processing
- **Root Cause**: Under `set -Eeuo pipefail`, when utilities like `head -n1` or `awk '... exit'` terminate early, `tshark` receives `SIGPIPE` and exits with code 141, triggering pipeline failure.
- **Resolution**:
  Wrap all reading pipelines:
  ```bash
  (tshark -r file.pcap ... 2>/dev/null || true) | head -n1
  ```

---

## 4. DUT WAN Firewall Dropping DHCPv6 / DS-Lite Replies

### Symptom: WAN server transmits `DHCPv6 Advertise`/`Reply` or DS-Lite packets, but DUT drops them
- **Root Cause**: Commercial router firmwares frequently default to dropping unsolicited inbound WAN traffic in the `INPUT` chain.
- **Resolution**:
  Access the DUT via SSH and install input rules for testing:

  **For NFTables on DUT:**
  ```nft
  iifname "eth1" udp sport 547 udp dport 546 counter accept comment "Allow DHCPv6 Server responses"
  iifname "eth1" udp sport 67 udp dport 68 counter accept comment "Allow DHCPv4 Server responses"
  iifname "eth1" ip6 nexthdr 4 counter accept comment "Allow DS-Lite IPv4-in-IPv6 packets"
  ```

  **For IPTables on DUT:**
  ```bash
  iptables -I INPUT -i eth1 -p udp --sport 67 --dport 68 -j ACCEPT
  ip6tables -I INPUT -i eth1 -p udp --sport 547 --dport 546 -j ACCEPT
  ip6tables -I INPUT -i eth1 -p 4 -j ACCEPT
  ```

---

## 5. Offline Testing Without Hardware (`--virtual`)

If physical DUT hardware or USB Ethernet adapters are not available, the entire suite can run in virtual mode:
```bash
sudo ./scripts/setup.sh --virtual
sudo ./scripts/scenario.sh dual-stack
./scripts/show_state.sh
sudo ./scripts/cleanup.sh
```
This spawns a simulated router namespace (`ns-dut`) with full L3 routing, IPv6 forwarding, and address handling for CI/CD and verification testing.
