# IdeaPad5-14ITL05-Hackintosh

OpenCore EFI builder for the Lenovo IdeaPad 5 14ITL05 (i3-1115G4) → macOS Tahoe 26.7

OpenCore 1.0.8 (DEBUG build) · SMBIOS MacBookPro16,2 · WhateverXe graphics acceleration · this is the
EFI that was booted and tested on this laptop.

## Build

| OS | Command |
|---|---|
| macOS / Linux | `./build-efi.sh` (needs curl, unzip, python3; on macOS `xcode-select --install` gives python3) |
| Windows | `build-efi.cmd`, or `powershell -ExecutionPolicy Bypass -File .\build-efi.ps1` |

Options, the same on all three (Windows spelling in brackets):

| Option | What it does |
|---|---|
| `--usb /Volumes/OPENCORE` (`-Usb E:`) | copy the finished EFI (plus WhateverXe Graphics pkg) to a mounted FAT32 stick; an existing EFI is renamed `EFI.bak-<date>` |
| `--format /dev/disk4` or `/dev/sdb` (`-Format` + `-Usb E:`, as Administrator) | **erase** the stick first. Asks you to type `ERASE`, refuses non-USB and system disks |
| `--recovery` (`-Recovery`) | download Tahoe recovery from Apple, verify every chunk against Apple's chunklist, put it in `com.apple.recovery.boot/` |
| `--voodooi2c file.zip` (`-VoodooI2C file.zip`) | use a VoodooI2C CI build (smooth touchpad, see below) |

## Mac identity (serial / MLB / UUID / ROM)
The configs in this repo only have placeholders. On the first build the script runs OpenCore's own
`macserial` (from the OpenCore zip it downloads) to make a MacBookPro16,2 identity, saves it in
**`smbios.json`**, and reuses that file on every later build. Back it up: a new identity means
iCloud/iMessage see a different Mac. Check the serial at checkcoverage.apple.com and make sure it says
it's **not valid** (i.e. not a real Mac's) before signing in.

To keep the identity of an existing install, create `smbios.json` yourself before building:
```json
{ "model": "MacBookPro16,2", "serial": "C02XXXXXXXXX", "mlb": "C02XXXXXXXXXXXXXX",
  "uuid": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX", "rom": "112233445566" }
```
(read the values from your current `config.plist` → PlatformInfo → Generic; `rom` is hex). `smbios.json`
is in `.gitignore`, so it never ends up on GitHub.

Downloads are cached in `_downloads/`. If GitHub's API limit (60 requests/hour) is hit, the scripts fall back
to the release pages and then to the cache.

## Two touchpad variants (picked automatically)
- **release** (default): VoodooI2C 2.9.1 + `VoodooI2CTigerLakeInjector.kext`. Works, but in **polling mode**, so
  the cursor jumps when you move fast. 2.9.1 has no Tiger Lake I2C entry (the injector adds it), and its
  VoodooGPIO doesn't know the Tiger Lake GPIO chip `INT34C5`.
- **master** (with `--voodooi2c`): a CI build from github.com/VoodooI2C/VoodooI2C/actions (needs a GitHub
  login; download the newest `master` artifact zip). Interrupt mode, smooth tracking, uses
  `SSDT-TPAD-GPIO` (GPIO pin 0xC4 instead of APIC 0x44). Once a VoodooI2C release newer than 2.9.1
  exists, the CI build is no longer needed.

## Firmware facts this EFI is built around (all from this laptop's own logs/ACPI dump)
| Problem seen | Fix in config |
|---|---|
| Freeze at `EXITBS:START` | `AppleXcpmExtraMsrs` (required on Tiger Lake), Cpuid1Data `55060A00` (Comet Lake) + `ProvideCurrentCpuInfo` |
| Firmware has no MAT (`MAT support is 0`) | `EnableWriteUnprotector` on, `RebuildAppleMemoryMap` / `SyncRuntimePermissions` off |
| Panic `CR2 0xFF022058` | `MmioWhitelist` 0xFF000000 (kept mapped despite `DevirtualiseMmio`) |
| Recovery dmg "Unsupported" | `OpenHfsPlus.efi` |
| WhateverXe skipped | no `MinKernel`: Tahoe 26.7.x still reports Darwin 25.6.0 |
| Audio controller ignored | HDEF `class-code` 0x040300 (firmware exposes Smart Sound class 0x0401) |
| SIP stuck at 0x3 | `csr-active-config` in NVRAM → Delete, so 0x803 is actually written |
| Root patch | `amfi=0x80 ipc_control_port_options=0` in boot-args |

## After installing macOS
1. Install `WhateverXe-Graphics/*.pkg`, allow it, reboot → acceleration.
2. **Audio**: Tahoe has no AppleHDA. Root-patch it back (OCLP fork "Modern Audio" + KDK for your build).
   SIP 0x803 and the amfi boot-args are already set. Revert from Recovery with
   `bless --mount "/Volumes/Macintosh HD" --bootefi --last-sealed-snapshot`.
3. **Wi-Fi**: itlwm + the HeliPort app. To join a network before HeliPort works (installer, recovery), put
   SSID/password in `itlwm.kext/Contents/Info.plist` → `WiFiConfig` → `WiFi_1` (plain text — remove it afterwards).
4. Copy `EFI/` to the SSD's EFI partition (`sudo diskutil mount disk0s1`). Keep the stick as a rescue disk.

## Known limits
- Brightness tops out lower than the firmware's (WhateverXe sets 99.8% PWM duty, the panel is still dimmer).
  Not fixable in the config — report to WhateverXe.
- Built-in microphone (DMIC through the Smart Sound DSP) has no macOS driver.
- USB ports aren't mapped (map with USBToolBox if a port misbehaves).
- Debugging: set `Misc → Debug → Target` to 67 to get `opencore-*.txt` logs on the EFI partition again.
