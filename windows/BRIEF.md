# Surface Pro 12 (Intel): Windows-side investigation brief

This brief is for a Claude session running on the Windows install of this Surface Pro 12 (Intel, Panther Lake). The same machine dual-boots Arch Linux (Omarchy), where the peripheral bring-up happens. We're stuck on three things where only Windows has the answer.

Work it out here, with whatever tools help: WinDbg, Ghidra, ETW/WPR, PowerShell, or public Microsoft symbols (`srv*C:\symbols*https://msdl.microsoft.com/download/symbols`). Write the findings back as Markdown. The Linux session reads them from the Windows partition, which it mounts read-only.

## Ground rules
- **Output:** `C:\Users\turbi\sp12\out\<task>\RESULTS.md`, plus any raw captures next to it (`.etl`, `.xml`, `.txt`). One folder per task: `nfc`, `pen-keys`, `pen-charger`, `psr`.
- **Keys and secrets never go in files.** That covers Bluetooth link keys (LTK/IRK/ERand/EDIV), the pen's "Security Key", and anything read from `BTHPORT\Parameters\Keys`. When you need to check that a derivation reproduces a stored key, compare in memory and write only "matches" or "doesn't match". The one exception is `windows\sp12-bt-keys.ps1`: it already exports keys to `out\bt-keys.reg` for the Linux side, and that file is private.
- **Don't write to device EEPROM or firmware.** No NFC EEPROM writes and no firmware updates. Reading is fine, and so are runtime or RAM-only settings.
- **Boot changes need care.** BitLocker may be on. Before `bcdedit /debug on`, turning off Secure Boot, or anything else that changes boot measurements, check `manage-bde -status`, have the recovery key ready, and ask the user first.
  - Static analysis plus public symbols, ETW and user-mode debugging usually avoid kernel debugging entirely. Prefer them.
  - WinDbg local kernel debugging (`lkd`) needs `/debug on`.
- **Ask the user before any physical step:** docking the pen, tapping a card, attaching or detaching the keyboard. Say exactly what to do and when. Timed captures start only after they say they're ready.
- **Record method, not just results:** exact commands, provider GUIDs, function names and addresses, and what didn't work. Linux has to reimplement whatever you find.

## Machine facts
- **Board:** Surface Pro 12 (Intel), Panther Lake, xe3lpd display. Surface Flex Keyboard (attached, or over Bluetooth). Surface Slim Pen 2 (045E:0C0F).
- **Bluetooth adapter:** `00:1A:2B:3C:4D:5E`, Intel BE201 (`btintel_pcie`).
- **Pen, loosely coupled (LC) identity on Windows:** static `C6:12:34:56:78:9A`. It advertises from an RPA after docking.
- **Surface Aggregator (SSAM):** the embedded controller. The keyboard's HID devices (0C8B, 0C8D, 0C8E, 0C8F, 0C90) are reached through it when the keyboard is attached.
- **NFC:** NXP PN560 (`ACPI\1FC93002`, I²C 0x28), with an NCI 2.0 firmware info reply of `1f ca 01 01 40`. Its client driver is `NxpNfcClientDriver` (UMDF, over NfcCx). The antenna is at the top-left of the screen (front), with about 15 mm range.

---

## Task 1: NFC. Why does Windows read a contactless card when Linux can't?
**Symptom:**
- On Linux (stock `nxp-nci` plus a GPIO fix), a phone (HCE) is detected on every tap as ISO14443-A.
- A passive contactless credit card is never detected on Linux. Windows reads the same card easily.
- Our guess: RF settings (field strength, receiver gain), or a card-detection or polling mode the NXP client driver sets up at runtime.

