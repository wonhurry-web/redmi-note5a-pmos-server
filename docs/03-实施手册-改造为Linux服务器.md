# 03 · 实施手册：改造为 Linux 服务器（核心）

> 全流程 8 个阶段：备份 → 环境 → 初始化 → 构建 → 刷机 → 首启 → 服务器配置 → 验证
> 预计耗时：备份 10–30 分钟；构建 20–60 分钟（首次）；刷机 5–15 分钟。

---

## 阶段 A · 前置备份（⚠️ 不可跳过）

刷 `rootfs` 会清除 `/data`。先做两件事：

### A1. 全分区镜像备份（fastboot，最完整）

在 Windows 上（PowerShell 管理员）：

```powershell
cd D:\platform-tools
# 进入 fastboot 模式（二选一）
adb -s <DEVICE_SERIAL> reboot bootloader
# 或：手机关机后按住 音量下 + 电源 直到出现 fastboot 画面

# 确认设备已进入 fastboot
.\fastboot.exe devices
# 应输出: <DEVICE_SERIAL>    fastboot

# 建立备份目录
$bk = "D:\backup\ugglite\$(Get-Date -Format yyyyMMdd_HHmmss)"
New-Item -ItemType Directory -Force -Path $bk | Out-Null

# 逐个备份关键分区（对应诊断报告中的分区表）
$parts = @("aboot","abootbak","boot","recovery","system","cache","persist","misc","userdata")
foreach ($p in $parts) {
    .\fastboot.exe getvar partition-size:$p 2>&1 | Out-Null
    .\fastboot.exe dump_image $p "$bk\$p.img"
}
# 保存分区表与变量
.\fastboot.exe getvar all 2>&1 | Out-File "$bk\fastboot_getvar_all.txt"
```

> 完整脚本见 `scripts/windows/01-preflash-backup.ps1`（自动完成上述步骤）。

### A2. 用户数据备份（ADB，开机状态下）

```powershell
# 回到系统
.\fastboot.exe reboot
# 等待开机后
adb -s <DEVICE_SERIAL> pull /sdcard/ D:\backup\ugglite\sdcard\
```

备份完成后再进入后续阶段。

---

## 阶段 B · 构建环境准备（Linux / WSL2）

`pmbootstrap` 必须在 Linux 环境运行。推荐 Ubuntu 22.04+ 或 WSL2 Ubuntu。

> 当前自动化环境禁用 WSL，故此阶段需在你自己的 Linux / WSL2 主机执行。

```bash
# 1. 安装依赖
sudo apt update
sudo apt install -y python3 python3-pip git android-sdk-platform-tools-common kpartx

# 2. 安装 pmbootstrap（推荐 pipx，隔离环境）
python3 -m pip install --user pmbootstrap
# 或：pipx install pmbootstrap

# 3. 验证
pmbootstrap --version
```

> WSL2 注意：需使用 WSL2（非 WSL1），且 `fastboot`/`adb` 能识别设备。若 WSL2 无法直连 USB，可在 Windows 侧用 fastboot 刷机（阶段 E 的 Windows 方案），WSL 只负责构建导出。

---

## 阶段 C · pmbootstrap init 交互配置

运行 `pmbootstrap init`，按以下选择（**关键项加粗**）：

```
Work path                    [默认] ~/.local/var/pmbootstrap
pmaports path                [默认]
Release channel              [edge]   ← 推荐 edge（msm89x7 为测试端口，新内核在 edge）
Vendor                       * qcom  *  ← 通用端口，不是 xiaomi
Device codename              * msm89x7 * ← 关键：选通用端口而非 ugglite
Username                     [默认 user 或自定义，如 srv]
User interface               * none  *  ← 关键：无图形界面 = 无头服务器
Extra packages               * openssh networkmanager avahi docker tmux htop nano curl wget *
Hostname                     [如 note5a-srv]
Copy SSH keys                [按需要，y 可免密登录]
Timezone                     [Asia/Shanghai]
```

