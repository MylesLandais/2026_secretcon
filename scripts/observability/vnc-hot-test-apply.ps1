# Hot-test registry converge (mirrors planned Ansible service_config.yml).
$ErrorActionPreference = 'Stop'
$base = 'HKLM:\SOFTWARE\TightVNC\Server'
$protected = @(
    'BlacklistThreshold', 'BlacklistTimeout', 'SecurityType', 'PreferAuth',
    'UseVncAuthentication', 'UseControlAuthentication', 'Password',
    'ControlPassword', 'LogLevel', 'LogDir', 'PSPath', 'PSParentPath',
    'PSChildName', 'PSDrive', 'PSProvider'
)

Stop-Service tvnserver -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

$props = Get-ItemProperty -Path $base -ErrorAction SilentlyContinue
if ($props) {
    foreach ($name in $props.PSObject.Properties.Name) {
        if ($protected -contains $name) { continue }
        if ($name -match '^\d+\.\d+\.\d+\.\d+$' -or
            $name -match '^(FailedAuth|RejectedAuth|BlockedClient)') {
            Write-Output "Removing $name"
            Remove-ItemProperty -Path $base -Name $name -Force -ErrorAction SilentlyContinue
        }
    }
}

& reg.exe add HKLM\SOFTWARE\TightVNC\Server /v SecurityType /t REG_DWORD /d 2 /f
& reg.exe add HKLM\SOFTWARE\TightVNC\Server /v PreferAuth /t REG_DWORD /d 2 /f
& reg.exe add HKLM\SOFTWARE\TightVNC\Server /v BlacklistThreshold /t REG_DWORD /d 10000 /f
& reg.exe add HKLM\SOFTWARE\TightVNC\Server /v BlacklistTimeout /t REG_DWORD /d 0 /f

Start-Service tvnserver
Start-Sleep -Seconds 2
Get-Service tvnserver | Format-List *
Write-Output '--- reg query ---'
& reg.exe query HKLM\SOFTWARE\TightVNC\Server
