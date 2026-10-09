# singbox-lite 竞品功能对比

> 对比对象：https://github.com/0xdabiaoge/singbox-lite（README 标注版本：singbox.sh v28）
> 我方版本：SingBox-YUY v0.3.4（2026-10-09）
> 结论一句话：对方是**单文件大而全的运维脚本**（双核心、多协议、中转转发一条龙），我们是**模块化+智能分流**（WARP 解锁、订阅服务、CLI/TUI 双模式、CI 测试）。协议广度与运维纵深我们差一截，智能出站与工程化我们领先。

## 一、协议支持

| 协议 | singbox-lite | SingBox-YUY |
|---|---|---|
| VLESS + Reality + Vision | ✅ | ✅ |
| Hysteria2 | ✅（+Salamander 混淆、+端口跳跃） | ✅（基础） |
| TUIC v5 | ✅ | ✅ |
| AnyTLS / Any-Reality | ✅（可同时创建） | ✅（AnyTLS） |
| Shadowsocks | ✅ 经典 aes-128/256-gcm、chacha20、xchacha20、3 种 SS2022、SS2022+Padding、SS2022+ShadowTLS v3 | ⚠️ 仅 `2022-blake3-aes-128-gcm` |
| Trojan（WS+TLS） | ✅ | ❌ |
| VLESS-WS-TLS / VLESS-gRPC-TLS | ✅ | ❌ |
| 纯 VLESS + TCP（无加密） | ✅ | ❌ |
| SOCKS5 inbound | ✅（用户名/密码） | ❌ |
| Xray 双核心（8 种协议：gRPC-Reality、XHTTP 等） | ✅ | ❌ |
| Argo 隧道（临时/固定） | ✅ | ❌ |

## 二、安装 / 升级 / 卸载

| 能力 | singbox-lite | SingBox-YUY |
|---|---|---|
| 一键安装（curl\|bash） | ✅ 单文件 `sb` | ✅ 单文件 `dist/sb` |
| 安装后快捷命令 | ✅ `sb` | ✅ `sb` |
| 脚本自更新 | ✅（四组件预下载校验后统一提交） | ✅ `sb self-update`（校验和比对+CDN穿透） |
| 核心版本锁定（防升级） | ✅ 可锁定 1.13.21 | ❌ |
| 核心下载 SHA-256 校验 | ✅（官方标签+资产名+摘要+二进制版本四重校验） | ⚠️ 仅 GitHub API 取最新版，无摘要校验 |
| 一键卸载 | ✅（按进程→规则→服务→状态依赖顺序清理） | ❌ |
| 无 init 系统降级（direct 后台模式） | ✅ | ❌（仅提示手动前台运行） |
| 低内存优化（128MB 容器、GOMEMLIMIT） | ✅ | ❌ |

## 三、交互体验

| 能力 | singbox-lite | SingBox-YUY |
|---|---|---|
| 交互菜单 | ✅ 数字菜单（19 项） | ✅ whiptail 九项菜单（无 whiptail 降级数字菜单） |
| CLI 非交互命令 | ❌（纯菜单） | ✅ 全命令 CLI 化 |
| 中文界面 | ✅ | ✅ |
| 批量创建节点 | ✅（多协议组合、端口规划、冲突检查、整批回滚） | ❌ |
| 修改节点（改名/端口/密码/SNI/证书轮换） | ✅（按协议显示可改项，保存失败回滚） | ❌（只能删了重建） |
| 查看实时日志 | ✅ | ❌ |
| 修改监听端口 | ✅（独立功能） | ❌（需删重建） |

## 四、订阅 / 分享

| 能力 | singbox-lite | SingBox-YUY |
|---|---|---|
| 标准 URI 链接 | ✅ | ✅ |
| 终端二维码 | ❌ | ✅（qrencode） |
| sing-box 客户端 JSON | ❌（只有 clash.yaml） | ✅ |
| Mihomo/Clash YAML | ✅（sing-box+Xray 共享） | ✅ |
| 聚合 Base64 订阅（手动生成） | ✅ | ❌（我们是 HTTP 服务形式） |
| HTTP 订阅服务（token 鉴权） | ❌ | ✅（3 路由：base64/singbox/clash） |
| CF 优选专用链接 | ✅ | ❌ |

## 五、中转 / 转发

| 能力 | singbox-lite | SingBox-YUY |
|---|---|---|
| 中转（前置→落地） | ✅（本机 Token ENC2 AES-256-CBC / 第三方节点导入，二选一中转入口协议） | ✅（relay-add/route/del，geosite 绑定） |
| 第三方节点严格导入 | ✅（白名单解析器：vless/ss/http/socks5，拒绝非白名单协议） | ⚠️（relay-add --link 支持 vless/trojan/ss/hysteria2/tuic/anytls，校验较宽松） |
| 端口转发 | ✅（nftables DNAT 能力探测，降级 sing-box 用户态转发；TCP/UDP、v4/v6/域名、命名规则、每分钟 DNS 刷新） | ❌ |
| WARP 链式出站 | ❌ | ✅（wireguard endpoint + 注册） |
| 流媒体/AI 解锁分流 | ❌ | ✅（geosite 规则集，广告拦截常开） |