**关键说明**：

1. **`vendor=qcom` + `device=msm89x7`**：官方 Wiki 指定的通用端口，覆盖本机 MSM8917/8937。
2. **`User interface = none`**：不装 Phosh/Plasma Mobile 等移动桌面，节省内存、降低功耗、减少攻击面 —— 服务器的正确选择。
3. **Extra packages**：一次性预装服务器所需软件，避免首次启动后再逐个 `apk add`。
   - `openssh`：SSH 远程管理（核心）
   - `networkmanager`：网络管理（Wi-Fi / 以太网）
   - `avahi`：mDNS 发现（`note5a-srv.local` 访问，可选但方便）
   - `docker`：容器运行时（真正内核，cgroups/namespaces 完整）
   - `tmux htop nano curl wget`：运维常用工具
4. **init 系统**：默认 OpenRC（更轻，推荐）。若偏好 systemd 可后续切换，但手机硬件上 OpenRC 更稳。

> 交互式配置较繁琐，可使用 `scripts/linux/build-pmos.sh` 脚本，它把上述参数以命令方式固化。

---

## 阶段 D · 构建与导出

```bash
# 构建镜像（下载 + 编译，首次 20–60 分钟）
pmbootstrap install

# 若构建失败，清理缓存重试
pmbootstrap zap -hc
pmbootstrap install

# 导出镜像（需要单独 rootfs 文件时）
pmbootstrap export
# 产物通常在 /tmp/postmarketOS-export/ 下
```

构建完成后，可在 chroot 中预先配置（可选但推荐）：

```bash
# 进入设备 rootfs chroot
pmbootstrap chroot -r

# 在 chroot 内：设置 root 密码、启用 sshd、配置开机服务
passwd root
rc-update add sshd default
rc-update add networkmanager default
rc-update add avahi-daemon default   # 若装了 avahi

# 允许 root 登录（OpenRC + openssh 默认可能禁止）
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config

exit
```

---

## 阶段 E · 刷机

### E1. 进入 fastboot 模式

```powershell
adb -s <DEVICE_SERIAL> reboot bootloader
.\fastboot.exe devices   # 确认出现 <DEVICE_SERIAL> fastboot
```

或物理方式：关机 → 按住 **音量下 + 电源** 数秒。

### E2. 获取 lk2nd

从 <https://github.com/msm8916-mainline/lk2nd/releases/> 下载最新 `lk2nd-msm8952.img`，放到 `D:\platform-tools\`。

### E3. 刷入（Windows 侧执行，顺序严格）

```powershell
cd D:\platform-tools

# 1) 刷 lk2nd 到 boot（硬性依赖，不可跳过）
.\fastboot.exe flash boot lk2nd-msm8952.img

# 2) 刷 rootfs（在 fastboot 模式下由 pmbootstrap 完成，或用导出的镜像）
#    方案 A：在 WSL/Linux 中执行（设备需仍在 fastboot）
pmbootstrap flasher flash_rootfs

#    方案 B：Windows 侧手动刷写导出的 rootfs 镜像
#    .\fastboot.exe flash userdata <导出的 rootfs.img>
```

> 若 `pmbootstrap flasher` 在 WSL 中无法识别 fastboot 设备，用方案 B：在 Linux 侧 `pmbootstrap export` 导出镜像，拷贝到 Windows 用 fastboot 手动刷 `userdata` 分区。

### E4. 完成

```powershell
.\fastboot.exe reboot
```

手机重启后进入 postmarketOS。无头配置下屏幕可能黑屏属正常 —— 通过网络访问即可。

---

## 阶段 F · 首次启动与 SSH 连接

postmarketOS 默认通过 USB 建立私有网络。等待 1–2 分钟后：

### F1. USB 网络连接（推荐，最可靠）

在 Windows 主机上配置 USB 网卡（首次需手动设一次）：

