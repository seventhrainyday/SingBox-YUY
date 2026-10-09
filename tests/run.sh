#!/usr/bin/env bash
# tests/run.sh - SingBox-YUY 一键测试（CI 与本地通用）
# 1. lint：shellcheck + bash -n + py_compile
# 2. builder.py --test 生成示例 -> 真实 sing-box check 逐个校验 + clash YAML 结构校验
# 3. crypto 加密->解密回环 diff
# 4. subsrv.py --test 冒烟
# 5. sb-mgr 端到端：add/del/link/export/relay（临时 SB_ETC）
# 任一失败即非零退出。
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTDIR="/tmp/sb-mgr-test"
SBDIR="/tmp/sb-mgr-singbox"
export SB_BIN="$SBDIR/sing-box"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$*" >&2; }

SC_BIN=""
if command -v shellcheck >/dev/null 2>&1; then SC_BIN="shellcheck";
elif [ -x "$PROJ/.tools/shellcheck" ]; then SC_BIN="$PROJ/.tools/shellcheck";
elif [ -x "$HOME/workspace/.tools/shellcheck" ]; then SC_BIN="$HOME/workspace/.tools/shellcheck"; fi

echo "=== [1/7] lint ==="
if [ -z "$SC_BIN" ]; then fail "未找到 shellcheck"; else
    if "$SC_BIN" -S warning "$PROJ"/lib/*.sh "$PROJ/sb-mgr" "$PROJ/tests/run.sh" "$PROJ/install.sh"; then
        ok "shellcheck -S warning 零警告"
    else fail "shellcheck 发现警告"; fi
fi
for f in "$PROJ"/lib/*.sh "$PROJ/sb-mgr" "$PROJ/tests/run.sh" "$PROJ/install.sh"; do
    bash -n "$f" || { fail "bash -n 失败：$f"; }
done
ok "bash -n 全部通过"
python3 -m py_compile "$PROJ/lib/builder.py" "$PROJ/lib/subsrv.py" "$PROJ/lib/aesgcm.py" \
    && ok "py_compile 通过" || fail "py_compile 失败"
python3 "$PROJ/lib/aesgcm.py" && ok "aesgcm 自检通过" || fail "aesgcm 自检失败"

echo "=== [2/7] 准备 sing-box 真实二进制 ==="
mkdir -p "$SBDIR" "$TESTDIR"
if [ ! -x "$SB_BIN" ]; then
    TAG=$(curl -fsS -m 30 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    ARCH=amd64; [ "$(uname -m)" = "aarch64" ] && ARCH=arm64
    curl -fSL -m 300 -o "$SBDIR/sb.tar.gz" \
        "https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${TAG#v}-linux-${ARCH}.tar.gz"
    tar -xzf "$SBDIR/sb.tar.gz" -C "$SBDIR"
    BIN=$(find "$SBDIR" -maxdepth 2 -name sing-box -type f ! -name "*.tar.gz" | head -1)
    mv "$BIN" "$SB_BIN"; chmod +x "$SB_BIN"
fi
"$SB_BIN" version | head -1
ok "sing-box 二进制就绪：$SB_BIN"

echo "=== [3/7] builder --test + sing-box check ==="
# 自签证书占位（hy2/tuic/anytls 示例引用此路径；check 可能校验文件存在）
openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=test.example.com" \
    -keyout "$TESTDIR/key.pem" -out "$TESTDIR/cert.pem" -days 30 2>/dev/null
chmod 600 "$TESTDIR/key.pem"
SB_ETC="$TESTDIR" python3 "$PROJ/lib/builder.py" --test --out-dir "$TESTDIR"
for cfg in "$TESTDIR"/server-full.json "$TESTDIR"/server-basic.json "$TESTDIR"/client.json; do
    if "$SB_BIN" check -c "$cfg" >/dev/null 2>&1; then
        ok "sing-box check 通过：$(basename "$cfg")"
    else
        fail "sing-box check 失败：$(basename "$cfg")"
        "$SB_BIN" check -c "$cfg" 2>&1 | head -10 >&2 || true
    fi
done
if python3 - "$TESTDIR/client.clash.yaml" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert isinstance(d.get("proxies"), list) and len(d["proxies"]) == 5, "proxies!=5"
assert any(g["name"] == "PROXY" for g in d["proxy-groups"]), "缺 PROXY 组"
assert "MATCH,PROXY" in d["rules"], "缺 MATCH 规则"
types = sorted(p["type"] for p in d["proxies"])
assert types == ["anytls", "hysteria2", "ss", "tuic", "vless"], types
EOF
then
    ok "clash YAML 结构校验通过（5 proxies / PROXY+AUTO / MATCH）"
else
    fail "clash YAML 校验失败"
fi

# builder 负向测试：端口冲突应拒绝
SB_ETC_NEG="$TESTDIR/neg"
mkdir -p "$SB_ETC_NEG"
python3 - "$SB_ETC_NEG" <<'EOF'
import json, sys
d = sys.argv[1]
n = [{"id": "a1", "proto": "ss2022", "tag": "ss-1", "port": 8388,
      "method": "2022-blake3-aes-128-gcm", "password": "cGFzc3dvcmQ=",
      "remark": "x", "created": "2026-10-09T00:00:00Z"},
     {"id": "a2", "proto": "ss2022", "tag": "ss-2", "port": 8388,
      "method": "2022-blake3-aes-128-gcm", "password": "cGFzc3dvcmQ=",
      "remark": "y", "created": "2026-10-09T00:00:00Z"}]
json.dump(n, open(d + "/nodes.json", "w"))
json.dump({"host": "127.0.0.1", "relays": []}, open(d + "/settings.json", "w"))
EOF
if SB_ETC="$SB_ETC_NEG" python3 "$PROJ/lib/builder.py" >/dev/null 2>&1; then
    fail "builder 未拒绝端口冲突"
else
    ok "builder 正确拒绝端口冲突（负向测试）"
fi

echo "=== [4/7] crypto 回环测试 ==="
FIX="$TESTDIR/fixture"
mkdir -p "$FIX"
export FIXD="$FIX"
SB_ETC="$FIX" python3 - <<'EOF'
import json, subprocess, os
sb = os.environ["SB_BIN"]
out = subprocess.run([sb, "generate", "reality-keypair"],
                     capture_output=True, text=True)
priv = pub = ""
for line in out.stdout.splitlines():
    if "Private" in line:
        priv = line.split()[-1]
    if "Public" in line:
        pub = line.split()[-1]
assert priv and pub, "reality-keypair 生成失败"
nodes = [
    {"id": "f1", "proto": "reality", "tag": "reality-443", "port": 443,
     "uuid": "11111111-2222-4333-8444-555555555555", "flow": "xtls-rprx-vision",
     "sni": "www.sony.com", "reality_private_key": priv,
     "reality_public_key": pub, "short_id": "aabbccdd",
     "remark": "回环-reality", "created": "2026-10-09T00:00:00Z"},
    {"id": "f2", "proto": "ss2022", "tag": "ss-8388", "port": 8388,
     "method": "2022-blake3-aes-128-gcm",
     "password": "MDEyMzQ1Njc4OWFiY2RlZg==", "remark": "回环-ss",
     "created": "2026-10-09T00:00:00Z"},
]
d = os.environ["FIXD"]
json.dump(nodes, open(d + "/nodes.json", "w"))
json.dump({"host": "203.0.113.9", "sub_port": 2096, "sub_token": "tok123",
           "unlock": False, "relays": []},
          open(d + "/settings.json", "w"))
print("fixture written")
EOF
[ -s "$FIX/nodes.json" ] || { fail "fixture 写入失败"; exit 1; }
cp "$FIX/nodes.json" "$TESTDIR/nodes.orig.json"
SB_ETC="$FIX" "$PROJ/sb-mgr" node-export --out "$TESTDIR/nodes.enc" --password "testpw123" \
    && ok "node-export 加密成功" || fail "node-export 失败"
head -1 "$TESTDIR/nodes.enc" | grep -q "SB-AES256GCM-V" \
    && ok "加密文件头自描述" || fail "加密文件头缺失"
IMP="$TESTDIR/imported"; mkdir -p "$IMP"
printf '[]' > "$IMP/nodes.json"
printf '{"host":"203.0.113.9","relays":[]}' > "$IMP/settings.json"
SB_ETC="$IMP" SB_MGR_YES=1 "$PROJ/sb-mgr" node-import --in "$TESTDIR/nodes.enc" \
    --password "testpw123" --yes >/dev/null \
    && ok "node-import 解密成功" || fail "node-import 失败"
if python3 -c "
import json
a=json.load(open('$TESTDIR/nodes.orig.json')); b=json.load(open('$IMP/nodes.json'))
assert a==b, '回环不一致'
"; then ok "加密->解密回环 diff 一致"; else fail "回环 diff 不一致"; fi
# 错误密码应失败
if SB_ETC="$IMP" "$PROJ/sb-mgr" node-import --in "$TESTDIR/nodes.enc" \
    --password "wrongpw" --yes >/dev/null 2>&1; then
    fail "错误密码竟解密成功"
else ok "错误密码正确被拒绝"; fi

# aesgcm 纯 Python 实现 vs cryptography 库：20 轮随机交叉验证
#（cryptography 装在 /tmp/cvlib 隔离目录，不污染主 python，保证上面走的是 V3 路径）
if [ -d /tmp/cvlib/cryptography ]; then
    if PYTHONPATH="/tmp/cvlib" python3 - "$PROJ/lib" <<'EOF'; then
import os, random, sys
sys.path.insert(0, sys.argv[1])
import aesgcm
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
random.seed(20261009)
for t in range(20):
    key = os.urandom(32); nonce = os.urandom(12)
    pt = os.urandom(random.randrange(0, 300))
    aad = os.urandom(random.randrange(0, 40))
    ct1, tag1 = aesgcm.gcm_encrypt(key, nonce, pt, aad)
    ref = AESGCM(key).encrypt(nonce, pt, aad)
    assert ct1 + tag1 == ref, "trial %d: 密文/tag 与参考实现不一致" % t
    assert AESGCM(key).decrypt(nonce, ct1 + tag1, aad) == pt
    assert aesgcm.gcm_decrypt(key, nonce, ref[:-16], ref[-16:], aad) == pt
    bad = bytearray(ct1 or b"\x00"); bad[0] ^= 1
    assert aesgcm.gcm_decrypt(key, nonce, bytes(bad), tag1, aad) is None, \
        "trial %d: 篡改未被检出" % t
print("cross-validation: 20/20 OK")
EOF
        ok "aesgcm 与 cryptography 交叉验证通过（20 轮随机）"
    else fail "aesgcm 交叉验证失败"; fi
else
    log_warn "跳过 aesgcm 交叉验证（/tmp/cvlib 无 cryptography）"
fi

echo "=== [5/7] subsrv 冒烟测试 ==="
export SB_MGR="$PROJ/sb-mgr"
if SB_ETC="$FIX" python3 "$PROJ/lib/subsrv.py" --test; then
    ok "subsrv 冒烟测试通过"
else fail "subsrv 冒烟测试失败"; fi

echo "=== [6/7] sb-mgr 端到端（add/link/export/relay/del）==="
E2E="$TESTDIR/e2e"; mkdir -p "$E2E"
export SB_ETC="$E2E"
export SB_SYSCTL_D="$TESTDIR/sysctl.d"  # UDP 调优写入隔离目录，不污染测试机
printf '[]' > "$E2E/nodes.json"
printf '{"host":"203.0.113.8","relays":[]}' > "$E2E/settings.json"
M="$PROJ/sb-mgr"
"$M" add --proto ss2022 --port 18388 --remark "e2e-ss" --yes >/dev/null \
    && ok "add ss2022 成功" || fail "add ss2022 失败"
"$M" add --proto anytls --port 18443 --remark "e2e-anytls" --yes >/dev/null \
    && ok "add anytls 成功" || fail "add anytls 失败"
"$M" add --proto hy2 --port 18444 --sni "test.example.com" --remark "e2e-hy2" --yes >/dev/null \
    && ok "add hy2 成功" || fail "add hy2 失败"
"$M" add --proto tuic --port 18445 --sni "test.example.com" --remark "e2e-tuic" --yes >/dev/null \
    && ok "add tuic 成功" || fail "add tuic 失败"
"$M" add --proto reality --port 18446 --sni www.sony.com --remark "e2e-reality" --yes >/dev/null \
    && ok "add reality 成功" || fail "add reality 失败"
"$SB_BIN" check -c "$E2E/config.json" >/dev/null 2>&1 \
    && ok "端到端 config.json（5 协议）通过 sing-box check" || fail "端到端 check 失败"
ID_SS=$(jq -r '.[] | select(.proto=="ss2022") | .id' "$E2E/nodes.json")
URI_SS=$("$M" link "$ID_SS")
case "$URI_SS" in ss://*) ok "ss URI 格式正确";; *) fail "ss URI 格式错误：$URI_SS";; esac
ID_HY2=$(jq -r '.[] | select(.proto=="hy2") | .id' "$E2E/nodes.json")
URI_HY2=$("$M" link "$ID_HY2")
case "$URI_HY2" in hysteria2://*sni=test.example.com*insecure=1*) ok "hy2 URI 格式正确";; *) fail "hy2 URI 错误";; esac
ID_TUIC=$(jq -r '.[] | select(.proto=="tuic") | .id' "$E2E/nodes.json")
URI_TUIC=$("$M" link "$ID_TUIC")
case "$URI_TUIC" in tuic://*congestion_control=bbr*allow_insecure=1*) ok "tuic URI 格式正确";; *) fail "tuic URI 错误";; esac
ID_AT=$(jq -r '.[] | select(.proto=="anytls") | .id' "$E2E/nodes.json")
case "$("$M" link "$ID_AT")" in anytls://*insecure=1'&'sni=*) ok "anytls URI 最短化正确";; *) fail "anytls URI 错误";; esac
ID_RL=$(jq -r '.[] | select(.proto=="reality") | .id' "$E2E/nodes.json")
URI_RL=$("$M" link "$ID_RL")
case "$URI_RL" in vless://*security=reality*pbk=*) ok "reality URI 格式正确";; *) fail "reality URI 错误";; esac
"$M" export --format singbox --out "$TESTDIR/e2e-client.json" >/dev/null \
    && "$SB_BIN" check -c "$TESTDIR/e2e-client.json" >/dev/null 2>&1 \
    && ok "export singbox 客户端配置通过 check" || fail "export singbox 失败"
"$M" export --format clash --out "$TESTDIR/e2e-clash.yaml" >/dev/null \
    && python3 -c "import yaml; yaml.safe_load(open('$TESTDIR/e2e-clash.yaml'))" \
    && ok "export clash YAML 合法" || fail "export clash 失败"
# relay：用刚生成的 reality 链接做中转
"$M" relay-add --link "$URI_RL" >/dev/null \
    && ok "relay-add --link 成功" || fail "relay-add 失败"
"$M" relay-route --tag relay-1 --geosite netflix,youtube >/dev/null \
    && ok "relay-route 绑定成功" || fail "relay-route 失败"
"$SB_BIN" check -c "$E2E/config.json" >/dev/null 2>&1 \
    && ok "含 relay 的服务端配置通过 check" || fail "relay 配置 check 失败"
"$M" relay-del --tag relay-1 >/dev/null && ok "relay-del 成功" || fail "relay-del 失败"
"$M" del "$ID_SS" >/dev/null && ok "del 节点成功" || fail "del 失败"
[ "$(jq 'length' "$E2E/nodes.json")" = "4" ] && ok "删除后剩余 4 节点" || fail "删除后节点数不对"

# 回滚语义回归测试：check 失败时 nodes.json 必须恢复到修改前（无残留节点）
RB="$TESTDIR/rollback"; mkdir -p "$RB"
printf '[]' > "$RB/nodes.json"
printf '{"host":"203.0.113.8","relays":[]}' > "$RB/settings.json"
printf '#!/usr/bin/env bash\necho "fake sing-box: check failed" >&2\nexit 1\n' > "$TESTDIR/fake-singbox"
chmod +x "$TESTDIR/fake-singbox"
BEFORE=$(md5sum < "$RB/nodes.json")
if SB_ETC="$RB" SB_BIN="$TESTDIR/fake-singbox" "$M" add --proto ss2022 --port 19999 --yes >/dev/null 2>&1; then
    fail "fake check 本应失败却通过了"
else
    AFTER=$(md5sum < "$RB/nodes.json")
    if [ "$BEFORE" = "$AFTER" ] && [ "$(jq 'length' "$RB/nodes.json")" = "0" ]; then
        ok "check 失败后 nodes.json 正确回滚（无残留节点）"
    else
        fail "回滚失败：nodes.json 在 check 失败后被修改"
    fi
fi

echo "=== [7/7] 多系统逻辑自测（detect_pm + 包名映射）==="
FIXT="$TESTDIR/osrelease"; mkdir -p "$FIXT"
printf 'ID=alpine\nVERSION_ID=3.19.0\n' > "$FIXT/alpine"
printf 'ID=ubuntu\nVERSION_ID=24.04\n' > "$FIXT/ubuntu"
printf 'ID=fedora\nVERSION_ID=41\n' > "$FIXT/fedora"
printf 'ID=arch\n' > "$FIXT/arch"
printf 'ID=opensuse-leap\nVERSION_ID=15.6\n' > "$FIXT/opensuse"
printf 'ID=rhel\nVERSION_ID=7.9\n' > "$FIXT/rhel7"
printf 'ID=rocky\nVERSION_ID=9.4\n' > "$FIXT/rocky9"
printf 'ID=customdistro\nID_LIKE="debian ubuntu"\n' > "$FIXT/like-debian"
pm_of() { # $1=fixture -> 包管理器（子 shell 中 source，避免污染主环境）
    OS_RELEASE_FILE="$FIXT/$1" bash -c '. "$0" >/dev/null 2>&1; detect_pm' "$PROJ/lib/common.sh"
}
pm_expect() { # $1=fixture $2=期望
    local got
    got=$(pm_of "$1")
    if [ "$got" = "$2" ]; then ok "detect_pm($1)=$got"; else fail "detect_pm($1)=$got，期望 $2"; fi
}
pm_expect alpine apk
pm_expect ubuntu apt-get
pm_expect fedora dnf
pm_expect arch pacman
pm_expect opensuse zypper
pm_expect rhel7 yum
pm_expect rocky9 dnf
pm_expect like-debian apt-get
# 包名映射：每种 pm 下每个通用名都必须有非空映射
pm_map_ok() { # $1=pm；0=完整
    bash -c '
        . "$0" >/dev/null 2>&1
        for g in curl jq python3 openssl ca-certificates iproute2 qrencode whiptail procps git; do
            n=$(pkg_name "$g" "$1") || n=""
            [ -n "$n" ] || { echo "EMPTY:$g" >&2; exit 1; }
        done' "$PROJ/lib/common.sh" "$1"
}
for _pm in apt-get dnf yum apk pacman zypper; do
    if pm_map_ok "$_pm" 2>/dev/null; then
        ok "包名映射完整：$_pm"
    else
        fail "包名映射缺失：$_pm"
    fi
done
# 关键差异映射 spot-check
[ "$(bash -c '. "$0" >/dev/null 2>&1; pkg_name whiptail dnf' "$PROJ/lib/common.sh")" = "newt" ] \
    && ok "whiptail 在 dnf 下映射为 newt" || fail "whiptail/dnf 映射错误"
[ "$(bash -c '. "$0" >/dev/null 2>&1; pkg_name whiptail pacman' "$PROJ/lib/common.sh")" = "libnewt" ] \
    && ok "whiptail 在 pacman 下映射为 libnewt" || fail "whiptail/pacman 映射错误"
[ "$(bash -c '. "$0" >/dev/null 2>&1; pkg_name iproute2 yum' "$PROJ/lib/common.sh")" = "iproute" ] \
    && ok "iproute2 在 yum 下映射为 iproute" || fail "iproute2/yum 映射错误"
[ "$(bash -c '. "$0" >/dev/null 2>&1; pkg_name procps zypper' "$PROJ/lib/common.sh")" = "procps4" ] \
    && ok "procps 在 zypper 下映射为 procps4" || fail "procps/zypper 映射错误"

echo "=== [8/8] 二进制冒烟测试 + gcompat 兜底 ==="
MUSLDIR="$TESTDIR/musl"; mkdir -p "$MUSLDIR"
touch "$MUSLDIR/alpine-release"   # 伪造 Alpine 标记文件
printf '#!/usr/bin/env bash\nexit 1\n' > "$MUSLDIR/badbin"; chmod +x "$MUSLDIR/badbin"
printf '#!/usr/bin/env bash\necho "sing-box version 1.14.3"\n' > "$MUSLDIR/goodbin"; chmod +x "$MUSLDIR/goodbin"
# run_ensure $bin -> 回显 0/1；子 shell 里桩掉 pkg_install，避免测试真装包
run_ensure() {
    ALPINE_RELEASE_FILE="$MUSLDIR/alpine-release" bash -c '
        . "$0" >/dev/null 2>&1
        . "$1" >/dev/null 2>&1
        pkg_install() { return 0; }
        if ensure_binary_runnable "$2" >/dev/null 2>&1; then echo 0; else echo 1; fi' \
        "$PROJ/lib/common.sh" "$PROJ/lib/install.sh" "$1"
}
[ "$(run_ensure "$MUSLDIR/goodbin")" = "0" ] \
    && ok "可运行二进制直接通过冒烟测试" || fail "goodbin 应返回 0"
[ "$(run_ensure "$MUSLDIR/badbin")" = "1" ] \
    && ok "不可运行二进制经 gcompat 兜底仍失败时返回 1" || fail "badbin 应返回 1"
[ "$(bash -c '. "$0" >/dev/null 2>&1; pkg_name gcompat apk' "$PROJ/lib/common.sh")" = "gcompat" ] \
    && ok "gcompat 在 apk 下映射为 gcompat" || fail "gcompat/apk 映射错误"
[ -z "$(bash -c '. "$0" >/dev/null 2>&1; pkg_name gcompat apt-get' "$PROJ/lib/common.sh")" ] \
    && ok "gcompat 在 apt-get 下无映射（自动跳过）" || fail "gcompat 不应在 apt-get 下有映射"

echo "----------------------------------------"
printf '结果：%d 通过，%d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
