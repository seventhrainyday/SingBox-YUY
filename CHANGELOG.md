# CHANGELOG

## v0.3.2（2026-10-09）

### 修复
- `sb self-update` 下载时对 http(s) URL 自动加时间戳穿透 CDN 缓存：raw.githubusercontent.com 有约 5 分钟缓存，之前刚推送完就 self-update 会拿到旧文件并误判"已是最新"。

## v0.3.1（2026-10-09）

### 修复
- `sb self-update` 改为按文件校验和（sha256）判断是否需要更新：之前只比版本号，同版本热修复（如 v0.3.0 的 TUI 变量名修复）会被误判为"已是最新"而拉不下来；现在内容不同即更新，sha256sum 不可用时保守地执行更新。
- 修复 v0.3.0 遗留：`lib/tui.sh` 菜单标题漏改的旧变量名 `$SBYUY_VERSION`（去代号时被 grep 排除条件误伤），导致无参数 `sb` 进 TUI 直接报错退出。

## v0.3.0（2026-10-09）

### 单文件发行版
- 新增 `dist/build.sh`：把全部 `lib/*.sh` 内联 + 7 个 payload（`py/builder.py`、`py/subsrv.py`、`py/aesgcm.py`、systemd/openrc 模板）base64 内嵌，打包成单个可执行文件 `dist/sb`（~130KB），提交进仓库供用户直接 curl。
- 安装体验：`(curl -LfsS <raw>/dist/sb -o /usr/local/bin/sb || wget -q <raw>/dist/sb -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb install`，之后永远只用 `sb`。
- bundle 运行时自动释放 payload 到 `$SB_HOME`（root 默认 `/opt/singbox-yuy`，普通用户 `~/.singbox-yuy`），版本标记变化或文件缺失时自动重释放；`SB_HOME`/`SB_DIST_URL` 环境变量可覆盖。
- 新增 `sb self-update`：仅单文件版可用，从 `SB_DIST_URL` 下载新版替换自身（校验 bundle 标记，非法文件拒绝写入）。
- 源码兼容补丁（`SB_BUNDLED=1` 分支，repo 模式行为不变）：`builder_py()`、`install_main` 的 `register_service` root、`register_autoupdate` 的管理命令路径（安装时解析 `command -v sb`）、`sub.sh` 的 root/subsrv 路径与 service 模板变量替换、`crypto.sh` 的 `LIBDIR`、`subsrv.py` 的管理命令解析顺序（SB_MGR → ../sb-mgr → `command -v sb` → /usr/local/bin/sb）。
- 根目录 `install.sh`（git clone 方式）保留为备选安装方式。

## v0.2.1（2026-10-09）

### 修复
- Alpine（musl）兼容：sing-box 1.14.x 官方二进制为 glibc 动态链接，在 musl 系统上直接执行报 `not found`。安装后新增二进制冒烟测试（`sing-box version`），失败且检测到 musl 时自动安装 `gcompat` 兼容层；仍失败则报错退出，不再静默装一个跑不起来的服务。`pkg_name` 新增 `gcompat` 映射（仅 apk 有，其余包管理器无映射自动跳过）。

## v0.2.0（2026-10-09）

### 一键安装
- 新增仓库根目录 `install.sh`：`curl -fsSL https://raw.githubusercontent.com/seventhrainyday/SingBox-YUY/main/install.sh | sudo bash` 一行安装；支持 `bash -s -- args...` 参数透传（如 `--proto hy2 --port 8443 --yes`）
- 逻辑：必须 root（非 root 直接报错提示加 sudo，不自动提权）；优先 `git clone` 到 `/opt/SingBox-YUY`（已存在则 `git pull --ff-only`，非 git 目录先备份再克隆）；无 git 时尝试包管理器安装，实在装不上回退下载 tarball；最后 `exec sb-mgr install "$@"`

