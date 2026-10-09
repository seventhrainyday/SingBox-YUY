# SingBox-YUY

现代化、模块化、原生支持智能出站与多协议链式分流的 **sing-box** 自动化运维工具。

- **CLI + TUI 双模式**：`sb-mgr` 一条命令走天下，无参数进 whiptail 交互菜单（无 whiptail 自动降级数字菜单）
- **5 种协议一键部署**：VLESS+REALITY+Vision、Hysteria2、TUIC v5、AnyTLS、Shadowsocks-2022
- **智能出站**：Cloudflare WARP（WireGuard）链式出站 + 流媒体/AI 解锁分流 + 自定义中转链
- **三端兼容导出**：标准 URI（含二维码）、sing-box 客户端 JSON、Mihomo（Clash.Meta）YAML
- **订阅服务**：内置轻量 HTTP 订阅（token 鉴权，三格式同源）
- **加密对接**：AES-256-GCM 加密节点库，前置机 ↔ 落地机一键对接
- **每次写配置必校验**：`sing-box check` 不通过自动回滚，绝不写坏配置

## 架构

```
┌─────────────────────────────────────────────────────────┐
│ sb-mgr（入口：CLI 解析 / 无参数进 TUI）                    │
├──────────┬──────────┬──────────┬──────────┬──────────────┤
│ envcheck │ install  │ inbound  │ warp     │ route        │
│ 自检     │ 安装更新 │ 5协议管理 │ WARP注册 │ 解锁/中转规则 │
├──────────┴──────────┴──────────┴──────────┴──────────────┤
│ builder.py（渲染核心：nodes.json + settings.json → config.json）│
├──────────┬──────────┬──────────┬─────────────────────────┤
│ export   │ subsrv   │ crypto   │ tui                     │
│ URI/二维码│ 订阅HTTP │ AES加密  │ whiptail 交互菜单        │
│ /客户端JSON/Clash   │ 服务     │ 导入导出 │              │
└──────────┴──────────┴──────────┴─────────────────────────┘
        状态文件（/etc/sing-box，可用 SB_ETC 覆盖）：
        nodes.json（节点库） settings.json（warp/token/中转）
        config.json（builder 渲染产物，sing-box 直接运行）
```

## 快速开始

一行命令安装（下载单文件 `sb` 到 `/usr/local/bin/sb`，之后永远只用 `sb`）：

```bash
(curl -LfsS https://raw.githubusercontent.com/seventhrainyday/SingBox-YUY/main/dist/sb -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/seventhrainyday/SingBox-YUY/main/dist/sb -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb install
```

> 已是 root（提示符为 `#`）无需 sudo；若 `curl`/`wget` 都没有，先装 curl。

装完之后：

```bash
sb install --proto hy2 --port 8443 --yes   # 装 sing-box + 直接建好 Hysteria2 节点
sb add --proto reality --port 443          # 交互式添加 Reality 节点（选 SNI）
sb link <id> --qr                          # 查看链接 / 二维码
sb self-update                             # 更新 sb 自身到最新版
sb                                         # 无参数进 TUI 交互菜单
```

备选安装方式（仓库根目录 `install.sh`，会 git clone 完整源码到 `/opt/SingBox-YUY`）：

```bash
curl -fsSL https://raw.githubusercontent.com/seventhrainyday/SingBox-YUY/main/install.sh | sudo bash
# 已是 root 请去掉 sudo，直接 | bash
```

手动 git clone（开发/改代码用）：

```bash
git clone https://github.com/seventhrainyday/SingBox-YUY.git /opt/SingBox-YUY
cd /opt/SingBox-YUY

# 1. 一键安装 sing-box + 环境自检
sudo ./sb-mgr install

# 2. 添加节点（示例：Reality，交互式选 SNI）
sudo ./sb-mgr add --proto reality --port 443

# 无交互一键（脚本/CI 用）：
sudo ./sb-mgr install --proto hy2 --port 8443 --yes

# 3. 查看链接 / 二维码
./sb-mgr link <id> --qr

# 4. TUI 菜单
sudo ./sb-mgr
```

