# wifi.py — 手机 WiFi 图形管理界面

> Redmi Note 5A / postmarketOS，headless 无桌面环境，用 Web 界面实现"鼠标点击选 WiFi"。
> 纯 Python 标准库，零依赖，Python 3.14 实测通过。状态：**已部署并端到端验证**。

## 为什么是 Web 界面

设备没有 X server / 桌面环境，无法跑 Tkinter 这类带鼠标的桌面 GUI。
所以做法是：SSH 连上后启动 `wifi.py`（一个本地 HTTP 服务），
然后在**电脑浏览器**里打开一个网址，用鼠标操作——这就是你要的"简易界面 + 点击选择"。

## 使用（三步）

### 1. SSH 连接设备
```sh
ssh -i D:\pmos-images\sshkey\id_ed25519 user@<手机IP>
```

### 2. 启动服务（需 root，因为 wpa_cli 的 socket 属 root）
```sh
sudo python3 /usr/local/bin/wifi.py 8090
```
后台启动（推荐，关掉 SSH 也不停）：
```sh
sudo nohup python3 /usr/local/bin/wifi.py 8090 >/var/log/wifi-ui.log 2>&1 &
```

### 3. 浏览器打开
```
http://<手机IP>:8090/?t=note5a-wifi
```
（`t=` 是访问令牌，防止局域网其他人乱改 WiFi；可用环境变量 `WIFI_UI_TOKEN` 改。）

## 界面功能

- 自动扫描，列出所有 WiFi：**信号强度条 + dBm 数值 + 加密类型 + 频段**
- 按信号强度从强到弱排序
- 标注「已连接」「已保存」
- 每个网络一个"连接"按钮 + 密码输入框（开放网络免填密码）
- 点击连接后显示"连接中"，约 10 秒后刷新显示结果
- 连接成功自动 `save_config` **写入手机**（重启保留）

## 连接流程（脚本内部）

```
add_network / 复用已有 id
  → set_network ssid / psk（开放网络用 key_mgmt NONE）
  → enable_network + select_network
  → 轮询 status 等 COMPLETED（最多 20 秒）
  → udhcpc 重新拿 IP
  → wpa_cli save_config 持久化到 /etc/wpa_supplicant/wpa-auto.conf
```

**防重复设计**：连接已保存的 SSID 时复用其 network id，不会每次新增条目；
连接失败且是新建网络时才删除，避免污染配置。

## 停止服务

```sh
sudo kill $(cat /run/wifi-ui.pid)
# 或
sudo pkill -f wifi.py
```

## 换 WiFi 后连不上本页怎么办

连新 WiFi 成功后设备 IP 可能变化，浏览器原地址会失效。
重新扫一下设备 IP（路由器后台 / `arp -a` / 串口登录后 `ip addr`），用新 IP 打开即可。
若连错密码导致没连上，设备仍停在原网络，原地址可继续访问，刷新后重试。

## 端口 / 令牌

```sh
# 换端口
sudo python3 /usr/local/bin/wifi.py 9000

# 换令牌
sudo WIFI_UI_TOKEN=mytoken python3 /usr/local/bin/wifi.py
```

## 排障

```sh
cat /var/log/wifi-ui.log              # 启动日志
sudo wpa_cli -i wlan0 status          # 当前连接状态
sudo wpa_cli -i wlan0 list_networks   # 已存网络
cat /etc/wpa_supplicant/wpa-auto.conf # 持久化配置
```

> 若 SSH 因换网断开，用 USB 串口（COM3/115200）登录救回，见 docs/06。

## 部署文件

| 本地 | 设备 | 作用 |
|---|---|---|
| `wifi.py` | `/usr/local/bin/wifi.py` | 主程序 |

未设开机自启（按需手动启动即可，避免常驻 Web 服务的安全面）。
