# Ping-WireGuard

面向中文用户的 WireGuard 链式中转管理脚本。它在落地服务器上提供 WireGuard 入站，用 sing-box TUN 只接管来自 WireGuard 接口的客户端流量，再把流量送往当前选择的 VLESS 或 Shadowsocks 外部节点。

> v1 定位为单机、单管理员、首个 WireGuard 客户端。节点可导入多个并随时切换。运行代码全部为 Bash，不依赖 jq。

## 数据流

```text
WireGuard 客户端
       │ UDP / wg0
       ▼
落地服务器 WireGuard 入站
       │ 内核转发（仅 wg0 流量）
       ▼
sing-box TUN / pingtun0
       │ 当前 outbound
       ▼
外部 VLESS 或 Shadowsocks 节点
       │
       ▼
Internet
```

sing-box TUN 使用以下关键项：

- `include_interface: ["wg0"]`：不接管宿主机其他业务流量。
- `auto_route` + `auto_redirect`：让 TUN 作为 WireGuard 客户端流量的网关。
- `strict_route`：避免不支持的流量静默绕过。
- `route.auto_detect_interface`：避免 sing-box 外部节点连接再次进入 TUN 形成回环。
- 默认 MTU 为 `1380`，WireGuard 与 TUN 保持一致，可在“重新配置”中调整。

项目不对 WireGuard 客户端流量做 SNAT/MASQUERADE；真正的出口是 sing-box 代理 outbound。

## 支持环境

- Debian / Ubuntu
- CentOS / Rocky Linux / RHEL 系发行版
- Alpine Linux
- systemd 或 OpenRC
- CPU：amd64、arm64；Alpine 回退下载还支持 armv7
- Bash 4.0+

CentOS/Rocky 主机的内核必须支持 WireGuard。非常旧的 CentOS 版本可能还需要自行安装内核模块，建议使用仍受维护的系统版本。

## 安装

推荐直接使用一键安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/Jyanbai/Ping-WireGuard/main/install.sh | sudo bash
```

`install.sh` 会自动从 GitHub 下载完整项目，并重新连接当前终端继续数字交互。整个过程不会把 GitHub 令牌写入系统。

也可以下载完整项目后执行：

```bash
chmod +x install.sh
sudo ./install.sh
```

安装器会：

1. 按发行版安装 WireGuard、curl、iproute2、nftables/iptables 等依赖。
2. 安装或升级到兼容的 sing-box 稳定版（要求 1.10+）。
3. 把管理文件安装到 `/usr/local/lib/ping-wireguard/`，把入口安装为 `/usr/local/bin/ping-wg`。
4. 交互式生成 WireGuard 服务端和首个客户端配置。
5. 启用 IP 转发、防火墙规则、systemd/OpenRC 自启动和 sing-box 崩溃自动重启。

安装完成后运行：

```bash
sudo ping-wg
```

客户端配置位于 `/etc/ping-wireguard/client.conf`，权限为 `0600`。请通过安全通道复制后导入 WireGuard 客户端。

### 已有服务保护

- 如果安装前发现系统自带的 `sing-box.service` 正在运行，安装器会停止并提示，不会直接中断现有代理业务。
- 如果 `/etc/wireguard/wg0.conf` 已存在且不是本项目生成，第一次写入前会备份为 `wg0.conf.ping-wg.bak.<时间>`。
- 云厂商安全组仍需手动放行所选 WireGuard UDP 端口。

## 数字管理菜单

```text
Ping-WireGuard 管理菜单

  1. 一键安装
  2. 导入外部节点
  3. 查看当前节点与状态
  4. 切换出站节点
  5. 重启服务
  6. 查看日志
  7. 重新配置
  8. 卸载
  9. 退出
```

“重新配置”只更新 WireGuard/MTU/地址等配置并重启服务，不重复安装软件。服务端与客户端密钥会保留。

## 导入节点

在菜单选择 `2`，直接粘贴分享链接：

```text
vless://UUID@example.com:443?encryption=none&security=tls&sni=example.com&type=ws&path=%2Fws#香港
```

或：

```text
ss://BASE64(method:password)@example.com:8388#东京
```

### VLESS 支持范围

- `security=none`、`tls`、`reality`
- Reality：`pbk/publicKey`、`sid/shortId`、`sni`、`fp`
- 传输：TCP/raw、WebSocket、gRPC、HTTP/H2、HTTPUpgrade
- `flow=xtls-rprx-vision`
- 外部节点地址支持 IPv4、域名、`[IPv6]:port`

解析器会拒绝无效 UUID、未知 security/flow/transport，以及缺少 `pbk` 的 Reality 链接。v1 暂不转换 XHTTP 等 sing-box 配置语义不明确的第三方扩展。

### Shadowsocks 支持范围

- SIP002：`ss://BASE64(method:password)@host:port`
- 旧格式：`ss://BASE64(method:password@host:port)`
- sing-box 当前支持的 AEAD、AEAD 2022 和兼容旧加密方法
- SIP003 插件：`obfs-local` / `simple-obfs`、`v2ray-plugin`
- 外部节点地址支持 IPv4、域名、`[IPv6]:port`

