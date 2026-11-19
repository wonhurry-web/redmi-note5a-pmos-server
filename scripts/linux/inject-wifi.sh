#!/bin/bash
# 离线在 postmarketOS rootfs 镜像中预配置 Wi-Fi (<YOUR_WIFI_SSID>) 自动连接
set -e
IMG=${IMG:-/path/to/qcom-msm89x7.img}   # 镜像路径，可通过环境变量 IMG= 覆盖
MNT=/tmp/pmos-root-mnt

echo "=== 映射分区（如未映射）==="
if [ ! -e /dev/mapper/loop0p2 ]; then
  sudo kpartx -av "$IMG"
fi

echo "=== 挂载根分区 ==="
sudo mkdir -p "$MNT"
sudo mount /dev/mapper/loop0p2 "$MNT"

echo "=== 写入 Wi-Fi 连接配置 ==="
sudo mkdir -p "$MNT/etc/NetworkManager/system-connections"
sudo tee "$MNT/etc/NetworkManager/system-connections/<YOUR_WIFI_SSID>.nmconnection" > /dev/null <<'EOF'
[connection]
id=<YOUR_WIFI_SSID>
uuid=3f2a1b4c-5d6e-7f80-9a1b-2c3d4e5f6071
type=wifi
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=<YOUR_WIFI_SSID>

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=<YOUR_WIFI_PASSWORD>

[ipv4]
method=auto

[ipv6]
method=auto
EOF
sudo chmod 600 "$MNT/etc/NetworkManager/system-connections/<YOUR_WIFI_SSID>.nmconnection"

echo "=== 确认 sshd 开机自启 ==="
sudo ls -la "$MNT/etc/init.d/sshd" 2>/dev/null || echo "sshd init 脚本缺失"
sudo ls "$MNT/etc/runlevels/default/" 2>/dev/null | grep -iE "sshd|network" || echo "检查 runlevel"

echo "=== 配置已写入，内容确认 ==="
sudo cat "$MNT/etc/NetworkManager/system-connections/<YOUR_WIFI_SSID>.nmconnection" | grep -E "ssid|psk|autoconnect"

echo "=== 卸载并清理 ==="
sudo umount "$MNT"
sudo kpartx -d "$IMG"
echo "DONE"