## 六、运维功能

| 能力 | singbox-lite | SingBox-YUY |
|---|---|---|
| DNS 设置菜单 | ✅（DoH、prefer_go 等） | ❌（写死默认） |
| 定时重启 | ✅ | ❌（只有核心每周自动更新） |
| 时间诊断 / NTP 补偿 | ✅（SS2022 时钟漂移处理） | ❌ |
| 配置备份 / 恢复 | ⚠️（仅 DNS 修改有备份） | ❌（有 check 失败回滚，无备份恢复） |
| 流量统计 | ❌ | ❌（都没有） |
| 节点测速 | ❌ | ❌（都没有） |

## 七、安全与可靠性（双方都有，列出差异点）

| 能力 | singbox-lite | SingBox-YUY |
|---|---|---|
| 写配置前校验 | ✅ sing-box check + 组合校验 | ✅ sing-box check |
| 失败回滚 | ✅（事务快照） | ✅（修改前快照） |
| 并发写锁 | ✅（跨脚本共享锁） | ❌（单进程假设） |
| 敏感文件权限收紧 | ✅（root-only、临时文件清理） | ⚠️（未系统化） |
| 端口冲突检查 | ✅（主节点/中转/转发/跳跃范围联动） | ✅（builder 端口/tag 预检） |

## 八、差距清单（对方有、我们没有）

| # | 差距 | 实现代价 | 是否需重启 sing-box |
|---|---|---|---|
| 1 | 节点修改（改名/改端口/换密码/换 SNI/证书轮换） | 中 | 是 |
| 2 | Trojan 协议（WS+TLS） | 中 | 是（新增节点时） |
| 3 | VLESS-WS-TLS / VLESS-gRPC-TLS | 中 | 是（新增节点时） |
| 4 | 经典 SS 加密方式（aes-128/256-gcm、chacha20、xchacha20） | 小 | 是（新增节点时） |
| 5 | SOCKS5 inbound | 小 | 是（新增节点时） |
| 6 | Hysteria2 端口跳跃 | 中 | 是 |
| 7 | 批量创建节点 | 中 | 是 |
| 8 | 一键卸载 | 小 | 否（删除动作） |
| 9 | DNS 设置菜单 | 小 | 是 |
| 10 | 定时重启 | 小 | 否 |
| 11 | 实时日志查看 | 小 | 否 |
| 12 | 核心版本锁定 | 小 | 否 |
| 13 | 端口转发（nftables/用户态双引擎） | 大 | 规则变更时是 |
| 14 | Argo 隧道 | 大 | 否（独立进程） |
| 15 | Xray 双核心 | 大 | 否（独立服务） |
| 16 | 第三方节点严格导入（白名单解析器） | 中 | 是（中转 outbound） |
| 17 | 低内存优化（GOMEMLIMIT） | 小 | 否 |
| 18 | direct 后台模式（无 init 系统） | 小 | 否 |

## 九、我们独有的（对方没有）

1. **WARP 链式出站 + 流媒体/AI 解锁分流**（对方完全没有 WARP 概念）
2. **HTTP 订阅服务**（token 鉴权，三格式同源；对方只有手动聚合 Base64）
3. **CLI 全命令非交互**（对方纯菜单，无法脚本化）
4. **sing-box 客户端 JSON 导出**（对方只有 clash.yaml）
5. **终端二维码**
6. **CI 自动化测试矩阵**（对方无）
7. **多系统包管理器矩阵更广**（Arch/openSUSE；对方重点 Debian/Ubuntu/Alpine）

## 十、建议优先补的功能排序（只排序，不实现）

1. **节点修改**（代价中，需重启）—— 用户最高频操作：改备注、改端口、换密码、轮换 Reality 密钥/SNI。现在只能删了重建，体验断层最大。
2. **Trojan 协议**（代价中，需重启）—— 补协议短板。NekoBox/Mihomo/v2rayNG 全支持，用户切 CDN/落地场景常用。
3. **一键卸载**（代价小，不需重启）—— 生命周期完整性：清服务、清定时任务、清 /etc/sing-box、可选删二进制。现在装完就没有回头路。
4. **Hysteria2 端口跳跃**（代价中，需重启）—— 弱网/移动网络体验提升明显，对方 README 重点宣传的特性；且 sing-box 原生支持 `udp_ports` 跳跃区间， mostly 配置层工作。
