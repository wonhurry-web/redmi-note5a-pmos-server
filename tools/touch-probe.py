#!/usr/bin/env python3
"""触摸事件捕获探针：读取 Goodix 电容屏的坐标范围，并实时打印触摸/抬起事件。

用法（需 root，因为 /dev/input/event* 属 root:input）:
    sudo python3 /usr/local/bin/touch-probe.py          # 打印坐标范围并监听 20 秒
    sudo python3 /usr/local/bin/touch-probe.py 60       # 监听 60 秒
    sudo python3 /usr/local/bin/touch-probe.py --info   # 只打印坐标范围

退出: Ctrl-C 或超时。
"""
import os
import sys
import time
import fcntl
import struct
import select

DEV = "/dev/input/event3"          # Goodix Capacitive TouchScreen（见 /proc/bus/input/devices）

# input_event: struct timeval(2x long) + __u16 type + __u16 code + __s32 value
EV_SIZE = struct.calcsize("llHHI")
EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
BTN_TOUCH = 0x14A
ABS_X, ABS_Y = 0x00, 0x01
ABS_MT_SLOT = 0x2F
ABS_MT_TOUCH_MAJOR = 0x30
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39
ABS_MT_PRESSURE = 0x3A

EVIOCGABS = 0x80184540             # _IOR('E', 0x40 + abs_code, struct input_absinfo)


def absinfo(fd, code):
    """返回 (value, min, max, fuzz, flat, resolution) —— struct input_absinfo 为 6 个 int。"""
    buf = fcntl.ioctl(fd, EVIOCGABS + code, b"\x00" * 24)
    return struct.unpack("iiiiii", buf)


def show_info(fd):
    print("设备: %s" % DEV)
    try:
        name = open("/sys/class/input/event3/device/name").read().strip()
        print("名称: %s" % name)
    except OSError:
        pass
    print("-" * 56)
    labels = [
        ("ABS_X", ABS_X), ("ABS_Y", ABS_Y),
        ("ABS_MT_SLOT", ABS_MT_SLOT),
        ("ABS_MT_TOUCH_MAJOR", ABS_MT_TOUCH_MAJOR),
        ("ABS_MT_POSITION_X", ABS_MT_POSITION_X),
        ("ABS_MT_POSITION_Y", ABS_MT_POSITION_Y),
        ("ABS_MT_TRACKING_ID", ABS_MT_TRACKING_ID),
        ("ABS_MT_PRESSURE", ABS_MT_PRESSURE),
    ]
    for label, code in labels:
        try:
            val, mn, mx, fuzz, flat, res = absinfo(fd, code)
            print("  %-20s value=%-6d min=%-6d max=%-6d res=%d" % (label, val, mn, mx, res))
        except OSError as e:
            print("  %-20s (不支持: %s)" % (label, e))
    print("-" * 56)


def listen(fd, seconds):
    print("监听 %d 秒，请触摸屏幕（多点也可）..." % seconds, flush=True)
    end = time.time() + seconds
    x = y = None
    touches = 0
    moves = 0
    last_print = 0
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if not ready:
            continue
        try:
            data = os.read(fd, EV_SIZE * 256)
        except OSError:
            break
        for off in range(0, len(data) - EV_SIZE + 1, EV_SIZE):
            _sec, _usec, etype, code, value = struct.unpack("llHHI", data[off:off + EV_SIZE])
            if etype == EV_ABS:
                if code == ABS_MT_POSITION_X or code == ABS_X:
                    x = value
                elif code == ABS_MT_POSITION_Y or code == ABS_Y:
                    y = value
                elif code == ABS_MT_TRACKING_ID and value >= 0:
                    touches += 1
                    print("  [DOWN] #%d x=%s y=%s" % (touches, x, y), flush=True)
                elif code == ABS_MT_TRACKING_ID and value < 0:
                    print("  [UP]   x=%s y=%s" % (x, y), flush=True)
                elif code in (ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_X, ABS_Y):
                    moves += 1
            elif etype == EV_KEY and code == BTN_TOUCH and value == 0:
                # 部分 Goodix 驱动用 BTN_TOUCH 0 表示最后一指抬起
                pass
        now = time.time()
        if now - last_print >= 5:
            print("  ... 已捕获 触摸%d次 / 坐标更新%d次" % (touches, moves), flush=True)
            last_print = now
    print("结果: 触摸 %d 次, 坐标更新 %d 次" % (touches, moves), flush=True)
    if touches == 0:
        print("未捕获到触摸事件（可能没摸、屏幕休眠、或驱动未真正工作）", flush=True)


def main():
    if not os.path.exists(DEV):
        print("找不到 %s，触摸驱动可能未加载" % DEV)
        return 1
    if os.geteuid() != 0:
        print("需要 root: sudo python3 %s" % sys.argv[0])
        return 1
    fd = os.open(DEV, os.O_RDONLY | os.O_NONBLOCK)
    try:
        show_info(fd)
        if len(sys.argv) > 1 and sys.argv[1] == "--info":
            return 0
        seconds = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 20
        listen(fd, seconds)
    except KeyboardInterrupt:
        print("\n已退出")
    finally:
        os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
