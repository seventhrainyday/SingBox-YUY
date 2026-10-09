#!/usr/bin/env bash
# tui.sh - whiptail 交互菜单；无 whiptail 时降级为 bash select 数字菜单

_have_whiptail() { command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; }

tui_msg() { # $1=标题 $2=文本
    if _have_whiptail; then
        whiptail --title "$1" --msgbox "$2" 18 72
    else
        printf '\n=== %s ===\n%s\n' "$1" "$2"
    fi
}

tui_input() { # $1=标题 $2=提示 $3=默认值 -> 输出到 stdout
    local title="$1" prompt="$2" def="${3:-}" ans
    if _have_whiptail; then
        ans=$(whiptail --title "$title" --inputbox "$prompt" 10 60 "$def" 3>&1 1>&2 2>&3) || return 1
        printf '%s' "$ans"
    else
        printf '%s [%s]：' "$prompt" "$def" >&2
        read -r ans
        printf '%s' "${ans:-$def}"
    fi
}

tui_yesno() { # $1=提示 -> 0=yes
    if _have_whiptail; then
        whiptail --yesno "$1" 10 60
    else
        printf '%s [y/N]：' "$1" >&2
        read -r ans
        case "$ans" in [yY]*) return 0;; *) return 1;; esac
    fi
}

tui_menu() { # $1=标题 $2=提示 起始于$3: tag item tag item...
    # 回显选中的 tag（stdout），取消返回 1
    local title="$1" prompt="$2"; shift 2
    if _have_whiptail; then
        whiptail --title "$title" --menu "$prompt" 20 70 12 "$@" 3>&1 1>&2 2>&3
    else
        local tags=() items=() i=0 n=1
        while [ $# -ge 2 ]; do tags+=("$1"); items+=("$2"); shift 2; done
        printf '\n=== %s ===\n' "$title" >&2
        for i in "${!tags[@]}"; do printf '  %d) %s\n' "$((i+1))" "${items[$i]}" >&2; done
        printf '  0) 返回/退出\n' >&2
        printf '请选择 [0-%d]：' "${#tags[@]}" >&2
        read -r n
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#tags[@]}" ]; then
            printf '%s' "${tags[$((n-1))]}"
        else
            return 1
        fi
    fi
}

tui_pause() {
    [ -t 0 ] || return 0
    if ! _have_whiptail; then printf '\n回车继续...'; read -r _; fi
}

tui_add_node() {
    local p
    p=$(tui_menu "添加节点" "选择协议" \
        reality "VLESS + REALITY + Vision" \
        hy2 "Hysteria2" \
        tuic "TUIC v5" \
        anytls "AnyTLS" \
        trojan "Trojan" \
        ss2022 "Shadowsocks 2022") || return 0
    local port remark
    case "$p" in
        reality) port=443;; hy2) port=8443;; tuic) port=443;;
        anytls) port=8443;; trojan) port=443;; ss2022) port=8388;;
    esac
    port=$(tui_input "添加节点" "监听端口" "$port") || return 0
    remark=$(tui_input "添加节点" "备注（可空）" "") || remark=""
    case "$p" in
        reality) add_reality --port "$port" --remark "$remark" ;;
        hy2)
            local sni hports
            sni=$(tui_input "Hysteria2" "TLS 域名/SNI" "www.sony.com") || return 0
            hports=$(tui_input "Hysteria2" "端口跳跃区间 起始:结束（空=不启用）" "") || hports=""
            if [ -n "$hports" ]; then
                add_hy2 --port "$port" --sni "$sni" --remark "$remark" --ports "$hports"
            else
                add_hy2 --port "$port" --sni "$sni" --remark "$remark"
            fi ;;
        tuic)
            local sni2
            sni2=$(tui_input "TUIC" "TLS 域名/SNI" "www.sony.com") || return 0
            add_tuic --port "$port" --sni "$sni2" --remark "$remark" ;;
        anytls)
            local sni3
            sni3=$(tui_input "AnyTLS" "TLS 域名/SNI" "www.microsoft.com") || return 0
            add_anytls --port "$port" --sni "$sni3" --remark "$remark" ;;
        trojan)
            local sni4
            sni4=$(tui_input "Trojan" "TLS 域名/SNI" "www.sony.com") || return 0
            add_trojan --port "$port" --sni "$sni4" --remark "$remark" ;;
        ss2022) add_ss2022 --port "$port" --remark "$remark" ;;
    esac
    tui_pause
}

