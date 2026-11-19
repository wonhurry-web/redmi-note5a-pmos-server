#!/usr/bin/env python3
"""SSH 服务器验收脚本：密码登录 + 远端命令执行"""
import sys
import paramiko

HOST = sys.argv[1] if len(sys.argv) > 1 else "<DEVICE_IP>"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 22
USER = sys.argv[3] if len(sys.argv) > 3 else "administrator"
PASS = sys.argv[4] if len(sys.argv) > 4 else "root"

REMOTE = (
    "echo '### identity'; id; whoami; "
    "echo '### os'; cat /etc/os-release | head -2; "
    "echo '### kernel'; uname -a; "
    "echo '### mem'; free -m | head -3; "
    "echo '### disk'; df -h / /data 2>/dev/null | grep -v Filesystem; "
    "echo '### sudo'; sudo id -u; "
    "echo '### ssh'; sshd -V 2>&1 || true"
)

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
try:
    c.connect(HOST, port=PORT, username=USER, password=PASS,
              timeout=15, allow_agent=False, look_for_keys=False)
except Exception as e:
    print(f"[FAIL] 登录失败: {type(e).__name__}: {e}")
    sys.exit(1)

print(f"[OK] 密码登录成功 {USER}@{HOST}:{PORT}")
_, out, err = c.exec_command(REMOTE, timeout=30)
print(out.read().decode(errors="replace").strip())
e = err.read().decode(errors="replace").strip()
if e:
    print("[stderr]", e)

# SFTP 子系统验证
try:
    sftp = c.open_sftp()
    sftp.listdir("/")
    sftp.close()
    print("[OK] SFTP 子系统可用")
except Exception as ex:
    print(f"[WARN] SFTP 不可用: {ex}")

c.close()
print("[OK] 验收通过")
