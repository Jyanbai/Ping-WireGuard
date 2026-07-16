#!/usr/bin/env bash
# WireGuard 客户端配置展示、导出与终端二维码。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

export_client_config() {
    local timestamp destination suffix=0
    [[ -s $PING_WG_CLIENT_CONFIG ]] || {
        log_error "尚未生成客户端配置：${PING_WG_CLIENT_CONFIG}"
        return 1
    }

    if [[ ${PING_WG_TEST_MODE:-0} == 1 ]]; then
        mkdir -p "$PING_WG_CLIENT_EXPORT_DIR" || return 1
    else
        install -d -m 0700 "$PING_WG_CLIENT_EXPORT_DIR" || return 1
    fi
    timestamp=$(date +%Y%m%d_%H%M%S)
    destination="${PING_WG_CLIENT_EXPORT_DIR%/}/ping-wireguard-client_${timestamp}.conf"
    while [[ -e $destination ]]; do
        ((suffix += 1))
        destination="${PING_WG_CLIENT_EXPORT_DIR%/}/ping-wireguard-client_${timestamp}_${suffix}.conf"
    done
    umask 077
    if [[ ${PING_WG_TEST_MODE:-0} == 1 ]]; then
        cp "$PING_WG_CLIENT_CONFIG" "$destination" || return 1
    else
        install -m 0600 "$PING_WG_CLIENT_CONFIG" "$destination" || return 1
    fi
    EXPORTED_CLIENT_CONFIG=$destination
}

show_client_config() {
    export_client_config || return 1

    printf '\n========== WireGuard 客户端配置 ==========\n\n'
    printf '【配置文件】\n  已保存: %s\n\n' "$EXPORTED_CLIENT_CONFIG"
    printf '【客户端配置】（包含私钥，请勿公开分享）\n\n'
    cat "$PING_WG_CLIENT_CONFIG"
    printf '\n【二维码】\n'
    if command_exists qrencode; then
        printf '使用 WireGuard Android/iOS 客户端扫描下方二维码导入：\n\n'
        if ! qrencode -t ANSIUTF8 -l L -m 1 < "$PING_WG_CLIENT_CONFIG"; then
            log_warn "二维码生成失败，仍可手动导入上方配置文件。"
        fi
    else
        log_warn "未安装 qrencode，无法显示二维码；仍可手动导入上方配置文件。"
        printf 'Debian/Ubuntu: apt install qrencode\n'
        printf 'CentOS/Rocky:  dnf install qrencode\n'
        printf 'Alpine:       apk add libqrencode-tools\n'
    fi
    printf '\n【导入方式】\n'
    printf '  手机：WireGuard → 添加隧道 → 扫描二维码\n'
    printf '  电脑：安全复制 %s 后导入 WireGuard 客户端\n' "$EXPORTED_CLIENT_CONFIG"
    printf '\n说明：WireGuard 没有通用分享链接，二维码内容就是完整客户端 .conf。\n'
}
