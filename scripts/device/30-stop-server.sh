#!/system/bin/sh
# ============================================================
# 停止 Linux(chroot) 服务器并卸载镜像
# 用法：su -c "sh /data/linux/stop.sh"
# ============================================================
MNTP=/data/linux/mnt
log() { echo "[*] $*"; }

log "停止 sshd"
pkill -f "/usr/sbin/sshd" 2>/dev/null
sleep 1

log "卸载伪文件系统"
for d in dev/pts dev proc sys; do
    umount "$MNTP/$d" 2>/dev/null
done

log "卸载镜像"
umount "$MNTP" 2>/dev/null
losetup -D 2>/dev/null
log "已停止（镜像数据保留在 /data/linux/rootfs.img）"
