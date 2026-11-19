# 05 · 历史方案：Android 原生 chroot Linux 服务器

> ⚠️ **历史/备选方案，非最终交付**。本文记录早期因 WSL 被拦截而采用的 chroot 过渡方案；
> 后续 WSL 放行后已改用 **刷入真正的 postmarketOS**（见 `docs/00`、`docs/06`），那才是本仓库的最终成果。
> 本文仅在"不想清数据/无法刷机"时作为备选参考。文中 `administrator` / `root` 账号密码仅为当时临时值。

> 实施时间：2026-11-19
> 实施方式：全程 ADB 远程完成，未刷机、未清数据、未触碰屏幕
> 状态：**已被 postmarketOS 方案取代**

---

## 一、方案变更说明（重要）

原计划（`docs/03`）为「刷入 postmarketOS 替换 Android」，需要 Linux 主机运行 `pmbootstrap` 构建 rootfs。**本次实施时 WSL 被主机安全策略硬性拉黑**：

```
PROGRAM BLOCKED BY SECURITY POLICY
  - wsl.exe (C:\Windows\System32\wsl.exe)
This block cannot be approved or bypassed from the current command.
```

由于 WSL 无法启动，`pmbootstrap` 构建环境不可用，刷机路线暂时不可行。改为**更优的替代路线**：

| 维度 | 刷 postmarketOS | ✅ 本次方案（Android 原生 chroot） |
|---|---|---|
| 是否清数据 | 清空 `/data`（不可逆） | **完全不动，Android 照常可用** |
| 稳定性 | `testing` 级移植，Wi-Fi/触屏有已知问题 | 用 LineageOS 成熟驱动 + 内核 |
| 性能损耗 | 原生 | **零指令翻译**（同内核 aarch64，非模拟器） |
| 可回滚 | 无法回滚（需重新刷 Android） | 删一个目录即彻底还原 |
| 相机/OTG | 不可用 | 保持 Android 原样可用 |
| 前置条件 | 需 Linux 构建主机 | **仅需 ADB + root** |

结论（当时的判断，已被后续实践推翻）：chroot 路线在可逆性上有优势且已实测跑通。但 WSL 解禁后，刷入真正的 postmarketOS 才是最终采用的方案——它带来主线内核、framebuffer 仪表盘、电源键控制等 chroot 无法提供的能力。**本文仅作历史记录与备选参考。**

---

## 二、架构

```
┌─────────────────────────────────────────────────────────┐
│ 物理层  Redmi Note 5A (ugglite)                          │
│         MSM8917/8937 · 4×Cortex-A53 aarch64 · 2GB RAM    │
├─────────────────────────────────────────────────────────┤
│ 内核层  Linux 4.9.337-lineageos (Android 12, userdebug)  │
│         SELinux = Permissive（chroot exec 前提）          │
├─────────────────────────────────────────────────────────┤
│ Android LineageOS 12  —— 未被修改，日常可用               │
├─────────────────────────────────────────────────────────┤
│ chroot  Alpine Linux 3.24.4 aarch64                      │
│   /data/linux/rootfs.img  ← 3GB ext4 稀疏镜像            │
│   挂载点 /data/linux/mnt                                 │
│   ├─ sshd   :22   密码登录 + SFTP                        │
│   ├─ nginx  :80   静态站点 + stub_status                 │
│   └─ crond         定时任务                              │
├─────────────────────────────────────────────────────────┤
│ 守护层  /data/linux/supervisor.sh  (20s 心跳)            │
│         Magisk service.d → 开机自动拉起                   │
└─────────────────────────────────────────────────────────┘
```

**关键点**：chroot 与 Android 共享同一个内核，`uname -r` 为 `4.9.337`，因此**没有 QEMU / proot 的指令翻译开销**，性能接近原生 Linux。

---

## 三、账号与访问

| 项目 | 值 |
|---|---|
| SSH 地址 | `<DEVICE_IP>:22`（局域网） |
| 用户名 | `administrator` 或 `Administrator`（两种大小写均实测可登录，同 UID 1000） |
| 密码 | `<YOUR_PASSWORD>` |
| sudo | 免密（`wheel` 组 NOPASSWD） |
| root 账号 | 密码同为 `<YOUR_PASSWORD>`，允许直接登录 |
| Web | `http://<DEVICE_IP>/` |
| 监控页 | `http://<DEVICE_IP>/status`（nginx stub_status） |
| SFTP | 同一账号，已实测可用 |

Windows 端连接（本机未安装 OpenSSH 客户端，三条路径任选）：

