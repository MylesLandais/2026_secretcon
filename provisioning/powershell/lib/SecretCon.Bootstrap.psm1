# SecretCon shared Packer bootstrap helpers (Sysmon, Wazuh, PROVISION ISO scan, logon tasks).
# Staged on the PROVISION CD; dot-source from bootstrap_*.ps1 during packer provision.

function Get-SecretConEnvDefault {
    param(
        [string]$Name,
        [string]$Default
    )
    $val = [Environment]::GetEnvironmentVariable($Name)
    if ($val) { return $val }
    return $Default
}

function Find-ProvisionFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    Get-PSDrive -PSProvider FileSystem |
        ForEach-Object { Join-Path $_.Root $Name } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

function Install-SecretConSysmon {
    param(
        [string]$ConfigName = "sysmonconfig.xml",
        [string]$ExpectedSha = $(if ($env:SYSMON_CONFIG_SHA256) { $env:SYSMON_CONFIG_SHA256 } else { "3913586d252d9a32319feb33e3715d3160a29476c480a807fd5a7992136504b4" }),
        [string]$InstallDir = "C:\secretcon"
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    $staged = Find-ProvisionFile -Name $ConfigName
    if (-not $staged) {
        throw "Sysmon config $ConfigName not found on any mounted drive (PROVISION ISO missing it?)"
    }
    $dest = Join-Path $InstallDir "sysmon-config.xml"
    Copy-Item -Path $staged -Destination $dest -Force
    $actual = (Get-FileHash -Algorithm SHA256 -Path $dest).Hash.ToLower()
    if ($actual -ne $ExpectedSha.ToLower()) {
        throw "Sysmon config hash mismatch: expected $ExpectedSha, got $actual"
    }

    $zip = "$env:TEMP\Sysmon.zip"
    Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath "$env:TEMP\Sysmon" -Force
    & "$env:TEMP\Sysmon\Sysmon64.exe" -accepteula -i $dest
}

function Install-SecretConWazuhAgent {
    param(
        [string]$Manager = $(Get-SecretConEnvDefault -Name "WAZUH_MANAGER" -Default "192.168.61.10"),
        [string]$Version = $(Get-SecretConEnvDefault -Name "WAZUH_AGENT_VERSION" -Default "4.14.5"),
        [string]$Group = "ews",
        [switch]$EnrollmentOptional
    )
    $msi = "C:\wazuh-agent-$Version-1.msi"
    Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-$Version-1.msi" -OutFile $msi
    Start-Process msiexec.exe -ArgumentList "/i $msi /q WAZUH_MANAGER=$Manager WAZUH_AGENT_GROUP=$Group" -Wait

    # Opt this agent in to manager-pushed <command> localfiles. Wazuh
    # rejects them by default (it logs "Remote commands are not accepted
    # from the manager") because they are an RCE primitive if the manager
    # is compromised. The opt-in MUST live in local_internal_options.conf
    # on the agent itself — it cannot be pushed via shared agent.conf for
    # exactly that reason. We need it for the tvnserver.log tailer (see
    # shared/ews/agent.conf and rule 100801) since TightVNC's exclusive
    # file lock prevents the built-in logcollector from tailing the log.
    $localOpts = "C:\Program Files (x86)\ossec-agent\local_internal_options.conf"
    if (-not (Test-Path -LiteralPath $localOpts)) {
        Set-Content -LiteralPath $localOpts -Value "" -Encoding ASCII
    }
    $existing = Get-Content -LiteralPath $localOpts -ErrorAction SilentlyContinue
    if ($existing -notmatch '^\s*logcollector\.remote_commands\s*=\s*1') {
        Add-Content -LiteralPath $localOpts -Value "logcollector.remote_commands=1"
    }

    Start-Service WazuhSvc

    $ossecLog = "C:\Program Files (x86)\ossec-agent\ossec.log"
    $deadline = (Get-Date).AddSeconds(60)
    $enrolled = $false
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $ossecLog) -and (Select-String -Path $ossecLog -Pattern 'Connected to the server' -SimpleMatch -Quiet)) {
            $enrolled = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $enrolled) {
        if ($EnrollmentOptional) {
            Write-Warning "Wazuh agent did not enroll with $Manager within 60s; continuing (EnrollmentOptional)"
        } else {
            Write-Error "Wazuh agent did not log 'Connected to the server' within 60s; check manager $Manager reachability"
            exit 1
        }
    } else {
        Write-Host "[*] Wazuh agent connected to $Manager"
    }
}

function Set-SecretConUpdatePromptSuppression {
    <#
    Machine + service scope: suppress Server Manager and Windows Update overlays.
    Matches provisioning/proxmox/autounattend.xml specialize pass (CysVuln recon cyv-005).
    #>
    $machineReg = @(
        @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU', 'NoAutoUpdate', 'REG_DWORD', '1'),
        @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'DoNotConnectToWindowsUpdateInternetLocations', 'REG_DWORD', '1'),
        @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate', 'SetDisableUXWUAccess', 'REG_DWORD', '1'),
        @('HKLM\SOFTWARE\Microsoft\ServerManager', 'DoNotOpenServerManagerAtLogon', 'REG_DWORD', '1')
    )
    foreach ($entry in $machineReg) {
        & reg.exe add $entry[0] /v $entry[1] /t $entry[2] /d $entry[3] /f | Out-Null
    }
    foreach ($svc in @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'ServerManager', 'MusNotification', 'MusNotificationUx' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host '[*] Windows Update / Server Manager prompts suppressed (machine scope)'
}

function Register-SecretConLogonSeederTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$User,
        [ValidateSet("Limited", "Highest")]
        [string]$RunLevel = "Limited"
    )
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $RunLevel
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Force | Out-Null
}

Export-ModuleMember -Function @(
    'Get-SecretConEnvDefault',
    'Find-ProvisionFile',
    'Install-SecretConSysmon',
    'Install-SecretConWazuhAgent',
    'Set-SecretConUpdatePromptSuppression',
    'Register-SecretConLogonSeederTask'
)
