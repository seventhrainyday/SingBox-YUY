#!/usr/bin/env python3
# builder.py - SingBox-YUY 配置渲染核心
# 读取 $SB_ETC/nodes.json + settings.json，渲染服务端 config.json。
# 子命令：
#   builder.py            渲染服务端配置 -> $SB_ETC/config.json
#   builder.py client     输出 sing-box 客户端 JSON（stdout）
#   builder.py clash      输出 Mihomo YAML（stdout）
#   builder.py --test --out-dir DIR
#       生成示例：server-full.json（5 协议 + warp + 解锁路由 + 中转示例）、
#                server-basic.json（最小：单 reality）、client.json
#       并打印清单，供 tests/run.sh 逐个 sing-box check。

import json
import os
import sys
import base64
import secrets
import subprocess
import datetime

SB_ETC = os.environ.get("SB_ETC", "/etc/sing-box")
SB_BIN = os.environ.get("SB_BIN", "/usr/local/bin/sing-box")
NODES_JSON = os.path.join(SB_ETC, "nodes.json")
SETTINGS_JSON = os.path.join(SB_ETC, "settings.json")
CONFIG_JSON = os.path.join(SB_ETC, "config.json")

STREAM_GEOSITES = ["netflix", "youtube", "disney", "hbo", "hulu",
                   "primevideo", "spotify", "tiktok"]
AI_GEOSITES = ["openai", "anthropic", "gemini", "copilot"]
ADS_GEOSITE = "category-ads-all"
SRS_URL = ("https://raw.githubusercontent.com/SagerNet/sing-box-geosite"
           "/rule-set/geosite-{name}.srs")


def load_json(path, default):
    if not os.path.exists(path):
        return default
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ")


# ---------------- inbound 渲染 ----------------

def _tls_block(node, sni_key="sni"):
    sni = node.get(sni_key, "")
    tls = {"enabled": True, "server_name": sni}
    if node.get("cert_path"):
        tls["certificate_path"] = node["cert_path"]
        tls["key_path"] = node["key_path"]
    return tls


def build_inbound(node):
    proto = node["proto"]
    tag = node["tag"]
    port = int(node["port"])
    base = {"tag": tag, "listen": "::", "listen_port": port}

    if proto == "reality":
        return dict(base, **{
            "type": "vless",
            "users": [{"uuid": node["uuid"],
                       "flow": node.get("flow", "xtls-rprx-vision")}],
            "tls": {
                "enabled": True,
                "server_name": node["sni"],
                "reality": {
                    "enabled": True,
                    "handshake": {"server": node["sni"],
                                  "server_port": 443},
                    "private_key": node["reality_private_key"],
                    "short_id": [node["short_id"]],
                },
            },
        })
    if proto == "hy2":
        return dict(base, **{
            "type": "hysteria2",
            "users": [{"password": node["password"]}],
            "ignore_client_bandwidth": False,
            "tls": dict(_tls_block(node), alpn=["h3"]),
        })
    if proto == "tuic":
        return dict(base, **{
            "type": "tuic",
            "users": [{"uuid": node["uuid"], "password": node["password"]}],
            "congestion_control": "bbr",
            "zero_rtt_handshake": False,
            "heartbeat": "10s",
            "tls": dict(_tls_block(node), alpn=["h3"]),
        })
    if proto == "anytls":
        return dict(base, **{
            "type": "anytls",
            "users": [{"name": "user", "password": node["password"]}],
            "padding_scheme": [],
            "tls": _tls_block(node),
        })
    if proto == "ss2022":
        return dict(base, **{
            "type": "shadowsocks",
            "method": node.get("method", "2022-blake3-aes-128-gcm"),
            "password": node["password"],
        })
    raise ValueError("未知协议: %s" % proto)


# ---------------- outbound / route ----------------

def build_warp_endpoint(warp):
    # sing-box 1.13 移除了 wireguard 出站，改用顶层 endpoints；
    # 路由规则仍可用 "outbound": "warp" 直接引用 endpoint 的 tag。
    return {
        "type": "wireguard",
        "tag": "warp",
        "mtu": 1280,
        "address": warp["local_address"],
        "private_key": warp["private_key"],
        "peers": [{
            "address": "engage.cloudflareclient.com",
            "port": 2408,
            "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
            "allowed_ips": ["0.0.0.0/0", "::/0"],
            "reserved": warp["reserved"],
        }],
    }


