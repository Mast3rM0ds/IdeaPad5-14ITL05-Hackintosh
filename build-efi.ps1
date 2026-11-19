# Builds the OpenCore EFI for the Lenovo IdeaPad 5 14ITL05 (Tiger Lake, Iris Xe, macOS Tahoe + WhateverXe).
# Uses only curl.exe + built-in PowerShell. Run from this folder:
#   powershell -ExecutionPolicy Bypass -File .\build-efi.ps1
# Optional: copy the result straight to a FAT32 USB stick:
#   powershell -ExecutionPolicy Bypass -File .\build-efi.ps1 -Usb E:
# Full USB installer (run PowerShell as Administrator): ERASES the stick, then EFI + Tahoe recovery:
#   powershell -ExecutionPolicy Bypass -File .\build-efi.ps1 -Usb D: -Format -Recovery
# Smooth touchpad: use a VoodooI2C CI/master build (zip from github.com/VoodooI2C/VoodooI2C/actions):
#   powershell -ExecutionPolicy Bypass -File .\build-efi.ps1 -VoodooI2C C:\path\VoodooI2C-xxxxxxxx.zip
# The Mac identity (serial/MLB/UUID/ROM) is generated once into smbios.json and reused afterwards.

param([string]$Usb = '', [switch]$Format, [switch]$Recovery, [string]$VoodooI2C = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$work  = Join-Path $root '_downloads'
$efi   = Join-Path $root 'EFI'
$oc    = Join-Path $efi 'OC'
$kexts = Join-Path $oc 'Kexts'
$OC_VERSION = '1.0.8'   # configs\*.plist were validated against this exact version

New-Item -ItemType Directory -Force $work, $kexts, (Join-Path $oc 'Drivers'), (Join-Path $oc 'Tools'), (Join-Path $efi 'BOOT') | Out-Null

function Get-Release([string]$repo, [string]$tag = '') {
    # 1) GitHub API (limited to 60 requests/hour without a login)
    $url = if ($tag) { "https://api.github.com/repos/$repo/releases/tags/$tag" } else { "https://api.github.com/repos/$repo/releases/latest" }
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $raw = curl.exe -sfL -H 'User-Agent: efi-builder' -H 'Accept: application/vnd.github+json' $url 2>$null | Out-String
    $ErrorActionPreference = $eap
    if ($raw) { return $raw | ConvertFrom-Json }

    # 2) Fallback without the API: tag from the /releases/latest redirect, assets from the release page
    if (-not $tag) {
        $hdr = curl.exe -sSI "https://github.com/$repo/releases/latest" | Out-String
        $m = [regex]::Match($hdr, '(?im)^location:\s*\S+/releases/tag/(\S+)')
        if (-not $m.Success) { throw "Could not find the latest release of $repo" }
        $tag = $m.Groups[1].Value
    }
    $html = curl.exe -sSfL "https://github.com/$repo/releases/expanded_assets/$tag" | Out-String
    $assets = foreach ($a in [regex]::Matches($html, 'href="(/[^"]+/releases/download/[^"]+)"')) {
        $path = [Uri]::UnescapeDataString($a.Groups[1].Value)
        [pscustomobject]@{ name = ($path -split '/')[-1]; browser_download_url = "https://github.com$($a.Groups[1].Value)" }
    }
    if (-not $assets) { throw "No downloadable files found for $repo $tag" }
    return [pscustomobject]@{ tag_name = $tag; assets = @($assets | Sort-Object name -Unique) }
}

function Get-Asset([string]$repo, [string]$pattern, [string]$tag = '') {
    try {
        $rel = Get-Release $repo $tag
    } catch {
        # 3) Last resort: reuse a file downloaded by an earlier run
        # File must match the pattern AND be named after this repo (OpenCorePkg -> OpenCore-*, IntelBluetoothFirmware -> IntelBluetooth-*)
        $short = (($repo -split '/')[1]) -replace 'Pkg$', '' -replace 'Firmware$', ''
        $cached = Get-ChildItem $work -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match $pattern -and $_.Name.StartsWith($short, [StringComparison]::OrdinalIgnoreCase) } |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $cached) { throw }
        Write-Host ("  {0,-40} (offline, reusing {1})" -f $repo, $cached.Name) -ForegroundColor DarkYellow
        return Expand-Asset $cached.FullName
    }
    $a = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $a) {
        $names = ($rel.assets | ForEach-Object { $_.name }) -join ', '
        throw "No asset matching '$pattern' in $repo $($rel.tag_name). Available: $names"
    }
    $file = Join-Path $work $a.name
    Write-Host ("  {0,-40} {1}  ({2})" -f $repo, $rel.tag_name, $a.name)
    if (-not (Test-Path $file) -or (Get-Item $file).Length -eq 0) {
        curl.exe -sSfL -o $file $a.browser_download_url
        if ($LASTEXITCODE -ne 0) { Remove-Item -Force $file -ErrorAction SilentlyContinue; throw "Download failed: $($a.browser_download_url)" }
    }
    return Expand-Asset $file
}

