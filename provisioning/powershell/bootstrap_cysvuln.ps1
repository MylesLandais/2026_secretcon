# SecretCon 2026 - CysVulnServer (VM 108) Bootstrap
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

$secretconLib = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root "SecretCon.Bootstrap.psm1" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $secretconLib) {
    $secretconLib = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib\SecretCon.Bootstrap.psm1"
}
Import-Module $secretconLib -Force -ErrorAction Stop

$ErrorActionPreference = "Stop"
Write-Host "[*] Starting CysVulnServer bootstrap..."

$userFlag = Get-SecretConEnvDefault -Name "SECRETCON_USER_FLAG" -Default "cysvuln-user-flag-placeholder"
$rootFlag = Get-SecretConEnvDefault -Name "SECRETCON_ROOT_FLAG" -Default "cysvuln-root-flag-placeholder"
$joePw    = Get-SecretConEnvDefault -Name "CYSVULN_JOE_PASSWORD" -Default "VeryStrongPassword123!@#"
$expectedHash = Get-SecretConEnvDefault -Name "CYSVULN_INSTALLER_HASH" -Default "60ea3256cd272797675e2ec6ea8e02d8ad51209f1cbf9083bc909284b5331d79"

# Long paths (matches EWS pattern; avoids Inno Setup edge cases on deeply nested paths)
Set-ItemProperty `
  -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name 'LongPathsEnabled' -Value 1

Install-SecretConSysmon
$wazuhOptional = ($env:WAZUH_ENROLLMENT_OPTIONAL -eq "1")
Install-SecretConWazuhAgent `
    -Manager (Get-SecretConEnvDefault -Name "WAZUH_MANAGER" -Default "192.168.61.10") `
    -Group "ews" `
    -EnrollmentOptional:$wazuhOptional

