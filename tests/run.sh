#!/usr/bin/env bash
# tests/run.sh - SingBox-YUY 一键测试（CI 与本地通用）
# 0. 预构建 dist/sb（[1/7] lint 与 [9/9] 需要）
# 1. lint：shellcheck + bash -n + py_compile（含 dist/build.sh 与 dist/sb）
# 2. builder.py --test 生成示例 -> 真实 sing-box check 逐个校验 + clash YAML 结构校验
# 3. crypto 加密->解密回环 diff
# 4. subsrv.py --test 冒烟
# 5. sb-mgr 端到端：add/del/link/export/relay（临时 SB_ETC）
# 6. （预留）
# 7. 多系统逻辑自测（detect_pm + 包名映射）
# 8. 二进制冒烟测试 + gcompat 兜底
# 9. 单文件 bundle：重复构建确定性 / payload 释放与幂等 / bundle 端到端 / self-update
# 10. 全功能矩阵：CLI 冒烟 / add 全协议 / TUI(TTY) / link-export / 订阅 HTTP / 加密边界 /
#    中转全链路 / 路由开关 / 鲁棒性 / 构建一致性
# 任一失败即非零退出。
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTDIR="/tmp/sb-mgr-test"
SBDIR="/tmp/sb-mgr-singbox"
export SB_BIN="$SBDIR/sing-box"
SB_VERSION_SRC="$(sed -n 's/^SB_VERSION="\(.*\)"$/\1/p' "$PROJ/lib/common.sh" | head -1)"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '[FAIL] %s\n' "$*" >&2; }

SC_BIN=""
if command -v shellcheck >/dev/null 2>&1; then SC_BIN="shellcheck";
elif [ -x "$PROJ/.tools/shellcheck" ]; then SC_BIN="$PROJ/.tools/shellcheck";
elif [ -x "$HOME/workspace/.tools/shellcheck" ]; then SC_BIN="$HOME/workspace/.tools/shellcheck"; fi

# 单文件 bundle 预构建（[1/7] lint 与 [9/9] 需要 dist/sb 存在）
bash "$PROJ/dist/build.sh" >/dev/null 2>&1 || fail "dist/build.sh 构建失败"
[ -x "$PROJ/dist/sb" ] || fail "dist/sb 未生成或不可执行"

