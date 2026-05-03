# SecretCon 2026 — Win11 EWS Bootstrap
# Runs during Packer provisioning (both Proxmox and AWS)

Write-Host "[*] Starting EWS bootstrap..."

# Long Paths
Set-ItemProperty `
  -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name 'LongPathsEnabled' -Value 1

# .NET 3.5
Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart

# Static IP (Proxmox OT VLAN 10) — skip if already DHCP'd (local test)
$iface = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
if ($iface -and -not ($iface.IPAddress -match "192\.168\.61\.")) {
    try {
        New-NetIPAddress `
          -InterfaceAlias $iface.Name `
          -IPAddress "192.168.61.20" `
          -PrefixLength 24 `
          -DefaultGateway "192.168.61.1" -ErrorAction Stop
        Set-DnsClientServerAddress `
          -InterfaceAlias $iface.Name `
          -ServerAddresses ("192.168.61.1","1.1.1.1") -ErrorAction Stop
    } catch {
        Write-Host "[!] Static IP config skipped (local test env detected)"
    }
}

# Sysmon (Wazuh blue-team logging)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path "C:\secretcon" -Force | Out-Null
$sysmonConfigUrl = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"
Invoke-WebRequest -Uri $sysmonConfigUrl -OutFile "C:\secretcon\sysmon-config.xml" -UseBasicParsing
$sysmonUrl = "https://download.sysinternals.com/files/Sysmon.zip"
$sysmonZip = "$env:TEMP\Sysmon.zip"
Invoke-WebRequest -Uri $sysmonUrl -OutFile $sysmonZip
Expand-Archive -Path $sysmonZip -DestinationPath "$env:TEMP\Sysmon" -Force
& "$env:TEMP\Sysmon\Sysmon64.exe" -accepteula -i C:\secretcon\sysmon-config.xml

# Wazuh agent
$WazuhManager = if ($env:WAZUH_MANAGER) { $env:WAZUH_MANAGER } else { "192.168.61.10" }
$WazuhVersion = "4.8.0"
$wazuhMsi = "C:\wazuh-agent-$WazuhVersion-1.msi"
Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WazuhVersion-1.msi" -OutFile $wazuhMsi
Start-Process msiexec.exe -ArgumentList "/i $wazuhMsi /q WAZUH_MANAGER=$WazuhManager WAZUH_AGENT_GROUP=ews" -Wait
Start-Service WazuhSvc

# CTF user: patrick (low-priv)
$pw = ConvertTo-SecureString "Changeme123!" -AsPlainText -Force
New-LocalUser -Name "patrick" -Password $pw -FullName "Patrick" -Description "OT Operator"
Add-LocalGroupMember -Group "Users" -Member "patrick"
Remove-LocalGroupMember -Group "Administrators" -Member "patrick" -ErrorAction SilentlyContinue

# Flag artifact
New-Item -ItemType Directory -Path "C:\secretcon" -Force
"crit-low-priv-patrick" | Out-File -Encoding utf8 "C:\secretcon\flag_lowpriv.txt"

# Python + pycomm3 for ICS challenges
$pyInstaller = "C:\python-3.12.7-amd64.exe"
Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe" -OutFile $pyInstaller
Start-Process $pyInstaller -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1" -Wait
& "C:\Program Files\Python312\python.exe" -m pip install --no-warn-script-location pycomm3

Write-Host "[*] Validating bootstrap..."
$failed = @()
foreach ($svc in 'Sysmon64','WazuhSvc') {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { $failed += "$svc not installed" }
    elseif ($s.Status -ne 'Running') { $failed += "$svc not running ($($s.Status))" }
}
& "C:\Program Files\Python312\python.exe" -c "import pycomm3; print(pycomm3.__version__)"
if ($LASTEXITCODE -ne 0) { $failed += "pycomm3 import failed" }
if ($failed.Count -gt 0) {
    Write-Error ("Bootstrap validation failed: " + ($failed -join '; '))
    exit 1
}
Write-Host "[*] Bootstrap complete."
