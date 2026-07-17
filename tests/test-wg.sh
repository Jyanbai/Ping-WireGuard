#!/usr/bin/env bash
# WireGuard 配置、PSK 与直连/代理防火墙规则测试；不改系统配置。

set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${ROOT_DIR}/.test-wg.XXXXXX")
trap 'rm -rf -- "$TEST_TMP"' EXIT

export NO_COLOR=1
export PING_WG_TEST_MODE=1
export PING_WG_LIB_DIR=$ROOT_DIR
export PING_WG_CONFIG_DIR=$TEST_TMP/etc
export PING_WG_NODES_DIR=$TEST_TMP/etc/nodes
export PING_WG_SETTINGS_FILE=$TEST_TMP/etc/settings.conf
export PING_WG_CURRENT_FILE=$TEST_TMP/etc/current-node
export PING_WG_WG_CONFIG=$TEST_TMP/wireguard/wg0.conf
export PING_WG_CLIENT_CONFIG=$TEST_TMP/etc/client.conf

# shellcheck source=../scripts/wg.sh
. "$ROOT_DIR/scripts/wg.sh"
# shellcheck source=../scripts/firewall.sh
. "$ROOT_DIR/scripts/firewall.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

WG_GEN_COUNT=0
WG_PSK_COUNT=0
wg() {
    case ${1:-} in
        genkey)
            ((WG_GEN_COUNT += 1))
            printf 'PRIVATE_KEY_%s\n' "$WG_GEN_COUNT"
            ;;
        pubkey)
            local private
            IFS= read -r private
            printf 'PUBLIC_%s\n' "$private"
            ;;
        genpsk)
            ((WG_PSK_COUNT += 1))
            printf 'PRESHARED_KEY_%s\n' "$WG_PSK_COUNT"
            ;;
        *) return 1 ;;
    esac
}

ensure_directories
default_settings
WG_PORT=40004
SERVER_ENDPOINT=203.0.113.10
PUBLIC_INTERFACE=eth0
write_settings
generate_wg_config

grep -q '^ListenPort = 40004$' "$PING_WG_WG_CONFIG" || fail '服务端监听端口错误'
grep -q '^Endpoint = 203.0.113.10:40004$' "$PING_WG_CLIENT_CONFIG" || fail '客户端入口 Endpoint 错误'
[[ $(grep -h '^PresharedKey = PRESHARED_KEY_1$' "$PING_WG_WG_CONFIG" "$PING_WG_CLIENT_CONFIG" | wc -l) -eq 2 ]] || \
    fail '服务端和客户端没有使用相同 PSK'
generate_wg_config
[[ $WG_PSK_COUNT -eq 1 ]] || fail '重新配置时不应轮换现有 PSK'

IPTABLES_CAPTURE=$TEST_TMP/iptables.log
iptables() {
    printf '%s\n' "$*" >> "$IPTABLES_CAPTURE"
    [[ " $* " == *' -C '* ]] && return 1
    return 0
}

firewall_up_iptables
grep -q -- '-t nat -I POSTROUTING.*-s 10.66.66.0/24.*-o eth0.*MASQUERADE' "$IPTABLES_CAPTURE" || \
    fail '直连模式没有添加限定网段的 MASQUERADE'
if grep -q -- '-I FORWARD 1.*Ping-WireGuard-proxy-guard.*REJECT' "$IPTABLES_CAPTURE"; then
    fail '直连模式不应添加代理防直连规则'
fi

mkdir -p "$PING_WG_NODES_DIR"
printf '{}\n' > "$PING_WG_NODES_DIR/proxy.json"
printf 'proxy\n' > "$PING_WG_CURRENT_FILE"
: > "$IPTABLES_CAPTURE"
firewall_up_iptables
if grep -q -- '-I POSTROUTING.*MASQUERADE' "$IPTABLES_CAPTURE"; then fail '外部节点模式不应添加直连 MASQUERADE'; fi
grep -q -- '-I FORWARD 1.*-i wg0.*-o eth0.*Ping-WireGuard-proxy-guard.*REJECT' "$IPTABLES_CAPTURE" || \
    fail '外部节点模式没有添加防直连规则'

NFT_CAPTURE=$TEST_TMP/nft.rules
nft() {
    if [[ ${1:-} == delete ]]; then return 0; fi
    if [[ ${1:-} == -f && ${2:-} == - ]]; then command cat > "$NFT_CAPTURE"; return 0; fi
    return 1
}

rm -f "$PING_WG_CURRENT_FILE"
firewall_up_nft
grep -q 'masquerade comment "Ping-WireGuard direct"' "$NFT_CAPTURE" || fail 'nft 直连模式没有 MASQUERADE'
if grep -q 'Ping-WireGuard proxy guard' "$NFT_CAPTURE"; then fail 'nft 直连模式不应添加防直连规则'; fi

printf 'proxy\n' > "$PING_WG_CURRENT_FILE"
firewall_up_nft
grep -q 'reject comment "Ping-WireGuard proxy guard"' "$NFT_CAPTURE" || fail 'nft 外部节点模式没有防直连规则'
if grep -q 'masquerade comment "Ping-WireGuard direct"' "$NFT_CAPTURE"; then fail 'nft 外部节点模式不应保留 MASQUERADE'; fi

printf 'PASS: WireGuard PSK、Endpoint 与防火墙模式测试通过\n'
