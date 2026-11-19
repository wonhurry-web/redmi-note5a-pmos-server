#!/system/bin/sh
# ============================================================
# 服务器软件栈补齐 + 开机自启注册（设备端 root 执行）
# 用法：su -c "sh /data/local/tmp/40-provision.sh"
# 依赖：/data/local/tmp/inner-provision.sh
# ============================================================
set -e
MNTP=/data/linux/mnt
log() { echo "[*] $*"; }

[ "$(id -u)" = "0" ] || { echo "[!] 需要 root"; exit 1; }
grep -q " $MNTP " /proc/mounts || { echo "[!] 镜像未挂载，先执行 sh /data/linux/start.sh"; exit 1; }

# ---------- A. 镜像内配置 ----------
log "拷入内层脚本并执行"
cp /data/local/tmp/inner-provision.sh "$MNTP/root/inner-provision.sh"
chmod 755 "$MNTP/root/inner-provision.sh"
chroot "$MNTP" /bin/sh /root/inner-provision.sh || { echo "[!] 内层配置失败"; exit 1; }

# ---------- B. 开机自启（Magisk late_start service） ----------
log "注册 Magisk 开机自启"
mkdir -p /data/adb/service.d
cat > /data/adb/service.d/zz-linux-server.sh <<'BOOTEOF'
#!/system/bin/sh
# Magisk late_start service：开机拉起 chroot Linux 服务器
(
  sleep 10                      # 等 Wi-Fi / 存储子系统就绪
  sh /data/linux/start.sh
) &
BOOTEOF
chmod 755 /data/adb/service.d/zz-linux-server.sh
log "已写入 /data/adb/service.d/zz-linux-server.sh"

log "完成"
