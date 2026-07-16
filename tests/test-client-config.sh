#!/usr/bin/env bash
# 客户端配置导出、二维码输出与无 qrencode 降级测试。

set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d "${ROOT_DIR}/.test-client.XXXXXX")
trap 'rm -rf -- "$TEST_TMP"' EXIT

export NO_COLOR=1
export PING_WG_TEST_MODE=1
export PING_WG_LIB_DIR=$ROOT_DIR
export PING_WG_CONFIG_DIR=$TEST_TMP/etc
export PING_WG_CLIENT_CONFIG=$TEST_TMP/etc/client.conf
export PING_WG_CLIENT_EXPORT_DIR=$TEST_TMP/export

# shellcheck source=../scripts/client.sh
. "$ROOT_DIR/scripts/client.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $(uri_encode "a b+'/" ) == 'a%20b%2B%27%2F' ]] || fail 'URI 百分号编码边界错误'
mkdir -p "$PING_WG_CONFIG_DIR"
printf '%s\n' \
    '[Interface]' \
    'PrivateKey = TEST+PRIVATE/KEY=' \
    'Address = 10.66.66.2/32' \
    '' \
    '[Peer]' \
    'PublicKey = TEST+PUBLIC/KEY=' \
    'PresharedKey = TEST+PSK/=' \
    'Endpoint = 203.0.113.1:51820' > "$PING_WG_CLIENT_CONFIG"

QR_CAPTURE=$TEST_TMP/qr-input
qrencode() {
    cat > "$QR_CAPTURE"
    printf 'FAKE_QR_OUTPUT\n'
}

output=$(show_client_config 2>&1)
[[ $output == *FAKE_QR_OUTPUT* ]] || fail '未调用 qrencode 输出二维码'
[[ $output == *'包含私钥，请勿公开分享'* ]] || fail '缺少私钥安全提示'
[[ $output == *'wg://203.0.113.1:51820/'* ]] || fail '未生成 wg:// 分享链接'
[[ $output == *'pk=TEST%2BPRIVATE%2FKEY%3D'* ]] || fail '分享链接私钥未正确编码'
[[ $output == *'peer_pk=TEST%2BPUBLIC%2FKEY%3D'* ]] || fail '分享链接服务端公钥未正确编码'
[[ $output == *'pre_shared_key=TEST%2BPSK%2F%3D'* ]] || fail '分享链接 PSK 未正确编码'
cmp -s "$PING_WG_CLIENT_CONFIG" "$QR_CAPTURE" || fail '二维码内容不是完整客户端配置'
exported=$(find "$PING_WG_CLIENT_EXPORT_DIR" -maxdepth 1 -type f -name 'ping-wireguard-client_*.conf' | head -n1)
[[ -n $exported ]] || fail '未生成时间戳客户端配置'
cmp -s "$PING_WG_CLIENT_CONFIG" "$exported" || fail '导出配置内容不一致'

unset -f qrencode
command_exists() { [[ $1 != qrencode ]] && command -v "$1" >/dev/null 2>&1; }
fallback=$(show_client_config 2>&1)
[[ $fallback == *'未安装 qrencode'* ]] || fail '缺少 qrencode 降级提示'
[[ $fallback == *'PrivateKey = TEST+PRIVATE/KEY='* ]] || fail '降级时未显示客户端配置'

# shellcheck source=../ping-wg.sh
. "$ROOT_DIR/ping-wg.sh"
main_menu() { printf 'MENU_OK\n'; }
[[ $(dispatch_command) == MENU_OK ]] || fail '无参数执行未进入管理菜单'

printf 'PASS: 客户端配置导出与二维码测试通过\n'
