#!/usr/bin/env python3
"""
wifi.py - 手机 postmarketOS 上的简易 WiFi 管理 Web 界面

用法：
    sudo python3 wifi.py [端口]          # 默认 8090
然后在浏览器打开：
    http://<手机IP>:8090/?t=<令牌>

功能：扫描并展示 WiFi + 信号强度，鼠标点击选择，填密码连接，
连接成功后 save_config 存入手机（重启保留）。

原理：调用 sudo wpa_cli 操作 wlan0 的控制 socket（属 root，故本脚本需 root 运行）。
仅用 Python 标准库，无需 pip 安装任何东西。
"""

import os
import re
import sys
import html
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# ---------------- 配置 ----------------
IFACE = "wlan0"
WPA_CONF = "/etc/wpa_supplicant/wpa-auto.conf"
DEFAULT_PORT = 8090
# 访问令牌：留空则关闭校验（不建议，局域网任何人都能改 WiFi）。
# 也可用环境变量 WIFI_UI_TOKEN 覆盖。
TOKEN = os.environ.get("WIFI_UI_TOKEN", "note5a-wifi")

# 连接结果状态（供页面轮询）
_result = {"running": False, "ssid": "", "ok": None, "msg": "", "ts": 0}


def run(cmd, timeout=12):
    """执行命令，返回 (returncode, stdout+stderr)。"""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True)
        return p.returncode, p.stdout.strip()
    except subprocess.TimeoutExpired:
        return -1, "timeout"
    except FileNotFoundError:
        return -1, "command not found"


def wpa(args, timeout=12):
    """调用 wpa_cli（本脚本已是 root，无需再 sudo）。"""
    return run(["wpa_cli", "-i", IFACE] + list(args), timeout)


def scan():
    """触发扫描并解析结果，返回按信号强度排序的 [(ssid, signal, flags), ...]。"""
    wpa(["scan"], timeout=6)
    time.sleep(2.5)
    rc, out = wpa(["scan_results"], timeout=8)
    aps = {}
    for line in out.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        bssid, freq, sig, flags, ssid = parts[0], parts[1], parts[2], parts[3], parts[4]
        if not ssid:
            continue
        # 过滤隐藏/乱码 SSID：去掉控制字符与 NUL，若清洗后为空则跳过
        ssid = "".join(ch for ch in ssid if ch.isprintable()).strip()
        if not ssid:
            continue
        try:
            sig = int(sig)
        except ValueError:
            continue
        # 同一 SSID 取信号最强的那个 BSSID
        if ssid not in aps or sig > aps[ssid][1]:
            aps[ssid] = (ssid, sig, flags)
    return sorted(aps.values(), key=lambda x: -x[1])


def saved_ssids():
    """读取已保存的网络名与当前连接。"""
    rc, out = wpa(["list_networks"])
    saved, current = [], ""
    for line in out.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        saved.append(parts[1])
        if len(parts) >= 4 and "CURRENT" in parts[3]:
            current = parts[1]
    return saved, current


def signal_bars(sig):
    """把 dBm 转成 4 格信号条文字。"""
    if sig >= -50:
        n = 4
    elif sig >= -60:
        n = 3
    elif sig >= -70:
        n = 2
    else:
        n = 1
    return "▮" * n + "▯" * (4 - n)


def sec_type(flags):
    if "WPA3" in flags or "SAE" in flags:
        return "WPA3"
    if "WPA2" in flags or "WPA-PSK" in flags:
        return "WPA2"
    if "WEP" in flags:
        return "WEP"
    return "开放"


