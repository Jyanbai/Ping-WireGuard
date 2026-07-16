#!/usr/bin/env bash
# Ping-WireGuard 公共函数：路径、日志、平台检测、输入校验。

if [[ -n ${PING_WG_COMMON_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
readonly PING_WG_COMMON_LOADED=1

readonly PROJECT_NAME="Ping-WireGuard"
readonly PROJECT_VERSION="1.3.0"

PING_WG_LIB_DIR="${PING_WG_LIB_DIR:-/usr/local/lib/ping-wireguard}"
PING_WG_CONFIG_DIR="${PING_WG_CONFIG_DIR:-/etc/ping-wireguard}"
PING_WG_STATE_DIR="${PING_WG_STATE_DIR:-/var/lib/ping-wireguard}"
PING_WG_LOG_DIR="${PING_WG_LOG_DIR:-/var/log/ping-wireguard}"
PING_WG_NODES_DIR="${PING_WG_NODES_DIR:-${PING_WG_CONFIG_DIR}/nodes}"
PING_WG_SETTINGS_FILE="${PING_WG_SETTINGS_FILE:-${PING_WG_CONFIG_DIR}/settings.conf}"
PING_WG_CURRENT_FILE="${PING_WG_CURRENT_FILE:-${PING_WG_CONFIG_DIR}/current-node}"
PING_WG_INDEX_FILE="${PING_WG_INDEX_FILE:-${PING_WG_CONFIG_DIR}/nodes.tsv}"
PING_WG_SB_CONFIG="${PING_WG_SB_CONFIG:-${PING_WG_CONFIG_DIR}/sing-box.json}"
PING_WG_WG_CONFIG="${PING_WG_WG_CONFIG:-/etc/wireguard/wg0.conf}"
PING_WG_CLIENT_CONFIG="${PING_WG_CLIENT_CONFIG:-${PING_WG_CONFIG_DIR}/client.conf}"
PING_WG_CLIENT_EXPORT_DIR="${PING_WG_CLIENT_EXPORT_DIR:-/root}"
PING_WG_TEMPLATE="${PING_WG_TEMPLATE:-${PING_WG_LIB_DIR}/templates/sing-box.json.template}"

if [[ -t 1 && ${NO_COLOR:-0} != 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

log_info()  { printf '%s[信息]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%s[完成]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行。"
}

require_bash4() {
    (( BASH_VERSINFO[0] >= 4 )) || die "需要 Bash 4.0 或更高版本。"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_directories() {
    if [[ ${PING_WG_TEST_MODE:-0} == 1 ]]; then
        mkdir -p "$PING_WG_CONFIG_DIR" "$PING_WG_NODES_DIR" "$PING_WG_STATE_DIR" "$PING_WG_LOG_DIR"
        return 0
    fi
    install -d -m 0700 "$PING_WG_CONFIG_DIR" "$PING_WG_NODES_DIR" "$PING_WG_STATE_DIR"
    install -d -m 0750 "$PING_WG_LOG_DIR"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release。"
    # /etc/os-release 是发行版提供的可信系统文件。
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=${ID,,}
    OS_LIKE=${ID_LIKE:-}
    case "$OS_ID" in
        debian|ubuntu) OS_FAMILY=debian ;;
        centos|rocky|rhel|almalinux|fedora) OS_FAMILY=rhel ;;
        alpine) OS_FAMILY=alpine ;;
        *)
            case " ${OS_LIKE,,} " in
                *" debian "*) OS_FAMILY=debian ;;
                *" rhel "*|*" fedora "*) OS_FAMILY=rhel ;;
                *) die "暂不支持当前发行版：${OS_ID}。" ;;
            esac
            ;;
    esac
    export OS_ID OS_FAMILY
}

detect_init() {
    if command_exists systemctl && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM=systemd
    elif command_exists rc-service && command_exists rc-update; then
        INIT_SYSTEM=openrc
    else
        die "仅支持 systemd 或 OpenRC。"
    fi
    export INIT_SYSTEM
}

load_settings() {
    [[ -r "$PING_WG_SETTINGS_FILE" ]] || return 1
    # 此文件只允许 root 写入，变量值均由本项目校验后生成。
    # shellcheck disable=SC1090
    . "$PING_WG_SETTINGS_FILE"
    # 兼容 v1.2 及更早版本的 settings.conf。
    PUBLIC_INTERFACE=${PUBLIC_INTERFACE:-}
}

service_do() {
    local action=$1 service=$2
    detect_init
    if [[ $INIT_SYSTEM == systemd ]]; then
        systemctl "$action" "$service"
    else
        case "$action" in
            enable) rc-update add "$service" default ;;
            disable) rc-update del "$service" default 2>/dev/null || true ;;
            *) rc-service "$service" "$action" ;;
        esac
    fi
}

service_restart() {
    local service=$1
    service_do restart "$service" || service_do start "$service"
}

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

