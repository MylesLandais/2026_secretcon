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
        [string]$ExpectedSha = $(if ($env:SYSMON_CONFIG_SHA256) { $env:SYSMON_CONFIG_SHA256 } else { "055febc600e6d7448cdf3812307275912927a62b1f94d0d933b64b294bc87162" }),
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
    'Register-SecretConLogonSeederTask'
)
