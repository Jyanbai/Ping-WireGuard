#!/usr/bin/env bash
# 安装后的统一管理入口：/usr/local/bin/ping-wg

set -uo pipefail
SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ -r /usr/local/lib/ping-wireguard/scripts/common.sh ]]; then
    LIB_DIR=/usr/local/lib/ping-wireguard
else
    LIB_DIR=$SELF_DIR
fi

# shellcheck source=scripts/common.sh
. "${LIB_DIR}/scripts/common.sh"
# shellcheck source=scripts/import-node.sh
. "${LIB_DIR}/scripts/import-node.sh"
# shellcheck source=scripts/wg.sh
. "${LIB_DIR}/scripts/wg.sh"
# shellcheck source=scripts/client.sh
. "${LIB_DIR}/scripts/client.sh"
# shellcheck source=scripts/singbox.sh
. "${LIB_DIR}/scripts/singbox.sh"
# shellcheck source=scripts/services.sh
. "${LIB_DIR}/scripts/services.sh"

service_state() {
    local service=$1
    detect_init
    if [[ $INIT_SYSTEM == systemd ]]; then
        if systemctl is-active --quiet "$service" 2>/dev/null; then printf 'active'; else printf 'inactive'; fi
    else
        rc-service "$service" status >/dev/null 2>&1 && printf 'started' || printf 'stopped'
    fi
}

action_install() {
    local installer
    if [[ -x ${LIB_DIR}/install.sh ]]; then installer=${LIB_DIR}/install.sh; else installer=${SELF_DIR}/install.sh; fi
    [[ -x $installer ]] || { log_error "找不到 install.sh，请在完整项目目录中执行安装。"; return 1; }
    "$installer"
}

action_import() {
    local uri
    read -r -p "请粘贴 vless:// 或 ss:// 链接：" uri
    import_node_uri "$uri" || return 1
    if confirm "是否立即切换到新节点？"; then
        set_current_node "$IMPORTED_NODE_ID"
    else
        log_info "节点已保存，可稍后从菜单切换。"
    fi
}

action_status() {
    printf '\n%s当前节点%s\n' "$C_BOLD" "$C_RESET"
    show_current_node
    printf '\n%s服务状态%s\n' "$C_BOLD" "$C_RESET"
    printf 'WireGuard：%s\nsing-box：%s\n' "$(service_state ping-wireguard-wg)" "$(service_state ping-wireguard-singbox)"
    if command_exists wg; then
        printf '\n%sWireGuard 运行信息%s\n' "$C_BOLD" "$C_RESET"
        wg show "${WG_INTERFACE:-wg0}" 2>/dev/null || printf '接口尚未启动。\n'
    fi
}

action_restart() {
    load_settings || { log_error "尚未安装。"; return 1; }
    service_restart ping-wireguard-wg
    service_restart ping-wireguard-singbox
    log_ok "服务已重启。"
}

action_client_config() {
    show_client_config
}

action_logs() {
    detect_init
    if [[ $INIT_SYSTEM == systemd ]]; then
        journalctl -u ping-wireguard-wg -u ping-wireguard-singbox --no-pager -n 100
    else
        printf '%sOpenRC sing-box 日志%s\n' "$C_BOLD" "$C_RESET"
        if [[ -r ${PING_WG_LOG_DIR}/sing-box.log ]]; then tail -n 100 "${PING_WG_LOG_DIR}/sing-box.log"; fi
        if [[ -r ${PING_WG_LOG_DIR}/sing-box.err.log ]]; then tail -n 100 "${PING_WG_LOG_DIR}/sing-box.err.log"; fi
        rc-service ping-wireguard-wg status || true
        rc-service ping-wireguard-singbox status || true
    fi
}

action_reconfigure() {
    local installer
    installer=${LIB_DIR}/install.sh
    [[ -x $installer ]] || { log_error "缺少已安装的 install.sh。"; return 1; }
    "$installer" --reconfigure
}

action_uninstall() {
    confirm "确认卸载 Ping-WireGuard？节点和客户端密钥也会删除" || return 0
    load_settings || default_settings
    "${LIB_DIR}/scripts/firewall.sh" down 2>/dev/null || true
    remove_services
    remove_ip_forwarding
    [[ $PING_WG_CONFIG_DIR == /etc/ping-wireguard ]] && rm -rf -- "$PING_WG_CONFIG_DIR"
    [[ $PING_WG_STATE_DIR == /var/lib/ping-wireguard ]] && rm -rf -- "$PING_WG_STATE_DIR"
    [[ $PING_WG_LOG_DIR == /var/log/ping-wireguard ]] && rm -rf -- "$PING_WG_LOG_DIR"
    [[ $PING_WG_LIB_DIR == /usr/local/lib/ping-wireguard ]] && rm -rf -- "$PING_WG_LIB_DIR"
    [[ $PING_WG_WG_CONFIG == /etc/wireguard/wg0.conf ]] && rm -f -- "$PING_WG_WG_CONFIG"
    rm -f /usr/local/bin/ping-wg
    log_ok "项目文件和配置已卸载。WireGuard/sing-box 软件包予以保留，避免影响其他服务。"
}

print_menu() {
    clear 2>/dev/null || true
    printf '%sPing-WireGuard 管理菜单%s  v%s\n\n' "$C_BOLD" "$C_RESET" "$PROJECT_VERSION"
    printf '  1. 一键安装\n'
    printf '  2. 导入外部节点\n'
    printf '  3. 查看当前节点与状态\n'
    printf '  4. 切换出站节点\n'
    printf '  5. 查看客户端配置 / 二维码\n'
    printf '  6. 重启服务\n'
    printf '  7. 查看日志\n'
    printf '  8. 重新配置\n'
    printf '  9. 卸载\n'
    printf '  10. 退出\n\n'
    printf '快捷命令：ping-wg show\n\n'
}

main_menu() {
    require_root; require_bash4
    local choice
    while true; do
        load_settings 2>/dev/null || default_settings
        print_menu
        read -r -p "请输入选项 [1-10]：" choice || return 0
        printf '\n'
        case "$choice" in
            1) action_install ;;
            2) action_import ;;
            3) action_status ;;
            4) select_node_interactive ;;
            5) action_client_config ;;
            6) action_restart ;;
            7) action_logs ;;
            8) action_reconfigure ;;
            9) action_uninstall; return 0 ;;
            10) return 0 ;;
            *) log_error "无效选项，请输入 1 到 10。" ;;
        esac
        pause_menu
    done
}

dispatch_command() {
    local command_name=${1:-}
    case ${command_name,,} in
        '') main_menu ;;
        show|client-config|qr|--show) require_root; require_bash4; action_client_config ;;
        *) log_error "未知命令：$1（可用命令：show）"; exit 2 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    dispatch_command "$@"
fi
