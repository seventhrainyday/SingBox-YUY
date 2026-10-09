#!/usr/bin/env bash
# install.sh - SingBox-YUY 一键安装脚本（仓库根目录）
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/seventhrainyday/SingBox-YUY/main/install.sh | sudo bash
#   # 带参数透传（bash -s -- 之后的参数原样交给 sb-mgr install）：
#   curl -fsSL <url> | sudo bash -s -- --proto hy2 --port 8443 --yes
#
# 逻辑：必须 root -> 保证 git 可用（包管理器安装，实在不行走 tarball）
#       -> git clone / git pull 到 /opt/SingBox-YUY -> exec sb-mgr install "$@"
set -euo pipefail

REPO_URL="https://github.com/seventhrainyday/SingBox-YUY.git"
TARBALL_URL="https://codeload.github.com/seventhrainyday/SingBox-YUY/tar.gz/refs/heads/main"
INSTALL_DIR="/opt/SingBox-YUY"

log()  { printf '[install] %s\n' "$*"; }
die()  { printf '[install][ERR] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行，例如：curl -fsSL <url> | sudo bash"

detect_pm() {
    # 精简版包管理器检测（与 lib/common.sh 的 detect_pm 同逻辑）
    local f=/etc/os-release id="" ver=""
    if [ -r "$f" ]; then
        id=$(sed -n 's/^ID=//p' "$f" | tr -d '"' | tr '[:upper:]' '[:lower:]')
        ver=$(sed -n 's/^VERSION_ID=//p' "$f" | tr -d '"')
    fi
    case "$id" in
        ubuntu|debian|raspbian|linuxmint|pop|kali) echo "apt-get"; return 0 ;;
        alpine) echo "apk"; return 0 ;;
        fedora|almalinux|rocky|ol) echo "dnf"; return 0 ;;
        centos|rhel)
            case "$ver" in 7*) echo "yum";; *) echo "dnf";; esac; return 0 ;;
        arch|manjaro|endeavouros|cachyos) echo "pacman"; return 0 ;;
        opensuse-leap|opensuse-tumbleweed|sles|opensuse) echo "zypper"; return 0 ;;
    esac
    echo "unknown"
}

ensure_git() {
    # 0=git 可用，1=实在装不上（调用方回退 tarball）
    command -v git >/dev/null 2>&1 && return 0
    log "未检测到 git，尝试用包管理器安装..."
    local pm
    pm=$(detect_pm)
    case "$pm" in
        apt-get) apt-get update -qq && apt-get install -y -qq git ;;
        dnf|yum) "$pm" install -y -q git ;;
        apk) apk add --no-cache git ;;
        pacman) pacman -Sy --noconfirm git ;;
        zypper) zypper --non-interactive install git ;;
        *) log "无法识别包管理器（$pm），跳过 git 安装"; return 1 ;;
    esac >/dev/null 2>&1 || { log "git 安装失败"; return 1; }
    command -v git >/dev/null 2>&1
}

fetch_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        log "目录已存在，从 git 更新：$INSTALL_DIR"
        git -C "$INSTALL_DIR" pull --ff-only || die "git pull 失败"
        return 0
    fi
    if [ -d "$INSTALL_DIR" ]; then
        local bak
        bak="${INSTALL_DIR}.bak.$(date +%Y%m%d%H%M%S)"
        log "目录已存在但非 git 仓库，备份到 $bak"
        mv "$INSTALL_DIR" "$bak" || die "备份旧目录失败"
    fi
    if ensure_git; then
        log "git clone $REPO_URL -> $INSTALL_DIR"
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" || die "git clone 失败"
        return 0
    fi
    log "回退：下载 tarball..."
    local tmpd
    tmpd=$(mktemp -d) || die "mktemp 失败"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpd'" EXIT
    curl -fSL -m 300 -o "$tmpd/repo.tar.gz" "$TARBALL_URL" || die "tarball 下载失败"
    tar -xzf "$tmpd/repo.tar.gz" -C "$tmpd" || die "tarball 解压失败"
    local top
    top=$(find "$tmpd" -maxdepth 1 -type d -name "SingBox-YUY-*" | head -1)
    [ -n "$top" ] || die "tarball 内未找到顶层目录"
    mkdir -p "$INSTALL_DIR"
    cp -a "$top"/. "$INSTALL_DIR"/ || die "复制文件失败"
    rm -rf "$tmpd"
    trap - EXIT
    log "tarball 已解压到 $INSTALL_DIR"
}

main() {
    fetch_repo
    chmod +x "$INSTALL_DIR/sb-mgr"
    log "移交 sb-mgr install $*"
    exec "$INSTALL_DIR/sb-mgr" install "$@"
}

main "$@"
