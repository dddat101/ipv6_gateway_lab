#!/usr/bin/env bash
# ==============================================================================
# NETWORK TEST LAB - IPV6 GATEWAY COMMON LIBRARY
# Standard framework helpers: logging, lifecycle, interface safety, netns, bridges
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
readonly CONFIG_FILE="${PROJECT_ROOT}/config.env"
readonly LOG_TAG="IPV6-GATEWAY-LAB"

# 1. Standard Logging & Output Formatting
log_info()    { printf '\e[1;32m[INFO]\e[0m    %s\n' "$*"; }
log_success() { printf '\e[1;32m[PASS]\e[0m    %s\n' "$*"; }
log_warn()    { printf '\e[1;33m[WARN]\e[0m    %s\n' "$*" >&2; }
log_error()   { printf '\e[1;31m[ERROR]\e[0m   %s\n' "$*" >&2; }
log_step()    { printf '\e[1;36m===> %s\e[0m\n' "$*"; }
die()         { log_error "$*"; exit 1; }

log_debug() {
    if [[ "${DEBUG:-0}" == "1" || "${VERBOSE:-0}" == "1" ]]; then
        printf '\e[1;34m[DEBUG]\e[0m   %s\n' "$*"
    fi
}

print_header() {
    local title="$1"
    printf '==================================================================\n'
    printf '  %s\n' "${title}"
    printf '==================================================================\n'
}

print_section() {
    local section="$1"
    printf '\n--- [%s] ---\n' "${section}"
}

# 2. Privileges & Command Assertions
require_root() {
    if (( EUID != 0 )); then
        die "This command requires root/sudo privileges. Please run with sudo."
    fi
}
is_root() { (( EUID == 0 )); }

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "Required command is not installed: ${cmd}"
    fi
}
require_cmd() { require_command "$@"; }

check_command() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1
}