def connect_worker(ssid, password):
    """后台连接线程：避免连接过程断网导致 HTTP 请求挂死。"""
    global _result
    _result = {"running": True, "ssid": ssid, "ok": None, "msg": "连接中…", "ts": time.time()}
    try:
        # 1) 若该 SSID 已存在则复用其 id（避免 select_network 产生 disabled 重复条目），
        #    仅当完全没有时才 add_network。
        rc, lst = wpa(["list_networks"])
        nid = None
        for line in lst.splitlines()[1:]:
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1] == ssid:
                nid = parts[0]
                break
        was_new = nid is None
        if was_new:
            rc, out = wpa(["add_network"])
            m = re.search(r"(\d+)", out)
            if not m:
                raise RuntimeError("add_network 失败: " + out)
            nid = m.group(1)

        # 2) 设置 SSID（wpa_cli 要求值外层再包单引号）
        wpa(["set_network", nid, "ssid", '"%s"' % ssid])

        # 3) 设置密码：开放网络设 key_mgmt NONE，否则 WPA-PSK + psk
        if sec_type_from_ssid(ssid) == "开放" or not password:
            wpa(["set_network", nid, "key_mgmt", "NONE"])
        else:
            wpa(["set_network", nid, "key_mgmt", "WPA-PSK"])
            wpa(["set_network", nid, "psk", '"%s"' % password])

        # 4) 启用并切换（复用旧 id 时不会新增禁用条目）
        wpa(["enable_network", nid])
        wpa(["select_network", nid])

        # 5) 等待关联结果
        ok = False
        for _ in range(20):
            time.sleep(1)
            rc, st = wpa(["status"])
            state = ""
            cur_ssid = ""
            for line in st.splitlines():
                if line.startswith("wpa_state="):
                    state = line.split("=", 1)[1]
                elif line.startswith("ssid="):
                    cur_ssid = line.split("=", 1)[1]
            if state == "COMPLETED" and cur_ssid == ssid:
                ok = True
                break
            if state == "INVALID_PASSWORD" or "AUTHENTICATING" in state and _ > 12:
                break

        if ok:
            # 6) 重新拿 IP
            run(["killall", "udhcpc"])
            time.sleep(1)
            run(["udhcpc", "-i", IFACE, "-n"], timeout=15)
            # 7) 持久化到手机：写回 wpa-auto.conf
            rc, save_out = wpa(["save_config"])
            ip = ""
            rc2, addr = run(["ip", "-4", "addr", "show", IFACE])
            mip = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", addr)
            if mip:
                ip = mip.group(1)
            _result.update(ok=True, msg="连接成功并已保存到手机" + ("，IP " + ip if ip else ""))
        else:
            # 连接失败：若是本次新建的网络则删除，避免污染配置；
            # 若是复用的已存网络则保留（拔线测试可重来）。
            if was_new:
                wpa(["remove_network", nid])
                _result.update(ok=False, msg="连接失败：密码错误或信号太弱，已清除该网络")
            else:
                _result.update(ok=False, msg="连接失败：密码错误或信号太弱，原配置已保留，可重试")
    except Exception as e:
        _result.update(ok=False, msg="异常: %s" % e)
    finally:
        _result["running"] = False


# 缓存 SSID->加密类型，供连接线程判断开放网络
_ssid_sec = {}
def sec_type_from_ssid(ssid):
    return _ssid_sec.get(ssid, "")


