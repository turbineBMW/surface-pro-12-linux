<#
.SYNOPSIS
  Export Windows' Bluetooth pairing keys so Linux can share the bonds
  (dual boot on the same Bluetooth controller).

.DESCRIPTION
  Run from an elevated Windows PowerShell 5.1 prompt:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    C:\Users\turbi\sp12\sp12-bt-keys.ps1

  The keys live under HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\
  Parameters\Keys, readable only by SYSTEM. The script registers a one-shot
  scheduled task that runs as SYSTEM, exports that key to
  <script dir>\out\bt-keys.reg, and deletes the task again. Nothing else is
  changed.

  Use: the Surface Slim Pen's "loosely coupled" bond. Windows creates it when
  the pen first touches the screen, and the pen uses that identity whenever it
  has been docked. With the same bond, Linux reconnects the pen on any button
  press, as Windows does. Keep the exported file private: it holds the pairing
  keys of every Bluetooth device paired with Windows.
#>
$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Run this from an elevated (Administrator) PowerShell.' }

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$out = Join-Path $root 'out'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$reg = Join-Path $out 'bt-keys.reg'
$cmd = Join-Path $out 'bt-keys-export.cmd'
Remove-Item -Force -ErrorAction SilentlyContinue $reg

@"
@echo off
reg export "HKLM\SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Keys" "$reg" /y
"@ | Set-Content -Path $cmd -Encoding ASCII

$task = 'sp12-bt-keys-export'
schtasks /Create /TN $task /RU SYSTEM /SC ONCE /ST 00:00 /TR "`"$cmd`"" /F | Out-Null
try {
  schtasks /Run /TN $task | Out-Null
  for ($i = 0; $i -lt 30 -and -not (Test-Path $reg); $i++) { Start-Sleep -Seconds 1 }
} finally {
  schtasks /Delete /TN $task /F | Out-Null
  Remove-Item -Force -ErrorAction SilentlyContinue $cmd
}

if (Test-Path $reg) {
  Write-Host "Exported: $reg" -ForegroundColor Green
  Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match '^BTHLE\\DEV_' } |
    Select-Object FriendlyName, InstanceId | Format-Table -AutoSize |
    Out-String | Set-Content (Join-Path $out 'bt-devices.txt') -Encoding UTF8
} else {
  Write-Warning 'The export did not appear; is Bluetooth on and the pen paired?'
}
