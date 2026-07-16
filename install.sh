#!/usr/bin/env bash
# Ping-WireGuard 一键安装入口。
# 支持完整仓库执行，也支持 GitHub Raw 单文件自举安装。

set -Eeuo pipefail

readonly PING_WG_REPOSITORY="${PING_WG_REPOSITORY:-Jyanbai/Ping-WireGuard}"
readonly PING_WG_REF="${PING_WG_REF:-main}"
BOOTSTRAP_DIR=''

bootstrap_cleanup() {
    local tmp_root=${TMPDIR:-/tmp}
    [[ $tmp_root == /* ]] || tmp_root=/tmp
    if [[ -n ${BOOTSTRAP_DIR:-} && -d $BOOTSTRAP_DIR ]]; then
        case "$BOOTSTRAP_DIR" in
            "${tmp_root%/}"/ping-wireguard.*) rm -rf -- "$BOOTSTRAP_DIR" ;;
            *) printf '[警告] 拒绝清理异常临时目录：%s\n' "$BOOTSTRAP_DIR" >&2 ;;
        esac
    fi
}

bootstrap_full_project() {
    local tmp_root archive_url archive listing first_entry top project_dir status
    command -v tar >/dev/null 2>&1 || {
        printf '[错误] 一键安装需要 tar，请先安装 tar。\n' >&2
        exit 1
    }
    [[ $PING_WG_REF =~ ^[A-Za-z0-9._/-]+$ ]] || {
        printf '[错误] 非法的仓库分支或标签：%s\n' "$PING_WG_REF" >&2
        exit 1
    }

    tmp_root=${TMPDIR:-/tmp}
    [[ $tmp_root == /* ]] || tmp_root=/tmp
    BOOTSTRAP_DIR=$(mktemp -d "${tmp_root%/}/ping-wireguard.XXXXXX") || exit 1
    trap bootstrap_cleanup EXIT
    archive="${BOOTSTRAP_DIR}/source.tar.gz"
    archive_url=${PING_WG_ARCHIVE_URL:-"https://codeload.github.com/${PING_WG_REPOSITORY}/tar.gz/refs/heads/${PING_WG_REF}"}

    printf '[信息] 正在下载 Ping-WireGuard 完整项目...\n'
    if [[ -f $archive_url ]]; then
        cp "$archive_url" "$archive"
    else
        command -v curl >/dev/null 2>&1 || {
            printf '[错误] 一键安装需要 curl，请先安装 curl。\n' >&2
            exit 1
        }
        curl -fL --retry 3 --connect-timeout 10 "$archive_url" -o "$archive"
    fi
    listing=$(tar -tzf "$archive")
    if grep -Eq '(^/|(^|/)\.\.(/|$))' <<< "$listing"; then
        printf '[错误] 下载包包含不安全路径，已停止安装。\n' >&2
        exit 1
    fi
    first_entry=${listing%%$'\n'*}
    top=${first_entry%%/*}
    [[ $top =~ ^[A-Za-z0-9._-]+$ ]] || {
        printf '[错误] 下载包目录结构异常。\n' >&2
        exit 1
    }
    tar -xzf "$archive" -C "$BOOTSTRAP_DIR"
    project_dir="${BOOTSTRAP_DIR}/${top}"
    [[ -r ${project_dir}/install.sh && -r ${project_dir}/scripts/common.sh && \
       -r ${project_dir}/templates/sing-box.json.template ]] || {
        printf '[错误] 下载的项目文件不完整。\n' >&2
        exit 1
    }

    if [[ ${PING_WG_BOOTSTRAP_ONLY:-0} == 1 ]]; then
        printf 'BOOTSTRAP_OK\n'
        exit 0
    fi

    export PING_WG_BOOTSTRAPPED=1
    set +e
    if [[ -r /dev/tty ]]; then
        bash "${project_dir}/install.sh" "$@" < /dev/tty
    else
        printf '[注意] 未检测到交互终端，将按非交互模式继续。\n' >&2
        bash "${project_dir}/install.sh" "$@"
    fi
    status=$?
    set -e
    exit "$status"
}

# `curl ... | bash` 从标准输入执行时 BASH_SOURCE 为空，必须直接进入自举，
# 不能误把当前工作目录中的同名 scripts/ 当作已下载的项目。
[[ -n ${BASH_SOURCE[0]:-} ]] || bootstrap_full_project "$@"

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_SCRIPTS="${ROOT_DIR}/scripts"

[[ -r ${SOURCE_SCRIPTS}/common.sh ]] || {
    [[ ${PING_WG_BOOTSTRAPPED:-0} != 1 ]] || {
        printf '[错误] 自举完成后仍缺少 scripts/common.sh。\n' >&2
        exit 1
    }
    bootstrap_full_project "$@"
}

# shellcheck source=scripts/common.sh
. "${SOURCE_SCRIPTS}/common.sh"
# shellcheck source=scripts/wg.sh
. "${SOURCE_SCRIPTS}/wg.sh"
# shellcheck source=scripts/singbox.sh
. "${SOURCE_SCRIPTS}/singbox.sh"
# shellcheck source=scripts/services.sh
. "${SOURCE_SCRIPTS}/services.sh"

on_error() {
    local code=$? line=${BASH_LINENO[0]:-?}
    log_error "安装在第 ${line} 行失败（退出码 ${code}）。已生成的配置不会被静默删除，请修复后重试。"
    exit "$code"
}
trap on_error ERR

guard_existing_singbox_service() {
    if [[ $INIT_SYSTEM == systemd ]] && systemctl is-active --quiet sing-box 2>/dev/null; then
        die "检测到既有 sing-box.service 正在运行。为避免中断现有业务，请先迁移或停止它后再安装。"
    fi
    if [[ $INIT_SYSTEM == openrc ]] && rc-service sing-box status >/dev/null 2>&1; then
        die "检测到既有 sing-box 服务正在运行。为避免中断现有业务，请先迁移或停止它后再安装。"
    fi
}

install_dependencies() {
    log_info "安装 WireGuard 与基础依赖..."
    case "$OS_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends bash ca-certificates curl wireguard-tools iproute2 nftables iptables tar coreutils
            ;;
        rhel)
            local pm
            if command_exists dnf; then pm=dnf; else pm=yum; fi
            "$pm" -y install bash ca-certificates curl wireguard-tools iproute nftables iptables tar coreutils || {
                log_warn "首次安装 WireGuard 失败，尝试启用 EPEL。"
                "$pm" -y install epel-release
                "$pm" -y install bash ca-certificates curl wireguard-tools iproute nftables iptables tar coreutils
            }
            ;;
        alpine)
            apk add --no-cache bash ca-certificates curl wireguard-tools iproute2 nftables iptables tar coreutils
            ;;
    esac
    command_exists wg && command_exists wg-quick || die "WireGuard 工具安装失败。"
}

install_qrencode() {
    command_exists qrencode && return 0
    log_info "安装二维码工具 qrencode..."
    case "$OS_FAMILY" in
        debian)
            apt-get install -y --no-install-recommends qrencode || \
                log_warn "qrencode 安装失败，客户端配置仍可文本导出。"
            ;;
        rhel)
            local pm
            if command_exists dnf; then pm=dnf; else pm=yum; fi
            if ! "$pm" -y install qrencode; then
                if [[ $OS_ID != fedora ]] && "$pm" -y install epel-release && "$pm" -y install qrencode; then
                    :
                else
                    log_warn "qrencode 安装失败，可启用 EPEL 后手动安装。"
                fi
            fi
            ;;
        alpine)
            apk add --no-cache libqrencode-tools || \
                log_warn "qrencode 安装失败，客户端配置仍可文本导出。"
            ;;
    esac
}

version_ge() {
    local have=${1%%-*} need=${2%%-*} a b i
    local -a hv nv
    IFS=. read -r -a hv <<< "$have"; IFS=. read -r -a nv <<< "$need"
    for ((i=0; i<3; i++)); do
        a=${hv[i]:-0}; b=${nv[i]:-0}
        [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || return 1
        ((10#$a > 10#$b)) && return 0
        ((10#$a < 10#$b)) && return 1
    done
    return 0
}

install_singbox_release() {
    local arch api url archive member
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l|armv7) arch=armv7 ;;
        *) die "暂不支持此 CPU 架构：$(uname -m)" ;;
    esac
    api=$(mktemp); archive=$(mktemp)
    curl -fL --retry 3 --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest -o "$api"
    url=$({ grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' "$api" \
        | sed -E 's/^.*"(https:[^"]+)"$/\1/' \
        | grep -E "sing-box-[0-9.]+-linux-${arch}\\.tar\\.gz$" | head -n1; } || true)
    rm -f "$api"
    [[ -n $url ]] || { rm -f "$archive"; die "无法找到适合当前架构的 sing-box 安装包。"; }
    curl -fL --retry 3 --connect-timeout 10 "$url" -o "$archive"
    member=$({ tar -tzf "$archive" | grep -E '/sing-box$' | head -n1; } || true)
    [[ -n $member ]] || { rm -f "$archive"; die "sing-box 安装包结构异常。"; }
    tar -xOzf "$archive" "$member" > /usr/local/bin/sing-box
    chmod 0755 /usr/local/bin/sing-box
    rm -f "$archive"
}

install_singbox() {
    local current='' installer
    if command_exists sing-box; then
        current=$(sing-box version 2>/dev/null | awk 'NR==1 {print $3}')
        version_ge "${current:-0}" 1.10.0 && { log_ok "sing-box ${current} 已安装。"; return 0; }
        log_warn "sing-box ${current:-未知} 过旧，将升级到当前稳定版。"
    fi
    log_info "安装 sing-box..."
    if [[ $OS_FAMILY == alpine ]] && apk add --no-cache sing-box; then
        :
    elif [[ $OS_FAMILY != alpine ]]; then
        installer=$(mktemp)
        curl -fL --retry 3 --connect-timeout 10 https://sing-box.app/install.sh -o "$installer"
        sh "$installer"
        rm -f "$installer"
    else
        install_singbox_release
    fi
    command_exists sing-box || die "sing-box 安装失败。"
    current=$(sing-box version 2>/dev/null | awk 'NR==1 {print $3}')
    version_ge "${current:-0}" 1.10.0 || die "sing-box ${current:-未知} 低于最低要求 1.10.0。"
}

install_project_files() {
    log_info "安装 Ping-WireGuard 管理文件..."
    install -d -m 0755 "$PING_WG_LIB_DIR/scripts" "$PING_WG_LIB_DIR/templates"
    if [[ $ROOT_DIR == "$PING_WG_LIB_DIR" ]]; then
        chmod 0755 "$PING_WG_LIB_DIR/install.sh" "$PING_WG_LIB_DIR/scripts/"*.sh /usr/local/bin/ping-wg
        chmod 0644 "$PING_WG_LIB_DIR/templates/sing-box.json.template"
        return 0
    fi
    install -m 0755 "$ROOT_DIR/install.sh" "$PING_WG_LIB_DIR/install.sh"
    install -m 0755 "$ROOT_DIR/ping-wg.sh" /usr/local/bin/ping-wg
    local file
    for file in common.sh wg.sh client.sh singbox.sh import-node.sh firewall.sh services.sh; do
        install -m 0755 "$SOURCE_SCRIPTS/$file" "$PING_WG_LIB_DIR/scripts/$file"
    done
    install -m 0644 "$ROOT_DIR/templates/sing-box.json.template" "$PING_WG_LIB_DIR/templates/sing-box.json.template"
}

detect_public_endpoint() {
    local value=''
    value=$(curl -4fsS --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
    if valid_ipv4 "$value"; then printf '%s' "$value"; return 0; fi
    return 1
}

prompt_value() {
    local var_name=$1 prompt=$2 current=$3 value
    read -r -p "${prompt} [${current}]: " value
    printf -v "$var_name" '%s' "${value:-$current}"
}

collect_settings() {
    local detected=''
    if ! load_settings; then
        default_settings
        detected=$(detect_public_endpoint || true)
        SERVER_ENDPOINT=$detected
    fi
    if [[ ! -t 0 ]]; then
        [[ -n $SERVER_ENDPOINT ]] || die "非交互安装请先通过已有 settings.conf 提供 SERVER_ENDPOINT。"
        return 0
    fi
    printf '\n%s基础配置%s（直接回车使用括号中的值）\n' "$C_BOLD" "$C_RESET"
    prompt_value WG_PORT 'WireGuard UDP 端口' "$WG_PORT"
    prompt_value WG_SERVER_ADDRESS 'WireGuard 服务端地址/CIDR' "$WG_SERVER_ADDRESS"
    prompt_value WG_CLIENT_ADDRESS '首个客户端地址/CIDR' "$WG_CLIENT_ADDRESS"
    prompt_value WG_CLIENT_DNS '客户端 DNS' "$WG_CLIENT_DNS"
    prompt_value WG_MTU 'WireGuard/TUN MTU' "$WG_MTU"
    prompt_value SERVER_ENDPOINT '服务器公网 IP 或域名' "${SERVER_ENDPOINT:-请填写}"
    prompt_value CLIENT_NAME '客户端名称' "$CLIENT_NAME"
    valid_port "$WG_PORT" || die "WireGuard 端口无效。"
    valid_ipv4_cidr "$WG_SERVER_ADDRESS" || die "服务端地址必须是合法 IPv4 CIDR。"
    valid_ipv4_cidr "$WG_CLIENT_ADDRESS" || die "客户端地址必须是合法 IPv4 CIDR。"
    valid_ipv4 "$WG_CLIENT_DNS" || die "v1 客户端 DNS 仅接受 IPv4 地址。"
    valid_mtu "$WG_MTU" || die "MTU 必须在 1280 到 9000 之间。"
    [[ $SERVER_ENDPOINT =~ ^[A-Za-z0-9._:-]+$ && $SERVER_ENDPOINT != 请填写 ]] || die "公网地址格式无效。"
    CLIENT_NAME=$(sanitize_label "$CLIENT_NAME")
    WG_PORT=$((10#$WG_PORT))
    WG_MTU=$((10#$WG_MTU))
}

perform_install() {
    require_root; require_bash4; detect_os; detect_init
    if [[ ${1:-} == --reconfigure ]]; then
        [[ -r $PING_WG_SETTINGS_FILE && -x /usr/local/bin/ping-wg ]] || die "尚未安装，不能执行重新配置。"
        collect_settings
        stop_services
        write_settings
        generate_wg_config
        configure_ip_forwarding
        generate_singbox_config
        start_services
        log_ok "配置已更新。客户端配置：$PING_WG_CLIENT_CONFIG"
        return 0
    fi
    guard_existing_singbox_service
    install_dependencies
    install_qrencode
    install_singbox
    install_project_files
    ensure_directories
    collect_settings
    stop_services
    write_settings
    generate_wg_config
    configure_ip_forwarding
    generate_singbox_config
    install_services
    start_services
    printf '\n'
    log_ok "Ping-WireGuard v${PROJECT_VERSION} 安装完成。"
    printf '管理命令：ping-wg\n客户端配置：%s\n' "$PING_WG_CLIENT_CONFIG"
    if ! current_node_id >/dev/null 2>&1; then
        log_warn "当前尚未导入外部节点，请运行 ping-wg 并选择“导入外部节点”。"
    fi
}

if [[ ${BASH_SOURCE[0]:-} == "$0" ]]; then
    perform_install "$@"
fi
