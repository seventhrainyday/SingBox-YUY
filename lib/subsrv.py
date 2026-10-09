#!/usr/bin/env python3
# subsrv.py - 轻量订阅 HTTP 服务（仅标准库）
# 路由：
#   /sub/<token>          -> base64(URI 列表，换行拼接)
#   /sub/<token>/singbox  -> sing-box 客户端 JSON
#   /sub/<token>/clash    -> Mihomo YAML
# token 不匹配 -> 404。
# 配置来源：环境变量 SB_TOKEN / SB_PORT，缺省读 $SB_ETC/settings.json。
# 内容通过调用管理命令 export 生成（解析顺序：SB_MGR 环境变量 -> 源码旁 ../sb-mgr -> PATH 中的 sb -> /usr/local/bin/sb）。

import base64
import hmac
import json
import os
import shutil
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

SB_ETC = os.environ.get("SB_ETC", "/etc/sing-box")
SETTINGS_JSON = os.path.join(SB_ETC, "settings.json")
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MGR = os.path.abspath(os.path.join(HERE, "..", "sb-mgr"))


def load_settings():
    try:
        with open(SETTINGS_JSON, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def get_token():
    tok = os.environ.get("SB_TOKEN", "").strip()
    if tok:
        return tok
    return (load_settings().get("sub_token") or "").strip()


def get_port():
    p = os.environ.get("SB_PORT", "").strip()
    if p.isdigit():
        return int(p)
    s = load_settings()
    try:
        return int(s.get("sub_port", 2096))
    except (TypeError, ValueError):
        return 2096


def mgr_path():
    # 解析顺序：SB_MGR 环境变量 -> 源码旁 ../sb-mgr（存在才用）
    #           -> PATH 中的 sb -> /usr/local/bin/sb（单文件版默认安装位）
    m = os.environ.get("SB_MGR", "").strip()
    if m and os.path.exists(m):
        return m
    if os.path.exists(DEFAULT_MGR):
        return DEFAULT_MGR
    v = shutil.which("sb")
    if v:
        return v
    return "/usr/local/bin/sb"


def export_content(fmt):
    # fmt: uri | singbox | clash
    mgr = mgr_path()
    env = dict(os.environ)
    try:
        out = subprocess.run(
            [mgr, "export", "--format", fmt],
            capture_output=True, text=True, timeout=30, env=env)
    except (OSError, subprocess.SubprocessError) as e:
        return 500, "text/plain", "export 调用失败: %s" % e
    if out.returncode != 0:
        return 500, "text/plain", "export 失败: %s" % out.stderr.strip()[:200]
    ctype = {"uri": "text/plain",
             "singbox": "application/json",
             "clash": "text/yaml"}.get(fmt, "text/plain")
    body = out.stdout
    if fmt == "uri":
        body = base64.b64encode(
            body.encode("utf-8")).decode("ascii")
    return 200, ctype, body


class Handler(BaseHTTPRequestHandler):
    server_version = "SingBox-YUY-Sub/0.3.1"

    def log_message(self, *args):
        sys.stderr.write("[subsrv] %s %s\n" % (self.command, self.path))

    def _send(self, code, ctype, body):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        token = get_token()
        path = unquote(self.path.split("?", 1)[0])
        parts = [p for p in path.split("/") if p]
        # 期望：["sub", "<token>"] 或 ["sub", "<token>", "singbox"|"clash"]
        if len(parts) < 2 or parts[0] != "sub" or not token \
                or not hmac.compare_digest(parts[1], token):
            self._send(404, "text/plain", "not found")
            return
        fmt = "uri"
        if len(parts) == 3:
            if parts[2] == "singbox":
                fmt = "singbox"
            elif parts[2] == "clash":
                fmt = "clash"
            else:
                self._send(404, "text/plain", "not found")
                return
        elif len(parts) > 3:
            self._send(404, "text/plain", "not found")
            return
        code, ctype, body = export_content(fmt)
        self._send(code, ctype, body)


def run_server(port):
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print("订阅服务监听端口：%d" % srv.server_address[1], flush=True)
    srv.serve_forever()


# ---------------- --test 冒烟测试 ----------------

def run_smoke():
    """自包含冒烟测试：起临时端口，校验 3 路由 200 + 错误 token 404。"""
    import threading
    import urllib.request
    import urllib.error

    token = get_token()
    if not token:
        print("SMOKE FAIL: 未配置 token（settings.json sub_token 或 SB_TOKEN）")
        return 1
    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()

    def get(path):
        url = "http://127.0.0.1:%d%s" % (port, path)
        try:
            with urllib.request.urlopen(url, timeout=15) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")[:100]

    fails = 0

    def check(name, cond, detail=""):
        nonlocal fails
        print(("SMOKE PASS: " if cond else "SMOKE FAIL: ") + name
              + (" (%s)" % detail if detail and not cond else ""))
        if not cond:
            fails += 1

    code, body = get("/sub/%s" % token)
    ok = code == 200
    if ok:
        try:
            raw = base64.b64decode(body).decode("utf-8")
            ok = "://" in raw
        except Exception:
            ok = False
    check("GET /sub/<token> -> base64 URI 列表", ok, "code=%s" % code)

    code, body = get("/sub/%s/singbox" % token)
    ok = code == 200
    if ok:
        try:
            ok = isinstance(json.loads(body).get("outbounds"), list)
        except Exception:
            ok = False
    check("GET /sub/<token>/singbox -> 客户端 JSON", ok, "code=%s" % code)

    code, body = get("/sub/%s/clash" % token)
    check("GET /sub/<token>/clash -> Mihomo YAML",
          code == 200 and "proxies:" in body, "code=%s" % code)

    code, _ = get("/sub/WRONGTOKEN")
    check("GET /sub/<错误token> -> 404", code == 404, "code=%s" % code)

    code, _ = get("/sub/%s/nope" % token)
    check("GET 未知子路径 -> 404", code == 404, "code=%s" % code)

    srv.shutdown()
    print("冒烟测试：%s" % ("全部通过" if fails == 0 else "%d 项失败" % fails))
    return 1 if fails else 0


def main(argv):
    if "--test" in argv:
        return run_smoke()
    port = get_port()
    if "--port" in argv:
        i = argv.index("--port")
        port = int(argv[i + 1])
    if not get_token():
        print("未配置订阅 token：先 sb-mgr sub regen 生成", file=sys.stderr)
        return 2
    run_server(port)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
