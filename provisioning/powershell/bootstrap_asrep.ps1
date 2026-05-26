# SecretCon 2026 - ASREP demo DC bootstrap
#
# Stages guest-side promotion/seed script and registers a startup fallback task.
# Packer runs C:\secretcon\asrep-bootstrap.ps1 directly after reboot.
#
# Inputs (env):
#   AD_DOMAIN, AD_NETBIOS, AD_SAFEMODE_PASSWORD
#   SECRETCON_ASREP_USER, SECRETCON_ASREP_PASSWORD, SECRETCON_ASREP_FLAG
#   WAZUH_MANAGER

$secretconLib = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root "SecretCon.Bootstrap.psm1" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $secretconLib) {
    $secretconLib = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib\SecretCon.Bootstrap.psm1"
}
Import-Module $secretconLib -Force -ErrorAction Stop

$ErrorActionPreference = "Stop"
Write-Host "[*] ASREP demo DC bootstrap starting"

$domain       = Get-SecretConEnvDefault -Name "AD_DOMAIN" -Default "secretcon.local"
$netbios      = Get-SecretConEnvDefault -Name "AD_NETBIOS" -Default "SECRETCON"
$dsrmPlain    = Get-SecretConEnvDefault -Name "AD_SAFEMODE_PASSWORD" -Default "PizzaMan123!"
$asrepUser    = Get-SecretConEnvDefault -Name "SECRETCON_ASREP_USER" -Default "enite"
$asrepPass    = Get-SecretConEnvDefault -Name "SECRETCON_ASREP_PASSWORD" -Default "stud87"
$asrepFlag    = Get-SecretConEnvDefault -Name "SECRETCON_ASREP_FLAG" -Default "asrep-flag-placeholder"
$dcUserFlag   = Get-SecretConEnvDefault -Name "SECRETCON_DC_USER_FLAG" -Default $asrepFlag
$dcRootFlag   = Get-SecretConEnvDefault -Name "SECRETCON_DC_ROOT_FLAG" -Default "asrep-root-flag-placeholder"
$eniteDa      = Get-SecretConEnvDefault -Name "SECRETCON_ASREP_ENITE_DA" -Default "1"
$wazuhManager = Get-SecretConEnvDefault -Name "WAZUH_MANAGER" -Default "10.0.3.2"

New-Item -ItemType Directory -Path "C:\secretcon" -Force | Out-Null

Install-SecretConSysmon
$wazuhOptional = ($env:WAZUH_ENROLLMENT_OPTIONAL -eq "1")
Install-SecretConWazuhAgent `
    -Manager $wazuhManager `
    -Group "asrep" `
    -EnrollmentOptional:$wazuhOptional

Write-Host "[*] Installing AD-Domain-Services feature"
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null

$runtimeSrc = Find-ProvisionFile -Name "asrep-bootstrap-runtime.ps1"
if (-not $runtimeSrc) {
    throw "asrep-bootstrap-runtime.ps1 not found on PROVISION media"
}

$bootstrapPath = "C:\secretcon\asrep-bootstrap.ps1"
Copy-Item -Path $runtimeSrc -Destination $bootstrapPath -Force
Write-Host "[+] Staged runtime bootstrap: $bootstrapPath"

# Persist config for startup task / later Packer passes (machine scope).
[Environment]::SetEnvironmentVariable("AD_DOMAIN", $domain, "Machine")
[Environment]::SetEnvironmentVariable("AD_NETBIOS", $netbios, "Machine")
[Environment]::SetEnvironmentVariable("AD_SAFEMODE_PASSWORD", $dsrmPlain, "Machine")
[Environment]::SetEnvironmentVariable("SECRETCON_ASREP_USER", $asrepUser, "Machine")
[Environment]::SetEnvironmentVariable("SECRETCON_ASREP_PASSWORD", $asrepPass, "Machine")
[Environment]::SetEnvironmentVariable("SECRETCON_ASREP_FLAG", $asrepFlag, "Machine")
[Environment]::SetEnvironmentVariable("SECRETCON_DC_USER_FLAG", $dcUserFlag, "Machine")
[Environment]::SetEnvironmentVariable("SECRETCON_DC_ROOT_FLAG", $dcRootFlag, "Machine")
[Environment]::SetEnvironmentVariable("SECRETCON_ASREP_ENITE_DA", $eniteDa, "Machine")

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$bootstrapPath`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "SecretConAsrepBootstrap" `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "[*] Registered SecretConAsrepBootstrap (startup fallback)"
Write-Host "[*] ASREP bootstrap staging complete"
exit 0
