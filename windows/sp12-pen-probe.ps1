<#
.SYNOPSIS
  Surface Pro 12 pen probe: how Windows pairs the Slim Pen when it touches
  the screen, whether the pen drops its Bluetooth link while docked, and what
  the Flex Keyboard's pen charger and the digitizer report meanwhile. No
  debugger needed; nothing is written to any device.

.DESCRIPTION
  Run from an elevated Windows PowerShell 5.1 prompt:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    C:\Users\turbi\sp12\sp12-pen-probe.ps1 -Mode pair
    C:\Users\turbi\sp12\sp12-pen-probe.ps1 -Mode watch
    C:\Users\turbi\sp12\sp12-pen-probe.ps1 -Mode cradle

  -Mode pair    Touch-to-pair. Remove the pen in Settings > Bluetooth &
                devices first (the script checks and waits). Then, with the
                capture running, touch the pen tip to the screen; the script
                stops once Windows has paired it (or after -Seconds).
  -Mode watch   Pen docked in the keyboard cradle, keyboard attached. Logs
                the pen's Bluetooth connection state every 5 s for up to
                -Minutes. If the pen disconnects, it beeps and starts a
                capture: pull the pen out of the cradle when prompted.
  -Mode cradle  Cued dock/undock with a capture running (high beep = pen IN,
                low beep = pen OUT).

  Each run writes <script dir>\out\pen-<mode>-<timestamp>\ and a .zip:
    hid.txt       HID collections of the keyboard (045E) and digitizer
                  (04F3), vendor feature reads, and any errors
    reports.txt   timestamped input reports from those HID collections, with
                  step markers
    pen.txt       pen Bluetooth device nodes and connection state over time
    hci.etl/.xml  raw HCI traffic (BTHPORT provider, all keywords)
    bluetooth.etl Windows Bluetooth stack trace (BluetoothStack.wprp)
