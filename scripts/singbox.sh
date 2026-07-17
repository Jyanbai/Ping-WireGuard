#!/usr/bin/env bash
# sing-box 配置生成、节点列表与事务式切换。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

singbox_binary() {
    command -v sing-box 2>/dev/null || {
        [[ -x /usr/local/bin/sing-box ]] && printf '%s' /usr/local/bin/sing-box && return 0
        [[ -x /usr/bin/sing-box ]] && printf '%s' /usr/bin/sing-box && return 0
        return 1
    }
}

current_node_id() {
    current_node_setting
}

node_record() {
    local wanted=$1 id type name server port
    [[ -r $PING_WG_INDEX_FILE ]] || return 1
    while IFS=$'\t' read -r id type name server port; do
        [[ $id == "$wanted" ]] || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$type" "$name" "$server" "$port"
        return 0
    done < "$PING_WG_INDEX_FILE"
    return 1
}

list_nodes() {
    local current='' id type name server port mark
    current=$(current_node_id 2>/dev/null || true)
    printf '%-3s %-20s %-12s %-24s %s\n' '#' '名称' '类型' '服务器' '当前'
    mark=''; [[ -z $current ]] && mark='*'
    printf '%-3d %-20s %-12s %-24s %s\n' 1 '本机直连' 'direct' '服务器公网出口' "$mark"
    local n=1
    if [[ -r $PING_WG_INDEX_FILE ]]; then
        while IFS=$'\t' read -r id type name server port; do
            ((n+=1)); mark=''
            [[ $id == "$current" ]] && mark='*'
            printf '%-3d %-20.20s %-12s %-24.24s %s\n' "$n" "$name" "$type" "${server}:${port}" "$mark"
        done < "$PING_WG_INDEX_FILE"
    fi
}

render_template() {
    local outbound=$1 template=$2 target=$3 line marker value prefix suffix
    [[ -r $template ]] || { log_error "缺少 sing-box 模板：$template"; return 1; }
    : > "$target"
    while IFS= read -r line || [[ -n $line ]]; do
        for marker in __TUN_INTERFACE__ __TUN_ADDRESS__ __MTU__ __WG_INTERFACE__ __PUBLIC_INTERFACE__ __TUN_TABLE_INDEX__ __TUN_RULE_INDEX__ __OUTBOUND__; do
            [[ $line == *"$marker"* ]] || continue
            case "$marker" in
                __TUN_INTERFACE__) value=$TUN_INTERFACE ;;
                __TUN_ADDRESS__) value=$TUN_ADDRESS ;;
                __MTU__) value=$WG_MTU ;;
                __WG_INTERFACE__) value=$WG_INTERFACE ;;
                __PUBLIC_INTERFACE__) value=$PUBLIC_INTERFACE ;;
                __TUN_TABLE_INDEX__) value=$TUN_TABLE_INDEX ;;
                __TUN_RULE_INDEX__) value=$TUN_RULE_INDEX ;;
                __OUTBOUND__) value=$outbound ;;
            esac
            prefix=${line%%"$marker"*}; suffix=${line#*"$marker"}
            line=${prefix}${value}${suffix}
        done
        printf '%s\n' "$line" >> "$target"
    done < "$template"
}

