#!/usr/bin/env bash
# inbound.sh - 添加/删除/列出/修改 inbound 节点
# 函数：add_reality / add_hy2 / add_tuic / add_anytls / add_trojan / add_ss2022 /
#       del_inbound / list_inbounds / node_modify
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
    # 注意：本函数常被 $() 包裹调用，所有交互提示必须走 stderr，
    # 只有最终选中的 sni 走 stdout，否则提示被吞、用户看到"卡死"，sni 还会被菜单文字污染
    log_info "请选择 Reality handshake SNI（推荐列表）：" >&2
    local i=1 s
    for s in $SNI_RECOMMEND; do printf '  %d) %s\n' "$i" "$s" >&2; i=$((i+1)); done
    printf '  0) 自定义输入\n' >&2
    printf '输入序号 [1]：' >&2; read -r n
    n="${n:-1}"
    if [ "$n" = "0" ]; then
        printf '输入自定义 SNI：' >&2; read -r sni
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

_check_port_except() { # $1=port $2=exclude-id（node-modify 改端口时排除自身）
    local p="$1" ex="$2"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "非法端口：$p"
    if port_in_use "$p"; then
        die "端口 $p 已被占用，换一个端口再试"
    fi
    if jq -e --argjson p "$p" --arg id "$ex" '.[] | select(.port==$p and .id!=$id)' \
            "$NODES_JSON" >/dev/null 2>&1; then
        die "端口 $p 已分配给其他节点"
    fi
    _port_in_hops "$p" "$ex" && die "端口 $p 已被其他节点的跳跃区间占用"
    return 0
}