#>
param(
  [ValidateSet('pair', 'watch', 'cradle')][string]$Mode = 'pair',
  [int]$Seconds = 120,
  [int]$Minutes = 30,
  [switch]$NoTrace
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $root "out\pen-$Mode-$stamp"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$hidTxt = Join-Path $out 'hid.txt'
$penTxt = Join-Path $out 'pen.txt'
function Log($text) { ($text | Out-String -Width 400).TrimEnd() | Add-Content $hidTxt -Encoding UTF8 }
function PenLog($text) { "$(Get-Date -Format 'HH:mm:ss.fff') $text" | Add-Content $penTxt -Encoding UTF8 }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning 'Not elevated: the Bluetooth traces will be skipped.' }

Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class Sp12Hid {
  [StructLayout(LayoutKind.Sequential)]
  public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort Version; }
  [StructLayout(LayoutKind.Sequential)]
  public struct HIDP_CAPS {
    public ushort Usage; public ushort UsagePage;
    public ushort InputReportByteLength; public ushort OutputReportByteLength; public ushort FeatureReportByteLength;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
    public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices,
      NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices,
      NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
  }

  [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES a);
  [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
  [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
  [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, ref HIDP_CAPS c);
  [DllImport("hid.dll", SetLastError = true)] static extern bool HidD_GetFeature(SafeFileHandle h, byte[] b, int n);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern SafeFileHandle CreateFileW(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);

  public static SafeFileHandle Open(string path, uint access) {
    return CreateFileW(path, access, 3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
  }

  // Returns "vid pid page usage in feat" or throws with the Win32 error.
  public static int[] Caps(string path) {
    using (var h = Open(path, 0u)) {
      if (h.IsInvalid) throw new Exception("open failed " + Marshal.GetLastWin32Error());
      var a = new HIDD_ATTRIBUTES(); a.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
      if (!HidD_GetAttributes(h, ref a)) throw new Exception("attributes failed " + Marshal.GetLastWin32Error());
      IntPtr p;
      if (!HidD_GetPreparsedData(h, out p)) throw new Exception("preparsed failed " + Marshal.GetLastWin32Error());
      var c = new HIDP_CAPS(); c.Reserved = new ushort[17];
      HidP_GetCaps(p, ref c);
      HidD_FreePreparsedData(p);
      return new int[] { a.VendorID, a.ProductID, c.UsagePage, c.Usage, c.InputReportByteLength, c.FeatureReportByteLength };
    }
  }

  public static string GetFeature(string path, byte id, int len) {
    if (len <= 0) return "no features";
    foreach (uint access in new uint[] { 0xC0000000u, 0u }) {
      using (var h = Open(path, access)) {
        if (h.IsInvalid) continue;
        var b = new byte[len]; b[0] = id;
        if (HidD_GetFeature(h, b, len)) return BitConverter.ToString(b).Replace("-", " ");
        int e = Marshal.GetLastWin32Error();
        if (access == 0u) return "error " + e;
      }
    }
    return "open failed " + Marshal.GetLastWin32Error();
  }

  public static ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
  static Stopwatch clock = Stopwatch.StartNew();
  static volatile bool stop;
  public static void ResetClock() { clock.Restart(); }
  public static double Now() { return clock.Elapsed.TotalSeconds; }
  public static void Mark(string what) { Lines.Enqueue(string.Format("{0,8:F2} ---- {1}", Now(), what)); }

  public static string StartReader(string path, string name, int len) {
    SafeFileHandle h = Open(path, 0xC0000000u);
    if (h.IsInvalid) h = Open(path, 0x80000000u);
    if (h.IsInvalid) return "open failed " + Marshal.GetLastWin32Error();
    FileStream fs;
    try { fs = new FileStream(h, FileAccess.Read, Math.Max(len, 1), false); }
    catch (Exception e) { return "stream failed: " + e.Message; }
    var t = new Thread(() => {
      var buf = new byte[len];
      while (!stop) {
        int n;
        try { n = fs.Read(buf, 0, len); }
        catch (Exception e) { Lines.Enqueue(name + ": read stopped: " + e.Message); return; }
        if (n > 0) Lines.Enqueue(string.Format("{0,8:F2} {1} {2}", Now(), name, BitConverter.ToString(buf, 0, n).Replace("-", " ")));
      }
    });
    t.IsBackground = true; t.Start();
    return "reading";
  }
  public static void StopReaders() { stop = true; }
}
"@

$hidGuid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'

# --- HID collections ---------------------------------------------------------
function Get-HidCollections {
  $list = @()
  $devs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match '^HID\\' -and $_.InstanceId -match 'VID_045E|VID_04F3|045E|04F3' }
  foreach ($d in $devs) {
    $path = '\\?\' + ($d.InstanceId -replace '\\', '#') + '#' + $hidGuid
    try {
      $c = [Sp12Hid]::Caps($path)
      $o = [pscustomobject]@{ Path = $path; Id = $d.InstanceId; Name = $d.FriendlyName
        Vid = $c[0]; Pid = $c[1]; Page = $c[2]; Usage = $c[3]; In = $c[4]; Feat = $c[5] }
      Log ("{0:X4}:{1:X4} page {2:X4} usage {3:X4} in {4} feat {5}  {6}" -f $o.Vid, $o.Pid, $o.Page, $o.Usage, $o.In, $o.Feat, $d.InstanceId)
      $list += $o
    } catch {
      Log "caps failed for $($d.InstanceId): $($_.Exception.Message)"
    }
  }
  return $list
}

Log "===== HID collections ====="
$cols = Get-HidCollections
$vendor = $cols | Where-Object { $_.Page -ge 0xFF00 -and $_.Feat -gt 0 }

function Snapshot($label) {
  Log "`r`n===== vendor features: $label ====="
  foreach ($c in $vendor) {
    # Feature report IDs seen in the SP12 descriptors; unknown IDs just fail
    foreach ($id in 0x56, 0x70, 0x73, 0x32, 0x33, 0x05, 0x06, 0x07, 0x08) {
      $r = [Sp12Hid]::GetFeature($c.Path, [byte]$id, $c.Feat)
      if ($r -notmatch '^error') {
        Log ("  {0:X4}:{1:X4} {2:X4}:{3:X4} feature {4:X2}: {5}" -f $c.Vid, $c.Pid, $c.Page, $c.Usage, $id, $r)
      }
    }
  }
  [Sp12Hid]::Mark("features: $label")
}

function Start-Readers {
  foreach ($c in ($cols | Where-Object { $_.In -gt 0 -and ($_.Page -ge 0xFF00 -or $_.Pid -eq 0x0C8E) })) {
    $name = '{0:X4}/{1:X4}:{2:X4}' -f $c.Pid, $c.Page, $c.Usage
    Log "reader $name ($($c.In) bytes): $([Sp12Hid]::StartReader($c.Path, $name, $c.In))"
  }
}

# --- Pen Bluetooth state -----------------------------------------------------
$isConnectedKey = '{83DA6326-97A6-4088-9453-A1923F573B29} 15'
function Get-PenNodes {
  Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -match 'Slim Pen|Surface Pen' -and $_.InstanceId -match '^BTHLE' }
}
function Get-PenState {
  $nodes = @(Get-PenNodes)
  if ($nodes.Count -eq 0) { return 'not paired' }
  $states = foreach ($n in $nodes) {
    $v = (Get-PnpDeviceProperty -InstanceId $n.InstanceId -KeyName $isConnectedKey -ErrorAction SilentlyContinue).Data
    "$($n.Status)/connected=$v"
  }
  return ($states | Sort-Object -Unique) -join ', '
}

