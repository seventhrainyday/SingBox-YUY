#!/usr/bin/env bash
# common.sh - 日志 / 颜色 / 错误处理 / 系统检测 / 共享路径
# 被所有 lib/*.sh 与 sb-mgr source。支持环境变量覆盖：
#   SB_ETC  状态目录（默认 /etc/sing-box）
#   SB_BIN  sing-box 二进制路径（默认 /usr/local/bin/sing-box）

# shellcheck disable=SC2034
SBYUY_VERSION="0.1.0"
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

have_systemd() {
    [ -d /run/systemd/system ]
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
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    printf '%s/builder.py' "$d"
}

snapshot_config() {
    # 在修改 nodes.json/settings.json 之前调用，快照当前状态。
    # 幂等：一次 sb-mgr 调用链中只保留最早的一份快照。
    if [ -z "${SBYUY_BAK_NODES:-}" ]; then
        SBYUY_BAK_NODES=$(mktemp) || die "mktemp 失败"
        SBYUY_BAK_SETTINGS=$(mktemp) || die "mktemp 失败"
        cp -f "$NODES_JSON" "$SBYUY_BAK_NODES"
        cp -f "$SETTINGS_JSON" "$SBYUY_BAK_SETTINGS"
        export SBYUY_BAK_NODES SBYUY_BAK_SETTINGS
    fi
}

_apply_cleanup() { # $1=own（1=快照由本函数创建，删除临时文件）
    if [ "$1" = "1" ]; then
        rm -f "${SBYUY_BAK_NODES:-}" "${SBYUY_BAK_SETTINGS:-}"
    fi
    unset SBYUY_BAK_NODES SBYUY_BAK_SETTINGS
}

_apply_rollback() {
    cp -f "$SBYUY_BAK_NODES" "$NODES_JSON"
    cp -f "$SBYUY_BAK_SETTINGS" "$SETTINGS_JSON"
}

apply_config() {
    # 重渲染 config.json -> sing-box check -> 失败回滚到 snapshot_config 时的状态
    local own=0
    if [ -z "${SBYUY_BAK_NODES:-}" ]; then
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
    if have_systemd && [ "$(id -u)" -eq 0 ]; then
        systemctl restart sing-box 2>/dev/null && log_ok "sing-box 已重启" \
            || log_warn "systemctl restart sing-box 失败，请手动检查"
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
