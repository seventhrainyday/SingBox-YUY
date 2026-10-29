# CHANGELOG

## v0.4.1（2026-10-29）

### 修复（重要）
- **规则集下载地址全错，守护进程启动即 FATAL**：geosite 规则集仓库名误写为不存在的 `SagerNet/sing-box-geosite`（正确：`SagerNet/sing-geosite`）；AI 列表里的 `gemini`/`copilot` 条目在仓库中不存在（正确：`google-gemini`/`github-copilot`，sing-geosite 无微软 Copilot 条目故用 GitHub Copilot）。默认配置也中招（广告拦截集常开），拉不到规则集 sing-box 直接拒绝启动。已逐个 URL 验证返回 200，测试新增"全部 rule_set URL 返回 200"断言。
- **sing-box ≥1.14 守护进程无法启动**：生成的配置给 DNS server 写了 `"detour": "direct"`，1.14 起这是运行时硬错误（`detour to an empty direct outbound makes no sense`），进程启动即退出；但 `sing-box check` 查不出来，OpenRC 后台启动还会假报 `[ok]`，极具迷惑性。已移除该字段（语义不变，DNS 本就走直连）；同时移除 1.14 已弃用、1.16 将删除的 rule_set `download_detour`。测试新增"守护进程真启动"用例（实际 `run` 二进制断言输出 `sing-box started` 且存活），堵住"只 check 不 run"的盲区。
- **TUI 输错一个字符就退出**：降级菜单把任何无效输入都当作"退出"，包括中文输入法发出的全角数字（如 `３`）——用户选"3 添加节点"会直接看到"再见"退出。现改为：输入先清洗（去空白/回车、全角转半角），无效只提示重输，只有 `0`/EOF 才退出；`_pick_sni` 的序号、端口输入同步清洗。
- **Alpine 可选包映射错误**：whiptail 在 Alpine 的包名是 `newt`（此前误写 whiptail）、qrencode 命令行工具在 `libqrencode-tools` 包里（此前误写 qrencode），导致这两个可选包在 Alpine 上永远装不上（只能用降级菜单、无二维码）。已对照 Alpine 3.21 仓库索引修正映射。
- CI 容器矩阵全红修复（v0.4.0 推送后 5 个容器 job 全灭）：debian-11 切 archive.debian.org（bullseye EOL，security 源已归档）；debian-12/alpine/debian-11 补 shellcheck（tests/run.sh 缺失时直接 fail）；alpine 补 gcompat（glibc 动态链接的 sing-box 二进制在 musl 下 exit 127）；almalinux-9/rockylinux-9 加 epel-release + ShellCheck（EPEL 提供）。

### 文档
- README 已知限制新增条目：sing-box 全版本客户端（含 NekoBox）连 Xray ≥26.9.8 的 Reality 节点必失败，与 uTLS 指纹无关——服务端要求 ClientHello 携带 X25519MLKEM768 密钥份额，sing-box 的 Reality 客户端层会将其丢弃（上游 SagerNet/sing-box#4520 仍 open）；临时方案：客户端改用 Xray 内核（v2rayNG），或服务端降级到 <26.9.8。

### 优化
- 服务（systemd/OpenRC）内置 `GOMEMLIMIT=48MiB` + `GOGC=50` 软限制，抑制负载下 Go 堆膨胀。实测 sing-box 1.14.4 空载 RSS 约 59MB（规则集真加载后测得；默认 1 个集与全解锁 13 个集几乎无差，瓶颈是 sing-box 本体而非规则集）——**64MB 整机内存不足以稳定运行，128MB 起较稳**。
- 生成配置开启 `experimental.cache_file`：重启不再重新下载规则集（实测第二次启动零下载），小机器启动更快更省。
- `sb install` 在拒绝重装二进制时不再直接退出，改为刷新配置与服务定义并重启服务——脚本升级后老用户选 N 即可完成配置/服务迁移（本次 DNS 修复就走这条路）。

## v0.4.0（2026-10-09）

### 新增
- **节点修改**：`sb-mgr node-modify --id <id> [--remark/--port/--sni/--password/--uuid/--regen-key/--ports]`，按协议校验合法字段（非法组合直接拒绝）；改端口自动同步 tag；reality 换 SNI 时自签证书原地重签；hy2 可用 `--ports` 开关跳跃。TUI 节点管理菜单新增"修改节点"。
- **Trojan 协议**：`sb-mgr add --proto trojan`（TLS 自签证书），link 输出标准 `trojan://`，export 三格式（uri/singbox/clash）与订阅服务全支持，relay-add 可解析 trojan 链接做中转。TUI 添加节点菜单新增第 6 项。
- **一键卸载**：`sb-mgr uninstall [--yes] [--purge-binary]`——停服务、删 unit/init、清 cron 定时任务、备份配置到 `/tmp/singbox-yuy-backup-<日期>.tar.gz`、删配置目录；sing-box 二进制默认保留，`sb` 本体永远不动。TUI 系统菜单新增"卸载 SingBox-YUY"（二次确认）。
- **Hysteria2 端口跳跃**：`add-hy2 --ports 起始:结束`（单区间≤32 端口）。实测 sing-box 1.14.3 的 hysteria2 inbound 不支持跳跃字段，服务端用"多 inbound 监听"等效实现；客户端 outbound 原生支持 `server_ports`，singbox JSON / clash YAML / URI 导出自动携带。

## v0.3.4（2026-10-09）

### 修复
- `relay-add --link` 现在支持解析自家生成的全部 6 种链接（vless/trojan/ss/hysteria2/tuic/anytls）：之前 `parse_link` 只认 vless/trojan/ss，hy2/tuic/anytls 做中转直接报错。
- 修复中转 ss 出站类型名错误：`parse_link` 返回 `"type": "ss"`，sing-box 合法类型是 `"shadowsocks"`，多条中转并存时 `sing-box check` 报 `unknown outbound type: ss` 并回滚。
- 测试套件根除 SIGPIPE 竞态：`cmd | grep -q` 在 `set -o pipefail` 下 grep 提前退出会导致生产者收 SIGPIPE 偶发失败，改为"输出收进变量 + `[[ == *pattern* ]]`"断言；修复 tests/run.sh:198 调用未定义 `log_warn` 导致的中断。
- README：中转链接支持列表更新为 6 种协议。

### 测试
- 新增 [10/10] 全功能矩阵：CLI 冒烟、5 协议 add、TUI 全流程（伪造 TTY 复现"选完备注卡死"场景）、5 协议 URI 正则、`--qr` 降级、export 三格式、`sub regen` token 轮换、加密边界、中转 5 协议全链路、route-unlock/lock、9 种非法输入鲁棒性。**154 通过，0 失败**。
- `docs/singbox-lite-compare.md`：与 0xdabiaoge/singbox-lite 的功能对比。

## v0.3.3（2026-10-09）

### 修复
- TUI 添加 Reality 节点时"卡死"：`_pick_sni` 在 `$()` 命令替换中运行时，选单提示走了 stdout 被吞掉（用户看到空白终端以为卡死），且选出的 sni 会被菜单文字污染。现全部交互提示改走 stderr，只有最终结果走 stdout（与 `tui_input` 一致）。另审计全仓库其他 `read` 点，确认仅此一处在命令替换中使用。

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