```powershell
# 查看网络连接，找到 "Remote NDIS based Internet Sharing Device" 之类的适配器
Get-NetIPInterface | Where-Object { $_.InterfaceDescription -like "*RNDIS*" -or $_.InterfaceDescription -like "*Remote NDIS*" }
# 假设接口索引为 42，设置主机侧 IP
New-NetIPAddress -InterfaceIndex 42 -IPAddress 172.16.42.2 -PrefixLength 24
```

设备端固定为 `172.16.42.1`。然后 SSH：

```powershell
ssh srv@172.16.42.1      # srv 替换为你在 init 中设置的用户名
# 首次连接输入 yes 接受主机密钥，再输入密码
```

### F2. Wi-Fi 连接（备用）

若已预配置 Wi-Fi 或连接了可用的 Wi-Fi：

```powershell
ssh srv@192.168.1.xxx   # 在路由器中查看设备新 IP（DHCP 列表）
# 或用 mDNS（装了 avahi 时）
ssh srv@note5a-srv.local
```

### F3. 首次登录后必做

```bash
sudo -i
apk update && apk upgrade
passwd root                    # 若阶段 D 未设置
```

---

## 阶段 G · 服务器软件栈配置

SSH 登录后运行设备端脚本（见 `scripts/device/setup-server.sh`），或手动配置：

### G1. 基础服务自启（OpenRC）

```bash
rc-update add sshd default
rc-update add networkmanager default
rc-update add docker default
rc-service sshd start
rc-service docker start
```

### G2. Wi-Fi 配置（若 USB 网络之外想用无线）

```bash
nmcli device wifi list
nmcli device wifi connect "你的SSID" password "你的密码"
# 设置静态 IP（推荐，便于稳定 SSH）
nmcli con mod "你的SSID" ipv4.addresses <DEVICE_STATIC_IP>/24
nmcli con mod "你的SSID" ipv4.gateway <GATEWAY_IP>
nmcli con mod "你的SSID" ipv4.method manual
```

### G3. Docker（容器化部署）

```bash
apk add docker
rc-update add docker default
rc-service docker start

# 测试（arm64 镜像）
docker run --rm hello-world
```

> 2GB 内存限制：同时运行 1–2 个轻量容器为宜（如 nginx、mosquitto、adguard home 等）。

### G4. 推荐的轻量服务组合

```bash
# Web 服务器
apk add nginx && rc-update add nginx default

# MQTT broker（家庭自动化）
apk add mosquitto && rc-update add mosquitto default

# 内网穿透（可选，手机常在 NAT 后）
apk add tailscale && rc-update add tailscaled default
tailscale up

# 监控采集（轻量）
apk add netdata   # 注意内存占用，2GB 下建议精简模块
```

### G5. SSH 安全加固

```bash
# 改用密钥登录，禁用密码（把公钥放到手机上）
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# 在 Windows 侧：scp 公钥过去
# scp C:\Users\Administrator\.ssh\id_rsa.pub srv@172.16.42.1:~/.ssh/authorized_keys

# 编辑 /etc/ssh/sshd_config
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
```

---

## 阶段 H · 验证清单

```bash
# 1. 系统信息
uname -a                 # 应为 postmarketOS 主线内核 7.x
cat /etc/os-release      # postmarketOS
free -h                  # 内存未被 Android 占用
uptime

# 2. 网络
ip addr                  # USB: 172.16.42.1 / Wi-Fi: 192.168.1.x
ping -c 3 8.8.8.8
ssh localhost            # sshd 正常

# 3. 服务
rc-status                # sshd/docker/networkmanager 均为 started
docker info

# 4. 稳定性（重要）
# 连续运行 24 小时，观察：
# - 是否死机/重启：uptime
# - 温度与降频：见 docs/04
# - Wi-Fi 是否掉线：dmesg | grep -i wlan
```

全部通过即完成改造。后续运维见 `docs/04`。
