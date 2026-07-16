#!/usr/bin/env bash
# WireGuard 密钥、服务端配置和客户端配置生成。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

format_endpoint() {
    local host=$1
    if [[ $host == *:* && $host != \[*\] ]]; then printf '[%s]' "$host"; else printf '%s' "$host"; fi
}

ensure_wg_keys() {
    local server_key=${PING_WG_CONFIG_DIR}/server.key client_key=${PING_WG_CONFIG_DIR}/client.key
    local preshared_key=${PING_WG_CONFIG_DIR}/client.psk
    umask 077
    [[ -s $server_key ]] || wg genkey > "$server_key"
    [[ -s $client_key ]] || wg genkey > "$client_key"
    [[ -s $preshared_key ]] || wg genpsk > "$preshared_key"
    chmod 0600 "$server_key" "$client_key" "$preshared_key"
    wg pubkey < "$server_key" > "${PING_WG_CONFIG_DIR}/server.pub"
    wg pubkey < "$client_key" > "${PING_WG_CONFIG_DIR}/client.pub"
    chmod 0600 "${PING_WG_CONFIG_DIR}/server.pub" "${PING_WG_CONFIG_DIR}/client.pub"
}

generate_wg_config() {
    local server_private server_public client_private client_public client_psk endpoint tmp
    load_settings || { log_error "尚未完成基础配置。"; return 1; }
    [[ -n $SERVER_ENDPOINT ]] || { log_error "服务器公网地址不能为空。"; return 1; }
    ensure_directories
    if [[ ${PING_WG_TEST_MODE:-0} == 1 ]]; then
        mkdir -p "$(dirname "$PING_WG_WG_CONFIG")"
    else
        install -d -m 0700 "$(dirname "$PING_WG_WG_CONFIG")"
    fi
    if [[ -s $PING_WG_WG_CONFIG ]] && ! grep -q '^# Managed by Ping-WireGuard$' "$PING_WG_WG_CONFIG"; then
        if command_exists ip && ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
            log_error "检测到既有 ${WG_INTERFACE} 接口正在运行，为避免中断现有 WireGuard 业务，安装已停止。"
            return 1
        fi
        local backup="${PING_WG_WG_CONFIG}.ping-wg.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$PING_WG_WG_CONFIG" "$backup"
        log_warn "发现既有 WireGuard 配置，已备份到：$backup"
    fi
    ensure_wg_keys || return 1
    server_private=$(<"${PING_WG_CONFIG_DIR}/server.key")
    server_public=$(<"${PING_WG_CONFIG_DIR}/server.pub")
    client_private=$(<"${PING_WG_CONFIG_DIR}/client.key")
    client_public=$(<"${PING_WG_CONFIG_DIR}/client.pub")
    client_psk=$(<"${PING_WG_CONFIG_DIR}/client.psk")
    endpoint=$(format_endpoint "$SERVER_ENDPOINT")

    tmp=$(mktemp "$(dirname "$PING_WG_WG_CONFIG")/.wg0.XXXXXX") || return 1
    umask 077
    {
        printf '# Managed by Ping-WireGuard\n[Interface]\nAddress = %s\nListenPort = %s\nPrivateKey = %s\nMTU = %s\n' \
            "$WG_SERVER_ADDRESS" "$WG_PORT" "$server_private" "$WG_MTU"
        printf 'PostUp = %s/scripts/firewall.sh up\n' "$PING_WG_LIB_DIR"
        printf 'PostDown = %s/scripts/firewall.sh down\n\n' "$PING_WG_LIB_DIR"
        printf '# %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s\n' \
            "$CLIENT_NAME" "$client_public" "$client_psk" "$WG_CLIENT_ADDRESS"
    } > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$PING_WG_WG_CONFIG"

    tmp=$(mktemp "${PING_WG_CONFIG_DIR}/.client.XXXXXX") || return 1
    {
        printf '[Interface]\nPrivateKey = %s\nAddress = %s\nDNS = %s\nMTU = %s\n\n' \
            "$client_private" "$WG_CLIENT_ADDRESS" "$WG_CLIENT_DNS" "$WG_MTU"
        printf '[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
            "$server_public" "$client_psk" "$endpoint" "$WG_PORT"
    } > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$PING_WG_CLIENT_CONFIG"
    log_ok "WireGuard 配置已生成；客户端配置：$PING_WG_CLIENT_CONFIG"
}

configure_ip_forwarding() {
    local target=/etc/sysctl.d/99-ping-wireguard.conf
    {
        printf '# Managed by Ping-WireGuard\n'
        printf 'net.ipv4.ip_forward = 1\n'
        printf 'net.ipv6.conf.all.forwarding = 1\n'
    } > "$target"
    sysctl -p "$target" >/dev/null
}

remove_ip_forwarding() {
    rm -f /etc/sysctl.d/99-ping-wireguard.conf
}