PAGE = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>手机 WiFi 管理</title>
<style>
  body{font-family:system-ui,-apple-system,"Microsoft YaHei",sans-serif;background:#0f1115;color:#e6e6e6;margin:0;padding:24px;max-width:760px;margin:auto}
  h1{font-size:22px;margin:0 0 4px} .sub{color:#888;font-size:13px;margin-bottom:20px}
  .card{background:#1a1d24;border:1px solid #2a2e38;border-radius:10px;padding:14px;margin-bottom:10px;display:flex;align-items:center;gap:12px}
  .sig{font-size:16px;color:#4ade80;letter-spacing:1px;min-width:70px}
  .info{flex:1;min-width:0} .ssid{font-size:16px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .meta{font-size:12px;color:#888;margin-top:3px}
  .tag{font-size:11px;padding:2px 7px;border-radius:10px;margin-left:6px}
  .tag-saved{background:#1e3a2f;color:#4ade80} .tag-cur{background:#1e3a5f;color:#60a5fa}
  button{background:#2563eb;color:#fff;border:0;border-radius:7px;padding:8px 16px;font-size:14px;cursor:pointer}
  button:hover{background:#1d4ed8} button.conn{background:#16a34a} button.conn:hover{background:#15803d}
  input[type=password],input[type=text]{background:#0f1115;border:1px solid #3a3f4b;color:#e6e6e6;border-radius:7px;padding:9px 12px;font-size:14px;width:220px;outline:none}
  input:focus{border-color:#2563eb}
  .form{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
  .msg{padding:12px 16px;border-radius:8px;margin-bottom:16px;font-size:14px}
  .ok{background:#14532d;color:#86efac} .bad{background:#451a1a;color:#fca5a5} .wait{background:#1e293b;color:#93c5fd}
  code{background:#0f1115;padding:2px 6px;border-radius:4px;color:#93c5fd}
</style></head><body>
<h1>📶 手机 WiFi 管理</h1>
<div class="sub">Redmi Note 5A / postmarketOS · 点击「连接」选择网络 · 成功后自动保存到手机</div>
__MSG__
__LIST__
<div class="sub" style="margin-top:24px">刷新页面可重新扫描。连接过程约需 10 秒，若换网导致本页断开，重连后再刷新即可。</div>
</body></html>"""


def render(msg_html=""):
    aps = scan()
    saved, current = saved_ssids()
    global _ssid_sec
    _ssid_sec = {s: sec_type(f) for s, _, f in aps}

    rows = []
    for ssid, sig, flags in aps:
        enc = sec_type(flags)
        tags = ""
        if ssid == current:
            tags += '<span class="tag tag-cur">已连接</span>'
        if ssid in saved:
            tags += '<span class="tag tag-saved">已保存</span>'
        # 每个卡片带一个表单：输入密码 + 连接按钮（开放网络隐藏密码框）
        need_pwd = "" if enc == "开放" else (
            '<input type="password" name="password" placeholder="密码" required>')
        action = "/connect?t=" + html.escape(TOKEN, quote=True) + "&ssid=" + html.escape(ssid, quote=True)
        s = html.escape(ssid, quote=True)
        rows.append(
            '<div class="card">'
            '<div class="sig" title="%d dBm">%s</div>'
            '<div class="info"><div class="ssid">%s%s</div>'
            '<div class="meta">%d dBm · %s · %s MHz</div></div>'
            '<form method="post" action="%s" class="form" style="margin:0">%s'
            '<button class="conn" type="submit">连接</button></form>'
            '</div>' % (sig, signal_bars(sig), s, tags, sig, enc,
                        "" if not re.search(r'\d{4}', flags) else "2.4G", action, need_pwd)
        )

    if not rows:
        rows = ['<div class="card">未扫描到 WiFi，请刷新重试。</div>']

    # 结果提示
    m = ""
    if _result["running"]:
        m = '<div class="msg wait">⏳ 正在连接 %s …</div>' % html.escape(_result["ssid"])
    elif _result["ok"] is True:
        m = '<div class="msg ok">✅ %s</div>' % html.escape(_result["msg"])
    elif _result["ok"] is False:
        m = '<div class="msg bad">❌ %s</div>' % html.escape(_result["msg"])

    return PAGE.replace("__MSG__", m + msg_html).replace("__LIST__", "".join(rows))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # 静默日志

    def _check_token(self, qs):
        return TOKEN and qs.get("t", [""])[0] == TOKEN

    def _send(self, body, status=200):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if not self._check_token(qs):
            self._send("<h2>需要访问令牌</h2><p>请在地址后加 <code>?t=令牌</code></p>")
            return
        self._send(render())

    def do_POST(self):
        u = urlparse(self.path)
        qs = parse_qs(u.query)
        if not self._check_token(qs):
            self._send("forbidden", 403)
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "ignore")
        form = parse_qs(body)
        ssid = form.get("ssid", qs.get("ssid", [""]))[0]
        password = form.get("password", [""])[0]
        if not ssid:
            self._send(render('<div class="msg bad">未指定 SSID</div>'))
            return
        # 点连接时立刻返回"连接中"页，实际连接在后台线程做（避免断网卡住 HTTP）
        _result.update(running=True, ssid=ssid, ok=None, msg="连接中…", ts=time.time())
        threading.Thread(target=connect_worker, args=(ssid, password), daemon=True).start()
        self._send(render())


def main():
    if os.geteuid() != 0:
        print("请以 root 运行：sudo python3 wifi.py")
        sys.exit(1)
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    # 检查 wpa_cli 可用性
    rc, out = wpa(["status"], timeout=5)
    if rc != 0:
        print("警告：wpa_cli 调用失败，请确认 wpa_supplicant 正在运行：", out)

    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    rc, addr = run(["ip", "-4", "addr", "show", IFACE])
    mip = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", addr)
    ip = mip.group(1) if mip else "<手机IP>"
    print("WiFi UI 已启动： http://%s:%d/?t=%s" % (ip, port, TOKEN))
    print("按 Ctrl-C 退出")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n已退出")
        srv.shutdown()


if __name__ == "__main__":
    main()
