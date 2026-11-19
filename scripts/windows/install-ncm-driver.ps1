# 强制为指定设备实例安装系统 NCM 驱动（SetupAPI DiInstallDevice）
# 绕过 PnP 自动匹配失败（问题代码 28）
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class DevInstall {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SP_DEVINFO_DATA {
        public int cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SetupDiGetClassDevs(
        ref Guid ClassGuid, string Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiEnumDeviceInfo(IntPtr DeviceInfoSet, uint MemberIndex, ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiGetDeviceInstanceId(
        IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData,
        System.Text.StringBuilder InstanceId, int InstanceIdSize, out int RequiredSize);

    [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool DiInstallDevice(
        IntPtr hwndParent, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData,
        IntPtr DriverInfoData, uint Flags, out bool NeedReboot);
}
'@

$targetInstance = 'USB\VID_18D1&PID_D001&MI_00\6&77A60DF&0&0000'
$GUID_DEVCLASS_NET = [Guid]'{4d36e972-e325-11ce-bfc1-08002be10318}'
$DIGCF_PRESENT = 0x00000002
$DIGCF_ALLCLASSES = 0x00000004

$h = [DevInstall]::SetupDiGetClassDevs([ref]$GUID_DEVCLASS_NET, $null, [IntPtr]::Zero, ($DIGCF_PRESENT -bor $DIGCF_ALLCLASSES))
if ($h -eq [IntPtr](-1)) { throw "SetupDiGetClassDevs failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

$found = $false
$idx = 0
while ($true) {
    $dev = New-Object DevInstall+SP_DEVINFO_DATA
    $dev.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($dev)
    if (-not [DevInstall]::SetupDiEnumDeviceInfo($h, $idx, [ref]$dev)) { break }
    $idx++
    $sb = New-Object System.Text.StringBuilder 512
    $req = 0
    if ([DevInstall]::SetupDiGetDeviceInstanceId($h, [ref]$dev, $sb, $sb.Capacity, [ref]$req)) {
        $iid = $sb.ToString()
        if ($iid -eq $targetInstance) {
            "Found device instance: $iid"
            $needReboot = $false
            # DiInstallDevice with DriverInfoData=NULL -> re-run PnP selection using best available (system INF)
            $ok = [DevInstall]::DiInstallDevice([IntPtr]::Zero, $h, [ref]$dev, [IntPtr]::Zero, 0, [ref]$needReboot)
            "DiInstallDevice result: $ok ; NeedReboot: $needReboot ; LastError: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            $found = $true
            break
        }
    }
}
[void][DevInstall]::SetupDiDestroyDeviceInfoList($h)
if (-not $found) { "Target device instance not found in NET class." }
