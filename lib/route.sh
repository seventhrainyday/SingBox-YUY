#!/usr/bin/env bash
# route.sh - 路由规则管理：解锁分流开关、链式中转出站
#   sb-mgr route-unlock
#   sb-mgr relay-add --link "vless://..." | --from-node <id> [--host H]
#   sb-mgr relay-route --tag relay-1 --geosite netflix,youtube
#   sb-mgr relay-del --tag relay-1
#   sb-mgr relay-list

route_unlock_main() {
    ensure_etc
    local warp
    warp=$(json_get "$SETTINGS_JSON" '.warp // null')
    [ "$warp" != "null" ] || die "尚未配置 WARP，请先执行：sb-mgr warp"
    json_set "$SETTINGS_JSON" '.unlock = true'
    apply_config
    log_ok "流媒体/AI 解锁路由已开启（走 warp 出站）"
}

route_lock_main() {
    ensure_etc
    json_set "$SETTINGS_JSON" '.unlock = false'
    apply_config
    log_ok "流媒体/AI 解锁路由已关闭"
}

_relay_next_tag() {
    local max=0 n
    n=$(jq -r '.relays // [] | .[].tag' "$SETTINGS_JSON" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
    [ -n "$n" ] && max="$n"
    printf 'relay-%d' $((max + 1))
}

relay_add_main() { # [--link URI] | [--from-node <id> [--host H]]
    ensure_etc
    local link="" from_node="" host=""
    while [ $# -gt 0 ]; do case "$1" in
        --link)      link="$2"; shift 2;;
        --from-node) from_node="$2"; shift 2;;
        --host)      host="$2"; shift 2;;
        *) die "relay-add 未知参数：$1";;
    esac; done

    local ob tag
    if [ -n "$link" ]; then
        ob=$(python3 "$(builder_py)" parse-link "$link") \
            || die "链接解析失败"
    elif [ -n "$from_node" ]; then
        if [ -z "$host" ]; then
            host=$(json_get "$SETTINGS_JSON" '.host')
            [ -n "$host" ] || die "请指定 --host <落地机地址>（或先 sb-mgr set-host）"
        fi
        ob=$(python3 "$(builder_py)" node-outbound "$from_node" "$host") \
            || die "节点 $from_node 不存在"
    else
        die "用法：sb-mgr relay-add --link \"vless://...\" 或 --from-node <id> [--host H]"
    fi
    # 校验是合法 JSON
    printf '%s' "$ob" | jq -e . >/dev/null || die "出站 JSON 非法"

    tag=$(_relay_next_tag)
    local entry
    entry=$(jq -n --arg tag "$tag" --argjson ob "$ob" \
        '{tag:$tag, outbound:$ob, geosites:[]}')
    json_set "$SETTINGS_JSON" --argjson e "$entry" '.relays += [$e]'
    apply_config
    log_ok "中转出站已添加：$tag"
    log_info "用 'sb-mgr relay-route --tag $tag --geosite netflix,youtube' 为其绑定分流规则"
}

relay_route_main() { # --tag relay-1 --geosite netflix,youtube
    ensure_etc
    local tag="" geosites=""
    while [ $# -gt 0 ]; do case "$1" in
        --tag)     tag="$2"; shift 2;;
        --geosite) geosites="$2"; shift 2;;
        *) die "relay-route 未知参数：$1";;
    esac; done
    [ -n "$tag" ] && [ -n "$geosites" ] || die "用法：sb-mgr relay-route --tag <tag> --geosite <g1,g2>"
    jq -e --arg t "$tag" '.relays // [] | map(select(.tag==$t)) | length > 0' "$SETTINGS_JSON" >/dev/null \
        || die "未找到中转出站：$tag"
    local arr
    arr=$(printf '%s' "$geosites" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))')
    json_set "$SETTINGS_JSON" --arg t "$tag" --argjson g "$arr" \
        '(.relays[] | select(.tag==$t) | .geosites) = $g'
    apply_config
    log_ok "已为 $tag 绑定 geosite 规则：$geosites"
}

relay_del_main() { # --tag relay-1
    ensure_etc
    local tag=""
    while [ $# -gt 0 ]; do case "$1" in
        --tag) tag="$2"; shift 2;;
        *) die "relay-del 未知参数：$1";;
    esac; done
    [ -n "$tag" ] || die "用法：sb-mgr relay-del --tag <tag>"
    json_set "$SETTINGS_JSON" --arg t "$tag" '.relays |= map(select(.tag!=$t))'
    apply_config
    log_ok "中转出站 $tag 已删除"
}

relay_list_main() {
    ensure_etc
    local n
    n=$(jq '.relays // [] | length' "$SETTINGS_JSON")
    [ "$n" -eq 0 ] && { log_info "暂无中转出站"; return 0; }
    printf '%-10s %-10s %s\n' "TAG" "类型" "geosite 规则"
    jq -r '.relays[] | [.tag, .outbound.type, (.geosites|join(","))] | @tsv' "$SETTINGS_JSON" \
    | while IFS=$'\t' read -r tag type gs; do
        printf '%-10s %-10s %s\n' "$tag" "$type" "${gs:-（未绑定）}"
    done
}
