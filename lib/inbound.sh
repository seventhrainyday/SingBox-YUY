#!/usr/bin/env bash
# inbound.sh - 添加/删除/列出 inbound 节点
# 函数：add_reality / add_hy2 / add_tuic / add_anytls / add_ss2022 /
#       del_inbound / list_inbounds
# 每次变更后调用 apply_config（渲染 + sing-box check + 失败回滚 + 重启）

SNI_RECOMMEND="www.sony.com www.microsoft.com www.apple.com www.amazon.com dl.google.com www.cloudflare.com www.samsung.com"

_node_id()   { rand_hex 4; }
_node_tag()  { # $1=proto $2=port -> 唯一 tag
    local base="$1-$2" i=2
    local t="$base"
    while jq -e --arg t "$t" '.[] | select(.tag==$t)' "$NODES_JSON" >/dev/null 2>&1; do
        t="${base}-$i"; i=$((i+1))
    done
    printf '%s' "$t"
}

_pick_sni() { # $1=已指定sni(可空) $2=yes模式(1非交互)
    local sni="$1" yes="$2"
    if [ -n "$sni" ]; then printf '%s' "$sni"; return 0; fi
    if [ "$yes" = "1" ] || [ ! -t 0 ]; then printf 'www.sony.com'; return 0; fi
    log_info "请选择 Reality handshake SNI（推荐列表）："
    local i=1 s
    for s in $SNI_RECOMMEND; do printf '  %d) %s\n' "$i" "$s"; i=$((i+1)); done
    printf '  0) 自定义输入\n'
    printf '输入序号 [1]：'; read -r n
    n="${n:-1}"
    if [ "$n" = "0" ]; then
        printf '输入自定义 SNI：'; read -r sni
        [ -n "$sni" ] || die "SNI 不能为空"
        printf '%s' "$sni"
    else
        sni=$(printf '%s' "$SNI_RECOMMEND" | cut -d' ' -f"$n")
        [ -n "$sni" ] || sni="www.sony.com"
        printf '%s' "$sni"
    fi
}

_check_port() { # $1=port
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "非法端口：$p"
    if port_in_use "$p"; then
        die "端口 $p 已被占用，换一个端口再试"
    fi
    if jq -e --argjson p "$p" '.[] | select(.port==$p)' "$NODES_JSON" >/dev/null 2>&1; then
        die "端口 $p 已分配给现有节点"
    fi
}

mk_selfcert() { # $1=id $2=sni -> 输出 "cert_path key_path"
    local id="$1" sni="$2"
    local cert="$SB_ETC/cert-${id}.pem" key="$SB_ETC/key-${id}.pem"
    command -v openssl >/dev/null 2>&1 || die "需要 openssl，请先安装"
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$key" -out "$cert" -days 3650 \
        -subj "/CN=${sni}" 2>/dev/null || die "自签证书生成失败"
    chmod 600 "$key"
    printf '%s %s\n' "$cert" "$key"
}

acme_cert() { # $1=domain -> 输出 "cert_path key_path"
    local domain="$1"
    local acme="$HOME/.acme.sh/acme.sh"
    [ -x "$acme" ] || die "未检测到 acme.sh，请先安装：curl https://get.acme.sh | sh"
    log_warn "ACME 签发要求：域名 $domain 已正确解析到本机，且 80 端口可从公网访问"
    "$acme" --issue -d "$domain" --standalone \
        || die "acme.sh 签发失败"
    local cert="$SB_ETC/cert-${domain}.pem" key="$SB_ETC/key-${domain}.pem"
    "$acme" --install-cert -d "$domain" \
        --key-file "$key" --fullchain-file "$cert" \
        || die "证书安装失败"
    printf '%s %s\n' "$cert" "$key"
}