function Expand-Asset([string]$file) {
    if ($file -notmatch '\.zip$') { return $file }
    $dest = $file -replace '\.zip$', ''
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    Expand-Archive -Force $file $dest
    return $dest
}

function Copy-Kext([string]$from, [string]$name) {
    # Pick the top-level copy of the kext (not one nested in another kext's PlugIns, not a dSYM).
    $k = Get-ChildItem -Path $from -Recurse -Directory -Filter $name |
         Where-Object { $_.FullName -notmatch '\.dSYM' -and $_.Parent.Name -ne 'PlugIns' } |
         Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if (-not $k) { throw "$name not found in $from" }
    $dst = Join-Path $kexts $name
    if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
    Copy-Item -Recurse $k.FullName $dst
}

# ---------------- USB formatting ----------------
function Format-UsbStick([string]$drive) {
    $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Formatting needs an Administrator PowerShell (right-click > Run as administrator).'
    }
    $letter = $drive.TrimEnd('\').TrimEnd(':')
    $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $disk = Get-Disk -Number $part.DiskNumber
    if ($disk.BusType -ne 'USB')        { throw "Disk $($disk.Number) ($($disk.FriendlyName)) is not a USB disk (BusType $($disk.BusType)). Refusing." }
    if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $($disk.Number) is a boot/system disk. Refusing." }
    $gb = [math]::Round($disk.Size / 1GB, 1)
    Write-Host ""
    Write-Host "  About to ERASE disk $($disk.Number): $($disk.FriendlyName)  ($gb GB, currently ${letter}:)" -ForegroundColor Yellow
    Write-Host "  Every partition on it will be deleted." -ForegroundColor Yellow
    $answer = Read-Host '  Type ERASE to continue'
    if ($answer -cne 'ERASE') { throw 'Cancelled - nothing was changed.' }

    Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false
    if ((Get-Disk -Number $disk.Number).PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
    } else {
        Set-Disk -Number $disk.Number -PartitionStyle GPT
    }
    # Windows only formats FAT32 up to 32 GB, and the installer needs ~2 GB, so use 16 GB max.
    $size = [math]::Min([int64]16GB, [int64]($disk.Size - 64MB))
    New-Partition -DiskNumber $disk.Number -Size $size -DriveLetter $letter | Out-Null
    Format-Volume -DriveLetter $letter -FileSystem FAT32 -NewFileSystemLabel 'OPENCORE' -Confirm:$false | Out-Null
    Write-Host "  ${letter}: formatted as FAT32 (OPENCORE)" -ForegroundColor Green
}

# ---------------- Tahoe recovery (port of OpenCore's macrecovery.py) ----------------
function New-HexId([int]$len) { -join (1..$len | ForEach-Object { '0123456789ABCDEF'[(Get-Random -Maximum 16)] }) }

