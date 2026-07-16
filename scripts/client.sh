#!/usr/bin/env bash
# WireGuard 客户端配置展示、导出与终端二维码。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

trim_client_value() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

client_config_value() {
    local wanted_section=$1 wanted_key=$2 section='' line key value
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if [[ $line =~ ^\[([^]]+)\]$ ]]; then
            section=${BASH_REMATCH[1]}
            continue
        fi
        [[ $section == "$wanted_section" && $line == *=* ]] || continue
        key=$(trim_client_value "${line%%=*}")
        [[ $key == "$wanted_key" ]] || continue
        value=$(trim_client_value "${line#*=}")
        printf '%s' "$value"
        return 0
    done < "$PING_WG_CLIENT_CONFIG"
    return 1
}

uri_encode() {
    local LC_ALL=C input=$1 output='' char i hex
    for ((i=0; i<${#input}; i++)); do
        char=${input:i:1}
        case "$char" in
            [A-Za-z0-9._~-]) output+=$char ;;
            *) printf -v hex '%%%02X' "'$char"; output+=$hex ;;
        esac
    done
    printf '%s' "$output"
}

generate_wg_share_link() {
    local private_key address peer_public_key endpoint mtu preshared_key link
    private_key=$(client_config_value Interface PrivateKey) || return 1
    address=$(client_config_value Interface Address) || return 1
    mtu=$(client_config_value Interface MTU 2>/dev/null || printf '1380')
    peer_public_key=$(client_config_value Peer PublicKey) || return 1
    endpoint=$(client_config_value Peer Endpoint) || return 1
    preshared_key=$(client_config_value Peer PresharedKey 2>/dev/null || true)

    link="wg://${endpoint}/?pk=$(uri_encode "$private_key")"
    link+="&local_address=$(uri_encode "$address")"
    link+="&peer_pk=$(uri_encode "$peer_public_key")"
    [[ -z $preshared_key ]] || link+="&pre_shared_key=$(uri_encode "$preshared_key")"
    link+="&mtu=$(uri_encode "$mtu")&reserved=0,0,0#Ping-WireGuard"
    printf '%s' "$link"
}

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
    local share_link
    share_link=$(generate_wg_share_link) || {
        log_error "客户端配置字段不完整，无法生成 WireGuard 分享链接。"
        return 1
    }
    export_client_config || return 1

    printf '\n========== WireGuard 客户端配置 ==========\n\n'
    printf '【WireGuard 分享链接】（包含私钥；兼容 Hiddify 等支持 wg:// 的客户端）\n%s\n\n' "$share_link"
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
    printf '  Hiddify：从剪贴板导入上方 wg:// 链接\n'
    printf '\n说明：wg:// 不是 WireGuard 官方通用标准；官方客户端请使用 .conf 或二维码。\n'
}
