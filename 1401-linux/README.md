# 1401 on Linux

[1401](https://github.com/nullmoth/1401) by NullMoth only ships for Windows, but most of it already runs on Linux:

| 1401 step | On Linux |
|---|---|
| Check this PC (`p1401.scan`, Hardware Sniffer) | works as is: Hardware Sniffer has a Linux backend (sysfs, `lspci`, `lsusb`, ACPI from `/sys/firmware/acpi/tables`) |
| Build the Mac setup (`python3 -m p1401 build`) | works as is: pure Python, `ocvalidate.linux` from the same OpenCore release |
| Create the macOS stick (`p1401.usbwriter`) | Windows-only (PowerShell + diskpart) → replaced by `linux_write.py` |

`linux_write.py` erases the stick with Linux tools (MBR, one active FAT32 partition labelled `1401`, max 16 GiB, the
same layout 1401 writes on Windows) and then calls 1401's own payload step, so the Apple recovery download, the signed
chunklist checks, the read-back, the EFI copy check and the NullMoth driver on the stick are 1401's code, unchanged.

1401 itself is not copied here: the script downloads it from GitHub at a pinned commit (1401 3.0). 1401 is under the
PolyForm Noncommercial License 1.0.0.

## Use

On any Linux with Python 3.12 or newer (Debian 13, Ubuntu 24.04+, Arch, Fedora), booted on the PC you want macOS on:

```bash
git clone https://github.com/Mast3rM0ds/IdeaPad5-14ITL05-Hackintosh
cd IdeaPad5-14ITL05-Hackintosh/1401-linux
sudo ./1401-linux.sh all              # scan, build for Tahoe, write the stick (it asks which one)
```

Or step by step: `sudo ./1401-linux.sh scan`, then `build`, then `write`.

| Option | |
|---|---|
| `--macos 24` | Sequoia 15 instead of Tahoe 26 (`25`, the default) |
| `--disk /dev/sdX` | the stick to erase (otherwise you pick it from a list of USB disks) |
| `--new-identity` | new serial numbers instead of the previous build's |
| `--yes` | do not ask before erasing |
| `RECOVERY_DIR=/path` (env) | use a `BaseSystem.dmg` + `BaseSystem.chunklist` you already have instead of downloading |

Missing tools (`pciutils usbutils parted dosfstools git sudo unzip`) are installed with apt, pacman or dnf.
Everything goes into `work/` next to the script: `work/scan` (Report.json + ACPI), `work/efi/EFI` (the OpenCore
folder), `work/build.json` (what 1401 decided and which rules fired).

## Safety

Only a whole USB disk can be erased. A disk is refused if Linux runs from it, if it holds an APFS, HFS+ or Windows
recovery partition, if it is read-only, smaller than 2 GiB or larger than 256 GiB. The stick is looked up again by
serial and size right before erasing, and you have to type its name (`sdb`) to confirm.

## Scan notes

- Let the NVIDIA card use a Linux driver (nouveau on a fresh Debian is fine): Hardware Sniffer finds GPUs through
  `/sys/class/drm`, so a card with no driver bound is missed.
- Boot Linux in UEFI mode, the way macOS will boot.
