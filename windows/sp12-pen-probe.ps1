<#
.SYNOPSIS
  Surface Pro 12 pen cradle probe: what the Flex Keyboard's pen charger
  reports when the Slim Pen docks and undocks, and what Windows' Bluetooth
  stack does meanwhile. No debugger needed.

.DESCRIPTION
  Run from an elevated Windows PowerShell 5.1 prompt, keyboard attached:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    C:\Users\turbi\sp12\sp12-pen-probe.ps1

  The keyboard's HID device 045E:0C8E carries the pen charger ("Surface
  Wireless Pen Charger Hotkey" binds its collection 1). Its vendor page FFF4
  collections hold a pen status input report (0x14: 6 bytes, 3 flag bits and
  a 0-100 value) and pairing reports with features 0x56, 0x70 and 0x73. Linux
  never receives report 0x14, presumably because Windows' PenService first
  sets a feature (a "host auto-bonding capability"). This script only READS
  features and input reports; it never writes to the device.

  Collects, into <script dir>\out\pen-<timestamp>\:
    hid.txt         every 045E HID collection (usage page/usage, report sizes)
                    and the 0C8E vendor features, read before, during and
                    after the dock test
    reports.txt     timestamped input reports from every 0C8E collection and
                    the digitizer while you dock and undock the pen
    bluetooth.etl   Windows Bluetooth stack trace (Microsoft's
                    BluetoothStack.wprp, verbose) across the same window
    bluetooth.xml   the same, decoded with tracerpt
  and zips the folder next to it.

  Follow the prompts and beeps: a high beep means put the pen IN its cradle,
  a low beep means take it OUT. Don't touch the keyboard or touchpad.
#>
param([switch]$NoTrace)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $root "out\pen-$stamp"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$hidTxt = Join-Path $out 'hid.txt'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning 'Not elevated: the Bluetooth trace will be skipped.' }

Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class Sp12Hid {
  [StructLayout(LayoutKind.Sequential)]
  struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid g; public int flags; public IntPtr r; }
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

  [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
  [DllImport("hid.dll")] static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES a);
  [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
  [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
  [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, ref HIDP_CAPS c);
  [DllImport("hid.dll")] static extern bool HidD_GetFeature(SafeFileHandle h, byte[] b, int n);
  [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
  static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
  [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
  static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA x);
  [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
  static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA x, IntPtr d, int n, out int req, IntPtr di);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern SafeFileHandle CreateFile(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);

  public static List<string> Paths() {
    var list = new List<string>();
    Guid g; HidD_GetHidGuid(out g);
    IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
    var x = new SP_DEVICE_INTERFACE_DATA(); x.cbSize = Marshal.SizeOf(x);
    for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref x); i++) {
      int req; SetupDiGetDeviceInterfaceDetail(set, ref x, IntPtr.Zero, 0, out req, IntPtr.Zero);
      IntPtr buf = Marshal.AllocHGlobal(req);
      Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
      if (SetupDiGetDeviceInterfaceDetail(set, ref x, buf, req, out req, IntPtr.Zero))
        list.Add(Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4)));
      Marshal.FreeHGlobal(buf);
    }
    SetupDiDestroyDeviceInfoList(set);
    return list;
  }

  // Query access (0) is enough for attributes and caps; features need read/write.
  public static SafeFileHandle Open(string path, bool rw, bool overlapped) {
    return CreateFile(path, rw ? 0xC0000000u : 0u, 3u, IntPtr.Zero, 3u, overlapped ? 0x40000000u : 0u, IntPtr.Zero);
  }

  public static string Describe(string path, out HIDP_CAPS caps) {
    caps = new HIDP_CAPS();
    using (var h = Open(path, false, false)) {
      if (h.IsInvalid) return "open failed " + Marshal.GetLastWin32Error();
      var a = new HIDD_ATTRIBUTES(); a.Size = Marshal.SizeOf(a);
      HidD_GetAttributes(h, ref a);
      IntPtr p;
      if (!HidD_GetPreparsedData(h, out p)) return string.Format("{0:X4}:{1:X4} no preparsed data", a.VendorID, a.ProductID);
      HidP_GetCaps(p, ref caps);
      HidD_FreePreparsedData(p);
      return string.Format("{0:X4}:{1:X4} page {2:X4} usage {3:X4} in {4} out {5} feat {6}",
        a.VendorID, a.ProductID, caps.UsagePage, caps.Usage,
        caps.InputReportByteLength, caps.OutputReportByteLength, caps.FeatureReportByteLength);
    }
  }

  public static string GetFeature(string path, byte id, int len) {
    if (len <= 0) return "no features";
    using (var h = Open(path, true, false)) {
      if (h.IsInvalid) return "open failed " + Marshal.GetLastWin32Error();
      var b = new byte[len]; b[0] = id;
      if (!HidD_GetFeature(h, b, len)) return "error " + Marshal.GetLastWin32Error();
      return BitConverter.ToString(b).Replace("-", " ");
    }
  }

  // Background readers: one thread per collection, lines queued with a timestamp.
  public static ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
  static Stopwatch clock = Stopwatch.StartNew();
  static volatile bool stop;
  public static void ResetClock() { clock.Restart(); }
  public static double Now() { return clock.Elapsed.TotalSeconds; }
  public static void Mark(string what) { Lines.Enqueue(string.Format("{0,8:F2} ---- {1}", Now(), what)); }

  public static bool StartReader(string path, string name, int len) {
    var h = Open(path, true, false);
    if (h.IsInvalid) h = CreateFile(path, 0x80000000u, 3u, IntPtr.Zero, 3u, 0, IntPtr.Zero);
    if (h.IsInvalid) { Lines.Enqueue(name + ": open failed " + Marshal.GetLastWin32Error()); return false; }
    var fs = new FileStream(h, FileAccess.Read, len, false);
    var t = new Thread(() => {
      var buf = new byte[len];
      while (!stop) {
        int n;
        try { n = fs.Read(buf, 0, len); } catch (Exception e) { Lines.Enqueue(name + ": " + e.Message); return; }
        if (n > 0) Lines.Enqueue(string.Format("{0,8:F2} {1} {2}", Now(), name, BitConverter.ToString(buf, 0, n).Replace("-", " ")));
      }
    });
    t.IsBackground = true; t.Start();
    return true;
  }
  public static void StopReaders() { stop = true; }
}
"@

