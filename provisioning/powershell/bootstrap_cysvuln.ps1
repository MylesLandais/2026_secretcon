# SecretCon 2026 — CysVulnServer (VM 108) Bootstrap
# Reproduces Cy's challenge box from a clean Windows Server 2016 install.
#
# Inputs (env):
#   WAZUH_MANAGER          : Wazuh manager IP (default 192.168.61.10)
#   SECRETCON_USER_FLAG    : flag string written to User_Joe's desktop (default placeholder)
#   SECRETCON_ROOT_FLAG    : flag string written to Administrator desktop (default placeholder)
#   CYSVULN_JOE_PASSWORD   : low-priv user password (default matches Cy's plaintext note)
#   CYSVULN_INSTALLER_HASH : sha256 of the EFS installer to pin (default = observed hash)
#
# Staged on the provisioning ISO (mounted at first removable drive):
#   60f3ff1f3cd34dec80fba130ea481f31-efssetup.exe

$ErrorActionPreference = "Stop"
Write-Host "[*] Starting CysVulnServer bootstrap..."

$userFlag = if ($env:SECRETCON_USER_FLAG) { $env:SECRETCON_USER_FLAG } else { "cysvuln-user-flag-placeholder" }
$rootFlag = if ($env:SECRETCON_ROOT_FLAG) { $env:SECRETCON_ROOT_FLAG } else { "cysvuln-root-flag-placeholder" }
$joePw    = if ($env:CYSVULN_JOE_PASSWORD) { $env:CYSVULN_JOE_PASSWORD } else { "VeryStrongPassword123!@#" }
$expectedHash = if ($env:CYSVULN_INSTALLER_HASH) { $env:CYSVULN_INSTALLER_HASH } else { "60ea3256cd272797675e2ec6ea8e02d8ad51209f1cbf9083bc909284b5331d79" }