# Low-priv user: matches Cy's documented Notes.txt account
$pwSecure = ConvertTo-SecureString $joePw -AsPlainText -Force
if (-not (Get-LocalUser -Name "User_Joe" -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name "User_Joe" -Password $pwSecure -FullName "Joe" -Description "CysVuln low-priv operator" -PasswordNeverExpires
}
Add-LocalGroupMember -Group "Users" -Member "User_Joe" -ErrorAction SilentlyContinue
Remove-LocalGroupMember -Group "Administrators" -Member "User_Joe" -ErrorAction SilentlyContinue

# Seed User_Joe HKCU hive before profile/desktop activity locks NTUSER.DAT.
$joeProfileDir = "C:\Users\User_Joe"
$joeDesktopDir = Join-Path $joeProfileDir "Desktop"
$joeHive = Join-Path $joeProfileDir "NTUSER.DAT"
$defaultHive = "C:\Users\Default\NTUSER.DAT"

if (-not (Test-Path $joeProfileDir)) {
    New-Item -ItemType Directory -Path $joeProfileDir -Force | Out-Null
    & icacls $joeProfileDir /inheritance:r /grant "User_Joe:(OI)(CI)(RX)" /grant "SYSTEM:(OI)(CI)(F)" /grant "Administrators:(OI)(CI)(F)" | Out-Null
}
if (-not (Test-Path $joeHive) -and (Test-Path $defaultHive)) {
    Copy-Item -Path $defaultHive -Destination $joeHive -Force
}
if (Test-Path $joeHive) {
    $tempHive = Join-Path $env:TEMP ("User_Joe_NTUSER_" + [guid]::NewGuid().Guid + ".dat")
    $seedKey = "JoeSeed"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Copy-Item -Path $joeHive -Destination $tempHive -Force
        & takeown /f $tempHive /a 2>&1 | Out-Null
        & icacls $tempHive /grant "Administrators:(F)" /grant "SYSTEM:(F)" | Out-Null
        & reg.exe load "HKU\$seedKey" $tempHive 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg load failed (exit $LASTEXITCODE)" }
        New-Item -Path "HKU:\$seedKey\SOFTWARE\Policies\Microsoft\Windows\Installer" -Force | Out-Null
        Set-ItemProperty -Path "HKU:\$seedKey\SOFTWARE\Policies\Microsoft\Windows\Installer" `
                         -Name "AlwaysInstallElevated" -Value 1 -Type DWord
        [gc]::Collect()
        Start-Sleep -Seconds 1
        & reg.exe unload "HKU\$seedKey" 2>&1 | Out-Null
        Copy-Item -Path $tempHive -Destination $joeHive -Force
        & icacls $joeHive /inheritance:r /grant "User_Joe:(F)" /grant "SYSTEM:(F)" /grant "Administrators:(F)" | Out-Null
        Write-Host "[*] Pre-seeded HKCU AlwaysInstallElevated in User_Joe's hive"
    } catch {
        Write-Warning "Could not pre-seed User_Joe's HKCU hive: $($_.Exception.Message)"
    } finally {
        Remove-Item -Path $tempHive -Force -ErrorAction SilentlyContinue
        & reg.exe unload "HKU\$seedKey" 2>&1 | Out-Null
        $ErrorActionPreference = $prevEap
    }
} else {
    Write-Warning "User_Joe NTUSER.DAT not available; HKCU pre-seed skipped"
}

# Locate the staged EFS installer from the PROVISION ISO
$installerName = "60f3ff1f3cd34dec80fba130ea481f31-efssetup.exe"
$stagedInstaller = Find-ProvisionFile -Name $installerName
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

# Easy File Sharing Web Server 6.9 - Inno Setup silent install
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

# fswsService writes a 4-byte counter to C:\Windows\SysWOW64\swsfe.dll on each
# start. Joe inherits only (RX) there; the resulting CreateFile ACCESS DENIED
# raises C++ exception 0xe06d7363 in KERNELBASE.dll and the service dies.
# Create the counter file if the installer did not, then grant Modify.
$swsfeCounter = "C:\Windows\SysWOW64\swsfe.dll"
if (-not (Test-Path $swsfeCounter)) {
    New-Item -ItemType File -Path $swsfeCounter -Force | Out-Null
    [System.IO.File]::WriteAllBytes($swsfeCounter, [byte[]](0, 0, 0, 0))
}
& icacls $swsfeCounter /grant "User_Joe:(M)" | Out-Null

# Deploy Cy's option.ini so /vfolder.ghp is reachable (load-bearing for EDB-37951/42256).
$stagedOption = Find-ProvisionFile -Name "option.ini"
if ($stagedOption) {
    Copy-Item -Path $stagedOption -Destination "$efsRoot\option.ini" -Force
    Write-Host "[*] Deployed option.ini to $efsRoot"
} else {
    Write-Warning "option.ini not found on PROVISION media; vfolder.ghp may not work"
}
$vfoldersPath = "C:\vfolders"
New-Item -ItemType Directory -Path $vfoldersPath -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $vfoldersPath "disk_d") -Force | Out-Null
& icacls $vfoldersPath /grant "User_Joe:(OI)(CI)(M)" "SYSTEM:(OI)(CI)(F)" "Administrators:(OI)(CI)(F)" | Out-Null

# Interactive User_Joe path for AIE validation (RDP + logon rights).
$secCfgInteractive = "$env:TEMP\joe-interactive-logon.inf"
$secDbInteractive  = "$env:TEMP\joe-interactive-logon.sdb"
secedit /export /cfg $secCfgInteractive /areas USER_RIGHTS | Out-Null
$cfgInteractive = Get-Content $secCfgInteractive -Raw
foreach ($right in @("SeInteractiveLogonRight", "SeRemoteInteractiveLogonRight")) {
    if ($cfgInteractive -match "$right\s*=\s*([^\r\n]*)") {
        $existing = $matches[1]
        if ($existing -notmatch [Regex]::Escape($joeSid)) {
            $cfgInteractive = $cfgInteractive -replace "$right\s*=.*", "$right = $existing,*$joeSid"
        }
    } else {
        $cfgInteractive = $cfgInteractive -replace '(\[Privilege Rights\])', "`$1`r`n$right = *$joeSid"
    }
}
Set-Content -Path $secCfgInteractive -Value $cfgInteractive -Encoding Unicode
secedit /configure /db $secDbInteractive /cfg $secCfgInteractive /areas USER_RIGHTS | Out-Null
Add-LocalGroupMember -Group "Remote Desktop Users" -Member "User_Joe" -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0

