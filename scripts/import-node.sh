#!/usr/bin/env bash
# 解析 vless:// 与 ss:// 分享链接，生成可直接嵌入 sing-box 的 outbound JSON。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
require_bash4

declare -gA URI_PARAMS=()
PARSED_TYPE=''; PARSED_NAME=''; PARSED_SERVER=''; PARSED_PORT=''; PARSED_JSON=''; IMPORTED_NODE_ID=''

url_decode() {
    local input=$1 output='' char hex i
    for ((i=0; i<${#input}; i++)); do
        char=${input:i:1}
        if [[ $char == '%' && ${input:i+1:2} =~ ^[0-9A-Fa-f]{2}$ ]]; then
            hex=${input:i+1:2}
            printf -v char '%b' "\\x${hex}"
            output+=$char
            ((i+=2))
        else
            output+=$char
        fi
    done
    printf '%s' "$output"
}

json_escape() {
    local input=$1 output='' char code i
    for ((i=0; i<${#input}; i++)); do
        char=${input:i:1}
        case "$char" in
            '"') output+='\\"' ;;
            '\\') output+='\\\\' ;;
            $'\b') output+='\\b' ;;
            $'\f') output+='\\f' ;;
            $'\n') output+='\\n' ;;
            $'\r') output+='\\r' ;;
            $'\t') output+='\\t' ;;
            *)
                printf -v code '%d' "'$char"
                if (( code < 32 )); then
                    printf -v char '\\u%04x' "$code"
                fi
                output+=$char
                ;;
        esac
    done
    printf '%s' "$output"
}

json_string() { printf '"%s"' "$(json_escape "$1")"; }