valid_port() {
    is_uint "$1" && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_mtu() {
    is_uint "$1" && (( 10#$1 >= 1280 && 10#$1 <= 9000 ))
}

valid_ipv4() {
    local ip=$1 part
    local -a octets
    IFS=. read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for part in "${octets[@]}"; do
        is_uint "$part" && (( 10#$part <= 255 )) || return 1
    done
}

valid_ipv4_cidr() {
    local ip=${1%/*} prefix=${1#*/}
    [[ $1 == */* ]] && valid_ipv4 "$ip" && is_uint "$prefix" && (( 10#$prefix <= 32 ))
}

valid_endpoint_host() {
    local host=$1
    valid_ipv4 "$host" && return 0
    [[ $host =~ ^[A-Za-z0-9._-]+$ ]] && return 0
    # v1 接受不带方括号和端口的原始 IPv6；方括号由配置生成器补上。
    [[ $host == *:* && $host != *.* && $host =~ ^[0-9A-Fa-f:]+$ ]]
}

is_non_public_ipv4() {
    local ip=$1 a b
    valid_ipv4 "$ip" || return 0
    IFS=. read -r a b _ _ <<< "$ip"
    (( 10#$a == 0 || 10#$a == 10 || 10#$a == 127 )) && return 0
    (( 10#$a == 169 && 10#$b == 254 )) && return 0
    (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 )) && return 0
    (( 10#$a == 192 && 10#$b == 168 )) && return 0
    (( 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 )) && return 0
    (( 10#$a >= 224 )) && return 0
    return 1
}

ipv4_network_cidr() {
    local cidr=$1 ip=${1%/*} prefix=${1#*/} a b c d value mask network
    valid_ipv4_cidr "$cidr" || return 1
    IFS=. read -r a b c d <<< "$ip"
    value=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    if (( 10#$prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    fi
    network=$(( value & mask ))
    printf '%d.%d.%d.%d/%d' \
        "$(( (network >> 24) & 255 ))" "$(( (network >> 16) & 255 ))" \
        "$(( (network >> 8) & 255 ))" "$(( network & 255 ))" "$((10#$prefix))"
}

current_node_setting() {
    local id
    [[ -r $PING_WG_CURRENT_FILE ]] || return 1
    IFS= read -r id < "$PING_WG_CURRENT_FILE"
    [[ $id =~ ^[A-Za-z0-9._-]+$ && -r ${PING_WG_NODES_DIR}/${id}.json ]] || return 1
    printf '%s' "$id"
}

using_external_node() { current_node_setting >/dev/null 2>&1; }

sanitize_label() {
    local value=$1
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//$'\t'/ }
    value=${value//|/-}
    value=${value:0:80}
    printf '%s' "${value:-未命名节点}"
}

pause_menu() {
    [[ -t 0 ]] || return 0
    printf '\n按 Enter 键返回菜单...'
    read -r _
}

confirm() {
    local prompt=${1:-确认继续？} answer
    read -r -p "$prompt [y/N]: " answer
    [[ ${answer,,} == y || ${answer,,} == yes ]]
}

write_settings() {
    local tmp
    tmp=$(mktemp "${PING_WG_CONFIG_DIR}/.settings.XXXXXX") || return 1
    umask 077
    {
        printf 'WG_INTERFACE=%q\n' "$WG_INTERFACE"
        printf 'WG_PORT=%q\n' "$WG_PORT"
        printf 'WG_SERVER_ADDRESS=%q\n' "$WG_SERVER_ADDRESS"
        printf 'WG_CLIENT_ADDRESS=%q\n' "$WG_CLIENT_ADDRESS"
        printf 'WG_CLIENT_DNS=%q\n' "$WG_CLIENT_DNS"
        printf 'WG_MTU=%q\n' "$WG_MTU"
        printf 'SERVER_ENDPOINT=%q\n' "$SERVER_ENDPOINT"
        printf 'PUBLIC_INTERFACE=%q\n' "$PUBLIC_INTERFACE"
        printf 'CLIENT_NAME=%q\n' "$CLIENT_NAME"
        printf 'TUN_INTERFACE=%q\n' "$TUN_INTERFACE"
        printf 'TUN_ADDRESS=%q\n' "$TUN_ADDRESS"
    } > "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$PING_WG_SETTINGS_FILE"
}

default_settings() {
    WG_INTERFACE=wg0
    WG_PORT=51820
    WG_SERVER_ADDRESS=10.66.66.1/24
    WG_CLIENT_ADDRESS=10.66.66.2/32
    WG_CLIENT_DNS=1.1.1.1
    WG_MTU=1380
    SERVER_ENDPOINT=''
    PUBLIC_INTERFACE=''
    CLIENT_NAME=client
    TUN_INTERFACE=pingtun0
    TUN_ADDRESS=172.19.0.1/30
}
