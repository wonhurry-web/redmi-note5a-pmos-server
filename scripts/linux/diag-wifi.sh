#!/bin/bash
# 诊断镜像内网络服务配置
IMG=${IMG:-/path/to/qcom-msm89x7.img}   # 镜像路径，可通过环境变量 IMG= 覆盖
MNT=/tmp/pmos-diag
sudo kpartx -av "$IMG" >/dev/null 2>&1
sudo mkdir -p "$MNT"
sudo mount /dev/mapper/loop0p2 "$MNT" 2>/dev/null

echo "=== default runlevel 服务 ==="
sudo ls "$MNT/etc/runlevels/default/" 2>/dev/null
echo "=== NetworkManager init 脚本是否存在 ==="
sudo ls "$MNT/etc/init.d/NetworkManager" "$MNT/etc/init.d/networkmanager" 2>/dev/null || echo "无 NetworkManager init"
echo "=== wpa_supplicant init ==="
sudo ls "$MNT/etc/init.d/"*wpa* 2>/dev/null || echo "无 wpa init"
echo "=== 已装网络包 ==="
sudo cat "$MNT/lib/apk/db/installed" 2>/dev/null | grep -E "^P:(networkmanager|wpa_supplicant|openssh|postmarketos-base)" | head
echo "=== rc.conf / 网络配置 ==="
sudo cat "$MNT/etc/conf.d/network" 2>/dev/null | head
echo "=== Wi-Fi 配置内容 ==="
sudo cat "$MNT/etc/NetworkManager/system-connections/<YOUR_WIFI_SSID>.nmconnection" 2>/dev/null | head -20

sudo umount "$MNT" 2>/dev/null
sudo kpartx -d "$IMG" >/dev/null 2>&1
echo DONE
