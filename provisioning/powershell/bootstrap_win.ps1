# SecretCon 2026 — Win11 EWS Bootstrap
# Runs during Packer provisioning (both Proxmox and AWS)

Write-Host "[*] Starting EWS bootstrap..."

# Long Paths
Set-ItemProperty `
  -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name 'LongPathsEnabled' -Value 1

# .NET 3.5
Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart

# Static IP (Proxmox OT VLAN 10)
$iface = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
if ($iface) {
    New-NetIPAddress `
      -InterfaceAlias $iface.Name `
      -IPAddress "192.168.61.20" `
      -PrefixLength 24 `
      -DefaultGateway "192.168.61.1" -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress `
      -InterfaceAlias $iface.Name `
      -ServerAddresses ("192.168.61.1","1.1.1.1") -ErrorAction SilentlyContinue
}

# WinRM hardening for Packer
winrm quickconfig -q
winrm set winrm/config/service '@{AllowUnencrypted="true"}'
winrm set winrm/config/service/auth '@{Basic="true"}'
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name 'LocalAccountTokenFilterPolicy' -Value 1

# Sysmon (Wazuh blue-team logging)
$sysmonUrl = "https://download.sysinternals.com/files/Sysmon.zip"
$sysmonZip = "$env:TEMP\Sysmon.zip"
Invoke-WebRequest -Uri $sysmonUrl -OutFile $sysmonZip
Expand-Archive -Path $sysmonZip -DestinationPath "$env:TEMP\Sysmon" -Force
& "$env:TEMP\Sysmon\sysmon.exe" -accepteula -i C:\secretcon\sysmon-config.xml

# CTF user: patrick (low-priv)
$pw = ConvertTo-SecureString "Changeme123!" -AsPlainText -Force
New-LocalUser -Name "patrick" -Password $pw -FullName "Patrick" -Description "OT Operator"
Add-LocalGroupMember -Group "Users" -Member "patrick"
Remove-LocalGroupMember -Group "Administrators" -Member "patrick" -ErrorAction SilentlyContinue

# Flag artifact
New-Item -ItemType Directory -Path "C:\secretcon" -Force
"crit-low-priv-patrick" | Out-File -Encoding utf8 "C:\secretcon\flag_lowpriv.txt"

# Wazuh agent placeholder
Write-Host "[*] Bootstrap complete. Install Wazuh agent manually or via GPO."
