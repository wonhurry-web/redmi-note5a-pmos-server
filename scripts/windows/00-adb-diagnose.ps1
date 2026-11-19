#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Redmi Note 5A (ugglite) ADB 诊断脚本 —— 可随时复跑，只读不改设备。
.DESCRIPTION
  采集设备身份、系统、内存、存储、分区、bootloader、电池等信息并输出到控制台。
  用法: powershell -ExecutionPolicy Bypass -File .\00-adb-diagnose.ps1
#>
$ErrorActionPreference = "Continue"
$ADB = "D:\platform-tools\adb.exe"

function Invoke-Adb([string]$arg) {
    & $ADB -s <DEVICE_SERIAL> shell $arg 2>&1
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Redmi Note 5A (ugglite) ADB 诊断" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host "`n[0] 已连接设备" -ForegroundColor Yellow
& $ADB devices -l

Write-Host "`n[1] 设备身份" -ForegroundColor Yellow
"  型号     : $(Invoke-Adb 'getprop ro.product.model')"
"  品牌     : $(Invoke-Adb 'getprop ro.product.brand')"
"  代号     : $(Invoke-Adb 'getprop ro.product.device')"
"  主板     : $(Invoke-Adb 'getprop ro.product.board')"
"  平台     : $(Invoke-Adb 'getprop ro.board.platform')"
"  架构     : $(Invoke-Adb 'getprop ro.product.cpu.abi')"

Write-Host "`n[2] 系统版本" -ForegroundColor Yellow
"  Android  : $(Invoke-Adb 'getprop ro.build.version.release')"
"  SDK      : $(Invoke-Adb 'getprop ro.build.version.sdk')"
"  内核     : $(Invoke-Adb 'uname -a')"

Write-Host "`n[3] 内存" -ForegroundColor Yellow
Invoke-Adb 'free -h'

Write-Host "`n[4] 存储" -ForegroundColor Yellow
Invoke-Adb 'df -h /data'

Write-Host "`n[5] 分区布局" -ForegroundColor Yellow
Invoke-Adb 'ls -l /dev/block/bootdevice/by-name/'

Write-Host "`n[6] Bootloader 状态" -ForegroundColor Yellow
$vb = Invoke-Adb 'getprop ro.boot.verifiedbootstate'
"  verifiedbootstate = $vb"
if ($vb -match "orange") { Write-Host "  => 已解锁，可刷机 [OK]" -ForegroundColor Green }
else { Write-Host "  => 未解锁，需先解锁 Bootloader [STOP]" -ForegroundColor Red }

Write-Host "`n[7] 电池 / 供电" -ForegroundColor Yellow
Invoke-Adb 'dumpsys battery' | Select-String -Pattern "level|status|powered"

Write-Host "`n[8] 网络 IP" -ForegroundColor Yellow
Invoke-Adb 'ip addr' | Select-String -Pattern "inet "

Write-Host "`n诊断完成。" -ForegroundColor Cyan
