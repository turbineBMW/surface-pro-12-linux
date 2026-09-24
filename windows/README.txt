SP12 sensor probe - run in Windows, results come back to Linux (C: is mounted there)

1. Open "Windows PowerShell" as Administrator.

2. Run the probe (about 2 minutes; it prompts room / covered / flashlight / room):
     Set-ExecutionPolicy -Scope Process Bypass -Force
     C:\Users\turbi\sp12\sp12-sensor-probe.ps1

Results land in C:\Users\turbi\sp12\out\<timestamp> (and a .zip).
Add -NoTrace to skip the ETW trace.

Shut down or restart normally afterwards (Fast Startup is off, so C: is clean for Linux).
