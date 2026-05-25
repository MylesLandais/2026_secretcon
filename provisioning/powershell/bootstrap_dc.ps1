# SecretCon 2026 — Domain Controller bootstrap (DC1 primary / DC2 replica)
#
# Inputs (env):
#   DC_ROLE              : "primary" | "replica"
#   AD_DOMAIN            : FQDN, default heliumsupply.local
#   AD_NETBIOS           : NetBIOS, default HELIUM
#   AD_SAFEMODE_PASSWORD : DSRM password (required)
#   AD_ADMIN_PASSWORD    : Domain Admin password for replica join (replica only)
#   REPLICA_SOURCE_DC    : DC1 IP for replica to reach (replica only)
#   WAZUH_MANAGER        : Wazuh manager IP, default 192.168.61.10
#   WAZUH_AGENT_VERSION  : default 4.14.5
#
# Strategy: install telemetry + AD-Domain-Services feature now, then stage a
# one-shot SYSTEM scheduled task that runs the dcpromo at next boot. Packer's
# bootstrap returns cleanly; the deploy wrapper triggers `qm reset` to fire
# the task. The promotion itself auto-reboots a second time to complete.

$secretconLib = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root "SecretCon.Bootstrap.psm1" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $secretconLib) {
    $secretconLib = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib\SecretCon.Bootstrap.psm1"
}
Import-Module $secretconLib -Force -ErrorAction Stop

$ErrorActionPreference = "Stop"
Write-Host "[*] DC bootstrap starting (role=$env:DC_ROLE)"

$role         = Get-SecretConEnvDefault -Name "DC_ROLE" -Default "primary"
$domain       = Get-SecretConEnvDefault -Name "AD_DOMAIN" -Default "heliumsupply.local"
$netbios      = Get-SecretConEnvDefault -Name "AD_NETBIOS" -Default "HELIUM"
$dsrmPlain    = Get-SecretConEnvDefault -Name "AD_SAFEMODE_PASSWORD" -Default ""
if (-not $dsrmPlain) { throw "AD_SAFEMODE_PASSWORD required" }
$wazuhManager = Get-SecretConEnvDefault -Name "WAZUH_MANAGER" -Default "192.168.61.10"
$wazuhVersion = Get-SecretConEnvDefault -Name "WAZUH_AGENT_VERSION" -Default "4.14.5"

Install-SecretConSysmon
$wazuhGroup = if ($role -eq "primary") { "dc-primary" } else { "dc-replica" }
Install-SecretConWazuhAgent -Manager $wazuhManager -Version $wazuhVersion -Group $wazuhGroup

Write-Host "[*] Installing AD-Domain-Services feature"
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null

$promoteMarker = "C:\secretcon\promoted.marker"
$promoteLog    = "C:\secretcon\promote.log"

if ($role -eq "primary") {
    $promoteScript = @"
`$ErrorActionPreference = 'Stop'
Start-Transcript -Path '$promoteLog' -Append
try {
    if (Test-Path '$promoteMarker') { Write-Host 'already promoted'; Stop-Transcript; exit 0 }
    Import-Module ADDSDeployment
    `$dsrm = ConvertTo-SecureString '$dsrmPlain' -AsPlainText -Force
    Install-ADDSForest ``
        -DomainName               '$domain' ``
        -DomainNetbiosName        '$netbios' ``
        -SafeModeAdministratorPassword `$dsrm ``
        -InstallDns               `$true ``
        -CreateDnsDelegation:`$false ``
        -DatabasePath             'C:\Windows\NTDS' ``
        -LogPath                  'C:\Windows\NTDS' ``
        -SysvolPath               'C:\Windows\SYSVOL' ``
        -ForestMode               'WinThreshold' ``
        -DomainMode               'WinThreshold' ``
        -NoRebootOnCompletion:`$false ``
        -Force:`$true
    New-Item -Path '$promoteMarker' -ItemType File -Force | Out-Null
} catch {
    Write-Host "ERROR: `$_"
} finally {
    Stop-Transcript
}
"@
}
elseif ($role -eq "replica") {
    $adminPlain = Get-SecretConEnvDefault -Name "AD_ADMIN_PASSWORD" -Default ""
    if (-not $adminPlain) { throw "AD_ADMIN_PASSWORD required for replica" }
    $srcDc      = Get-SecretConEnvDefault -Name "REPLICA_SOURCE_DC" -Default ""
    if (-not $srcDc) { throw "REPLICA_SOURCE_DC required for replica" }

    $promoteScript = @"
`$ErrorActionPreference = 'Stop'
Start-Transcript -Path '$promoteLog' -Append
try {
    if (Test-Path '$promoteMarker') { Write-Host 'already promoted'; Stop-Transcript; exit 0 }
    `$deadline = (Get-Date).AddMinutes(15)
    `$ok = `$false
    while ((Get-Date) -lt `$deadline) {
        if (Test-NetConnection -ComputerName '$srcDc' -Port 389 -InformationLevel Quiet) { `$ok = `$true; break }
        Start-Sleep -Seconds 10
    }
    if (-not `$ok) { throw "DC1 $srcDc:389 unreachable" }

    Import-Module ADDSDeployment
    `$dsrm  = ConvertTo-SecureString '$dsrmPlain' -AsPlainText -Force
    `$admin = ConvertTo-SecureString '$adminPlain' -AsPlainText -Force
    `$cred  = New-Object System.Management.Automation.PSCredential('$netbios\Administrator', `$admin)
    Install-ADDSDomainController ``
        -DomainName               '$domain' ``
        -SafeModeAdministratorPassword `$dsrm ``
        -Credential               `$cred ``
        -InstallDns               `$true ``
        -DatabasePath             'C:\Windows\NTDS' ``
        -LogPath                  'C:\Windows\NTDS' ``
        -SysvolPath               'C:\Windows\SYSVOL' ``
        -SiteName                 'Default-First-Site-Name' ``
        -NoRebootOnCompletion:`$false ``
        -Force:`$true
    New-Item -Path '$promoteMarker' -ItemType File -Force | Out-Null
} catch {
    Write-Host "ERROR: `$_"
} finally {
    Stop-Transcript
}
"@
}
else {
    throw "Unknown DC_ROLE '$role'"
}

$promotePath = "C:\secretcon\promote-dc.ps1"
Set-Content -Path $promotePath -Value $promoteScript -Encoding UTF8

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$promotePath`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "SecretConDcPromote" `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "[*] DC bootstrap done. Scheduled task SecretConDcPromote will run at next boot."
Write-Host "[*] Deploy wrapper should now: qm reset, then poll for promotion completion."
exit 0
