#!/bin/sh
# 电池充电保护守护：充到 STOP% 停止充电，掉到 RESUME% 再恢复。
# 设备：Redmi Note 5A / postmarketOS，充电芯片 TI bq25601，电量计 bq27426。
#
# 原理（不要改成 input_current_limit 方案）：
#   bq25601 的 constant_charge_voltage(CV) 是恒压上限，驱动钳制范围下限=3856000uV。
#   当电池电压高于 CV 时，充电芯片判定已到终点，停止充电 → 等效软件断开充电。
#   把 CV 写回 4208000(4.208V) 即恢复正常满充。
#   （input_current_limit 下限只能到 100000，无法真正断开，故不用。）
#
# 注意 power-path：插着 USB 时系统优先由 USB 供电，停充后电池电量通常停在 STOP%
#   不下降（理想保护状态）；若系统改由电池供电，电量会下降，到 RESUME% 自动恢复充电。

CAP=/sys/class/power_supply/bq27426-0/capacity
VOLT=/sys/class/power_supply/bq27426-0/voltage_now
ONLINE=/sys/class/power_supply/bq256xx-charger/online
CV=/sys/class/power_supply/bq256xx-charger/constant_charge_voltage

CV_NORMAL=4208000      # 正常满充电压 4.208V
CV_STOP=3856000        # 止充电压（驱动下限，低于电池电压即停充）
STOP=80                # 到达此电量 → 停充
RESUME=40              # 低于此电量 → 恢复充电
INTERVAL=60            # 检查周期(秒)

STATEFILE=/run/charge-guard.state
LOG=/var/log/charge-guard.log

log() { echo "$(date +%F_%T) $*" >> "$LOG"; }

read_val() { cat "$1" 2>/dev/null | tr -d '[:space:]'; }

set_cv() {
    target=$1
    cur=$(read_val "$CV")
    [ "$cur" = "$target" ] && return 0        # 已是目标值，避免重复写 I2C
    echo "$target" > "$CV" 2>/dev/null
    actual=$(read_val "$CV")
    log "CV $cur -> $target (actual=$actual)"
}

# 启动时根据当前电量推断状态，避免重启后卡在错误状态
boot_cap=$(read_val "$CAP")
if [ -n "$boot_cap" ] && [ "$boot_cap" -ge "$STOP" ]; then
    echo hold > "$STATEFILE"
    set_cv "$CV_STOP"
    log "BOOT cap=${boot_cap}% -> hold (charge stopped)"
else
    echo charging > "$STATEFILE"
    set_cv "$CV_NORMAL"
    log "BOOT cap=${boot_cap}% -> charging (charge enabled)"
fi

log "started: STOP=${STOP}% RESUME=${RESUME}% interval=${INTERVAL}s"

while true; do
    sleep "$INTERVAL"
    online=$(read_val "$ONLINE")
    [ "$online" = "1" ] || continue           # 拔电时不动作

    cap=$(read_val "$CAP")
    [ -n "$cap" ] || continue
    volt=$(read_val "$VOLT")
    state=$(cat "$STATEFILE" 2>/dev/null)

    if [ "$state" != "hold" ] && [ "$cap" -ge "$STOP" ]; then
        echo hold > "$STATEFILE"
        set_cv "$CV_STOP"
        log "STOP  cap=${cap}% volt=${volt} -> charge stopped"
    elif [ "$state" = "hold" ] && [ "$cap" -le "$RESUME" ]; then
        echo charging > "$STATEFILE"
        set_cv "$CV_NORMAL"
        log "RESUME cap=${cap}% volt=${volt} -> charge enabled"
    fi
done