```powershell
# 1) 装 Windows 自带 OpenSSH 客户端（一次性）
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
ssh administrator@<DEVICE_IP>

# 2) 用项目自带验收脚本（已装 paramiko）
python D:\ai项目\RedMiNote5A\scripts\windows\02-verify-ssh.py

# 3) 用 srvctl 进入 chroot shell
powershell -File D:\ai项目\RedMiNote5A\scripts\windows\03-srvctl.ps1 shell
```

---

## 四、实测数据

```
======== note5a-srv 状态 ========
镜像挂载  : OK
SSH :22   : OK
HTTP:80   : OK
Wi-Fi IP  : <DEVICE_IP>
守护进程  : OK
SELinux   : Permissive
发行版    : 3.24.4 Alpine
内核      : 4.9.337-lineageos aarch64
内存      : 1454M / 1811M 已用 (80%)   ← 含 Android 本身
磁盘      : 126M / 2.9G 已用 (5%)
服务      : sshd:up nginx:up crond:up
```

外部验证（Windows 侧真实发起）：

| 检查 | 结果 |
|---|---|
| TCP 22 连通 | ✅ |
| SSH banner | `SSH-2.0-OpenSSH_10.3` ✅ |
| 密码登录 `administrator/root` | ✅ `uid=1000(administrator) groups=wheel` |
| `sudo id -u` | ✅ `0`（免密提权） |
| SFTP 子系统 | ✅ |
| HTTP GET `/` | ✅ `200`，532 bytes |
| `/status` | ✅ `Active connections: 1` |
| 冷启动自启（重启 2 次） | ✅ sshd 秒起，Wi-Fi 30s 内自愈 |

---

## 五、实施过程（可复现步骤）

```bash
# 0. 主机侧准备
cd D:\ai项目\RedMiNote5A
curl -LO https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-3.24.4-aarch64.tar.gz
# 校验 sha256 = 4b14c18f7e90a063b61462ea1462a5732c154bf6adad594974fe6487cd98a8de

# 1. 推送 rootfs
adb -s <DEVICE_SERIAL> push alpine-minirootfs-3.24.4-aarch64.tar.gz /data/local/tmp/alpine.tar.gz

# 2. 推送脚本
adb -s <DEVICE_SERIAL> push scripts/device/10-bootstrap-chroot.sh  /data/local/tmp/10-bootstrap.sh
adb -s <DEVICE_SERIAL> push scripts/device/inner-provision.sh      /data/local/tmp/inner-provision.sh
adb -s <DEVICE_SERIAL> push scripts/device/40-provision.sh         /data/local/tmp/40-provision.sh
adb -s <DEVICE_SERIAL> push scripts/device/20-start-server.sh      /data/local/tmp/start.sh
adb -s <DEVICE_SERIAL> push scripts/device/25-supervisor.sh        /data/local/tmp/supervisor.sh
adb -s <DEVICE_SERIAL> push scripts/device/15-status.sh            /data/local/tmp/status.sh

# 3. 建镜像 + 解包 + 装 ALpine（root）
adb -s <DEVICE_SERIAL> shell su -c "SSH_USER=administrator SSH_PASS=root sh /data/local/tmp/10-bootstrap.sh"

# 4. 服务栈 + 开机自启
adb -s <DEVICE_SERIAL> shell su -c "sh /data/local/tmp/40-provision.sh"

# 5. 部署运行时脚本并启动
adb -s <DEVICE_SERIAL> shell su -c "cp /data/local/tmp/start.sh /data/linux/start.sh;
  cp /data/local/tmp/supervisor.sh /data/linux/supervisor.sh;
  cp /data/local/tmp/status.sh /data/linux/status.sh; chmod 755 /data/linux/*.sh;
  setsid sh /data/linux/supervisor.sh >/dev/null 2>&1 &"

# 6. 验收
python scripts/windows/02-verify-ssh.py
```

> 注：Git Bash 下 `adb push` 的 `/data/...` 会被 MSYS 改写为 Windows 路径，须先 `export MSYS_NO_PATHCONV=1`。

---

