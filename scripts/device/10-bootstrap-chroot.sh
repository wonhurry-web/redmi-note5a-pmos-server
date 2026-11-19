#!/system/bin/sh
# ============================================================
# Redmi Note 5A (ugglite) -> Linux 服务器 引导安装脚本
# 在设备上以 root 执行：adb shell su -c "sh /data/local/tmp/10-bootstrap-chroot.sh"
# 作用：创建 ext4 镜像 -> 挂载 -> 解包 Alpine -> chroot 内配置 SSH 服务器
# 幂等：可重复执行，已存在的镜像/软件包不会重复创建
# ============================================================
set -e

IMG=/data/linux/rootfs.img
MNTP=/data/linux/mnt
SIZE_MB=3072
SSH_USER="${SSH_USER:-administrator}"
SSH_PASS="${SSH_PASS:-root}"
SSH_PORT="${SSH_PORT:-22}"
ROOTFS_TAR=/data/local/tmp/alpine.tar.gz

log() { echo "[*] $*"; }
die() { echo "[!] $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "需要 root 权限"

# ---------- 1. SELinux ----------
log "SELinux -> Permissive（chroot 执行 /data 下二进制的前提）"
setenforce 0 2>/dev/null || true
log "当前状态: $(getenforce)"

# ---------- 2. 镜像 ----------
mkdir -p /data/linux "$MNTP"
if [ ! -f "$IMG" ]; then
    log "创建 ${SIZE_MB}MB 稀疏 ext4 镜像: $IMG"
    dd if=/dev/zero of="$IMG" bs=1M count=0 seek=$SIZE_MB 2>/dev/null
    mke2fs -t ext4 -F -q -L pmos-srv "$IMG" || die "mke2fs 失败"
else
    log "镜像已存在，复用: $IMG"
fi
log "镜像占用: $(du -h "$IMG" | awk '{print $1}') / 名义 $((SIZE_MB/1024))G"

# ---------- 3. 挂载 ----------
if mountpoint -q "$MNTP" 2>/dev/null || grep -q " $MNTP " /proc/mounts; then
    log "已挂载: $MNTP"
else
    LOOP=$(losetup -f --show "$IMG") || die "losetup 失败"
    log "loop 设备: $LOOP"
    mount -t ext4 "$LOOP" "$MNTP" || die "mount 失败"
    log "挂载成功: $LOOP -> $MNTP"
fi

# ---------- 4. 解包 rootfs ----------
if [ ! -f "$MNTP/etc/alpine-release" ]; then
    [ -f "$ROOTFS_TAR" ] || die "缺少 $ROOTFS_TAR，请先 adb push"
    log "解包 Alpine rootfs 到 $MNTP"
    tar -xzf "$ROOTFS_TAR" -C "$MNTP" || die "解包失败"
else
    log "rootfs 已存在: Alpine $(cat "$MNTP/etc/alpine-release")"
fi

# ---------- 5. 基础文件 ----------
log "写入 DNS 与 apk 镜像源"
cat > "$MNTP/etc/resolv.conf" <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver <GATEWAY_IP>
EOF

# 国内镜像优先，失败自动回落官方源
cat > "$MNTP/etc/apk/repositories" <<'EOF'
https://mirrors.aliyun.com/alpine/v3.24/main
https://mirrors.aliyun.com/alpine/v3.24/community
EOF

cat > "$MNTP/etc/hostname" <<'EOF'
note5a-srv
EOF

cat > "$MNTP/etc/hosts" <<'EOF'
127.0.0.1   localhost localhost.localdomain
127.0.1.1   note5a-srv note5a-srv.local
::1         localhost
EOF

# ---------- 6. 进入 chroot 配置 ----------
log "挂载伪文件系统"
for d in dev proc sys; do
    grep -q " $MNTP/$d " /proc/mounts || mount --bind /$d "$MNTP/$d" 2>/dev/null || true
done

log "chroot 内执行配置（首次需下载软件包，约 2-5 分钟）"
chroot "$MNTP" /bin/sh -c "
set -e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root

apk update >/dev/null 2>&1 || {
    echo '[*] 阿里云源不可用，回落官方源'
    printf '%s\n' 'https://dl-cdn.alpinelinux.org/alpine/v3.24/main' \
                  'https://dl-cdn.alpinelinux.org/alpine/v3.24/community' \
                  > /etc/apk/repositories
    apk update
}

echo '[*] 安装服务器软件栈'
apk add --no-cache openssh openssh-server bash shadow sudo coreutils \
    procps htop nano curl wget tzdata util-linux ca-certificates \
    iproute2 nmap-ncat >/dev/null

echo '[*] 时区'
cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo 'Asia/Shanghai' > /etc/timezone

echo '[*] 创建用户 ${SSH_USER}'
id ${SSH_USER} >/dev/null 2>&1 || adduser -D -s /bin/bash ${SSH_USER}
echo '${SSH_USER}:${SSH_PASS}' | chpasswd
echo 'root:${SSH_PASS}' | chpasswd

echo '[*] sudo 免密（wheel 组）'
addgroup ${SSH_USER} wheel 2>/dev/null || true
printf '%%wheel ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# 兼容 Windows 账号首字母大写：额外提供 Administrator 别名（同 UID 1000）
ALIAS=Administrator
if [ "\${SSH_USER}" != "\${ALIAS}" ]; then
    UID0=\$(id -u \${SSH_USER})
    GID0=\$(id -g \${SSH_USER})
    grep -q "^\${ALIAS}:" /etc/passwd || \
        echo "\${ALIAS}:x:\${UID0}:\${GID0}:\${ALIAS}:/home/\${SSH_USER}:/bin/bash" >> /etc/passwd
    grep -q "^\${ALIAS}:" /etc/shadow || \
        sed -n "s/^\${SSH_USER}:/ \${ALIAS}:/p" /etc/shadow | sed "s/^ //" >> /etc/shadow
    echo "[*] 已添加登录别名 \${ALIAS}"
fi

echo '[*] SSH 主机密钥'
ssh-keygen -A >/dev/null

echo '[*] sshd 配置'
mkdir -p /run/sshd /root/.ssh /home/${SSH_USER}/.ssh
chmod 700 /root/.ssh /home/${SSH_USER}/.ssh
cat > /etc/ssh/sshd_config <<SSHDEOF
Port ${SSH_PORT}
AddressFamily any
ListenAddress 0.0.0.0
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
PubkeyAuthentication yes
UseDNS no
X11Forwarding no
AllowTcpForwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
Subsystem sftp /usr/lib/ssh/sftp-server
SSHDEOF
chmod 600 /etc/ssh/sshd_config

echo '[*] 校验配置'
/usr/sbin/sshd -t && echo '    sshd_config OK'
" || die "chroot 配置失败"

log "完成基础配置"
