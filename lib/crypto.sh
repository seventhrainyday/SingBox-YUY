#!/usr/bin/env bash
# crypto.sh - AES-256-GCM 节点配置加密导入导出（前置机 ↔ 落地机对接）
#   sb-mgr node-export --out nodes.enc --password <pw>
#   sb-mgr node-import --in nodes.enc --password <pw> [--yes]
# 文件头自描述算法：
#   V3 = PBKDF2-HMAC-SHA256(20万轮) + 纯标准库 AES-256-GCM（lib/aesgcm.py）
#   V2 = 同上 KDF + python cryptography 库（若已安装则优先）
#   V1 = 已废弃（openssl enc 不支持 AEAD/GCM，无法加解密）
# 注：openssl 的 enc 命令不支持 GCM，因此无 cryptography 时走纯 Python 实现，
#     不依赖 openssl enc。

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_have_crypto_py() {
    python3 -c "from cryptography.hazmat.primitives.ciphers.aead import AESGCM" 2>/dev/null
}

_py_aesgcm_export() { # $1=in $2=out ; 密码经 SB_PW 环境变量传入
    SB_LIB="$LIBDIR" python3 - "$1" "$2" <<'EOF'
import sys, os, json, base64, hashlib, importlib.util
spec = importlib.util.spec_from_file_location(
    "aesgcm", os.path.join(os.environ["SB_LIB"], "aesgcm.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
pw = os.environ["SB_PW"].encode()
data = open(sys.argv[1], "rb").read()
salt = os.urandom(16)
nonce = os.urandom(12)
key = hashlib.pbkdf2_hmac("sha256", pw, salt, 200_000, 32)
ct, tag = m.gcm_encrypt(key, nonce, data, b"SB-V3")
env = {"v": 3,
       "salt": base64.b64encode(salt).decode(),
       "nonce": base64.b64encode(nonce).decode(),
       "ct": base64.b64encode(ct + tag).decode()}
blob = base64.b64encode(json.dumps(env).encode()).decode()
open(sys.argv[2], "w").write("SB-AES256GCM-V3\n" + blob + "\n")
EOF
}

_py_aesgcm_import() { # $1=in $2=out(tmp) ; 密码经 SB_PW 环境变量传入
    SB_LIB="$LIBDIR" python3 - "$1" "$2" <<'EOF'
import sys, os, json, base64, hashlib, importlib.util
spec = importlib.util.spec_from_file_location(
    "aesgcm", os.path.join(os.environ["SB_LIB"], "aesgcm.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
pw = os.environ["SB_PW"].encode()
lines = open(sys.argv[1]).read().splitlines()
env = json.loads(base64.b64decode(lines[1]))
assert env.get("v") == 3, "不是 V3 加密包"
key = hashlib.pbkdf2_hmac("sha256", pw,
                          base64.b64decode(env["salt"]), 200_000, 32)
raw = base64.b64decode(env["ct"])
ct, tag = raw[:-16], raw[-16:]
pt = m.gcm_decrypt(key, base64.b64decode(env["nonce"]), ct, tag, b"SB-V3")
if pt is None:
    sys.exit(7)  # 密码错误或数据被篡改
open(sys.argv[2], "wb").write(pt)
EOF
}

crypto_export_main() { # --out FILE --password PW
    ensure_etc
    local out="" password=""
    while [ $# -gt 0 ]; do case "$1" in
        --out)      out="$2"; shift 2;;
        --password) password="$2"; shift 2;;
        *) die "node-export 未知参数：$1";;
    esac; done
    [ -n "$out" ] && [ -n "$password" ] || die "用法：sb-mgr node-export --out <文件> --password <密码>"
    [ -s "$NODES_JSON" ] || die "nodes.json 为空，无可导出节点"

    if _have_crypto_py; then
        SB_PW="$password" python3 - "$NODES_JSON" "$out" <<'EOF'
import sys, os, json, base64, hashlib
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
pw = os.environ["SB_PW"].encode()
data = open(sys.argv[1], "rb").read()
salt = os.urandom(16); nonce = os.urandom(12)
key = hashlib.pbkdf2_hmac("sha256", pw, salt, 200_000, 32)
ct = AESGCM(key).encrypt(nonce, data, b"SB-V2")
env = {"v": 2, "salt": base64.b64encode(salt).decode(),
       "nonce": base64.b64encode(nonce).decode(),
       "ct": base64.b64encode(ct).decode()}
blob = base64.b64encode(json.dumps(env).encode()).decode()
open(sys.argv[2], "w").write("SB-AES256GCM-V2\n" + blob + "\n")
EOF
        log_ok "已导出（AES-256-GCM V2，cryptography）：$out"
    else
        SB_PW="$password" _py_aesgcm_export "$NODES_JSON" "$out" \
            || die "加密失败"
        log_ok "已导出（AES-256-GCM V3，纯标准库）：$out"
    fi
    chmod 600 "$out"
}

crypto_import_main() { # --in FILE --password PW [--yes]
    ensure_etc
    local in="" password=""
    while [ $# -gt 0 ]; do case "$1" in
        --in)       in="$2"; shift 2;;
        --password) password="$2"; shift 2;;
        --yes)      shift;;  # 兼容性保留：导入本就非交互
        *) die "node-import 未知参数：$1";;
    esac; done
    [ -n "$in" ] && [ -n "$password" ] || die "用法：sb-mgr node-import --in <文件> --password <密码> [--yes]"
    [ -f "$in" ] || die "文件不存在：$in"

    local header tmp
    header=$(head -1 "$in")
    tmp=$(mktemp) || die "mktemp 失败"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN

    case "$header" in
        SB-AES256GCM-V3)
            SB_PW="$password" _py_aesgcm_import "$in" "$tmp" \
                || die "解密失败（密码错误或文件被篡改）"
            ;;
        SB-AES256GCM-V2)
            _have_crypto_py || die "该文件为 V2 格式，需要 python3-cryptography 才能解密（pip install cryptography）"
            if SB_PW="$password" python3 - "$in" "$tmp" <<'EOF'