generate_singbox_config() {
    local node_id=${1:-} outbound tmp sb conflict
    load_settings || { log_error "尚未完成基础配置。"; return 1; }
    conflict=$(find_tun_address_conflict "$TUN_ADDRESS" || true)
    [[ -z $conflict ]] || { log_error "TUN 地址 ${TUN_ADDRESS} 与${conflict}冲突，请先执行重新配置。"; return 1; }
    ensure_directories
    if [[ -z $node_id ]]; then node_id=$(current_node_id 2>/dev/null || printf 'direct'); fi
    if [[ $node_id == direct ]]; then
        outbound='{"type":"direct","tag":"proxy"}'
    elif [[ -n $node_id ]]; then
        [[ $node_id =~ ^[A-Za-z0-9._-]+$ && -r ${PING_WG_NODES_DIR}/${node_id}.json ]] || {
            log_error "节点不存在：$node_id"; return 1;
        }
        outbound=$(<"${PING_WG_NODES_DIR}/${node_id}.json")
    fi
    tmp=$(mktemp "${PING_WG_CONFIG_DIR}/.sing-box.XXXXXX") || return 1
    umask 077
    render_template "$outbound" "$PING_WG_TEMPLATE" "$tmp" || { rm -f "$tmp"; return 1; }
    sb=$(singbox_binary 2>/dev/null || true)
    if [[ -n $sb ]]; then
        case "$(uname -s)" in
            MINGW*|MSYS*|CYGWIN*)
                # 开发机测试：Windows 无法初始化 Linux-only auto_redirect，format 仍会校验配置结构。
                "$sb" format -c "$tmp" >/dev/null || {
                    log_error "sing-box 配置结构校验失败，旧配置保持不变。"; rm -f "$tmp"; return 1;
                }
                ;;
            *)
                "$sb" check -c "$tmp" || {
                    log_error "sing-box 配置校验失败，旧配置保持不变。"; rm -f "$tmp"; return 1;
                }
                ;;
        esac
    else
        log_warn "未找到 sing-box，暂时只生成配置，无法执行语义校验。"
    fi
    chmod 0600 "$tmp"
    mv -f "$tmp" "$PING_WG_SB_CONFIG"
}

verify_tun_runtime() {
    local attempt
    [[ ${PING_WG_TEST_MODE:-0} == 1 ]] && return 0
    command_exists ip || { log_error "缺少 iproute2，无法验证 TUN 运行状态。"; return 1; }
    for ((attempt=1; attempt<=20; attempt++)); do
        if ip link show dev "$TUN_INTERFACE" >/dev/null 2>&1 &&
           [[ -n $(ip -4 route show table "$TUN_TABLE_INDEX" 2>/dev/null) ]] &&
           ip -4 rule show 2>/dev/null | grep -Eq "(^|[[:space:]])(lookup|table)[[:space:]]+${TUN_TABLE_INDEX}([[:space:]]|$)"; then
            return 0
        fi
        sleep 0.25
    done
    log_error "sing-box 进程已启动，但 TUN 接口或策略路由未就绪。"
    return 1
}

show_tun_runtime_status() {
    local interface_state='缺失' route_state='缺失' rule_state='缺失' guard_state='缺失'
    command_exists ip && ip link show dev "$TUN_INTERFACE" >/dev/null 2>&1 && interface_state='正常'
    command_exists ip && [[ -n $(ip -4 route show table "$TUN_TABLE_INDEX" 2>/dev/null) ]] && route_state='正常'
    if command_exists ip && ip -4 rule show 2>/dev/null | grep -Eq "(^|[[:space:]])(lookup|table)[[:space:]]+${TUN_TABLE_INDEX}([[:space:]]|$)"; then
        rule_state='正常'
    fi
    if command_exists iptables && iptables -t filter -C FORWARD -i "$WG_INTERFACE" -o "$PUBLIC_INTERFACE" -m comment --comment Ping-WireGuard-proxy-guard -j REJECT 2>/dev/null; then
        guard_state='正常'
    elif command_exists nft && nft list table ip ping_wireguard 2>/dev/null | grep -q 'Ping-WireGuard proxy guard'; then
        guard_state='正常'
    fi
    printf 'TUN 接口：%s（%s，MTU %s）\n策略路由表 %s：%s\n策略规则：%s\n出口绑定：%s\n防直连保护：%s\n' \
        "$interface_state" "$TUN_ADDRESS" "$WG_MTU" "$TUN_TABLE_INDEX" "$route_state" "$rule_state" "$PUBLIC_INTERFACE" "$guard_state"
}

write_current_node_id() {
    local node_id=$1 tmp
    tmp=$(mktemp "${PING_WG_CONFIG_DIR}/.current.XXXXXX") || return 1
    printf '%s\n' "$node_id" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$PING_WG_CURRENT_FILE"
}