_port_in_hops() { # $1=port $2=exclude-id -> 0=被任一其他节点的跳跃区间占用
    local p="$1" ex="$2"
    jq -e --argjson p "$p" --arg id "$ex" '
        .[] | select(.id != $id and (.ports // "") != "") |
        (.ports | split(":")) as $r |
        select(($r|length)==2 and ($r[0]|tonumber) <= $p and $p <= ($r[1]|tonumber))
    ' "$NODES_JSON" >/dev/null 2>&1
}

_check_hop_range() { # $1=range(起始:结束) $2=exclude-id $3=own-port（可空：区间不得包含自身主端口）
    # 校验 hy2 跳跃区间合法性；失败直接 die。单区间最多 32 个端口。
    local r="$1" ex="$2" own="${3:-}"
    [[ "$r" =~ ^[0-9]+:[0-9]+$ ]] || die "跳跃区间格式错误，应为 起始:结束（如 20000:20010）"
    local s="${r%%:*}" e="${r##*:}"
    [ "$s" -lt "$e" ] || die "跳跃区间起始端口必须小于结束端口：$r"
    { [ "$s" -ge 1 ] && [ "$e" -le 65535 ]; } || die "端口超出范围 1-65535：$r"
    local cnt=$((e - s + 1))
    [ "$cnt" -le 32 ] || die "跳跃区间最多 32 个端口（$r 共 $cnt 个），请缩小范围"
    if [ -n "$own" ]; then
        { [ "$own" -lt "$s" ] || [ "$own" -gt "$e" ]; } \
            || die "跳跃区间 $r 不得包含节点自身主端口 $own"
    fi
    local p
    for ((p=s; p<=e; p++)); do
        if port_in_use "$p"; then
            die "端口 $p 已被系统占用，跳跃区间 $r 不可用"
        fi
        if jq -e --argjson p "$p" --arg id "$ex" \
                '.[] | select(.id!=$id and .port==$p)' "$NODES_JSON" >/dev/null 2>&1; then
            die "端口 $p 已分配给其他节点，跳跃区间 $r 不可用"
        fi
        _port_in_hops "$p" "$ex" && die "端口 $p 已被其他节点的跳跃区间占用，$r 不可用"
    done
    return 0
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
    # 测试可用 SB_SYSCTL_D 覆盖写入目录；无 /etc/sysctl.d 的系统（如 Alpine）改写 /etc/sysctl.conf
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "非 root，跳过 UDP 缓冲区调优（建议 root 下执行）"
        return 0
    fi
    sysctl -w net.core.rmem_max=26214400 >/dev/null 2>&1 \
        || log_warn "sysctl -w net.core.rmem_max 失败（容器受限可忽略）"
    sysctl -w net.core.wmem_max=26214400 >/dev/null 2>&1 \
        || log_warn "sysctl -w net.core.wmem_max 失败（容器受限可忽略）"
    local conf
    if [ -n "${SB_SYSCTL_D:-}" ]; then
        mkdir -p "$SB_SYSCTL_D"
        conf="$SB_SYSCTL_D/99-singbox-yuy.conf"
    elif [ -d /etc/sysctl.d ]; then
        conf="/etc/sysctl.d/99-singbox-yuy.conf"
    else
        conf="/etc/sysctl.conf"
    fi
    if ! grep -q "singbox-yuy" "$conf" 2>/dev/null; then
        cat >> "$conf" <<'EOF'
# SingBox-YUY: UDP 缓冲区调优（Hysteria2/TUIC）
net.core.rmem_max=26214400
net.core.wmem_max=26214400
EOF
    fi
    if ! sysctl --system >/dev/null 2>&1; then
        log_warn "sysctl --system 未生效，已用 sysctl -w 即时应用（重启后以 $conf 为准）"
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

add_hy2() { # [--port N] [--domain D|--sni S] [--acme] [--password P] [--ports 起始:结束] [--remark R] [--yes]
    local port=8443 sni="" password="" remark="" yes=0 acme=0 ports=""
    while [ $# -gt 0 ]; do case "$1" in
        --port)     port="$2"; shift 2;;
        --domain|--sni) sni="$2"; shift 2;;
        --acme)     acme=1; shift;;
        --password) password="$2"; shift 2;;
        --ports)    ports="$2"; shift 2;;
        --remark)   remark="$2"; shift 2;;
        --yes)      yes=1; shift;;
        *) die "add_hy2 未知参数：$1";;
    esac; done
    _check_port "$port"
    [ -n "$ports" ] && _check_hop_range "$ports" "" "$port"
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
    if [ -n "$ports" ]; then
        node=$(jq -n \
            --arg id "$id" --arg tag "$tag" --argjson port "$port" \
            --arg pw "$password" --arg sni "$sni" --arg ct "$cert_type" \
            --arg cert "$cert" --arg key "$key" --arg ports "$ports" \
            --arg remark "${remark:-$tag}" --arg created "$(now_iso)" \
            '{id:$id,proto:"hy2",tag:$tag,port:$port,password:$pw,sni:$sni,
              cert_type:$ct,cert_path:$cert,key_path:$key,ports:$ports,
              remark:$remark,created:$created}')
    else
        node=$(jq -n \
            --arg id "$id" --arg tag "$tag" --argjson port "$port" \
            --arg pw "$password" --arg sni "$sni" --arg ct "$cert_type" \
            --arg cert "$cert" --arg key "$key" \
            --arg remark "${remark:-$tag}" --arg created "$(now_iso)" \
            '{id:$id,proto:"hy2",tag:$tag,port:$port,password:$pw,sni:$sni,
              cert_type:$ct,cert_path:$cert,key_path:$key,
              remark:$remark,created:$created}')
    fi
    _append_node "$node"
    apply_config
    log_ok "Hysteria2 节点已添加：id=$id tag=$tag 端口=$port 证书=$cert_type${ports:+ 跳跃=$ports}"
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

add_trojan() { # [--port N] [--sni S] [--password P] [--remark R] [--yes]
    local port=443 sni="" password="" remark="" yes=0
    while [ $# -gt 0 ]; do case "$1" in
        --port)     port="$2"; shift 2;;
        --sni)      sni="$2"; shift 2;;
        --password) password="$2"; shift 2;;
        --remark)   remark="$2"; shift 2;;
        --yes)      yes=1; shift;;
        *) die "add_trojan 未知参数：$1";;
    esac; done
    _check_port "$port"
    [ -z "$sni" ] && sni="www.sony.com"
    [ -z "$password" ] && password=$(rand_b64 12)

    local id cert key
    id=$(_node_id)
    read -r cert key < <(mk_selfcert "$id" "$sni") || die "自签证书生成失败"
    log_warn "使用自签证书，客户端需开启 insecure/skip-cert-verify"
    local tag
    tag=$(_node_tag trojan "$port")

    local node
    node=$(jq -n \
        --arg id "$id" --arg tag "$tag" --argjson port "$port" \
        --arg pw "$password" --arg sni "$sni" \
        --arg cert "$cert" --arg key "$key" \
        --arg remark "${remark:-$tag}" --arg created "$(now_iso)" \
        '{id:$id,proto:"trojan",tag:$tag,port:$port,password:$pw,
          sni:$sni,cert_type:"self",cert_path:$cert,key_path:$key,
          remark:$remark,created:$created}')
    _append_node "$node"
    apply_config
    log_ok "Trojan 节点已添加：id=$id tag=$tag 端口=$port"
    log_info "查看链接：sb-mgr link $id"
}

