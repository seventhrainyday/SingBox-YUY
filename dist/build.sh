#!/usr/bin/env bash
# dist/build.sh - 生成单文件发行版 dist/sb（可重复运行、输出确定性）
#
# 用法：bash dist/build.sh
# 输出：dist/sb（chmod +x），提交进仓库供用户 curl 下载。
# 结构：文件头 -> bootstrap -> __sb_write_payloads（base64 内嵌 7 个 payload）
#       -> __sb_ensure_payloads -> 内联 lib/*.sh -> 内联 sb-mgr 主体
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$PROJ/dist"
OUT="$DIST/sb"

SB_VERSION="$(sed -n 's/^SB_VERSION="\(.*\)"$/\1/p' "$PROJ/lib/common.sh" | head -1)"
[ -n "$SB_VERSION" ] || { echo "无法从 lib/common.sh 读取 SB_VERSION" >&2; exit 1; }

# payload 清单：目标路径:源文件（释放时保持子目录结构）
PAYLOADS=(
    "py/builder.py:lib/builder.py"
    "py/subsrv.py:lib/subsrv.py"
    "py/aesgcm.py:lib/aesgcm.py"
    "systemd/sing-box.service:systemd/sing-box.service"
    "systemd/singbox-yuy-sub.service:systemd/singbox-yuy-sub.service"
    "openrc/singbox.initd:openrc/singbox.initd"
    "openrc/singbox-yuy-sub.initd:openrc/singbox-yuy-sub.initd"
)
# lib 内联顺序（与 sb-mgr 的 source 顺序一致）
LIB_ORDER=(common envcheck install inbound warp route export sub crypto tui)

for p in "${PAYLOADS[@]}"; do
    [ -f "$PROJ/${p#*:}" ] || { echo "payload 源文件缺失：${p#*:}" >&2; exit 1; }
done
for l in "${LIB_ORDER[@]}"; do
    [ -f "$PROJ/lib/$l.sh" ] || { echo "lib 文件缺失：lib/$l.sh" >&2; exit 1; }
done

mkdir -p "$DIST"

{
    # ---- 文件头 ----
    printf '#!/usr/bin/env bash\n'
    printf '# SingBox-YUY 单文件发行版 v%s\n' "$SB_VERSION"
    printf '# 由 dist/build.sh 生成，请勿手工修改；改源码后重跑 build。\n'
    printf 'set -euo pipefail\n'

    # ---- bootstrap（手写模板；quoted heredoc 防展开，再 sed 替换版本号）----
    sed -e "s/@SB_VERSION@/$SB_VERSION/g" <<'BOOTSTRAP_EOF'

# ===== bootstrap：单文件模式初始化 =====
SB_BUNDLED=1
export SB_BUNDLED
if [ "$(id -u)" -eq 0 ]; then
    SB_HOME="${SB_HOME:-/opt/singbox-yuy}"
else
    SB_HOME="${SB_HOME:-${HOME:-/tmp}/.singbox-yuy}"
fi
export SB_HOME
SB_DIST_VERSION="@SB_VERSION@"
SB_DIST_URL="${SB_DIST_URL:-https://raw.githubusercontent.com/seventhrainyday/SingBox-YUY/main/dist/sb}"
export SB_DIST_VERSION SB_DIST_URL
# 自定位：PATH 里能找到就用绝对路径，否则回退 $0（./dist/sb、bash dist/sb 等）
SB_SELF="$(command -v "$0" 2>/dev/null || true)"
[ -n "$SB_SELF" ] || SB_SELF="$0"
export SB_MGR="$SB_SELF"
BOOTSTRAP_EOF

    # ---- payload 释放函数（build 时生成 7 段 base64 heredoc）----
    printf '\n__sb_write_payloads() {\n'
    printf '    # 释放内嵌 payload（base64 -d），保持子目录结构\n'
    printf '    mkdir -p "$SB_HOME/py" "$SB_HOME/systemd" "$SB_HOME/openrc"\n'
    i=0 dest="" src=""
    for p in "${PAYLOADS[@]}"; do
        dest="${p%%:*}"; src="${p#*:}"
        i=$((i + 1))
        # 双引号定界符同样阻止 heredoc 展开，且无需单引号转义体操
        printf '    base64 -d > "$SB_HOME/%s" << "__SB_PAYLOAD_%d__"\n' "$dest" "$i"
        base64 "$PROJ/$src"
        # 结束定界符必须顶格（heredoc 语法要求），不能缩进
        printf '__SB_PAYLOAD_%d__\n' "$i"
    done
    printf '}\n'

    # ---- payload 版本管理 ----
    cat <<'ENSURE_EOF'

__sb_ensure_payloads() {
    # 版本标记不一致或关键文件缺失时，重新释放全部 payload
    local vf="$SB_HOME/.dist_version" need=0
    [ -f "$vf" ] || need=1
    if [ "$need" = "0" ] && [ "$(cat "$vf" 2>/dev/null)" != "$SB_DIST_VERSION" ]; then
        need=1
    fi
    if [ "$need" = "0" ]; then
        local f
        for f in py/builder.py py/subsrv.py py/aesgcm.py \
                 systemd/sing-box.service systemd/singbox-yuy-sub.service \
                 openrc/singbox.initd openrc/singbox-yuy-sub.initd; do
            [ -f "$SB_HOME/$f" ] || { need=1; break; }
        done
    fi
    if [ "$need" = "1" ]; then
        mkdir -p "$SB_HOME"
        __sb_write_payloads
        printf '%s\n' "$SB_DIST_VERSION" > "$vf"
    fi
}

__sb_ensure_payloads
ENSURE_EOF

    # ---- 内联 lib/*.sh（去掉首行 shebang）----
    for lib in "${LIB_ORDER[@]}"; do
        printf '\n# ===== lib/%s.sh（内联） =====\n' "$lib"
        sed '1{/^#!/d}' "$PROJ/lib/$lib.sh"
    done

    # ---- 内联 sb-mgr 主体 ----
    printf '\n# ===== sb-mgr 主体（内联） =====\n'
    printf 'PROG="$(basename "${SB_SELF:-sb-mgr}")"\n'
    sed -e '1{/^#!/d}' \
        -e '/^set -euo pipefail$/d' \
        -e '/^MGR_DIR=/d' \
        -e '/^LIB=/d' \
        -e '/^\. "\$LIB\//d' \
        -e 's/sb-mgr/$PROG/g' \
        "$PROJ/sb-mgr"
} > "$OUT"

chmod +x "$OUT"
printf '已生成：%s（%s 字节，版本 %s）\n' "$OUT" "$(wc -c < "$OUT")" "$SB_VERSION"
