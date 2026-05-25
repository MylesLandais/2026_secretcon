#Requires -Version 5.1
<#
.SYNOPSIS
  Stage OpenSSH + TightVNC vendor files and verify the Win10 LTSC ISO for Hyper-V Packer.

.DESCRIPTION
  Downloads missing provisioning binaries (pinned SHA-256). Ensures the LTSC ISO exists at
  %USERPROFILE%\Downloads\en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso with the
  checksum expected by infrastructure/packer/ews/win10-ews-hyperv.pkr.hcl.

  Packer on Windows needs **oscdimg.exe** on PATH to build the PROVISION ISO from cd_files; this script installs
  Microsoft.OSCDIMG via winget when missing (or uses the Windows ADK copy if present).

.PARAMETER IsoPath
  Optional path to your LTSC 2021 x64 ISO file (copied to the Downloads filename Packer expects).

.EXAMPLE
  .\Prepare-SecretConHyperVBuild.ps1 -IsoPath 'D:\isos\en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso'
#>
[CmdletBinding()]
param(
  [string] $IsoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-OscdimgForPacker {
  if (Get-Command oscdimg.exe -ErrorAction SilentlyContinue) {
    return
  }

  $wgRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
  if (Test-Path -LiteralPath $wgRoot) {
    $hit = Get-ChildItem -LiteralPath $wgRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'Microsoft.OSCDIMG*' } |
      ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter 'oscdimg.exe' -ErrorAction SilentlyContinue } |
      Select-Object -First 1
    if ($hit) {
      $env:PATH = $hit.DirectoryName + ';' + $env:PATH
    }
  }

  if (Get-Command oscdimg.exe -ErrorAction SilentlyContinue) {
    return
  }

  $adkCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe')
    (Join-Path ${env:ProgramFiles} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe')
  )
  foreach ($p in $adkCandidates) {
    if ($p -and (Test-Path -LiteralPath $p)) {
      $env:PATH = (Split-Path -Parent $p) + ';' + $env:PATH
      return
    }
  }

  if (Get-Command oscdimg.exe -ErrorAction SilentlyContinue) {
    return
  }

  Write-Host "[*] oscdimg not found; installing Microsoft.OSCDIMG via winget (needed for Packer PROVISION ISO)..."
  winget install --id Microsoft.OSCDIMG --source winget --accept-package-agreements --accept-source-agreements -e
  if ($LASTEXITCODE -ne 0) {
    throw "winget install Microsoft.OSCDIMG failed ($LASTEXITCODE). Run manually: winget install Microsoft.OSCDIMG"
  }

  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = @($machinePath, $userPath) -join ';'

  if (Test-Path -LiteralPath $wgRoot) {
    $hit2 = Get-ChildItem -LiteralPath $wgRoot -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'Microsoft.OSCDIMG*' } |
      ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter 'oscdimg.exe' -ErrorAction SilentlyContinue } |
      Select-Object -First 1
    if ($hit2) {
      $env:PATH = $hit2.DirectoryName + ';' + $env:PATH
    }
  }

  if (-not (Get-Command oscdimg.exe -ErrorAction SilentlyContinue)) {
    throw "oscdimg.exe still not on PATH after winget. Open a new PowerShell window and rerun the build."
  }
}


function Get-Sha256([string] $Path) {
  return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToUpperInvariant()
}

function Ensure-UrlToFile {
  param(
    [string] $Url,
    [string] $Destination,
    [string] $ExpectedSha256
  )
  $dir = Split-Path -Parent $Destination
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $ok = $false
  if (Test-Path -LiteralPath $Destination) {
    if ((Get-Sha256 $Destination) -eq $ExpectedSha256.ToUpperInvariant()) {
      $ok = $true
    } else {
      Write-Host "[*] Replacing $($Destination) (SHA256 mismatch)"
      Remove-Item -LiteralPath $Destination -Force
    }
  }
  if (-not $ok) {
    Write-Host "[*] Downloading:`n    $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    $got = Get-Sha256 $Destination
    if ($got -ne $ExpectedSha256.ToUpperInvariant()) {
      throw "SHA256 mismatch after download for $Destination : got $got expected $ExpectedSha256"
    }
  }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$opensshDest = Join-Path $repoRoot 'provisioning\openssh\OpenSSH-Win64.zip'
$tightDest = Join-Path $repoRoot 'provisioning\tightvnc\tightvnc-2.8.87-gpl-setup-64bit.msi'

$opensshUrl = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip'
$opensshSha = '23F50F3458C4C5D0B12217C6A5DDFDE0137210A30FA870E98B29827F7B43ABA5'

$tightUrl = 'https://www.tightvnc.com/download/2.8.87/tightvnc-2.8.87-gpl-setup-64bit.msi'
$tightSha = 'AA256612C5B8BB387355E9C4BCE6068BF9BA77EF849F54EFCF6087D86B86F52A'

Ensure-UrlToFile -Url $opensshUrl -Destination $opensshDest -ExpectedSha256 $opensshSha
Ensure-UrlToFile -Url $tightUrl -Destination $tightDest -ExpectedSha256 $tightSha

$dl = Join-Path $env:USERPROFILE 'Downloads'
if (-not (Test-Path -LiteralPath $dl)) {
  New-Item -ItemType Directory -Path $dl -Force | Out-Null
}

$isoName = 'en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso'
$isoDest = Join-Path $dl $isoName
$isoSha = 'C90A6DF8997BF49E56B9673982F3E80745058723A707AEF8F22998AE6479597D'

$src = $IsoPath
if (-not $src -and $env:SECRETCON_WIN10_ISO) {
  $src = $env:SECRETCON_WIN10_ISO
}

if ($src) {
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
    throw "ISO source not found: $src"
  }
  Write-Host "[*] Copying ISO to $isoDest"
  Copy-Item -LiteralPath $src -Destination $isoDest -Force
}

if (-not (Test-Path -LiteralPath $isoDest -PathType Leaf)) {
  throw @"
Missing LTSC ISO at:
  $isoDest

Download Windows 10 Enterprise LTSC 2021 (x64, en-us) from Microsoft (Evaluation Center or VLSC),
then either:
  .\Prepare-SecretConHyperVBuild.ps1 -IsoPath 'C:\path\to\your.iso'
or set environment variable SECRETCON_WIN10_ISO to that path and run this script again.

Expected SHA-256 (must match Packer pin):
  $isoSha
"@
}

$isoGot = Get-Sha256 $isoDest
if ($isoGot -ne $isoSha.ToUpperInvariant()) {
  throw "ISO SHA256 mismatch for $isoDest : got $isoGot expected $isoSha"
}

Ensure-OscdimgForPacker

Write-Host "[ok] Staged OpenSSH, TightVNC, and verified LTSC ISO."
Write-Host "     ISO: $isoDest"