function Get-TahoeRecovery([string]$outDir) {
    $ua  = 'User-Agent: InternetRecovery/1.0'
    $tmp = Join-Path $work 'recovery-tmp'
    New-Item -ItemType Directory -Force $tmp, $outDir | Out-Null

    $hdr = curl.exe -sS -D - -o NUL -H $ua 'http://osrecovery.apple.com/' | Out-String
    $session = ([regex]::Match($hdr, '(?im)^set-cookie:\s*(session=[^;\r\n]+)')).Groups[1].Value
    if (-not $session) { throw "Apple recovery server gave no session cookie. Headers:`n$hdr" }

    # Board ID / MLB for Tahoe, from OpenCorePkg Utilities/macrecovery/recovery_urls.txt
    $body = "cid=$(New-HexId 16)`nsn=00000000000000000`nbid=Mac-CFF7D910A743CAAF`nk=$(New-HexId 64)`nfg=$(New-HexId 64)`nos=latest"
    $bodyFile = Join-Path $tmp 'body.txt'
    [IO.File]::WriteAllText($bodyFile, $body)   # LF line endings, no BOM
    $resp = curl.exe -sS -H $ua -H "Cookie: $session" -H 'Content-Type: text/plain' `
                     --data-binary "@$bodyFile" 'http://osrecovery.apple.com/InstallationPayload/RecoveryImage' | Out-String
    $info = @{}
    foreach ($line in ($resp -split "`n")) { if ($line -match '^(\w+): (.+?)\s*$') { $info[$Matches[1]] = $Matches[2] } }
    foreach ($k in 'AU', 'AT', 'CU', 'CT') { if (-not $info[$k]) { throw "Recovery server response missing $k :`n$resp" } }
    Write-Host "  Product: $($info['AP'])"

    $dmg = Join-Path $outDir 'BaseSystem.dmg'
    $cnk = Join-Path $outDir 'BaseSystem.chunklist'
    curl.exe -sSfL -H $ua -H "Cookie: AssetToken=$($info['CT'])" -o $cnk $info['CU']
    Write-Host '  Downloading BaseSystem.dmg (~1-2 GB)...'
    curl.exe -fL --progress-bar -H $ua -H "Cookie: AssetToken=$($info['AT'])" -o $dmg $info['AU']
    if ($LASTEXITCODE -ne 0) { throw "BaseSystem.dmg download failed (curl exit $LASTEXITCODE)" }
    Test-Chunklist $dmg $cnk
}

function Test-Chunklist([string]$dmg, [string]$cnk) {
    Write-Host '  Verifying BaseSystem.dmg against the chunklist...'
    $c = [IO.File]::ReadAllBytes($cnk)
    if ([Text.Encoding]::ASCII.GetString($c, 0, 4) -ne 'CNKL') { throw 'Chunklist has a bad header' }
    $count  = [BitConverter]::ToUInt64($c, 0x0C)
    $offset = [BitConverter]::ToUInt64($c, 0x14)
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs  = [IO.File]::OpenRead($dmg)
    try {
        for ($i = 0; $i -lt $count; $i++) {
            $e    = [int]$offset + 36 * $i
            $len  = [BitConverter]::ToUInt32($c, $e)
            $want = [BitConverter]::ToString($c, $e + 4, 32)
            $buf  = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) { $n = $fs.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
            if ($read -ne $len) { throw "BaseSystem.dmg is truncated at chunk $($i + 1)" }
            if ([BitConverter]::ToString($sha.ComputeHash($buf)) -ne $want) { throw "BaseSystem.dmg chunk $($i + 1) hash mismatch - delete it and run again" }
        }
        if ($fs.ReadByte() -ne -1) { throw 'BaseSystem.dmg is larger than the chunklist says' }
    } finally { $fs.Close() }
    Write-Host "  Image verified ($count chunks)" -ForegroundColor Green
}

if ($Format -or $Recovery) {
    if (-not $Usb) { throw '-Format and -Recovery need -Usb <drive letter>, e.g. -Usb D:' }
}
if ($Format) {
    Write-Host "`n== Formatting USB $Usb"
    Format-UsbStick $Usb
}

Write-Host "`n== Downloading OpenCore $OC_VERSION (DEBUG build, for logging + SysReport) and kexts"

