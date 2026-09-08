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

# Standard logging
log_info()  { printf '[INFO] %s\n' "$*"; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

require_root() {
    if (( EUID != 0 )); then
        die "This command requires root/sudo privileges."
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "Required command is not installed: ${cmd}"
    fi
}
require_cmd() { require_command "$@"; }

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

    : "${WAN_IPV6_CIDR:=2001:db8:10::1/64}"
    : "${WAN_IPV6_PREFIX:=2001:db8:10::/64}"
    : "${WAN_IPV6_DNS:=2001:db8:10::1}"

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
}

iface_exists_root() {
    local iface="$1"
    ip link show dev "${iface}" >/dev/null 2>&1
}

iface_exists_ns() {
    local ns="$1"
    local iface="$2"
    ip netns exec "${ns}" ip link show dev "${iface}" >/dev/null 2>&1
}

ns_exists() {
    local ns="$1"
    ip netns list 2>/dev/null | awk '{print $1}' | grep -Fxq "${ns}"
}

bridge_exists() {
    local bridge="$1"
    ip link show dev "${bridge}" >/dev/null 2>&1
}

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

bridge_create() {
    local bridge="$1"
    if ! bridge_exists "${bridge}"; then
        ip link add name "${bridge}" type bridge
    fi
    ip addr flush dev "${bridge}" 2>/dev/null || true
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

cleanup_bridge_and_nic() {
    local bridge="$1"
    local iface="${2:-}"

    if [[ -n "${iface}" ]] && iface_exists_root "${iface}"; then
        ip link set dev "${iface}" nomaster 2>/dev/null || true
        ip addr flush dev "${iface}" 2>/dev/null || true
        ip link set dev "${iface}" down 2>/dev/null || true
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

namespace_ip() {
    local ns="${1:-${NS_WAN}}"
    local iface="${2:-${NS_IF}}"
    ip netns exec "${ns}" ip -4 -o addr show dev "${iface}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

namespace_ipv6() {
    local ns="${1:-${NS_WAN}}"
    local iface="${2:-${NS_IF}}"
    ip netns exec "${ns}" ip -6 -o addr show dev "${iface}" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

is_pidfile_running() {
    local pidfile="$1"
    local pid=""
    if [[ ! -f "${pidfile}" ]]; then return 1; fi
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -z "${pid}" || "${pid}" =~ [^0-9] ]]; then return 1; fi
    kill -0 "${pid}" 2>/dev/null || [[ -d "/proc/${pid}" ]]
}

stop_pidfile() {
    local pidfile="$1"
    local pid=""
    local attempt
    if [[ ! -f "${pidfile}" ]]; then return 0; fi
    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]]; then
        if kill -0 "${pid}" 2>/dev/null; then
            kill -INT "${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
            for attempt in {1..15}; do
                if ! kill -0 "${pid}" 2>/dev/null; then break; fi
                sleep 0.1
            done
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
        fi
    fi
    rm -f "${pidfile}"
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

run_dut_cmd() {
    local cmd="$1"
    if [[ -z "${DUT_SSH_HOST:-}" || -z "${cmd}" ]]; then return 0; fi
    require_command ssh
    # shellcheck disable=SC2086
    ssh ${DUT_SSH_OPTS:-} "${DUT_SSH_USER:-root}@${DUT_SSH_HOST}" "${cmd}"
}

render_template() {
    local src="$1"
    local dst="$2"
    local iface="${3:-${NS_IF}}"

    sed \
        -e "s|@DUT_IF@|${iface}|g" \
        -e "s|@WAN_IPV4_SUBNET@|${WAN_IPV4_SUBNET}|g" \
        -e "s|@WAN_IPV4_POOL_START@|${WAN_IPV4_POOL_START}|g" \
        -e "s|@WAN_IPV4_POOL_END@|${WAN_IPV4_POOL_END}|g" \
        -e "s|@WAN_IPV4_ROUTER@|${WAN_IPV4_ROUTER}|g" \
        -e "s|@WAN_IPV4_DNS@|${WAN_IPV4_DNS}|g" \
        -e "s|@WAN_IPV6_PREFIX@|${WAN_IPV6_PREFIX}|g" \
        -e "s|@WAN_IPV6_DNS@|${WAN_IPV6_DNS}|g" \
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
