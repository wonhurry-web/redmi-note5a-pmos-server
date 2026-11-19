#!/usr/bin/env bash
# ============================================================================
# build-pmos.sh —— 在 Linux / WSL2 上构建 postmarketOS（无头服务器版）
# 目标设备: Xiaomi Redmi Note 5A (ugglite) -> 通用端口 device=msm89x7
#
# 本脚本已在真实环境验证，修复了以下坑：
#   1. pip 上 pmbootstrap 版本被 yanked -> 改用 git 源码安装（新地址 gitlab.postmarketos.org）
#   2. PEP 668 限制 -> 用 venv
#   3. pmbootstrap init 逐项交互 -> 预写 ~/.config/pmbootstrap.cfg + 连续回车应答
#   4. 新版 fastboot 无 dump_image/fetch -> 备份走 adb pull（见 windows 脚本）
#
# 用法:
#   chmod +x build-pmos.sh
#   ./build-pmos.sh              # 初始化 + 构建 + 导出
# ============================================================================
set -euo pipefail

SUDO_PASS="${SUDO_PASS:-root}"   # WSL 用户密码
DEVICE="qcom-msm89x7"                # pmbootstrap 要求 vendor-codename 完整格式
UI="none"
EXTRA_PKGS="openssh,networkmanager,avahi,docker,tmux,htop,nano,curl,wget"
HOSTNAME="note5a-srv"
TIMEZONE="Asia/Shanghai"
PMB_DIR="$HOME/pmbootstrap"
VENV="$HOME/pmb-venv"

echo "============================================================"
echo " postmarketOS build (device=$DEVICE ui=$UI)"
echo "============================================================"

# ---------- 1. 依赖 ----------
echo "[1/6] apt 依赖..."
export DEBIAN_FRONTEND=noninteractive
echo "$SUDO_PASS" | sudo -S apt-get update -qq
echo "$SUDO_PASS" | sudo -S apt-get install -y -qq \
    python3 python3-pip python3-venv git kpartx adb fastboot >/dev/null

# ---------- 2. pmbootstrap 源码 ----------
echo "[2/6] 安装 pmbootstrap (源码, venv)..."
if [ ! -f "$PMB_DIR/pmbootstrap.py" ]; then
    git clone --depth 1 https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git "$PMB_DIR"
fi
python3 -m venv --system-site-packages "$VENV" 2>/dev/null || true
# shellcheck disable=SC1090
source "$VENV/bin/activate"
pip install -q -e "$PMB_DIR"
PMB="python3 $PMB_DIR/pmbootstrap.py"
$PMB --version

# ---------- 3. 预写配置 ----------
echo "[3/6] 写入 pmbootstrap 配置..."
mkdir -p "$HOME/.config"
cat > "$HOME/.config/pmbootstrap.cfg" <<EOF
[pmbootstrap]
build_default_device_arch = True
ccache_size = 5G
device = $DEVICE
extra_packages = $EXTRA_PKGS
hostname = $HOSTNAME
is_default_channel = False
jobs = 4
kernel = edge
locale = C.UTF-8
service_manager = openrc
ssh_keys = False
sudo_timer = True
timezone = $TIMEZONE
ui = $UI
work = $HOME/.local/var/pmbootstrap

[providers]

[mirrors]
EOF

# ---------- 4. init ----------
echo "[4/6] pmbootstrap init (连续回车应答，配置已预写)..."
printf '\n%.0s' {1..25} | $PMB init --shallow-initial-clone

# ---------- 5. 构建 ----------
echo "[5/6] 构建镜像 pmbootstrap install..."
if ! $PMB install; then
    echo "构建失败，清理缓存后重试..."
    $PMB zap -hc
    $PMB install
fi

# ---------- 6. 导出 ----------
echo "[6/6] 导出镜像..."
$PMB export
echo "镜像导出到 /tmp/postmarketOS-export/"
echo "下一步: Windows 侧 fastboot 刷机（先 lk2nd，再 rootfs）。"