### 多系统支持
- `lib/common.sh` 新增 `detect_pm()`（/etc/os-release 识别，`OS_RELEASE_FILE` 可覆盖测试）与 `pkg_install()`（通用包名→各发行版实际包名映射矩阵：curl/jq/python3/openssl/ca-certificates/iproute2/qrencode/whiptail/procps/git；qrencode/whiptail 可选，失败只警告）
- 覆盖：Debian 11/12、Ubuntu 22.04/24.04（apt-get）、RHEL/Alma/Rocky 8/9（dnf，7 系 yum）、Fedora（dnf）、Alpine 3.18+（apk）、Arch（pacman）、openSUSE（zypper）
- 服务抽象 `svc_enable/start/restart/stop/is_active`：systemd 与 OpenRC 自动分支；`apply_config`、`sub.sh`、`tui.sh`/`sb-mgr` 内原直接 `systemctl` 调用全部改走 `svc_*`
- 新增 `openrc/`：`singbox.initd`（start_pre 先 `sing-box check -c`，失败拒绝启动）、`singbox-yuy-sub.initd`
- 自动更新三分支：有 crontab 走 cron（每周一 03:30）；OpenRC 无 cron 时装到 `/etc/periodic/weekly/singbox-auto-update`（run-parts 风格）；都没有则打印手动执行提示
- sing-box 二进制下载新增 armv7 映射（armv7l→armv7）
- Hysteria2/TUIC 的 sysctl 调优：无 `/etc/sysctl.d` 的系统改写 `/etc/sysctl.conf`（Alpine），`sysctl --system` 失败则已用 `sysctl -w` 即时生效
- `envcheck` 输出包管理器与 init 系统；CI 测试矩阵新增 `almalinux:9`、`rockylinux:9`；`tests/run.sh` 新增"多系统逻辑自测"（伪造 os-release 断言 detect_pm + 全矩阵包名映射非空）

### 去掉代号（v0.1.0 刚发布尚无真实用户，直接重命名，不做兼容层）
- 环境变量统一 `SB_` 前缀：`SB_VERSION`（值 `0.2.0`）、`SB_BAK_NODES`/`SB_BAK_SETTINGS`、`SB_SYSCTL_D`、`SB_WG_PRIV_HEX`、`SB_TOKEN`/`SB_PORT`/`SB_MGR`、`SB_PW`/`SB_LIB`
- 自动更新脚本改名 `singbox-auto-update`，`logger` tag 改为 `singbox-yuy`
- sysctl 调优文件改名 `99-singbox-yuy.conf`
- AnyTLS 用户名改为 `"user"`；订阅服务 `server_version` 改为 `SingBox-YUY-Sub/0.2.0`
- 订阅服务单元改名 `singbox-yuy-sub.service`（systemd 与 openrc 同名）
- 加密包头与 AAD 改为 `SB-` 前缀（`SB-AES256GCM-V*`）；旧版加密包不再可读，无用户受影响
- README 标题及全文去掉代号表述；测试临时目录改为 `/tmp/sb-mgr-test`

## v0.1.0（2026-10-09）

首个可用版本：从零实现的 sing-box 一键安装/运维工具（bash + python），CLI + TUI 双模式。

### 核心骨架
- `sb-mgr` 统一入口：完整 CLI 参数解析，无参数进 TUI
- `lib/common.sh`：日志/颜色/die/架构检测/公网 IP/端口检查；`SB_ETC`/`SB_BIN` 环境变量覆盖，支持无 root 测试
- `lib/builder.py`：配置渲染核心（nodes.json + settings.json → config.json），含 `client`/`clash`/`parse-link`/`node-outbound` 子命令与 `--test` 示例生成模式；已适配 sing-box 1.12+ 新 DNS 服务器格式、1.13 移除 dns 出站、WARP 改用 wireguard endpoint（路由规则直接引用其 tag）
- 每次写配置必经 `sing-box check`，失败自动回滚 nodes.json/settings.json
- `systemd/`：sing-box.service 与 singbox-yuy-sub.service 单元文件

### 环境与安装
- `lib/envcheck.sh`：OS/架构（amd64/arm64）/TUN/内核版本/BBR/依赖自检，缺失项给修复提示
- `lib/install.sh`：GitHub API 取最新版 sing-box，arch 映射下载解压到 /usr/local/bin，systemd 注册，cron 每周一 03:30 自动更新；`sb-mgr update` 手动更新

### 5 种 inbound 协议（`lib/inbound.sh`）
- VLESS + REALITY + Vision：7 个推荐 SNI 交互选择/自定义，`sing-box generate` 生成 UUID/keypair/short_id
- Hysteria2：自签证书一键生成，`--acme` 可选 Let's Encrypt（acme.sh），自动调大 UDP 缓冲区并持久化到 /etc/sysctl.d/99-singbox-yuy.conf
- TUIC v5：uuid+password 双凭证，bbr 拥塞控制
- AnyTLS：name 固定 user，导出链接最短化防移动端截断
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
