#!/usr/bin/env bash
# 1401 on Linux: check this PC, build the OpenCore EFI, write the macOS install stick.
# 1401 (https://github.com/nullmoth/1401) is downloaded at a pinned commit and used as is; only the stick erase is
# done here (linux_write.py), because 1401's own writer is Windows-only.
#
#   sudo ./1401-linux.sh all            scan + build + write (asks which stick)
#   sudo ./1401-linux.sh scan|build|write
#   options: --macos 25 (Tahoe, default) | 24 (Sequoia)   --disk /dev/sdX   --new-identity   --yes
set -euo pipefail

PIN=1699e670c5dcc1f9eacdf98da329c89a8ca79168          # 1401 3.0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK_1401:-$HERE/work}"
SRC="$WORK/1401"; SCAN="$WORK/scan"; EFI="$WORK/efi"

die() { echo "STOP $*" >&2; exit 1; }
info() { echo; echo "== $*"; }

CMD="${1:-}"; shift || true
MACOS=25; DISK=""; YES=""; NEWID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --macos) MACOS="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --yes) YES=--yes; shift;;
    --new-identity) NEWID=--new-identity; shift;;
    *) die "unknown option $1";;
  esac
done
case "$CMD" in scan|build|write|all) ;; *) sed -n '2,8p' "$0"; exit 1;; esac
[ "$(id -u)" = 0 ] || die "run it with sudo (reading the ACPI tables and erasing the stick need root)"

deps() {
  local need=()
  for t in python3:python3 git:git lspci:pciutils lsusb:usbutils parted:parted mkfs.vfat:dosfstools wipefs:util-linux \
           lsblk:util-linux partprobe:parted sudo:sudo unzip:unzip; do
    command -v "${t%%:*}" >/dev/null || need+=("${t##*:}")
  done
  if [ ${#need[@]} -gt 0 ]; then
    if command -v apt-get >/dev/null; then
      info "installing ${need[*]}"; apt-get update -qq && apt-get install -y -qq "${need[@]}" ca-certificates
    elif command -v pacman >/dev/null; then pacman -S --needed --noconfirm "${need[@]}"
    elif command -v dnf >/dev/null; then dnf install -y "${need[@]}"
    else die "install these first: ${need[*]}"; fi
  fi
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))' \
    || die "1401 needs Python 3.12 or newer ($(python3 -V) here). Debian 13, Ubuntu 24.04 or newer have it."
}

fetch_1401() {
  if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" = "$PIN" ]; then return; fi
  info "downloading 1401 (pinned ${PIN:0:7})"
  rm -rf "$SRC"; mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" fetch -q --depth 1 https://github.com/nullmoth/1401.git "$PIN"
  git -C "$SRC" checkout -q FETCH_HEAD
}

do_scan() {
  info "Check this PC (Hardware Sniffer, Linux)"
  rm -rf "$SCAN"
  (cd "$SRC" && python3 -u -m p1401.scan "$SCAN") || die "the scan failed (see above)"
  python3 - "$SCAN/Report.json" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
print("Board:", r.get("Motherboard", {}).get("Name"), "/", r.get("Motherboard", {}).get("Chipset"))
print("CPU:  ", r.get("CPU", {}).get("Processor Name"), "/", r.get("CPU", {}).get("Codename"))
for n, g in (r.get("GPU") or {}).items():
    print("GPU:  ", n, "/", g.get("Codename"), g.get("Device ID"), "ReBAR", g.get("Resizable BAR"))
EOF
  fix_report
}

fix_report() {
  python3 -I "$HERE/fix_report.py" "$SRC" "$SCAN/Report.json" || die "the hardware report does not pass 1401's check (see above)"
}

do_build() {
  [ -s "$SCAN/Report.json" ] || die "no scan yet: run '$0 scan' first"
  fix_report
  info "Build the Mac setup (macOS darwin $MACOS)"
  rm -rf "$EFI"
  (cd "$SRC" && python3 -u -m p1401 build "$SCAN/Report.json" "$SCAN/ACPI" "$EFI" --macos "$MACOS" $NEWID --json) \
    > "$WORK/build.json" || { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('error'));print((d.get('transcript') or '')[-3000:])" "$WORK/build.json" 2>/dev/null; die "the build failed"; }
  python3 - "$WORK/build.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"OK macOS {d['macos_version']}  SMBIOS {d['smbios']}")
print("kexts:", ", ".join(d.get("kexts") or []))
for c in d.get("policy_changes") or []:
    print("rule:", c.get("rule"), "-", c.get("why", ""))
for n in d.get("notices") or []:
    if len(n) < 400:
        print("note:", n)
for b in d.get("bios_requirements") or []:
    print("BIOS:", b)
EOF
  echo "EFI: $EFI/EFI"
}

do_write() {
  [ -d "$EFI/EFI" ] || die "no build yet: run '$0 build' first"
  local darwin
  darwin=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['macos_version'].split('.')[0])" "$WORK/build.json")
  info "Create the macOS stick"
  python3 -u "$HERE/linux_write.py" --p1401 "$SRC" --efi "$EFI" --report "$SCAN/Report.json" --darwin "$darwin" \
    ${DISK:+--disk "$DISK"} ${RECOVERY_DIR:+--recovery-dir "$RECOVERY_DIR"} $YES
}

mkdir -p "$WORK"
deps
fetch_1401
case "$CMD" in
  scan) do_scan;;
  build) do_build;;
  write) do_write;;
  all) do_scan; do_build; do_write;;
esac