def build_route(settings):
    warp_cfg = settings.get("warp")
    unlock = bool(settings.get("unlock"))
    relays = settings.get("relays") or []

    rules = []
    needed = set()

    # ① 广告拦截 -> block
    rules.append({"rule_set": ["geosite-" + ADS_GEOSITE], "outbound": "block"})
    needed.add(ADS_GEOSITE)

    # ② 流媒体 + AI 解锁 -> warp（无 warp 则 direct）
    if unlock:
        names = STREAM_GEOSITES + AI_GEOSITES
        detour = "warp" if warp_cfg else "direct"
        if not warp_cfg:
            print("WARN: unlock=true 但未配置 warp，解锁规则走 direct",
                  file=sys.stderr)
        rules.append({
            "rule_set": ["geosite-" + n for n in names],
            "outbound": detour,
        })
        needed.update(names)

    # ③ 用户自定义中转规则
    for r in relays:
        gs = r.get("geosites") or []
        if not gs:
            continue
        rules.append({
            "rule_set": ["geosite-" + n for n in gs],
            "outbound": r["tag"],
        })
        needed.update(gs)

    rule_set = [{
        "type": "remote",
        "tag": "geosite-" + n,
        "format": "binary",
        "url": SRS_URL.format(name=n),
        "download_detour": "direct",
    } for n in sorted(needed)]

    return {
        "rules": rules,
        "rule_set": rule_set,
        "final": "direct",
        "auto_detect_interface": True,
    }


def validate(nodes):
    ports = {}
    tags = set()
    for n in nodes:
        p = int(n["port"])
        if p in ports:
            raise ValueError("端口冲突：%d 已被节点 %s 占用" % (p, ports[p]))
        ports[p] = n.get("id", n.get("tag"))
        if n["tag"] in tags:
            raise ValueError("tag 重复：%s" % n["tag"])
        tags.add(n["tag"])


def build_server_config(nodes, settings):
    validate(nodes)
    outbounds = [
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"},
        # 注：type=dns 的 outbound 在 sing-box 1.13 已移除，故不再渲染；
        # DNS 功能由顶层 "dns" 段承担。
    ]
    endpoints = []
    if settings.get("warp"):
        # wireguard 出站在 1.13 已移除，改用 wireguard endpoint
        endpoints.append(build_warp_endpoint(settings["warp"]))
    for r in settings.get("relays") or []:
        ob = dict(r["outbound"])
        ob["tag"] = r["tag"]
        outbounds.append(ob)

    cfg = {
        "log": {"level": "info", "timestamp": True},
        "dns": {
            "servers": [
                {"type": "udp", "tag": "dns-direct",
                 "server": "223.5.5.5", "detour": "direct"}
            ],
            "final": "dns-direct",
            "strategy": "prefer_ipv4",
        },
        "inbounds": [build_inbound(n) for n in nodes],
        "outbounds": outbounds,
        "route": build_route(settings),
    }
    if endpoints:
        cfg["endpoints"] = endpoints
    return cfg


# ---------------- 客户端配置（sing-box / clash） ----------------

def _client_outbound(node, host):
    tag = node.get("remark") or node["tag"]
    proto = node["proto"]
    if proto == "reality":
        return {
            "type": "vless", "tag": tag,
            "server": host, "server_port": int(node["port"]),
            "uuid": node["uuid"], "flow": "xtls-rprx-vision",
            "packet_encoding": "xudp",
            "tls": {
                "enabled": True, "server_name": node["sni"],
                "utls": {"enabled": True, "fingerprint": "chrome"},
                "reality": {"enabled": True,
                            "public_key": node["reality_public_key"],
                            "short_id": node["short_id"]},
            },
        }
    if proto == "hy2":
        insecure = node.get("cert_type", "self") != "acme"
        return {
            "type": "hysteria2", "tag": tag,
            "server": host, "server_port": int(node["port"]),
            "password": node["password"],
            "tls": {"enabled": True, "server_name": node["sni"],
                    "insecure": insecure, "alpn": ["h3"]},
        }
    if proto == "tuic":
        insecure = node.get("cert_type", "self") != "acme"
        return {
            "type": "tuic", "tag": tag,
            "server": host, "server_port": int(node["port"]),
            "uuid": node["uuid"], "password": node["password"],
            "congestion_control": "bbr",
            "tls": {"enabled": True, "server_name": node["sni"],
                    "insecure": insecure, "alpn": ["h3"]},
        }
    if proto == "anytls":
        return {
            "type": "anytls", "tag": tag,
            "server": host, "server_port": int(node["port"]),
            "password": node["password"],
            "tls": {"enabled": True, "server_name": node["sni"],
                    "insecure": True},
        }
    if proto == "ss2022":
        return {
            "type": "shadowsocks", "tag": tag,
            "server": host, "server_port": int(node["port"]),
            "method": node.get("method", "2022-blake3-aes-128-gcm"),
            "password": node["password"],
        }
    raise ValueError("未知协议: %s" % proto)


