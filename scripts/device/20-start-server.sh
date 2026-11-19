#!/system/bin/sh
# ============================================================
# 启动/巡检 Linux(chroot) 服务器
# 逐项确保：镜像挂载 -> 伪文件系统 -> sshd -> nginx -> crond
# 幂等 + 仅在发生动作时记录日志（供 supervisor 每 20s 调用）
# 用法：su -c "sh /data/linux/start.sh"
# ============================================================
IMG=/data/linux/rootfs.img
MNTP=/data/linux/mnt
LOG=/data/linux/server.log
CB="export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin;"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

if [ -f "$LOG" ] && [ $(wc -c < "$LOG" 2>/dev/null || echo 0) -gt 262144 ]; then
    mv -f "$LOG" "$LOG.1"
fi

port_open() { awk -v h="$1" '$2 ~ ":"h"$" && $4=="0A" {f=1} END{exit !f}' /proc/net/tcp; }

# ---------- 0. 等 boot 完成 ----------
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 60 ]; do
    sleep 2; i=$((i+1))
done

# SELinux 必须 Permissive（/data 下 musl 二进制 exec 依赖）
if [ "$(getenforce)" != "Permissive" ]; then
    setenforce 0 2>/dev/null
    log "SELinux -> $(getenforce)"
fi

# ---------- 1. 镜像挂载 ----------
if grep -q " $MNTP " /proc/mounts; then
    :
else
    ok=0
    for try in 1 2 3 4 5 6 7 8 9 10; do
        [ -e /dev/block/loop0 ] || { sleep 2; continue; }
        LOOP=$(losetup -f --show "$IMG" 2>>"$LOG")
        if [ -n "$LOOP" ]; then
            ERR=$(mount -t ext4 "$LOOP" "$MNTP" 2>&1)
            if [ $? -eq 0 ] && grep -q " $MNTP " /proc/mounts; then
                log "挂载成功 $LOOP -> $MNTP (第 $try 次)"
                ok=1; break
            fi
            log "mount 失败[$try]: $ERR"
            losetup -d "$LOOP" 2>/dev/null
        else
            log "losetup 失败[$try]"
        fi
        sleep 3
    done
    if [ "$ok" != "1" ]; then
        log "本轮挂载失败，等下一轮"
        exit 1
    fi
fi

# ---------- 2. 伪文件系统 ----------
for d in dev proc sys; do
    grep -q " $MNTP/$d " /proc/mounts || mount --bind "/$d" "$MNTP/$d" 2>/dev/null
done
mkdir -p "$MNTP/run/sshd" "$MNTP/run/nginx" "$MNTP/dev/pts"

# ---------- 3. sshd ----------
if port_open 0016; then
    :
else
    printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > "$MNTP/etc/resolv.conf"
    chroot "$MNTP" /bin/sh -c "$CB /usr/sbin/sshd" 2>>"$LOG"
    sleep 2
    if port_open 0016; then
        IP=$(ip addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
        log "sshd 已启动 -> ssh administrator@${IP:-<设备IP>}"
    else
        log "sshd 启动失败"
    fi
fi

# ---------- 4. nginx / crond ----------
# 用端口判定，不用 pgrep -f（会匹配到自身命令行）
if ! port_open 0050; then
    chroot "$MNTP" /bin/sh -c "$CB nginx" 2>>"$LOG"
    sleep 1
    port_open 0050 && log "nginx 已启动 (:80)" || log "nginx 启动失败"
fi
chroot "$MNTP" /bin/sh -c "$CB pgrep -x crond >/dev/null 2>&1 || crond -b -l 8" 2>/dev/null
