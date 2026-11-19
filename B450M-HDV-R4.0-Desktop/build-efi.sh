#!/usr/bin/env bash
# Builds the OpenCore EFI for an ASRock B450M-HDV R4.0 + Ryzen 5 3500X + RTX 3050 desktop (macOS Tahoe).
# macOS and Linux. Needs: bash, curl, unzip, python3.
#
#   ./build-efi.sh                                   build ./EFI only
#   ./build-efi.sh --usb /Volumes/OPENCORE           build + copy EFI to a mounted FAT32 stick
#   ./build-efi.sh --format /dev/disk4 --recovery    ERASE the stick, build, copy EFI + Tahoe recovery
# The Mac identity (serial/MLB/UUID/ROM) is generated once into smbios.json and reused afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/_downloads"
EFI="$ROOT/EFI"; OC="$EFI/OC"; KEXTS="$OC/Kexts"
OC_VERSION="1.0.8"            # configs/*.plist were validated against this exact version
USB=""; FORMAT_DEV=""; RECOVERY=0

die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --usb)       USB="${2:?--usb needs a mount point}"; shift 2 ;;
    --format)    FORMAT_DEV="${2:?--format needs a device, e.g. /dev/disk4 or /dev/sdb}"; shift 2 ;;
    --recovery)  RECOVERY=1; shift ;;
    -h|--help)   sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

for t in curl unzip python3; do command -v "$t" >/dev/null || die "$t is missing$( [ "$t" = python3 ] && [ "$(uname)" = Darwin ] && echo ' (run: xcode-select --install)')"; done
OS="$(uname)"
mkdir -p "$WORK" "$KEXTS" "$OC/Drivers" "$OC/Tools" "$OC/ACPI" "$EFI/BOOT"

# ---------------------------------------------------------------- USB formatting
format_usb() {
  local dev="$1"
  info "Formatting $dev"
  if [ "$OS" = Darwin ]; then
    diskutil info "$dev" >/dev/null 2>&1 || die "$dev is not a disk (see: diskutil list external)"
    local inf; inf="$(diskutil info "$dev")"
    grep -E 'Device Location: +External|Protocol: +USB' <<<"$inf" >/dev/null || die "$dev is not an external/USB disk. Refusing."
    grep -E 'Whole: +Yes' <<<"$inf" >/dev/null || die "give the whole disk (e.g. /dev/disk4), not a partition"
    echo "$inf" | grep -E 'Device / Media Name|Disk Size' | sed 's/^/  /'
  else
    [ -b "$dev" ] || die "$dev is not a block device (see: lsblk)"
    [ "$(lsblk -dno TYPE "$dev")" = disk ] || die "give the whole disk (e.g. /dev/sdb), not a partition"
    [ "$(lsblk -dno TRAN "$dev")" = usb ] || die "$dev is not a USB disk. Refusing."
    grep -E '^/$|^/boot|^/home' <<<"$(lsblk -no MOUNTPOINT "$dev")" >/dev/null && die "$dev holds a system mount. Refusing."
    lsblk -dno MODEL,SIZE "$dev" | sed 's/^/  /'
  fi
  printf '  Everything on %s will be ERASED. Type ERASE to continue: ' "$dev"
  local a; read -r a; [ "$a" = ERASE ] || die "cancelled - nothing was changed"

  if [ "$OS" = Darwin ]; then
    diskutil eraseDisk FAT32 OPENCORE GPT "$dev"
    USB="/Volumes/OPENCORE"
  else
    for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do sudo umount "$p" 2>/dev/null || true; done
    command -v parted >/dev/null && command -v mkfs.vfat >/dev/null || die "needs parted and mkfs.vfat (dosfstools)"
    sudo wipefs -a "$dev"
    sudo parted -s "$dev" mklabel gpt mkpart OPENCORE fat32 1MiB 100% set 1 esp on
    sudo partprobe "$dev" 2>/dev/null || true; sleep 2
    local part; part="$(lsblk -lnpo NAME "$dev" | sed -n 2p)"
    sudo mkfs.vfat -F 32 -n OPENCORE "$part"
    USB="$(mktemp -d)"; sudo mount -o uid="$(id -u)",gid="$(id -g)" "$part" "$USB"
    UNMOUNT_AFTER="$USB"
  fi
  echo "  formatted, mounted at $USB"
}