function Log($text) { $text | Add-Content $hidTxt -Encoding UTF8 }

# --- 1. Inventory -------------------------------------------------------------
Write-Host '[1/4] HID inventory'
$cols = @()
foreach ($p in [Sp12Hid]::Paths()) {
  if ($p -notmatch 'vid_045e|vid_04f3') { continue }
  $caps = New-Object Sp12Hid+HIDP_CAPS
  $d = [Sp12Hid]::Describe($p, [ref]$caps)
  Log "$d`r`n    $p"
  $cols += [pscustomobject]@{ Path = $p; Desc = $d; Page = $caps.UsagePage; Usage = $caps.Usage
    In = $caps.InputReportByteLength; Feat = $caps.FeatureReportByteLength }
}
$charger = $cols | Where-Object { $_.Path -match 'pid_0c8e' }
$vendor = $charger | Where-Object { $_.Page -eq 0xFFF4 }
if (-not $charger) { Write-Warning 'No 045E:0C8E collections: is the keyboard attached?' }

function Snapshot($label) {
  Log "`r`n===== features: $label ====="
  foreach ($c in $vendor) {
    foreach ($id in 0x56, 0x70, 0x73) {
      Log ("  {0:X4}:{1:X4} feature {2:X2}: {3}" -f $c.Page, $c.Usage, $id, [Sp12Hid]::GetFeature($c.Path, [byte]$id, $c.Feat))
    }
  }
  [Sp12Hid]::Mark("features: $label")
}
Snapshot 'start (pen as it is now)'

# --- 2. Traces and readers ----------------------------------------------------
$etl = Join-Path $out 'bluetooth.etl'
$wprp = Join-Path $root 'BluetoothStack.wprp'
$traceOn = $false
if ($isAdmin -and -not $NoTrace -and (Test-Path $wprp)) {
  Write-Host '[2/4] Starting the Bluetooth trace'
  wpr -cancel 2>$null | Out-Null
  wpr -start "$wprp!BluetoothStack.Verbose" -filemode 2>&1 | Add-Content $hidTxt -Encoding UTF8
  $traceOn = $LASTEXITCODE -eq 0
}

[Sp12Hid]::ResetClock()
foreach ($c in $charger) {
  if ($c.In -gt 0) {
    $name = '{0:X4}:{1:X4}' -f $c.Page, $c.Usage
    if ([Sp12Hid]::StartReader($c.Path, "0C8E/$name", $c.In)) { Log "reading 0C8E/$name ($($c.In) bytes)" }
  }
}
# The digitizer's vendor collections too, in case the pen reports through it
foreach ($c in ($cols | Where-Object { $_.Path -match 'vid_04f3' -and $_.Page -ge 0xFF00 -and $_.In -gt 0 })) {
  $name = '{0:X4}:{1:X4}' -f $c.Page, $c.Usage
  [Sp12Hid]::StartReader($c.Path, "04F3/$name", $c.In) | Out-Null
}

# --- 3. Guided dock / undock ---------------------------------------------------
function Step($seconds, $text, $freq) {
  Write-Host ''
  Write-Host ">>> $text" -ForegroundColor Yellow
  [Sp12Hid]::Mark($text)
  if ($freq) { [console]::Beep($freq, 400) }
  $end = [Sp12Hid]::Now() + $seconds
  while ([Sp12Hid]::Now() -lt $end) { Start-Sleep -Milliseconds 250 }
}

Write-Host ''
Write-Host '[3/4] Dock test. Take the pen OUT of the cradle now, then press Enter.' -ForegroundColor Cyan
Read-Host | Out-Null
[Sp12Hid]::ResetClock()
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
Step 3 'Done' 1600

[Sp12Hid]::StopReaders()
$lines = New-Object System.Collections.Generic.List[string]
$line = $null
while ([Sp12Hid]::Lines.TryDequeue([ref]$line)) { $lines.Add($line) }
$lines | Set-Content (Join-Path $out 'reports.txt') -Encoding UTF8
Write-Host "  $($lines.Count) lines of reports and markers"

# --- 4. Stop, decode, pack -----------------------------------------------------
if ($traceOn) {
  Write-Host '[4/4] Stopping the trace (this can take a minute)'
  wpr -stop $etl 2>&1 | Add-Content $hidTxt -Encoding UTF8
  Push-Location $out
  tracerpt bluetooth.etl -o bluetooth.xml -of XML -summary bt-summary.txt -y 2>&1 | Out-Null
  Pop-Location
}
$zip = "$out.zip"
Compress-Archive -Path "$out\*" -DestinationPath $zip -Force
Write-Host ''
Write-Host "Done: $out" -ForegroundColor Green
Write-Host "      $zip"
