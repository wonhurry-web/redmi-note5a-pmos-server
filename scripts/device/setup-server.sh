#!/bin/sh
# ============================================================================
# setup-server.sh —— 设备端首次启动后服务器环境配置（在手机上以 root 运行）
#
# 用法:
#   ssh srv@172.16.42.1
#   sudo -i
#   scp setup-server.sh root@172.16.42.1:/root/    # 从 Windows 传脚本
#   sh /root/setup-server.sh
#
# 功能: 服务自启 / Wi-Fi 静态 IP / Docker / zram / 基础安全 / 监控
# 注意: Wi-Fi 名称、密码、静态 IP 请按实际修改下方变量。
# ============================================================================
set -eu

# ---------- 可调参数 ----------
WIFI_SSID="YOUR_WIFI_SSID"          # <-- 修改
WIFI_PASS="YOUR_WIFI_PASSWORD"      # <-- 修改
STATIC_IP="<DEVICE_STATIC_IP>/24"        # <-- 修改
GATEWAY="<GATEWAY_IP>"              # <-- 修改
DNS="<GATEWAY_IP>"                  # <-- 修改

echo "============================================================"
echo " postmarketOS 服务器环境配置"
echo "============================================================"

# ---------- 1. 系统更新 ----------
echo "[1/6] 更新系统..."
apk update
apk upgrade

# ---------- 2. 安装软件 ----------
echo "[2/6] 安装服务器软件..."
apk add --no-cache \
    openssh networkmanager avahi docker \
    tmux htop nano curl wget \
    e2fsprogs zram-init ufw \
    mosquitto nginx 2>/dev/null || \
apk add --no-cache openssh networkmanager docker tmux htop nano curl wget

# ---------- 3. 服务自启 ----------
echo "[3/6] 配置服务开机自启 (OpenRC)..."
for svc in sshd networkmanager docker; do
    rc-update add "$svc" default 2>/dev/null || true
    rc-service "$svc" start 2>/dev/null || true
done
rc-update add avahi-daemon default 2>/dev/null || true
rc-service avahi-daemon start 2>/dev/null || true

# ---------- 4. zram（缓解 2GB 内存） ----------
echo "[4/6] 配置 zram..."
rc-update add zram-init default 2>/dev/null || true
rc-service zram-init start 2>/dev/null || true

# ---------- 5. Wi-Fi 静态 IP（可选） ----------
if [ "$WIFI_SSID" != "YOUR_WIFI_SSID" ]; then
    echo "[5/6] 配置 Wi-Fi 静态 IP..."
    nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" 2>/dev/null || true
    CON=$(nmcli -t -f NAME con show --active | head -n1)
    if [ -n "$CON" ]; then
        nmcli con mod "$CON" ipv4.addresses "$STATIC_IP"
        nmcli con mod "$CON" ipv4.gateway "$GATEWAY"
        nmcli con mod "$CON" ipv4.dns "$DNS"
        nmcli con mod "$CON" ipv4.method manual
        nmcli con up "$CON"
    fi
else
    echo "[5/6] 跳过 Wi-Fi 配置（未修改 SSID 占位符，使用 USB 网络）"
fi

# ---------- 6. 基础安全 ----------
echo "[6/6] 基础安全配置..."
# SSH 加固：建议先确认密钥登录可用后再禁用密码，这里默认保留密码以防锁死
# 如需禁用密码登录，取消下面两行注释（务必先放好公钥！）
# sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
# rc-service sshd restart

# 防火墙：仅允许局域网访问 SSH（按需调整）
ufw allow from 192.168.1.0/24 to any port 22 2>/dev/null || true
ufw --force enable 2>/dev/null || true

# ---------- 完成 ----------
echo "============================================================"
echo " 配置完成。当前状态："
echo "------------------------------------------------------------"
uname -a
echo "--- 内存 ---";      free -h
echo "--- IP ---";        ip addr | grep 'inet '
echo "--- 服务 ---";      rc-status 2>/dev/null | head -30
echo "--- Docker ---";    docker version 2>/dev/null | head -10 || true
echo "============================================================"
echo " 提醒：请先 24 小时压力测试，再迁移实际负载。详见 docs/04。"
echo "============================================================"
