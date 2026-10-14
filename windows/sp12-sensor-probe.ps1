<#
.SYNOPSIS
  Surface Pro 12 sensor probe: what Windows sees and does with the ambient
  light sensor (ALS) and any human presence sensor. No debugger needed.

.DESCRIPTION
  Run from an elevated Windows PowerShell 5.1 prompt:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    L:\sp12\sp12-sensor-probe.ps1

  Collects, into <script dir>\out\<timestamp>\:
    inventory.txt      sensor / ISH / presence PnP devices, drivers, properties
    powercfg.txt       adaptive brightness power settings
    presence.txt       HumanPresenceSensor API and settings, if present
    als-live.csv       60 s of ALS readings through the Windows sensor API,
                       in three guided phases (room / covered / flashlight)
    trace\             ETW trace of the sensor stack during the live test,
                       decoded with tracerpt
  and zips the folder next to it.

  -NoTrace skips the ETW trace. -Seconds sets each live phase length.
#>
param(
  [switch]$NoTrace,
  [int]$Seconds = 20
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $root "out\$stamp"
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Section($file, $title) {
  Add-Content -Path (Join-Path $out $file) -Value "`r`n===== $title =====" -Encoding UTF8
}
function Log($file, $obj) {
  ($obj | Out-String -Width 400) | Add-Content -Path (Join-Path $out $file) -Encoding UTF8
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning 'Not elevated: the ETW trace and some properties will be missing.' }

# --- WinRT plumbing (Windows PowerShell 5.1) --------------------------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, [Type]$type) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
  [void]$task.Wait(10000)
  $task.Result
}
function Try-Type([string]$name) {
  try { return ([type]"$name, Windows.Devices.Sensors, ContentType=WindowsRuntime") } catch { return $null }
}

Write-Host "Output: $out"

# --- 1. Inventory ------------------------------------------------------------
Write-Host '[1/5] Device inventory'
Section inventory.txt 'OS'
Log inventory.txt (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber)
Log inventory.txt (Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, SystemSKUNumber)
Log inventory.txt (Get-CimInstance Win32_BIOS | Select-Object SMBIOSBIOSVersion, ReleaseDate)

$devs = Get-PnpDevice -PresentOnly | Where-Object {
  $_.Class -eq 'Sensor' -or
  $_.FriendlyName -match 'sensor|ISH|presence|light|proximity|context' -or
  $_.InstanceId -match 'ISH|8087|HID_DEVICE_UP:0020' }
Section inventory.txt 'Sensor-related PnP devices'
Log inventory.txt ($devs | Sort-Object Class, FriendlyName | Format-Table -AutoSize Status, Class, FriendlyName, InstanceId)

$keys = 'DEVPKEY_Device_HardwareIds', 'DEVPKEY_Device_CompatibleIds', 'DEVPKEY_Device_DriverVersion',
        'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverProvider', 'DEVPKEY_Device_Service',
        'DEVPKEY_Device_Parent', 'DEVPKEY_Device_LowerFilters', 'DEVPKEY_Device_UpperFilters',
        'DEVPKEY_Device_ProblemCode'
foreach ($d in $devs) {
  Section inventory.txt "$($d.FriendlyName)  [$($d.InstanceId)]"
  foreach ($k in $keys) {
    $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName $k -ErrorAction SilentlyContinue
    if ($p -and $p.Data) { Log inventory.txt ("{0} = {1}" -f $k, (($p.Data | ForEach-Object { $_ }) -join '; ')) }
  }
  # Every other property too: sensor-specific keys have no DEVPKEY names.
  $all = Get-PnpDeviceProperty -InstanceId $d.InstanceId -ErrorAction SilentlyContinue |
    Where-Object { $_.Data -ne $null -and $keys -notcontains $_.KeyName }
  Log inventory.txt ($all | Select-Object KeyName, Type, @{n='Data';e={($_.Data | ForEach-Object { $_ }) -join '; '}} |
    Format-Table -AutoSize -Wrap)
  $reg = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)\Device Parameters"
  if (Test-Path $reg) {
    Section inventory.txt "Device Parameters: $($d.InstanceId)"
    Log inventory.txt (Get-ItemProperty $reg)
    Get-ChildItem $reg -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
      Log inventory.txt $_.Name; Log inventory.txt (Get-ItemProperty $_.PSPath) }
  }
}

