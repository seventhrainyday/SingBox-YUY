#!/usr/bin/env bash
# envcheck.sh - 环境自检：OS/架构/TUN/内核版本/BBR
# 用法：sb-mgr envcheck

envcheck_main() {
    local fails=0
    log_info "=== SingBox-YUY 环境自检 ==="

    # 1. OS 发行版
    local os
    os=$(detect_os)
    printf '  %-14s %s\n' "OS:" "$os"
    case "$os" in
        ubuntu*|debian*|alpine*) log_ok "发行版受支持" ;;
        *) log_warn "未在 CI 矩阵内（ubuntu/debian/alpine），可能仍可运行";;
    esac

    # 2. 架构
    local arch
    arch=$(detect_arch)
    printf '  %-14s %s\n' "架构:" "$arch"
    case "$arch" in
        amd64|arm64) log_ok "架构受支持" ;;
        *) log_err "不支持的架构：$arch（仅 amd64/arm64）"; fails=$((fails+1)) ;;
    esac

    # 3. 内核版本
    local kern
    kern=$(uname -r)
    printf '  %-14s %s\n' "内核:" "$kern"

    # 4. TUN 支持
    if [ -c /dev/net/tun ]; then
        if : > /dev/net/tun 2>/dev/null || [ -r /dev/net/tun ]; then
            printf '  %-14s %s\n' "TUN:" "可用 (/dev/net/tun)"
            log_ok "TUN 设备可用"
        else
            printf '  %-14s %s\n' "TUN:" "设备存在但不可读写"
            log_warn "TUN 设备存在但不可读写（容器内可能受限）"
        fi
    else
        printf '  %-14s %s\n' "TUN:" "缺失"
        log_warn "未检测到 /dev/net/tun。如需 TUN 模式：宿主机执行 modprobe tun，或容器加 --device=/dev/net/tun"
    fi

    # 5. BBR
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    printf '  %-14s %s\n' "拥塞控制:" "$cc"
    if [ "$cc" = "bbr" ]; then
        log_ok "BBR 已启用"
    else
        log_warn "当前拥塞控制为 $cc。开启 BBR："
        echo "      echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf"
        echo "      echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf"
        echo "      sysctl -p"
    fi

    # 6. 依赖
    local dep miss=0
    for dep in curl jq python3 openssl; do
        if command -v "$dep" >/dev/null 2>&1; then
            printf '  %-14s %s\n' "依赖 $dep:" "ok"
        else
            printf '  %-14s %s\n' "依赖 $dep:" "缺失"
            miss=1
        fi
    done
    [ "$miss" -eq 0 ] || { log_warn "缺少依赖，请先安装：apt install -y curl jq python3 openssl（alpine: apk add ...）"; }

    # 7. sing-box 二进制
    if [ -x "$SB_BIN" ]; then
        printf '  %-14s %s\n' "sing-box:" "$("$SB_BIN" version 2>/dev/null | head -1)"
        log_ok "sing-box 已安装"
    else
        printf '  %-14s %s\n' "sing-box:" "未安装 ($SB_BIN)"
        log_warn "运行 'sb-mgr install' 一键安装"
    fi

    echo "----------------------------------------"
    if [ "$fails" -eq 0 ]; then
        log_ok "环境自检通过"
        return 0
    else
        log_err "环境自检发现 $fails 个硬性失败"
        return 1
    fi
}
