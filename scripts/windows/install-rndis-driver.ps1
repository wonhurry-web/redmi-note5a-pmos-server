$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class DevInst3 {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SP_DEVINFO_DATA {
        public int cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SetupDiGetClassDevs(
        IntPtr ClassGuid, string Enumerator, IntPtr hwndParent, uint Flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    public static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiEnumDeviceInfo(IntPtr DeviceInfoSet, uint MemberIndex, ref SP_DEVINFO_DATA DeviceInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetupDiGetDeviceInstanceId(
        IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData,
        StringBuilder InstanceId, int InstanceIdSize, out int RequiredSize);

    [DllImport("newdev.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool DiInstallDevice(
        IntPtr hwndParent, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData,
        IntPtr DriverInfoData, uint Flags, out bool NeedReboot);
}
'@

$targetInstance = 'USB\VID_1D6B&PID_0104&MI_00\6&23370CEF&0&0000'
$DIGCF_PRESENT = 0x00000002
$DIGCF_ALLCLASSES = 0x00000004

$h = [DevInst3]::SetupDiGetClassDevs([IntPtr]::Zero, $null, [IntPtr]::Zero, ($DIGCF_PRESENT -bor $DIGCF_ALLCLASSES))
if ($h -eq [IntPtr](-1)) { throw "SetupDiGetClassDevs failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

$found = $false
$idx = 0
while ($true) {
    $dev = New-Object DevInst3+SP_DEVINFO_DATA
    $dev.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'DevInst3+SP_DEVINFO_DATA')
    if (-not [DevInst3]::SetupDiEnumDeviceInfo($h, $idx, [ref]$dev)) { break }
    $idx++
    $sb = New-Object System.Text.StringBuilder 512
    $req = 0
    if ([DevInst3]::SetupDiGetDeviceInstanceId($h, [ref]$dev, $sb, $sb.Capacity, [ref]$req)) {
        $iid = $sb.ToString()
        if ($iid -eq $targetInstance) {
            "Found: $iid (class GUID: $($dev.ClassGuid))"
            $needReboot = $false
            $ok = [DevInst3]::DiInstallDevice([IntPtr]::Zero, $h, [ref]$dev, [IntPtr]::Zero, 0, [ref]$needReboot)
            "DiInstallDevice result: $ok ; NeedReboot: $needReboot ; LastError: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
            $found = $true
            break
        }
    }
}
[void][DevInst3]::SetupDiDestroyDeviceInfoList($h)
if (-not $found) { "Target not found. Total enumerated: $idx" }