# ---------------------------------------------------------------- GitHub downloads
# Prints "tag<TAB>url" of the first release asset matching a regex. API first, release page as fallback
# (the API allows 60 requests/hour without a login).
find_asset() {
  local repo="$1" pattern="$2" tag="${3:-}" json url
  url="https://api.github.com/repos/$repo/releases/${tag:+tags/$tag}"; [ -z "$tag" ] && url="${url}latest"
  if json="$(curl -sfL -H 'User-Agent: efi-builder' "$url" 2>/dev/null)"; then
    python3 -c 'import json,re,sys
r=json.loads(sys.stdin.read()); p=sys.argv[1]
for a in r.get("assets",[]):
    if re.search(p,a["name"],re.I): print(r["tag_name"]+"\t"+a["browser_download_url"]); break' "$pattern" <<<"$json"
    return
  fi
  if [ -z "$tag" ]; then
    tag="$(curl -sSI "https://github.com/$repo/releases/latest" 2>/dev/null | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/releases/tag/##p' || true)"
    [ -n "$tag" ] || return 0
  fi
  curl -sfL "https://github.com/$repo/releases/expanded_assets/$tag" 2>/dev/null \
   | grep -o 'href="/[^"]*/releases/download/[^"]*"' | sed 's/^href="//;s/"$//' \
   | python3 -c 'import re,sys,urllib.parse
p,tag=sys.argv[1],sys.argv[2]
for l in sys.stdin:
    l=l.strip(); n=urllib.parse.unquote(l.rsplit("/",1)[-1])
    if re.search(p,n,re.I): print(tag+"\thttps://github.com"+l); break' "$pattern" "$tag"
}

# Downloads (or reuses) an asset, unzips it, prints the directory (or the file for non-zips).
get_asset() {
  local repo="$1" pattern="$2" tag="${3:-}" line ver url name file
  line="$(find_asset "$repo" "$pattern" "$tag" || true)"
  if [ -z "$line" ]; then
    local short="${repo##*/}"; short="${short%Pkg}"; short="${short%Firmware}"
    # an anchored pattern (^Name...) already names the file; otherwise also require the repo name
    case "$pattern" in ^*) short="" ;; esac
    file="$( { ls -t "$WORK" 2>/dev/null || true; } | grep -Ei "$pattern" | grep -i "^$short" | sed -n 1p || true)"
    [ -n "$file" ] || die "no download for $repo matching '$pattern' (GitHub rate limit? try again in an hour)"
    printf '  %-42s (offline, reusing %s)\n' "$repo" "$file" >&2; file="$WORK/$file"
  else
    ver="${line%%$'\t'*}"; url="${line#*$'\t'}"; name="$(basename "$url")"; file="$WORK/$name"
    printf '  %-42s %-8s (%s)\n' "$repo" "$ver" "$name" >&2
    [ -s "$file" ] || curl -sSfL -o "$file" "$url" || { rm -f "$file"; die "download failed: $url"; }
  fi
  case "$file" in
    *.zip) local d="${file%.zip}"; rm -rf "$d"; unzip -q -o "$file" -d "$d"; echo "$d" ;;
    *) echo "$file" ;;
  esac
}

# Copies the top-level copy of a kext (not one nested in PlugIns, not a dSYM).
copy_kext() {
  local from="$1" name="$2" k
  k="$(find "$from" -type d -name "$name" -not -path '*.dSYM*' -not -path '*/PlugIns/*' -not -path '*/Debug/*' | awk '{print length, $0}' | sort -n | sed -n 1p | cut -d' ' -f2- || true)"
  [ -n "$k" ] || die "$name not found in $from"
  rm -rf "${KEXTS:?}/$name"; cp -R "$k" "$KEXTS/$name"
}

# ---------------------------------------------------------------- Tahoe recovery (port of OpenCore's macrecovery.py)
verify_chunklist() {
  python3 - "$1" "$2" <<'PY'
import hashlib,struct,sys
dmg,cnk=sys.argv[1],sys.argv[2]
c=open(cnk,'rb').read()
if c[:4]!=b'CNKL': sys.exit('chunklist has a bad header')
count,off=struct.unpack_from('<QQ',c,0x0C)
with open(dmg,'rb') as f:
    for i in range(count):
        size,want=struct.unpack_from('<I32s',c,off+36*i)
        data=f.read(size)
        if len(data)!=size: sys.exit(f'BaseSystem.dmg is truncated at chunk {i+1}')
        if hashlib.sha256(data).digest()!=want: sys.exit(f'chunk {i+1} hash mismatch - delete the image and run again')
    if f.read(1): sys.exit('BaseSystem.dmg is larger than the chunklist says')
print(f'  image verified ({count} chunks)')
PY
}

