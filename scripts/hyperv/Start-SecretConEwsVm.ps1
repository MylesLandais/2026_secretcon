#Requires -Version 5.1
<#
.SYNOPSIS
  Register an existing SecretCon EWS VHDX as a Hyper-V VM and start it.

.DESCRIPTION
  Registers an existing root Windows disk only; it does not create the VHDX.

  Create the disk first (same machine, Hyper-V + Packer):
    .\Build-SecretConEwsVhdx.ps1
  Or manually from infrastructure/packer (ISOs under %USERPROFILE%\Downloads\):
    packer init .
    packer build -only=win10-ews-hyperv.hyperv-iso.win10-ews-hyperv win10-ews-hyperv.pkr.hcl

  The new VHDX ends up under output/win10-ews-hyperv/ (nested export folders are normal).

.PARAMETER VhdxPath
  Path to the root Windows disk (.vhdx) from the Hyper-V Packer build or a copy of it.

.EXAMPLE
  .\Start-SecretConEwsVm.ps1 -VhdxPath "C:\...\2026_secretcon\infrastructure\packer\output\win10-ews-hyperv\...\win10-ews-hyperv.vhdx"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
  [string] $VhdxPath,

  [string] $VmName = 'secretcon-ews',

  [ValidateRange(1, 2)]
  [int] $Generation = 1,

  [string] $SwitchName = 'Default Switch',

  [uint64] $MemoryBytes = 8GB,

  [ValidateRange(1, 64)]
  [int] $ProcessorCount = 4,

  [switch] $ReplaceExistingVm,

  [switch] $SkipStart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HyperV {
  if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw "Hyper-V PowerShell module missing. Enable the Hyper-V Windows feature."
  }
  Import-Module Hyper-V -ErrorAction Stop
  $null = Get-VMHost -ErrorAction Stop
}

$VhdxPath = (Resolve-Path -LiteralPath $VhdxPath).Path
if ([System.IO.Path]::GetExtension($VhdxPath) -notin @('.vhdx', '.vhd')) {
  throw "Expected a .vhdx or .vhd root disk path, got: $VhdxPath"
}

Assert-HyperV

$existing = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($existing) {
  if (-not $ReplaceExistingVm) {
    throw "VM '$VmName' already exists. Remove it from Hyper-V Manager or pass -ReplaceExistingVm."
  }
  if ($PSCmdlet.ShouldProcess($VmName, 'Remove existing VM')) {
    if ($existing.State -ne 'Off') { Stop-VM -Name $VmName -Force }
    Remove-VM -Name $VmName -Force
  }
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
  throw "Virtual switch '$SwitchName' not found. Create a switch or pass -SwitchName."
}

if ($PSCmdlet.ShouldProcess($VmName, "New-VM Generation $Generation")) {
  $vm = New-VM -Name $VmName -MemoryStartupBytes $MemoryBytes -Generation $Generation -VHDPath $VhdxPath
  Set-VMProcessor -VM $vm -Count $ProcessorCount
  Get-VMNetworkAdapter -VM $vm | Connect-VMNetworkAdapter -SwitchName $SwitchName

  if ($Generation -eq 2) {
    Set-VMFirmware -VM $vm -EnableSecureBoot Off
  }
}

if (-not $SkipStart) {
  if ($PSCmdlet.ShouldProcess($VmName, 'Start-VM')) {
    Start-VM -Name $VmName
  }
}

Write-Host ""
$stateMsg = if ($SkipStart) { 'created (not started)' } else { 'running' }
Write-Host "[ok] VM '$VmName' is $stateMsg."
Write-Host "     Connect with Hyper-V Manager; RDP/WinRM/VNC are on the guest IP (switch: $SwitchName)."
Write-Host "     Localhost VNC tunnel (admin PowerShell):  .\Connect-SecretConEwsVnc.ps1"
