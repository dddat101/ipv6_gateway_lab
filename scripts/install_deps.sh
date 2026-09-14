#!/usr/bin/env bash
# ==============================================================================
# IPV6 GATEWAY LAB - DEPENDENCY INSTALLATION SCRIPT
# Installs required host packages (radvd, Kea DHCP, dnsmasq, udhcpc, tcpdump, etc.)
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly REQUIRED_PACKAGES=(
    ca-certificates
    dnsmasq
    ethtool
    iperf3
    iproute2
    iptables
    iputils-ping
    isc-dhcp-client
    kea-dhcp4-server
    kea-dhcp6-server
    openssh-client
    procps
    python3
    radvd
    tcpdump
    tshark
    udhcpc
)

usage() {
    cat <<'USAGE'
Description:
  Installs required system host packages (radvd, Kea DHCP, dnsmasq, udhcpc,
  dhclient, tcpdump, tshark, iperf3, python3, ethtool, etc.) on Debian/Ubuntu or Fedora/RHEL.

Usage:
  sudo ./scripts/install_deps.sh [options]

Options:
  -h, --help    Show this help message

Examples:
  sudo ./scripts/install_deps.sh

Suggested Next Steps:
  - Verify environment:    ./scripts/diagnose.sh
  - Deploy topology:       sudo ./scripts/setup.sh --virtual
USAGE
}

main() {
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            usage
            exit 0
        fi
    done

    if [[ "$(id -u)" -ne 0 ]]; then
        printf 'ERROR: This script must be run as root (or with sudo).\n' >&2
        printf 'Usage: sudo ./scripts/install_deps.sh\n' >&2
        exit 1
    fi

    printf '==============================================================================\n'
    printf '        IPV6 GATEWAY TEST LAB - HOST DEPENDENCY INSTALLER                     \n'
    printf '==============================================================================\n\n'

    if command -v apt-get >/dev/null 2>&1; then
        printf 'Detected Debian/Ubuntu APT package manager.\n'
        printf 'Updating package indices...\n'
        apt-get update -y

        printf 'Installing required packages: %s...\n' "${REQUIRED_PACKAGES[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${REQUIRED_PACKAGES[@]}"

        # Disable default host-level system services for daemons managed inside netns
        for svc in kea-dhcp4-server kea-dhcp6-server radvd; do
            if systemctl is-enabled "${svc}" >/dev/null 2>&1 || systemctl is-active "${svc}" >/dev/null 2>&1; then
                systemctl disable --now "${svc}" 2>/dev/null || true
            fi
        done

        printf '\nAll dependencies installed successfully!\n'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'Detected Fedora/RHEL DNF package manager.\n'
        dnf install -y \
            ca-certificates \
            dnsmasq \
            ethtool \
            iperf3 \
            iproute \
            iptables \
            iputils \
            dhcp-client \
            kea \
            openssh-clients \
            procps-ng \
            python3 \
            radvd \
            tcpdump \
            wireshark-cli \
            udhcpc-script

        for svc in kea-dhcp4 kea-dhcp6 radvd; do
            if systemctl is-enabled "${svc}" >/dev/null 2>&1 || systemctl is-active "${svc}" >/dev/null 2>&1; then
                systemctl disable --now "${svc}" 2>/dev/null || true
            fi
        done

        printf '\nAll dependencies installed successfully!\n'
    else
        printf 'WARNING: Unsupported package manager. Please manually install:\n'
        printf '  %s\n' "${REQUIRED_PACKAGES[*]}"
        exit 1
    fi

    printf '==============================================================================\n'
    printf 'You are ready to run the IPv6 gateway lab!\n'
    printf '==============================================================================\n'
}

main "$@"
