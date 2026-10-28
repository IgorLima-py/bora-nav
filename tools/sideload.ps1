# Sideload MotoNav onto the Venu 4 over MTP (Shell.Application), locked by a stamp.
#
#   powershell -File tools/sideload.ps1 [-Name Venu]   (-Nome still works)
#
# 1. Refuses without the stamp that `python tools/sim.py tudo` writes (watch/bin/tudo.carimbo)
#    with the .prg hash: nothing goes to the wrist without a green tudo (CLAUDE.md rule).
# 2. Copies the .prg to GARMIN\APPS, CHECKS by listing (the MTP copy is asynchronous: CopyHere
#    returns before the file exists) and only then deletes the previous MotoNav*.prg.
# 3. Brings CIQ_LOG.YML and the .PRF files, if any, to corridas\<date>\ (outside git).
#
# Exit: 0 ok · 1 stamp missing or not matching · 2 watch not found
#        3 the copy did not show up on the watch · 4 the copied size does not match.
# Not tested with the watch plugged in on C6a (no hardware on the bench): the first real use is C6b.
param([Alias('Nome')][string]$Name = 'Venu')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stamp = Join-Path $root 'watch\bin\tudo.carimbo'

# --- 1. the stamp -------------------------------------------------------------------------
if (-not (Test-Path $stamp)) {
    Write-Host 'FAILED: stamp missing (watch\bin\tudo.carimbo). Run: python tools/sim.py tudo'
    exit 1
}
$stampInfo = Get-Content $stamp -Raw -Encoding UTF8 | ConvertFrom-Json
$prg = Join-Path $root ('watch\bin\' + $stampInfo.prg)
if (-not (Test-Path $prg)) {
    Write-Host "FAILED: stamp missing for this build: $($stampInfo.prg) does not exist. Run: python tools/sim.py tudo"
    exit 1
}
$hash = (Get-FileHash $prg -Algorithm SHA256).Hash.ToLower()
if ($hash -ne $stampInfo.sha256) {
    Write-Host "FAILED: stamp does not match: $($stampInfo.prg) changed after tudo. Run: python tools/sim.py tudo"
    exit 1
}
Write-Host "stamp ok: $($stampInfo.prg) ($($stampInfo.quando))"

# --- 2. the watch -------------------------------------------------------------------------
$shell = New-Object -ComObject Shell.Application
$pc = $shell.Namespace(17)   # This PC
$device = $pc.Items() | Where-Object { $_.Name -like "*$Name*" } | Select-Object -First 1
if (-not $device) {
    Write-Host "FAILED: watch '$Name' not found in This PC (USB in MTP mode?)"
    exit 2
}

function Get-SubFolder($folder, [string]$name) {
    $item = $folder.Items() | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($item) { return $item.GetFolder }
    return $null
}

$storage = $null
foreach ($candidate in $device.GetFolder.Items()) { $storage = $candidate.GetFolder; break }  # Internal Storage
$garmin = if ($storage) { Get-SubFolder $storage 'GARMIN' } else { $null }
$apps = if ($garmin) { Get-SubFolder $garmin 'APPS' } else { $null }
if (-not $apps) {
    Write-Host "FAILED: GARMIN\APPS not found in $($device.Name)"
    exit 2
}

# On the Venu 4 over MTP, .Size returns 0 (measured on 2026-10-02: 61676 B real, .Size = 0);
# System.Size brings the right size.
function Get-MtpSize($item) {
    return [int64]$item.ExtendedProperty('System.Size')
}

function Find-Item($folder, [string]$name) {
    return $folder.Items() | Where-Object { $_.Name -eq $name } | Select-Object -First 1
}

$target = Split-Path $prg -Leaf
$size = (Get-Item $prg).Length
Write-Host "copying $target ($size B) to $($device.Name)\GARMIN\APPS ..."
$apps.CopyHere($prg, 20)   # 4 = no progress window, 16 = yes to all

# --- the MTP copy is asynchronous: check by listing, do not trust the return ---------------------
$deadline = (Get-Date).AddSeconds(60)
$copied = $null
while ((Get-Date) -lt $deadline) {
    $copied = Find-Item $apps $target
    if ($copied -and (Get-MtpSize $copied) -eq $size) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $copied) {
    Write-Host "FAILED: $target did not show up in GARMIN\APPS within 60 s"
    exit 3
}
if ((Get-MtpSize $copied) -ne $size) {
    Write-Host "FAILED: $target on the watch is $(Get-MtpSize $copied) B, the file is $size B"
    exit 4
}
Write-Host "verified: $target in GARMIN\APPS, $size B"

# --- 3. the previous .prg: only MotoNav*.prg, never another app ----------------------------------------
foreach ($old in @($apps.Items() | Where-Object { $_.Name -like 'MotoNav*.prg' -and $_.Name -ne $target })) {
    Write-Host "deleting the previous one: $($old.Name)"
    $old.InvokeVerb('delete')
}

# --- 4. what the watch kept: CIQ_LOG.YML and .PRF --------------------------------------------
$outDir = Join-Path $root ('corridas\' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
$fetched = @()
function Copy-Out($item) {
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $shell.Namespace($outDir).CopyHere($item, 20)
    $script:trouxe += $item.Name
}
$logs = Get-SubFolder $apps 'LOGS'
if ($logs) {
    $yml = Find-Item $logs 'CIQ_LOG.YML'
    if ($yml) { Copy-Out $yml }
}
foreach ($sub in @($apps.Items() | Where-Object { $_.IsFolder })) {
    foreach ($file in @($sub.GetFolder.Items() | Where-Object { $_.Name -like '*.PRF' })) { Copy-Out $file }
}
if ($fetched.Count -gt 0) {
    Write-Host "fetched to ${outDir}: $($fetched -join ', ')"
} else {
    Write-Host 'nothing to fetch (no CIQ_LOG.YML or .PRF)'
}
Write-Host "sideload ok: $target. Disconnect the watch and open the app."
exit 0