## 系统支持

| 发行版 | 包管理器 | init 系统 | 备注 |
|---|---|---|---|
| Debian 11 / 12 | apt-get | systemd | CI 实测 |
| Ubuntu 22.04 / 24.04 | apt-get | systemd | CI 实测 |
| RHEL / AlmaLinux / RockyLinux 8 / 9 | dnf（7 系用 yum） | systemd | CI 实测 alma/rocky 9 |
| Fedora | dnf | systemd | — |
| Alpine 3.18+ | apk | OpenRC | 无 whiptail 时 TUI 自动降级数字菜单；sysctl 持久化改写 /etc/sysctl.conf |
| Arch Linux | pacman | systemd | — |
| openSUSE Leap / Tumbleweed | zypper | systemd | — |

- 依赖安装全自动（`sb-mgr install` 内走包管理器矩阵装 curl/jq/python3/openssl 等）；`qrencode`/`whiptail` 为可选，装不上只警告不中断。
- 服务注册自动分支：systemd 写 unit 并 enable；OpenRC 安装 `openrc/*.initd` 并 `rc-update add`。
- 自动更新：有 cron 走 cron（每周一 03:30）；OpenRC 无 cron 时装到 `/etc/periodic/weekly`；都没有则打印手动执行提示。

## CLI 命令表

| 命令 | 说明 |
|---|---|
| `sb-mgr install [--proto P] [--port N] [--domain D] [--sni S] [--yes]` | 安装/更新 sing-box 最新版，自动装依赖，注册服务（systemd/OpenRC）+ 每周自动更新；带 `--proto` 装完直接建节点 |
| `sb-mgr update` | 手动检查并更新 sing-box 到最新版 |
| `sb-mgr envcheck` | 环境自检：OS/架构/TUN/内核/BBR/依赖 |
| `sb-mgr add --proto reality\|hy2\|tuic\|anytls\|ss2022 [参数]` | 添加节点（`--port/--sni/--domain/--password/--remark/--yes`，hy2 支持 `--acme` 走 Let's Encrypt） |
| `sb-mgr list` / `sb-mgr del <id>` | 列出 / 删除节点 |
| `sb-mgr link <id> [--qr]` | 打印标准 URI；`--qr` 终端渲染二维码（需 qrencode） |
| `sb-mgr warp` | 注册 Cloudflare WARP 并写入 wireguard 出站 |
| `sb-mgr route-unlock` / `sb-mgr route-lock` | 开/关 流媒体+AI 解锁分流（走 warp，需先 `warp`） |
| `sb-mgr relay-add --link "vless://..."` | 解析标准链接为中转出站（支持 vless/trojan/ss，含 reality 参数） |
| `sb-mgr relay-add --from-node <id> [--host H]` | 从节点库选节点做中转出站 |
| `sb-mgr relay-route --tag relay-1 --geosite netflix,youtube` | 为中转绑定 geosite 分流规则 |
| `sb-mgr relay-del --tag relay-1` / `sb-mgr relay-list` | 删除 / 列出中转 |
| `sb-mgr export --format uri\|singbox\|clash [--out FILE] [--id ID]` | 导出标准 URI / sing-box 客户端 JSON / Mihomo YAML |
| `sb-mgr sub [start\|stop\|restart\|regen]` | 显示订阅链接 / 管理订阅服务 / 重生成 token（`sub-regen` 同 `sub regen`） |
| `sb-mgr set-host <IP/域名>` | 设置链接与订阅中的 HOST（不设则自动探测公网 IP） |
| `sb-mgr node-export --out f.enc --password PW` | AES-256-GCM 加密导出节点库 |
| `sb-mgr node-import --in f.enc --password PW` | 解密导入并合并（按 id 去重） |
| `sb-mgr check` | 重渲染 + `sing-box check` 校验当前配置 |
| `sb-mgr tui` / `sb-mgr version` / `sb-mgr help` | 交互菜单 / 版本 / 帮助 |
| `sb self-update` | 仅单文件版：从 SB_DIST_URL 下载新版替换自身 |

