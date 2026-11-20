# wifi.py — Xshell 终端里的 WiFi 管理界面（TUI）

> Redmi Note 5A / postmarketOS，SSH 连上后直接运行，**无需浏览器**。
> 用 curses 绘制终端界面，方向键/数字键/鼠标选择，回车连接，成功后存入手机。
> 纯 Python 标准库，零依赖。状态：**已部署并端到端验证**。

## 使用（SSH 连上后，三步）

### 1. SSH 连接设备
```sh
ssh -i <你的私钥> user@<手机IP>
```

### 2. 运行（需 root，因为 wpa_cli 的控制 socket 属 root）
```sh
sudo python3 /usr/local/bin/wifi.py
```
（会提示输一次 user 的 sudo 密码。）

### 3. 在终端里操作
```
=== WiFi Manager - Redmi Note 5A (postmarketOS) ===
Up/Down/1-9/mouse: select | Enter: connect | r: rescan | q: quit
------------------------------------------------------------
 #  SIG  SSID                     ENC    BAND STATUS
 1> #### GZHY                     WPA2   2.4G CURRENT,SAVED
 2  ###. HYQA                     WPA2   2.4G
 3  ###. Guest_2.4GHz             OPEN   2.4G
...
> Ready. 16 networks found.
```

| 按键 | 作用 |
|---|---|
| `↑` / `↓` | 移动光标 |
| `1`–`9` | 直接选中第 N 行（最可靠，任何终端都支持） |
| 鼠标点击 / 滚轮 | 选中（需在 Xshell 开启鼠标报告，见下） |
| `Enter` | 连接高亮的网络；WPA 网络会提示输入密码 |
| `r` | 重新扫描 |
| `q` / `Esc` | 退出 |

密码输入时不回显，直接输入回车即可；留空取消。

## Xshell 开启鼠标（可选）

方向键和数字键默认就能用。要用鼠标点选：
Xshell → 会话属性 → **终端** → 勾选「启用鼠标报告」/「发送鼠标事件」，
重连后即可点击列表行选中。

## 连接流程（脚本内部）

```
list_networks 找同 SSID id（有则复用，不新建重复条目）
  → set_network ssid / psk（开放网络用 key_mgmt NONE）
  → enable_network + select_network
  → 轮询 status 等 COMPLETED（最多 20 秒）
  → killall udhcpc + udhcpc 重拿 IP
  → wpa_cli save_config 写入 /etc/wpa_supplicant/wpa-auto.conf（重启保留）
```

- 连接成功：底部显示 `OK: Connected & saved to phone. IP: x.x.x.x`
- 连接失败：显示原因；若是新建网络则自动删除，若是已存网络则保留原配置可重试
- 换网后 IP 若变化，SSH 会断——用新 IP 重连，或用 USB 串口（COM3/115200）救回（见 docs/06）

## 文件

| 本地 | 设备 | 作用 |
|---|---|---|
| `wifi.py` | `/usr/local/bin/wifi.py` | TUI 主程序（当前使用） |
| `wifi-web.py` | — | 早期 Web 版，归档备查（未部署） |

未设开机自启：按需手动运行，避免常驻进程。

## 排障

```sh
python3 -c "import curses; print(curses.version)"   # 确认 curses 可用（实测 2.2）
sudo wpa_cli -i wlan0 status                        # 当前连接
sudo wpa_cli -i wlan0 list_networks                 # 已存网络
cat /etc/wpa_supplicant/wpa-auto.conf               # 持久化配置
```

> 若提示 `TERM` 未设置或界面乱码，在 Xshell 会话属性里把终端类型设为 `xterm-256color`；脚本已内置兜底。

## 验证记录

- pty 抓屏：标题/列头/16 个 WiFi/信号条/加密类型/CURRENT,SAVED 标注全部正确 ✅
- 隐藏 SSID 乱码已过滤 ✅
- 数字键/方向键/q 退出交互正常 ✅
- 连接链路（复用 id、save_config、udhcpc）已通过 Web 版端到端验证，TUI 版共用同一逻辑 ✅
