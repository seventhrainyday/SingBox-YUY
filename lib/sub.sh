#!/usr/bin/env bash
# sub.sh - 订阅服务管理
#   sb-mgr sub [start|stop|restart|regen]   无参数=显示订阅链接
#   sb-mgr sub-regen                        重新生成 token（同 sub regen）

SUB_SVC="singbox-yuy-sub"

sub_regen_main() {
    ensure_etc
    local tok
    tok=$(rand_hex 16)
    json_set "$SETTINGS_JSON" --arg t "$tok" '.sub_token = $t'
    log_ok "订阅 token 已重新生成"
    sub_show_main
}

sub_show_main() {
    ensure_etc
    local tok port host
    tok=$(json_get "$SETTINGS_JSON" '.sub_token // ""')
    port=$(json_get "$SETTINGS_JSON" '.sub_port // 2096')
    if [ -z "$tok" ]; then
        log_warn "尚未生成 token，执行：sb-mgr sub regen"
        return 0
    fi
    host=$(export_host)
    echo "订阅链接（通用 base64）："
    echo "  http://${host}:${port}/sub/${tok}"
    echo "订阅链接（sing-box 客户端 JSON）："
    echo "  http://${host}:${port}/sub/${tok}/singbox"
    echo "订阅链接（Mihomo YAML）："
    echo "  http://${host}:${port}/sub/${tok}/clash"
    if svc_is_active "$SUB_SVC" 2>/dev/null; then
        echo "服务状态：运行中"
    else
        echo "服务状态：未运行（sb-mgr sub start 启动）"
    fi
}

sub_svc_main() { # start|stop|restart
    local act="${1:-}"
    case "$act" in
        start|stop|restart) ;;
        *) die "用法：sb-mgr sub [start|stop|restart|regen]" ;;
    esac
    ensure_etc
    local tok
    tok=$(json_get "$SETTINGS_JSON" '.sub_token // ""')
    [ -n "$tok" ] || { sub_regen_main >/dev/null; }
    need_root
    # bundled 单文件模式：模板从 $SB_HOME payloads 取，路径指向 bundle 自身
    local root mgr_bin srvpy
    if [ "${SB_BUNDLED:-}" = "1" ]; then
        root="${SB_HOME:?SB_HOME 未设置}"
        mgr_bin="${SB_SELF:-$(command -v sb 2>/dev/null || echo /usr/local/bin/sb)}"
        srvpy="$SB_HOME/py/subsrv.py"
    else
        root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        mgr_bin="$root/sb-mgr"
        srvpy="$root/lib/subsrv.py"
    fi
    if has_systemd; then
        sed -e "s|^Environment=SB_MGR=.*|Environment=SB_MGR=$mgr_bin|" \
            -e "s|^ExecStart=/usr/bin/python3 .*|ExecStart=/usr/bin/python3 $srvpy|" \
            "$root/systemd/singbox-yuy-sub.service" \
            > "/etc/systemd/system/${SUB_SVC}.service"
        chmod 0644 "/etc/systemd/system/${SUB_SVC}.service"
        svc_daemon_reload
    elif has_openrc; then
        sed -e "s|^: \"\${SB_MGR:=.*\"|: \"\${SB_MGR:=$mgr_bin}\"|" \
            -e "s|^: \"\${SB_SUBSRV:=.*\"|: \"\${SB_SUBSRV:=$srvpy}\"|" \
            "$root/openrc/singbox-yuy-sub.initd" \
            > "/etc/init.d/${SUB_SVC}"
        chmod 0755 "/etc/init.d/${SUB_SVC}"
    else
        log_warn "未检测到 systemd/OpenRC，请前台手动运行："
        echo "  SB_ETC=$SB_ETC python3 $srvpy"
        return 0
    fi
    case "$act" in
        start)   svc_enable "$SUB_SVC" && svc_start "$SUB_SVC" ;;
        stop)    svc_stop "$SUB_SVC" ;;
        restart) svc_restart "$SUB_SVC" ;;
    esac
    log_ok "$SUB_SVC 已 $act"
}

sub_main() { # [start|stop|restart|regen] 缺省显示链接
    case "${1:-}" in
        "") sub_show_main ;;
        start|stop|restart) sub_svc_main "$1" ;;
        regen) sub_regen_main ;;
        *) die "用法：sb-mgr sub [start|stop|restart|regen]" ;;
    esac
}
