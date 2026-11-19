# ============================================================
# note5a-srv 运维控制台（Windows / PowerShell）
# 用法：
#   .\03-srvctl.ps1 status   状态面板
#   .\03-srvctl.ps1 start    启动 / 修复
#   .\03-srvctl.ps1 stop     停止（保留镜像数据）
#   .\03-srvctl.ps1 shell    进入 chroot bash
#   .\03-srvctl.ps1 logs     查看日志
#   .\03-srvctl.ps1 verify   SSH 登录验收
#   .\03-srvctl.ps1 reboot   重启手机（验证自启）
# ============================================================
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'start', 'stop', 'shell', 'logs', 'verify', 'reboot')]
    [string]$Action = 'status'
)

$ADB = 'D:\platform-tools\adb.exe'
$SERIAL = '<DEVICE_SERIAL>'
$DEV_IP = '<DEVICE_IP>'

function Invoke-Root {
    param([string]$Cmd)
    & $ADB -s $SERIAL shell su -c $Cmd
}

switch ($Action) {
    'status' { Invoke-Root 'sh /data/linux/status.sh' }

    'start'  {
        Invoke-Root 'sh /data/linux/start.sh'
        Invoke-Root 'tail -4 /data/linux/server.log'
    }

    'stop'   { Invoke-Root 'sh /data/linux/stop.sh' }

    'shell'  {
        Invoke-Root 'chroot /data/linux/mnt /bin/sh -c "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; exec /bin/bash"'
    }

    'logs'   {
        Invoke-Root 'tail -20 /data/linux/server.log; echo --- supervisor ---; tail -10 /data/linux/supervisor.log'
    }

    'verify' { & python "$PSScriptRoot\02-verify-ssh.py" $DEV_IP 22 administrator root }

    'reboot' {
        & $ADB -s $SERIAL reboot
        Write-Host '已发送重启，约 90 秒后完成自启' -ForegroundColor Yellow
    }
}
