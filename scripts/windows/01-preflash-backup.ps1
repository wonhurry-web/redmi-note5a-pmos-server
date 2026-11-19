#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Pre-flash full partition backup for Redmi Note 5A (ugglite).
.DESCRIPTION
  Enter fastboot -> dump all key partitions -> reboot -> pull /sdcard data.
  Output: D:\backup\ugglite\<timestamp>\
#>
$ErrorActionPreference = "Stop"
$ADB      = "D:\platform-tools\adb.exe"
$FASTBOOT = "D:\platform-tools\fastboot.exe"
$DEVICE   = "<DEVICE_SERIAL>"
$PARTITIONS = @("aboot","abootbak","boot","recovery","system","cache","persist","misc","userdata")

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$bkRoot = "D:\backup\ugglite\$stamp"
$imgDir = Join-Path $bkRoot "images"
$sdDir  = Join-Path $bkRoot "sdcard"
New-Item -ItemType Directory -Force -Path $imgDir | Out-Null
New-Item -ItemType Directory -Force -Path $sdDir  | Out-Null
Write-Host "Backup dir: $bkRoot" -ForegroundColor Cyan

Write-Host "`n[1/4] Check ADB device..." -ForegroundColor Yellow
$devs = (& $ADB devices 2>&1 | Out-String)
if ($devs -notmatch [regex]::Escape($DEVICE)) { throw "Device $DEVICE not found in ADB. Current:`n$devs" }
Write-Host "  ADB device OK: $DEVICE"

Write-Host "`n[2/4] Reboot into fastboot..." -ForegroundColor Yellow
& $ADB -s $DEVICE reboot bootloader 2>&1 | Out-Null
Start-Sleep -Seconds 6
$fb = (& $FASTBOOT devices 2>&1 | Out-String)
if ($fb -notmatch "fastboot") { throw "Device not in fastboot. Manually hold VolDown+Power to enter, then rerun." }
Write-Host "  Fastboot device: $fb" -ForegroundColor Green

Write-Host "`n[3/4] Dump partitions..." -ForegroundColor Yellow
& $FASTBOOT getvar all 2>&1 | Out-File (Join-Path $bkRoot "fastboot_getvar_all.txt") -Encoding utf8
foreach ($p in $PARTITIONS) {
    $out = Join-Path $imgDir "$p.img"
    Write-Host "  -> $p ..." -NoNewline
    & $FASTBOOT dump_image $p $out 2>&1 | Out-Null
    if (Test-Path $out) {
        $size = [math]::Round((Get-Item $out).Length / 1MB, 1)
        Write-Host " done ($size MB)" -ForegroundColor Green
    } else {
        Write-Host " skipped (partition absent)" -ForegroundColor DarkYellow
    }
}

Write-Host "`n[4/4] Reboot to system and pull /sdcard ..." -ForegroundColor Yellow
& $FASTBOOT reboot 2>&1 | Out-Null
Write-Host "  Waiting for boot (~40s)..." -ForegroundColor DarkYellow
Start-Sleep -Seconds 40
$ready = $false
for ($i = 0; $i -lt 12; $i++) {
    $state = (& $ADB -s $DEVICE get-state 2>&1 | Out-String)
    if ($state -match "device") { $ready = $true; break }
    Start-Sleep -Seconds 5
}
if ($ready) {
    & $ADB -s $DEVICE pull /sdcard/ $sdDir 2>&1 | Out-Null
    Write-Host "  User data pulled to $sdDir" -ForegroundColor Green
} else {
    Write-Host "  Device did not boot in time. Manual: adb pull /sdcard/ $sdDir" -ForegroundColor Red
}

Write-Host "`n===== BACKUP DONE =====" -ForegroundColor Cyan
Write-Host "Backup dir: $bkRoot" -ForegroundColor Cyan
Write-Host "Verify all .img under images\ are non-zero before flashing." -ForegroundColor Yellow
