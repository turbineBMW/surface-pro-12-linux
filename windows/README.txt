SP12 Windows probes - run in Windows; results come back to Linux (C: is mounted there)

Open "Windows PowerShell" as Administrator, then:
  Set-ExecutionPolicy -Scope Process Bypass -Force

Pen (Phase 8a) - keyboard ATTACHED; follow the prompts and beeps:
  C:\Users\turbi\sp12\sp12-pen-probe.ps1 -Mode pair
      touch-to-pair: remove the pen in Settings > Bluetooth first, then touch
      the pen to the screen when it beeps
  C:\Users\turbi\sp12\sp12-pen-probe.ps1 -Mode watch
      pen docked: watches for up to 30 min (-Minutes N) whether the pen drops
      its Bluetooth link; if it does, it beeps three times and captures you
      pulling the pen out
  C:\Users\turbi\sp12\sp12-pen-probe.ps1 -Mode cradle
      cued dock/undock (high beep = pen IN, low beep = pen OUT)

Bluetooth pairing keys (pen "loosely coupled" bond for Linux) - pen paired in
Windows (touch it to the screen once); exports to out\bt-keys.reg (keep private):
  C:\Users\turbi\sp12\sp12-bt-keys.ps1

NFC card (Phase 8b) - restarts the NFC device, then asks for card taps:
  C:\Users\turbi\sp12\sp12-nfc-probe.ps1

Light sensor (done; kept for reference):
  C:\Users\turbi\sp12\sp12-sensor-probe.ps1

Results land in C:\Users\turbi\sp12\out\<name>-<timestamp> (and a .zip).
-NoTrace skips the ETW trace in each.

BluetoothStack.wprp is Microsoft's Bluetooth tracing profile, unmodified, from
github.com/microsoft/busiotools (bluetooth/tracing, MIT licence).

Shut down or restart normally afterwards (Fast Startup is off, so C: is clean for Linux).