tune_udp_buffer() {
    # Hysteria2/TUIC 建议调大 UDP 缓冲区
    # 测试可用 SBYUY_SYSCTL_D 覆盖写入目录（默认 /etc/sysctl.d）
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "非 root，跳过 UDP 缓冲区调优（建议 root 下执行）"
        return 0
    fi
    local sysctl_d="${SBYUY_SYSCTL_D:-/etc/sysctl.d}"
    sysctl -w net.core.rmem_max=26214400 >/dev/null 2>&1 \
        || log_warn "sysctl -w net.core.rmem_max 失败（容器受限可忽略）"
    sysctl -w net.core.wmem_max=26214400 >/dev/null 2>&1 \
        || log_warn "sysctl -w net.core.wmem_max 失败（容器受限可忽略）"
    mkdir -p "$sysctl_d"
    if ! grep -q "sbyuy" "$sysctl_d/99-sbyuy.conf" 2>/dev/null; then
        cat >> "$sysctl_d/99-sbyuy.conf" <<'EOF'
# SingBox-YUY: UDP 缓冲区调优（Hysteria2/TUIC）
net.core.rmem_max=26214400
net.core.wmem_max=26214400
EOF
    fi
    log_ok "UDP 缓冲区已调大（rmem_max/wmem_max=26214400）"
}

_append_node() { # $1=json对象 -> 追加到 nodes.json
    local obj="$1" tmp
    snapshot_config
    tmp=$(mktemp) || die "mktemp 失败"
    jq --argjson n "$obj" '. + [$n]' "$NODES_JSON" > "$tmp" \
        && mv "$tmp" "$NODES_JSON" || { rm -f "$tmp"; die "写入 nodes.json 失败"; }
}

# ---------------- 各协议 ----------------

add_reality() { # [--port N] [--sni S] [--remark R] [--yes]
    local port=443 sni="" remark="" yes=0
    while [ $# -gt 0 ]; do case "$1" in
        --port)   port="$2"; shift 2;;
        --sni)    sni="$2"; shift 2;;
        --remark) remark="$2"; shift 2;;
        --yes)    yes=1; shift;;
        *) die "add_reality 未知参数：$1";;
    esac; done
    _check_port "$port"
    sni=$(_pick_sni "$sni" "$yes")

    local uuid kp priv pub sid id tag
    uuid=$(gen_uuid)
    kp=$(gen_reality_keypair) || die "reality keypair 生成失败（需要 sing-box 二进制；先 sb-mgr install）"
    priv=$(printf '%s' "$kp" | sed -n '1p')
    pub=$(printf '%s' "$kp" | sed -n '2p')
    sid=$(gen_rand_hex 8)
    id=$(_node_id); tag=$(_node_tag reality "$port")

    local node
    node=$(jq -n \
        --arg id "$id" --arg tag "$tag" --argjson port "$port" \
        --arg uuid "$uuid" --arg sni "$sni" \
        --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" \
        --arg remark "${remark:-$tag}" --arg created "$(now_iso)" \
        '{id:$id,proto:"reality",tag:$tag,port:$port,uuid:$uuid,
          flow:"xtls-rprx-vision",sni:$sni,
          reality_private_key:$priv,reality_public_key:$pub,short_id:$sid,
          remark:$remark,created:$created}')
    _append_node "$node"
    apply_config
    log_ok "Reality 节点已添加：id=$id tag=$tag 端口=$port SNI=$sni"
    log_info "查看链接：sb-mgr link $id"
}