tui_modify_node() {
    local id
    id=$(tui_input "修改节点" "节点 ID（先用 列表 查看）" "") || return 0
    [ -n "$id" ] || return 0
    local node proto
    node=$(node_json "$id") || return 0
    proto=$(jq -r .proto <<<"$node")
    tui_msg "当前节点" "$(jq -r '"协议: \(.proto)\n端口: \(.port)\n备注: \(.remark)\nSNI: \(.sni // "-")\n跳跃: \(.ports // "-")"' <<<"$node")"
    local remark port sni password uuid ports
    local args=(--id "$id")
    remark=$(tui_input "修改节点" "新备注（空=不改）" "") || return 0
    [ -n "$remark" ] && args+=(--remark "$remark")
    port=$(tui_input "修改节点" "新端口（空=不改）" "") || return 0
    [ -n "$port" ] && args+=(--port "$port")
    case "$proto" in
        reality|hy2|tuic|anytls|trojan)
            sni=$(tui_input "修改节点" "新 SNI（空=不改）" "") || return 0
            [ -n "$sni" ] && args+=(--sni "$sni") ;;
    esac
    case "$proto" in
        hy2|tuic|anytls|trojan|ss2022)
            password=$(tui_input "修改节点" "新密码（空=不改）" "") || return 0
            [ -n "$password" ] && args+=(--password "$password") ;;
    esac
    case "$proto" in
        reality)
            uuid=$(tui_input "修改节点" "新 UUID（空=不改）" "") || return 0
            [ -n "$uuid" ] && args+=(--uuid "$uuid")
            tui_yesno "重新生成 Reality 密钥对？" && args+=(--regen-key) ;;
        hy2)
            ports=$(tui_input "修改节点" "跳跃区间 起始:结束（空=不改，-=清除）" "") || return 0
            if [ "$ports" = "-" ]; then args+=(--ports "")
            elif [ -n "$ports" ]; then args+=(--ports "$ports"); fi ;;
    esac
    if [ "${#args[@]}" -le 2 ]; then
        tui_msg "修改节点" "未修改任何字段"
        return 0
    fi
    node_modify "${args[@]}"
    tui_pause
}

tui_manage_nodes() {
    local c
    c=$(tui_menu "节点管理" "选择操作" \
        list "列出所有节点" \
        link "查看节点链接/二维码" \
        modify "修改节点" \
        del "删除节点") || return 0
    case "$c" in
        list) list_inbounds; tui_pause ;;
        link)
            local id
            id=$(tui_input "节点链接" "节点 ID" "") || return 0
            [ -n "$id" ] || return 0
            link_main "$id"
            if tui_yesno "是否渲染二维码？"; then
                link_main "$id" --qr
            fi
            tui_pause ;;
        modify) tui_modify_node ;;
        del)
            local id2
            id2=$(tui_input "删除节点" "节点 ID" "") || return 0
            [ -n "$id2" ] || return 0
            tui_yesno "确认删除节点 $id2？" && del_inbound "$id2"
            tui_pause ;;
    esac
}

tui_warp() {
    local c
    c=$(tui_menu "WARP 与解锁" "选择操作" \
        warp "注册/更新 WARP" \
        unlock "开启 流媒体/AI 解锁分流" \
        lock "关闭 解锁分流") || return 0
    case "$c" in
        warp) warp_main ;;
        unlock) route_unlock_main ;;
        lock) route_lock_main ;;
    esac
    tui_pause
}

tui_relay() {
    local c
    c=$(tui_menu "中转链" "选择操作" \
        list "列出中转出站" \
        add "添加中转（粘贴节点链接）" \
        route "为中转绑定 geosite 分流规则" \
        del "删除中转") || return 0
    case "$c" in
        list) relay_list_main; tui_pause ;;
        add)
            local link
            link=$(tui_input "添加中转" "粘贴节点链接" "") || return 0
            [ -n "$link" ] || return 0
            relay_add_main --link "$link"; tui_pause ;;
        route)
            local tag gs
            tag=$(tui_input "绑定规则" "中转 tag（如 relay-1）" "") || return 0
            gs=$(tui_input "绑定规则" "geosite 列表，逗号分隔" "netflix,youtube") || return 0
            relay_route_main --tag "$tag" --geosite "$gs"; tui_pause ;;
        del)
            local tag2
            tag2=$(tui_input "删除中转" "中转 tag" "") || return 0
            relay_del_main --tag "$tag2"; tui_pause ;;
    esac
}

