#!/usr/bin/env bash
# export.sh - 标准 URI / 二维码 / sing-box 客户端 JSON / Mihomo YAML 导出
# 函数：uri_reality / uri_hy2 / uri_tuic / uri_anytls / uri_ss2022（参数为节点 JSON）
#       export_main / link_main

uri_encode() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

export_host() {
    local h
    h=$(json_get "$SETTINGS_JSON" '.host // ""')
    if [ -n "$h" ]; then printf '%s' "$h"; return 0; fi
    public_ip 2>/dev/null || printf '127.0.0.1'
}

node_json() { # $1=id -> 节点 JSON（压缩）
    local id="$1" n
    n=$(jq -c --arg id "$id" '.[] | select(.id==$id)' "$NODES_JSON")
    [ -n "$n" ] || die "未找到节点：$id"
    printf '%s' "$n"
}

uri_reality() { # $1=node-json $2=host
    local n="$1" host="$2"
    local uuid port sni pub sid remark
    uuid=$(jq -r .uuid <<<"$n"); port=$(jq -r .port <<<"$n")
    sni=$(jq -r .sni <<<"$n"); pub=$(jq -r .reality_public_key <<<"$n")
    sid=$(jq -r .short_id <<<"$n"); remark=$(jq -r '.remark//.tag' <<<"$n")
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&type=tcp#%s' \
        "$uuid" "$host" "$port" "$(uri_encode "$sni")" "$(uri_encode "$pub")" \
        "$(uri_encode "$sid")" "$(uri_encode "$remark")"
}

uri_hy2() {
    local n="$1" host="$2"
    local pw port sni remark insecure
    pw=$(jq -r .password <<<"$n"); port=$(jq -r .port <<<"$n")
    sni=$(jq -r .sni <<<"$n"); remark=$(jq -r '.remark//.tag' <<<"$n")
    insecure=1
    [ "$(jq -r .cert_type <<<"$n")" = "acme" ] && insecure=0
    printf 'hysteria2://%s@%s:%s?sni=%s&insecure=%s#%s' \
        "$(uri_encode "$pw")" "$host" "$port" "$(uri_encode "$sni")" \
        "$insecure" "$(uri_encode "$remark")"
}

uri_tuic() {
    local n="$1" host="$2"
    local uuid pw port sni remark
    uuid=$(jq -r .uuid <<<"$n"); pw=$(jq -r .password <<<"$n")
    port=$(jq -r .port <<<"$n"); sni=$(jq -r .sni <<<"$n")
    remark=$(jq -r '.remark//.tag' <<<"$n")
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=1#%s' \
        "$uuid" "$(uri_encode "$pw")" "$host" "$port" \
        "$(uri_encode "$sni")" "$(uri_encode "$remark")"
}

uri_anytls() {
    local n="$1" host="$2"
    local pw port sni remark
    pw=$(jq -r .password <<<"$n"); port=$(jq -r .port <<<"$n")
    sni=$(jq -r .sni <<<"$n"); remark=$(jq -r '.remark//.tag' <<<"$n")
    printf 'anytls://%s@%s:%s?insecure=1&sni=%s#%s' \
        "$(uri_encode "$pw")" "$host" "$port" \
        "$(uri_encode "$sni")" "$(uri_encode "$remark")"
}

uri_ss2022() {
    local n="$1" host="$2"
    local method pw port remark userinfo
    method=$(jq -r .method <<<"$n"); pw=$(jq -r .password <<<"$n")
    port=$(jq -r .port <<<"$n"); remark=$(jq -r '.remark//.tag' <<<"$n")
    userinfo=$(printf '%s:%s' "$method" "$pw" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    printf 'ss://%s@%s:%s#%s' "$userinfo" "$host" "$port" "$(uri_encode "$remark")"
}

node_uri() { # $1=node-json $2=host
    local n="$1" host="$2" proto
    proto=$(jq -r .proto <<<"$n")
    case "$proto" in
        reality) uri_reality "$n" "$host" ;;
        hy2)     uri_hy2 "$n" "$host" ;;
        tuic)    uri_tuic "$n" "$host" ;;
        anytls)  uri_anytls "$n" "$host" ;;
        ss2022)  uri_ss2022 "$n" "$host" ;;
        *) die "未知协议：$proto" ;;
    esac
}

link_main() { # <id> [--qr]
    ensure_etc
    local id="${1:-}" qr=0
    [ -n "$id" ] || die "用法：sb-mgr link <id> [--qr]"
    [ "${2:-}" = "--qr" ] && qr=1
    local n host uri
    n=$(node_json "$id"); host=$(export_host)
    uri=$(node_uri "$n" "$host")
    if [ "$qr" = "1" ]; then
        if command -v qrencode >/dev/null 2>&1; then
            qrencode -t ANSIUTF8 <<<"$uri"
        else
            log_warn "未安装 qrencode（apt install qrencode），先打印链接："
        fi
    fi
    printf '%s\n' "$uri"
}

export_main() { # --format uri|singbox|clash [--out FILE] [--id ID]
    ensure_etc
    local format="" out="" id=""
    while [ $# -gt 0 ]; do case "$1" in
        --format) format="$2"; shift 2;;
        --out)    out="$2"; shift 2;;
        --id)     id="$2"; shift 2;;
        *) die "export 未知参数：$1";;
    esac; done
    [ -n "$format" ] || die "用法：sb-mgr export --format uri|singbox|clash [--out FILE] [--id ID]"

    local result
    case "$format" in
        uri)
            local host
            host=$(export_host)
            if [ -n "$id" ]; then
                result=$(node_uri "$(node_json "$id")" "$host")
            else
                local n line
                result=""
                while IFS= read -r n; do
                    [ -n "$n" ] || continue
                    line=$(node_uri "$n" "$host")
                    if [ -z "$result" ]; then result="$line"
                    else result="${result}"$'\n'"${line}"; fi
                done < <(jq -c '.[]' "$NODES_JSON")
            fi
            ;;
        singbox)
            result=$(python3 "$(builder_py)" client) || die "客户端配置生成失败"
            ;;
        clash)
            result=$(python3 "$(builder_py)" clash) || die "Clash 配置生成失败"
            ;;
        *) die "未知格式：$format（uri|singbox|clash）" ;;
    esac

    if [ -n "$out" ]; then
        printf '%s\n' "$result" > "$out" || die "写入 $out 失败"
        log_ok "已导出到：$out"
    else
        printf '%s\n' "$result"
    fi
}
