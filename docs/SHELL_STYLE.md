# Shell Coding Standard

This project adheres to strict Bash scripting conventions to protect the host machine, prevent silent runtime failures, and enable reliable automated execution in CI/CD and Linux network test labs.

---

## 1. Script Initialization & Strict Mode

Every script in the `scripts/` directory must begin with:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
```

- `-e`: Exit immediately if any command returns a non-zero exit code.
- `-E`: Inherit `ERR` traps across subshells and functions.
- `-u`: Treat unset variables as an error and exit immediately.
- `-o pipefail`: Return the exit status of the last command in the pipeline that failed.
- `IFS=$'\n\t'`: Prevent unintended word-splitting on whitespace.

---

## 2. Safe Pipelines & SIGPIPE Prevention

Under `pipefail`, commands such as:
```bash
tshark -r file.pcap ... | head -n1
```
cause `head -n1` to exit immediately after reading the first line, closing the read end of the pipe. When `tshark` attempts to write further data, it receives `SIGPIPE` (exit code 141), causing the entire script to abort.

**Mandatory Rule:** Wrap all early-terminating pipelines:
```bash
(tshark -r file.pcap ... 2>/dev/null || true) | head -n1
```

---

## 3. Host Safety & NetworkManager Handling

1. **Never Interfere with Host Default Route**:
   - Always verify that the test interface does not carry the host default route before manipulation (`assert_safe_test_if`).
2. **Smart NetworkManager Unmanage & Flush**:
   - USB Ethernet adapters frequently receive unexpected DHCP addresses upon connection.
   - Scripts automatically unmanage and flush test interfaces safely:
     ```bash
     command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true
     ip addr flush dev "${iface}" 2>/dev/null || true
     ```
3. **Never Flush Global Host Firewalls**:
   - All NAT, firewall, and iptables operations must be scoped inside isolated network namespaces (`ip netns exec ...`).

---

## 4. Process Management & Rollback Traps

1. **Automated Rollback in `setup.sh`**:
   - Register an error trap `trap 'rollback_setup $? ${LINENO}' ERR` so that any setup failure automatically rolls back temporary namespaces, bridges, and veth links.
2. **Graceful PID Management (`stop_pidfile`)**:
   - Send `SIGINT` (or `SIGTERM`) $\rightarrow$ wait up to 1.5 seconds $\rightarrow$ send `SIGKILL` (`kill -9`) only if still running.

---

## 5. Strict Variable Quoting

- Quote all variable expansions: `"${var}"`.
- Configuration string variables in `config.env` containing spaces or special characters must be enclosed in double quotes `""`.