def build_client_config(nodes, settings, host):
    proxies = [_client_outbound(n, host) for n in nodes]
    names = [p["tag"] for p in proxies]
    if names:
        tail_outbounds = [
            {"type": "selector", "tag": "PROXY", "outbounds": names,
             "default": names[0]},
            {"type": "urltest", "tag": "AUTO", "outbounds": names,
             "url": "https://www.gstatic.com/generate_204",
             "interval": "10m"},
            {"type": "direct", "tag": "direct"},
        ]
        final = "PROXY"
    else:
        tail_outbounds = [{"type": "direct", "tag": "direct"}]
        final = "direct"
    return {
        "log": {"level": "info"},
        "dns": {"servers": [{"type": "tls", "tag": "google",
                             "server": "8.8.8.8"}],
                "final": "google"},
        "inbounds": [
            {"type": "mixed", "tag": "mixed-in",
             "listen": "127.0.0.1", "listen_port": 10808},
            {"type": "socks", "tag": "socks-in",
             "listen": "127.0.0.1", "listen_port": 10809},
        ],
        "outbounds": proxies + tail_outbounds,
        "route": {"final": final, "auto_detect_interface": True},
    }


def _yaml_str(s):
    s = str(s)
    if s == "" or any(c in s for c in ":#{}[],&*!|>'\"%@`") \
            or s != s.strip() or s.lower() in ("true", "false", "null"):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def _yaml_dump(obj, indent=0):
    # 极简 YAML emitter（无第三方依赖），仅用于 clash 导出
    pad = "  " * indent
    lines = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, (dict, list)):
                lines.append("%s%s:" % (pad, _yaml_str(k)))
                lines.extend(_yaml_dump(v, indent + 1))
            else:
                lines.append("%s%s: %s" % (pad, _yaml_str(k),
                                           _yaml_scalar(v)))
    elif isinstance(obj, list):
        for v in obj:
            if isinstance(v, (dict, list)):
                lines.append("%s-" % pad)
                lines.extend(_yaml_dump(v, indent + 1))
            else:
                lines.append("%s- %s" % (pad, _yaml_scalar(v)))
    return lines


def _yaml_scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return str(v)
    return _yaml_str(v)


def build_clash_config(nodes, settings, host):
    proxies = []
    for n in nodes:
        name = n.get("remark") or n["tag"]
        p = int(n["port"])
        proto = n["proto"]
        if proto == "reality":
            proxies.append({
                "name": name, "type": "vless", "server": host, "port": p,
                "uuid": n["uuid"], "network": "tcp", "tls": True,
                "udp": True, "flow": "xtls-rprx-vision",
                "servername": n["sni"], "client-fingerprint": "chrome",
                "reality-opts": {"public-key": n["reality_public_key"],
                                 "short-id": n["short_id"]},
            })
        elif proto == "hy2":
            proxies.append({
                "name": name, "type": "hysteria2", "server": host,
                "port": p, "password": n["password"], "sni": n["sni"],
                "alpn": ["h3"],
                "skip-cert-verify": n.get("cert_type", "self") != "acme",
            })
        elif proto == "tuic":
            proxies.append({
                "name": name, "type": "tuic", "server": host, "port": p,
                "uuid": n["uuid"], "password": n["password"],
                "congestion-controller": "bbr",
                "udp-relay-mode": "native", "reduce-rtt": False,
                "sni": n["sni"], "alpn": ["h3"],
                "skip-cert-verify": n.get("cert_type", "self") != "acme",
            })
        elif proto == "anytls":
            # Mihomo 对 anytls 支持因版本而异；按通用字段输出
            proxies.append({
                "name": name, "type": "anytls", "server": host, "port": p,
                "password": n["password"], "sni": n["sni"],
                "skip-cert-verify": True, "udp": True,
            })
        elif proto == "ss2022":
            proxies.append({
                "name": name, "type": "ss", "server": host, "port": p,
                "cipher": n.get("method", "2022-blake3-aes-128-gcm"),
                "password": n["password"], "udp": True,
            })
    names = [x["name"] for x in proxies]
    cfg = {
        "mixed-port": 7890,
        "allow-lan": False,
        "mode": "rule",
        "log-level": "info",
        "proxies": proxies,
        "proxy-groups": [
            {"name": "PROXY", "type": "select",
             "proxies": ["AUTO"] + names},
            {"name": "AUTO", "type": "url-test", "proxies": names,
             "url": "https://www.gstatic.com/generate_204",
             "interval": 600},
        ],
        "rules": [
            "GEOSITE,category-ads-all,REJECT",
            "GEOSITE,cn,DIRECT",
            "GEOIP,cn,DIRECT",
            "MATCH,PROXY",
        ],
    }
    return "\n".join(_yaml_dump(cfg)) + "\n"


