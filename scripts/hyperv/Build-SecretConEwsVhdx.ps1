#Requires -Version 5.1
<#
.SYNOPSIS
  Create the SecretCon EWS VHDX on Hyper-V using Packer (no QEMU).

.DESCRIPTION
  Runs Prepare-SecretConHyperVBuild.ps1 (vendor zips + ISO verify), then packer init/build on infrastructure/packer/hyperv-ews/win10-ews-hyperv.pkr.hcl.

  Needs: Hyper-V, Packer on PATH (or under Program Files), Win10 LTSC ISO matching the pinned checksum.

.PARAMETER IsoPath
  Path to your en-us Windows 10 Enterprise LTSC 2021 x64 ISO (copied to %USERPROFILE%\Downloads\ with the expected name).

.PARAMETER AndStart
  After a successful build, register and start the VM via Start-SecretConEwsVm.ps1.

.PARAMETER AndVncTunnel
  After -AndStart, wait briefly then run Connect-SecretConEwsVnc.ps1 (requires Administrator for portproxy).

.EXAMPLE
  .\Build-SecretConEwsVhdx.ps1 -IsoPath 'D:\isos\en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso' -AndStart -AndVncTunnel -ReplaceExistingVm
#>
[CmdletBinding()]
param(
  [string] $IsoPath,

  [switch] $AndStart,

  [switch] $ReplaceExistingVm,

  [switch] $AndVncTunnel
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HyperVPackerAccess {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    return
  }
  foreach ($g in $id.Groups) {
    $sid = $g.Translate([Security.Principal.SecurityIdentifier])
    if ($sid.Value -eq 'S-1-5-32-578') {
      return
    }
  }
  throw @"
Packer cannot control Hyper-V from this session. Run this script from an elevated PowerShell (Run as Administrator),
or add your user to the 'Hyper-V Administrators' group, sign out, sign in, and retry:

  net localgroup "Hyper-V Administrators" $env:USERNAME /add

"@
}

Assert-HyperVPackerAccess

if ($AndVncTunnel) {
  $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isElevated) {
    throw "-AndVncTunnel requires an elevated PowerShell (Administrator) so Connect-SecretConEwsVnc.ps1 can run netsh portproxy after the build."
  }
}

foreach ($dir in @(
    (Join-Path ${env:ProgramFiles} 'Packer')
    (Join-Path ${env:ProgramFiles} 'HashiCorp\Packer')
  )) {
  $exe = Join-Path $dir 'packer.exe'
  if (Test-Path -LiteralPath $exe) {
    $env:PATH = "$dir;$env:PATH"
    break
  }
}
$wingetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
if (Test-Path -LiteralPath $wingetRoot) {
  $wg = Get-ChildItem -LiteralPath $wingetRoot -Directory -Filter 'Hashicorp.Packer_*' -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($wg) {
    $exe = Join-Path $wg.FullName 'packer.exe'
    if (Test-Path -LiteralPath $exe) {
      $env:PATH = "$($wg.FullName);$env:PATH"
    }
  }
}

$packerExe = Get-Command packer -ErrorAction SilentlyContinue
if (-not $packerExe) {
  throw "packer not on PATH. Install with: winget install Hashicorp.Packer; then open a new terminal."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$packerDir = Join-Path $repoRoot 'infrastructure\packer\hyperv-ews'
$recipe = Join-Path $packerDir 'win10-ews-hyperv.pkr.hcl'
if (-not (Test-Path -LiteralPath $recipe)) {
  throw "Missing recipe: $recipe"
}

$prepare = Join-Path $PSScriptRoot 'Prepare-SecretConHyperVBuild.ps1'
$prepareArgs = @{}
if ($IsoPath) { $prepareArgs['IsoPath'] = $IsoPath }
Write-Host "[*] Preparing vendor files + ISO..."
& $prepare @prepareArgs

Push-Location $packerDir
$varFile = Join-Path $env:TEMP ("secretcon-hyperv-{0}.pkrvars.hcl" -f [guid]::NewGuid().ToString('n'))
$expectedIso = Join-Path $env:USERPROFILE 'Downloads\en-us_windows_10_enterprise_ltsc_2021_x64_dvd_d289cf96.iso'
$isoUrl = 'file:///' + (($expectedIso -replace '\\', '/'))
Set-Content -LiteralPath $varFile -Encoding utf8 -Value "iso_url = `"$isoUrl`""
try {
  Write-Host "[*] packer init  ($packerDir)"
  & packer init .
  if ($LASTEXITCODE -ne 0) { throw "packer init failed: $LASTEXITCODE" }

  Write-Host "[*] packer build -var-file <temp> (expect roughly one to two hours)"
  & packer build -var-file $varFile .
  if ($LASTEXITCODE -ne 0) { throw "packer build failed: $LASTEXITCODE" }
}
finally {
  Remove-Item -LiteralPath $varFile -Force -ErrorAction SilentlyContinue
  Pop-Location
}

$outDir = Join-Path $packerDir 'output\win10-ews-hyperv'
if (-not (Test-Path -LiteralPath $outDir)) {
  throw "Expected output directory missing: $outDir"
}

$vhdx = Get-ChildItem -LiteralPath $outDir -Recurse -Filter '*.vhdx' -ErrorAction SilentlyContinue |
  Sort-Object Length -Descending |
  Select-Object -First 1

if (-not $vhdx) {
  throw "No .vhdx found under $outDir. Check Packer logs and export layout."
}

Write-Host ""
Write-Host "[ok] VHDX: $($vhdx.FullName)"
Write-Host "     Register VM:  .\Start-SecretConEwsVm.ps1 -VhdxPath `"$($vhdx.FullName)`""

if ($AndStart) {
  $start = Join-Path $PSScriptRoot 'Start-SecretConEwsVm.ps1'
  $startParams = @{ VhdxPath = $vhdx.FullName }
  if ($ReplaceExistingVm) { $startParams['ReplaceExistingVm'] = $true }
  & $start @startParams
}

if ($AndVncTunnel) {
  if (-not $AndStart) {
    throw "-AndVncTunnel requires -AndStart (VM must exist and be running)."
  }
  Write-Host '[*] Waiting for first boot before VNC tunnel...'
  Start-Sleep -Seconds 45
  $connect = Join-Path $PSScriptRoot 'Connect-SecretConEwsVnc.ps1'
  & $connect
}
