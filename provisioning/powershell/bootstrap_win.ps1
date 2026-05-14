# SecretCon 2026 — Win11 EWS Bootstrap
# Runs during Packer provisioning (both Proxmox and AWS)

Write-Host "[*] Starting EWS bootstrap..."

# Long Paths
Set-ItemProperty `
  -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name 'LongPathsEnabled' -Value 1

# .NET 3.5 — skipped (no offline source on this image; not needed for current CTF stack)

# Static IP — deferred to per-clone provisioning (would kill the build SSH session if applied here)

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
New-LocalUser -Name "patrick" -Password $pw -FullName "Patrick" -Description "EWS Operator"
Add-LocalGroupMember -Group "Users" -Member "patrick"
Remove-LocalGroupMember -Group "Administrators" -Member "patrick" -ErrorAction SilentlyContinue

# VNC foothold: weak default password from SecLists' VNC defaults list.
$tightVncVersion = "2.8.87"
$tightVncFile = "tightvnc-$tightVncVersion-gpl-setup-64bit.msi"
$tightVncMsi = Join-Path "C:\secretcon" $tightVncFile
$stagedTightVnc = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object {
        Join-Path $_.Root $tightVncFile
        Join-Path $_.Root "tightvnc\$tightVncFile"
    } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if ($stagedTightVnc) {
    Copy-Item -Path $stagedTightVnc -Destination $tightVncMsi -Force
} else {
    Invoke-WebRequest `
      -Uri "https://www.tightvnc.com/download/$tightVncVersion/$tightVncFile" `
      -OutFile $tightVncMsi `
      -UseBasicParsing
}