def resolve_host(settings):
    h = (settings.get("host") or "").strip()
    if h:
        return h
    return "127.0.0.1"


# ---------------- 链接解析（供 relay-add 使用） ----------------

def parse_link(link):
    from urllib.parse import urlparse, parse_qs, unquote
    u = urlparse(link.strip())
    scheme = u.scheme.lower()
    q = {k: v[0] for k, v in parse_qs(u.query).items()}
    remark = unquote(u.fragment or "")

    if scheme == "vless":
        ob = {
            "type": "vless",
            "server": u.hostname, "server_port": u.port or 443,
            "uuid": unquote(u.username or ""),
            "packet_encoding": "xudp",
        }
        if q.get("flow"):
            ob["flow"] = q["flow"]
        sec = q.get("security", "")
        if sec == "reality":
            ob["tls"] = {
                "enabled": True, "server_name": q.get("sni", ""),
                "utls": {"enabled": True,
                         "fingerprint": q.get("fp", "chrome")},
                "reality": {"enabled": True,
                            "public_key": q.get("pbk", ""),
                            "short_id": q.get("sid", "")},
            }
        elif sec == "tls":
            ob["tls"] = {"enabled": True, "server_name": q.get("sni", ""),
                         "utls": {"enabled": True,
                                  "fingerprint": q.get("fp", "chrome")}}
        return ob
    if scheme == "trojan":
        insecure = q.get("allowInsecure", "0") in ("1", "true")
        return {
            "type": "trojan",
            "server": u.hostname, "server_port": u.port or 443,
            "password": unquote(u.username or ""),
            "tls": {"enabled": True, "server_name": q.get("sni", u.hostname),
                    "insecure": insecure},
        }
    if scheme == "ss":
        userinfo = u.username or ""
        # ss://BASE64(method:password)@host:port 或 ss://base64(method:password@host:port)
        try:
            pad = "=" * (-len(userinfo) % 4)
            decoded = base64.urlsafe_b64decode(userinfo + pad).decode()
        except Exception:
            decoded = ""
        if "@" in decoded and ":" in decoded.split("@")[0]:
            method, rest = decoded.split(":", 1)
            password, hostport = rest.rsplit("@", 1)
            host, port = hostport.rsplit(":", 1)
        else:
            if ":" not in decoded:
                raise ValueError("无法解析 ss 链接")
            method, password = decoded.split(":", 1)
            host, port = u.hostname, u.port
        return {"type": "shadowsocks", "server": host,
                "server_port": int(port or 8388),
                "method": method, "password": password}
    if scheme == "hysteria2":
        insecure = q.get("insecure", "0") in ("1", "true")
        return {
            "type": "hysteria2",
            "server": u.hostname, "server_port": u.port or 443,
            "password": unquote(u.username or ""),
            "tls": {"enabled": True,
                    "server_name": q.get("sni", u.hostname),
                    "insecure": insecure},
        }
    if scheme == "tuic":
        insecure = q.get("allow_insecure", "0") in ("1", "true")
        alpn = [a for a in q.get("alpn", "h3").split(",") if a]
        return {
            "type": "tuic",
            "server": u.hostname, "server_port": u.port or 443,
            "uuid": unquote(u.username or ""),
            "password": unquote(u.password or ""),
            "congestion_control": q.get("congestion_control", "bbr"),
            "udp_relay_mode": q.get("udp_relay_mode", "native"),
            "zero_rtt_handshake": False,
            "tls": {"enabled": True,
                    "server_name": q.get("sni", u.hostname),
                    "insecure": insecure,
                    "alpn": alpn or ["h3"]},
        }
    if scheme == "anytls":
        insecure = q.get("insecure", "0") in ("1", "true")
        return {
            "type": "anytls",
            "server": u.hostname, "server_port": u.port or 443,
            "password": unquote(u.username or ""),
            "tls": {"enabled": True,
                    "server_name": q.get("sni", u.hostname),
                    "insecure": insecure},
        }
    raise ValueError("不支持的链接协议：%s（仅支持 vless/trojan/ss/hysteria2/tuic/anytls）" % scheme)


