#!/usr/bin/env bash
# install.sh - sing-box 官方二进制下载安装、服务注册（systemd/OpenRC）、自动更新
# 用法：install_main [--yes]

SB_REPO="SagerNet/sing-box"

install_main() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1

    need_root
    log_info "安装依赖（curl jq python3 openssl ca-certificates iproute2 procps）..."
    pkg_install curl jq python3 openssl ca-certificates iproute2 procps qrencode whiptail \
        || log_warn "部分依赖安装失败，继续尝试（缺失项稍后按提示手动安装）"

    local arch
    arch=$(detect_arch)
    case "$arch" in
        amd64|arm64|armv7) ;;
        *) die "不支持的架构：$arch（仅 amd64/arm64/armv7）" ;;
    esac

    log_info "正在查询 sing-box 最新版本..."
    local tag
    tag=$(curl -fsS -m 20 "https://api.github.com/repos/${SB_REPO}/releases/latest" | jq -r '.tag_name') \
        || die "GitHub API 查询失败，请检查网络"
    [ -n "$tag" ] && [ "$tag" != "null" ] || die "未能解析到 tag_name"
    local ver="${tag#v}"
    log_info "最新版本：$tag"

    if [ -x "$SB_BIN" ]; then
        local cur
        cur=$("$SB_BIN" version 2>/dev/null | head -1 || true)
        log_info "当前已安装：$cur"
        if [ "$yes" -eq 0 ]; then
            printf '是否重新安装/更新到 %s？[y/N] ' "$tag"
            read -r ans
            case "$ans" in [yY]*) ;; *) log_info "已取消"; return 0;; esac
        fi
    fi

    local url="https://github.com/${SB_REPO}/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz"
    local tmpd
    tmpd=$(mktemp -d) || die "mktemp 失败"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpd'" EXIT

    log_info "下载：$url"
    curl -fSL -m 300 -o "$tmpd/sb.tar.gz" "$url" || die "下载失败"
    tar -xzf "$tmpd/sb.tar.gz" -C "$tmpd" || die "解压失败"
    local bin
    bin=$(find "$tmpd" -maxdepth 2 -name sing-box -type f | head -1)
    [ -n "$bin" ] || die "压缩包内未找到 sing-box 二进制"

    install -m 0755 "$bin" "$SB_BIN" || die "安装到 $SB_BIN 失败"
    log_ok "已安装：$("$SB_BIN" version 2>/dev/null | head -1)"

    ensure_etc
    # 首次安装生成一个最小可运行配置（无 inbound），避免 service 启动失败
    if [ ! -f "$CONFIG_JSON" ]; then
        python3 "$(builder_py)" || log_warn "初始配置渲染失败，稍后可用 sb-mgr check 重试"
    fi

    register_service "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    register_autoupdate

    trap - EXIT
    rm -rf "$tmpd"
    log_ok "sing-box 安装完成"
}

register_service() {
    # $1: 项目根目录（含 systemd/ 与 openrc/）
    local root="$1"
    [ -n "$root" ] || die "register_service 缺少项目根目录参数"
    need_root
    if has_systemd; then
        install -m 0644 "$root/systemd/sing-box.service" /etc/systemd/system/sing-box.service
        svc_daemon_reload
        systemctl enable --now sing-box 2>/dev/null || systemctl enable sing-box
        log_ok "systemd 服务 sing-box 已注册并设为开机自启"
    elif has_openrc; then
        install -m 0755 "$root/openrc/singbox.initd" /etc/init.d/singbox
        rc-update add singbox default
        rc-service singbox start
        log_ok "OpenRC 服务 singbox 已注册并启动"
    else
        log_warn "未检测到 systemd/OpenRC，跳过服务注册（前台运行：$SB_BIN run -c $CONFIG_JSON）"
    fi
}

register_autoupdate() {
    # 自动更新：cron 优先；OpenRC 无 cron 时走 /etc/periodic/weekly；都没有则手动提示
    need_root
    local script=/usr/local/bin/singbox-auto-update
    cat > "$script" <<'EOF'
#!/usr/bin/env bash
# SingBox-YUY 每周自动更新 sing-box（由 install.sh 注册）
set -euo pipefail
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
CUR=$(basename "$("$SB_BIN" version 2>/dev/null | head -1)" 2>/dev/null || echo none)
TAG=$(curl -fsS -m 30 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
if [ -n "$TAG" ] && [ "$TAG" != "null" ] && ! "$SB_BIN" version 2>/dev/null | grep -q "$TAG"; then
    logger -t singbox-yuy "sing-box $CUR -> $TAG，开始更新"
    export SB_MGR_YES=1
    /opt/SingBox-YUY/sb-mgr install --yes >/var/log/singbox-yuy-update.log 2>&1 || logger -t singbox-yuy "自动更新失败，见 /var/log/singbox-yuy-update.log"
else
    logger -t singbox-yuy "sing-box 已是最新（$TAG）"
fi
EOF
    chmod 0755 "$script"
    if command -v crontab >/dev/null 2>&1; then
        local cronline="30 3 * * 1 root $script"
        if [ -f /etc/crontab ]; then
            grep -q "singbox-auto-update" /etc/crontab 2>/dev/null \
                || echo "$cronline" >> /etc/crontab
            log_ok "已注册每周自动更新任务（/etc/crontab，每周一 03:30）"
        else
            (crontab -l 2>/dev/null | grep -v "singbox-auto-update";
             echo "$cronline" | sed 's/^[^ ]* [^ ]* \* \* [^ ]* root //') | crontab -
            log_ok "已注册每周自动更新任务（root crontab）"
        fi
    elif [ -d /etc/periodic/weekly ]; then
        # OpenRC run-parts 风格：脚本本身即任务体，无需 cron 时间头
        install -m 0755 "$script" /etc/periodic/weekly/singbox-auto-update
        log_ok "已注册每周自动更新（/etc/periodic/weekly/singbox-auto-update）"
    else
        log_warn "未找到 crontab 且无 /etc/periodic/weekly；可手动执行 $script 更新 sing-box"
    fi
}

update_main() {
    # 手动检查并更新到最新版
    local tag cur
    tag=$(curl -fsS -m 20 "https://api.github.com/repos/${SB_REPO}/releases/latest" | jq -r '.tag_name') \
        || die "GitHub API 查询失败"
    if [ -x "$SB_BIN" ] && "$SB_BIN" version 2>/dev/null | grep -q "$tag"; then
        log_ok "已是最新版本：$tag"
        return 0
    fi
    cur=$([ -x "$SB_BIN" ] && "$SB_BIN" version 2>/dev/null | head -1 || echo "未安装")
    log_info "当前：$cur，最新：$tag，开始更新..."
    install_main --yes
}