import sys, os, json, base64, hashlib
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
pw = os.environ["SB_PW"].encode()
lines = open(sys.argv[1]).read().splitlines()
env = json.loads(base64.b64decode(lines[1]))
key = hashlib.pbkdf2_hmac("sha256", pw, base64.b64decode(env["salt"]), 200_000, 32)
try:
    pt = AESGCM(key).decrypt(base64.b64decode(env["nonce"]),
                             base64.b64decode(env["ct"]), b"SB-V2")
except Exception:
    sys.exit(7)
open(sys.argv[2], "wb").write(pt)
EOF
            then
                :
            else
                die "解密失败（密码错误或文件被篡改）"
            fi
            ;;
        SB-AES256GCM-V1)
            die "V1 加密包已废弃（openssl enc 不支持 GCM，无法解密），请用新版重新导出"
            ;;
        *) die "未知的文件头：$header（不是 SingBox-YUY 加密包）" ;;
    esac

    jq -e 'type=="array"' "$tmp" >/dev/null 2>&1 || die "解密内容不是合法的节点数组"
    local cnt
    cnt=$(jq 'length' "$tmp")
    log_info "解密得到 $cnt 个节点，合并入本地节点库（按 id 去重）..."
    local merged
    snapshot_config
    merged=$(mktemp) || die "mktemp 失败"
    jq -s '
        (.[0] | map(.id)) as $ids
        | .[0] + (.[1] | map(select(.id as $i | $ids | index($i) | not)))
    ' "$NODES_JSON" "$tmp" > "$merged" \
        && mv "$merged" "$NODES_JSON" || { rm -f "$merged"; die "合并失败"; }
    apply_config
    log_ok "导入完成，当前共 $(jq 'length' "$NODES_JSON") 个节点"
}