# ---------------- --test 模式 ----------------

def _gen_reality_keypair():
    if os.path.exists(SB_BIN) and os.access(SB_BIN, os.X_OK):
        try:
            out = subprocess.run(
                [SB_BIN, "generate", "reality-keypair"],
                capture_output=True, text=True, timeout=15)
            priv = pub = ""
            for line in out.stdout.splitlines():
                if "Private" in line:
                    priv = line.split()[-1]
                elif "Public" in line:
                    pub = line.split()[-1]
            if priv and pub:
                return priv, pub
        except Exception:
            pass
    raw = secrets.token_bytes(32)
    b64 = base64.urlsafe_b64encode(raw).rstrip(b"=").decode()
    return b64, b64  # 仅用于 check 语法校验的占位


def _gen_uuid():
    if os.path.exists(SB_BIN) and os.access(SB_BIN, os.X_OK):
        try:
            out = subprocess.run([SB_BIN, "generate", "uuid"],
                                 capture_output=True, text=True, timeout=15)
            u = out.stdout.strip()
            if u:
                return u
        except Exception:
            pass
    import uuid as _uuid
    return str(_uuid.uuid4())


def sample_nodes():
    priv, pub = _gen_reality_keypair()
    u1, u2 = _gen_uuid(), _gen_uuid()
    ts = utcnow()
    return [
        {"id": "aa01", "proto": "reality", "tag": "reality-443",
         "port": 443, "uuid": u1, "flow": "xtls-rprx-vision",
         "sni": "www.sony.com", "reality_private_key": priv,
         "reality_public_key": pub, "short_id": "a1b2c3d4",
         "remark": "测试-reality", "created": ts},
        {"id": "aa02", "proto": "hy2", "tag": "hy2-8443", "port": 8443,
         "password": "testpassword1234", "sni": "test.example.com",
         "cert_type": "self", "cert_path": "/tmp/sb-mgr-test/cert.pem",
         "key_path": "/tmp/sb-mgr-test/key.pem",
         "remark": "测试-hy2", "created": ts},
        {"id": "aa03", "proto": "tuic", "tag": "tuic-9443", "port": 9443,
         "uuid": u2, "password": "tuicpw12345678", "sni": "test.example.com",
         "cert_type": "self", "cert_path": "/tmp/sb-mgr-test/cert.pem",
         "key_path": "/tmp/sb-mgr-test/key.pem",
         "remark": "测试-tuic", "created": ts},
        {"id": "aa04", "proto": "anytls", "tag": "anytls-8843", "port": 8843,
         "password": "anytlspw123456", "sni": "www.microsoft.com",
         "cert_type": "self", "cert_path": "/tmp/sb-mgr-test/cert.pem",
         "key_path": "/tmp/sb-mgr-test/key.pem",
         "remark": "测试-anytls", "created": ts},
        {"id": "aa05", "proto": "ss2022", "tag": "ss-8388", "port": 8388,
         "method": "2022-blake3-aes-128-gcm",
         "password": base64.b64encode(b"0123456789abcdef").decode(),
         "remark": "测试-ss2022", "created": ts},
    ]


