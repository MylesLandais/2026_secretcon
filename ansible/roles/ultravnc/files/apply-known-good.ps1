# SecretCon EWS — known-good UltraVNC apply (hot patch + Ansible converge).
# Single source of truth for admin/poll ini flags, password, listener, watchdog.
param(
    [Parameter(Mandatory = $true)]
    [string]$Password,
    [string]$RegBlobHex = '',
    [int]$Port = 5900,
    [switch]$SkipRegistry
)

$ErrorActionPreference = 'Stop'

$uvncDir = 'C:\Program Files\uvnc bvba\UltraVNC'
$ini = Join-Path $uvncDir 'ultravnc.ini'
$staging = 'C:\secretcon'
$taskName = 'SecretCon-UltraVNC-Run'
$watchdog = Join-Path $staging 'start-ultravnc-watchdog.ps1'
$setpasswdArg = $Password.Substring(0, [Math]::Min(8, $Password.Length))

if (-not (Test-Path -LiteralPath $uvncDir)) {
    throw "UltraVNC not installed at $uvncDir (install Chocolatey package first)"
}

Stop-Service uvnc_service -Force -ErrorAction SilentlyContinue
Set-Service uvnc_service -StartupType Disabled -ErrorAction SilentlyContinue
Get-Process winvnc -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

Set-Location -LiteralPath $uvncDir
cmd /c "setpasswd.exe $setpasswdArg" | Out-Null

$passwdLine = (Select-String -Path $ini -Pattern '^passwd=(.+)$').Matches.Groups[1].Value.Trim()

$knownAdmin = @(
    '[admin]',
    'UseRegistry=0',
    'MSLogonRequired=0',
    'NewMSLogon=0',
    'Secure=0',
    'AuthRequired=1',
    'SocketConnect=1',
    "PortNumber=$Port",
    'AutoPortSelect=0',
    'HTTPConnect=0',
    'AllowLoopback=1',
    'LoopbackOnly=0',
    'QueryAccept=1',
    'QueryIfNoLogon=0',
    'QuerySetting=2',
    'InputsEnabled=1',
    'DisableTrayIcon=1',
    'AllowShutdown=0',
    'AllowProperties=0',
    'DebugMode=0',
    'DebugLevel=5',
    'path=C:\ProgramData\UltraVNC',
    'RemoveWallpaper=1',
    'RemoveAero=1',
    '',
    '[poll]',
    'TurboMode=1',
    'PollFullScreen=1',
    'EnableHook=1',
    'EnableDriver=0',
    ''
)

$ultraBlock = @(
    '[ultravnc]',
    "passwd=$passwdLine",
    'passwd2=',
    ''
)

$iniBody = ($ultraBlock + $knownAdmin) -join "`r`n"
Set-Content -LiteralPath $ini -Value $iniBody -Encoding ASCII

New-Item -ItemType Directory -Force -Path 'C:\ProgramData\UltraVNC' | Out-Null

if ($RegBlobHex -and -not $SkipRegistry) {
    cmd /c "reg add HKLM\SOFTWARE\ORL\WinVNC3 /v Password /t REG_BINARY /d $RegBlobHex /f" | Out-Null
}

if (-not (Test-Path -LiteralPath $watchdog)) {
    throw "Missing watchdog script: $watchdog (stage via Ansible or hot-patch copy first)"
}

$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $task) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$watchdog`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

Start-Process -FilePath (Join-Path $uvncDir 'winvnc.exe') -ArgumentList '-run'

$deadline = (Get-Date).AddSeconds(12)
$listening = $false
while ((Get-Date) -lt $deadline) {
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        $listening = $true
        break
    }
    Start-Sleep -Milliseconds 400
}

Write-Output "passwd=$passwdLine"
Write-Output "listening=$listening"
Write-Output "port=$Port"
if (-not $listening) { exit 1 }