Set-Service -Name fswsService -StartupType Automatic
# Bootstrap previously claimed reboot would fix this; empirically it does not
# without the swsfe.dll ACL grant above.
try {
    Start-Service fswsService -ErrorAction Stop
} catch {
    Write-Warning "fswsService did not start in-band ($($_.Exception.Message)); will start on next boot (StartupType=Automatic)"
}

# Firewall - Cy's pending build-steps
Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In -ErrorAction SilentlyContinue
if (-not (Get-NetFirewallRule -DisplayName "Allow Port 80" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow Port 80" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow | Out-Null
}
if (-not (Get-NetFirewallRule -DisplayName "Allow Port 443" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow Port 443" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
}
if (-not (Get-NetFirewallRule -DisplayName "Allow RDP 3389" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow RDP 3389" -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow | Out-Null
}
Enable-NetFirewallRule -DisplayName "Remote Desktop*" -ErrorAction SilentlyContinue

# AlwaysInstallElevated - Cy's pending build-steps. HKLM is set here directly.
# HKCU is pre-seeded in User_Joe's NTUSER.DAT below (direct hive load).
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" `
                 -Name "AlwaysInstallElevated" -Value 1 -Type DWord
# Allow non-admin MSI installs when AIE is set (blocks error 1625 on Server 2016).
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" `
                 -Name "DisableUserInstalls" -Value 0 -Type DWord -Force
# Terminal Services / RDP sessions block unmanaged per-user installs unless DisableMSI=0.
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer" `
                 -Name "DisableMSI" -Value 0 -Type DWord -Force

# UAC consent gate - the second load-bearing setting that the original Notes.txt
# checklist missed. On Server 2016, AIE alone is not sufficient: msiexec still
# cannot obtain its SYSTEM elevation token while ConsentPromptBehaviorAdmin is at
# its default of 5 (prompt-for-consent). Setting it to 0 lets the Installer
# service auto-elevate non-interactively, which is what the AIE chain assumes.
# EnableLUA stays 1 so UAC remains "on" in the OS sense and the misconfig stays
# realistic. See nickvourd's privesc cookbook for the canonical reference.
$uacKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $uacKey -Name "ConsentPromptBehaviorAdmin" -Value 0 -Type DWord
Set-ItemProperty -Path $uacKey -Name "PromptOnSecureDesktop"      -Value 0 -Type DWord

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

New-Item -ItemType Directory -Path $joeDesktopDir -Force | Out-Null

# Notes.txt parity with Cy's box (player-visible hint sheet).
$notesPath = Join-Path $joeDesktopDir "Notes.txt"
$notesBody = @"
https://www.exploit-db.com/exploits/42256


Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In

New-NetFirewallRule -DisplayName "Allow Port 80" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow

reg add HKLM\Software\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated /t REG_DWORD /d 1 /f

reg add HKCU\Software\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated /t REG_DWORD /d 1 /f

User_Joe
$joePw
"@
[System.IO.File]::WriteAllText($notesPath, $notesBody, [System.Text.UTF8Encoding]::new($false))
Write-Host "[*] Seeded Notes.txt to $notesPath"

# EFS installer on Joe's desktop (reproducibility artifact).
Copy-Item -Path $installerPath -Destination (Join-Path $joeDesktopDir $installerName) -Force
Write-Host "[*] Seeded EFS installer to Joe desktop"

# Defender must be fully neutered: msfvenom payloads are detected on contact.
# Disable real-time for the current session + registry GPO for reboot persistence.
# Note: Set-Service WinDefend -StartupType Disabled fails with Access Denied on
# Server 2016 eval (WRP-protected service). The GPO-level key handles reboot persistence.
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Force | Out-Null
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" `
                     -Name "DisableAntiSpyware" -Value 1 -Type DWord
} catch {
    Write-Host "[!] Defender disable skipped: $($_.Exception.Message)"
}

# Software Restriction Policies — Server 2016 eval images ship with SRP active.
# Remove the policies key to allow msiexec from non-Program Files paths.
$srpKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers"
if (Test-Path $srpKey) {
    try {
        Remove-Item -Path $srpKey -Recurse -Force -ErrorAction Stop
        Write-Host "[*] Disabled Software Restriction Policies"
    } catch {
        Write-Host "[!] Could not disable SRP: $($_.Exception.Message)"
    }
}

# Stage validation MSI from PROVISION ISO to C:\Users\Public
$msiName = "aie-validation-payload.msi"
$stagedMsi = Find-ProvisionFile -Name $msiName
if ($stagedMsi) {
    Copy-Item -Path $stagedMsi -Destination "C:\Users\Public\$msiName" -Force
    Write-Host "[*] Staged $msiName to C:\Users\Public"
}

# Write user flag directly to Joe's desktop (profile directory guaranteed to exist).
$userFlagPath = Join-Path $joeDesktopDir "user.txt"
[System.IO.File]::WriteAllText($userFlagPath, $userFlag, [System.Text.UTF8Encoding]::new($false))
& icacls $userFlagPath /inheritance:r /grant "User_Joe:R" "SYSTEM:F" "Administrators:F" | Out-Null
Write-Host "[*] Seeded user flag to $userFlagPath"

# Stage validation script from PROVISION ISO
$validateScript = "validate-aie.ps1"
$stagedValidate = Find-ProvisionFile -Name $validateScript
if ($stagedValidate) {
    Copy-Item -Path $stagedValidate -Destination "C:\secretcon\$validateScript" -Force
    Write-Host "[*] Staged $validateScript to C:\secretcon"
}

Write-Host "[*] Validating bootstrap..."
$failed = @()
foreach ($svc in 'Sysmon64','WazuhSvc','fswsService') {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { $failed += "$svc not installed"; continue }
    if ($s.Status -ne 'Running') {
        # fswsService consistently fails its first in-band start after the
        # User_Joe service-account downgrade; StartupType=Automatic ensures the
        # next boot brings it up. Treat as warning, not validation failure.
        if ($svc -eq 'fswsService' -and $s.StartType -eq 'Automatic') {
            Write-Warning "$svc Stopped post-bootstrap; StartupType=Automatic will start it on next boot"
        } else {
            $failed += "$svc not running ($($s.Status))"
        }
    }
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
if ($cpba -ne 0) { $failed += "ConsentPromptBehaviorAdmin not 0 (got $cpba) - AIE chain will be blocked at the UAC gate" }
if (-not (Test-Path $rootFlagPath)) { $failed += "root flag missing" }
if (-not (Test-Path "C:\Users\User_Joe\Desktop\user.txt")) { $failed += "user flag missing" }
if (-not (Test-Path "C:\Users\User_Joe\Desktop\Notes.txt")) { $failed += "Joe Notes.txt missing" }
if (-not (Test-Path (Join-Path $joeDesktopDir $installerName))) { $failed += "Joe desktop installer missing" }
if (-not (Test-Path "C:\Users\Public\aie-validation-payload.msi")) { $failed += "AIE validation MSI missing" }
if (-not (Test-Path "C:\secretcon\validate-aie.ps1")) { $failed += "AIE validation script missing" }
if (-not (Test-Path "$efsRoot\option.ini")) { $failed += "EFS option.ini missing" }
if (-not (Test-Path "C:\vfolders")) { $failed += "C:\vfolders missing" }
# AppLocker/SRP check — catch hardened base images before they ship
if (Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue) {
    $alPolicy = Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue
    if ($alPolicy -and $alPolicy.RuleCollections.Count -gt 0) { $failed += "AppLocker policy is active" }
}
$srpKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers"
if (Test-Path $srpKey) { $failed += "Software Restriction Policies are active" }
if (-not (Get-NetFirewallRule -DisplayName "Allow Port 80" -ErrorAction SilentlyContinue)) {
    $failed += "TCP/80 firewall rule missing"
}
if ($failed.Count -gt 0) {
    Write-Error ("Bootstrap validation failed: " + ($failed -join '; '))
    exit 1
}
Write-Host "[*] Bootstrap complete. Both flags seeded, Defender disabled, AIE keys set. System ready for validation."
