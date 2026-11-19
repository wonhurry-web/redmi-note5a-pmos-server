#!/system/bin/sh
# ============================================================
# 服务器状态面板（设备端 root 执行）
# 用法：su -c "sh /data/linux/status.sh"
# ============================================================
MNTP=/data/linux/mnt
PIDF=/data/linux/supervisor.pid

chk() { if [ "$1" = "1" ]; then echo "OK"; else echo "FAIL"; fi; }
port_open() { awk -v h="$1" '$2 ~ ":"h"$" && $4=="0A" {f=1} END{printf "%d", f+0}' /proc/net/tcp; }

echo "======== note5a-srv 状态 ========"
echo "时间      : $(date '+%Y-%m-%d %H:%M:%S')"
echo "运行时长  : $(uptime | sed 's/.*up //;s/,.*//')"

M=0; grep -q " $MNTP " /proc/mounts && M=1
echo "镜像挂载  : $(chk $M)"
echo "SSH :22   : $(chk $(port_open 0016))"
echo "HTTP:80   : $(chk $(port_open 0050))"

IP=$(ip addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
echo "Wi-Fi IP  : ${IP:-<未连接>}"

S=0; [ -f "$PIDF" ] && [ -d "/proc/$(cat $PIDF 2>/dev/null)" ] && S=1
echo "守护进程  : $(chk $S) (pid $(cat $PIDF 2>/dev/null))"

if [ "$M" = "1" ]; then
    echo "SELinux   : $(getenforce)"
    echo "-------------- 系统资源 --------------"
    chroot "$MNTP" /bin/sh -c '
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      echo "发行版    : $(cat /etc/alpine-release 2>/dev/null) Alpine"
      echo "内核      : $(uname -r) $(uname -m)"
      free -m | awk "/Mem:/{printf \"内存      : %sM / %sM 已用 (%.0f%%)\\n\", \$3, \$2, \$3*100/\$2}"
      df -h / | awk "NR==2{printf \"磁盘      : %s / %s 已用 (%s)\\n\", \$3, \$2, \$5}"
      SVC=""
      for s in sshd nginx crond; do
        if pgrep -x "$s" >/dev/null 2>&1; then SVC="$SVC $s:up"; else SVC="$SVC $s:down"; fi
      done
      echo "服务      :$SVC"
    '
fi
echo "=================================="
