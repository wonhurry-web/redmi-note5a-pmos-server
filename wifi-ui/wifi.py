#!/usr/bin/env python3
"""
wifi.py - 在 Xshell 终端里直接操作的 WiFi 管理界面（curses TUI）

用法（在 SSH 连上后）：
    sudo python3 /usr/local/bin/wifi.py

操作：
    ↑ / ↓      移动光标（也支持鼠标点击，需 Xshell 开启鼠标报告）
    Enter      连接高亮的网络（WPA 网络会提示输入密码）
    r          重新扫描
    q / Esc    退出

连接成功后自动 save_config 写入手机，重启保留。
纯 Python 标准库（curses + subprocess），无需 pip 安装。需 root 运行（wpa_cli socket 属 root）。
"""

import os
# 在 import curses 之前设定，确保方向键 ESC 序列可靠解析
os.environ.setdefault("ESCDELAY", "25")
if not os.environ.get("TERM"):
    os.environ["TERM"] = "xterm-256color"
import re
import sys
import curses
import subprocess
import time

IFACE = "wlan0"


def run(cmd, timeout=12):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True)
        return p.returncode, p.stdout.strip()
    except subprocess.TimeoutExpired:
        return -1, "timeout"
    except FileNotFoundError:
        return -1, "command not found"


def wpa(args, timeout=12):
    return run(["wpa_cli", "-i", IFACE] + list(args), timeout)


def scan():
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
        # 过滤隐藏/乱码 SSID：只保留可打印且非替换字符的字形
        ssid = "".join(ch for ch in ssid if ch.isprintable() and ch != "\ufffd").strip()
        # 若清洗后含大量 \x00 残留（某些隐藏 SSID 以转义形式出现）或为空则跳过
        if not ssid or ssid.count("\\x00") > 2 or ssid.count("\x00") > 0:
            continue
        try:
            sig = int(sig)
        except ValueError:
            continue
        if ssid not in aps or sig > aps[ssid][1]:
            aps[ssid] = [ssid, sig, flags]
    return sorted(aps.values(), key=lambda x: -x[1])


def saved_status():
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


def sec_type(flags):
    if "SAE" in flags or "WPA3" in flags:
        return "WPA3"
    if "WPA2" in flags or "WPA-PSK" in flags:
        return "WPA2"
    if "WEP" in flags:
        return "WEP"
    return "OPEN"


def bars(sig):
    if sig >= -50:
        n = 4
    elif sig >= -60:
        n = 3
    elif sig >= -70:
        n = 2
    else:
        n = 1
    return "#" * n + "." * (4 - n)


def connect(ssid, password, enc):
    """返回 (ok, msg)。同步执行，约 10-18 秒。"""
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
            return False, "add_network failed: " + out
        nid = m.group(1)

    wpa(["set_network", nid, "ssid", '"%s"' % ssid])
    if enc == "OPEN" or not password:
        wpa(["set_network", nid, "key_mgmt", "NONE"])
    else:
        wpa(["set_network", nid, "key_mgmt", "WPA-PSK"])
        wpa(["set_network", nid, "psk", '"%s"' % password])
    wpa(["enable_network", nid])
    wpa(["select_network", nid])

    ok = False
    for i in range(20):
        time.sleep(1)
        rc, st = wpa(["status"])
        state = cur = ""
        for line in st.splitlines():
            if line.startswith("wpa_state="):
                state = line.split("=", 1)[1]
            elif line.startswith("ssid="):
                cur = line.split("=", 1)[1]
        if state == "COMPLETED" and cur == ssid:
            ok = True
            break
        if state in ("INVALID_PASSWORD", "ASSOCIATING", "AUTHENTICATING") and i > 12:
            break

    if ok:
        run(["killall", "udhcpc"])
        time.sleep(1)
        run(["udhcpc", "-i", IFACE, "-n"], timeout=15)
        wpa(["save_config"])
        rc, addr = run(["ip", "-4", "addr", "show", IFACE])
        mip = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", addr)
        ip = mip.group(1) if mip else "?"
        return True, "Connected & saved to phone. IP: " + ip
    else:
        if was_new:
            wpa(["remove_network", nid])
            return False, "Failed (wrong password / weak signal). Network removed."
        return False, "Failed (wrong password / weak signal). Existing config kept."