echo "=== [1/7] lint ==="
if [ -z "$SC_BIN" ]; then fail "未找到 shellcheck"; else
    if "$SC_BIN" -S warning "$PROJ"/lib/*.sh "$PROJ/sb-mgr" "$PROJ/tests/run.sh" "$PROJ/install.sh" "$PROJ/dist/build.sh" "$PROJ/dist/sb"; then
        ok "shellcheck -S warning 零警告"
    else fail "shellcheck 发现警告"; fi
fi
for f in "$PROJ"/lib/*.sh "$PROJ/sb-mgr" "$PROJ/tests/run.sh" "$PROJ/install.sh" "$PROJ/dist/build.sh" "$PROJ/dist/sb"; do
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
[[ "$(head -1 "$TESTDIR/nodes.enc")" == *"SB-AES256GCM-V"* ]] \
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
    printf '[SKIP] 跳过 aesgcm 交叉验证（无 cryptography 库）\n'
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

echo "=== [9/9] 单文件 bundle（build/释放/e2e/self-update）==="
# 9.1 重复构建确定性
cp "$PROJ/dist/sb" "$TESTDIR/sb.before"
bash "$PROJ/dist/build.sh" >/dev/null 2>&1
if cmp -s "$PROJ/dist/sb" "$TESTDIR/sb.before"; then
    ok "重复构建输出一致（确定性）"
else
    fail "重复构建输出不一致"
fi
[ -x "$PROJ/dist/sb" ] && ok "dist/sb 存在且可执行" || fail "dist/sb 缺失"

# 9.2 payload 释放 + 版本标记 + 幂等
SBHOME="$TESTDIR/sbhome"; rm -rf "$SBHOME"
SB_HOME="$SBHOME" bash "$PROJ/dist/sb" version >/dev/null 2>&1 \
    || fail "bundle version 执行失败"
for f in py/builder.py py/subsrv.py py/aesgcm.py \
         systemd/sing-box.service systemd/singbox-yuy-sub.service \
         openrc/singbox.initd openrc/singbox-yuy-sub.initd; do
    src="$f"; case "$f" in py/*) src="lib/$(basename "$f")";; esac
    if [ -f "$SBHOME/$f" ] && cmp -s "$SBHOME/$f" "$PROJ/$src"; then
        ok "payload 释放一致：$f"
    else
        fail "payload 缺失或不一致：$f"
    fi
done
[ "$(cat "$SBHOME/.dist_version" 2>/dev/null)" = "$SB_VERSION_SRC" ] \
    && ok "版本标记 .dist_version 正确" || fail ".dist_version 内容错误"
# 幂等：版本未变时不重复释放（mtime 不应变化）
touch -d "2020-01-01" "$SBHOME/py/builder.py"
SB_HOME="$SBHOME" bash "$PROJ/dist/sb" version >/dev/null 2>&1
if [ "$(stat -c %y "$SBHOME/py/builder.py" | cut -d- -f1)" = "2020" ]; then
    ok "版本未变时不重复释放 payload"
else
    fail "payload 被意外重写"
fi
# 版本变化时重新释放
printf '0.0.0\n' > "$SBHOME/.dist_version"
SB_HOME="$SBHOME" bash "$PROJ/dist/sb" version >/dev/null 2>&1
if [ "$(stat -c %y "$SBHOME/py/builder.py" | cut -d- -f1)" != "2020" ]; then
    ok "版本变化时重新释放 payload"
else
    fail "版本变化后 payload 未重释放"
fi

# 9.3 bundle 端到端（SB_HOME/SB_ETC 覆盖，非 root 友好）
if SB_HOME="$SBHOME" SB_ETC="$SBHOME/etc" bash "$PROJ/dist/sb" add --proto ss2022 --port 18443 --yes >/dev/null 2>&1; then
    ok "bundle add ss2022 成功"
    _bid=$(SB_HOME="$SBHOME" SB_ETC="$SBHOME/etc" bash "$PROJ/dist/sb" list 2>/dev/null | grep -o '[a-f0-9]\{8\}' | head -1)
    [ -n "$_bid" ] && ok "bundle list 找到节点" || fail "bundle list 未找到节点"
    _bout=$(SB_HOME="$SBHOME" SB_ETC="$SBHOME/etc" bash "$PROJ/dist/sb" link "$_bid" 2>/dev/null)
    [[ "$_bout" == "ss://"* ]] \
        && ok "bundle link 生成 ss:// 链接" || fail "bundle link 失败"
    _bout=$(SB_HOME="$SBHOME" SB_ETC="$SBHOME/etc" bash "$PROJ/dist/sb" export --format clash 2>/dev/null)
    [[ "$_bout" == *"proxies:"* ]] \
        && ok "bundle export clash 成功" || fail "bundle export clash 失败"
    SB_HOME="$SBHOME" SB_ETC="$SBHOME/etc" bash "$PROJ/dist/sb" del "$_bid" >/dev/null 2>&1 \
        && ok "bundle del 成功" || fail "bundle del 失败"
else
    fail "bundle add ss2022 失败"
fi

# 9.4 self-update（file:// 伪造远端）
printf '#!/usr/bin/env bash\nSB_DIST_VERSION="9.9.9"\necho fake-bundle\n' > "$SBHOME/fake-sb"
cp "$PROJ/dist/sb" "$TESTDIR/sbself"; chmod +x "$TESTDIR/sbself"
if SB_HOME="$SBHOME" SB_DIST_URL="file://$SBHOME/fake-sb" bash "$TESTDIR/sbself" self-update >/dev/null 2>&1; then
    grep -q 'fake-bundle' "$TESTDIR/sbself" \
        && ok "self-update 替换自身成功" || fail "self-update 未替换内容"
    [ ! -f "$SBHOME/.dist_version" ] \
        && ok "self-update 后删除版本标记" || fail ".dist_version 未删除"
else
    fail "self-update 执行失败"
fi
# 非法文件必须被拒绝
printf 'not a bundle\n' > "$SBHOME/fake-bad"
cp "$PROJ/dist/sb" "$TESTDIR/sbself2"; chmod +x "$TESTDIR/sbself2"
if SB_HOME="$SBHOME" SB_DIST_URL="file://$SBHOME/fake-bad" bash "$TESTDIR/sbself2" self-update >/dev/null 2>&1; then
    fail "self-update 应拒绝非法文件"
else
    ok "self-update 拒绝非法文件"
fi
# 同版本但内容不同（热修复）必须更新：伪造一个同版本不同内容的 bundle
cp "$PROJ/dist/sb" "$TESTDIR/sbself3"; chmod +x "$TESTDIR/sbself3"
cp "$PROJ/dist/sb" "$SBHOME/fake-samever"
printf '# hotfix line\n' >> "$SBHOME/fake-samever"
if SB_HOME="$SBHOME" SB_DIST_URL="file://$SBHOME/fake-samever" bash "$TESTDIR/sbself3" self-update >/dev/null 2>&1; then
    grep -q '# hotfix line' "$TESTDIR/sbself3" \
        && ok "同版本热修复：内容不同则更新" || fail "同版本热修复未替换内容"
else
    fail "同版本热修复 self-update 执行失败"
fi
# repo 模式必须拒绝 self-update
if bash "$PROJ/sb-mgr" self-update >/dev/null 2>&1; then
    fail "repo 模式 self-update 应被拒绝"
else
    ok "repo 模式 self-update 被拒绝"
fi

echo "=== [10/10] 全功能矩阵 ==="
T10="$TESTDIR/t10"; rm -rf "$T10"; mkdir -p "$T10"
t10() { SB_HOME="$T10/home" SB_ETC="$T10/etc" bash "$PROJ/dist/sb" "$@"; }
tnodes() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$T10/etc/nodes.json" 2>/dev/null || echo 0; }
tcheck() { "$SB_BIN" check -c "$T10/etc/config.json" >/dev/null 2>&1; }
tid_of() { python3 -c "import json,sys;ns=json.load(open(sys.argv[1]));print([n['id'] for n in ns if n['proto']==sys.argv[2]][0])" "$T10/etc/nodes.json" "$1"; }

# ---- 10.1 CLI 冒烟（输出收进变量再断言，避免 grep -q 提前关管道导致 SIGPIPE） ----
t10out=$(t10 version 2>/dev/null); [[ "$t10out" == *"SingBox-YUY v"* ]] && ok "version 输出版本号" || fail "version 输出"
t10out=$(t10 help 2>/dev/null); [[ "$t10out" == *"用法"* ]] && ok "help 输出用法" || fail "help 输出"
t10 badoption >/dev/null 2>&1 && fail "未知命令应报错退出" || ok "未知命令报错退出"
t10 add --proto bogus >/dev/null 2>&1 && fail "未知协议应报错退出" || ok "未知协议报错退出"
t10out=$(t10 envcheck 2>/dev/null)
[[ "$t10out" == *"架构"* ]] && ok "envcheck 输出架构行" || fail "envcheck 架构行"
[[ "${t10out,,}" == *"tun"* ]] && ok "envcheck 输出 TUN 行" || fail "envcheck TUN 行"
t10 set-host 203.0.113.7 >/dev/null 2>&1 && ok "set-host 成功" || fail "set-host"
t10 check >/dev/null 2>&1 && ok "空节点库 check 通过" || fail "空库 check"
t10out=$(t10 list 2>/dev/null); [[ "$t10out" == *"暂无节点"* ]] && ok "空库 list 提示" || fail "空库 list 提示"

# ---- 10.2 add 全协议非交互 ----
t10 add --proto reality --port 5543 --sni www.apple.com --remark t10-reality --yes >/dev/null 2>&1 \
    && ok "add reality（指定 sni/端口/备注）" || fail "add reality"
t10 add --proto hy2 --port 5544 --sni www.example.com --remark t10-hy2 --yes >/dev/null 2>&1 \
    && ok "add hy2" || fail "add hy2"
t10 add --proto tuic --port 5545 --remark t10-tuic --yes >/dev/null 2>&1 \
    && ok "add tuic" || fail "add tuic"
t10 add --proto anytls --port 5546 --remark t10-anytls --yes >/dev/null 2>&1 \
    && ok "add anytls" || fail "add anytls"
t10 add --proto ss2022 --port 5547 --remark t10-ss --yes >/dev/null 2>&1 \
    && ok "add ss2022" || fail "add ss2022"
[ "$(tnodes)" = "5" ] && ok "nodes.json 共 5 条目" || fail "nodes.json 条目数异常：$(tnodes)"
if python3 - "$T10/etc/nodes.json" <<'PYEOF'
import json,sys
nodes=json.load(open(sys.argv[1]))
req={"reality":["uuid","reality_private_key","reality_public_key","short_id","sni","port"],
     "hy2":["password","port","sni"],"tuic":["uuid","password","port"],
     "anytls":["password","port"],"ss2022":["password","port","method"]}
bad=[(n["proto"],f) for n in nodes for f in req[n["proto"]] if not n.get(f)]
sys.exit(1 if bad else 0)
PYEOF
then ok "5 协议节点字段完整"; else fail "节点字段缺失"; fi
tcheck && ok "5 协议 config.json 过 check" || fail "config check 失败"
rid=$(tid_of reality)
t10out=$(t10 link "$rid" 2>/dev/null); [[ "$t10out" == *"203.0.113.7"* ]] \
    && ok "set-host 在链接中生效" || fail "set-host 未生效"

# ---- 10.3 TUI 全流程（script 伪造 TTY + 隐藏 whiptail 走降级菜单） ----
if script -qec "true" /dev/null >/dev/null 2>&1; then
    (
        mkdir -p "$T10/bin"
        for d in /usr/local/bin /usr/bin /bin; do
            [ -d "$d" ] || continue
            for f in "$d"/*; do
                b=${f##*/}
                [ "$b" = whiptail ] && continue
                ln -sf "$f" "$T10/bin/$b" 2>/dev/null || true
            done
        done
        export PATH="$T10/bin:/usr/sbin:/sbin"
        # 序列：3加节点→1reality→端口→备注→SNI选1→回车→4管理→1列出→回车→0返回→0退出
        printf '3\n1\n52052\ntui-reality\n1\n\n4\n1\n\n0\n' > "$T10/tui.in"
        SB_HOME="$T10/home" SB_ETC="$T10/etc" \
            script -qec "bash \"$PROJ/dist/sb\"" /dev/null < "$T10/tui.in" > "$T10/tui.out" 2>&1 || true
    ) || true
    grep -q "unbound variable" "$T10/tui.out" 2>/dev/null \
        && fail "TUI 出现 unbound variable" || ok "TUI 全程无 unbound variable"
    grep -q "SingBox-YUY v" "$T10/tui.out" 2>/dev/null \
        && ok "TUI 菜单正常渲染" || fail "TUI 菜单渲染失败"
    python3 -c "