# --- 2. Adaptive brightness settings ----------------------------------------
Write-Host '[2/5] Brightness settings'
Section powercfg.txt 'powercfg /q SCHEME_CURRENT SUB_VIDEO'
Log powercfg.txt (powercfg /q SCHEME_CURRENT SUB_VIDEO 2>&1)
Section powercfg.txt 'ADAPTBRIGHT (fbd9aa66-9553-4097-ba44-ed6e9d65eab8)'
Log powercfg.txt (powercfg /q SCHEME_CURRENT SUB_VIDEO ADAPTBRIGHT 2>&1)
Section powercfg.txt 'Content adaptive brightness / display registry'
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SettingSync\Settings\Display',
               'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Sensor',
               'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\AdaptiveBrightness') {
  if (Test-Path $k) { Log powercfg.txt $k; Log powercfg.txt (Get-ItemProperty $k) }
}

# --- 3. Presence sensing ----------------------------------------------------
Write-Host '[3/5] Presence sensing'
$hps = Try-Type 'Windows.Devices.Sensors.HumanPresenceSensor'
if ($hps) {
  try {
    $sel = $hps::GetDeviceSelector()
    [void][Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime]
    $found = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)) `
      ([Windows.Devices.Enumeration.DeviceInformationCollection])
    Section presence.txt "HumanPresenceSensor devices: $($found.Count)"
    foreach ($f in $found) { Log presence.txt ($f | Select-Object Name, Id, IsEnabled) }
  } catch { Log presence.txt "enumeration failed: $_" }
  $hpset = Try-Type 'Windows.Devices.Sensors.HumanPresenceSettings'
  if ($hpset) {
    try {
      $s = Await ($hpset::GetCurrentSettingsAsync()) $hpset
      Section presence.txt 'HumanPresenceSettings'
      Log presence.txt ($s | Format-List *)
    } catch { Log presence.txt "settings failed: $_" }
  }
} else {
  Section presence.txt 'HumanPresenceSensor API not available on this build'
}

# --- 4. ETW trace around the live test --------------------------------------
$traceDir = Join-Path $out 'trace'
$session = 'sp12-sensor-probe'
$traceOn = $false
if (-not $NoTrace -and $isAdmin) {
  Write-Host '[4/5] Starting ETW trace of the sensor stack'
  New-Item -ItemType Directory -Force -Path $traceDir | Out-Null
  $providers = (logman query providers) | Where-Object { $_ -match 'Sensor|Presence|HumanInterface|Hid|Ish|Brightness|Display-Brightness' } |
    ForEach-Object { ($_ -split '\s{2,}')[0].Trim() } | Where-Object { $_ } | Sort-Object -Unique
  $providers | Set-Content (Join-Path $traceDir 'providers.txt') -Encoding UTF8
  logman stop $session -ets 2>$null | Out-Null
  $etl = Join-Path $traceDir 'sensors.etl'
  $first = $true
  foreach ($p in $providers) {
    if ($first) {
      logman start $session -p "$p" 0xffffffffffffffff 0xff -o $etl -ets -bs 1024 -nb 64 256 | Out-Null
      $first = $false
    } else {
      logman update $session -p "$p" 0xffffffffffffffff 0xff -ets | Out-Null
    }
  }
  $traceOn = -not $first
} else {
  Write-Host '[4/5] ETW trace skipped'
}

# --- 5. Live ALS readings ---------------------------------------------------
Write-Host '[5/5] Ambient light sensor'
$csv = Join-Path $out 'als-live.csv'
'phase,elapsed_ms,reading_timestamp,lux,new_reading' | Set-Content $csv -Encoding UTF8
$lsType = Try-Type 'Windows.Devices.Sensors.LightSensor'
$ls = $null
if ($lsType) { $ls = $lsType::GetDefault() }
if (-not $ls) {
  Write-Host '  No default LightSensor: Windows exposes no ALS to apps.' -ForegroundColor Yellow
  Add-Content $csv 'none,0,,,' -Encoding UTF8
} else {
  Section inventory.txt 'LightSensor (WinRT)'
  Log inventory.txt ($ls | Select-Object DeviceId, MinimumReportInterval, ReportInterval, MaxBatchSize, ReportLatency)
  try { Log inventory.txt ($ls.ReportThreshold | Format-List *) } catch {}
  $ls.ReportInterval = [Math]::Max($ls.MinimumReportInterval, 200)

  $phases = @(
    @{ name = 'room';       msg = 'Leave the sensor UNCOVERED in normal room light' },
    @{ name = 'covered';    msg = 'COVER the sensor (top bezel near the front camera) with a finger' },
    @{ name = 'flashlight'; msg = 'Shine a FLASHLIGHT at the sensor' },
    @{ name = 'room2';      msg = 'Uncover again, normal room light' }
  )
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $lastTs = $null
  foreach ($ph in $phases) {
    Write-Host ''
    Write-Host ("  >>> {0} for {1} s" -f $ph.msg, $Seconds) -ForegroundColor Cyan
    for ($c = 3; $c -gt 0; $c--) { Write-Host "      starting in $c"; Start-Sleep 1 }
    $end = $clock.ElapsedMilliseconds + $Seconds * 1000
    while ($clock.ElapsedMilliseconds -lt $end) {
      $r = $ls.GetCurrentReading()
      if ($r) {
        $ts = $r.Timestamp.ToString('o')
        $new = [int]($ts -ne $lastTs)
        $lastTs = $ts
        Add-Content $csv ("{0},{1},{2},{3:F3},{4}" -f $ph.name, $clock.ElapsedMilliseconds, $ts, $r.IlluminanceInLux, $new) -Encoding UTF8
        Write-Host -NoNewline ("`r      {0,10:F2} lux   {1}" -f $r.IlluminanceInLux, ($(if ($new) { 'new' } else { '   ' })))
      } else {
        Add-Content $csv ("{0},{1},,,0" -f $ph.name, $clock.ElapsedMilliseconds) -Encoding UTF8
      }
      Start-Sleep -Milliseconds 250
    }
  }
  Write-Host ''
  $ls.ReportInterval = 0
}

if ($traceOn) {
  logman stop $session -ets | Out-Null
  Push-Location $traceDir
  tracerpt sensors.etl -o sensors.xml -of XML -summary summary.txt -report report.xml -y 2>&1 | Out-Null
  Pop-Location
}

# --- Summary and zip --------------------------------------------------------
$rows = Import-Csv $csv
$summary = $rows | Group-Object phase | ForEach-Object {
  $l = $_.Group | Where-Object { $_.lux -ne '' } | ForEach-Object { [double]$_.lux }
  [pscustomobject]@{
    phase = $_.Name
    samples = $_.Count
    new_readings = ($_.Group | Where-Object { $_.new_reading -eq '1' }).Count
    min_lux = if ($l) { ($l | Measure-Object -Minimum).Minimum } else { '' }
    max_lux = if ($l) { ($l | Measure-Object -Maximum).Maximum } else { '' }
  }
}
Section inventory.txt 'ALS live summary'
Log inventory.txt ($summary | Format-Table -AutoSize)
$summary | Format-Table -AutoSize

$zip = "$out.zip"
Compress-Archive -Path "$out\*" -DestinationPath $zip -Force
Write-Host "Done. Results: $out"
Write-Host "Zip:           $zip"
