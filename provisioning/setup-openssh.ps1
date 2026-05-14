$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\setup-openssh.log'
Start-Transcript -Path $log -Force

$src = (Get-Volume | Where-Object FileSystemLabel -eq 'PROVISION' | Select-Object -First 1).DriveLetter
if (-not $src) {
  $src = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path "$($_.Root)setup-openssh.ps1" } | Select-Object -First 1).Name
}
if (-not $src) { throw "PROVISION media not found" }
$root = "${src}:\"
Write-Host "[setup-openssh] using provisioning media at $root"

$networkConfig = Join-Path $root 'proxmox-static-ip.txt'
if (Test-Path $networkConfig) {
  $parts = ((Get-Content $networkConfig -Raw).Trim() -split '\|')
  if ($parts.Count -lt 3) {
    throw "Invalid proxmox-static-ip.txt; expected IP|prefix|gateway|dns"
  }

  $ip = $parts[0]
  $prefix = [int]$parts[1]
  $gateway = $parts[2]
  $dns = @()
  if ($parts.Count -ge 4 -and $parts[3]) {
    $dns = $parts[3] -split ','
  }

  $adapter = Get-NetAdapter |
    Where-Object Status -eq 'Up' |
    Sort-Object InterfaceMetric, ifIndex |
    Select-Object -First 1
  if (-not $adapter) { throw "No active network adapter found for static IP setup" }

  Write-Host "[setup-openssh] applying static IPv4 $ip/$prefix via $gateway on $($adapter.Name)"
  Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object IPAddress -ne '127.0.0.1' |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
  Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object DestinationPrefix -eq '0.0.0.0/0' |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gateway | Out-Null
  if ($dns.Count -gt 0) {
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dns
  }
}

$zip = Join-Path $root 'OpenSSH-Win64.zip'
$dst = 'C:\Program Files\OpenSSH'
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Expand-Archive -Path $zip -DestinationPath 'C:\Program Files' -Force
Rename-Item 'C:\Program Files\OpenSSH-Win64' $dst

& powershell -NoProfile -ExecutionPolicy Bypass -File "$dst\install-sshd.ps1"

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH SSH Server' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

$key = (Get-Content (Join-Path $root 'packer_ed25519.pub') -Raw).Trim()
$akf = 'C:\ProgramData\ssh\administrators_authorized_keys'
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\ssh' | Out-Null
Set-Content -Path $akf -Value $key -Encoding ASCII
icacls $akf /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'

New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -PropertyType String -Force | Out-Null

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

Write-Host "[setup-openssh] done"
Stop-Transcript