$p = Get-Asset 'acidanthera/OpenCorePkg' "OpenCore-$([regex]::Escape($OC_VERSION))-DEBUG\.zip" $OC_VERSION
$ocPkg = $p
$x = Join-Path $p 'X64\EFI'
Copy-Item -Force (Join-Path $x 'BOOT\BOOTx64.efi') (Join-Path $efi 'BOOT\')
Copy-Item -Force (Join-Path $x 'OC\OpenCore.efi')  $oc
foreach ($d in 'OpenRuntime.efi', 'ResetNvramEntry.efi', 'OpenHfsPlus.efi') { Copy-Item -Force (Join-Path $x "OC\Drivers\$d") (Join-Path $oc 'Drivers\') }
foreach ($t in 'OpenShell.efi', 'ControlMsrE2.efi')      { Copy-Item -Force (Join-Path $x "OC\Tools\$t")   (Join-Path $oc 'Tools\') }

$p = Get-Asset 'acidanthera/Lilu' 'RELEASE\.zip$';                      Copy-Kext $p 'Lilu.kext'
$p = Get-Asset 'acidanthera/VirtualSMC' 'RELEASE\.zip$'
foreach ($k in 'VirtualSMC.kext', 'SMCBatteryManager.kext', 'SMCProcessor.kext') { Copy-Kext $p $k }
$p = Get-Asset 'acidanthera/AppleALC' '^AppleALC-.*RELEASE\.zip$';      Copy-Kext $p 'AppleALC.kext'
$p = Get-Asset 'acidanthera/NVMeFix' 'RELEASE\.zip$';                   Copy-Kext $p 'NVMeFix.kext'
$p = Get-Asset 'acidanthera/VoodooPS2' 'RELEASE\.zip$';                 Copy-Kext $p 'VoodooPS2Controller.kext'
$p = Get-Asset 'acidanthera/BrcmPatchRAM' 'RELEASE\.zip$';              Copy-Kext $p 'BlueToolFixup.kext'
if ($VoodooI2C) {
    # CI artifact zip: contains Debug\ and Release\ zips - use the Release one.
    Write-Host ("  {0,-40} local  ({1})" -f 'VoodooI2C/VoodooI2C', (Split-Path -Leaf $VoodooI2C))
    $p = Expand-Asset (Copy-Item -PassThru -Force $VoodooI2C (Join-Path $work 'VoodooI2C-local.zip')).FullName
    $inner = Get-ChildItem $p -Recurse -File -Filter '*RELEASE*.zip' | Select-Object -First 1
    if ($inner) { $p = Expand-Asset $inner.FullName }
    $variant = 'master'
} else {
    $p = Get-Asset 'VoodooI2C/VoodooI2C' '^VoodooI2C-.*RELEASE\.zip$'
    $variant = 'release'
}
foreach ($k in 'VoodooI2C.kext', 'VoodooI2CHID.kext') { Copy-Kext $p $k }
$p = Get-Asset '1Revenger1/ECEnabler' 'RELEASE\.zip$';                  Copy-Kext $p 'ECEnabler.kext'
$p = Get-Asset 'OpenIntelWireless/itlwm' '^itlwm_.*\.zip$';             Copy-Kext $p 'itlwm.kext'
$p = Get-Asset 'OpenIntelWireless/IntelBluetoothFirmware' '\.zip$'
foreach ($k in 'IntelBluetoothFirmware.kext', 'IntelBTPatcher.kext') { Copy-Kext $p $k }

Write-Host "`n== WhateverXe pieces"
$p = Get-Asset 'b00t0x/WhateverXe' 'RELEASE\.zip$';                     Copy-Kext $p 'WhateverXe.kext'
try {
    $p = Get-Asset 'b00t0x/AMFIAnchor' 'RELEASE\.zip$';                 Copy-Kext $p 'AMFIAnchor.kext'
} catch {
    Write-Warning "AMFIAnchor release download failed: $_"
    Write-Warning "Get AMFIAnchor.kext from https://github.com/b00t0x/AMFIAnchor/releases and put it in EFI\OC\Kexts by hand."
}
# The Graphics pkg is installed later from inside macOS - keep it next to the EFI on the USB.
$gfx = Join-Path $root 'WhateverXe-Graphics'
New-Item -ItemType Directory -Force $gfx | Out-Null
try {
    $pkg = Get-Asset 'b00t0x/WhateverXe-Graphics' '^WhateverXe-Graphics-.*\.pkg$'
    Copy-Item -Force $pkg $gfx
} catch { Write-Warning "Could not fetch the WhateverXe Graphics pkg: $_" }

Copy-Item -Force (Join-Path $root "configs\config-$variant.plist") (Join-Path $oc 'config.plist')
if ($variant -eq 'master') { Write-Host '  config: configs\config-master.plist (interrupt touchpad)' }
else { Write-Host '  config: configs\config-release.plist (VoodooI2C 2.9.1 + Tiger Lake injector, polling touchpad)' }

Write-Host "`n== Mac identity (SMBIOS MacBookPro16,2)"
$idFile = Join-Path $root 'smbios.json'
if (-not (Test-Path $idFile) -or (Get-Item $idFile).Length -eq 0) {
    $ms = Join-Path $ocPkg 'Utilities\macserial\macserial.exe'
    if (-not (Test-Path $ms)) { throw "macserial.exe not found in the OpenCore zip ($ms)" }
    $line = & $ms -m 'MacBookPro16,2' -n 1 -g | Select-Object -First 1
    $parts = @($line -split '\|' | ForEach-Object { $_.Trim() })
    $rom = -join (1..6 | ForEach-Object { '{0:X2}' -f (Get-Random -Maximum 256) })
    [ordered]@{ model = 'MacBookPro16,2'; serial = $parts[0]; mlb = $parts[1]
                uuid = [guid]::NewGuid().ToString().ToUpper(); rom = $rom } | ConvertTo-Json | Set-Content -Encoding ASCII $idFile
    Write-Host '  generated a new identity -> smbios.json (keep this file; it is reused on every build)'
} else { Write-Host '  reusing smbios.json' }
$id = Get-Content -Raw $idFile | ConvertFrom-Json
if ($id.serial -notmatch '^[0-9A-Z]{12}$' -or $id.mlb -notmatch '^[0-9A-Z]{17}$' -or
    $id.uuid -notmatch '^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$' -or $id.rom -notmatch '^[0-9A-Fa-f]{12}$') {
    throw "smbios.json has a malformed serial/MLB/UUID/ROM - fix or delete it"
}
$romBytes = [byte[]](0..5 | ForEach-Object { [Convert]::ToByte($id.rom.Substring($_ * 2, 2), 16) })
$cfgPath = Join-Path $oc 'config.plist'
$t = [IO.File]::ReadAllText($cfgPath)
$swaps = @(
    @('<string>GENERATE-SERIAL</string>', "<string>$($id.serial)</string>"),
    @('<string>GENERATE-MLB</string>', "<string>$($id.mlb)</string>"),
    @('DEADBEEF-0000-4000-8000-000000000000', $id.uuid.ToUpper()),
    @('R0VOUk9N', [Convert]::ToBase64String($romBytes)))
foreach ($s in $swaps) {
    if ([regex]::Matches($t, [regex]::Escape($s[0])).Count -ne 1) { throw "placeholder $($s[0]) not found exactly once in config.plist" }
    $t = $t.Replace($s[0], $s[1])
}
[IO.File]::WriteAllText($cfgPath, $t)
Write-Host "  serial $($id.serial)  MLB $($id.mlb)  (check checkcoverage.apple.com says 'not valid' before using iCloud)"

Write-Host "`n== Checking every kext referenced in config.plist exists"
[xml]$cfg = (Get-Content -Raw (Join-Path $oc 'config.plist')) -replace '<!DOCTYPE[^>]*>', ''
$missing = 0
$addArray = $cfg.SelectSingleNode("//key[.='Kernel']/following-sibling::dict[1]/key[.='Add']/following-sibling::array[1]")
foreach ($d in $addArray.dict) {
    $keys = @($d.key); $vals = @($d.ChildNodes | Where-Object { $_.Name -ne 'key' })
    $h = @{}; for ($i = 0; $i -lt $keys.Count; $i++) { $h[$keys[$i]] = $vals[$i] }
    if ($h['Enabled'].Name -ne 'true') { continue }
    $bundle = Join-Path $kexts ($h['BundlePath'].InnerText -replace '/', '\')
    $exe    = $h['ExecutablePath'].InnerText
    $ok = (Test-Path $bundle) -and (-not $exe -or (Test-Path (Join-Path $bundle ($exe -replace '/', '\'))))
    if (-not $ok) { Write-Warning "MISSING: $($h['BundlePath'].InnerText) $exe"; $missing++ }
}
if ($missing -eq 0) { Write-Host '  all kexts present' -ForegroundColor Green }

Write-Host "`n== Hardware check (this only means something if you run it ON the IdeaPad)"
$report = @()
$dev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue
function Show($label, $rx) {
    $m = $dev | Where-Object { $_.InstanceId -match $rx } | Select-Object -First 3
    foreach ($i in $m) { $script:report += ("{0,-10} {1}  [{2}]" -f $label, $i.FriendlyName, ($i.InstanceId -split '\\')[1]) }
    if (-not $m) { $script:report += ("{0,-10} (not found)" -f $label) }
}
Show 'iGPU'     'PCI\\VEN_8086&DEV_9A(40|49|59|60|68|70|78|C0|C9|D9|F8)'
Show 'Codec'    'HDAUDIO\\FUNC_01&VEN_10EC'
Show 'WiFi'     'PCI\\VEN_8086&DEV_(A0F0|2723|2725|51F0)|PCI\\VEN_10EC&DEV_(C822|B852|8852)'
Show 'Touchpad' 'ACPI\\(ELAN|SYNA|MSFT0001)|HID\\.*(ELAN|SYNA)'
Show 'VMD'      'PCI\\VEN_8086&DEV_(9A0B|467F)'
$report | ForEach-Object { Write-Host "  $_" }
$report | Set-Content (Join-Path $root 'hardware-report.txt')
if ($report -match 'VMD\s+[^\s(]') {
    Write-Warning 'Intel VMD is ACTIVE: macOS will not see the NVMe drive. It has to be turned off before installing (see README).'
}
if ($report -match 'Codec.*DEV_(?!0257)') {
    Write-Warning 'Audio codec is not ALC257 - layout-id 11 may give no sound; change it in DeviceProperties (see README).'
}

if ($Usb) {
    $target = $Usb.TrimEnd('\') + '\EFI'
    Write-Host "`n== Copying EFI to $target"
    if (Test-Path $target) { Rename-Item $target ("EFI.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    Copy-Item -Recurse $efi $target
    Copy-Item -Recurse -Force $gfx ($Usb.TrimEnd('\') + '\')
}

if ($Recovery) {
    Write-Host "`n== Downloading macOS Tahoe recovery from Apple"
    $cache = Join-Path $root 'com.apple.recovery.boot'
    $have = (Test-Path (Join-Path $cache 'BaseSystem.dmg')) -and (Test-Path (Join-Path $cache 'BaseSystem.chunklist'))
    if ($have) {
        try { Test-Chunklist (Join-Path $cache 'BaseSystem.dmg') (Join-Path $cache 'BaseSystem.chunklist') }
        catch { Write-Warning "Cached image is bad ($_), downloading again"; $have = $false }
    }
    if (-not $have) { Get-TahoeRecovery $cache }
    $dst = $Usb.TrimEnd('\') + '\com.apple.recovery.boot'
    Write-Host "  Copying recovery to $dst"
    New-Item -ItemType Directory -Force $dst | Out-Null
    Copy-Item -Force (Join-Path $cache '*') $dst
}

Write-Host "`nDone. EFI folder: $efi" -ForegroundColor Green
