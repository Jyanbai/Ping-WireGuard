#!/usr/bin/env bash
# WireGuard 入站与转发规则：直连时做 MASQUERADE，外部节点模式交给 sing-box TUN。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

firewall_up_nft() {
    local subnet nat_rule=''
    subnet=$(ipv4_network_cidr "$WG_SERVER_ADDRESS") || return 1
    using_external_node || nat_rule="ip saddr ${subnet} oifname \"${PUBLIC_INTERFACE}\" masquerade comment \"Ping-WireGuard direct\""
    nft delete table inet ping_wireguard 2>/dev/null || true
    nft delete table ip ping_wireguard 2>/dev/null || true
    nft -f - <<EOF
table ip ping_wireguard {
  chain input {
    type filter hook input priority -50; policy accept;
    udp dport ${WG_PORT} accept comment "Ping-WireGuard inbound"
  }
  chain forward {
    type filter hook forward priority -50; policy accept;
    iifname "${WG_INTERFACE}" accept comment "Ping-WireGuard clients"
    oifname "${WG_INTERFACE}" ct state established,related accept comment "Ping-WireGuard return"
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ${nat_rule}
  }
}
EOF
}

iptables_add() {
    local table=$1 chain=$2; shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -I "$chain" 1 "$@"
}

iptables_del() {
    local table=$1 chain=$2; shift 2
    while iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
        iptables -t "$table" -D "$chain" "$@" || break
    done
}

firewall_up_iptables() {
    local subnet
    subnet=$(ipv4_network_cidr "$WG_SERVER_ADDRESS") || return 1
    iptables_add filter INPUT -p udp --dport "$WG_PORT" -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_add filter FORWARD -i "$WG_INTERFACE" -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_add filter FORWARD -o "$WG_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment Ping-WireGuard -j ACCEPT
    if ! using_external_node; then
        iptables_add nat POSTROUTING -s "$subnet" -o "$PUBLIC_INTERFACE" -m comment --comment Ping-WireGuard-direct -j MASQUERADE
    fi
}

firewall_down_iptables() {
    local subnet
    subnet=$(ipv4_network_cidr "$WG_SERVER_ADDRESS") || return 1
    iptables_del filter INPUT -p udp --dport "$WG_PORT" -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_del filter FORWARD -i "$WG_INTERFACE" -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_del filter FORWARD -o "$WG_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_del nat POSTROUTING -s "$subnet" -o "$PUBLIC_INTERFACE" -m comment --comment Ping-WireGuard-direct -j MASQUERADE
}

firewall_up_firewalld() {
    local subnet rich
    subnet=$(ipv4_network_cidr "$WG_SERVER_ADDRESS") || return 1
    rich="rule family=ipv4 source address=${subnet} masquerade"
    firewall-cmd --zone=public --add-interface="$WG_INTERFACE" >/dev/null
    firewall-cmd --permanent --zone=public --add-interface="$WG_INTERFACE" >/dev/null
    firewall-cmd --zone=public --add-port="${WG_PORT}/udp" >/dev/null
    firewall-cmd --permanent --zone=public --add-port="${WG_PORT}/udp" >/dev/null
    if ! using_external_node; then
        firewall-cmd --zone=public --add-rich-rule="$rich" >/dev/null
        firewall-cmd --permanent --zone=public --add-rich-rule="$rich" >/dev/null
    fi
}

firewall_down_firewalld() {
    local subnet rich
    subnet=$(ipv4_network_cidr "$WG_SERVER_ADDRESS") || return 1
    rich="rule family=ipv4 source address=${subnet} masquerade"
    firewall-cmd --zone=public --remove-interface="$WG_INTERFACE" >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-interface="$WG_INTERFACE" >/dev/null 2>&1 || true
    firewall-cmd --zone=trusted --remove-interface="$WG_INTERFACE" >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=trusted --remove-interface="$WG_INTERFACE" >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-port="${WG_PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-port="${WG_PORT}/udp" >/dev/null 2>&1 || true
    firewall-cmd --zone=public --remove-rich-rule="$rich" >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=public --remove-rich-rule="$rich" >/dev/null 2>&1 || true
}

firewall_up() {
    load_settings || return 1
    if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall_up_firewalld
        return
    fi
    if command_exists ufw && ufw status 2>/dev/null | grep -qi 'status: active'; then
        ufw allow "${WG_PORT}/udp" >/dev/null
        ufw route allow in on "$WG_INTERFACE" >/dev/null
        ufw route allow out on "$WG_INTERFACE" >/dev/null
    fi
    if command_exists iptables; then firewall_up_iptables; else firewall_up_nft; fi
}

firewall_down() {
    load_settings || return 0
    if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall_down_firewalld
    fi
    if command_exists ufw && ufw status 2>/dev/null | grep -qi 'status: active'; then
        ufw --force delete allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
        ufw --force route delete allow in on "$WG_INTERFACE" >/dev/null 2>&1 || true
        ufw --force route delete allow out on "$WG_INTERFACE" >/dev/null 2>&1 || true
    fi
    if command_exists nft; then
        nft delete table inet ping_wireguard 2>/dev/null || true
        nft delete table ip ping_wireguard 2>/dev/null || true
    fi
    command_exists iptables && firewall_down_iptables || true
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case ${1:-} in
        up) require_root; firewall_up ;;
        down) require_root; firewall_down ;;
        *) printf '用法：%s {up|down}\n' "$0" >&2; exit 2 ;;
    esac
fi