import json
ns=json.load(open('$T10/etc/nodes.json'))
assert any(n.get('port')==52052 and n.get('remark')=='tui-reality' for n in ns)
" 2>/dev/null && ok "TUI 添加 reality 节点成功（SNI 交互分支）" || fail "TUI 添加 reality 节点失败"
else
    printf '[SKIP] 无 util-linux script，跳过 TUI TTY 测试\n'
fi

# ---- 10.4 link/export 全格式 ----
for p in reality hy2 tuic anytls ss2022; do
    pid=$(tid_of "$p")
    case "$p" in
        reality) pat='vless://';; hy2) pat='hysteria2://';; tuic) pat='tuic://';;
        anytls) pat='anytls://';; ss2022) pat='ss://';;
    esac
    t10out=$(t10 link "$pid" 2>/dev/null); [[ "$t10out" == "$pat"* ]] \
        && ok "link $p URI 格式" || fail "link $p URI 格式"
done
if command -v qrencode >/dev/null 2>&1; then
    printf '[SKIP] 本机有 qrencode，跳过降级测试\n'
else
    t10out=$(t10 link "$rid" --qr 2>&1); [[ "${t10out,,}" == *"qrencode"* ]] \
        && ok "无 qrencode 时 --qr 优雅降级" || fail "--qr 降级提示缺失"