def draw(stdscr, aps, saved, current, sel, offset, status_msg):
    stdscr.clear()
    h, w = stdscr.getmaxyx()
    safe_w = w - 1

    def put(y, x, s):
        if 0 <= y < h and 0 <= x < safe_w:
            try:
                stdscr.addnstr(y, x, s, safe_w - x)
            except curses.error:
                pass

    put(0, 0, "=== WiFi Manager - Redmi Note 5A (postmarketOS) ===")
    put(1, 0, "Up/Down/1-9/mouse: select | Enter: connect | r: rescan | q: quit")
    put(2, 0, "-" * min(safe_w, 60))
    put(3, 0, (" #  %-4s %-24s %-6s %-4s %s" % ("SIG", "SSID", "ENC", "BAND", "STATUS"))[:safe_w])

    visible = h - 6
    for i in range(min(visible, len(aps) - offset)):
        idx = offset + i
        ssid, sig, flags = aps[idx][0], aps[idx][1], aps[idx][2]
        enc = sec_type(flags)
        tags = []
        if ssid == current:
            tags.append("CURRENT")
        if ssid in saved:
            tags.append("SAVED")
        num = "%d" % (idx + 1) if idx < 9 else " "
        line = "%s%s %-4s %-24.24s %-6s %-4s %s" % (
            num, ">" if idx == sel else " ", bars(sig), ssid, enc, "2.4G", ",".join(tags))
        try:
            if idx == sel:
                stdscr.addnstr(4 + i, 0, line, safe_w, curses.A_REVERSE)
            else:
                stdscr.addnstr(4 + i, 0, line, safe_w)
        except curses.error:
            pass

    if status_msg:
        put(h - 2, 0, "> " + status_msg[:safe_w - 2])
    stdscr.refresh()


def ask_password(stdscr, ssid, enc):
    h, w = stdscr.getmaxyx()
    safe_w = w - 1
    if enc == "OPEN":
        return ""
    curses.curs_set(1)
    stdscr.clear()
    try:
        stdscr.addnstr(2, 0, "Connect to: %s (%s)" % (ssid, enc), safe_w)
        stdscr.addnstr(4, 0, "Password (blank to cancel): ", safe_w)
    except curses.error:
        pass
    stdscr.refresh()
    win = curses.newwin(1, min(safe_w - 1, 60), 5, 0)
    try:
        curses.noecho()
        s = win.getstr().decode("utf-8", "ignore")
    finally:
        curses.echo()
        curses.curs_set(0)
    return s.strip()


def tui(stdscr):
    curses.curs_set(0)
    stdscr.keypad(True)
    try:
        curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    except Exception:
        pass

    draw(stdscr, [], [], "", 0, 0, "Scanning...")
    aps = scan()
    saved, current = saved_status()
    sel, offset = 0, 0
    status = "Ready. %d networks found." % len(aps)

    while True:
        h, w = stdscr.getmaxyx()
        visible = h - 6
        draw(stdscr, aps, saved, current, sel, offset, status)
        key = stdscr.getch()

        if key in (ord('q'), 27):
            break
        elif key in (curses.KEY_UP, ord('k')):
            sel = max(0, sel - 1)
            offset = min(offset, sel)
        elif key in (curses.KEY_DOWN, ord('j')):
            sel = min(len(aps) - 1 if aps else 0, sel + 1)
            if sel >= offset + visible:
                offset = sel - visible + 1
        elif ord('1') <= key <= ord('9'):
            n = key - ord('1')
            if n < len(aps):
                sel = n
                offset = max(0, sel - visible + 1) if sel >= offset + visible else offset
                status = "Selected %s - press Enter to connect" % aps[sel][0]
        elif key == ord('r'):
            status = "Rescanning..."
            draw(stdscr, aps, saved, current, sel, offset, status)
            aps = scan()
            saved, current = saved_status()
            sel, offset = 0, 0
            status = "Rescanned. %d networks." % len(aps)
        elif key == curses.KEY_MOUSE:
            try:
                _, mx, my, _, _ = curses.getmouse()
                row = my - 4
                if 0 <= row < min(visible, len(aps) - offset):
                    sel = offset + row
                    status = "Selected %s - press Enter to connect" % aps[sel][0]
            except Exception:
                pass
        elif key in (10, 13):
            if not aps:
                continue
            ssid, _, flags = aps[sel]
            enc = sec_type(flags)
            pwd = ask_password(stdscr, ssid, enc)
            if enc != "OPEN" and not pwd:
                status = "Cancelled."
                continue
            status = "Connecting to %s ..." % ssid
            draw(stdscr, aps, saved, current, sel, offset, status)
            ok, msg = connect(ssid, pwd, enc)
            status = ("OK: " if ok else "ERR: ") + msg
            saved, current = saved_status()


def main():
    if os.geteuid() != 0:
        print("Run as root: sudo python3 wifi.py")
        sys.exit(1)
    rc, out = wpa(["status"], timeout=5)
    if rc != 0:
        print("Warning: wpa_cli failed (is wpa_supplicant running?):", out)
    curses.wrapper(tui)


if __name__ == "__main__":
    main()
