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
    [[ -r $PING_WG_CURRENT_FILE ]] || return 1
    local id
    IFS= read -r id < "$PING_WG_CURRENT_FILE"
    [[ $id =~ ^[A-Za-z0-9._-]+$ && -r ${PING_WG_NODES_DIR}/${id}.json ]] || return 1
    printf '%s' "$id"
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
    if [[ ! -s $PING_WG_INDEX_FILE ]]; then
        printf '尚未导入外部节点。\n'
        return 0
    fi
    printf '%-3s %-20s %-12s %-24s %s\n' '#' '名称' '类型' '服务器' '当前'
    local n=0
    while IFS=$'\t' read -r id type name server port; do
        ((n+=1)); mark=''
        [[ $id == "$current" ]] && mark='*'
        printf '%-3d %-20.20s %-12s %-24.24s %s\n' "$n" "$name" "$type" "${server}:${port}" "$mark"
    done < "$PING_WG_INDEX_FILE"
}

render_template() {
    local outbound=$1 template=$2 target=$3 line marker value prefix suffix
    [[ -r $template ]] || { log_error "缺少 sing-box 模板：$template"; return 1; }
    : > "$target"
    while IFS= read -r line || [[ -n $line ]]; do
        for marker in __TUN_INTERFACE__ __TUN_ADDRESS__ __MTU__ __WG_INTERFACE__ __OUTBOUND__; do
            [[ $line == *"$marker"* ]] || continue
            case "$marker" in
                __TUN_INTERFACE__) value=$TUN_INTERFACE ;;
                __TUN_ADDRESS__) value=$TUN_ADDRESS ;;
                __MTU__) value=$WG_MTU ;;
                __WG_INTERFACE__) value=$WG_INTERFACE ;;
                __OUTBOUND__) value=$outbound ;;
            esac
            prefix=${line%%"$marker"*}; suffix=${line#*"$marker"}
            line=${prefix}${value}${suffix}
        done
        printf '%s\n' "$line" >> "$target"
    done < "$template"
}

generate_singbox_config() {
    local node_id=${1:-} outbound tmp sb
    load_settings || { log_error "尚未完成基础配置。"; return 1; }
    ensure_directories
    if [[ -z $node_id ]]; then node_id=$(current_node_id 2>/dev/null || true); fi
    if [[ -n $node_id ]]; then
        [[ $node_id =~ ^[A-Za-z0-9._-]+$ && -r ${PING_WG_NODES_DIR}/${node_id}.json ]] || {
            log_error "节点不存在：$node_id"; return 1;
        }
        outbound=$(<"${PING_WG_NODES_DIR}/${node_id}.json")
    else
        # 未导入节点时保持服务可启动并 fail closed，避免客户端意外直连泄漏出口。
        outbound='{"type":"block","tag":"proxy"}'
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

set_current_node() {
    local node_id=$1 tmp old=''
    node_record "$node_id" >/dev/null || { log_error "节点不存在：$node_id"; return 1; }
    old=$(current_node_id 2>/dev/null || true)
    generate_singbox_config "$node_id" || return 1
    tmp=$(mktemp "${PING_WG_CONFIG_DIR}/.current.XXXXXX") || return 1
    printf '%s\n' "$node_id" > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$PING_WG_CURRENT_FILE"
    if service_restart ping-wireguard-singbox; then
        log_ok "已切换出站节点。"
        return 0
    fi
    log_error "服务重启失败，正在回滚节点选择。"
    if [[ -n $old ]]; then
        generate_singbox_config "$old" && printf '%s\n' "$old" > "$PING_WG_CURRENT_FILE"
    else
        rm -f "$PING_WG_CURRENT_FILE"
        generate_singbox_config
    fi
    service_restart ping-wireguard-singbox 2>/dev/null || true
    return 1
}

select_node_interactive() {
    local -a ids=()
    local id type name server port choice
    [[ -s $PING_WG_INDEX_FILE ]] || { log_warn "尚未导入节点。"; return 1; }
    list_nodes
    while IFS=$'\t' read -r id type name server port; do ids+=("$id"); done < "$PING_WG_INDEX_FILE"
    read -r -p "请输入节点序号（0 取消）：" choice
    is_uint "$choice" || { log_error "请输入数字。"; return 1; }
    (( 10#$choice == 0 )) && return 0
    (( 10#$choice >= 1 && 10#$choice <= ${#ids[@]} )) || { log_error "序号超出范围。"; return 1; }
    set_current_node "${ids[10#$choice-1]}"
}

show_current_node() {
    local id record type name server port
    id=$(current_node_id 2>/dev/null || true)
    if [[ -z $id ]]; then
        printf '当前节点：未选择（block 占位，客户端流量不会直连）\n'
        return 0
    fi
    record=$(node_record "$id") || return 1
    IFS=$'\t' read -r _ type name server port <<< "$record"
    printf '当前节点：%s\n协议：%s\n服务器：%s:%s\n' "$name" "$type" "$server" "$port"
}