get_recovery() {
  local out="$1" ua='User-Agent: InternetRecovery/1.0' session body resp
  mkdir -p "$out"
  session="$(curl -sS -D - -o /dev/null -H "$ua" http://osrecovery.apple.com/ | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: *\(session=[^;]*\).*/\1/p' | sed -n 1p || true)"
  [ -n "$session" ] || die "can't reach Apple's recovery server (osrecovery.apple.com) - check the internet connection"
  hex() { python3 -c "import secrets;print(secrets.token_hex($1).upper())"; }
  # Board ID / MLB for Tahoe, from OpenCorePkg Utilities/macrecovery/recovery_urls.txt
  body="cid=$(hex 8)"$'\n'"sn=00000000000000000"$'\n'"bid=Mac-CFF7D910A743CAAF"$'\n'"k=$(hex 32)"$'\n'"fg=$(hex 32)"$'\n'"os=latest"
  resp="$(printf '%s' "$body" | curl -sS -H "$ua" -H "Cookie: $session" -H 'Content-Type: text/plain' \
          --data-binary @- http://osrecovery.apple.com/InstallationPayload/RecoveryImage)"
  val() { sed -n "s/^$1: *//p" <<<"$resp" | tr -d '\r' | head -1; }
  local AU AT CU CT; AU="$(val AU)"; AT="$(val AT)"; CU="$(val CU)"; CT="$(val CT)"
  [ -n "$AU" ] && [ -n "$CU" ] || die "unexpected recovery server answer: $resp"
  echo "  product: $(val AP)"
  curl -sSfL -H "$ua" -H "Cookie: AssetToken=$CT" -o "$out/BaseSystem.chunklist" "$CU"
  echo "  downloading BaseSystem.dmg (~1 GB)..."
  curl -fL --progress-bar -H "$ua" -H "Cookie: AssetToken=$AT" -o "$out/BaseSystem.dmg" "$AU"
  verify_chunklist "$out/BaseSystem.dmg" "$out/BaseSystem.chunklist"
}

# ================================================================ main
[ -n "$FORMAT_DEV" ] && format_usb "$FORMAT_DEV"
if [ "$RECOVERY" = 1 ] && [ -z "$USB" ]; then die "--recovery needs --usb or --format"; fi

