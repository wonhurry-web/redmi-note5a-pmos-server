#!/bin/bash
# 经代理完整下载内核包，绕过缓存目录的 root 权限问题
CACHE=/home/administrator/.local/var/pmbootstrap/cache_apk_aarch64
F=$CACHE/linux-postmarketos-qcom-msm89x7-7.1.3-r1.d02eb925.apk
TMP=/tmp/linux-kernel-msm89x7.apk
URL=http://mirror.nura.eco/postmarketos/main/aarch64/linux-postmarketos-qcom-msm89x7-7.1.3-r1.apk
PROXY=http://172.21.208.1:7891
TARGET=45221549
echo "删除 root 拥有的残包..."
sudo rm -f "$F"
rm -f "$TMP"
for i in 1 2 3; do
  echo "代理下载第 $i 轮到 $TMP ..."
  timeout 150 curl -x "$PROXY" -L -o "$TMP" "$URL" 2>/dev/null
  sz=$(stat -c %s "$TMP" 2>/dev/null)
  echo "大小: $sz / $TARGET"
  if [ -n "$sz" ] && [ "$sz" -ge "$TARGET" ]; then
    echo "下载完整，安装到缓存..."
    sudo cp "$TMP" "$F"
    sudo chown root:root "$F"
    echo "缓存最终大小: $(stat -c %s "$F")"
    echo "DOWNLOAD_COMPLETE"
    exit 0
  fi
done
echo "DOWNLOAD_INCOMPLETE"
exit 1