add_hy2() { # [--port N] [--domain D|--sni S] [--acme] [--password P] [--remark R] [--yes]
    local port=8443 sni="" password="" remark="" yes=0 acme=0
    while [ $# -gt 0 ]; do case "$1" in
        --port)     port="$2"; shift 2;;
        --domain|--sni) sni="$2"; shift 2;;
        --acme)     acme=1; shift;;
        --password) password="$2"; shift 2;;
        --remark)   remark="$2"; shift 2;;
        --yes)      yes=1; shift;;
        *) die "add_hy2 未知参数：$1";;
    esac; done
    _check_port "$port"
    [ -z "$sni" ] && sni="www.sony.com"
    [ -z "$password" ] && password=$(rand_b64 12)

    local cert_type="self" cert key
    if [ "$acme" = "1" ]; then
        read -r cert key < <(acme_cert "$sni") || die "ACME 证书获取失败"
        cert_type="acme"
    else
        local id
        id=$(_node_id)
        read -r cert key < <(mk_selfcert "$id" "$sni") || die "自签证书生成失败"
        log_warn "使用自签证书，客户端需开启 insecure/skip-cert-verify"
    fi
    [ -n "${id:-}" ] || id=$(_node_id)
    tune_udp_buffer
    local tag
    tag=$(_node_tag hy2 "$port")

    local node
    node=$(jq -n \
        --arg id "$id" --arg tag "$tag" --argjson port "$port" \
        --arg pw "$password" --arg sni "$sni" --arg ct "$cert_type" \
        --arg cert "$cert" --arg key "$key" \
        --arg remark "${remark:-$tag}" --arg created "$(now_iso)" \
        '{id:$id,proto:"hy2",tag:$tag,port:$port,password:$pw,sni:$sni,
          cert_type:$ct,cert_path:$cert,key_path:$key,
          remark:$remark,created:$created}')
    _append_node "$node"
    apply_config
    log_ok "Hysteria2 节点已添加：id=$id tag=$tag 端口=$port 证书=$cert_type"
    log_info "查看链接：sb-mgr link $id"
}

add_tuic() { # [--port N] [--sni S] [--password P] [--remark R] [--yes]
    local port=443 sni="" password="" remark="" yes=0
    while [ $# -gt 0 ]; do case "$1" in
        --port)     port="$2"; shift 2;;
        --sni)      sni="$2"; shift 2;;
        --password) password="$2"; shift 2;;
        --remark)   remark="$2"; shift 2;;
        --yes)      yes=1; shift;;
        *) die "add_tuic 未知参数：$1";;
    esac; done
    _check_port "$port"
    [ -z "$sni" ] && sni="www.sony.com"
    [ -z "$password" ] && password=$(rand_b64 12)

    local id uuid cert key
    id=$(_node_id); uuid=$(gen_uuid)
    read -r cert key < <(mk_selfcert "$id" "$sni") || die "自签证书生成失败"
    log_warn "使用自签证书，客户端需开启 allow-insecure"
    tune_udp_buffer
    local tag
    tag=$(_node_tag tuic "$port")

    local node
    node=$(jq -n \
        --arg id "$id" --arg tag "$tag" --argjson port "$port" \
        --arg uuid "$uuid" --arg pw "$password" --arg sni "$sni" \
        --arg cert "$cert" --arg key "$key" \
        --arg remark "${remark:-$tag}" --arg created "$(now_iso)" \
        '{id:$id,proto:"tuic",tag:$tag,port:$port,uuid:$uuid,password:$pw,
          sni:$sni,cert_type:"self",cert_path:$cert,key_path:$key,
          remark:$remark,created:$created}')
    _append_node "$node"
    apply_config
    log_ok "TUIC 节点已添加：id=$id tag=$tag 端口=$port"
    log_info "查看链接：sb-mgr link $id"
}