## TUI 菜单

无参数运行 `sb-mgr` 即进菜单：①环境自检 ②安装/更新 ③添加节点（二级协议菜单）
④节点管理（列表/链接/删除）⑤WARP 与解锁路由 ⑥中转链 ⑦订阅与导出
⑧加密导入导出 ⑨系统（BBR/防火墙提示）⓪退出。无 whiptail 时自动降级为数字菜单。

## 协议与客户端兼容

| 协议 | 端口默认 | 认证 | NekoBox | sing-box 官方客户端 | Mihomo |
|---|---|---|---|---|---|
| VLESS + REALITY + Vision | 443 | UUID + reality 密钥对 | ✅ URI 导入 | ✅ JSON/outbound | ✅ vless + reality-opts |
| Hysteria2 | 8443 | 密码 + TLS（自签/ACME） | ✅ | ✅ | ✅（skip-cert-verify） |
| TUIC v5 | 443 | UUID + 密码 + TLS | ✅ | ✅ | ✅ |
| AnyTLS | 8443 | 密码（name=user）+ TLS | ✅（链接已做最短化，防移动端截断） | ✅ | ✅（新版本） |
| Shadowsocks 2022 | 8388 | `2022-blake3-aes-128-gcm` | ✅ | ✅ | ✅ |

> Reality SNI 内置推荐：`www.sony.com / www.microsoft.com / www.apple.com / www.amazon.com / dl.google.com / www.cloudflare.com / www.samsung.com`，支持自定义。

## WARP 与解锁分流

```bash
sudo ./sb-mgr warp           # 注册 WARP（纯 curl+jq+openssl，无需 wg 二进制）
sudo ./sb-mgr route-unlock   # 流媒体/AI 域名走 warp
```

- WARP 出站为 WireGuard **endpoint**（`engage.cloudflareclient.com:2408`，sing-box 1.13 起 wireguard 出站类型已移除，改用顶层 endpoints；路由规则直接引用其 tag），密钥对本地 X25519 生成。
- 解锁规则（remote rule-set，二进制 srs，自动下载）：
  - 流媒体：netflix / youtube / disney / hbo / hulu / primevideo / spotify / tiktok
  - AI：openai / anthropic / gemini / copilot
  - 广告：`geosite-category-ads-all` → block（常开）
- 未配置 WARP 时解锁规则自动降级走 direct，不会写坏配置。

## 中转链

```bash
# 前置机：把落地机节点链接解析为出站
sudo ./sb-mgr relay-add --link "vless://uuid@落地机:443?security=reality&sni=...&pbk=...#备注"
sudo ./sb-mgr relay-route --tag relay-1 --geosite netflix,openai
```

## 订阅服务

```bash
sudo ./sb-mgr sub regen     # 生成 token
sudo ./sb-mgr sub start     # 启动订阅服务 singbox-yuy-sub（systemd/OpenRC 自动分支）
./sb-mgr sub                # 显示三个订阅链接
```

- `http://HOST:PORT/sub/<token>` → base64（URI 列表，通用客户端）
- `http://HOST:PORT/sub/<token>/singbox` → sing-box 客户端 JSON
- `http://HOST:PORT/sub/<token>/clash` → Mihomo YAML
- token 错误返回 404；token 与端口可在 `settings.json` 中改（`sub_port`/`sub_token`）。

## 加密传输（前置机 ↔ 落地机）

```bash
# 落地机导出
./sb-mgr node-export --out nodes.enc --password '强密码'
# 前置机导入（自动合并去重 → 重渲染 → check → 重启）
sudo ./sb-mgr node-import --in nodes.enc --password '强密码'
# 再把导入的节点做成中转出站
sudo ./sb-mgr relay-add --from-node <id> --host <落地机地址>
```