tui_sub_export() {
    local c
    c=$(tui_menu "订阅与导出" "选择操作" \
        show "显示订阅链接" \
        regen "重新生成订阅 token" \
        svc "启动/重启订阅服务" \
        uri "导出全部标准 URI" \
        singbox "导出 sing-box 客户端 JSON" \
        clash "导出 Mihomo YAML") || return 0
    case "$c" in
        show) sub_show_main; tui_pause ;;
        regen) sub_regen_main; tui_pause ;;
        svc) sub_svc_main restart; tui_pause ;;
        uri) export_main --format uri; tui_pause ;;
        singbox)
            local f
            f=$(tui_input "导出" "保存路径" "/tmp/singbox-client.json") || return 0
            export_main --format singbox --out "$f"; tui_pause ;;
        clash)
            local f2
            f2=$(tui_input "导出" "保存路径" "/tmp/clash.yaml") || return 0
            export_main --format clash --out "$f2"; tui_pause ;;
    esac
}

tui_crypto() {
    local c
    c=$(tui_menu "加密导入导出" "选择操作" \
        export "加密导出节点库" \
        import "解密导入节点库") || return 0
    case "$c" in
        export)
            local f pw
            f=$(tui_input "加密导出" "输出文件" "/tmp/nodes.enc") || return 0
            pw=$(tui_input "加密导出" "加密密码" "") || return 0
            [ -n "$pw" ] || { tui_msg "提示" "密码不能为空"; return 0; }
            crypto_export_main --out "$f" --password "$pw"; tui_pause ;;
        import)
            local f2 pw2
            f2=$(tui_input "解密导入" "输入文件" "/tmp/nodes.enc") || return 0
            pw2=$(tui_input "解密导入" "解密密码" "") || return 0
            crypto_import_main --in "$f2" --password "$pw2" --yes; tui_pause ;;
    esac
}

tui_system() {
    local c
    c=$(tui_menu "系统" "选择操作" \
        info "查看系统信息（BBR/防火墙提示）" \
        uninstall "卸载 SingBox-YUY") || return 0
    case "$c" in
        info)
            local cc bbr_hint
            cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
            bbr_hint="当前拥塞控制：$cc"
            [ "$cc" = "bbr" ] || bbr_hint="$bbr_hint（建议开启 BBR：见 envcheck 输出）"
            tui_msg "系统信息" "$bbr_hint

防火墙提示：
- 确保节点监听端口（TCP/UDP）已在安全组/防火墙放行
- Hysteria2/TUIC 需要放行 UDP
- ACME 签证书需要放行 TCP 80

订阅服务端口：$(json_get "$SETTINGS_JSON" '.sub_port // 2096')（TCP）"
            tui_pause ;;
        uninstall)
            if tui_yesno "确认卸载 SingBox-YUY？配置将备份到 /tmp"; then
                uninstall_main --yes
            fi
            tui_pause ;;
    esac
}

tui_main() {
    ensure_etc
    while true; do
        local c
        c=$(tui_menu "SingBox-YUY v$SB_VERSION" "现代化 sing-box 运维工具" \
            envcheck "① 环境自检" \
            install "② 安装/更新 sing-box" \
            add "③ 添加节点" \
            manage "④ 节点管理（列表/链接/修改/删除）" \
            warp "⑤ WARP 与解锁路由" \
            relay "⑥ 中转链" \
            sub "⑦ 订阅与导出" \
            crypto "⑧ 加密导入导出" \
            system "⑨ 系统（BBR/防火墙提示）" \
            quit "⓪ 退出") || break
        case "$c" in
            envcheck) envcheck_main; tui_pause ;;
            install) install_main; tui_pause ;;
            add) tui_add_node ;;
            manage) tui_manage_nodes ;;
            warp) tui_warp ;;
            relay) tui_relay ;;
            sub) tui_sub_export ;;
            crypto) tui_crypto ;;
            system) tui_system ;;
            quit) break ;;
        esac
    done
    log_info "再见"
}