base64_decode() {
    local data=${1//-/+} decoded padding
    data=${data//_/\/}
    data=${data//$'\r'/}; data=${data//$'\n'/}
    padding=$(( (4 - ${#data} % 4) % 4 ))
    while (( padding-- > 0 )); do data+='='; done
    if command_exists base64; then
        decoded=$(printf '%s' "$data" | base64 -d 2>/dev/null) || return 1
    elif command_exists openssl; then
        decoded=$(printf '%s' "$data" | openssl base64 -d -A 2>/dev/null) || return 1
    else
        log_error "缺少 base64（或 openssl），无法解析编码链接。"
        return 1
    fi
    printf '%s' "$decoded"
}

parse_query() {
    local query=$1 pair key value
    URI_PARAMS=()
    while [[ -n $query ]]; do
        if [[ $query == *'&'* ]]; then pair=${query%%&*}; query=${query#*&}; else pair=$query; query=''; fi
        [[ -n $pair ]] || continue
        key=${pair%%=*}
        if [[ $pair == *=* ]]; then value=${pair#*=}; else value=''; fi
        key=$(url_decode "$key"); value=$(url_decode "$value")
        [[ -n $key ]] || continue
        URI_PARAMS["$key"]=$value
    done
}

query_first() {
    local key
    for key in "$@"; do
        if [[ -v URI_PARAMS[$key] && -n ${URI_PARAMS[$key]} ]]; then
            printf '%s' "${URI_PARAMS[$key]}"
            return 0
        fi
    done
    return 1
}

parse_host_port() {
    local endpoint=$1
    PARSED_SERVER=''; PARSED_PORT=''
    endpoint=${endpoint%/}
    if [[ $endpoint =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        PARSED_SERVER=${BASH_REMATCH[1]}; PARSED_PORT=${BASH_REMATCH[2]}
    elif [[ $endpoint =~ ^([^:]+):([0-9]+)$ ]]; then
        PARSED_SERVER=${BASH_REMATCH[1]}; PARSED_PORT=${BASH_REMATCH[2]}
    else
        log_error "节点地址格式错误（IPv6 必须使用 [地址]:端口）：$endpoint"
        return 1
    fi
    PARSED_SERVER=$(url_decode "$PARSED_SERVER")
    valid_port "$PARSED_PORT" || { log_error "节点端口无效：$PARSED_PORT"; return 1; }
    PARSED_PORT=$((10#$PARSED_PORT))
    [[ -n $PARSED_SERVER ]] || { log_error "节点服务器地址为空。"; return 1; }
}

json_array_from_csv() {
    local csv=$1 item first=1
    local -a values
    IFS=, read -r -a values <<< "$csv"
    printf '['
    for item in "${values[@]}"; do
        [[ -n $item ]] || continue
        (( first )) || printf ','
        json_string "$item"
        first=0
    done
    printf ']'
}

build_vless_transport() {
    local transport=$1 host path service
    host=$(query_first host 2>/dev/null || true)
    path=$(query_first path 2>/dev/null || true)
    case "$transport" in
        ''|none|tcp|raw) printf '' ;;
        ws|websocket)
            printf ',"transport":{"type":"ws"'
            [[ -n $path ]] && printf ',"path":%s' "$(json_string "$path")"
            [[ -n $host ]] && printf ',"headers":{"Host":%s}' "$(json_string "$host")"
            printf '}'
            ;;
        grpc)
            service=$(query_first serviceName service_name 2>/dev/null || true)
            printf ',"transport":{"type":"grpc"'
            [[ -n $service ]] && printf ',"service_name":%s' "$(json_string "$service")"
            printf '}'
            ;;
        h2|http)
            printf ',"transport":{"type":"http"'
            [[ -n $host ]] && printf ',"host":%s' "$(json_array_from_csv "$host")"
            [[ -n $path ]] && printf ',"path":%s' "$(json_string "$path")"
            printf '}'
            ;;
        httpupgrade)
            printf ',"transport":{"type":"httpupgrade"'
            [[ -n $path ]] && printf ',"path":%s' "$(json_string "$path")"
            [[ -n $host ]] && printf ',"headers":{"Host":%s}' "$(json_string "$host")"
            printf '}'
            ;;
        *) log_error "暂不支持 VLESS 传输类型：$transport"; return 1 ;;
    esac
}

build_vless_tls() {
    local security=$1 server=$2 sni insecure alpn fp public_key short_id
    [[ $security == tls || $security == reality ]] || { printf ''; return 0; }
    sni=$(query_first sni serverName peer 2>/dev/null || true)
    [[ -n $sni ]] || sni=$server
    insecure=$(query_first allowInsecure insecure 2>/dev/null || true)
    alpn=$(query_first alpn 2>/dev/null || true)
    fp=$(query_first fp fingerprint 2>/dev/null || true)
    printf ',"tls":{"enabled":true,"server_name":%s' "$(json_string "$sni")"
    [[ $insecure == 1 || ${insecure,,} == true ]] && printf ',"insecure":true'
    [[ -n $alpn ]] && printf ',"alpn":%s' "$(json_array_from_csv "$alpn")"
    [[ -n $fp && $fp != none ]] && printf ',"utls":{"enabled":true,"fingerprint":%s}' "$(json_string "$fp")"
    if [[ $security == reality ]]; then
        public_key=$(query_first pbk publicKey public_key 2>/dev/null || true)
        short_id=$(query_first sid shortId short_id 2>/dev/null || true)
        [[ -n $public_key ]] || { log_error "Reality 节点缺少公钥（pbk）。"; return 1; }
        printf ',"reality":{"enabled":true,"public_key":%s' "$(json_string "$public_key")"
        [[ -n $short_id ]] && printf ',"short_id":%s' "$(json_string "$short_id")"
        printf '}'
    fi
    printf '}'
}

parse_vless_uri() {
    local uri=$1 body fragment query authority uuid endpoint security encryption transport flow packet_encoding header_type
    local tls_json transport_json
    body=${uri#vless://}
    if [[ $body == *'#'* ]]; then fragment=${body#*#}; body=${body%%#*}; else fragment=''; fi
    if [[ $body == *'?'* ]]; then query=${body#*\?}; authority=${body%%\?*}; else query=''; authority=$body; fi
    parse_query "$query"
    [[ $authority == *@* ]] || { log_error "VLESS 链接缺少 UUID 或服务器地址。"; return 1; }
    uuid=$(url_decode "${authority%%@*}")
    endpoint=${authority#*@}
    [[ $uuid =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || {
        log_error "VLESS UUID 格式无效。"; return 1;
    }
    parse_host_port "$endpoint" || return 1
    encryption=$(query_first encryption 2>/dev/null || true)
    [[ -z $encryption || $encryption == none ]] || { log_error "仅支持 encryption=none 的 VLESS 节点。"; return 1; }
    security=$(query_first security 2>/dev/null || true); security=${security:-none}
    [[ $security == none || $security == tls || $security == reality ]] || {
        log_error "暂不支持 VLESS 安全类型：$security"; return 1;
    }
    transport=$(query_first type 2>/dev/null || true)
    header_type=$(query_first headerType header_type 2>/dev/null || true)
    [[ -z $header_type || $header_type == none ]] || {
        log_error "暂不支持 VLESS TCP headerType：$header_type"; return 1;
    }
    flow=$(query_first flow 2>/dev/null || true)
    [[ -z $flow || $flow == xtls-rprx-vision ]] || { log_error "暂不支持 VLESS flow：$flow"; return 1; }
    if [[ -n $flow && ( $security == none || ( -n $transport && $transport != none && $transport != tcp && $transport != raw ) ) ]]; then
        log_error "xtls-rprx-vision 仅支持 TLS/Reality + TCP/raw。"
        return 1
    fi
    packet_encoding=$(query_first packetEncoding packet_encoding 2>/dev/null || true)
    transport_json=$(build_vless_transport "$transport") || return 1
    tls_json=$(build_vless_tls "$security" "$PARSED_SERVER") || return 1
    PARSED_TYPE=vless
    PARSED_NAME=$(sanitize_label "$(url_decode "$fragment")")
    PARSED_JSON=$(printf '{"type":"vless","tag":"proxy","server":%s,"server_port":%d,"uuid":%s' \
        "$(json_string "$PARSED_SERVER")" "$PARSED_PORT" "$(json_string "$uuid")")
    [[ -n $flow ]] && PARSED_JSON+=",\"flow\":$(json_string "$flow")"
    [[ -n $packet_encoding ]] && PARSED_JSON+=",\"packet_encoding\":$(json_string "$packet_encoding")"
    PARSED_JSON+="${tls_json}${transport_json}}"
}

valid_ss_method() {
    case "$1" in
        2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305|none|\
        aes-128-gcm|aes-192-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305|\
        aes-128-ctr|aes-192-ctr|aes-256-ctr|aes-128-cfb|aes-192-cfb|aes-256-cfb|rc4-md5|\
        chacha20-ietf|xchacha20) return 0 ;;
        *) return 1 ;;
    esac
}

parse_ss_uri() {
    local uri=$1 body fragment query authority decoded userinfo endpoint method password plugin plugin_name plugin_opts
    body=${uri#ss://}
    if [[ $body == *'#'* ]]; then fragment=${body#*#}; body=${body%%#*}; else fragment=''; fi
    if [[ $body == *'?'* ]]; then query=${body#*\?}; authority=${body%%\?*}; else query=''; authority=$body; fi
    parse_query "$query"
    if [[ $authority == *@* ]]; then
        userinfo=${authority%@*}; endpoint=${authority##*@}
        endpoint=${endpoint%/}
        if [[ $userinfo == *:* ]]; then
            userinfo=$(url_decode "$userinfo")
        else
            userinfo=$(base64_decode "$userinfo") || { log_error "Shadowsocks 用户信息 Base64 无效。"; return 1; }
        fi
    else
        decoded=$(base64_decode "$authority") || { log_error "Shadowsocks 链接 Base64 无效。"; return 1; }
        [[ $decoded == *@* ]] || { log_error "旧格式 Shadowsocks 链接缺少服务器地址。"; return 1; }
        userinfo=${decoded%@*}; endpoint=${decoded##*@}
    fi
    [[ $userinfo == *:* ]] || { log_error "Shadowsocks 链接缺少 method:password。"; return 1; }
    method=${userinfo%%:*}; password=${userinfo#*:}
    method=$(url_decode "$method"); password=$(url_decode "$password")
    valid_ss_method "$method" || { log_error "sing-box 不支持此 Shadowsocks 加密方法：$method"; return 1; }
    [[ -n $password ]] || { log_error "Shadowsocks 密码为空。"; return 1; }
    parse_host_port "$endpoint" || return 1
    PARSED_TYPE=shadowsocks
    PARSED_NAME=$(sanitize_label "$(url_decode "$fragment")")
    PARSED_JSON=$(printf '{"type":"shadowsocks","tag":"proxy","server":%s,"server_port":%d,"method":%s,"password":%s' \
        "$(json_string "$PARSED_SERVER")" "$PARSED_PORT" "$(json_string "$method")" "$(json_string "$password")")
    plugin=$(query_first plugin 2>/dev/null || true)
    if [[ -n $plugin ]]; then
        plugin_name=${plugin%%;*}
        [[ $plugin == *';'* ]] && plugin_opts=${plugin#*;} || plugin_opts=''
        [[ $plugin_name == simple-obfs ]] && plugin_name=obfs-local
        [[ $plugin_name == obfs-local || $plugin_name == v2ray-plugin ]] || {
            log_error "sing-box 仅支持 obfs-local/simple-obfs 和 v2ray-plugin：$plugin_name"; return 1;
        }
        PARSED_JSON+=",\"plugin\":$(json_string "$plugin_name")"
        [[ -n $plugin_opts ]] && PARSED_JSON+=",\"plugin_opts\":$(json_string "$plugin_opts")"
    fi
    PARSED_JSON+='}'
}

parse_node_uri() {
    local uri=$1
    PARSED_TYPE=''; PARSED_NAME=''; PARSED_SERVER=''; PARSED_PORT=''; PARSED_JSON=''
    uri=${uri//$'\r'/}; uri=${uri//$'\n'/}
    case "$uri" in
        vless://*) parse_vless_uri "$uri" ;;
        ss://*) parse_ss_uri "$uri" ;;
        *) log_error "仅支持 vless:// 或 ss:// 链接。"; return 1 ;;
    esac
}

new_node_id() {
    local suffix
    if [[ -r /dev/urandom ]]; then
        suffix=$(od -An -N3 -tx1 /dev/urandom 2>/dev/null); suffix=${suffix//[[:space:]]/}
    else
        suffix=$RANDOM$RANDOM
    fi
    printf '%s-%s' "$(date +%Y%m%d%H%M%S)" "$suffix"
}

store_parsed_node() {
    local raw_uri=$1 id tmp_json tmp_uri tmp_index line
    ensure_directories
    id=$(new_node_id)
    tmp_json=$(mktemp "${PING_WG_NODES_DIR}/.${id}.json.XXXXXX") || return 1
    tmp_uri=$(mktemp "${PING_WG_NODES_DIR}/.${id}.uri.XXXXXX") || { rm -f "$tmp_json"; return 1; }
    tmp_index=$(mktemp "${PING_WG_CONFIG_DIR}/.nodes.XXXXXX") || { rm -f "$tmp_json" "$tmp_uri"; return 1; }
    umask 077
    printf '%s\n' "$PARSED_JSON" > "$tmp_json"
    printf '%s\n' "$raw_uri" > "$tmp_uri"
    [[ -f $PING_WG_INDEX_FILE ]] && cat "$PING_WG_INDEX_FILE" > "$tmp_index"
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$PARSED_TYPE" "$PARSED_NAME" "$PARSED_SERVER" "$PARSED_PORT" >> "$tmp_index"
    chmod 0600 "$tmp_json" "$tmp_uri" "$tmp_index"
    mv -f "$tmp_json" "${PING_WG_NODES_DIR}/${id}.json"
    mv -f "$tmp_uri" "${PING_WG_NODES_DIR}/${id}.uri"
    mv -f "$tmp_index" "$PING_WG_INDEX_FILE"
    printf '%s\n' "$id"
}

import_node_uri() {
    local uri=$1 id
    parse_node_uri "$uri" || return 1
    id=$(store_parsed_node "$uri") || return 1
    IMPORTED_NODE_ID=$id
    log_ok "节点已导入：${PARSED_NAME}（${PARSED_TYPE}，${PARSED_SERVER}:${PARSED_PORT}）"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    require_root
    if [[ $# -gt 0 ]]; then
        node_uri=$1
    else
        read -r -p "请粘贴 vless:// 或 ss:// 链接：" node_uri
    fi
    import_node_uri "$node_uri"
    printf '节点 ID：%s\n' "$IMPORTED_NODE_ID"
fi
