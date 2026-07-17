#!/usr/bin/env bash
# 安装 systemd / OpenRC 服务。sing-box 服务启用崩溃自动拉起。

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# shellcheck source=singbox.sh
. "${SCRIPT_DIR}/singbox.sh"

install_systemd_services() {
    local sb
    sb=$(singbox_binary)
    tee /etc/systemd/system/ping-wireguard-wg.service >/dev/null <<EOF
[Unit]
Description=Ping-WireGuard WireGuard inbound
After=network-online.target
Wants=network-online.target
Before=ping-wireguard-singbox.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env wg-quick up ${PING_WG_WG_CONFIG}
ExecStop=/usr/bin/env wg-quick down ${PING_WG_WG_CONFIG}

[Install]
WantedBy=multi-user.target
EOF
    tee /etc/systemd/system/ping-wireguard-singbox.service >/dev/null <<EOF
[Unit]
Description=Ping-WireGuard sing-box chain gateway
After=network-online.target ping-wireguard-wg.service
Wants=network-online.target
Requires=ping-wireguard-wg.service

[Service]
Type=simple
ExecStartPre=${sb} check -c ${PING_WG_SB_CONFIG}
ExecStart=${sb} run -c ${PING_WG_SB_CONFIG}
Restart=on-failure
RestartSec=3s
TimeoutStartSec=30s
TimeoutStopSec=15s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

install_openrc_services() {
    local sb
    sb=$(singbox_binary)
    tee /etc/init.d/ping-wireguard-wg >/dev/null <<EOF
#!/sbin/openrc-run
description="Ping-WireGuard WireGuard inbound"
depend() { need net; before ping-wireguard-singbox; }
start() { ebegin "Starting WireGuard"; /usr/bin/wg-quick up "${PING_WG_WG_CONFIG}"; eend \$?; }
stop() { ebegin "Stopping WireGuard"; /usr/bin/wg-quick down "${PING_WG_WG_CONFIG}"; eend \$?; }
EOF
    tee /etc/init.d/ping-wireguard-singbox >/dev/null <<EOF
#!/sbin/openrc-run
description="Ping-WireGuard sing-box chain gateway"
command="${sb}"
command_args="run -c ${PING_WG_SB_CONFIG}"
supervisor="supervise-daemon"
pidfile="/run/ping-wireguard-singbox.pid"
respawn_delay=3
respawn_max=0
output_log="${PING_WG_LOG_DIR}/sing-box.log"
error_log="${PING_WG_LOG_DIR}/sing-box.err.log"
depend() { need net ping-wireguard-wg; }
start_pre() { "${sb}" check -c "${PING_WG_SB_CONFIG}"; }
EOF
    chmod 0755 /etc/init.d/ping-wireguard-wg /etc/init.d/ping-wireguard-singbox
}

install_services() {
    detect_init
    if [[ $INIT_SYSTEM == systemd ]]; then
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            log_warn "检测到发行版自带的 sing-box 服务正在运行，将停用它并改用项目专用服务。"
            systemctl disable --now sing-box
        fi
        install_systemd_services
    else
        if rc-service sing-box status >/dev/null 2>&1; then
            log_warn "检测到发行版自带的 sing-box 服务正在运行，将停用它并改用项目专用服务。"
            rc-service sing-box stop || true
            rc-update del sing-box default 2>/dev/null || true
        fi
        install_openrc_services
    fi
    service_do enable ping-wireguard-wg
    if using_external_node; then
        service_do enable ping-wireguard-singbox
    else
        service_do disable ping-wireguard-singbox
    fi
}

start_services() {
    service_restart ping-wireguard-wg
    if using_external_node; then
        service_do enable ping-wireguard-singbox
        service_restart ping-wireguard-singbox
    else
        service_do stop ping-wireguard-singbox 2>/dev/null || true
        service_do disable ping-wireguard-singbox 2>/dev/null || true
    fi
}

stop_services() {
    service_do stop ping-wireguard-singbox 2>/dev/null || true
    service_do stop ping-wireguard-wg 2>/dev/null || true
}

remove_services() {
    detect_init
    stop_services
    service_do disable ping-wireguard-singbox
    service_do disable ping-wireguard-wg
    if [[ $INIT_SYSTEM == systemd ]]; then
        rm -f /etc/systemd/system/ping-wireguard-wg.service /etc/systemd/system/ping-wireguard-singbox.service
        systemctl daemon-reload
    else
        rm -f /etc/init.d/ping-wireguard-wg /etc/init.d/ping-wireguard-singbox
    fi
}