# Long paths (matches EWS pattern; avoids Inno Setup edge cases on deeply nested paths)
Set-ItemProperty `
  -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name 'LongPathsEnabled' -Value 1

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Path "C:\secretcon" -Force | Out-Null

# Sysmon (telemetry parity with EWS)
$sysmonConfigUrl = "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml"
Invoke-WebRequest -Uri $sysmonConfigUrl -OutFile "C:\secretcon\sysmon-config.xml" -UseBasicParsing
$sysmonZip = "$env:TEMP\Sysmon.zip"
Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $sysmonZip
Expand-Archive -Path $sysmonZip -DestinationPath "$env:TEMP\Sysmon" -Force
& "$env:TEMP\Sysmon\Sysmon64.exe" -accepteula -i C:\secretcon\sysmon-config.xml

# Wazuh agent — closes the open todo from 2026-secretcon-ctf.md line 157
$WazuhManager = if ($env:WAZUH_MANAGER) { $env:WAZUH_MANAGER } else { "192.168.61.10" }
$WazuhVersion = "4.8.0"
$wazuhMsi = "C:\wazuh-agent-$WazuhVersion-1.msi"
Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WazuhVersion-1.msi" -OutFile $wazuhMsi
Start-Process msiexec.exe -ArgumentList "/i $wazuhMsi /q WAZUH_MANAGER=$WazuhManager WAZUH_AGENT_GROUP=ews" -Wait
Start-Service WazuhSvc

# Low-priv user: matches Cy's documented Notes.txt account
$pwSecure = ConvertTo-SecureString $joePw -AsPlainText -Force
if (-not (Get-LocalUser -Name "User_Joe" -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name "User_Joe" -Password $pwSecure -FullName "Joe" -Description "CysVuln low-priv operator" -PasswordNeverExpires
}
Add-LocalGroupMember -Group "Users" -Member "User_Joe" -ErrorAction SilentlyContinue
Remove-LocalGroupMember -Group "Administrators" -Member "User_Joe" -ErrorAction SilentlyContinue

# Locate the staged EFS installer from the PROVISION ISO
$installerName = "60f3ff1f3cd34dec80fba130ea481f31-efssetup.exe"
$stagedInstaller = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root $installerName } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $stagedInstaller) {
    throw "EFS installer $installerName not found on any mounted drive"
}
$installerPath = "C:\secretcon\$installerName"
Copy-Item -Path $stagedInstaller -Destination $installerPath -Force

# Pin the installer by sha256; refuse to proceed if it does not match the
# artifact captured from Cy's live box on 2026-05-19.
$actualHash = (Get-FileHash -Algorithm SHA256 -Path $installerPath).Hash.ToLower()
if ($actualHash -ne $expectedHash.ToLower()) {
    throw "EFS installer hash mismatch: expected $expectedHash, got $actualHash"
}

# Easy File Sharing Web Server 6.9 — Inno Setup silent install
# Inno Setup honours /VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART
$installArgs = "/VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART"
Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait

$efsRoot = "C:\EFS Software\Easy File Sharing Web Server"
if (-not (Test-Path "$efsRoot\fsws.exe")) {
    throw "EFS install did not produce fsws.exe at $efsRoot"
}

# Downgrade fswsService identity from LocalSystem to User_Joe so that the
# foothold exploit (EDB-42256) yields a Joe shell, not a SYSTEM shell.
# Without this the two-flag chain collapses into one.
if (Get-Service -Name fswsService -ErrorAction SilentlyContinue) {
    & sc.exe config fswsService obj= ".\User_Joe" password= $joePw | Out-Null
    & sc.exe privs fswsService /SeServiceLogonRight | Out-Null
} else {
    # Inno Setup may not have registered the service; create it manually.
    & sc.exe create fswsService binPath= "`"$efsRoot\fswsService.exe`"" start= auto obj= ".\User_Joe" password= $joePw DisplayName= "Easy File Sharing Web Server" | Out-Null
}
# Grant "Log on as a service" to User_Joe via secedit (sc.exe privs requires modern Win versions)
$secCfg = "$env:TEMP\joe-svc-logon.inf"
$secDb  = "$env:TEMP\joe-svc-logon.sdb"
secedit /export /cfg $secCfg /areas USER_RIGHTS | Out-Null
$cfgText = Get-Content $secCfg -Raw
$joeSid = (New-Object System.Security.Principal.NTAccount("User_Joe")).Translate([System.Security.Principal.SecurityIdentifier]).Value
if ($cfgText -match 'SeServiceLogonRight\s*=\s*([^\r\n]*)') {
    $existing = $matches[1]
    if ($existing -notmatch [Regex]::Escape($joeSid)) {
        $cfgText = $cfgText -replace 'SeServiceLogonRight\s*=.*', "SeServiceLogonRight = $existing,*$joeSid"
    }
} else {
    $cfgText = $cfgText -replace '(\[Privilege Rights\])', "`$1`r`nSeServiceLogonRight = *$joeSid"
}
Set-Content -Path $secCfg -Value $cfgText -Encoding Unicode
secedit /configure /db $secDb /cfg $secCfg /areas USER_RIGHTS | Out-Null

Set-Service -Name fswsService -StartupType Automatic
Start-Service fswsService

