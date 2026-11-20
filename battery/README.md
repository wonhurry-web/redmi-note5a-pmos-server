# 电池充电保护（80% 停充 / 40% 恢复）

> 部署时间：2026-11-20 · 状态：**已上线运行**
> 设备：Redmi Note 5A / postmarketOS 主线内核 7.1.3-msm89x7
> 充电芯片：TI **bq25601**（I2C 0x6b）；电量计：TI **bq27426**

## 背景

电池严重老化：设计容量 3080mAh，实测满充仅 2402mAh（约 78%）。长期满电浮充会进一步加速老化。本方案让电池充到 80% 即停止充电，掉到 40% 再恢复，避免长期处于满电状态。

## 可行性原理（关键）

设备**没有** `charging_enabled` 这类开关节点，但有可写的 `constant_charge_voltage`（恒压上限）。

bq25601 是降压充电芯片，恒压阶段把电池电压维持在 CV 值。当电池电压 **高于** CV 时，芯片判定充电终点，停止充电。驱动把 CV 钳制在 **3856000 µV（3.856V）下限**，而电池工作电压约 3.4–4.35V，因此把 CV 拉到下限即可可靠停充；写回 4208000（4.208V）恢复满充。

> 为什么不用 `input_current_limit`：驱动把它钳制在最小 100000 µA（100mA），无法真正断开，只能减小电流。故 CV 方案是唯一可靠的软件断充手段。

| 节点 | 用途 | 可写范围（实测钳制） |
|---|---|---|
| `bq256xx-charger/constant_charge_voltage` | 恒压上限 → 停充控制 | 下限 3856000，正常 4208000 |
| `bq27426-0/capacity` | 电量百分比（判断依据） | 只读 |
| `bq256xx-charger/online` | 是否插入充电器 | 只读 |

## 行为逻辑

```
插入充电器且 capacity >= 80%  → CV=3856000（停充），state=hold
插入充电器且 capacity <= 40%  → CV=4208000（恢复充电），state=charging
拔掉充电器                    → 不动作
守护重启/开机                 → 按当前电量自动推断状态，不会卡在错误状态
```

检查周期 60 秒，开销可忽略。状态文件 `/run/charge-guard.state`，日志 `/var/log/charge-guard.log`。

## power-path 说明

bq25601 带 power-path 管理：插着 USB 时系统负载优先由 USB 供电。因此停充后电池电量**通常保持在 80% 不下降**（最理想的保护状态，电池既不充也不放）。若系统实际从电池取电，电量会缓慢下降，到 40% 自动恢复充电，形成 40%↔80% 循环。两种情况都达到保护目的。

## 部署内容

| 文件 | 设备路径 | 作用 |
|---|---|---|
| `charge-guard.sh` | `/usr/local/bin/charge-guard` | 守护进程主体 |
| `85-charge-guard.start` | `/etc/local.d/85-charge-guard.start` | 开机自启（编号 85，在省电脚本后、Docker 前） |

```sh
# 手动启停
sudo /etc/local.d/85-charge-guard.start          # 启动（幂等）
sudo kill $(cat /run/charge-guard.pid)           # 停止

# 观察
cat /run/charge-guard.state                       # charging / hold
cat /sys/class/power_supply/bq256xx-charger/constant_charge_voltage
tail -f /var/log/charge-guard.log
```

## 调整阈值

编辑 `/usr/local/bin/charge-guard` 顶部变量后重启：

```sh
STOP=80       # 停充电量
RESUME=40     # 恢复电量
INTERVAL=60   # 检查周期(秒)
```

建议 STOP 不超过 90（锂电长期高电压仍有压力），RESUME 不低于 20（避免过放）。

## 验证记录

- 100% 满电前台运行：CV 4208000 → 3856000，state=hold，日志正确 ✅
- 后台守护运行：PID 正常、幂等启动（重复执行只保留 1 实例）✅
- 一个完整 60s 周期：CV/state 稳定，无误动作 ✅
- 恢复分支（CV 写回 4208000）：与停充分支对称，set_cv 函数已验证；满电场景不触发

> 局限：满电插电状态下无法立即展示 40%↔80% 完整循环，需电池实际放电后观察。

## 风险与注意

- CV 写入是硬件合法范围（驱动自动钳制），不会损坏充电芯片或电池
- 守护脚本被杀或设备重启后，开机脚本会按当前电量重新判定，不会让电池卡在"永久停充"
- 若长时间拔电存放，电量低于 40% 时插回充电器会自动恢复充电
