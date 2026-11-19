# Framebuffer 极简仪表盘（pmos-dash）

开机自动全屏显示基础信息，SSH / USB 串口登录不受影响。设备屏幕 720×1280 竖屏、32bpp。

## 效果

显示内容（v3，从上到下）：
- 时间/日期（NTP 自动同步）
- IP 地址（WLAN0）+ **Wi-Fi 信号强度**：RSSI dBm 数值、信号质量文字（EXCELLENT/GOOD/FAIR/WEAK）、4 格信号条
- **网络吞吐**：RX / TX 实时速率（KB/S，每 2 秒采样 `/proc/net/dev`）、TCP 连接状态（ACTIVE / LISTEN，读 `/proc/net/tcp{,6}`）
- 电量（含充电状态）+ 进度条
- CPU 占用 + 进度条
- **Top 5 CPU 进程**：进程名 + 2 秒窗口 CPU 百分比 + 条形（读 `/proc/[pid]/stat` 的 utime+stime 增量排序）
- **Top 5 内存进程**：进程名 + RSS 占用（MB）+ 条形（读 `/proc/[pid]/statm` 的 resident 页数，按内存从高到低排序，条形相对最大进程归一化）
- 内存 + 进度条
- 温度、磁盘（并排）、运行时间

预览见 `preview.png`（v1）、`preview-v2.png`（v2 含网络与 CPU Top5）、`preview-v3.png`（v3 含 RSSI 与 MEM Top5）。

## 部署状态（已上线）

设备上已就位：

| 项目 | 路径 / 状态 |
|------|------------|
| 二进制 | `/usr/local/bin/pmos-dash` (aarch64, ~73KB) |
| 编译工具 | `gcc` `musl-dev`（已 apk add） |
| 开机自启 | `/etc/local.d/70-dashboard.start` |
| 时间同步 | `/etc/local.d/60-timesync.start` + `ntpd` 加入 default runlevel |
| Wi-Fi 自动连 | `/etc/local.d/50-wifi.start`（既有） |
| tty1 getty | 已在 `/etc/inittab` 注释（备份 `.bak-dash`），避免登录提示覆盖仪表盘 |
| USB 串口 | `ttyGS0` getty 保留，作为应急登录通道 |

开机流程：`local` 服务依次执行 50-wifi（连 Wi-Fi）→ 60-timesync（NTP 对时）→ 70-dashboard（解绑 fbcon + 启动仪表盘）→ 80-pwrkey（启动电源键亮灭屏守护进程）。

## 电源键亮屏/灭屏（pwrkey-blank）

- **短按电源键（<2 秒）**：切换背光 开/关（255↔0）；**长按（≥2 秒）不拦截**，留给内核做关机/复位
- 实现：`pwrkey-blank.c` 守护进程监听 `/dev/input/event0`（`pm8941_pwrkey`）的 `KEY_POWER` evdev 事件，短按翻转 `/sys/class/backlight/1a94000.dsi.0/brightness`，状态写入 `/run/pwr-screen-state`
- 防抖 80ms（过滤毛刺）；短按判定 80ms~2s；长按阈值 2s
- 仪表盘联动：`pmos-dash.c` 的 main 循环读 `/run/pwr-screen-state`，灭屏时跳过绘制+整帧 blit 以省电（CPU%/速率是相对窗口量，灭屏期间不采样不影响恢复后数值正确性）
- 开机自启：`/etc/local.d/80-pwrkey.start`（先按 PID 清理旧实例，再置背光 255 并启动）
- 日志：`/var/log/pwrkey-blank.log`（记录每次 start / short press / long press ignored）
- 源码：`pwrkey-blank.c`；测试工具 `inject-pwrkey.c`（uinput 注入模拟按键，仅调试用，不部署到设备）

## 重新部署（重刷镜像后）

```bash
# 1. 装编译工具（需代理时加 http_proxy=http://<PROXY_HOST>:7891）
apk add gcc musl-dev

# 2. 上传源码并编译
scp pmos-dash.c user@<DEVICE_IP>:/tmp/
ssh user@<DEVICE_IP>
gcc -O2 -o /tmp/pmos-dash /tmp/pmos-dash.c
sudo cp /tmp/pmos-dash /usr/local/bin/pmos-dash

# 3. 恢复自启配置（见“关键配置”一节重建 local.d 脚本）

# 4. 重启验证
sudo reboot
```

## 关键配置

`/etc/local.d/70-dashboard.start`：
```sh
#!/bin/sh
[ -w /sys/class/vtconsole/vtcon1/bind ] && echo 0 > /sys/class/vtconsole/vtcon1/bind 2>/dev/null
pkill -f "getty 38400 tty1" 2>/dev/null
pkill -x pmos-dash 2>/dev/null
sleep 1
nohup /usr/local/bin/pmos-dash >/var/log/pmos-dash.log 2>&1 &
```

`/etc/local.d/60-timesync.start`：
```sh
#!/bin/sh
sleep 20
ntpd -q -n -p pool.ntp.org 2>/dev/null &
```

## 抓图与预览

从设备抓取 raw framebuffer，用 `fb2png.py` 转 PNG：
```bash
ssh ... 'sudo dd if=/dev/fb0 of=/tmp/fb.raw bs=2944 count=1280'
scp .../tmp/fb.raw ./
python3 fb2png.py fb.raw preview.png
```

## 踩坑记录（重要）

