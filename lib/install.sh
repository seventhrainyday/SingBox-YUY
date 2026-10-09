#!/usr/bin/env bash
# install.sh - sing-box 官方二进制下载安装、服务注册（systemd/OpenRC）、自动更新
# 用法：install_main [--yes]

SB_REPO="SagerNet/sing-box"

ensure_binary_runnable() {
    # $1=二进制路径。冒烟测试 sing-box 能否执行；musl 系统（Alpine 等）上
    # glibc 链接的官方二进制需 gcompat 兼容层，自动尝试安装一次。
    # 返回 0=可运行，1=不可运行。ALPINE_RELEASE_FILE 可覆盖 Alpine 标记文件路径（供测试）。
    local bin="$1"
    "$bin" version >/dev/null 2>&1 && return 0
    local alpine_release="${ALPINE_RELEASE_FILE:-/etc/alpine-release}"
    if [ -f "$alpine_release" ] || ldd --version 2>&1 | grep -qi musl; then
        log_info "二进制无法直接运行，尝试安装 gcompat 兼容层..."
        # 子 shell 跑 pkg_install：其内部 die 只退出子 shell，不中断安装主流程
        ( pkg_install gcompat ) >/dev/null 2>&1 || log_warn "gcompat 安装失败"
        "$bin" version >/dev/null 2>&1 && return 0
    fi
    return 1
}

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
    ensure_binary_runnable "$SB_BIN" \
        || die "sing-box 二进制无法运行（$SB_BIN version 失败）；musl 系统请确认 gcompat 已安装"
    log_ok "已安装：$("$SB_BIN" version 2>/dev/null | head -1)"

    ensure_etc
    # 首次安装生成一个最小可运行配置（无 inbound），避免 service 启动失败
    if [ ! -f "$CONFIG_JSON" ]; then
        python3 "$(builder_py)" || log_warn "初始配置渲染失败，稍后可用 sb-mgr check 重试"
    fi

    if [ "${SB_BUNDLED:-}" = "1" ]; then
        register_service "${SB_HOME:?SB_HOME 未设置}"
    else
        register_service "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
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
    # 管理命令路径：优先已安装的 sb（单文件版），否则源码树 sb-mgr
    local mgr_bin
    mgr_bin="$(command -v sb 2>/dev/null || true)"
    if [ -z "$mgr_bin" ]; then
        if [ "${SB_BUNDLED:-}" = "1" ]; then
            mgr_bin="${SB_SELF:-/usr/local/bin/sb}"
        else
            mgr_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sb-mgr"
        fi
    fi
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
    @MGR_BIN@ install --yes >/var/log/singbox-yuy-update.log 2>&1 || logger -t singbox-yuy "自动更新失败，见 /var/log/singbox-yuy-update.log"
else
    logger -t singbox-yuy "sing-box 已是最新（$TAG）"
fi
EOF
    # shellcheck disable=SC2086
    sed -i "s|@MGR_BIN@|$mgr_bin|g" "$script"
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

uninstall_main() { # [--yes] [--purge-binary]
    # 一键卸载：停服务 -> 删 unit/init -> 清 cron -> 备份配置 -> 删目录
    # 路径可用环境变量覆盖（供测试）：SB_UNIT_DIR / SB_INITD_DIR / SB_CRON_FILE /
    #   SB_AUTOUPDATE_SCRIPT / SB_PERIODIC_DIR / SB_BACKUP_DIR
    # 注意：sb 本体（/usr/local/bin/sb）永远不动；sing-box 二进制默认保留，
    #   仅 --purge-binary 时删除。
    local yes=0 purge=0
    while [ $# -gt 0 ]; do case "$1" in
        --yes)          yes=1; shift;;
        --purge-binary) purge=1; shift;;
        *) die "uninstall 未知参数：$1";;
    esac; done
    need_root
    ensure_etc
    local sub_svc="${SUB_SVC:-singbox-yuy-sub}"
    local unit_dir="${SB_UNIT_DIR:-/etc/systemd/system}"
    local initd_dir="${SB_INITD_DIR:-/etc/init.d}"
    local cron_file="${SB_CRON_FILE:-/etc/crontab}"
    local autoupdate="${SB_AUTOUPDATE_SCRIPT:-/usr/local/bin/singbox-auto-update}"
    local periodic_dir="${SB_PERIODIC_DIR:-/etc/periodic/weekly}"
    local backup_dir="${SB_BACKUP_DIR:-/tmp}"

    if [ "$yes" != "1" ]; then
        log_warn "将卸载 SingBox-YUY：停止服务、删除 $SB_ETC 配置、清理定时任务"
        log_info "配置将先备份到 $backup_dir/singbox-yuy-backup-<日期>.tar.gz"
        printf '确认卸载？[y/N] '; read -r ans
        case "$ans" in [yY]*) ;; *) log_info "已取消"; return 0;; esac
    fi

    # 1. 停止并禁用服务（尽力而为）
    if has_systemd; then
        systemctl disable --now sing-box 2>/dev/null || true
        systemctl disable --now "$sub_svc" 2>/dev/null || true
    elif has_openrc; then
        rc-service singbox stop 2>/dev/null || true
        rc-update del singbox default 2>/dev/null || true
        rc-service "$sub_svc" stop 2>/dev/null || true
        rc-update del "$sub_svc" default 2>/dev/null || true
    fi
    log_ok "服务已停止"

    # 2. 删除 unit / init 脚本
    rm -f "$unit_dir/sing-box.service" "$unit_dir/${sub_svc}.service"
    rm -f "$initd_dir/singbox" "$initd_dir/$sub_svc"
    svc_daemon_reload
    log_ok "服务定义已删除"

    # 3. 清理定时任务
    if [ -f "$cron_file" ] && grep -q "singbox-auto-update" "$cron_file" 2>/dev/null; then
        sed -i '/singbox-auto-update/d' "$cron_file"
        log_ok "已从 $cron_file 移除自动更新任务"
    fi
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "singbox-auto-update"; then
        (crontab -l 2>/dev/null | grep -v "singbox-auto-update") | crontab -
        log_ok "已从 root crontab 移除自动更新任务"
    fi
    rm -f "$periodic_dir/singbox-auto-update" "$autoupdate"

    # 4. 备份配置
    local stamp backup=""
    stamp=$(date +%Y%m%d-%H%M%S)
    if [ -d "$SB_ETC" ]; then
        mkdir -p "$backup_dir"
        backup="$backup_dir/singbox-yuy-backup-${stamp}.tar.gz"
        tar -czf "$backup" -C "$(dirname "$SB_ETC")" "$(basename "$SB_ETC")" 2>/dev/null \
            && log_ok "配置已备份：$backup" \
            || { log_warn "备份失败，继续卸载"; backup=""; }
    fi

    # 5. 删除配置与 payload 目录
    [ -n "$SB_ETC" ] && [ "$SB_ETC" != "/" ] && rm -rf "$SB_ETC"
    if [ -n "${SB_HOME:-}" ] && [ "$SB_HOME" != "/" ] && [ -d "$SB_HOME" ]; then
        rm -rf "$SB_HOME"
    fi
    log_ok "已删除 $SB_ETC${SB_HOME:+ 与 $SB_HOME}"

    # 6. sing-box 二进制：默认保留
    if [ "$purge" = "1" ]; then
        rm -f "$SB_BIN"
        log_ok "已删除 sing-box 二进制：$SB_BIN"
    else
        log_info "sing-box 二进制已保留（$SB_BIN）；彻底清除请加 --purge-binary"
    fi
    log_ok "SingBox-YUY 卸载完成${backup:+；备份在 $backup}"
}