refresh_project_firewall() {
    local script=${PING_WG_LIB_DIR}/scripts/firewall.sh
    [[ -r $script ]] || { log_error "缺少防火墙脚本：$script"; return 1; }
    bash "$script" down || return 1
    bash "$script" up
}

activate_external_runtime() {
    # current-node 已原子写入；先切换为 fail-closed 防火墙，再启动 TUN，避免切换窗口旁路。
    refresh_project_firewall || return 1
    service_do enable ping-wireguard-singbox || return 1
    service_restart ping-wireguard-singbox || return 1
    verify_tun_runtime
}

activate_direct_runtime() {
    refresh_project_firewall || return 1
    service_do stop ping-wireguard-singbox 2>/dev/null || true
    service_do disable ping-wireguard-singbox 2>/dev/null || true
}

set_direct_outbound() {
    local old=''
    old=$(current_node_id 2>/dev/null || true)
    generate_singbox_config direct || return 1
    if ! rm -f "$PING_WG_CURRENT_FILE"; then
        log_error "无法更新出口状态，正在恢复原配置。"
        if [[ -n $old ]]; then generate_singbox_config "$old"; else generate_singbox_config direct; fi
        return 1
    fi
    if activate_direct_runtime; then
        log_ok "已切换为本机直连出口。"
        return 0
    fi
    log_error "出口运行时切换失败，正在回滚出口选择。"
    if [[ -n $old ]]; then
        generate_singbox_config "$old" && write_current_node_id "$old"
    else
        generate_singbox_config direct
    fi
    if [[ -n $old ]]; then activate_external_runtime 2>/dev/null || true; else activate_direct_runtime 2>/dev/null || true; fi
    return 1
}

set_current_node() {
    local node_id=$1 old=''
    node_record "$node_id" >/dev/null || { log_error "节点不存在：$node_id"; return 1; }
    old=$(current_node_id 2>/dev/null || true)
    generate_singbox_config "$node_id" || return 1
    if ! write_current_node_id "$node_id"; then
        log_error "无法更新出口状态，正在恢复原配置。"
        if [[ -n $old ]]; then generate_singbox_config "$old"; else generate_singbox_config direct; fi
        return 1
    fi
    if activate_external_runtime; then
        log_ok "已切换出站节点。"
        return 0
    fi
    log_error "出口运行时切换失败，正在回滚节点选择。"
    if [[ -n $old ]]; then
        generate_singbox_config "$old" && write_current_node_id "$old"
    else
        rm -f "$PING_WG_CURRENT_FILE"
        generate_singbox_config
    fi
    if [[ -n $old ]]; then activate_external_runtime 2>/dev/null || true; else activate_direct_runtime 2>/dev/null || true; fi
    return 1
}

select_node_interactive() {
    local -a ids=(direct)
    local id type name server port choice
    list_nodes
    if [[ -s $PING_WG_INDEX_FILE ]]; then
        while IFS=$'\t' read -r id type name server port; do ids+=("$id"); done < "$PING_WG_INDEX_FILE"
    fi
    read -r -p "请选择出口序号（0 取消）：" choice
    is_uint "$choice" || { log_error "请输入数字。"; return 1; }
    (( 10#$choice == 0 )) && return 0
    (( 10#$choice >= 1 && 10#$choice <= ${#ids[@]} )) || { log_error "序号超出范围。"; return 1; }
    if [[ ${ids[10#$choice-1]} == direct ]]; then
        set_direct_outbound
    else
        set_current_node "${ids[10#$choice-1]}"
    fi
}

show_current_node() {
    local id record type name server port
    id=$(current_node_id 2>/dev/null || true)
    if [[ -z $id ]]; then
        printf '当前出口：本机直连\n线路：WireGuard → 内核转发 / MASQUERADE → 服务器公网\n'
        return 0
    fi
    record=$(node_record "$id") || return 1
    IFS=$'\t' read -r _ type name server port <<< "$record"
    printf '当前出口：外部节点\n节点：%s\n协议：%s\n服务器：%s:%s\n' "$name" "$type" "$server" "$port"
}
