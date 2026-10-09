#!/usr/bin/env bash
# common.sh - 日志 / 颜色 / 错误处理 / 系统检测 / 共享路径
# 被所有 lib/*.sh 与 sb-mgr source。支持环境变量覆盖：
#   SB_ETC  状态目录（默认 /etc/sing-box）
#   SB_BIN  sing-box 二进制路径（默认 /usr/local/bin/sing-box）

# shellcheck disable=SC2034
SB_VERSION="0.3.4"
SB_ETC="${SB_ETC:-/etc/sing-box}"
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"
NODES_JSON="$SB_ETC/nodes.json"
SETTINGS_JSON="$SB_ETC/settings.json"
CONFIG_JSON="$SB_ETC/config.json"

# ---------- 颜色与日志 ----------
_C_RED=$'\e[31m'; _C_GRN=$'\e[32m'; _C_YLW=$'\e[33m'; _C_BLU=$'\e[34m'; _C_RST=$'\e[0m'
if [ ! -t 1 ]; then _C_RED=""; _C_GRN=""; _C_YLW=""; _C_BLU=""; _C_RST=""; fi

log_info()  { printf '%s[INFO]%s %s\n' "$_C_BLU" "$_C_RST" "$*"; }
log_ok()    { printf '%s[OK]%s %s\n'   "$_C_GRN" "$_C_RST" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$_C_YLW" "$_C_RST" "$*"; }
log_err()   { printf '%s[ERR]%s %s\n'  "$_C_RED" "$_C_RST" "$*" >&2; }
die()       { log_err "$*"; exit 1; }

# ---------- 权限 ----------
need_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限（当前 uid=$(id -u)）"
}

has_systemd() {
    [ -d /run/systemd/system ]
}

has_openrc() {
    command -v rc-service >/dev/null 2>&1
}

# ---------- 包管理器（多系统） ----------
detect_pm() {
    # 输出 apt-get|dnf|yum|apk|pacman|zypper|unknown
    # 测试可用 OS_RELEASE_FILE 覆盖 /etc/os-release
    local f="${OS_RELEASE_FILE:-/etc/os-release}"
    local id="" id_like="" ver=""
    if [ -r "$f" ]; then
        id=$(sed -n 's/^ID=//p' "$f" | tr -d '"' | tr '[:upper:]' '[:lower:]')
        id_like=$(sed -n 's/^ID_LIKE=//p' "$f" | tr -d '"' | tr '[:upper:]' '[:lower:]')
        ver=$(sed -n 's/^VERSION_ID=//p' "$f" | tr -d '"')
    fi
    case "$id" in
        ubuntu|debian|raspbian|linuxmint|pop|kali) echo "apt-get"; return 0 ;;
        alpine) echo "apk"; return 0 ;;
        fedora|almalinux|rocky|ol|amzn) echo "dnf"; return 0 ;;
        centos|rhel)
            case "$ver" in 7*) echo "yum";; *) echo "dnf";; esac
            return 0 ;;
        arch|manjaro|endeavouros|cachyos) echo "pacman"; return 0 ;;
        opensuse-leap|opensuse-tumbleweed|sles|opensuse) echo "zypper"; return 0 ;;
    esac
    case "$id_like" in
        *debian*|*ubuntu*) echo "apt-get" ;;
        *rhel*|*centos*|*fedora*) echo "dnf" ;;
        *arch*) echo "pacman" ;;
        *suse*) echo "zypper" ;;
        *alpine*) echo "apk" ;;
        *) echo "unknown" ;;
    esac
}

pkg_name() {
    # $1=通用名 $2=包管理器 -> 实际包名（空=该 pm 无此包）
    local g="$1" pm="$2"
    case "$g" in
        curl|jq|python3|openssl|ca-certificates|qrencode) echo "$g"; return 0 ;;
        iproute2)
            case "$pm" in apt-get|dnf|apk|pacman|zypper) echo "iproute2";; yum) echo "iproute";; esac
            return 0 ;;
        whiptail)
            case "$pm" in
                apt-get|apk|yum) echo "whiptail" ;;
                dnf|zypper) echo "newt" ;;
                pacman) echo "libnewt" ;;
            esac
            return 0 ;;
        procps)
            case "$pm" in
                apt-get) echo "procps" ;;
                dnf|yum|apk|pacman) echo "procps-ng" ;;
                zypper) echo "procps4" ;;
            esac
            return 0 ;;
        git) echo "git"; return 0 ;;
        gcompat)
            # musl 兼容层：仅 Alpine 提供，其余包管理器无映射（调用方自行容错）
            case "$pm" in apk) echo "gcompat";; esac
            return 0 ;;
    esac
    return 1
}

