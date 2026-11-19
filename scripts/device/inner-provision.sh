#!/bin/sh
# ============================================================
# [chroot 内执行] Alpine 服务器软件栈配置
# 路径：/root/inner-provision.sh（镜像内）
# ============================================================
set -e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
SSH_USER="${SSH_USER:-administrator}"

echo "[*] 安装服务栈"
apk add --no-cache nginx python3 git sqlite rsync openssl tmux \
    busybox-extras logrotate iptables >/dev/null

echo "[*] sudo 免密"
printf '%%wheel ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "[*] nginx 站点"
IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
[ -n "$IP" ] || IP="<设备IP>"
mkdir -p /var/www/localhost/htdocs /var/log/nginx /run/nginx

# Alpine 3.24 的默认站点是刻意返回 404 的空壳，需替换为真实站点
cat > /etc/nginx/http.d/default.conf <<'NGXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/localhost/htdocs;
    index index.html index.htm;

    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log warn;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;

    location / {
        try_files $uri $uri/ =404;
    }

    location /status {
        stub_status;
        allow 127.0.0.1;
        allow 192.168.0.0/16;
        deny all;
    }
}
NGXEOF

cat > /var/www/localhost/htdocs/index.html <<HTML
<!doctype html><meta charset="utf-8"><title>note5a-srv</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;background:#0f172a;color:#e2e8f0;padding:48px;line-height:1.7}
h1{font-weight:600;margin:0 0 8px}
code{background:#1e293b;padding:2px 6px;border-radius:4px;color:#7dd3fc}
.muted{color:#94a3b8;font-size:14px}
</style>
<h1>note5a-srv 在线</h1>
<p>Redmi Note 5A · Alpine Linux · aarch64 · chroot</p>
<p>SSH: <code>ssh ${SSH_USER}@${IP}</code></p>
<p class="muted">Kernel <span id="k"></span></p>
HTML

echo "[*] crond 心跳任务"
mkdir -p /var/spool/cron/crontabs
printf '*/5 * * * * echo "$(date) alive" >> /var/log/heartbeat.log\n' \
    > /var/spool/cron/crontabs/root
chmod 600 /var/spool/cron/crontabs/root

echo "[*] 启动 nginx / crond"
mkdir -p /run/nginx /var/log/nginx
nginx -t 2>&1 | grep -q successful && { pgrep -f "nginx: master" >/dev/null || nginx; }
pgrep -f crond >/dev/null || crond -b -l 8

echo "    nginx pid: $(pgrep -f 'nginx: master' | head -1)"
echo "    crond pid: $(pgrep -f crond | head -1)"
echo "    监听端口: $(ss -tlnp 2>/dev/null | awk 'NR>1{print $4}' | tr '\n' ' ')"
echo "[*] 完成"