def sample_settings():
    raw = secrets.token_bytes(32)
    return {
        "host": "203.0.113.10",
        "sub_port": 2096,
        "sub_token": "testtoken123",
        "unlock": True,
        "warp": {
            "private_key": base64.b64encode(raw).decode(),
            "local_address": ["172.16.0.2/32", "2606:4700:110:8a56::2/128"],
            "reserved": [1, 2, 3],
        },
        "relays": [{
            "tag": "relay-1",
            "outbound": {
                "type": "vless", "server": "198.51.100.7",
                "server_port": 443, "uuid": _gen_uuid(),
                "flow": "xtls-rprx-vision",
                "tls": {
                    "enabled": True, "server_name": "www.sony.com",
                    "utls": {"enabled": True, "fingerprint": "chrome"},
                    "reality": {"enabled": True,
                                "public_key": _gen_reality_keypair()[1],
                                "short_id": "0102030405060708"},
                },
            },
            "geosites": ["netflix", "openai"],
        }],
    }


def run_test(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    nodes = sample_nodes()
    settings = sample_settings()
    manifest = []

    full = build_server_config(nodes, settings)
    p1 = os.path.join(out_dir, "server-full.json")
    save_json(p1, full)
    manifest.append(("server-full（5 协议 + warp + 解锁 + 中转）", p1))

    basic = build_server_config([nodes[0]],
                                {"host": "203.0.113.10", "unlock": False,
                                 "relays": []})
    p2 = os.path.join(out_dir, "server-basic.json")
    save_json(p2, basic)
    manifest.append(("server-basic（单 reality，无 warp）", p2))

    client = build_client_config(nodes, settings, "203.0.113.10")
    p3 = os.path.join(out_dir, "client.json")
    save_json(p3, client)
    manifest.append(("client（sing-box 客户端，5 节点 + selector/urltest）", p3))

    p4 = os.path.join(out_dir, "client.clash.yaml")
    with open(p4, "w", encoding="utf-8") as f:
        f.write(build_clash_config(nodes, settings, "203.0.113.10"))
    manifest.append(("clash（Mihomo YAML，5 proxies）", p4))

    print("=== builder.py --test 清单 ===")
    for desc, path in manifest:
        print("  %-48s %s" % (desc, path))
    return manifest


def main(argv):
    if "--test" in argv:
        out_dir = "/tmp/sb-mgr-test"
        for i, a in enumerate(argv):
            if a == "--out-dir" and i + 1 < len(argv):
                out_dir = argv[i + 1]
        run_test(out_dir)
        return 0

    nodes = load_json(NODES_JSON, [])
    settings = load_json(SETTINGS_JSON, {})

    if len(argv) >= 2 and argv[1] == "client":
        host = resolve_host(settings)
        print(json.dumps(build_client_config(nodes, settings, host),
                         indent=2, ensure_ascii=False))
        return 0
    if len(argv) >= 2 and argv[1] == "clash":
        host = resolve_host(settings)
        sys.stdout.write(build_clash_config(nodes, settings, host))
        return 0
    if len(argv) >= 2 and argv[1] == "node-outbound":
        # node-outbound <id> [host] -> 该节点的客户端 outbound JSON（供 relay 使用）
        if len(argv) < 3:
            print("用法：builder.py node-outbound <id> [host]",
                  file=sys.stderr)
            return 2
        host = argv[3] if len(argv) > 3 else resolve_host(settings)
        node = next((n for n in nodes if n.get("id") == argv[2]), None)
        if node is None:
            print("未找到节点：%s" % argv[2], file=sys.stderr)
            return 2
        print(json.dumps(_client_outbound(node, host),
                         indent=2, ensure_ascii=False))
        return 0
    if len(argv) >= 2 and argv[1] == "parse-link":
        # parse-link <uri> -> outbound JSON（无 tag）
        if len(argv) < 3:
            print("用法：builder.py parse-link <uri>", file=sys.stderr)
            return 2
        print(json.dumps(parse_link(argv[2]), indent=2, ensure_ascii=False))
        return 0

    cfg = build_server_config(nodes, settings)
    save_json(CONFIG_JSON, cfg)
    print("已渲染：%s（inbounds=%d, outbounds=%d）"
          % (CONFIG_JSON, len(cfg["inbounds"]), len(cfg["outbounds"])))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (ValueError, KeyError, OSError) as e:
        print("builder 错误：%s" % e, file=sys.stderr)
        sys.exit(1)
