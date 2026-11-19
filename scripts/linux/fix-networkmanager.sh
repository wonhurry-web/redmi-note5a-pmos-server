#!/bin/bash
# 修复：把 networkmanager 加入 default runlevel，确保 Wi-Fi 自动连接
set -e
IMG=${IMG:-/path/to/qcom-msm89x7.img}   # 镜像路径，可通过环境变量 IMG= 覆盖
MNT=/tmp/pmos-fix
sudo kpartx -av "$IMG" >/dev/null 2>&1 || true
sudo mkdir -p "$MNT"
sudo mount /dev/mapper/loop0p2 "$MNT" 2>/dev/null

echo "=== 添加 networkmanager 自启符号链接 ==="
sudo ln -sf /etc/init.d/networkmanager "$MNT/etc/runlevels/default/networkmanager"
sudo ls -la "$MNT/etc/runlevels/default/" | grep -iE "network|sshd"

echo "=== 确认 Wi-Fi 配置仍在 ==="
sudo grep -E "ssid=|psk=|autoconnect" "$MNT/etc/NetworkManager/system-connections/<YOUR_WIFI_SSID>.nmconnection"

echo "=== 确认 sshd 自启 ==="
sudo ls "$MNT/etc/runlevels/default/" | grep sshd

sudo umount "$MNT"
sudo kpartx -d "$IMG" >/dev/null 2>&1
echo DONE