add_anytls() { # [--port N] [--sni S] [--password P] [--remark R] [--yes]
    local port=8443 sni="" password="" remark="" yes=0
    while [ $# -gt 0 ]; do case "$1" in
        --port)     port="$2"; shift 2;;
        --sni)      sni="$2"; shift 2;;
        --password) password="$2"; shift 2;;
        --remark)   remark="$2"; shift 2;;
        --yes)      yes=1; shift;;
        *) die "add_anytls 未知参数：$1";;
    esac; done
    _check_port "$port"
    [ -z "$sni" ] && sni="www.microsoft.com"
    [ -z "$password" ] && password=$(rand_b64 12)

    local id cert key
    id=$(_node_id)
    read -r cert key < <(mk_selfcert "$id" "$sni") || die "自签证书生成失败"
    local tag
    tag=$(_node_tag anytls "$port")

    local node
    node=$(jq -n \
        --arg id "$id" --arg tag "$tag" --argjson port "$port" \
        --arg pw "$password" --arg sni "$sni" \
        --arg cert "$cert" --arg key "$key" \
        --arg remark "${remark:-$tag}" --arg created "$(now_iso)" \
        '{id:$id,proto:"anytls",tag:$tag,port:$port,password:$pw,
          sni:$sni,cert_type:"self",cert_path:$cert,key_path:$key,
          remark:$remark,created:$created}')
    _append_node "$node"
    apply_config
    log_ok "AnyTLS 节点已添加：id=$id tag=$tag 端口=$port"
    log_info "查看链接：sb-mgr link $id"
}

add_ss2022() { # [--port N] [--password P] [--remark R] [--yes]
    local port=8388 password="" remark="" yes=0
    while [ $# -gt 0 ]; do case "$1" in
        --port)     port="$2"; shift 2;;
        --password) password="$2"; shift 2;;
        --remark)   remark="$2"; shift 2;;
        --yes)      yes=1; shift;;
        *) die "add_ss2022 未知参数：$1";;
    esac; done
    _check_port "$port"
    [ -z "$password" ] && password=$(rand_b64 16)

    local id tag
    id=$(_node_id); tag=$(_node_tag ss "$port")
    local node
    node=$(jq -n \
        --arg id "$id" --arg tag "$tag" --argjson port "$port" \
        --arg pw "$password" \
        --arg remark "${remark:-$tag}" --arg created "$(now_iso)" \
        '{id:$id,proto:"ss2022",tag:$tag,port:$port,
          method:"2022-blake3-aes-128-gcm",password:$pw,
          remark:$remark,created:$created}')
    _append_node "$node"
    apply_config
    log_ok "Shadowsocks-2022 节点已添加：id=$id tag=$tag 端口=$port"
    log_info "查看链接：sb-mgr link $id"
}

# ---------------- 删除 / 列表 ----------------

del_inbound() { # $1=id
    local id="${1:-}"
    [ -n "$id" ] || die "用法：sb-mgr del <id>"
    jq -e --arg id "$id" '.[] | select(.id==$id)' "$NODES_JSON" >/dev/null 2>&1 \
        || die "未找到节点：$id"
    local tmp certs
    snapshot_config
    tmp=$(mktemp) || die "mktemp 失败"
    certs=$(jq -r --arg id "$id" '.[] | select(.id==$id) | "\(.cert_path // empty)\n\(.key_path // empty)"' "$NODES_JSON")
    jq --arg id "$id" 'map(select(.id!=$id))' "$NODES_JSON" > "$tmp" \
        && mv "$tmp" "$NODES_JSON" || { rm -f "$tmp"; die "删除失败"; }
    # 清理该节点自签证书
    local c
    for c in $certs; do
        case "$c" in "$SB_ETC"/cert-*) rm -f "$c" 2>/dev/null;; esac
    done
    apply_config
    log_ok "节点 $id 已删除"
}

list_inbounds() {
    local n
    n=$(jq 'length' "$NODES_JSON")
    [ "$n" -eq 0 ] && { log_info "暂无节点，用 sb-mgr add 添加"; return 0; }
    printf '%-10s %-8s %-7s %-16s %s\n' "ID" "协议" "端口" "TAG" "备注"
    jq -r '.[] | [.id, .proto, (.port|tostring), .tag, (.remark//"")] | @tsv' "$NODES_JSON" \
    | while IFS=$'\t' read -r id proto port tag remark; do
        printf '%-10s %-8s %-7s %-16s %s\n' "$id" "$proto" "$port" "$tag" "$remark"
    done
}