_check_ss_password() { # $1=password（ss2022 要求 base64 编码的 16 字节密钥）
    local pw="$1" len
    len=$(printf '%s' "$pw" | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    [ "$len" = "16" ] || die "ss2022 密码必须是 base64 编码的 16 字节密钥（2022-blake3-aes-128-gcm）"
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
    _check_ss_password "$password"

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

# ---------------- 删除 / 修改 / 列表 ----------------

node_modify() { # --id ID [--remark R] [--port P] [--sni S] [--password PW] [--uuid U] [--regen-key] [--ports 起始:结束]
    # 按协议只应用合法字段；非法组合直接报错，不碰 nodes.json
    local _U="__SB_UNSET__"
    local id="" remark="$_U" port="$_U" sni="$_U" password="$_U" uuid="$_U" ports="$_U" regen=0
    while [ $# -gt 0 ]; do case "$1" in
        --id)       id="$2"; shift 2;;
        --remark)   remark="$2"; shift 2;;
        --port)     port="$2"; shift 2;;
        --sni)      sni="$2"; shift 2;;
        --password) password="$2"; shift 2;;
        --uuid)     uuid="$2"; shift 2;;
        --regen-key) regen=1; shift;;
        --ports)    ports="$2"; shift 2;;
        *) die "node-modify 未知参数：$1";;
    esac; done
    [ -n "$id" ] || die "用法：sb-mgr node-modify --id <id> [--remark R] [--port P] [--sni S] [--password PW] [--uuid U] [--regen-key] [--ports 起始:结束]"
    ensure_etc
    local node proto
    node=$(jq -c --arg id "$id" '.[] | select(.id==$id)' "$NODES_JSON")
    [ -n "$node" ] || die "未找到节点：$id"
    proto=$(jq -r .proto <<<"$node")

    local allowed
    case "$proto" in
        reality) allowed=" remark port sni uuid regen-key " ;;
        hy2)     allowed=" remark port sni password ports " ;;
        tuic)    allowed=" remark port sni password " ;;
        anytls)  allowed=" remark port sni password " ;;
        trojan)  allowed=" remark port sni password " ;;
        ss2022)  allowed=" remark port password " ;;
        *) die "未知协议：$proto" ;;
    esac
    local _mod_allowed
    _mod_allowed() { # $1=字段名
        case "$allowed" in *" $1 "*) ;; *) die "$proto 不支持修改字段：$1";; esac
    }
    [ "$remark"   != "$_U" ] && _mod_allowed remark
    [ "$port"     != "$_U" ] && _mod_allowed port
    [ "$sni"      != "$_U" ] && _mod_allowed sni
    [ "$password" != "$_U" ] && _mod_allowed password
    [ "$uuid"     != "$_U" ] && _mod_allowed uuid
    [ "$ports"    != "$_U" ] && _mod_allowed ports
    [ "$regen" = "1" ] && _mod_allowed regen-key
    { [ "$remark" != "$_U" ] || [ "$port" != "$_U" ] || [ "$sni" != "$_U" ] || \
      [ "$password" != "$_U" ] || [ "$uuid" != "$_U" ] || [ "$ports" != "$_U" ] || \
      [ "$regen" = "1" ]; } || die "未指定任何修改项"

    # ---- 计算新值（全部校验通过后才写文件） ----
    local old_port new_port new_tag
    old_port=$(jq -r .port <<<"$node")
    new_port="$old_port"
    if [ "$port" != "$_U" ]; then
        _check_port_except "$port" "$id"
        new_port="$port"
    fi
    if [ "$ports" != "$_U" ] && [ -n "$ports" ]; then
        _check_hop_range "$ports" "$id" "$new_port"
    fi
    # 仅改主端口时：新端口不得落入已有跳跃区间（否则运行时重复绑定）
    if [ "$new_port" != "$old_port" ] && [ "$ports" = "$_U" ]; then
        local cur_ports
        cur_ports=$(jq -r '.ports // ""' <<<"$node")
        if [ -n "$cur_ports" ]; then
            local hs="${cur_ports%%:*}" he="${cur_ports##*:}"
            { [ "$new_port" -lt "$hs" ] || [ "$new_port" -gt "$he" ]; } \
                || die "新端口 $new_port 落在现有跳跃区间 $cur_ports 内，先用 --ports 调整区间"
        fi
    fi
    new_tag=$(jq -r .tag <<<"$node")
    local tag_set=0
    if [ "$new_port" != "$old_port" ]; then
        new_tag=$(_node_tag "$proto" "$new_port")
        tag_set=1
    fi

    local new_sni sni_set=0
    new_sni=$(jq -r '.sni // ""' <<<"$node")
    if [ "$sni" != "$_U" ] && [ -n "$sni" ] && [ "$sni" != "$new_sni" ]; then
        new_sni="$sni"; sni_set=1
        local ct
        ct=$(jq -r '.cert_type // ""' <<<"$node")
        if [ "$ct" = "self" ]; then
            # 自签证书文件名与 id 绑定，原地重新生成即可（路径不变）
            mk_selfcert "$id" "$new_sni" >/dev/null || die "自签证书重新生成失败"
            log_info "SNI 已更换，自签证书已重新生成"
        else
            log_warn "ACME 证书不会随 SNI 自动更换，请手动处理证书"
        fi
    fi

    if [ "$password" != "$_U" ]; then
        [ -n "$password" ] || die "密码不能为空"
        [ "$proto" = "ss2022" ] && _check_ss_password "$password"
    fi

    local new_uuid uuid_set=0
    new_uuid=$(jq -r '.uuid // ""' <<<"$node")
    if [ "$uuid" != "$_U" ]; then
        [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
            || die "UUID 格式非法：$uuid"
        new_uuid="$uuid"; uuid_set=1
    fi

    local new_priv new_pub new_sid
    new_priv=$(jq -r '.reality_private_key // ""' <<<"$node")
    new_pub=$(jq -r '.reality_public_key // ""' <<<"$node")
    new_sid=$(jq -r '.short_id // ""' <<<"$node")
    if [ "$regen" = "1" ]; then
        local kp
        kp=$(gen_reality_keypair) || die "reality keypair 生成失败"
        new_priv=$(printf '%s' "$kp" | sed -n '1p')
        new_pub=$(printf '%s' "$kp" | sed -n '2p')
        new_sid=$(gen_rand_hex 8)
        log_info "Reality 密钥已重新生成"
    fi

    # ---- 写回 nodes.json（python 合并补丁），再走 apply_config 渲染/校验/回滚 ----
    snapshot_config
    local tmp
    tmp=$(mktemp) || die "mktemp 失败"
    SB_P_ID="$id" \
    SB_P_REMARK="$remark" \
    SB_P_PORT="$new_port" SB_P_PORT_SET="$([ "$port" != "$_U" ] && echo 1 || echo 0)" \
    SB_P_TAG="$new_tag" SB_P_TAG_SET="$tag_set" \
    SB_P_SNI="$new_sni" SB_P_SNI_SET="$sni_set" \
    SB_P_PASSWORD="$password" \
    SB_P_UUID="$new_uuid" SB_P_UUID_SET="$uuid_set" \
    SB_P_PRIV="$new_priv" SB_P_PUB="$new_pub" SB_P_SID="$new_sid" SB_P_REGEN="$regen" \
    SB_P_PORTS="$ports" \
    python3 - "$NODES_JSON" "$tmp" <<'PYEOF' || { rm -f "$tmp"; die "nodes.json 更新失败"; }
import json, os, sys
U = "__SB_UNSET__"
src, dst = sys.argv[1], sys.argv[2]
nodes = json.load(open(src))
nid = os.environ["SB_P_ID"]
def env(n):
    return os.environ.get("SB_P_" + n, U)
def is_set(n):
    return os.environ.get("SB_P_" + n + "_SET", "0") == "1"
for n in nodes:
    if n.get("id") != nid:
        continue
    if is_set("PORT"):
        n["port"] = int(env("PORT"))
    if is_set("TAG"):
        n["tag"] = env("TAG")
    if env("REMARK") != U:
        n["remark"] = env("REMARK")
    if is_set("SNI"):
        n["sni"] = env("SNI")
    if env("PASSWORD") != U:
        n["password"] = env("PASSWORD")
    if is_set("UUID"):
        n["uuid"] = env("UUID")
    if env("REGEN") == "1":
        n["reality_private_key"] = env("PRIV")
        n["reality_public_key"] = env("PUB")
        n["short_id"] = env("SID")
    if env("PORTS") != U:
        if env("PORTS") == "":
            n.pop("ports", None)
        else:
            n["ports"] = env("PORTS")
    break
json.dump(nodes, open(dst, "w"), indent=2, ensure_ascii=False)
PYEOF
    mv "$tmp" "$NODES_JSON"
    apply_config
    log_ok "节点 $id 已修改（协议 $proto）"
    log_info "查看链接：sb-mgr link $id"
}

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
