SP12 Windows probes - run in Windows; results come back to Linux (C: is mounted there)

Open "Windows PowerShell" as Administrator, then:
  Set-ExecutionPolicy -Scope Process Bypass -Force

Pen cradle (Phase 8a) - keyboard ATTACHED, about 3 minutes, follow the prompts
(high beep = pen IN the cradle, low beep = pen OUT; don't touch keyboard/touchpad):
  C:\Users\turbi\sp12\sp12-pen-probe.ps1

NFC card (Phase 8b) - restarts the NFC device, then asks for card taps:
  C:\Users\turbi\sp12\sp12-nfc-probe.ps1

Light sensor (done; kept for reference):
  C:\Users\turbi\sp12\sp12-sensor-probe.ps1

Results land in C:\Users\turbi\sp12\out\<name>-<timestamp> (and a .zip).
-NoTrace skips the ETW trace in each.

BluetoothStack.wprp is Microsoft's Bluetooth tracing profile, unmodified, from
github.com/microsoft/busiotools (bluetooth/tracing, MIT licence).

Shut down or restart normally afterwards (Fast Startup is off, so C: is clean for Linux).