# --- Traces ------------------------------------------------------------------
$hciSession = 'sp12-bthci'
$traceOn = $false
function Start-Traces {
  if (-not $isAdmin -or $NoTrace) { return }
  Write-Host 'Starting the Bluetooth traces'
  logman stop $hciSession -ets 2>$null | Out-Null
  logman start $hciSession -p '{8a1f9517-3a8c-4a9e-a018-4f17a200f277}' 0xffffffffffffffff 0xff `
    -o (Join-Path $out 'hci.etl') -ets -bs 1024 -nb 16 64 2>&1 | Add-Content $hidTxt -Encoding UTF8
  $wprp = Join-Path $root 'BluetoothStack.wprp'
  wpr -cancel 2>$null | Out-Null
  if (Test-Path $wprp) { wpr -start "$wprp!BluetoothStack.Verbose" -filemode 2>&1 | Add-Content $hidTxt -Encoding UTF8 }
  $script:traceOn = $true
}
function Stop-Traces {
  if (-not $traceOn) { return }
  Write-Host 'Stopping the traces (this can take a minute)'
  logman stop $hciSession -ets 2>&1 | Add-Content $hidTxt -Encoding UTF8
  wpr -stop (Join-Path $out 'bluetooth.etl') 2>&1 | Add-Content $hidTxt -Encoding UTF8
  Push-Location $out
  tracerpt hci.etl -o hci.xml -of XML -y 2>&1 | Out-Null
  Pop-Location
}

function Step($seconds, $text, $freq) {
  Write-Host ''
  Write-Host ">>> $text" -ForegroundColor Yellow
  [Sp12Hid]::Mark($text)
  PenLog "---- $text"
  if ($freq) { [console]::Beep($freq, 400) }
  $end = [Sp12Hid]::Now() + $seconds
  $last = ''
  while ([Sp12Hid]::Now() -lt $end) {
    $s = Get-PenState
    if ($s -ne $last) { PenLog "pen: $s"; [Sp12Hid]::Mark("pen: $s"); $last = $s }
    Start-Sleep -Milliseconds 500
  }
}

function Finish {
  [Sp12Hid]::StopReaders()
  $lines = New-Object System.Collections.Generic.List[string]
  $line = $null
  while ([Sp12Hid]::Lines.TryDequeue([ref]$line)) { $lines.Add($line) }
  $lines | Set-Content (Join-Path $out 'reports.txt') -Encoding UTF8
  Write-Host "  $($lines.Count) report lines"
  Stop-Traces
  Get-PenNodes | Format-List FriendlyName, InstanceId, Status | Out-String | Add-Content $penTxt -Encoding UTF8
  Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
  Write-Host ''
  Write-Host "Done: $out" -ForegroundColor Green
}

PenLog "pen at start: $(Get-PenState)"

# --- Modes -------------------------------------------------------------------
switch ($Mode) {
  'pair' {
    while ((Get-PenState) -ne 'not paired') {
      Write-Host "The pen looks paired ($(Get-PenState))." -ForegroundColor Cyan
      Write-Host 'Remove "Surface Slim Pen 2" in Settings > Bluetooth & devices, then press Enter' -ForegroundColor Cyan
      $answer = Read-Host '(or type go if it is already removed)'
      if ($answer -eq 'go') { break }
    }
    Snapshot 'before pairing'
    Start-Traces
    [Sp12Hid]::ResetClock()
    Start-Readers
    Step 5 'Capture running. Wait...' $null
    Write-Host ''
    Write-Host '>>> Now touch the pen tip to the screen (and write a little)' -ForegroundColor Yellow
    [console]::Beep(1200, 400)
    [Sp12Hid]::Mark('touch the pen to the screen')
    $deadline = [Sp12Hid]::Now() + $Seconds
    $last = ''
    while ([Sp12Hid]::Now() -lt $deadline) {
      $s = Get-PenState
      if ($s -ne $last) { PenLog "pen: $s"; [Sp12Hid]::Mark("pen: $s"); $last = $s }
      if ($s -match 'connected=True') { break }
      Start-Sleep -Milliseconds 500
    }
    Step 10 'Paired (or timed out); keep writing for 10 s' $null
    Snapshot 'after pairing'
    Step 2 'Done' 1600
  }
  'watch' {
    Write-Host "Watching the pen for up to $Minutes minutes (pen docked, keyboard attached)." -ForegroundColor Cyan
    $end = (Get-Date).AddMinutes($Minutes)
    $last = ''
    $dropped = $false
    while ((Get-Date) -lt $end) {
      $s = Get-PenState
      if ($s -ne $last) { PenLog "pen: $s"; Write-Host "$(Get-Date -Format 'HH:mm:ss') pen: $s"; $last = $s }
      if ($s -notmatch 'connected=True') { $dropped = $true; break }
      Start-Sleep -Seconds 5
    }
    if (-not $dropped) {
      Write-Host 'The pen stayed connected the whole time.' -ForegroundColor Green
      PenLog 'stayed connected'
      Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
      return
    }
    [console]::Beep(1200, 300); [console]::Beep(1200, 300); [console]::Beep(1200, 300)
    Write-Host 'The pen disconnected. Press Enter to start the capture (do not move the pen yet).' -ForegroundColor Cyan
    Read-Host | Out-Null
    Snapshot 'docked, disconnected'
    Start-Traces
    [Sp12Hid]::ResetClock()
    Start-Readers
    Step 10 'Capture running. Leave the pen docked...' $null
    Step 30 'Pull the pen OUT of the cradle now (low beep)' 500
    Snapshot 'pulled out'
    Step 20 'Put the pen back IN the cradle (high beep)' 1200
    Step 2 'Done' 1600
  }
  'cradle' {
    Write-Host 'Take the pen OUT of the cradle, then press Enter.' -ForegroundColor Cyan
    Read-Host | Out-Null
    Snapshot 'start (pen out)'
    Start-Traces
    [Sp12Hid]::ResetClock()
    Start-Readers
    Step 10 'Pen OUT: wait' $null
    Step 20 'Put the pen IN the cradle (high beep)' 1200
    Snapshot 'pen in'
    Step 20 'Take the pen OUT (low beep)' 500
    Snapshot 'pen out'
    Step 20 'Put the pen IN the cradle (high beep)' 1200
    Step 20 'Take the pen OUT (low beep)' 500
    Step 15 'Press the pen tail button once (pen out)' 800
    Step 15 'Put the pen IN, then press its tail button once' 1200
    Snapshot 'end (pen in)'
    Step 2 'Done' 1600
  }
}

Finish
