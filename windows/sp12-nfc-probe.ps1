<#
.SYNOPSIS
  Surface Pro 12 NFC probe: does the PN560 see cards under Windows, and what
  does Windows' NFC stack do when it starts the chip. No debugger needed.

.DESCRIPTION
  Run from an elevated Windows PowerShell 5.1 prompt:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    C:\Users\turbi\sp12\sp12-nfc-probe.ps1

  Collects, into <script dir>\out\nfc-<timestamp>\:
    inventory.txt   NFC / proximity / smart-card PnP devices, drivers, radio
                    state, and the NFC device's registry (Device Parameters)
    cards.csv       smart-card reader state every 0.5 s while you tap a card
    trace\          ETW trace of the NFC, proximity and smart-card stack
                    across an NFC device restart and the tap test, decoded
                    with tracerpt
  and zips the folder next to it.

  -Seconds sets the tap window (default 40).
#>
param([int]$Seconds = 40)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $root "out\nfc-$stamp"
New-Item -ItemType Directory -Force -Path $out | Out-Null
function Section($title) { Add-Content (Join-Path $out inventory.txt) "`r`n===== $title =====" -Encoding UTF8 }
function Log($obj) { ($obj | Out-String -Width 400) | Add-Content (Join-Path $out inventory.txt) -Encoding UTF8 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning 'Not elevated: the device restart and the ETW trace need Administrator.' }
Write-Host "Output: $out"

# --- 1. Inventory -------------------------------------------------------------
Write-Host '[1/4] NFC inventory'
$nfc = Get-PnpDevice -PresentOnly | Where-Object {
  $_.InstanceId -like 'ACPI\1FC93002*' -or $_.Class -in 'Proximity', 'SmartCardReader' -or
  $_.FriendlyName -match 'NFC|NXP|Proximity|Smart ?card' }
Section 'NFC-related PnP devices'
Log ($nfc | Sort-Object Class | Format-Table -AutoSize Status, Class, FriendlyName, InstanceId)
foreach ($d in $nfc) {
  Section "$($d.FriendlyName)  [$($d.InstanceId)]"
  Log (Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue |
    Where-Object { $_.Data -ne $null } |
    Select-Object KeyName, @{n='Data';e={($_.Data | ForEach-Object { $_ }) -join '; '}} | Format-Table -AutoSize -Wrap)
  $reg = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)\Device Parameters"
  if (Test-Path $reg) {
    Section "Registry: $reg"
    reg query ($reg -replace '^HKLM:', 'HKLM') /s 2>&1 | Add-Content (Join-Path $out inventory.txt) -Encoding UTF8
  }
}
foreach ($svc in 'NfcCx', 'NxpNfcClientDriver', 'SCardSvr', 'ScDeviceEnum') {
  $k = "HKLM\SYSTEM\CurrentControlSet\Services\$svc"
  Section "Service $svc"
  reg query $k /s 2>&1 | Add-Content (Join-Path $out inventory.txt) -Encoding UTF8
}

Section 'Radios'
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  [void][Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType=WindowsRuntime]
  $rt = [Type]'System.Collections.Generic.IReadOnlyList`1[Windows.Devices.Radios.Radio]'
  $task = $asTask.MakeGenericMethod($rt).Invoke($null, @([Windows.Devices.Radios.Radio]::GetRadiosAsync()))
  [void]$task.Wait(10000)
  Log ($task.Result | Select-Object Name, Kind, State)
  $nfcRadio = $task.Result | Where-Object { $_.Name -match 'NFC' }
  if ($nfcRadio -and $nfcRadio.State -ne 'On') {
    Write-Host '  NFC radio is OFF in Windows. Turn it on (Settings > Network > Airplane mode > NFC) and rerun.' -ForegroundColor Yellow
  }
} catch { Log "radio query failed: $_" }

# --- 2. Smart-card API -------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SC {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct READERSTATE {
    public string reader; public IntPtr userData;
    public uint currentState; public uint eventState; public uint atrLen;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 36)] public byte[] atr;
  }
  [DllImport("winscard.dll")] public static extern int SCardEstablishContext(uint scope, IntPtr r1, IntPtr r2, out IntPtr ctx);
  [DllImport("winscard.dll")] public static extern int SCardReleaseContext(IntPtr ctx);
  [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
  public static extern int SCardListReaders(IntPtr ctx, string groups, char[] readers, ref uint len);
  [DllImport("winscard.dll", CharSet = CharSet.Unicode)]
  public static extern int SCardGetStatusChange(IntPtr ctx, uint timeout, [In, Out] READERSTATE[] states, int count);
  public static string[] Readers(IntPtr ctx) {
    uint len = 0;
    if (SCardListReaders(ctx, null, null, ref len) != 0) return new string[0];
    char[] buf = new char[len];
    if (SCardListReaders(ctx, null, buf, ref len) != 0) return new string[0];
    return new string(buf).Split(new char[] { '\0' }, StringSplitOptions.RemoveEmptyEntries);
  }
}
"@

