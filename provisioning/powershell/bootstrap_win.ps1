# SecretCon 2026 — Win11 EWS Bootstrap
# Runs during Packer provisioning (both Proxmox and AWS)

$secretconLib = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root "SecretCon.Bootstrap.psm1" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $secretconLib) {
    $secretconLib = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib\SecretCon.Bootstrap.psm1"
}
Import-Module $secretconLib -Force -ErrorAction Stop

Write-Host "[*] Starting EWS bootstrap..."

$userFlag = Get-SecretConEnvDefault -Name "SECRETCON_USER_FLAG" -Default "crit-low-priv-patrick"
$rootFlag = Get-SecretConEnvDefault -Name "SECRETCON_ROOT_FLAG" -Default "crit-root-system-privs"
Write-Host "[*] User flag length: $($userFlag.Length); root flag length: $($rootFlag.Length)"

# Long Paths
Set-ItemProperty `
  -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name 'LongPathsEnabled' -Value 1

# .NET 3.5 — skipped (no offline source on this image; not needed for current CTF stack)

# Static IP — deferred to per-clone provisioning (would kill the build SSH session if applied here)

Install-SecretConSysmon
Install-SecretConWazuhAgent -Manager (Get-SecretConEnvDefault -Name "WAZUH_MANAGER" -Default "192.168.61.10") -Group "ews"

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

# Raise TightVNC's per-IP blacklist so credential-stuffing the SecLists default
# VNC list (~40 entries) does not hit the 5-attempt default lockout mid-run.
Set-ItemProperty -Path "HKLM:\SOFTWARE\TightVNC\Server" -Name "BlacklistThreshold" -Value 100 -Type DWord
Set-ItemProperty -Path "HKLM:\SOFTWARE\TightVNC\Server" -Name "BlacklistTimeout"   -Value 0   -Type DWord
Restart-Service tvnserver

# User flag artifact. A logon task avoids pre-creating Patrick's profile path.
$userFlagSeeder = "C:\secretcon\seed-user-flag.ps1"
$userFlagB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userFlag))
@"
`$desktop = [Environment]::GetFolderPath("Desktop")
`$flag = Join-Path `$desktop "flag.txt"
`$value = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("$userFlagB64"))
[System.IO.File]::WriteAllText(`$flag, `$value, [System.Text.UTF8Encoding]::new(`$false))
icacls `$flag /inheritance:r /grant "patrick:R" "Administrators:F" "SYSTEM:F" | Out-Null
"@ | Set-Content -Encoding utf8 $userFlagSeeder
Register-SecretConLogonSeederTask -TaskName "SecretConUserFlag" -ScriptPath $userFlagSeeder -User "patrick"

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
$rootFlagPath = Join-Path $administratorDesktop "root.txt"
New-Item -ItemType Directory -Path $administratorDesktop -Force | Out-Null
[System.IO.File]::WriteAllText(
    $rootFlagPath,
    $rootFlag,
    [System.Text.UTF8Encoding]::new($false)
)
icacls $rootFlagPath /inheritance:r /grant "SYSTEM:F" "Administrators:F" | Out-Null

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
if (-not (Test-Path $rootFlagPath)) {
    $failed += "root flag missing"
} else {
    $writtenRoot = [System.IO.File]::ReadAllText($rootFlagPath)
    if ($writtenRoot -ne $rootFlag) {
        $failed += "root flag contents do not match SECRETCON_ROOT_FLAG (got length $($writtenRoot.Length), expected $($rootFlag.Length))"
    }
}
if (-not (Get-ScheduledTask -TaskName "SecretConUserFlag" -ErrorAction SilentlyContinue)) { $failed += "user flag logon task missing" }
if ($failed.Count -gt 0) {
    Write-Error ("Bootstrap validation failed: " + ($failed -join '; '))
    exit 1
}
Write-Host "[*] Bootstrap complete."