**Already known:**
- **EEPROM config:** Windows' `CustomEEPROMConfigBlob` is three NXP TLVs (A011, A068, A00B). The chip already holds all three byte-for-byte; Linux reads them back with `CORE_GET_CONFIG`.
- **Runtime config:** Windows' `RfConfigData` is empty.
- **Power sub-state:** `CORE_SET_POWER_SUB_STATE` isn't needed for phones.
- **How Windows sees cards:** through the proximity path. Smart Card reader states stay empty (`cards.csv` from the earlier probe).
- **NfcCx source:** the class extension is open source (microsoft/NFC-Class-Extension-Driver).
  - Its NCI layer logs packet hex dumps through WPP GUID `696D4914-12A4-422C-A09E-E7E0EB25806A`.
  - Four more NfcCx WPP GUIDs, plus the TraceLogging provider `6E6BACF6-...`, are enabled in `sp12-nfc-probe.ps1`.
  - The NXP client driver can inject vendor NCI commands at NfcCx sequence points.
- **Earlier capture:** `out\nfc-20260924-141840\trace\nfc.etl` exists, but the WPP messages weren't decoded (no TMF), so the NCI packets weren't recovered.

**Wanted:**
1. **The full NCI exchange**, from NFC device start or restart through a card tap, as decoded packets: every `CORE_SET_CONFIG`, every proprietary (`2F xx`) command, `RF_DISCOVER_CMD` with its technologies and modes, and `RF_INTF_ACTIVATED_NTF` for the card.
   - Ways in: decode the WPP with public PDBs or TMFs for `NfcCx.dll`/`NxpNfcClientDriver.dll` (`tracefmt`/`traceview`); read the raw WPP payload bytes; or set breakpoints on the transport write in a user-mode debugger attached to the `WUDFHost` that hosts the NXP driver.
2. **Where the difference comes from:** is it a runtime config or an RF-parameter set applied in RAM (the NXP `A0xx` tags other than the EEPROM three), or a different discovery configuration? Name the exact TLVs and values.
3. **The same exchange with a phone tap,** for comparison, if it's cheap.

**Linux side:** it can send raw NCI over I²C with the driver unbound, and can add RAM-only settings to `nxp-nci`.

---

## Task 2a: Pen touch-to-pair. How does Windows derive the pen's LC bond keys?
**Goal:** Linux pairs the pen the way Windows does, on the first screen touch, with no Windows install needed.

**Already known:**
- **Touch-to-pair seen over the air:**
  - About 4 s after the pen first touches the screen, Windows puts the pen's static address on the accept list and connects.
  - It starts encryption straight away with an LTK it already has. There's no SMP pairing.