## 六、踩坑记录（4 个真实故障与修复）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `chroot: exec /sh: No such file or directory` | 用 `/system/bin/sh` 测试，它是动态链接，缺 Android linker | 用 musl 静态 busybox（Alpine rootfs 自带） |
| 2 | 重启后 `losetup 失败` / `mount 失败` 连续 30s | boot 早期 loop 子系统未就绪 | 启动脚本加 10 次重试（3s 间隔）+ 20s 心跳守护重试 |
| 3 | 重启后 nginx 不启动，但手动能起 | `chroot` **继承 Android 的 PATH**，找不到 `pgrep`/`nginx` | chroot 内显式 `export PATH=/usr/sbin:/usr/bin:...` |
| 4 | 脚本判断「nginx 已在运行」却实际没起 | `pgrep -f "nginx: master"` **匹配到自身命令行**导致误判 | 改用端口检测（`/proc/net/tcp` 状态 `0A`），并注意 `pkill -f` 会杀掉自己的 adb 会话 |
| 5 | 重启后 Wi-Fi 不自动连接 | Android 重启后偶发「已保存网络未自动关联」（`mAvailableSavedSsids` 为空） | supervisor 检测 `wlan0` 连续 2 周期无 IP 则 `svc wifi disable/enable`，实测 30s 内恢复同一 IP |
| 6 | `http://IP/` 返回 404 | Alpine 3.24 的 nginx 默认站点是**刻意返回 404 的空壳** | 替换 `/etc/nginx/http.d/default.conf` 为真实站点 |

---

## 七、日常运维

```powershell
# 状态面板
powershell -File scripts\windows\03-srvctl.ps1 status

# 启动 / 修复
powershell -File scripts\windows\03-srvctl.ps1 start

# 停止（保留镜像）
powershell -File scripts\windows\03-srvctl.ps1 stop

# 查看日志
powershell -File scripts\windows\03-srvctl.ps1 logs

# 重启手机并验证自启
powershell -File scripts\windows\03-srvctl.ps1 reboot
```

设备端文件布局：

```
/data/linux/
├── rootfs.img        3GB 稀疏 ext4（实际占用随使用增长）
├── mnt/              挂载点（= chroot 根）
├── start.sh          启动/巡检脚本（幂等）
├── supervisor.sh     守护进程（20s 心跳 + Wi-Fi 自愈）
├── status.sh         状态面板
├── stop.sh           停止并卸载
├── server.log        启动日志（>256KB 自动轮转）
└── supervisor.log    守护日志
/data/adb/service.d/zz-linux-server.sh   开机自启入口
```

---

## 八、容量与性能说明

| 项 | 现状 | 说明 |
|---|---|---|
| 镜像容量 | 3GB（已用 126M） | `resize2fs` 可在线扩容，注意 `/data` 仅剩约 1.2G |
| 内存 | Android 占 1.4G，剩余约 360M | **这是最大瓶颈** |
| 磁盘余量 | `/data` 可用 4.4G→约 1.2G | 建议不要把大文件放手机 |

**内存优化建议**（2GB 机型做服务器必须做）：

```bash
# 1. 停用不用的系统应用（不影响系统稳定性）
adb shell su -c "pm disable-user --user 0 com.google.android.youtube"
adb shell su -c "pm disable-user --user 0 com.android.chrome"

# 2. chroot 内避免跑 JVM / Node 大型应用，优先 Alpine 原生服务
# 3. 服务选型参考（实测内存占用）：
#    nginx       ~3 MB
#    mosquitto   ~2 MB
#    AdGuardHome ~40 MB
#    Python 脚本  ~15 MB
#    Node.js 应用 不建议（>100MB）
```

可运行的服务组合（按内存预算）：**nginx 静态站 + mosquitto MQTT + Python/Shell 定时任务 + rclone 备份 + tailscale 内网穿透**。

---

## 九、回滚 / 卸载

```bash
# 停止
adb shell su -c "sh /data/linux/stop.sh"

# 移除开机自启
adb shell su -c "rm -f /data/adb/service.d/zz-linux-server.sh"

# 彻底删除（释放 3GB 名义空间 / 实际占用）
adb shell su -c "rm -rf /data/linux"

# Android 完全不受影响，无需任何其他操作
```

---

## 十、后续可选项

1. **固定 IP**：在路由器 DHCP 里给 MAC `<DEVICE_MAC>` 绑定 `<DEVICE_IP>`，避免 IP 变化。
2. **内网穿透**：`apk add tailscale && rc-update add tailscaled && tailscale up`，手机在外网也可访问。
3. **换静态更强密码**：`ssh administrator@... 'passwd'`，并考虑改 `sshd_config` 关闭密码登录改用密钥。
4. **若要回到 postmarketOS 路线**：在「安全中心 → 命令安全 → 程序黑名单」移除 `wsl.exe`，然后按 `docs/03` 执行 `scripts/linux/build-pmos.sh`。