算法：AES-256-GCM，PBKDF2-HMAC-SHA256（20 万轮）。有 `cryptography` 库用 V2（随机 salt/nonce），
否则回退纯标准库实现的 V3（`lib/aesgcm.py`，已与 cryptography 库交叉验证）；
文件头自描述版本，import 自动识别。错误密码直接拒绝。
> 注：`openssl enc` 命令不支持 AEAD/GCM，因此不用它做加解密。

## 配置安全

- 每次写入 `nodes.json`/`settings.json` 后必经：`builder.py` 渲染 → `sing-box check -c` →
  失败则**回滚**两个状态文件并报错退出；通过才重启 sing-box 服务。
- `builder.py` 另做合法性预检：端口冲突、tag 重复直接拒绝渲染。

## 测试与 CI

```bash
bash tests/run.sh
```

覆盖：shellcheck 零警告 → bash -n → py_compile → `builder.py --test` 生成 5 协议示例 →
**真实 sing-box 二进制 `check`** 逐个校验服务端/客户端配置 → Mihomo YAML 结构解析 →
AES 加密回环 diff → 订阅服务冒烟（3 路由 200 + 错误 token 404）→
`sb-mgr add/link/export/relay/del` 端到端 → builder 端口冲突负向测试。

GitHub Actions（`.github/workflows/ci.yml`）：lint job → test 矩阵
`ubuntu-22.04 / ubuntu-24.04 / debian:11 / debian:12 / alpine:latest / almalinux:9 / rockylinux:9` →
dist-check（bundle 与源码一致性）。

## 单文件发行版

`/usr/local/bin/sb` 即 `dist/sb`：单个 bash 文件，内嵌全部 `lib/*.sh` 与 7 个 payload
（`py/*.py`、systemd/openrc 模板），base64 编码。首次运行时自动释放 payload 到
`$SB_HOME`（root 默认为 `/opt/singbox-yuy`，普通用户为 `~/.singbox-yuy`，
`SB_HOME` 环境变量可覆盖），并写入版本标记；版本变化或文件缺失时自动重新释放。

- `dist/sb` **由 `dist/build.sh` 生成，必须提交进仓库**（用户从
  `raw.githubusercontent.com` 直接 curl 它）。
- 不要手工改 `dist/sb`：改源码后重跑 `bash dist/build.sh` 重新生成。
- `sb self-update`：从 `SB_DIST_URL`（默认即上述 raw 链接，可用环境变量覆盖）
  下载新版替换自身，`curl -fsSL` 失败或内容校验不通过则拒绝更新。

## FAQ

- **无 root 能测吗？** 能。`SB_ETC=/tmp/x SB_BIN=/path/to/sing-box bash tests/run.sh`，
  所有 lib 函数都认这两个环境变量覆盖。
- **订阅服务不用 systemd/OpenRC 怎么跑？** `SB_ETC=/etc/sing-box python3 lib/subsrv.py` 前台运行；
  token/port 读 `settings.json`（或 `SB_TOKEN`/`SB_PORT` 环境变量）。
- **Hysteria2 连不上？** 先确认 UDP 端口放行；脚本已自动调大 `net.core.rmem_max/wmem_max`。
- **ACME 签证书失败？** 域名必须解析到本机且 TCP 80 可从公网访问；也可先用自签跑通再换。
- **AnyTLS 链接在手机上导入被截断？** 导出链接已是最短形式（仅 `insecure`+`sni` 两个参数）。
- **relay 出站连不上？** 先 `sb-mgr export --format uri --id <源节点id>` 确认源链接本身可用。

## 已知限制

- `sing-box check` 不下载 remote rule-set（srs）；首次启动需联网拉取 geosite 规则集。
- Mihomo 的 `anytls` 代理类型需较新版本内核才支持。
- WARP 注册依赖 `api.cloudflareclient.com` 可达；部分网络需先走代理。
- 架构支持 amd64 / arm64 / armv7；32 位 armv7 需 sing-box 官方提供对应构建。

## 许可证

MIT