v1 给 WireGuard 客户端分配 IPv4 地址，客户端配置只宣告 `0.0.0.0/0`；外部代理服务器本身仍可使用 IPv6 地址。客户端 IPv6 全隧道计划放到后续版本，当前不会生成一个实际不可用的 `::/0` 路由。

未知加密方法或插件会被拒绝，不会生成“看似成功但无法启动”的配置。

### 节点保存与切换

- 节点原始 URI：`/etc/ping-wireguard/nodes/<id>.uri`
- 节点 outbound JSON：`/etc/ping-wireguard/nodes/<id>.json`
- 无凭据索引：`/etc/ping-wireguard/nodes.tsv`
- 当前节点 ID：`/etc/ping-wireguard/current-node`

目录和凭据文件只允许 root 访问。切换时会先渲染临时配置并执行 `sing-box check`，校验成功才原子替换正式配置；服务重启失败时会尝试回滚原节点。

未选择节点时使用 `block` 占位 outbound：服务可以启动和诊断，但客户端流量会失败关闭（fail closed），不会从落地机公网出口意外直连。实际链式中转前必须导入并选择外部节点。

## sing-box 配置模板

模板位于 `templates/sing-box.json.template`，核心结构如下：

```json
{
  "inbounds": [
    {
      "type": "tun",
      "tag": "wg-tun-in",
      "interface_name": "pingtun0",
      "address": ["172.19.0.1/30"],
      "mtu": 1380,
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true,
      "include_interface": ["wg0"]
    }
  ],
  "outbounds": [
    "由 import-node.sh 生成的当前节点 outbound"
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
```

项目使用 Bash 逐行替换固定占位符，不使用 `eval`、jq 或把外部 URI 当 Shell 代码加载。

## 目录结构

```text
Ping-WireGuard/
├── install.sh
├── ping-wg.sh
├── scripts/
│   ├── common.sh
│   ├── firewall.sh
│   ├── import-node.sh
│   ├── services.sh
│   ├── singbox.sh
│   └── wg.sh
├── templates/
│   └── sing-box.json.template
├── tests/
│   ├── test-bootstrap.sh
│   └── test-import.sh
├── .gitignore
├── README.md
└── LICENSE
```

模块职责：

- `common.sh`：路径、日志、系统检测、服务抽象、校验和设置持久化。
- `wg.sh`：密钥、服务端/客户端配置、IP 转发。
- `import-node.sh`：URI/Base64/百分号解码、字段校验、JSON 转义和节点保存。
- `singbox.sh`：模板渲染、配置校验、节点列表、切换与回滚。
- `firewall.sh`：nftables/iptables，以及已启用的 firewalld/UFW 兼容规则。
- `services.sh`：systemd/OpenRC 服务与自动重启。

## 服务与日志

systemd：

```bash
systemctl status ping-wireguard-wg
systemctl status ping-wireguard-singbox
journalctl -u ping-wireguard-singbox -e
```

OpenRC：

```bash
rc-service ping-wireguard-wg status
rc-service ping-wireguard-singbox status
```

OpenRC 的 sing-box 输出保存到 `/var/log/ping-wireguard/`。

## 测试

在 Linux 或带 GNU 工具的 Bash 环境运行：

```bash
bash -n install.sh ping-wg.sh scripts/*.sh tests/*.sh
bash tests/test-import.sh
bash tests/test-bootstrap.sh
```

测试覆盖一键脚本离线自举，以及 VLESS Reality/gRPC、VLESS WebSocket、SIP002 Shadowsocks、旧式 Shadowsocks、IPv6、插件、错误拒绝、模板占位符和 JSON 语法。

## 卸载

从菜单选择 `8`。卸载会删除项目服务、配置、密钥、节点和客户端文件，但保留系统安装的 WireGuard 与 sing-box 软件包，避免误伤其他用途。此前生成的 `wg0.conf.ping-wg.bak.*` 备份不会删除。

## 上游文档

- [sing-box TUN inbound](https://sing-box.sagernet.org/configuration/inbound/tun/)
- [sing-box VLESS outbound](https://sing-box.sagernet.org/configuration/outbound/vless/)
- [sing-box Shadowsocks outbound](https://sing-box.sagernet.org/configuration/outbound/shadowsocks/)
- [sing-box 安装文档](https://sing-box.sagernet.org/installation/package-manager/)

## License

MIT
