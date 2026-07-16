#!/usr/bin/env bash
# 仅开放 WireGuard 入站并允许 wg0 的转发；不做 NAT，出口由 sing-box 代理。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

firewall_up_nft() {
    nft delete table inet ping_wireguard 2>/dev/null || true
    nft -f - <<EOF
table inet ping_wireguard {
  chain input {
    type filter hook input priority -50; policy accept;
    udp dport ${WG_PORT} accept comment "Ping-WireGuard inbound"
  }
  chain forward {
    type filter hook forward priority -50; policy accept;
    iifname "${WG_INTERFACE}" accept comment "Ping-WireGuard clients"
    oifname "${WG_INTERFACE}" ct state established,related accept comment "Ping-WireGuard return"
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
    iptables_add filter INPUT -p udp --dport "$WG_PORT" -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_add filter FORWARD -i "$WG_INTERFACE" -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_add filter FORWARD -o "$WG_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment Ping-WireGuard -j ACCEPT
}

firewall_down_iptables() {
    iptables_del filter INPUT -p udp --dport "$WG_PORT" -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_del filter FORWARD -i "$WG_INTERFACE" -m comment --comment Ping-WireGuard -j ACCEPT
    iptables_del filter FORWARD -o "$WG_INTERFACE" -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment Ping-WireGuard -j ACCEPT
}

firewall_up() {
    load_settings || return 1
    if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --zone=trusted --add-interface="$WG_INTERFACE" >/dev/null
        firewall-cmd --permanent --zone=trusted --add-interface="$WG_INTERFACE" >/dev/null
        firewall-cmd --add-port="${WG_PORT}/udp" >/dev/null
        firewall-cmd --permanent --add-port="${WG_PORT}/udp" >/dev/null
    fi
    if command_exists ufw && ufw status 2>/dev/null | grep -qi 'status: active'; then
        ufw allow "${WG_PORT}/udp" >/dev/null
        ufw route allow in on "$WG_INTERFACE" >/dev/null
        ufw route allow out on "$WG_INTERFACE" >/dev/null
    fi
    if command_exists nft; then firewall_up_nft; else firewall_up_iptables; fi
}

firewall_down() {
    load_settings || return 0
    if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --zone=trusted --remove-interface="$WG_INTERFACE" >/dev/null 2>&1 || true
        firewall-cmd --permanent --zone=trusted --remove-interface="$WG_INTERFACE" >/dev/null 2>&1 || true
        firewall-cmd --remove-port="${WG_PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --remove-port="${WG_PORT}/udp" >/dev/null 2>&1 || true
    fi
    if command_exists ufw && ufw status 2>/dev/null | grep -qi 'status: active'; then
        ufw --force delete allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
        ufw --force route delete allow in on "$WG_INTERFACE" >/dev/null 2>&1 || true
        ufw --force route delete allow out on "$WG_INTERFACE" >/dev/null 2>&1 || true
    fi
    if command_exists nft; then nft delete table inet ping_wireguard 2>/dev/null || true; fi
    command_exists iptables && firewall_down_iptables || true
}

case ${1:-} in
    up) require_root; firewall_up ;;
    down) require_root; firewall_down ;;
    *) printf '用法：%s {up|down}\n' "$0" >&2; exit 2 ;;
esac