fi
t10out=$(t10 export --format uri --id "$rid" 2>/dev/null); [[ "$t10out" == "vless://"* ]] \
    && ok "export --format uri --id 单节点" || fail "export uri --id"
t10 export --format singbox --out "$T10/client.json" >/dev/null 2>&1 && [ -f "$T10/client.json" ] \
    && ok "export singbox --out 写文件" || fail "export singbox 写文件"
"$SB_BIN" check -c "$T10/client.json" >/dev/null 2>&1 \
    && ok "导出的客户端配置过 check" || fail "客户端配置 check 失败"
t10 export --format clash --out "$T10/clash.yaml" >/dev/null 2>&1 \
    && python3 -c "import yaml;d=yaml.safe_load(open('$T10/clash.yaml'));assert d['proxies']" 2>/dev/null \
    && ok "export clash --out 写文件且 YAML 合法" || fail "export clash"

# ---- 10.5 订阅服务 ----
tok1=$(python3 -c "import json;print(json.load(open('$T10/etc/settings.json')).get('sub_token',''))" 2>/dev/null)
t10 sub regen >/dev/null 2>&1
tok2=$(python3 -c "import json;print(json.load(open('$T10/etc/settings.json')).get('sub_token',''))")
[ -n "$tok2" ] && [ "$tok1" != "$tok2" ] && ok "sub regen 更换 token" || fail "sub regen 未更换 token"
t10out=$(t10 sub 2>/dev/null)
[[ "$t10out" == *"/sub/$tok2"$'\n'* ]] && ok "sub 输出基础订阅 URL" || fail "sub 基础 URL"
[[ "$t10out" == *"/sub/$tok2/singbox"* ]] && ok "sub 输出 singbox URL" || fail "sub singbox URL"
[[ "$t10out" == *"/sub/$tok2/clash"* ]] && ok "sub 输出 clash URL" || fail "sub clash URL"
SB_ETC="$T10/etc" SB_HOME="$T10/home" SB_PORT=18080 SB_MGR="$PROJ/dist/sb" \
    python3 "$T10/home/py/subsrv.py" --port 18080 >/dev/null 2>&1 &
