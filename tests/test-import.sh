#!/usr/bin/env bash
# 解析器与模板渲染的回归测试；不需要 root，不改系统配置。

set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${ROOT_DIR}/.test.XXXXXX")
trap 'rm -rf -- "$TEST_TMP"' EXIT

export NO_COLOR=1
export PING_WG_TEST_MODE=1
export PING_WG_LIB_DIR=$ROOT_DIR
export PING_WG_CONFIG_DIR=$TEST_TMP/etc
export PING_WG_STATE_DIR=$TEST_TMP/state
export PING_WG_LOG_DIR=$TEST_TMP/log
export PING_WG_NODES_DIR=$TEST_TMP/etc/nodes
export PING_WG_SETTINGS_FILE=$TEST_TMP/etc/settings.conf
export PING_WG_CURRENT_FILE=$TEST_TMP/etc/current-node
export PING_WG_INDEX_FILE=$TEST_TMP/etc/nodes.tsv
export PING_WG_SB_CONFIG=$TEST_TMP/etc/sing-box.json
export PING_WG_WG_CONFIG=$TEST_TMP/wg0.conf
export PING_WG_CLIENT_CONFIG=$TEST_TMP/etc/client.conf
export PING_WG_TEMPLATE=$ROOT_DIR/templates/sing-box.json.template

# shellcheck source=../scripts/import-node.sh
. "$ROOT_DIR/scripts/import-node.sh"
# shellcheck source=../scripts/singbox.sh
. "$ROOT_DIR/scripts/singbox.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "期望 [$2]，实际 [$1]"; }
assert_has() { [[ $1 == *"$2"* ]] || fail "缺少片段 [$2]：$1"; }

assert_eq "$(ipv4_network_cidr 10.66.66.1/24)" '10.66.66.0/24'
is_non_public_ipv4 192.168.50.10 || fail '未识别 RFC1918 私网地址'
if is_non_public_ipv4 203.0.113.10; then fail '误把公网格式地址识别为非公网'; fi
valid_endpoint_host 203.0.113.10 || fail '公网 IPv4 Endpoint 被拒绝'
if valid_endpoint_host 203.0.113.10:40004; then fail 'Endpoint 不应允许重复附加端口'; fi

parse_node_uri 'vless://11111111-1111-4111-8111-111111111111@example.com:443?encryption=none&security=reality&sni=www.cloudflare.com&fp=chrome&pbk=abcDEF_123&sid=0123&type=grpc&serviceName=svc%2Fname#Hong%20Kong'
assert_eq "$PARSED_TYPE" vless
assert_eq "$PARSED_NAME" 'Hong Kong'
assert_has "$PARSED_JSON" '"reality":{"enabled":true'
assert_has "$PARSED_JSON" '"service_name":"svc/name"'

parse_node_uri 'vless://22222222-2222-4222-8222-222222222222@example.org:80?type=ws&security=none&host=cdn.example.org&path=%2Fws%3Fed%3D2048#WS'
assert_has "$PARSED_JSON" '"type":"ws"'
assert_has "$PARSED_JSON" '"path":"/ws?ed=2048"'
assert_has "$PARSED_JSON" '"Host":"cdn.example.org"'

userinfo=$(printf '%s' 'aes-256-gcm:p@ss:word' | base64 | tr -d '\r\n=')
parse_node_uri "ss://${userinfo}@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com#Tokyo"
assert_eq "$PARSED_TYPE" shadowsocks
assert_has "$PARSED_JSON" '"password":"p@ss:word"'
assert_has "$PARSED_JSON" '"plugin_opts":"obfs=http;obfs-host=cdn.example.com"'

legacy=$(printf '%s' 'chacha20-ietf-poly1305:secret@[2001:db8::1]:443' | base64 | tr -d '\r\n=')
parse_node_uri "ss://${legacy}#IPv6"
assert_eq "$PARSED_SERVER" '2001:db8::1'
assert_eq "$PARSED_PORT" 443

if parse_node_uri 'vless://bad@example.com:443?security=none' 2>/dev/null; then fail '无效 UUID 未被拒绝'; fi
if parse_node_uri 'ss://bm90LWEtY2lwaGVyOnBhc3M@example.com:443' 2>/dev/null; then fail '无效 SS method 未被拒绝'; fi
if parse_node_uri 'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=reality' 2>/dev/null; then fail '缺少 Reality 公钥未被拒绝'; fi
if parse_node_uri 'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=tls&type=tcp&headerType=http' 2>/dev/null; then fail '不支持的 TCP headerType 未被拒绝'; fi
if parse_node_uri 'vless://11111111-1111-4111-8111-111111111111@example.com:443?security=none&flow=xtls-rprx-vision' 2>/dev/null; then fail '无 TLS 的 Vision 未被拒绝'; fi

parse_node_uri 'vless://44444444-4444-4444-8444-444444444444@example.net:00443?security=tls'
assert_eq "$PARSED_PORT" 443

ensure_directories
default_settings
SERVER_ENDPOINT=203.0.113.1
write_settings
parse_node_uri 'vless://33333333-3333-4333-8333-333333333333@node.example:443?security=tls&sni=node.example&type=ws&path=%2Fproxy#Current'
node_id=$(store_parsed_node 'test-uri')
generate_singbox_config "$node_id"
grep -q '"include_interface": \["wg0"\]' "$PING_WG_SB_CONFIG" || fail '模板未限制 wg0'
grep -q '"final": "proxy"' "$PING_WG_SB_CONFIG" || fail '模板 final 不正确'
if grep -q '__[A-Z_]*__' "$PING_WG_SB_CONFIG"; then fail '模板仍有未替换占位符'; fi

if command -v python >/dev/null 2>&1; then
    python -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$PING_WG_SB_CONFIG"
fi

generate_singbox_config
grep -q '"type":"direct","tag":"proxy"' "$PING_WG_SB_CONFIG" || fail '未选择节点时没有使用本机直连'
assert_has "$(show_current_node)" '当前出口：本机直连'

service_do() { return 0; }
refresh_project_firewall() { return 0; }
service_restart() { return 1; }
if set_current_node "$node_id" 2>/dev/null; then fail '代理切换重启失败时未返回错误'; fi
if current_node_id >/dev/null 2>&1; then fail '代理切换失败后未回滚到直连'; fi
grep -q '"type":"direct","tag":"proxy"' "$PING_WG_SB_CONFIG" || fail '代理切换失败后配置未回滚'

service_restart() { return 0; }
set_current_node "$node_id"
assert_eq "$(current_node_id)" "$node_id"

refresh_project_firewall() { return 1; }
if set_direct_outbound 2>/dev/null; then fail '直连切换重启失败时未返回错误'; fi
assert_eq "$(current_node_id)" "$node_id"
grep -q '"type":"vless"' "$PING_WG_SB_CONFIG" || fail '直连切换失败后未回滚代理配置'

refresh_project_firewall() { return 0; }
set_direct_outbound
if current_node_id >/dev/null 2>&1; then fail '切回直连后仍保留 current-node'; fi
grep -q '"type":"direct","tag":"proxy"' "$PING_WG_SB_CONFIG" || fail '切回直连后配置不正确'
assert_has "$(list_nodes)" '本机直连'

printf 'PASS: import-node 与 sing-box 模板测试通过\n'