pkg_install() {
    # $@=通用包名；qrencode/whiptail 为可选，失败只警告
    local pm
    pm=$(detect_pm)
    [ "$pm" != "unknown" ] || { log_warn "无法识别包管理器，跳过依赖安装"; return 1; }
    need_root
    case "$pm" in
        apt-get) apt-get update -qq ;;
        dnf|yum) "$pm" makecache -q >/dev/null 2>&1 || true ;;
        apk) apk update ;;
        pacman) pacman -Sy --noconfirm >/dev/null 2>&1 || true ;;
        zypper) zypper --non-interactive refresh >/dev/null 2>&1 || true ;;
    esac
    local g name optional
    for g in "$@"; do
        name=$(pkg_name "$g" "$pm") || name=""
        if [ -z "$name" ]; then log_warn "包 $g 在 $pm 下无映射，跳过"; continue; fi
        case "$g" in qrencode|whiptail) optional=1;; *) optional=0;; esac
        local ok=0
        case "$pm" in
            apt-get) apt-get install -y -qq "$name" >/dev/null 2>&1 && ok=1 ;;
            dnf|yum) "$pm" install -y -q "$name" >/dev/null 2>&1 && ok=1 ;;
            apk) apk add --no-cache "$name" >/dev/null 2>&1 && ok=1 ;;
            pacman) pacman -S --noconfirm --needed "$name" >/dev/null 2>&1 && ok=1 ;;
            zypper) zypper --non-interactive install "$name" >/dev/null 2>&1 && ok=1 ;;
        esac
        if [ "$ok" = "1" ]; then
            log_ok "依赖已安装：$g ($name)"
        elif [ "$optional" = "1" ]; then
            log_warn "可选包 $g 安装失败，已跳过"
        else
            die "依赖 $g ($name) 安装失败"
        fi
    done
}

# ---------- 服务抽象（systemd / OpenRC） ----------
svc_daemon_reload() {
    has_systemd && systemctl daemon-reload || true
}

svc_enable() { # $1=服务名
    if has_systemd; then systemctl enable "$1"
    elif has_openrc; then rc-update add "$1" default
    else log_warn "无受支持的 init 系统，跳过 enable $1"; return 1; fi
}

svc_start() { # $1=服务名
    if has_systemd; then systemctl start "$1"
    elif has_openrc; then rc-service "$1" start
    else log_warn "无受支持的 init 系统，跳过 start $1"; return 1; fi
}

svc_restart() { # $1=服务名
    if has_systemd; then systemctl restart "$1"
    elif has_openrc; then rc-service "$1" restart
    else log_warn "无受支持的 init 系统，跳过 restart $1"; return 1; fi
}

svc_stop() { # $1=服务名
    if has_systemd; then systemctl stop "$1"
    elif has_openrc; then rc-service "$1" stop
    else log_warn "无受支持的 init 系统，跳过 stop $1"; return 1; fi
}

svc_is_active() { # $1=服务名；0=运行中
    if has_systemd; then systemctl is-active --quiet "$1"
    elif has_openrc; then rc-service "$1" status >/dev/null 2>&1
    else return 1; fi
}

# ---------- 系统检测 ----------
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l)         echo "armv7" ;;
        *)              echo "unknown" ;;
    esac
}

detect_os() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-}"
    else
        echo "unknown"
    fi
}