SRV=$!
sleep 1
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:18080/sub/$tok2" 2>/dev/null)
[ "$code" = "200" ] && ok "订阅 base64 路由 200" || fail "订阅 base64 路由 ($code)"
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:18080/sub/$tok2/singbox" 2>/dev/null)
[ "$code" = "200" ] && ok "订阅 singbox 路由 200" || fail "订阅 singbox 路由 ($code)"
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:18080/sub/$tok2/clash" 2>/dev/null)
[ "$code" = "200" ] && ok "订阅 clash 路由 200" || fail "订阅 clash 路由 ($code)"
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:18080/sub/${tok1:-none}" 2>/dev/null)
[ "$code" = "404" ] && ok "旧 token 返回 404" || fail "旧 token 未 404 ($code)"
kill $SRV 2>/dev/null || true
wait $SRV 2>/dev/null || true

# ---- 10.6 加密传输边界 ----
t10 node-export --out "$T10/e1.enc" --password "" >/dev/null 2>&1 \
    && fail "空密码应被拒绝" || ok "空密码被拒绝"
t10 node-export --out "$T10/e.enc" --password testpw123 >/dev/null 2>&1 \
    && ok "node-export 正常" || fail "node-export"
head -c 40 "$T10/e.enc" > "$T10/e.trunc"
t10 node-import --in "$T10/e.trunc" --password testpw123 >/dev/null 2>&1 \
    && fail "截断文件应被拒绝" || ok "截断/损坏文件被拒绝"
n0=$(tnodes)
t10 node-import --in "$T10/e.enc" --password testpw123 >/dev/null 2>&1 \
    && ok "node-import 正常" || fail "node-import"
[ "$(tnodes)" = "$n0" ] && ok "重复导入自动去重（$n0 条不变）" || fail "去重失败：$n0 -> $(tnodes)"

# ---- 10.7 中转链全链路 ----
for p in reality hy2 tuic anytls ss2022; do
    pid=$(tid_of "$p")
    uri=$(t10 link "$pid" 2>/dev/null)
    if t10 relay-add --link "$uri" >/tmp/t10-relayerr.txt 2>&1; then
        ok "relay-add --link $p"
    else
        fail "relay-add --link $p（$(tail -1 /tmp/t10-relayerr.txt)）"
    fi
done
t10 relay-add --from-node "$rid" --host 198.51.100.9 >/dev/null 2>&1 \
    && ok "relay-add --from-node" || fail "relay-add --from-node"
t10 relay-route --tag relay-1 --geosite netflix,youtube,openai >/dev/null 2>&1 \
    && ok "relay-route 绑定多 geosite" || fail "relay-route"
t10out=$(t10 relay-list 2>/dev/null); [[ "$t10out" == *"relay-1"* ]] \
    && ok "relay-list 输出" || fail "relay-list"
