#!/bin/bash
# 断点续传补全 postmarketOS 内核包（镜像站慢/易中断）
F=/home/administrator/.local/var/pmbootstrap/cache_apk_aarch64/linux-postmarketos-qcom-msm89x7-7.1.3-r1.d02eb925.apk
URL=http://mirror.nura.eco/postmarketos/main/aarch64/linux-postmarketos-qcom-msm89x7-7.1.3-r1.apk
TARGET=45221549
echo "残包字节数: $(stat -c %s "$F" 2>/dev/null)"
for i in 1 2 3 4 5 6 7 8; do
  timeout 90 curl -L -C - -o "$F" "$URL" 2>/dev/null
  sz=$(stat -c %s "$F" 2>/dev/null)
  echo "第 $i 轮后大小: $sz / $TARGET"
  if [ -n "$sz" ] && [ "$sz" -ge "$TARGET" ]; then
    echo "DOWNLOAD_COMPLETE"
    exit 0
  fi
done
echo "DOWNLOAD_INCOMPLETE"
exit 1
