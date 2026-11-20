# 配置模板说明

这些是设备上实际使用配置的**脱敏版本**，复制后把 `<...>` 占位符替换为自己的值（见根 README「脱敏说明」）。

| 模板 | 部署到设备路径 | 用途 |
|---|---|---|
| `50-wifi.start` | `/etc/local.d/50-wifi.start` | 开机自动连 Wi-Fi（同时生成 wpa-auto.conf） |
| `60-timesync.start` | `/etc/local.d/60-timesync.start` | NTP 对时 |
| `70-dashboard.start` | `/etc/local.d/70-dashboard.start` | 仪表盘自启 |
| `80-pwrkey.start` | `/etc/local.d/80-pwrkey.start` | 电源键亮灭屏守护进程 |
| `90-rproc-off.start` | `/etc/local.d/90-rproc-off.start` | 省电：停掉无用 modem/DSP 协处理器（保留 Wi-Fi）。仅 headless 不用移动数据时部署 |
| `wpa-auto.conf.example` | `/etc/wpa_supplicant/wpa-auto.conf` | Wi-Fi 凭据（若不用 50-wifi.start 自动生成） |
| `pmbootstrap_v3.cfg.example` | `~/.config/pmbootstrap_v3.cfg`（构建主机） | pmbootstrap 构建配置 |

所有 `.start` 文件需 `chmod +x`，属主 root。

部署示例：

```bash
scp config/50-wifi.start user@<DEVICE_IP>:/tmp/
ssh user@<DEVICE_IP>
sudo cp /tmp/50-wifi.start /etc/local.d/ && sudo chmod +x /etc/local.d/50-wifi.start
```