info "Downloading OpenCore $OC_VERSION (DEBUG build) and kexts"
d="$(get_asset acidanthera/OpenCorePkg "OpenCore-${OC_VERSION//./\\.}-DEBUG\.zip" "$OC_VERSION")"
OCPKG="$d"
cp "$d/X64/EFI/BOOT/BOOTx64.efi" "$EFI/BOOT/"; cp "$d/X64/EFI/OC/OpenCore.efi" "$OC/"
for f in OpenRuntime.efi ResetNvramEntry.efi OpenHfsPlus.efi OpenCanopy.efi; do cp "$d/X64/EFI/OC/Drivers/$f" "$OC/Drivers/"; done
cp "$d/X64/EFI/OC/Tools/OpenShell.efi" "$OC/Tools/"

d="$(get_asset acidanthera/Lilu 'RELEASE\.zip$')";                 copy_kext "$d" Lilu.kext
d="$(get_asset acidanthera/VirtualSMC 'RELEASE\.zip$')";           copy_kext "$d" VirtualSMC.kext
d="$(get_asset acidanthera/AppleALC '^AppleALC-.*RELEASE\.zip$')"; copy_kext "$d" AppleALC.kext
d="$(get_asset acidanthera/NVMeFix 'RELEASE\.zip$')";              copy_kext "$d" NVMeFix.kext
d="$(get_asset acidanthera/RestrictEvents 'RELEASE\.zip$')";       copy_kext "$d" RestrictEvents.kext
d="$(get_asset Mieze/RTL8111_driver_for_OS_X '^RealtekRTL8111.*\.zip$')";           copy_kext "$d" RealtekRTL8111.kext

info "OpenCanopy GUI theme (acidanthera/OcBinaryData)"
z="$WORK/OcBinaryData-master.zip"
[ -s "$z" ] || curl -sSfL -o "$z" https://github.com/acidanthera/OcBinaryData/archive/refs/heads/master.zip || { rm -f "$z"; die "theme download failed"; }
rm -rf "$WORK/OcBinaryData-master" "$OC/Resources"; unzip -q -o "$z" -d "$WORK"
mkdir -p "$OC/Resources"; for r in Font Image Label; do cp -R "$WORK/OcBinaryData-master/Resources/$r" "$OC/Resources/"; done
echo "  Resources: Font Image Label"

cp "$ROOT/configs/config.plist" "$OC/config.plist"

info "Mac identity (SMBIOS MacPro7,1)"
ID="$ROOT/smbios.json"
if [ ! -s "$ID" ]; then
  if [ "$OS" = Darwin ]; then MS="$OCPKG/Utilities/macserial/macserial"; else MS="$OCPKG/Utilities/macserial/macserial.linux"; fi
  [ -f "$MS" ] || die "macserial not found in the OpenCore zip ($MS)"
  chmod +x "$MS"
  line="$("$MS" -m MacPro7,1 -n 1 -g)" || die "macserial failed"
  python3 - "$ID" "$line" <<'PY'
import json,os,sys,uuid
serial,mlb=[x.strip() for x in sys.argv[2].split('|')][:2]
json.dump({'model':'MacPro7,1','serial':serial,'mlb':mlb,'uuid':str(uuid.uuid4()).upper(),
           'rom':os.urandom(6).hex().upper()},open(sys.argv[1],'w'),indent=2)
PY
  echo "  generated a new identity -> smbios.json (keep this file; it is reused on every build)"
else
  echo "  reusing smbios.json"
fi
python3 - "$ID" "$OC/config.plist" <<'PY'
import base64,json,re,sys
i=json.load(open(sys.argv[1])); f=sys.argv[2]; t=open(f).read()
assert re.fullmatch(r'[0-9A-Z]{12}',i['serial']) and re.fullmatch(r'[0-9A-Z]{17}',i['mlb']), 'bad serial/MLB in smbios.json'
assert re.fullmatch(r'[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}',i['uuid'].upper()) and re.fullmatch(r'[0-9A-Fa-f]{12}',i['rom']), 'bad uuid/rom in smbios.json'
for old,new in [('<string>GENERATE-SERIAL</string>','<string>%s</string>'%i['serial']),('<string>GENERATE-MLB</string>','<string>%s</string>'%i['mlb']),
                ('DEADBEEF-0000-4000-8000-000000000000',i['uuid'].upper()),('R0VOUk9N',base64.b64encode(bytes.fromhex(i['rom'])).decode())]:
    if t.count(old)!=1: sys.exit('placeholder %s not found exactly once in config.plist'%old)
    t=t.replace(old,new)
open(f,'w').write(t)
print('  serial %s  MLB %s  (check checkcoverage.apple.com says "not valid" before using iCloud)'%(i['serial'],i['mlb']))
PY

info "Checking every kext in config.plist exists"
python3 - "$OC" <<'PY'
import os,plistlib,sys
oc=sys.argv[1]; p=plistlib.load(open(os.path.join(oc,'config.plist'),'rb')); bad=0
for k in p['Kernel']['Add']:
    if not k['Enabled']: continue
    b=os.path.join(oc,'Kexts',k['BundlePath']); e=k['ExecutablePath']
    if not os.path.isdir(b) or (e and not os.path.isfile(os.path.join(b,e))): print('  MISSING:',k['BundlePath'],e); bad+=1
for d in p['UEFI']['Drivers']:
    if d['Enabled'] and not os.path.isfile(os.path.join(oc,'Drivers',d['Path'])): print('  MISSING driver:',d['Path']); bad+=1
for a in p['ACPI']['Add']:
    if a['Enabled'] and not os.path.isfile(os.path.join(oc,'ACPI',a['Path'])): print('  MISSING ACPI:',a['Path']); bad+=1
print('  all present' if not bad else f'  {bad} missing'); sys.exit(1 if bad else 0)
PY

if [ -n "$USB" ]; then
  info "Copying EFI to $USB"
  [ -d "$USB" ] || die "$USB is not a mounted folder"
  [ -d "$USB/EFI" ] && mv "$USB/EFI" "$USB/EFI.bak-$(date +%Y%m%d-%H%M%S)"
  cp -R "$EFI" "$USB/EFI"
fi

if [ "$RECOVERY" = 1 ]; then
  info "macOS Tahoe recovery from Apple"
  cache="$ROOT/com.apple.recovery.boot"
  if [ -s "$cache/BaseSystem.dmg" ] && verify_chunklist "$cache/BaseSystem.dmg" "$cache/BaseSystem.chunklist" 2>/dev/null; then
    echo "  using cached image"
  else
    get_recovery "$cache"
  fi
  mkdir -p "$USB/com.apple.recovery.boot"; cp "$cache"/BaseSystem.* "$USB/com.apple.recovery.boot/"
fi

[ -n "${UNMOUNT_AFTER:-}" ] && { sync; sudo umount "$UNMOUNT_AFTER"; rmdir "$UNMOUNT_AFTER"; echo "  stick unmounted"; }
printf '\n\033[32mDone.\033[0m EFI folder: %s\n' "$EFI"