public_ip() {
    local ip=""
    ip=$(curl -fsS -m 8 https://api.ipify.org 2>/dev/null) && [ -n "$ip" ] && { echo "$ip"; return 0; }
    ip=$(curl -fsS -m 8 https://ifconfig.me 2>/dev/null) && [ -n "$ip" ] && { echo "$ip"; return 0; }
    return 1
}

port_in_use() {
    # $1=port ; 0=被占用，1=空闲
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -qE "[:.]${p}([[:space:]]|$)" && return 0 || return 1
    fi
    (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null && { exec 3>&-; return 0; } || return 1
}

# ---------- 状态文件 ----------
ensure_etc() {
    mkdir -p "$SB_ETC"
    [ -f "$NODES_JSON" ]    || echo "[]" > "$NODES_JSON"
    if [ ! -f "$SETTINGS_JSON" ]; then
        printf '{"host":"","sub_port":2096,"sub_token":"","unlock":false,"warp":null,"relays":[]}' > "$SETTINGS_JSON"
    fi
}

json_get() {
    # $1=file $2=jq过滤器
    jq -r "$2" "$1" 2>/dev/null
}

json_set() {
    # $1=file，之后是 jq 选项（可选），最后是 filter 表达式
    # 例：json_set f.json --argjson w "$w" '.warp = $w'
    local f="$1"; shift
    local tmp
    snapshot_config
    tmp=$(mktemp) || die "mktemp 失败"
    jq "$@" "$f" > "$tmp" && mv "$tmp" "$f" || { rm -f "$tmp"; die "写入 $f 失败"; }
}

rand_hex()  { # $1=字节数
    local n="${1:-8}"
    if [ -r /dev/urandom ]; then head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'; else date +%s%N | sha256sum | head -c $((n*2)); fi
}

rand_b64() { # $1=字节数 -> base64(无换行)
    local n="${1:-16}"
    head -c "$n" /dev/urandom | base64 | tr -d '\n'
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------- 配置渲染 + 校验 + 回滚 ----------
builder_py() {
    # bundled 单文件模式：payload 释放到 $SB_HOME/py
    if [ "${SB_BUNDLED:-}" = "1" ]; then
        printf '%s/py/builder.py' "${SB_HOME:?SB_HOME 未设置}"
        return 0
    fi
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s/builder.py' "$d"
}

snapshot_config() {
    # 在修改 nodes.json/settings.json 之前调用，快照当前状态。
    # 幂等：一次 sb-mgr 调用链中只保留最早的一份快照。
    if [ -z "${SB_BAK_NODES:-}" ]; then
        SB_BAK_NODES=$(mktemp) || die "mktemp 失败"
        SB_BAK_SETTINGS=$(mktemp) || die "mktemp 失败"
        cp -f "$NODES_JSON" "$SB_BAK_NODES"
        cp -f "$SETTINGS_JSON" "$SB_BAK_SETTINGS"
        export SB_BAK_NODES SB_BAK_SETTINGS
    fi
}

_apply_cleanup() { # $1=own（1=快照由本函数创建，删除临时文件）
    if [ "$1" = "1" ]; then
        rm -f "${SB_BAK_NODES:-}" "${SB_BAK_SETTINGS:-}"
    fi
    unset SB_BAK_NODES SB_BAK_SETTINGS
}

_apply_rollback() {
    cp -f "$SB_BAK_NODES" "$NODES_JSON"
    cp -f "$SB_BAK_SETTINGS" "$SETTINGS_JSON"
}

apply_config() {
    # 重渲染 config.json -> sing-box check -> 失败回滚到 snapshot_config 时的状态
    local own=0
    if [ -z "${SB_BAK_NODES:-}" ]; then
        own=1
        snapshot_config
    fi

    if ! python3 "$(builder_py)"; then
        _apply_rollback
        _apply_cleanup "$own"
        die "builder.py 渲染失败，已回滚"
    fi
    if [ -x "$SB_BIN" ]; then
        if ! "$SB_BIN" check -c "$CONFIG_JSON" >/dev/null 2>&1; then
            "$SB_BIN" check -c "$CONFIG_JSON" 2>&1 | head -20 >&2 || true
            _apply_rollback
            _apply_cleanup "$own"
            die "sing-box check 未通过，已回滚 nodes.json/settings.json"
        fi
    else
        log_warn "未找到 $SB_BIN，跳过 sing-box check"
    fi
    _apply_cleanup "$own"
    log_ok "配置已渲染并通过校验：$CONFIG_JSON"
    if [ "$(id -u)" -eq 0 ] && { has_systemd || has_openrc; }; then
        svc_restart sing-box 2>/dev/null && log_ok "sing-box 已重启" \
            || log_warn "重启 sing-box 服务失败，请手动检查"
    fi
}

gen_uuid() {
    if [ -x "$SB_BIN" ]; then "$SB_BIN" generate uuid 2>/dev/null && return 0; fi
    cat /proc/sys/kernel/random/uuid 2>/dev/null || die "无法生成 UUID"
}

gen_reality_keypair() {
    # 输出两行：私钥 \n 公钥
    if [ -x "$SB_BIN" ]; then
        local out priv pub
        out=$("$SB_BIN" generate reality-keypair 2>/dev/null) || true
        priv=$(printf '%s' "$out" | awk '/Private[Kk]ey/{print $NF}')
        pub=$(printf '%s' "$out" | awk '/Public[Kk]ey/{print $NF}')
        if [ -n "$priv" ] && [ -n "$pub" ]; then printf '%s\n%s\n' "$priv" "$pub"; return 0; fi
    fi
    return 1
}

gen_rand_hex() {
    # $1=字节数
    local n="${1:-8}"
    if [ -x "$SB_BIN" ]; then "$SB_BIN" generate rand --hex "$n" 2>/dev/null && return 0; fi
    rand_hex "$n"
}