- **Where the pen ID comes from:** the digitizer (Elan/G6Touch, also 045E:0C8F on the keyboard's charger) supplies a 4-byte Pen ID (usage page FF0F usage 0x50) in input reports 0x54 and 0x6E of its FFF4:0001 collection. That collection also carries the address (FFF4:0x02) and flags 0x08, 0x11 (known host) and 0x12 (auto-bonding capable).
- **Address, from the static analysis of `SurfacePenBleLcAddrAdaptationDriver.sys`, function `ConvertPenIDToMACAddress` (0x140003454):**
  - `h` = SHA1(`f876af012e1c2840918f6f605e6b1fd6` || PenID, big-endian); take the first 8 bytes as a little-endian integer.
  - If flag 0x12 is set: address = `((h ^ hostAddr) & 0x3FFFFFFFFFFF) | 0xC00000000000`.
  - Otherwise: address = `(~h & 0x3FFFFFFFFFFF) | 0xC00000000000`.
  - `hostAddr` is what the host wrote in feature 0x56.
- **Security key:**
  - Output report 0x55 carries an 8-byte "Security Key" (usage 0x04) for a pen address.
  - The filter driver stores it under `Parameters\LCDATA`.
  - `ioctl_adaptation_cmd` = `0x9C402401` checks a signature against it.
- **Host setup Windows performs:**
  1. Write feature 0x70 = `70 01` (host auto-bonding capability).
  2. Write feature 0x56 = `56 <host BD_ADDR, LSB first> <flag>`.
  3. Wait for input 0x54/0x6E.
  4. Reply with output 0x55 (address + 0x08 bit + 8-byte key).
- **Service side:** it's in `C:\Windows\System32\Microsoft.Bluetooth.Service.dll`, not a separate PenService. `devicechargingdock.cpp` and the OOB pairing code call three HID feature functions.
- **LTK not seen on air:** Windows logs LE Start Encryption without parameters, so the LTK never shows up in the HCI trace.

**Wanted:**
1. **The key derivation:** how the LTK, IRK, EDIV and Rand, stored under `BTHPORT\Parameters\Keys\001a2b3c4d5e\c6123456789a`, are derived. Candidate inputs: the Pen ID, the 8-byte Security Key, the host address, constants, and the value Windows sends in 0x55.
   - Look in `Microsoft.Bluetooth.Service.dll` (LC / OOB pairing / "AutoBonding" code), `bthlcpen.sys` and the BthLE stack. Public symbols should give function names.
   - Look for BCrypt/SymCrypt calls (SHA-256, HMAC, AES-CMAC, SP800-108 KDF) near the code that writes the `Keys` registry values or calls the LE pairing APIs.
2. **Where the 8-byte Security Key comes from:** random per pairing, or derived? Is it the pen's key or the host's?
3. **Proof:** reproduce the stored keys from the inputs, comparing in memory only and writing "matches" or "doesn't match". Record the recipe as pseudocode with every constant.

---

## Task 2b: Pen charging status. Where does Windows get "pen charging" from?
**Already known:**
- **Report layout:** the keyboard charger (045E:0C8E, collection FFF4:0x0A/0x0B) defines input report 0x14: 6-byte pen address (usage 0x02), bits 0x08, 0x0D and 0x0E, then battery 0–100 (usage 0x0C).
  - `devicechargingdock.cpp` in `Microsoft.Bluetooth.Service.dll` only reads it.
- **On Linux, with the keyboard attached:** report 0x14 never arrives, and nothing arrives at the SSAM level when the pen docks. A get-feature request for 0x14 times out.
- **Setup doesn't unlock it:** writing Windows' `70 01` and `56 <addr> 00` setup made no difference.
- **Pen link while docked:** the pen hangs up by itself about 25 s after docking (reason 0x13). On Windows it seemed to stay connected longer, but the earlier Windows capture had the keyboard on Bluetooth, not attached.

**Wanted, with the keyboard attached:**
1. **Does 0x14 arrive?** Dock and undock the pen and see whether Windows receives 0x14 from `HID\VID_045E&PID_0C8E&Col0x` (the FFF4:0x0B collection). Log the timing and decode the bits.
2. **If it arrives:** what makes the charger send it? Trace SSAM and the Surface drivers (`surface_hid_mini`, `SurfaceIntegrationDriver`, the SAM ETW providers) for any request the host sends first. Is it periodic or event-driven?
3. **What the Windows UI shows:** does the pen charging state or battery come from 0x14, or from the pen's GATT Battery Level while it's connected?

---

## Task 3: OLED PSR2. What does Windows do differently?
**Symptom:** under Linux (`xe` driver), PSR2 (selective update, selective fetch) makes the OLED pulse faintly on a mostly still screen. PSR1 or PSR off removes it; Windows shows no pulse. The panel is eDP 1.5 with PSR2 capability (DPCD 0x070 = 03), and brightness goes through Intel's HDR AUX interface in nits.

**Wanted (quick, low priority):**
1. **Does Windows use PSR2 on this panel at all?** Look at the Intel graphics driver's registry settings (display class key `{4d36e968-e325-11ce-bfc1-08002be10318}\000x`: anything with PSR, SelectiveUpdate, PanelReplay or DPST in the name), Intel Graphics Software, or the Intel display ETW providers.
2. **If Windows uses PSR2,** find its parameters if they're exposed: SU granularity, wake/IO lines, early transport.
3. **Don't dump the VBT here:** Linux can read it from debugfs.

---

## Handing back
For each task, `RESULTS.md` should have:
- A three-line summary.
- The method, as exact commands.
- The findings, including byte layouts and pseudocode.
- What failed, and what you'd try next.

A partial answer is still worth writing up: a decoded NCI log alone would unblock Task 1.
