# CHANGELOG

## v0.1.0（2026-10-09）

首个可用版本：从零实现的 sing-box 一键安装/运维工具（bash + python），CLI + TUI 双模式。

### 核心骨架
- `sb-mgr` 统一入口：完整 CLI 参数解析，无参数进 TUI
- `lib/common.sh`：日志/颜色/die/架构检测/公网 IP/端口检查；`SB_ETC`/`SB_BIN` 环境变量覆盖，支持无 root 测试
- `lib/builder.py`：配置渲染核心（nodes.json + settings.json → config.json），含 `client`/`clash`/`parse-link`/`node-outbound` 子命令与 `--test` 示例生成模式；已适配 sing-box 1.12+ 新 DNS 服务器格式、1.13 移除 dns 出站、WARP 改用 wireguard endpoint（路由规则直接引用其 tag）
- 每次写配置必经 `sing-box check`，失败自动回滚 nodes.json/settings.json
- `systemd/`：sing-box.service 与 sbyuy-sub.service 单元文件

### 环境与安装
- `lib/envcheck.sh`：OS/架构（amd64/arm64）/TUN/内核版本/BBR/依赖自检，缺失项给修复提示
- `lib/install.sh`：GitHub API 取最新版 sing-box，arch 映射下载解压到 /usr/local/bin，systemd 注册，cron 每周一 03:30 自动更新；`sb-mgr update` 手动更新

### 5 种 inbound 协议（`lib/inbound.sh`）
- VLESS + REALITY + Vision：7 个推荐 SNI 交互选择/自定义，`sing-box generate` 生成 UUID/keypair/short_id
- Hysteria2：自签证书一键生成，`--acme` 可选 Let's Encrypt（acme.sh），自动调大 UDP 缓冲区并持久化到 /etc/sysctl.d/99-sbyuy.conf
- TUIC v5：uuid+password 双凭证，bbr 拥塞控制
- AnyTLS：name 固定 yuy，导出链接最短化防移动端截断
- Shadowsocks-2022：`2022-blake3-aes-128-gcm`，base64(16 随机字节) 密码

### 智能出站与路由
- `lib/warp.sh`：纯 curl+jq+openssl 注册 Cloudflare WARP，X25519 密钥对本地生成（openssl3 / python-cryptography 双路径），写入 wireguard 出站
- `lib/route.sh`：`route-unlock` 开启流媒体（8 站）+AI（4 站）走 warp（remote srs rule-set），广告 geosite 常驻 block；`relay-add/route/del/list` 自定义链式中转（vless/trojan/ss 链接解析或从节点库选取）

### 订阅与导出
- `lib/export.sh`：标准 URI（5 协议，remark URL 编码）、`link --qr` 二维码、`export --format singbox`（mixed+socks 入站，selector+urltest）、`export --format clash`（Mihomo proxies/groups/rules）
- `lib/subsrv.py` + `lib/sub.sh`：stdlib 订阅 HTTP 服务（/sub/&lt;token&gt;[/singbox|/clash]，token 错 404），systemd 启停，token 重生成；`--test` 自包含冒烟测试

### 加密传输
- `lib/crypto.sh`：AES-256-GCM + PBKDF2(20 万轮) 加密节点库；cryptography 可用时 V2，否则纯标准库 V3（`lib/aesgcm.py`，手写 AES-256 + GCM，已与 cryptography 库交叉验证）；文件头自描述版本；import 按 id 去重合并后重渲染+校验

### TUI
- `lib/tui.sh`：whiptail 九项主菜单 + 协议二级菜单；无 whiptail/非 TTY 自动降级 bash select 数字菜单

### 测试与 CI
- `tests/run.sh`：shellcheck 零警告 → bash -n → py_compile → 真实 sing-box 二进制 check 全部示例配置 → clash YAML 解析 → crypto 回环 diff → 订阅冒烟 → sb-mgr 端到端 → builder 负向测试
- `.github/workflows/ci.yml`：lint job + ubuntu-22.04/24.04、debian:11/12、alpine:latest 测试矩阵
