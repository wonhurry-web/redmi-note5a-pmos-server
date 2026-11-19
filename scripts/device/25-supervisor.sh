#!/system/bin/sh
# ============================================================
# 守护进程：常驻，确保 chroot 服务器与网络始终在线
#  - 20s 心跳：镜像掉挂 / sshd|nginx 崩溃 都会自动拉起
#  - Wi-Fi 守护：连续 2 个周期无 IP 则 toggle 无线（Android 重启后
#    偶发「已保存网络未自动关联」，toggle 可恢复）
#  - 单实例保护
# 用法：su -c "setsid sh /data/linux/supervisor.sh >/dev/null 2>&1 &"
# ============================================================
PIDF=/data/linux/supervisor.pid
LOG=/data/linux/supervisor.log

# 单实例保护
if [ -f "$PIDF" ]; then
    OLD=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$OLD" ] && [ -d "/proc/$OLD" ] && grep -q supervisor "/proc/$OLD/cmdline" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$PIDF"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
if [ -f "$LOG" ] && [ $(wc -c < "$LOG" 2>/dev/null || echo 0) -gt 131072 ]; then
    mv -f "$LOG" "$LOG.1"
fi

log "supervisor 启动 pid=$$"
WIFI_FAIL=0

while true; do
    sh /data/linux/start.sh

    # Wi-Fi 自愈
    if ip addr show wlan0 2>/dev/null | grep -q "inet "; then
        WIFI_FAIL=0
    else
        WIFI_FAIL=$((WIFI_FAIL + 1))
        log "wlan0 无 IP (第 $WIFI_FAIL 次)"
        if [ $WIFI_FAIL -ge 2 ]; then
            log "toggle Wi-Fi 尝试恢复"
            svc wifi disable 2>/dev/null
            sleep 4
            svc wifi enable 2>/dev/null
            WIFI_FAIL=0
        fi
    fi

    sleep 20
done