$tightVncArgs = @(
    "/i `"$tightVncMsi`"",
    "/quiet",
    "/norestart",
    "ADDLOCAL=Server",
    "SERVER_REGISTER_AS_SERVICE=1",
    "SERVER_ADD_FIREWALL_EXCEPTION=1",
    "SET_USEVNCAUTHENTICATION=1",
    "VALUE_OF_USEVNCAUTHENTICATION=1",
    "SET_PASSWORD=1",
    "VALUE_OF_PASSWORD=FELDTECH_VNC",
    "SET_USECONTROLAUTHENTICATION=1",
    "VALUE_OF_USECONTROLAUTHENTICATION=1",
    "SET_CONTROLPASSWORD=1",
    "VALUE_OF_CONTROLPASSWORD=FELDTECH_VNC"
) -join " "
Start-Process msiexec.exe -ArgumentList $tightVncArgs -Wait
if (-not (Get-NetFirewallRule -Name "SecretCon-TightVNC-In-TCP" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
      -Name "SecretCon-TightVNC-In-TCP" `
      -DisplayName "SecretCon TightVNC Server" `
      -Enabled True `
      -Direction Inbound `
      -Protocol TCP `
      -Action Allow `
      -LocalPort 5900 | Out-Null
}
Set-Service -Name tvnserver -StartupType Automatic
Start-Service tvnserver

# User flag artifact. A logon task avoids pre-creating Patrick's profile path.
$userFlagSeeder = "C:\secretcon\seed-user-flag.ps1"
@'
$desktop = [Environment]::GetFolderPath("Desktop")
$flag = Join-Path $desktop "flag.txt"
"crit-low-priv-patrick" | Set-Content -Encoding utf8 $flag
icacls $flag /inheritance:r /grant "patrick:R" "Administrators:F" "SYSTEM:F" | Out-Null
'@ | Set-Content -Encoding utf8 $userFlagSeeder
$flagTaskAction = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$userFlagSeeder`""
$flagTaskTrigger = New-ScheduledTaskTrigger -AtLogOn -User "patrick"
$flagTaskPrincipal = New-ScheduledTaskPrincipal -UserId "patrick" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask `
  -TaskName "SecretConUserFlag" `
  -Action $flagTaskAction `
  -Trigger $flagTaskTrigger `
  -Principal $flagTaskPrincipal `
  -Force | Out-Null

# Unquoted service-path privilege escalation target
$serviceRoot = "C:\Program Files\SecretCon"
$serviceDir = Join-Path $serviceRoot "EWS Sync"
$serviceExe = Join-Path $serviceDir "ews_sync.exe"
New-Item -ItemType Directory -Path $serviceDir -Force | Out-Null

$serviceSource = @"
using System;
using System.ServiceProcess;
using System.Threading;

public class EwsSyncService : ServiceBase {
    private readonly ManualResetEvent stopSignal = new ManualResetEvent(false);
    private Thread worker;

    public EwsSyncService() {
        ServiceName = "SecretConEwsSync";
        CanStop = true;
        CanPauseAndContinue = false;
        AutoLog = false;
    }

    protected override void OnStart(string[] args) {
        worker = new Thread(() => stopSignal.WaitOne());
        worker.IsBackground = true;
        worker.Start();
    }

    protected override void OnStop() {
        stopSignal.Set();
    }

    public static void Main() {
        ServiceBase.Run(new EwsSyncService());
    }
}
"@

Add-Type `
  -TypeDefinition $serviceSource `
  -Language CSharp `
  -OutputAssembly $serviceExe `
  -OutputType ConsoleApplication `
  -ReferencedAssemblies @('System.dll', 'System.ServiceProcess.dll') `
  -ErrorAction Stop

icacls $serviceExe /inheritance:r /grant "SYSTEM:F" "Administrators:F" | Out-Null
icacls $serviceDir /inheritance:r /grant "SYSTEM:(OI)(CI)(F)" "Administrators:(OI)(CI)(F)" | Out-Null
icacls $serviceRoot /grant "BUILTIN\Users:(OI)(CI)(M)" | Out-Null

& sc.exe create SecretConEwsSync binPath= $serviceExe start= auto obj= LocalSystem DisplayName= "SecretCon EWS Sync" | Out-Null
& sc.exe description SecretConEwsSync "Synchronizes engineering workstation telemetry with the plant historian" | Out-Null
Start-Service SecretConEwsSync

# Root flag artifact
$administratorDesktop = "C:\Users\Administrator\Desktop"
$rootFlag = Join-Path $administratorDesktop "root.txt"
New-Item -ItemType Directory -Path $administratorDesktop -Force | Out-Null
"crit-root-system-privs" | Set-Content -Encoding utf8 $rootFlag
icacls $rootFlag /inheritance:r /grant "SYSTEM:F" "Administrators:F" | Out-Null

# Keep Defender useful for telemetry while avoiding lab-path interference.
try {
    Add-MpPreference -ExclusionPath $serviceRoot -ErrorAction Stop
    Add-MpPreference -ExclusionPath "C:\Program Files\TightVNC" -ErrorAction Stop
} catch {
    Write-Host "[!] Defender exclusions skipped: $($_.Exception.Message)"
}

# Final image should present patrick's desktop over VNC after reboot.
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogon -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path $winlogon -Name "DefaultUserName" -Value "patrick"
Set-ItemProperty -Path $winlogon -Name "DefaultPassword" -Value "Changeme123!"
Set-ItemProperty -Path $winlogon -Name "DefaultDomainName" -Value $env:COMPUTERNAME
Set-ItemProperty -Path $winlogon -Name "ForceAutoLogon" -Value "1"

Write-Host "[*] Validating bootstrap..."
$failed = @()
foreach ($svc in 'Sysmon64','WazuhSvc','tvnserver','SecretConEwsSync') {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { $failed += "$svc not installed" }
    elseif ($s.Status -ne 'Running') { $failed += "$svc not running ($($s.Status))" }
}
$imagePath = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\SecretConEwsSync' -Name ImagePath).ImagePath
if ($imagePath -match '^".*"$') { $failed += "SecretConEwsSync ImagePath is quoted" }
if ($imagePath -notmatch '\s') { $failed += "SecretConEwsSync ImagePath does not contain spaces" }
$serviceAcl = icacls $serviceRoot
if (-not ($serviceAcl -match 'BUILTIN\\Users:.*\(M\)')) { $failed += "$serviceRoot is not modifiable by BUILTIN\Users" }
if (-not (Test-Path $rootFlag)) { $failed += "root flag missing" }
if (-not (Get-ScheduledTask -TaskName "SecretConUserFlag" -ErrorAction SilentlyContinue)) { $failed += "user flag logon task missing" }
if ($failed.Count -gt 0) {
    Write-Error ("Bootstrap validation failed: " + ($failed -join '; '))
    exit 1
}
Write-Host "[*] Bootstrap complete."
