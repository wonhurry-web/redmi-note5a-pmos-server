# 09 · 添加 / 管理 Wi-Fi 网络

> 适用：Redmi Note 5A / postmarketOS，wpa_supplicant + udhcpc 方案
> 更新：2026-11-20（修复了自启脚本覆盖配置文件的坑）

## 先理解现状（重要）

设备的 Wi-Fi 由两个文件管：

| 文件 | 作用 |
|---|---|
| `/etc/wpa_supplicant/wpa-auto.conf` | 存放所有已知 WiFi 的 SSID/密码（可多个 network 块） |
| `/etc/local.d/50-wifi.start` | 开机自启：起 wlan0、启动 wpa_supplicant、udhcpc 拿 IP |

**历史坑（已修复）**：旧版 `50-wifi.start` 每次开机都用 heredoc **覆盖** `wpa-auto.conf`，
只写死一个网络。所以往配置文件里加的 WiFi 重启后会丢失。
现已改为「仅当配置不存在时才生成默认模板，已存在则绝不覆盖」——
现在往 `wpa-auto.conf` 加网络是持久的。

另注：`wpa_cli` 的控制 socket `/run/wpa_supplicant/wlan0` 属 root，
**所有 wpa_cli 命令都要加 sudo**，否则无输出。

---

## 方法一：永久添加（写入配置，重启保留）★推荐

直接编辑 `/etc/wpa_supplicant/wpa-auto.conf`，追加一个 `network` 块：

```sh
sudo vi /etc/wpa_supplicant/wpa-auto.conf
```

```
ctrl_interface=/var/run/wpa_supplicant
update_config=1
country=CN

network={
    ssid="GZHY"
    psk="原密码"
    key_mgmt=WPA-PSK
}

# 新增的第二个 WiFi
network={
    ssid="你的新WiFi名"
    psk="你的新WiFi密码"
    key_mgmt=WPA-PSK
    priority=2        # 可选：数字越大越优先；不写则由信号强度自动选
}
```

保存后让 wpa_supplicant 重读配置（无需重启）：

```sh
sudo wpa_cli -i wlan0 reconfigure
```

验证：

```sh
sudo wpa_cli -i wlan0 list_networks      # 应看到两个网络
sudo wpa_cli -i wlan0 status             # 看当前连的是哪个
```

wpa_supplicant 会自动扫描，连接信号最好的已配置网络；`priority` 可强制优先某个。
重启后配置不丢（自启脚本已改，不会覆盖）。

---

## 方法二：临时切换（不写配置文件，重启丢失）

适合临时连一下某个 WiFi。用 wpa_cli 直接操作：

```sh
# 1. 新增网络，拿到 id（如 1）
sudo wpa_cli -i wlan0 add_network

# 2. 设置 SSID 和密码（注意 SSID 要带英文双引号）
sudo wpa_cli -i wlan0 set_network 1 ssid '"你的新WiFi名"'
sudo wpa_cli -i wlan0 set_network 1 psk  '"你的新WiFi密码"'

# 3. 启用并连接
sudo wpa_cli -i wlan0 enable_network 1
sudo wpa_cli -i wlan0 select_network 1

# 4. 重新拿 IP（换了网络通常需要）
sudo killall udhcpc
sudo udhcpc -i wlan0 -n

# 5. 确认
sudo wpa_cli -i wlan0 status
ip -4 addr show wlan0
```

> 注意：`ssid` / `psk` 的值要在原本的引号外**再包一层单引号**，
> 即 `'"xxx"'`，让 wpa_cli 收到带引号的字符串——这是 wpa_cli 的语法要求。

切回原来的网络：

```sh
sudo wpa_cli -i wlan0 select_network 0
sudo killall udhcpc && sudo udhcpc -i wlan0 -n
```

**持久化临时配置**（如果临时加的网络想保留）：

```sh
sudo wpa_cli -i wlan0 save_config
```

这会把当前所有网络写回 `wpa-auto.conf`（因为配置里开了 `update_config=1`）。

---

## 开放网络（无密码）

```sh
network={
    ssid="开放WiFi名"
    key_mgmt=NONE
}
```

wpa_cli 临时方式：`set_network 1 key_mgmt NONE`（不设 psk）。

---

## 隐藏 SSID

在 network 块里加 `scan_ssid=1`：

```
network={
    ssid="隐藏WiFi名"
    psk="密码"
    scan_ssid=1
}
```

---

## 故障排查

```sh
# 扫描看看能不能搜到目标 WiFi
sudo wpa_cli -i wlan0 scan
sudo wpa_cli -i wlan0 scan_results

# 看认证失败原因
sudo wpa_cli -i wlan0 status
tail -30 /var/log/wifiauto.log

# 完全重启 Wi-Fi（会短暂断网）
sudo killall wpa_supplicant udhcpc
sudo ip link set wlan0 down && sudo ip link set wlan0 up
sudo wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa-auto.conf -D nl80211
sudo udhcpc -i wlan0 -n
```

> 断网应急：SSH 断了就用 USB 串口（COM3 / 115200）登录，见 docs/06。

---

## 附：改动记录

2026-11-20 修改了 `config/50-wifi.start`（同步到设备 `/etc/local.d/50-wifi.start`）：
把无条件的 `cat > "$WPA_CONF"` 改为 `if [ ! -s "$WPA_CONF" ]; then ... fi`，
使已存在的配置文件不再被覆盖。原脚本备份在设备 `/etc/local.d/50-wifi.start.bak-wifi2`。
