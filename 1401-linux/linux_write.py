#!/usr/bin/env python3
"""Linux stick writer for 1401 (https://github.com/nullmoth/1401).

1401's own writer (p1401/usbwriter.py) only erases sticks on Windows (PowerShell + diskpart). This does the erase with
Linux tools and then hands the mounted stick to 1401's own payload step (usbwriter._write_payload), so the recovery
download, Apple chunklist checks, read-back, EFI copy/verify and NullMoth driver staging are exactly 1401's.

    linux_write.py --p1401 <1401 checkout> --efi <build dir> --report <Report.json> --darwin 25 [--disk /dev/sdX]
                   [--recovery-dir DIR] [--allow-large] [--yes]

Layout: MBR, one FAT32 partition (label 1401, active), capped at 16 GiB - the same layout 1401 writes on Windows.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

GiB = 1 << 30
MIN_DISK, MAX_DISK, PART_CAP = 2 * GiB, 256 * GiB, 16 * GiB
# partition types only an installed OS has: APFS, HFS+, Windows recovery (GPT GUIDs), and the MBR ids for HFS (af)
OS_PARTTYPES = {"7c3457ef-0000-11aa-aa11-00306543ecac", "48465300-0000-11aa-aa11-00306543ecac",
                "de94bba4-06d1-4d40-a16a-bfd50179d6ac", "0xaf"}
SYSTEM_MOUNTS = ("/", "/boot", "/boot/efi", "/efi", "/home", "/usr", "/var")


def die(msg, code=1):
    print(f"STOP {msg}", flush=True)
    sys.exit(code)


def run(*args, check=True):
    try:
        p = subprocess.run(args, capture_output=True, text=True)
    except FileNotFoundError:
        if check:
            die(f"{args[0]} is not installed")
        return ""
    if check and p.returncode != 0:
        die(f"{' '.join(args)} failed: {(p.stderr or p.stdout).strip()[-400:]}")
    return p.stdout


def lsblk():
    out = run("lsblk", "-J", "-b", "-o", "NAME,PATH,SIZE,TRAN,TYPE,RO,RM,MODEL,SERIAL,MOUNTPOINTS,PARTTYPE,FSTYPE,LABEL")
    return json.loads(out)["blockdevices"]


def mounts_of(dev):
    found = [m for m in (dev.get("mountpoints") or []) if m]
    for c in dev.get("children") or []:
        found += mounts_of(c)
    return found


def describe(d):
    return f"{d['path']}  {int(d['size']) / GiB:.1f} GiB  {(d.get('model') or '?').strip()}  (serial {d.get('serial') or '?'})"


def eligible(d, allow_large):
    why = []
    if d.get("type") != "disk":
        why.append("not a whole disk")
    if (d.get("tran") or "") != "usb":
        why.append(f"not a USB disk (bus: {d.get('tran') or 'unknown'})")
    if d.get("ro"):
        why.append("read-only")
    size = int(d.get("size") or 0)
    if size < MIN_DISK:
        why.append("smaller than 2 GiB")
    if size > MAX_DISK and not allow_large:
        why.append("bigger than 256 GiB (that is usually a backup drive; --allow-large to use it anyway)")
    sysm = [m for m in mounts_of(d) if m in SYSTEM_MOUNTS or m.startswith("/usr/") or m == "[SWAP]"]
    if sysm:
        why.append(f"this Linux system runs from it ({', '.join(sysm)})")
    for c in d.get("children") or []:
        if (c.get("parttype") or "").lower() in OS_PARTTYPES or (c.get("fstype") or "") in ("apfs", "hfsplus"):
            why.append(f"{c['path']} holds an operating system ({c.get('fstype') or c.get('parttype')})")
    return why


def pick_disk(want, allow_large):
    disks = [d for d in lsblk() if d.get("type") == "disk"]
    usb = [d for d in disks if (d.get("tran") or "") == "usb"]
    if want:
        d = next((x for x in disks if x["path"] == want or x["name"] == os.path.basename(want)), None)
        if not d:
            die(f"{want} is not a disk on this PC. USB disks: " + ("; ".join(describe(x) for x in usb) or "none"))
    else:
        ok = [x for x in usb if not eligible(x, allow_large)]
        if not ok:
            die("no USB stick that can be erased was found. USB disks: " + ("; ".join(describe(x) for x in usb) or "none"))
        print("USB sticks that can be erased:")
        for i, x in enumerate(ok, 1):
            print(f"  {i}. {describe(x)}")
        choice = input("Number of the stick to ERASE: ").strip()
        if not choice.isdigit() or not 1 <= int(choice) <= len(ok):
            die("no stick chosen. Nothing was erased.")
        d = ok[int(choice) - 1]
    why = eligible(d, allow_large)
    if why:
        die(f"refusing {d['path']}: " + "; ".join(why) + ". Nothing was erased.")
    return d


def part_path(disk):
    # /dev/sdb -> /dev/sdb1, /dev/nvme0n1 or /dev/mmcblk0 -> ...p1
    return disk + ("p1" if disk[-1].isdigit() else "1")


def erase(d):
    path, size = d["path"], int(d["size"])
    for m in mounts_of(d):
        run("umount", m, check=False)
    for c in d.get("children") or []:
        run("umount", c["path"], check=False)
    # the stick is looked up again by serial and size right before erasing: a replugged different stick can take the name
    again = next((x for x in lsblk() if x["path"] == path), None)
    if not again or again.get("serial") != d.get("serial") or int(again.get("size") or 0) != size:
        die(f"{path} is not the stick that was picked any more (unplugged or replaced). Nothing was erased.")
    print(f"STEP erasing {describe(d)}", flush=True)
    run("wipefs", "-a", "-f", path)
    end = f"{min(size, PART_CAP) // (1 << 20) - 1}MiB" if size > PART_CAP else "100%"
    run("parted", "-s", "-a", "optimal", path, "mklabel", "msdos", "mkpart", "primary", "fat32", "1MiB", end,
        "set", "1", "boot", "on")
    run("partprobe", path, check=False)
    run("udevadm", "settle", check=False)
    part = part_path(path)
    for _ in range(30):
        if os.path.exists(part):
            break
        time.sleep(1)
    else:
        die(f"the new partition {part} did not appear. Unplug the stick, plug it in again and write again.")
    run("mkfs.vfat", "-F", "32", "-n", "1401", part)
    mnt = tempfile.mkdtemp(prefix="1401-stick-")
    # quiet: vfat refuses chmod, and the EFI copy (shutil.copy2) sets modes on every file
    run("mount", "-t", "vfat", "-o", "quiet,flush", part, mnt)
    print(f"OK erased {path}: one FAT32 partition labelled 1401, mounted at {mnt}", flush=True)
    return part, mnt


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--p1401", required=True, help="1401 checkout (the folder that has p1401/ in it)")
    ap.add_argument("--efi", required=True, help="the build folder from `python3 -m p1401 build` (has EFI/ in it)")
    ap.add_argument("--report", required=True, help="the Report.json the EFI was built from")
    ap.add_argument("--darwin", type=int, required=True, help="macOS to download: 24 = Sequoia 15, 25 = Tahoe 26")
    ap.add_argument("--disk", default="", help="/dev/sdX; asked when left out")
    ap.add_argument("--recovery-dir", default="", help="a folder with BaseSystem.dmg + BaseSystem.chunklist to use instead of downloading")
    ap.add_argument("--allow-large", action="store_true")
    ap.add_argument("--yes", action="store_true", help="do not ask before erasing")
    a = ap.parse_args()
    if os.geteuid() != 0:
        die("run as root (sudo): erasing a disk needs it")
    sys.path.insert(0, os.path.abspath(a.p1401))
    from p1401 import apple, machine_handoff, usbwriter, validate, netsupport, legacy  # noqa: E402

    older = legacy.read_marker(a.efi)
    if older and older != a.darwin:
        die(f"this EFI was built for {legacy.NAME[older]}; build again or write that release. Nothing was erased.")
    print("STEP checking the build", flush=True)
    checked = validate.validate(a.efi)
    if not checked.get("ok"):
        die("the EFI did not pass validation: " + "; ".join(checked.get("invariants") or [str(checked.get("error"))]))
    handoff = machine_handoff.verified(a.efi, a.report)
    print("OK the EFI passed ocvalidate and 1401's own checks", flush=True)

    d = pick_disk(a.disk, a.allow_large)

    info = apple.local_image(a.recovery_dir) if a.recovery_dir else None
    if netsupport.needs_local_image(a.efi):
        print("NOTE " + netsupport.OFFLINE_INSTALLER_MESSAGE, flush=True)
    if info:
        print(f"OK using {info['name']} from {a.recovery_dir}", flush=True)
    else:
        print("STEP asking Apple for the macOS recovery image", flush=True)
        info = apple.image_info(a.darwin)
        print(f"OK {info['name']} ({info['product']})", flush=True)
        print("STEP checking that Apple will serve the download (nothing is erased yet)", flush=True)
        ready = apple.preflight(info)
        print(f"OK Apple is serving {info['name']} ({ready['bytes'] / GiB:.2f} GiB, signed chunklist verified)", flush=True)

    if not a.yes:
        print(f"\nEVERYTHING on {describe(d)} will be erased.")
        if input(f"Type {d['name']} to erase it: ").strip() != d["name"]:
            die("not confirmed. Nothing was erased.")

    part, mnt = erase(d)
    last = [-1]

    def progress(done, total, *_):
        pct = int(done * 100 / total) if total else 0
        if pct != last[0]:
            last[0] = pct
            print(f"\rPROGRESS {pct}% downloading macOS recovery from Apple", end="", flush=True)

    try:
        res = usbwriter._write_payload(mnt, a.efi, info, progress, handoff, describe(d), machine_handoff.opt_in(arm_apps=False))
        print("", flush=True)
    finally:
        run("sync", check=False)
        run("umount", mnt, check=False)
        try:
            os.rmdir(mnt)
        except OSError:
            pass
    print(f"OK the stick is ready ({part})" + (" - NVIDIA driver included in NullMoth/" if res.get("nullmoth") else ""), flush=True)


if __name__ == "__main__":
    main()