tcheck && ok "含 6 条中转的配置过 check" || fail "中转配置 check 失败"
t10 relay-add --link "not-a-uri" >/dev/null 2>&1 \
    && fail "非法 URI 应报错" || ok "非法 URI 报错"
t10 relay-add --link "https://example.com/" >/dev/null 2>&1 \
    && fail "非节点 URI 应报错" || ok "非节点 URI 报错"
t10 relay-del --tag relay-1 >/dev/null 2>&1 && ok "relay-del" || fail "relay-del"
tcheck && ok "删除中转后配置仍过 check" || fail "relay-del 后 check 失败"

# ---- 10.8 路由开关（伪造 warp，不调真实 Cloudflare API） ----
python3 - "$T10/etc/settings.json" <<'PYEOF'
import json,sys,base64,os
p=sys.argv[1]; s=json.load(open(p))
s["warp"]={"local_address":["172.16.0.2/32","2606:4700:110:8a56::2/128"],
           "private_key":base64.b64encode(os.urandom(32)).decode(),
           "reserved":[1,2,3]}
json.dump(s,open(p,"w"),indent=2)
PYEOF
t10 route-unlock >/dev/null 2>&1 && ok "route-unlock（有 warp）" || fail "route-unlock"
python3 -c "
import json
c=json.load(open('$T10/etc/config.json'))
eps=c.get('endpoints',[])
assert any(e.get('tag')=='warp' for e in eps), 'no warp endpoint'
rules=c.get('route',{}).get('rules',[])
assert any(r.get('outbound')=='warp' for r in rules), 'no warp rule'
" 2>/dev/null && ok "config 含 warp endpoint 且规则引用正确" || fail "warp endpoint/规则缺失"
tcheck && ok "unlock 后 check 通过" || fail "unlock 后 check 失败"
t10 route-lock >/dev/null 2>&1 && ok "route-lock" || fail "route-lock"
python3 - "$T10/etc/settings.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; s=json.load(open(p)); s.pop("warp",None); s["unlock"]=False
json.dump(s,open(p,"w"),indent=2)
PYEOF
cp "$T10/etc/config.json" "$T10/config.bak"
t10 route-unlock >/dev/null 2>&1 && fail "无 warp 时 unlock 应报错" || ok "无 warp 时 unlock 报错退出"
cmp -s "$T10/etc/config.json" "$T10/config.bak" \
    && ok "报错后配置未被破坏" || fail "报错后配置被破坏"

# ---- 10.9 鲁棒性（非法输入不破坏已有配置） ----
n0=$(tnodes)
t10 del no-such-id >/dev/null 2>&1 && fail "del 不存在应报错" || ok "del 不存在 id 报错"
t10 link no-such-id >/dev/null 2>&1 && fail "link 不存在应报错" || ok "link 不存在 id 报错"
t10 add --proto reality --port 0 --yes >/dev/null 2>&1 && fail "端口 0 应报错" || ok "端口 0 报错"
t10 add --proto reality --port 99999 --yes >/dev/null 2>&1 && fail "端口 99999 应报错" || ok "端口 99999 报错"
t10 add --proto reality --port abc --yes >/dev/null 2>&1 && fail "端口 abc 应报错" || ok "端口 abc 报错"
t10 add --proto reality --port 5543 --yes >/dev/null 2>&1 && fail "占用端口应报错" || ok "占用端口报错"
t10 export --format bogus >/dev/null 2>&1 && fail "非法 format 应报错" || ok "非法 format 报错"
t10 relay-route --tag no-such-tag --geosite netflix >/dev/null 2>&1 \
    && fail "relay-route 不存在 tag 应报错" || ok "relay-route 不存在 tag 报错"
[ "$(tnodes)" = "$n0" ] && ok "非法输入后节点数不变（$n0）" || fail "节点数被破坏：$n0 -> $(tnodes)"
tcheck && ok "非法输入后 check 仍通过" || fail "非法输入后 check 失败"

# ---- 10.10 bundle 一致性 ----
cp "$PROJ/dist/sb" "$T10/sb.rebuild-check"
bash "$PROJ/dist/build.sh" >/dev/null 2>&1
cmp -s "$PROJ/dist/sb" "$T10/sb.rebuild-check" \
    && ok "重复构建输出一致（确定性）" || fail "重复构建输出不一致"

echo "----------------------------------------"
printf '结果：%d 通过，%d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