# 3. Configuration & Runtime Storage
load_config() {
    local config_path="${1:-${CONFIG_FILE}}"

    if [[ ! -f "${config_path}" ]]; then
        if [[ -f "${PROJECT_ROOT}/config.env.example" ]]; then
            log_warn "config.env not found. Auto-generating from config.env.example..."
            cp "${PROJECT_ROOT}/config.env.example" "${config_path}"
        else
            die "Missing configuration file: ${config_path}. Create it from config.env.example."
        fi
    fi

    # shellcheck disable=SC1090
    source "${config_path}"

    # Defaults & Role Selection
    : "${LAB_ROLE:=single}"
    : "${TOPOLOGY_MODE:=physical}"
    : "${RESTORE_INTERFACES_ON_CLEANUP:=1}"
    : "${WAN_BRIDGE:=br-test-wan}"
    : "${LAN_BRIDGE:=br-test-lan}"
    : "${NS_WAN:=ns-wan}"
    : "${NS_LAN:=ns-lan1}"
    : "${NS_DUT:=ns-dut}"
    : "${NS_IF:=eth0}"
    : "${DEFAULT_SCENARIO:=dual-stack}"

    # WAN IPv4 / IPv6 Defaults
    : "${WAN_IPV4_CIDR:=10.10.0.1/24}"
    : "${WAN_IPV4_SUBNET:=10.10.0.0/24}"
    : "${WAN_IPV4_POOL_START:=10.10.0.100}"
    : "${WAN_IPV4_POOL_END:=10.10.0.200}"
    : "${WAN_IPV4_ROUTER:=10.10.0.1}"
    : "${WAN_IPV4_DNS:=10.10.0.1}"
    : "${WAN_IPV4_DNS2:=10.10.0.2}"

    : "${WAN_IPV6_CIDR:=2001:db8:10::1/64}"
    : "${WAN_IPV6_PREFIX:=2001:db8:10::/64}"
    : "${WAN_IPV6_DNS:=2001:db8:10::1}"
    : "${WAN_IPV6_DNS2:=2001:db8:10::2}"

    : "${PD_PREFIX:=2001:db8:100::}"
    : "${PD_PREFIX_LEN:=56}"
    : "${PD_DELEGATED_LEN:=64}"

    : "${AFTR_IPV6:=2001:db8:10::affe}"
    : "${AFTR_NAME:=aftr.example.com}"

    : "${DUT_LAN_IP:=192.168.1.1}"
    : "${LAN_IPV4_SUBNET:=192.168.1.0/24}"
    : "${LAN_IPV6_PREFIX:=2001:db8:100:1::/64}"
    : "${LAN_CLIENT_IPV4:=192.168.1.100}"
    : "${LAN_CLIENT_IPV6:=2001:db8:100:1::100}"
    : "${LAN_CLIENT_HOSTNAME:=ipv6-stb-client}"
    : "${LAN_CLIENT_VENDOR:=IPTV_STB}"

    : "${RA_MIN_INTERVAL_SEC:=3}"
    : "${RA_MAX_INTERVAL_SEC:=10}"
    : "${RA_LIFETIME_SEC:=60}"

    : "${DHCP_VALID_LIFETIME_SEC:=600}"
    : "${DHCP_RENEW_TIMER_SEC:=300}"
    : "${DHCP_REBIND_TIMER_SEC:=450}"
    : "${DHCP6_PREFERRED_LIFETIME_SEC:=450}"

    : "${CAPTURE_DIR:=${PROJECT_ROOT}/captures}"
    : "${STATE_DIR:=${PROJECT_ROOT}/state}"
    : "${LOG_DIR:=${PROJECT_ROOT}/logs}"
    : "${CAPTURE_SNAPLEN:=0}"
    : "${CAPTURE_FILTER:=icmp6 or (udp port 546 or udp port 547) or (udp port 67 or udp port 68) or (ip6 proto 4) or icmp}"

    : "${TCPDUMP_BIN:=tcpdump}"
    : "${TSHARK_BIN:=tshark}"

    # Auto-detect Python Virtualenv
    if [[ -z "${PYTHON_BIN:-}" ]]; then
        if [[ -x "${PROJECT_ROOT}/.venv/bin/python3" ]]; then
            PYTHON_BIN="${PROJECT_ROOT}/.venv/bin/python3"
        else
            PYTHON_BIN="python3"
        fi
    fi

    # Resolve relative paths to absolute paths
    if [[ "${CAPTURE_DIR}" != /* ]]; then CAPTURE_DIR="${PROJECT_ROOT}/${CAPTURE_DIR}"; fi
    if [[ "${STATE_DIR}" != /* ]]; then STATE_DIR="${PROJECT_ROOT}/${STATE_DIR}"; fi
    if [[ "${LOG_DIR}" != /* ]]; then LOG_DIR="${PROJECT_ROOT}/${LOG_DIR}"; fi

    ensure_runtime_dirs
}

ensure_runtime_dirs() {
    install -d -m 0777 "${CAPTURE_DIR}" "${STATE_DIR}" "${LOG_DIR}"
    chmod 0777 "${CAPTURE_DIR}" "${STATE_DIR}" "${LOG_DIR}" 2>/dev/null || true
    chmod -R a+rw "${CAPTURE_DIR}" "${STATE_DIR}" "${LOG_DIR}" 2>/dev/null || true
}

clean_logs() {
    ensure_runtime_dirs
    log_info "Cleaning log files in ${LOG_DIR}..."
    find "${LOG_DIR}" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
    log_info "Logs directory cleaned."
}

clean_captures() {
    ensure_runtime_dirs
    log_info "Cleaning PCAP capture files in ${CAPTURE_DIR}..."
    find "${CAPTURE_DIR}" -mindepth 1 ! -name '.gitkeep' -delete 2>/dev/null || true
    rm -f "${STATE_DIR}/last_capture.env" "${STATE_DIR}/latest_capture.txt" 2>/dev/null || true
    log_info "Captures directory cleaned."
}

# 4. Network Safety, Interfaces & Namespaces
iface_exists_root() { ip link show dev "$1" >/dev/null 2>&1; }
iface_exists_ns()   { ip netns exec "$1" ip link show dev "$2" >/dev/null 2>&1; }
ns_exists()         { ip netns list 2>/dev/null | awk '{print $1}' | grep -Fxq "$1"; }
bridge_exists()     { ip link show dev "$1" >/dev/null 2>&1; }

validate_namespace_ready() {
    local ns="$1"
    local iface="$2"

    if ! ns_exists "${ns}"; then
        die "Namespace does not exist: ${ns}. Run scripts/setup.sh first."
    fi
    if ! iface_exists_ns "${ns}" "${iface}"; then
        die "Interface ${iface} is missing in namespace ${ns}. Run scripts/cleanup.sh and scripts/setup.sh again."
    fi
}

assert_safe_test_if() {
    local iface="$1"

    [[ -n "${iface}" ]] || die "Interface name cannot be empty."
    [[ "${iface}" != "lo" ]] || die "Refusing to use loopback interface."
    iface_exists_root "${iface}" || die "Interface not found in root namespace: ${iface}"

    # 1. Strictly protect host default route
    if ip route show default 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        die "Interface ${iface} carries host default route! Use a dedicated Ethernet adapter."
    fi

    # 2. Smart NetworkManager unmanage & flush
    if ip -4 addr show dev "${iface}" 2>/dev/null | grep -q 'inet '; then
        log_warn "Interface ${iface} has host IPv4 address. Flushing and setting unmanaged..."
        command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true
        ip addr flush dev "${iface}" 2>/dev/null || true
    fi
}

namespace_ip() {
    local ns="${1:-${NS_WAN}}"
    local iface="${2:-${NS_IF}}"
    if ns_exists "${ns}"; then
        ip netns exec "${ns}" ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    else
        ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    fi
}

namespace_ipv6() {
    local ns="${1:-${NS_WAN}}"
    local iface="${2:-${NS_IF}}"
    if ns_exists "${ns}"; then
        ip netns exec "${ns}" ip -6 -o addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    else
        ip -6 -o addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || echo ""
    fi
}

namespace_mac() {
    local ns="${1:-${NS_WAN}}"
    local iface="${2:-${NS_IF}}"
    if ns_exists "${ns}"; then
        ip netns exec "${ns}" cat "/sys/class/net/${iface}/address" 2>/dev/null || echo ""
    else
        cat "/sys/class/net/${iface}/address" 2>/dev/null || echo ""
    fi
}

exec_in_ns() {
    local ns="$1"
    shift
    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        ip netns exec "${ns}" "$@"
    else
        "$@"
    fi
}

is_ip_reachable() {
    local target="$1"
    local timeout="${2:-1}"
    local ns="${3:-}"
    local is_v6=0
    [[ "${target}" == *:* ]] && is_v6=1

    local ping_bin="ping"
    if (( is_v6 == 1 )); then
        ping_bin="ping -6"
    fi

    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        ip netns exec "${ns}" ${ping_bin} -c 1 -W "${timeout}" "${target}" >/dev/null 2>&1
    else
        ${ping_bin} -c 1 -W "${timeout}" "${target}" >/dev/null 2>&1
    fi
}

wait_for_ping() {
    local target="$1"
    local timeout="${2:-10}"
    local ns="${3:-}"
    local elapsed=0
    while ! is_ip_reachable "${target}" 1 "${ns}"; do
        sleep 1
        elapsed=$((elapsed + 1))
        if (( elapsed >= timeout )); then
            log_warn "Timeout waiting for ping response from ${target} after ${timeout}s"
            return 1
        fi
    done
    return 0
}

# 5. Bridges & Interface Recovery
bridge_create() {
    local bridge="$1"
    if ! bridge_exists "${bridge}"; then
        ip link add name "${bridge}" type bridge
    fi
    ip addr flush dev "${bridge}" 2>/dev/null || true
    # Disable host-level IPv6 stack on test bridge to prevent host SLAAC route pollution
    sysctl -q -w "net.ipv6.conf.${bridge}.disable_ipv6=1" 2>/dev/null || true
    ip link set dev "${bridge}" type bridge stp_state 0 mcast_snooping 0 2>/dev/null || true
    ip link set dev "${bridge}" up
}

attach_physical_to_bridge() {
    local iface="$1"
    local bridge="$2"

    assert_safe_test_if "${iface}"
    command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed no 2>/dev/null || true
    ip link set dev "${iface}" down
    ip addr flush dev "${iface}" 2>/dev/null || true
    ip link set dev "${iface}" master "${bridge}"
    ip link set dev "${iface}" up
}

restore_physical_interface() {
    local iface="$1"
    require_root

    [[ -n "${iface}" ]] || return 0
    iface_exists_root "${iface}" || return 0

    log_info "Restoring interface ${iface} to UP state with DHCP..."

    # 1. Detach from bridge master if any
    ip link set dev "${iface}" nomaster 2>/dev/null || true

    # 2. Flush any static lab IP
    ip addr flush dev "${iface}" 2>/dev/null || true

    # 3. Bring interface link UP
    ip link set dev "${iface}" up

    # 4. Hand over to NetworkManager and trigger auto-connect
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device set "${iface}" managed yes 2>/dev/null || true
        nmcli device set "${iface}" autoconnect yes 2>/dev/null || true
        nmcli device connect "${iface}" >/dev/null 2>&1 || true
    fi

    # 5. Fallback DHCP if carrier is present
    if ip link show dev "${iface}" 2>/dev/null | grep -q "LOWER_UP"; then
        local got_ip=0
        for (( i=0; i<4; i++ )); do
            if ip -4 -o addr show dev "${iface}" 2>/dev/null | grep -q 'inet '; then
                got_ip=1
                break
            fi
            sleep 0.5
        done

        if (( got_ip == 0 )) && command -v dhclient >/dev/null 2>&1; then
            log_info "Triggering dhclient for ${iface}..."
            dhclient -4 -nw "${iface}" 2>/dev/null || true
        fi
    fi

    local current_ip
    current_ip="$(ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | head -n1 || echo '')"
    if [[ -n "${current_ip}" ]]; then
        log_info "Interface ${iface} is UP with IP: ${current_ip}"
    else
        log_info "Interface ${iface} is UP [Managed]. Waiting for DHCP lease from network."
    fi
}

tear_down_physical_interface() {
    local iface="$1"
    require_root

    [[ -n "${iface}" ]] || return 0
    iface_exists_root "${iface}" || return 0

    if command -v dhclient >/dev/null 2>&1; then
        dhclient -x "${iface}" 2>/dev/null || true
    fi
    ip link set dev "${iface}" nomaster 2>/dev/null || true
    ip addr flush dev "${iface}" 2>/dev/null || true
    ip link set dev "${iface}" down 2>/dev/null || true
    command -v nmcli >/dev/null 2>&1 && nmcli device set "${iface}" managed yes 2>/dev/null || true
    log_info "Interface ${iface} is DOWN and flushed."
}

cleanup_bridge_and_nic() {
    local bridge="$1"
    local iface="${2:-}"
    local restore="${3:-${RESTORE_INTERFACES_ON_CLEANUP:-1}}"

    if [[ -n "${iface}" ]] && iface_exists_root "${iface}"; then
        if (( restore == 1 )); then
            restore_physical_interface "${iface}"
        else
            tear_down_physical_interface "${iface}"
        fi
    fi

    if bridge_exists "${bridge}"; then
        ip link set dev "${bridge}" down 2>/dev/null || true
        ip link del dev "${bridge}" 2>/dev/null || true
    fi
}

ns_create() {
    local ns="$1"
    if ! ns_exists "${ns}"; then
        ip netns add "${ns}"
    fi
    ip -n "${ns}" link set lo up
}

create_veth_to_ns() {
    local ns="$1"
    local host_if="$2"
    local ns_if="$3"
    local bridge="$4"
    local cidrv4="${5:-}"
    local gatewayv4="${6:-}"
    local cidrv6="${7:-}"
    local gatewayv6="${8:-}"

    ns_create "${ns}"
    if ! iface_exists_ns "${ns}" "${ns_if}"; then
        ip link del dev "${host_if}" 2>/dev/null || true
        ip link add "${host_if}" type veth peer name "${ns_if}" netns "${ns}"
    fi

    ip link set dev "${host_if}" master "${bridge}"
    ip link set dev "${host_if}" up
    ip -n "${ns}" link set dev "${ns_if}" up

    # Flush IPv4 and global IPv6 only - preserve link-local fe80:: (RFC 4861 requirement)
    ip -n "${ns}" -4 addr flush dev "${ns_if}" 2>/dev/null || true
    ip -n "${ns}" -6 addr flush dev "${ns_if}" scope global 2>/dev/null || true

    # Enable IPv6 and prevent DAD delay on test interface
    ip netns exec "${ns}" sysctl -q -w "net.ipv6.conf.${ns_if}.disable_ipv6=0" 2>/dev/null || true
    ip netns exec "${ns}" sysctl -q -w "net.ipv6.conf.${ns_if}.addr_gen_mode=0" 2>/dev/null || true
    ip netns exec "${ns}" sysctl -q -w "net.ipv6.conf.${ns_if}.accept_dad=0" 2>/dev/null || true

    # Ensure link-local address exists immediately (required by radvd and DHCPv6)
    if ! ip netns exec "${ns}" ip -6 -o addr show dev "${ns_if}" scope link 2>/dev/null | grep -q 'inet6 '; then
        local host_id="1"
        [[ "${ns}" == "${NS_LAN:-ns-lan1}" ]] && host_id="100"
        ip -n "${ns}" -6 addr add "fe80::${host_id}/64" dev "${ns_if}" nodad 2>/dev/null || true
    fi

    if [[ -n "${cidrv4}" ]]; then
        ip -n "${ns}" addr add "${cidrv4}" dev "${ns_if}"
    fi
    if [[ -n "${gatewayv4}" ]]; then
        ip -n "${ns}" route replace default via "${gatewayv4}" dev "${ns_if}" 2>/dev/null || true
    fi
    if [[ -n "${cidrv6}" ]]; then
        ip -n "${ns}" -6 addr add "${cidrv6}" dev "${ns_if}" nodad 2>/dev/null || true
    fi
    if [[ -n "${gatewayv6}" ]]; then
        ip -n "${ns}" -6 route replace default via "${gatewayv6}" dev "${ns_if}" 2>/dev/null || true
    fi
}

# 6. Process Supervision & Daemon Management
is_pidfile_running() {
    local pidfile="$1"
    local pid=""
    if [[ ! -f "${pidfile}" ]]; then return 1; fi
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -z "${pid}" || "${pid}" =~ [^0-9] ]]; then return 1; fi
    kill -0 "${pid}" 2>/dev/null || [[ -d "/proc/${pid}" ]]
}

start_daemon() {
    local pid_file="$1" log_file="$2" service_name="$3" exec_ns="${4:-}"
    shift 4 || true
    local cmd=("$@")

    if is_pidfile_running "${pid_file}"; then
        log_warn "${service_name} is already running (PID: $(cat "${pid_file}"))."
        return 0
    fi
    log_info "Starting ${service_name}..."
    local prefix=()
    if [[ -n "${exec_ns}" ]] && ns_exists "${exec_ns}"; then
        prefix=("ip" "netns" "exec" "${exec_ns}")
    fi
    "${prefix[@]}" nohup "${cmd[@]}" > "${log_file}" 2>&1 &
    local daemon_pid=$!
    echo "${daemon_pid}" > "${pid_file}"
    chmod 0666 "${pid_file}" "${log_file}" 2>/dev/null || true
    sleep 0.2
    if kill -0 "${daemon_pid}" 2>/dev/null; then
        log_info "${service_name} running (PID: ${daemon_pid}, Log: ${log_file})"
        return 0
    else
        log_error "Failed to start ${service_name}! Check log: ${log_file}"
        return 1
    fi
}

stop_pidfile() {
    local pidfile="$1"
    local name="${2:-process}"
    local pid=""
    local attempt
    if [[ ! -f "${pidfile}" ]]; then return 0; fi
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]]; then
        if kill -0 "${pid}" 2>/dev/null; then
            log_info "Stopping ${name} (PID: ${pid})..."
            kill -INT "${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
            for attempt in {1..15}; do
                if ! kill -0 "${pid}" 2>/dev/null; then break; fi
                sleep 0.1
            done
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
            log_info "${name} stopped."
        fi
    fi
    rm -f "${pidfile}"
}

stop_process_by_pattern() {
    local pattern="$1"
    local name="${2:-processes matching '${pattern}'}"
    if pgrep -f "${pattern}" >/dev/null 2>&1; then
        log_info "Terminating ${name}..."
        pkill -INT -f "${pattern}" 2>/dev/null || true
        sleep 0.3
        pgrep -f "${pattern}" >/dev/null 2>&1 && pkill -TERM -f "${pattern}" 2>/dev/null || true
        sleep 0.5
        pgrep -f "${pattern}" >/dev/null 2>&1 && pkill -9 -f "${pattern}" 2>/dev/null || true
    fi
}

# 7. Deterministic Socket & Service Synchronization
is_port_listening() {
    local port="$1"
    local host="${2:-127.0.0.1}"
    local ns="${3:-}"
    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        ip netns exec "${ns}" python3 -c "import socket; s = socket.socket(); s.settimeout(0.5); s.connect(('${host}', int(${port}))); s.close()" >/dev/null 2>&1
    else
        python3 -c "import socket; s = socket.socket(); s.settimeout(0.5); s.connect(('${host}', int(${port}))); s.close()" >/dev/null 2>&1
    fi
}

wait_for_port() {
    local port="$1"
    local host="${2:-127.0.0.1}"
    local timeout="${3:-10}"
    local ns="${4:-}"
    local elapsed=0
    while ! is_port_listening "${port}" "${host}" "${ns}"; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if (( elapsed >= timeout * 2 )); then
            log_warn "Timeout waiting for port ${port} on ${host} after ${timeout}s"
            return 1
        fi
    done
    return 0
}

wait_for_http() {
    local url="$1"
    local expected_code="${2:-200}"
    local timeout="${3:-10}"
    local ns="${4:-}"
    local elapsed=0
    local curl_cmd=("curl" "-sk" "-o" "/dev/null" "-w" "%{http_code}" "--max-time" "1" "${url}")
    if [[ -n "${ns}" ]] && ns_exists "${ns}"; then
        curl_cmd=("ip" "netns" "exec" "${ns}" "${curl_cmd[@]}")
    fi
    while true; do
        local code
        code="$("${curl_cmd[@]}" 2>/dev/null || echo "000")"
        if [[ "${code}" == "${expected_code}" || ("${expected_code}" == "any" && "${code}" != "000") ]]; then
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
        if (( elapsed >= timeout * 2 )); then
            log_warn "Timeout waiting for HTTP URL ${url} (code: ${code}) after ${timeout}s"
            return 1
        fi
    done
}

# 8. DUT SSH Command Execution & Telemetry
run_dut_cmd() {
    local cmd="$1"
    local timeout="${2:-10}"
    if [[ -z "${DUT_SSH_HOST:-}" || -z "${cmd}" ]]; then return 0; fi
    require_command ssh
    local ssh_opts=(-o ConnectTimeout="${timeout}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR)
    [[ -n "${DUT_SSH_PORT:-}" ]] && ssh_opts+=(-p "${DUT_SSH_PORT}")
    [[ -n "${DUT_SSH_KEY:-}" && -f "${DUT_SSH_KEY}" ]] && ssh_opts+=(-i "${DUT_SSH_KEY}")
    ssh "${ssh_opts[@]}" "${DUT_SSH_USER:-root}@${DUT_SSH_HOST}" "${cmd}"
}

is_dut_ssh_ready() {
    [[ -z "${DUT_SSH_HOST:-}" ]] && return 1
    run_dut_cmd "echo ok" 3 >/dev/null 2>&1
}

# 9. PCAP, Metrics & Template Rendering
get_latest_pcap() {
    if [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        local pcap_from_env
        pcap_from_env="$(grep '^LAST_PCAP=' "${STATE_DIR}/last_capture.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
        if [[ -n "${pcap_from_env}" && -f "${pcap_from_env}" ]]; then
            printf '%s\n' "${pcap_from_env}"
            return 0
        fi
    fi
    if [[ -d "${CAPTURE_DIR}" ]]; then
        local newest
        newest="$(find "${CAPTURE_DIR}" -name '*.pcap' -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | awk '{print $2}' || true)"
        if [[ -n "${newest}" && -f "${newest}" ]]; then
            printf '%s\n' "${newest}"
            return 0
        fi
    fi
    return 1
}

format_bytes() {
    local bytes="${1:-0}"
    if (( bytes < 1024 )); then printf '%d B' "${bytes}"
    elif (( bytes < 1048576 )); then printf '%.1f KB' "$((bytes * 10 / 1024))e-1"
    elif (( bytes < 1073741824 )); then printf '%.1f MB' "$((bytes * 10 / 1048576))e-1"
    else printf '%.1f GB' "$((bytes * 10 / 1073741824))e-1"; fi
}

detect_tshark_field() {
    local cache_var="$1"
    shift
    local candidate
    for candidate in "$@"; do
        if grep -Fxq "${candidate}" <<< "${cache_var}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

render_template() {
    local src="$1"
    local dst="$2"
    local iface="${3:-${NS_IF}}"

    local v4_dns_list="${WAN_IPV4_DNS}"
    if [[ -n "${WAN_IPV4_DNS2:-}" ]]; then
        v4_dns_list="${WAN_IPV4_DNS}, ${WAN_IPV4_DNS2}"
    fi

    local v6_dns_list="${WAN_IPV6_DNS}"
    local v6_radvd_dns="${WAN_IPV6_DNS}"
    if [[ -n "${WAN_IPV6_DNS2:-}" ]]; then
        v6_dns_list="${WAN_IPV6_DNS}, ${WAN_IPV6_DNS2}"
        v6_radvd_dns="${WAN_IPV6_DNS} ${WAN_IPV6_DNS2}"
    fi

    sed \
        -e "s|@DUT_IF@|${iface}|g" \
        -e "s|@WAN_IPV4_SUBNET@|${WAN_IPV4_SUBNET}|g" \
        -e "s|@WAN_IPV4_POOL_START@|${WAN_IPV4_POOL_START}|g" \
        -e "s|@WAN_IPV4_POOL_END@|${WAN_IPV4_POOL_END}|g" \
        -e "s|@WAN_IPV4_ROUTER@|${WAN_IPV4_ROUTER}|g" \
        -e "s|@WAN_IPV4_DNS@|${v4_dns_list}|g" \
        -e "s|@WAN_IPV4_DNS1@|${WAN_IPV4_DNS}|g" \
        -e "s|@WAN_IPV4_DNS2@|${WAN_IPV4_DNS2:-}|g" \
        -e "s|@WAN_IPV6_PREFIX@|${WAN_IPV6_PREFIX}|g" \
        -e "s|@WAN_IPV6_DNS@|${v6_dns_list}|g" \
        -e "s|@WAN_IPV6_DNS1@|${WAN_IPV6_DNS}|g" \
        -e "s|@WAN_IPV6_DNS2@|${WAN_IPV6_DNS2:-}|g" \
        -e "s|@WAN_IPV6_RDNSS@|${v6_radvd_dns}|g" \
        -e "s|@PD_PREFIX@|${PD_PREFIX}|g" \
        -e "s|@PD_PREFIX_LEN@|${PD_PREFIX_LEN}|g" \
        -e "s|@PD_DELEGATED_LEN@|${PD_DELEGATED_LEN}|g" \
        -e "s|@AFTR_NAME@|${AFTR_NAME}|g" \
        -e "s|@RA_MIN_INTERVAL_SEC@|${RA_MIN_INTERVAL_SEC}|g" \
        -e "s|@RA_MAX_INTERVAL_SEC@|${RA_MAX_INTERVAL_SEC}|g" \
        -e "s|@RA_LIFETIME_SEC@|${RA_LIFETIME_SEC}|g" \
        -e "s|@DHCP_VALID_LIFETIME_SEC@|${DHCP_VALID_LIFETIME_SEC}|g" \
        -e "s|@DHCP_RENEW_TIMER_SEC@|${DHCP_RENEW_TIMER_SEC}|g" \
        -e "s|@DHCP_REBIND_TIMER_SEC@|${DHCP_REBIND_TIMER_SEC}|g" \
        -e "s|@DHCP6_PREFERRED_LIFETIME_SEC@|${DHCP6_PREFERRED_LIFETIME_SEC}|g" \
        "${src}" > "${dst}"
}