# --- 3. ETW trace across a device restart --------------------------------------
$traceDir = Join-Path $out 'trace'
$session = 'sp12-nfc-probe'
$traceOn = $false
if ($isAdmin) {
  Write-Host '[2/4] Starting ETW trace'
  New-Item -ItemType Directory -Force -Path $traceDir | Out-Null
  $providers = (logman query providers) | Where-Object { $_ -match 'NFC|Nfc|Proximity|SmartCard|Smartcard|SCard|Nxp|NXP' } |
    ForEach-Object { ($_ -split '\s{2,}')[0].Trim() } | Where-Object { $_ } | Sort-Object -Unique
  $providers | Set-Content (Join-Path $traceDir 'providers.txt') -Encoding UTF8
  logman stop $session -ets 2>$null | Out-Null
  $first = $true
  foreach ($p in $providers) {
    if ($first) {
      logman start $session -p "$p" 0xffffffffffffffff 0xff -o (Join-Path $traceDir 'nfc.etl') -ets -bs 1024 -nb 64 256 | Out-Null
      $first = $false
    } else {
      logman update $session -p "$p" 0xffffffffffffffff 0xff -ets | Out-Null
    }
  }
  $traceOn = -not $first

  $dev = $nfc | Where-Object { $_.InstanceId -like 'ACPI\1FC93002*' } | Select-Object -First 1
  if ($dev) {
    Write-Host "  restarting $($dev.FriendlyName) so the trace sees the chip start"
    pnputil /restart-device "$($dev.InstanceId)" 2>&1 | Add-Content (Join-Path $out inventory.txt) -Encoding UTF8
    Start-Sleep 6
  } else {
    Write-Host '  NFC device (ACPI\1FC93002) not found' -ForegroundColor Yellow
  }
} else {
  Write-Host '[2/4] ETW trace skipped (not elevated)'
}

# --- 4. Tap test -----------------------------------------------------------------
Write-Host '[3/4] Card test'
$csv = Join-Path $out 'cards.csv'
'elapsed_ms,reader,state_hex,present,atr' | Set-Content $csv -Encoding UTF8
$ctx = [IntPtr]::Zero
$rc = [SC]::SCardEstablishContext(2, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ctx)
$readers = if ($rc -eq 0) { [SC]::Readers($ctx) } else { @() }
Section 'Smart-card readers'
Log $readers
if (-not $readers) { Write-Host '  No smart-card readers: the NFC stack exposes none.' -ForegroundColor Yellow }

Write-Host ''
Write-Host ("  >>> For {0} s: hold a contactless card (or security key) flat on the TOP-LEFT" -f $Seconds) -ForegroundColor Cyan
Write-Host  '      corner of the screen for a few seconds, lift it away, and repeat.' -ForegroundColor Cyan
$clock = [Diagnostics.Stopwatch]::StartNew()
$last = @{}
while ($clock.ElapsedMilliseconds -lt $Seconds * 1000) {
  if ($readers) {
    $states = @($readers | ForEach-Object {
      $s = New-Object SC+READERSTATE; $s.reader = $_; $s.atr = New-Object byte[] 36; $s })
    $r = [SC]::SCardGetStatusChange($ctx, 0, $states, $states.Count)
    foreach ($s in $states) {
      $present = [int](($s.eventState -band 0x20) -ne 0)
      $atr = if ($s.atrLen -gt 0) { ($s.atr[0..($s.atrLen - 1)] | ForEach-Object { $_.ToString('X2') }) -join '' } else { '' }
      Add-Content $csv ("{0},{1},{2:X},{3},{4}" -f $clock.ElapsedMilliseconds, $s.reader, $s.eventState, $present, $atr) -Encoding UTF8
      if ($last[$s.reader] -ne $present) {
        Write-Host ("  {0,6:F1} s  {1}: {2} {3}" -f ($clock.ElapsedMilliseconds / 1000), $s.reader,
          $(if ($present) { 'CARD PRESENT' } else { 'no card' }), $atr)
        $last[$s.reader] = $present
      }
    }
  }
  Start-Sleep -Milliseconds 500
}
if ($ctx -ne [IntPtr]::Zero) { [void][SC]::SCardReleaseContext($ctx) }

# --- Finish --------------------------------------------------------------------
Write-Host '[4/4] Finishing'
if ($traceOn) {
  logman stop $session -ets | Out-Null
  Push-Location $traceDir
  tracerpt nfc.etl -o nfc.xml -of XML -summary summary.txt -report report.xml -y 2>&1 | Out-Null
  Pop-Location
}
$seen = (Import-Csv $csv | Where-Object { $_.present -eq '1' }).Count
Section 'Tap test summary'
Log "samples with a card present: $seen"
Write-Host "  samples with a card present: $seen"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Done. Results: $out"