# Firewall — Cy's pending build-steps
Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In -ErrorAction SilentlyContinue
if (-not (Get-NetFirewallRule -DisplayName "Allow Port 80" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow Port 80" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow | Out-Null
}
if (-not (Get-NetFirewallRule -DisplayName "Allow Port 443" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow Port 443" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
}

# AlwaysInstallElevated — Cy's pending build-steps. HKLM is set here directly.
# HKCU must be set in User_Joe's hive; we use a one-shot logon task seeded by the
# Administrator install, so the value lands the first time Joe signs in.
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" `
                 -Name "AlwaysInstallElevated" -Value 1 -Type DWord

# UAC consent gate — the second load-bearing setting that the original Notes.txt
# checklist missed. On Server 2016, AIE alone is not sufficient: msiexec still
# cannot obtain its SYSTEM elevation token while ConsentPromptBehaviorAdmin is at
# its default of 5 (prompt-for-consent). Setting it to 0 lets the Installer
# service auto-elevate non-interactively, which is what the AIE chain assumes.
# EnableLUA stays 1 so UAC remains "on" in the OS sense and the misconfig stays
# realistic. See nickvourd's privesc cookbook for the canonical reference.
$uacKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $uacKey -Name "ConsentPromptBehaviorAdmin" -Value 0 -Type DWord
Set-ItemProperty -Path $uacKey -Name "PromptOnSecureDesktop"      -Value 0 -Type DWord

$hkcuSeeder = "C:\secretcon\seed-joe-hkcu.ps1"
@'
New-Item -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer" `
                 -Name "AlwaysInstallElevated" -Value 1 -Type DWord
'@ | Set-Content -Encoding utf8 $hkcuSeeder

$hkcuTaskAction = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$hkcuSeeder`""
$hkcuTaskTrigger = New-ScheduledTaskTrigger -AtLogOn -User "User_Joe"
$hkcuTaskPrincipal = New-ScheduledTaskPrincipal -UserId "User_Joe" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask `
  -TaskName "CysVulnSeedJoeHKCU" `
  -Action $hkcuTaskAction `
  -Trigger $hkcuTaskTrigger `
  -Principal $hkcuTaskPrincipal `
  -Force | Out-Null

# User flag (Flag 1) on User_Joe's desktop — seeded via logon task so the
# profile path exists when we write it.
$userFlagSeeder = "C:\secretcon\seed-user-flag.ps1"
$userFlagB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userFlag))
@"
`$desktop = [Environment]::GetFolderPath("Desktop")
`$flag = Join-Path `$desktop "user.txt"
`$value = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$userFlagB64"))
[System.IO.File]::WriteAllText(`$flag, `$value, [System.Text.UTF8Encoding]::new(`$false))
icacls `$flag /inheritance:r /grant "User_Joe:R" "Administrators:F" "SYSTEM:F" | Out-Null
"@ | Set-Content -Encoding utf8 $userFlagSeeder
$flagTaskAction = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$userFlagSeeder`""
$flagTaskTrigger = New-ScheduledTaskTrigger -AtLogOn -User "User_Joe"
$flagTaskPrincipal = New-ScheduledTaskPrincipal -UserId "User_Joe" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask `
  -TaskName "CysVulnUserFlag" `
  -Action $flagTaskAction `
  -Trigger $flagTaskTrigger `
  -Principal $flagTaskPrincipal `
  -Force | Out-Null

# Root flag (Flag 2) on Administrator desktop
$administratorDesktop = "C:\Users\Administrator\Desktop"
$rootFlagPath = Join-Path $administratorDesktop "root.txt"
New-Item -ItemType Directory -Path $administratorDesktop -Force | Out-Null
[System.IO.File]::WriteAllText(
    $rootFlagPath,
    $rootFlag,
    [System.Text.UTF8Encoding]::new($false)
)
icacls $rootFlagPath /inheritance:r /grant "SYSTEM:F" "Administrators:F" | Out-Null

# Notes.txt parity with Cy's box (player-visible hint sheet).
# Includes credentials and EDB pointer; intentional side-door per spec.
$joeDesktopSeeder = "C:\secretcon\seed-joe-notes.ps1"
@'
$desktop = [Environment]::GetFolderPath("Desktop")
$notes = Join-Path $desktop "Notes.txt"
$body = @"
https://www.exploit-db.com/exploits/42256


Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In

New-NetFirewallRule -DisplayName "Allow Port 80" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow

reg add HKLM\Software\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated /t REG_DWORD /d 1 /f

reg add HKCU\Software\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated /t REG_DWORD /d 1 /f

User_Joe
VeryStrongPassword123!@#
"@
[System.IO.File]::WriteAllText($notes, $body, [System.Text.UTF8Encoding]::new($false))
'@ | Set-Content -Encoding utf8 $joeDesktopSeeder
$notesTaskAction = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$joeDesktopSeeder`""
Register-ScheduledTask `
  -TaskName "CysVulnSeedJoeNotes" `
  -Action $notesTaskAction `
  -Trigger $hkcuTaskTrigger `
  -Principal $hkcuTaskPrincipal `
  -Force | Out-Null

# Stage the EFS installer on Joe's desktop too (reproducibility artifact for
# any player auditing the box from inside)
Copy-Item -Path $installerPath -Destination "C:\secretcon\$installerName" -Force
$installerSeeder = "C:\secretcon\seed-joe-installer.ps1"
@"
`$desktop = [Environment]::GetFolderPath("Desktop")
Copy-Item -Path "C:\secretcon\$installerName" -Destination (Join-Path `$desktop "$installerName") -Force
"@ | Set-Content -Encoding utf8 $installerSeeder
Register-ScheduledTask `
  -TaskName "CysVulnSeedJoeInstaller" `
  -Action (New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$installerSeeder`"") `
  -Trigger $hkcuTaskTrigger `
  -Principal $hkcuTaskPrincipal `
  -Force | Out-Null

# Defender exclusions: lab paths only, keep telemetry useful elsewhere
try {
    Add-MpPreference -ExclusionPath $efsRoot -ErrorAction Stop
    Add-MpPreference -ExclusionPath "C:\secretcon" -ErrorAction Stop
} catch {
    Write-Host "[!] Defender exclusions skipped: $($_.Exception.Message)"
}

Write-Host "[*] Validating bootstrap..."
$failed = @()
foreach ($svc in 'Sysmon64','WazuhSvc','fswsService') {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { $failed += "$svc not installed" }
    elseif ($s.Status -ne 'Running') { $failed += "$svc not running ($($s.Status))" }
}
$fswsStartName = (Get-CimInstance Win32_Service -Filter "Name='fswsService'").StartName
if ($fswsStartName -ne '.\User_Joe' -and $fswsStartName -ne 'WIN-CYSVULN\User_Joe') {
    # The hostname may vary; accept any *\User_Joe form.
    if ($fswsStartName -notmatch '\\User_Joe$') {
        $failed += "fswsService runs as $fswsStartName, expected User_Joe"
    }
}
$hklmKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer"
$hklmVal = (Get-ItemProperty -Path $hklmKey -Name AlwaysInstallElevated -ErrorAction SilentlyContinue).AlwaysInstallElevated
if ($hklmVal -ne 1) { $failed += "HKLM AlwaysInstallElevated not set (got $hklmVal)" }
$uacCheckKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$cpba = (Get-ItemProperty -Path $uacCheckKey -Name ConsentPromptBehaviorAdmin -ErrorAction SilentlyContinue).ConsentPromptBehaviorAdmin
if ($cpba -ne 0) { $failed += "ConsentPromptBehaviorAdmin not 0 (got $cpba) — AIE chain will be blocked at the UAC gate" }
if (-not (Test-Path $rootFlagPath)) { $failed += "root flag missing" }
foreach ($t in 'CysVulnSeedJoeHKCU','CysVulnUserFlag','CysVulnSeedJoeNotes','CysVulnSeedJoeInstaller') {
    if (-not (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)) { $failed += "$t task missing" }
}
if (-not (Get-NetFirewallRule -DisplayName "Allow Port 80" -ErrorAction SilentlyContinue)) {
    $failed += "TCP/80 firewall rule missing"
}
if ($failed.Count -gt 0) {
    Write-Error ("Bootstrap validation failed: " + ($failed -join '; '))
    exit 1
}
Write-Host "[*] Bootstrap complete. First sign-in as User_Joe will seed HKCU AlwaysInstallElevated, Notes.txt, user.txt, and the installer artifact."
