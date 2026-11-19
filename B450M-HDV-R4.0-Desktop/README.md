# ASRock B450M-HDV R4.0 + Ryzen 5 3500X → macOS Tahoe

OpenCore 1.0.8 (DEBUG build) · SMBIOS **MacPro7,1** · AMD_Vanilla kernel patches (core count `06`) ·
OpenCanopy graphical boot picker.

| Part | Status |
|---|---|
| Ryzen 5 3500X (Zen 2, 6C/6T) | AMD_Vanilla patches, `ProvideCurrentCpuInfo` |
| Realtek RTL8111H ethernet | `RealtekRTL8111.kext`. Needed for the internet recovery install ("failed to download" without it) |
| 1 TB NVMe | native + `NVMeFix.kext` |
| Realtek ALC887 audio | `AppleALC` + `alcid=1`, **but** Tahoe has no AppleHDA, so root-patch it after install |
| RTX 3050 | **no macOS driver**: no acceleration until you install your own NVIDIA driver after install |
| USB | not mapped yet (map with USBToolBox if a port misbehaves) |

## Build (macOS or Linux; needs curl, unzip, python3)
```bash
./build-efi.sh --format /dev/disk4 --recovery   # ERASE stick, EFI + Tahoe recovery (diskutil list external)
./build-efi.sh --usb /Volumes/OPENCORE          # only (re)copy the EFI to a mounted FAT32 stick
```
The Mac identity is generated once into `smbios.json` (gitignored) and reused on every build.

## BIOS settings (F2 / Del)
- **Above 4G Decoding: Enabled**, Resizable BAR: Disabled (or leave `ResizeAppleGpuBars` at -1)
- Secure Boot: Disabled · CSM: Disabled · Fast Boot: Disabled
- SVM can stay on. If it hangs very early, set a fixed DRAM speed (XMP off) once, to rule out RAM.
- If it stops at `PCI configuration begin`: `npci=0x2000` is already set. Check Above 4G.

## The RTX 3050
macOS has never had drivers for NVIDIA RTX (Turing/Ampere) cards, and the 3500X has no iGPU, so the
installer runs on the firmware framebuffer: slow, no acceleration. Some setups lose the picture once
macOS takes over the display; if the screen goes black after the verbose text, try the other output
(DisplayPort vs HDMI) first.

## After install
1. Copy `EFI/` to the NVMe's EFI partition (`sudo diskutil mount disk0s1`).
2. Audio: AppleHDA root patch (OCLP fork "Modern Audio" + KDK). SIP 0x803 and `amfi=0x80` are already set.
3. Picker: `HideAuxiliary` is on. Press **Space** in the picker for Recovery, Reset NVRAM and the shell.
