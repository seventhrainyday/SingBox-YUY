#!/usr/bin/env bash
# warp.sh - Cloudflare WARP 账号注册 + wireguard 出站配置
# 纯 curl + jq + openssl 实现。用法：sb-mgr warp
# 测试可用 SB_WG_PRIV_HEX=<64位hex> 固定私钥做确定性验证。

WARP_API="https://api.cloudflareclient.com/v0i1909051800/reg"
# WARP peer 公钥固定写在 builder.py 的 build_warp_endpoint() 中

wg_keygen() {
    # 输出两行：私钥base64 \n 公钥base64（均为 32 字节 raw）
    local priv_pem tmpd
    tmpd=$(mktemp -d) || die "mktemp 失败"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpd'" RETURN
    priv_pem="$tmpd/priv.pem"

    if [ -n "${SB_WG_PRIV_HEX:-}" ]; then
        # 测试模式：固定私钥
        python3 - "$priv_pem" <<'EOF'
import sys, base64
raw = bytes.fromhex(__import__("os").environ["SB_WG_PRIV_HEX"])
assert len(raw) == 32, "SB_WG_PRIV_HEX 必须是 64 位 hex"
# 手工组装 PKCS#8 DER（X25519 私钥模板）
der = (bytes.fromhex("302e020100300506032b656e04220420") + raw)
open(sys.argv[1], "wb").write(der)
EOF
    elif openssl genpkey -algorithm X25519 -out "$priv_pem" 2>/dev/null; then
        :
    elif command -v python3 >/dev/null 2>&1 && python3 -c "import cryptography" 2>/dev/null; then
        python3 - "$priv_pem" <<'EOF'
import sys
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives import serialization
priv = x25519.X25519PrivateKey.generate()
der = priv.private_bytes(serialization.Encoding.DER,
                         serialization.PrivateFormat.PKCS8,
                         serialization.NoEncryption())
open(sys.argv[1], "wb").write(der)
EOF
    else
        die "无法生成 X25519 密钥：需要 openssl 3（genpkey -algorithm X25519）或 python3-cryptography"
    fi

    local priv_b64 pub_b64
    priv_b64=$(openssl pkey -in "$priv_pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n') \
        || die "私钥导出失败"
    pub_b64=$(openssl pkey -in "$priv_pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n') \
        || die "公钥派生失败"
    [ "${#priv_b64}" -ge 40 ] && [ "${#pub_b64}" -ge 40 ] || die "密钥长度异常"
    printf '%s\n%s\n' "$priv_b64" "$pub_b64"
}

warp_register() {
    local keys priv_b64 pub_b64
    keys=$(wg_keygen) || die "WireGuard 密钥生成失败"
    priv_b64=$(printf '%s' "$keys" | sed -n '1p')
    pub_b64=$(printf '%s' "$keys" | sed -n '2p')

    log_info "正在向 Cloudflare 注册 WARP 账号..."
    local body resp
    body=$(jq -n --arg key "$pub_b64" \
        '{install_id:"",tos:"2026-10-09T00:00:00.000Z",key:$key,
          fcm_token:"",type:"Android",locale:"en_US"}')
    resp=$(curl -fsS -m 30 -X POST "$WARP_API" \
        -H "Content-Type: application/json" \
        -H "User-Agent: okhttp/3.12.1" \
        -d "$body") || die "WARP 注册请求失败（api.cloudflareclient.com 不可达？）"

    local ok wid addr4 addr6 reserved peer
    ok=$(printf '%s' "$resp" | jq -r '.success // false')
    [ "$ok" = "true" ] || die "WARP 注册被拒绝：$(printf '%s' "$resp" | jq -c '.errors // .' | head -c 300)"
    wid=$(printf '%s' "$resp" | jq -r '.result.id')
    addr4=$(printf '%s' "$resp" | jq -r '.result.config.interface.addresses[] | select(test("^[0-9.]+/"))' | head -1)
    addr6=$(printf '%s' "$resp" | jq -r '.result.config.interface.addresses[] | select(test(":"))' | head -1)
    peer=$(printf '%s' "$resp" | jq -r '.result.config.peers[0].public_key')
    reserved=$(printf '%s' "$resp" | jq -r '.result.config.client_id' \
        | python3 -c 'import sys,base64,json; print(json.dumps(list(base64.b64decode(sys.stdin.read().strip()))))')

    [ -n "$addr4" ] && [ -n "$addr6" ] && [ -n "$peer" ] || die "WARP 响应解析失败"

    local warp_json
    warp_json=$(jq -n \
        --arg priv "$priv_b64" --arg a4 "$addr4" --arg a6 "$addr6" \
        --argjson reserved "$reserved" --arg id "$wid" \
        '{private_key:$priv,local_address:[$a4,$a6],reserved:$reserved,
          account_id:$id,registered_at:"'"$(now_iso)"'"}')
    json_set "$SETTINGS_JSON" --argjson w "$warp_json" '.warp = $w'
    log_ok "WARP 注册成功：account_id=$wid"
    log_info "地址：$addr4 / $addr6，reserved=$reserved"
}

warp_main() {
    ensure_etc
    local cur
    cur=$(json_get "$SETTINGS_JSON" '.warp // null')
    if [ "$cur" != "null" ]; then
        log_warn "已存在 WARP 配置，重新注册将覆盖"
        if [ "${SB_MGR_YES:-0}" != "1" ] && [ -t 0 ]; then
            printf '确认重新注册？[y/N] '; read -r ans
            case "$ans" in [yY]*) ;; *) log_info "已取消"; return 0;; esac
        fi
    fi
    warp_register
    apply_config
    log_ok "warp 出站已加入配置；用 'sb-mgr route-unlock' 开启流媒体/AI 解锁分流"
}