1. **屏幕间歇性闪烁（v1 问题）**：初版 `px()` 直接写前台 framebuffer，且每帧先全屏清屏再逐项重绘——这个"清屏→重绘"过程完全暴露在扫描输出（scanout）下，肉眼看到周期性闪烁，叠加 DRM 前台缓冲与 scanout 不同步的撕裂。**修复**：恢复双缓冲——所有绘制写入内存 `BACK`，`fb_flush()` 用一次 `memcpy(FB, BACK, FB_SIZE)` 整帧提交。验证：连续抓两帧 md5 完全一致，画面稳定无撕裂。注意双缓冲与"字符缺失"是两个独立问题，不要因为后者而退回直接渲染。
2. **`fb_fix_screeninfo.line_length` 报 0**：msmdrmfb 驱动不填该字段。必须用 `smem_len / yres` 推导 stride，本机为 `3768320 / 1280 = 2944`（= 720×4 + 64 padding）。直接用 `xres*4`(=2880) 会导致画面逐行累积错位、文字拉成斜线。
3. **不能用 `GLYPH[][] bitmask` 中间层**：原实现把字模解码成 bitmask 后绘制，出现字符随机缺失（IP 显示成 `121504`）。改为 `text()` 直接读 `FONT_ART` 字符串按 `#` 画点后完全正常。原因未完全定位（疑似 aarch64 上数组/位运算边界），但直接读字符串可靠。
4. **fbcon 会覆盖自绘内容**：必须 `echo 0 > /sys/class/vtconsole/vtcon1/bind` 解绑，否则 tty1 控制台重绘会盖掉仪表盘。同时注释 `/etc/inittab` 里的 tty1 getty，否则登录提示反复覆盖。
5. **字体只有大写 A-Z**：动态文本里不要用小写字母（会被映射成空格），运行时间用 `0H 1M` 而非 `0h 1m`。Top5 的进程名经 `sanitize_name()` 转大写、非法字符替换为 `?`。
6. **时间默认 1970**：RTC 无电池且不自动同步，必须靠 `ntpd -q` 在联网后对时。
7. **编译工具安装慢**：直连 alpine CDN 很慢/卡住，需走代理 `http://<PROXY_HOST>:7891`（Windows 上的 portproxy 7891→7890）。
8. **apt 包 `linux/fb.h` 缺失**：用内联结构体定义替代 `<linux/fb.h>`，避免安装 linux-headers。
9. **`strchr` 依赖**：`text()` 用 `strchr(ALPHA, ch)` 查字模索引，ALPHA 必须和 FONT_ART 顺序严格一致。
10. **Top5 CPU 算法**：按 pid 匹配上次采样的 utime+stime，取 2 秒增量；`/proc/[pid]/stat` 的 comm 字段含空格/括号，须用第一个 `(` 与最后一个 `)` 定位，再从 `)` 后跳过 11 个字段读第 14/15 字段（utime/stime）。**分母必须用系统总 jiffies 增量 `g_sys_delta`（= get_cpu 里 /proc/stat 的 total 增量），不能用「所有进程增量之和」**——后者在系统空闲时趋近 0，会把最忙的进程算成 ~100%，与 CPU 卡的 0% 自相矛盾。用共享分母后两者同口径：空闲时全 0%，各进程占比之和 ≈ 全局 CPU%。注意 /proc/stat 的 `cpu` 行是 4 核汇总，单核满载显示 ~25%（占系统总 CPU 比例，与 top 的 %Cpu(s) 一致），这是正常的，不是 bug。调用顺序必须 get_cpu 先于 get_top5_cpu，保证 g_sys_delta 是本周期的。
11. **网络速率采样间隔要与主循环一致**：`get_net_rate()` 假设两次采样间隔为 2 秒（主循环 `sleep(2)`），改主循环周期时需同步调整除数。
12. **RSSI 采集走 wpa_supplicant 控制套接字，不读 `/proc/net/wireless`**：本机内核没暴露 `/proc/net/wireless`，但有 `wpa_cli`。C 里直接用 `AF_UNIX/SOCK_DGRAM` 连 `/run/wpa_supplicant/wlan0`、发 `SIGNAL_POLL`、解析 `RSSI=`，避免每 2 秒 fork 一次 wpa_cli。**关键坑：客户端必须先 `bind()` 到自己的本地路径**（如 `/tmp/pmos-dash-ctrl-<pid>`），否则 wpa 端没有回包地址，`recv()` 会超时报 `Resource temporarily unavailable`；connect 的地址长度用 `offsetof(sockaddr_un,sun_path)+strlen(path)+1`，不要用 `sizeof(addr)`。仪表盘以 root 运行，对控制套接字（权限 770）有访问权。
13. **MEM Top5 用 `/proc/[pid]/statm` 第 2 字段（resident 页数）× 页大小**：比读 `/proc/[pid]/status` 的 VmRSS 更快。RSS 是瞬时值不需要两次采样差分（与 CPU Top5 不同），直接按 resident 降序取前 5；条形按最大进程归一化（否则单进程占总内存比例太小、条形看不见），数值显示实际 MB。

## 交互说明

- 手机端不需要任何操作，开机即进入仪表盘。
- 日常管理用 SSH：`ssh -i id_ed25519 user@<DEVICE_IP>`。
- 应急登录（SSH 挂了）：USB 数据线 + 串口，COM 口 115200，用户 `user` / 密码 `<TEMP_PASSWORD>`。
- 退出/替换仪表盘：`sudo pkill pmos-dash`，屏幕恢复 fbcon（需 `echo 1 > /sys/class/vtconsole/vtcon1/bind`，并恢复 inittab tty1 行）。
