#Requires -Version 5.1
<#
.SYNOPSIS
  Wait for the Hyper-V guest IPv4, then map localhost -> guest:5900 for TightVNC.

.DESCRIPTION
  Hyper-V Default Switch does not publish guest ports on 127.0.0.1 like QEMU user networking.
  This script uses netsh portproxy so you can aim a VNC viewer at 127.0.0.1:<LocalPort>.

  Default TightVNC password from bootstrap_win.ps1: FELDTECH_VNC

.PARAMETER VmName
  VM registered by Start-SecretConEwsVm.ps1 (default secretcon-ews).

.EXAMPLE
  .\Connect-SecretConEwsVnc.ps1
#>
[CmdletBinding()]
param(
  [string] $VmName = 'secretcon-ews',

  [ValidateRange(1, 65535)]
  [int] $LocalPort = 15900,

  [ValidateRange(1, 65535)]
  [int] $GuestVncPort = 5900,

  [int] $TimeoutSec = 1200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Administrator privileges required (netsh interface portproxy). Open an elevated PowerShell and run this script again."
}

Import-Module Hyper-V -ErrorAction Stop
$vm = Get-VM -Name $VmName -ErrorAction Stop
if ($vm.State -ne 'Running') {
  throw "VM '$VmName' is not Running (state: $($vm.State)). Start it first."
}

Write-Host "[*] Waiting for guest IPv4 on '$VmName' (timeout ${TimeoutSec}s)..."
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$guestIp = $null
while ((Get-Date) -lt $deadline) {
  $ips = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddresses)
  $guestIp = $ips |
    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^169\.' -and $_ -notmatch '^127\.' } |
    Select-Object -First 1
  if (-not $guestIp) {
    $guestIp = @(Get-VMGuestIPAddress -VM $vm -ErrorAction SilentlyContinue) |
      Where-Object { $_.IPAddress -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_.IPAddress -notmatch '^169\.' } |
      Select-Object -ExpandProperty IPAddress -First 1
  }
  if ($guestIp) { break }
  Start-Sleep -Seconds 5
}

if (-not $guestIp) {
  throw "No guest IPv4 seen on VM network adapter. Open Hyper-V Manager -> Connect, finish OOBE/boot, ensure Integration Services, then retry."
}

Write-Host "[ok] Guest IP: $guestIp"

$listen = '127.0.0.1'
cmd /c "netsh interface portproxy delete v4tov4 listenport=$LocalPort listenaddress=$listen >nul 2>&1"
netsh interface portproxy add v4tov4 listenport=$LocalPort listenaddress=$listen connectport=$GuestVncPort connectaddress=$guestIp | Out-Null

Write-Host ""
Write-Host "[ok] VNC tunnel:  127.0.0.1:$LocalPort  ->  ${guestIp}:${GuestVncPort}"
Write-Host "     TightVNC password (bootstrap):  FELDTECH_VNC"
Write-Host "     Remove tunnel later:  netsh interface portproxy delete v4tov4 listenport=$LocalPort listenaddress=$listen"
