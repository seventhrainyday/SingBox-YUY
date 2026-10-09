#!/usr/bin/env bash
# install.sh - sing-box 官方二进制下载安装、systemd 注册、cron 自动更新
# 用法：install_main [--yes]

SB_REPO="SagerNet/sing-box"

install_main() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1

    local arch
    arch=$(detect_arch)
    [ "$arch" = "amd64" ] || [ "$arch" = "arm64" ] || die "不支持的架构：$arch（仅 amd64/arm64）"

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

    need_root
    install -m 0755 "$bin" "$SB_BIN" || die "安装到 $SB_BIN 失败"
    log_ok "已安装：$("$SB_BIN" version 2>/dev/null | head -1)"

    ensure_etc
    # 首次安装生成一个最小可运行配置（无 inbound），避免 service 启动失败
    if [ ! -f "$CONFIG_JSON" ]; then
        python3 "$(builder_py)" || log_warn "初始配置渲染失败，稍后可用 sb-mgr check 重试"
    fi

    register_systemd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../systemd" && pwd)"
    register_cron

    trap - EXIT
    rm -rf "$tmpd"
    log_ok "sing-box 安装完成"
}

register_systemd() {
    # $1: service 文件来源目录
    local src="$1"
    [ -n "$src" ] || die "register_systemd 缺少 service 目录参数"
    if ! have_systemd; then
        log_warn "未检测到 systemd，跳过服务注册（容器/Docker 内请用前台运行：$SB_BIN run -c $CONFIG_JSON）"
        return 0
    fi
    need_root
    install -m 0644 "$src/sing-box.service" /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    systemctl enable --now sing-box 2>/dev/null || systemctl enable sing-box
    log_ok "systemd 服务 sing-box 已注册并设为开机自启"
}

register_cron() {
    # 每周一 03:30 检查更新
    need_root
    local script=/usr/local/bin/sbyuy-auto-update
    cat > "$script" <<'EOF'
#!/usr/bin/env bash
# SingBox-YUY 每周自动更新 sing-box（由 install.sh 注册）
set -euo pipefail
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
CUR=$(basename "$("$SB_BIN" version 2>/dev/null | head -1)" 2>/dev/null || echo none)
TAG=$(curl -fsS -m 30 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
if [ -n "$TAG" ] && [ "$TAG" != "null" ] && ! "$SB_BIN" version 2>/dev/null | grep -q "$TAG"; then
    logger -t sbyuy "sing-box $CUR -> $TAG，开始更新"
    export SB_MGR_YES=1
    /opt/SingBox-YUY/sb-mgr install --yes >/var/log/sbyuy-update.log 2>&1 || logger -t sbyuy "自动更新失败，见 /var/log/sbyuy-update.log"
else
    logger -t sbyuy "sing-box 已是最新（$TAG）"
fi
EOF
    chmod 0755 "$script"
    local cronline="30 3 * * 1 root $script"
    if [ -f /etc/crontab ]; then
        grep -q "sbyuy-auto-update" /etc/crontab 2>/dev/null || echo "$cronline" >> /etc/crontab
        log_ok "已注册每周自动更新任务（/etc/crontab，每周一 03:30）"
    else
        (crontab -l 2>/dev/null | grep -v "sbyuy-auto-update"; echo "$cronline" | sed 's/^[^ ]* [^ ]* \* \* [^ ]* root //') | crontab -
        log_ok "已注册每周自动更新任务（root crontab）"
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
