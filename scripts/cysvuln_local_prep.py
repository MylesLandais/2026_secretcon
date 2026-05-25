#!/usr/bin/env python3
"""WinRM prep steps for local CysVuln QEMU validation."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def session(host: str, port: int, password: str):
    try:
        import winrm
    except ImportError as exc:
        raise SystemExit("pywinrm required (nix develop)") from exc
    return winrm.Session(
        f"http://{host}:{port}/wsman",
        auth=("Administrator", password),
        transport="ntlm",
    )


def run_ps(s, script: str) -> None:
    r = s.run_ps(script)
    out = r.std_out.decode(errors="replace")
    if out.strip():
        print(out.rstrip())
    if r.status_code != 0:
        err = r.std_err.decode(errors="replace")
        if err.strip():
            print(err, file=sys.stderr)
        raise SystemExit(r.status_code)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", required=True)
    p.add_argument("--port", type=int, default=15985)
    p.add_argument("--admin-password", default="PizzaMan123!")
    p.add_argument("--user-flag", default="cysvuln-user-flag-placeholder")
    p.add_argument("--serve-port", type=int, default=8877)
    args = p.parse_args()

    s = session(args.target, args.port, args.admin_password)
    base = f"http://10.0.2.2:{args.serve_port}"

    run_ps(
        s,
        f"""
$base = '{base}'
$optionPath = 'C:\\EFS Software\\Easy File Sharing Web Server\\option.ini'
$psexecPath = 'C:\\Users\\Public\\PsExec.exe'
Invoke-WebRequest -Uri "$base/option.ini" -OutFile $optionPath -UseBasicParsing
Invoke-WebRequest -Uri "$base/PsExec.exe" -OutFile $psexecPath -UseBasicParsing
Invoke-WebRequest -Uri "$base/validate-aie.ps1" -OutFile 'C:\\secretcon\\validate-aie.ps1' -UseBasicParsing
Invoke-WebRequest -Uri "$base/aie-validation-payload.msi" -OutFile 'C:\\Users\\Public\\aie-validation-payload.msi' -UseBasicParsing
@'
@echo off
msiexec /quiet /norestart /i C:\\Users\\Public\\aie-validation-payload.msi /l*v C:\\Users\\Public\\aie-joe-validation.log
'@ | Set-Content -Path 'C:\\Users\\Public\\aie-run.cmd' -Encoding ASCII
Write-Host "[+] option.ini -> $optionPath ($((Get-Item $optionPath).Length) bytes)"
Write-Host "[+] PsExec.exe -> $psexecPath ($((Get-Item $psexecPath).Length) bytes)"
Write-Host "[+] validate-aie.ps1 -> C:\\secretcon\\validate-aie.ps1"
Write-Host "[+] MSI -> C:\\Users\\Public\\aie-validation-payload.msi ($((Get-Item 'C:\\Users\\Public\\aie-validation-payload.msi').Length) bytes)"
Write-Host "[+] aie-run.cmd -> C:\\Users\\Public\\aie-run.cmd"
""",
    )

    run_ps(
        s,
        """
$swsfe = 'C:\\Windows\\SysWOW64\\swsfe.dll'
if (-not (Test-Path $swsfe)) {
  New-Item -ItemType File -Path $swsfe -Force | Out-Null
  [IO.File]::WriteAllBytes($swsfe, [byte[]](0,0,0,0))
}
icacls $swsfe /grant 'User_Joe:(M)' | Out-Null
New-Item -ItemType Directory -Path 'C:\\vfolders' -Force | Out-Null
New-Item -ItemType Directory -Path 'C:\\vfolders\\disk_d' -Force | Out-Null
icacls 'C:\\vfolders' /grant 'User_Joe:(OI)(CI)(M)' 'SYSTEM:(OI)(CI)(F)' 'Administrators:(OI)(CI)(F)' | Out-Null
""",
    )

    run_ps(
        s,
        """
$instPol = 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Installer'
New-Item -Path $instPol -Force | Out-Null
Set-ItemProperty -Path $instPol -Name 'AlwaysInstallElevated' -Value 1 -Type DWord
Set-ItemProperty -Path $instPol -Name 'DisableUserInstalls' -Value 0 -Type DWord -Force
Set-ItemProperty -Path $instPol -Name 'DisableMSI' -Value 0 -Type DWord -Force
Write-Host '[+] AIE HKLM + DisableUserInstalls=0 + DisableMSI=0'
""",
    )

    run_ps(
        s,
        """
$joeSid = (New-Object Security.Principal.NTAccount('User_Joe')).Translate([Security.Principal.SecurityIdentifier]).Value
$secCfg = "$env:TEMP\\joe-interactive-logon.inf"
$secDb  = "$env:TEMP\\joe-interactive-logon.sdb"
secedit /export /cfg $secCfg /areas USER_RIGHTS | Out-Null
$cfgText = Get-Content $secCfg -Raw
foreach ($right in @('SeInteractiveLogonRight', 'SeRemoteInteractiveLogonRight')) {
  if ($cfgText -match ($right + '\\s*=\\s*([^\\r\\n]*)')) {
    $existing = $matches[1]
    if ($existing -notmatch [Regex]::Escape($joeSid)) {
      $cfgText = $cfgText -replace ($right + '\\s*=.*'), ($right + ' = ' + $existing + ',*' + $joeSid)
    }
  } else {
    $cfgText = $cfgText -replace '(\\[Privilege Rights\\])', ('$1' + [Environment]::NewLine + $right + ' = *' + $joeSid)
  }
}
Set-Content -Path $secCfg -Value $cfgText -Encoding Unicode
secedit /configure /db $secDb /cfg $secCfg /areas USER_RIGHTS | Out-Null
Add-LocalGroupMember -Group 'Remote Desktop Users' -Member 'User_Joe' -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server' -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayName 'Remote Desktop*' -ErrorAction SilentlyContinue
if (-not (Get-NetFirewallRule -DisplayName 'Allow RDP 3389' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName 'Allow RDP 3389' -Direction Inbound -Protocol TCP -LocalPort 3389 -Action Allow | Out-Null
}
Write-Host '[+] User_Joe interactive logon + RDP enabled'
""",
    )

    run_ps(
        s,
        """
Get-Process fsws,fswsService -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
sc.exe stop fswsService | Out-Null
Start-Sleep 2
sc.exe start fswsService | Out-Null
Start-Sleep 3
Get-Service fswsService | Select-Object Status, StartType
""",
    )

    user_flag = args.user_flag.replace("'", "''")
    run_ps(
        s,
        f"""
$joeSid = (New-Object Security.Principal.NTAccount('User_Joe')).Translate([Security.Principal.SecurityIdentifier]).Value
$desk = 'C:\\Users\\User_Joe\\Desktop'
New-Item -ItemType Directory -Path $desk -Force | Out-Null
$userFlag = Join-Path $desk 'user.txt'
if (-not (Test-Path $userFlag)) {{
  [IO.File]::WriteAllText($userFlag, '{user_flag}', [Text.UTF8Encoding]::new($false))
  icacls $userFlag /inheritance:r /grant 'User_Joe:R' 'SYSTEM:F' 'Administrators:F' | Out-Null
}}
$hive = 'C:\\Users\\User_Joe\\NTUSER.DAT'
if (Test-Path $hive) {{
  reg load ('HKU\\' + $joeSid) $hive | Out-Null
  New-Item -Path ('Registry::HKU\\' + $joeSid + '\\SOFTWARE\\Policies\\Microsoft\\Windows\\Installer') -Force | Out-Null
  Set-ItemProperty -Path ('Registry::HKU\\' + $joeSid + '\\SOFTWARE\\Policies\\Microsoft\\Windows\\Installer') -Name AlwaysInstallElevated -Value 1 -Type DWord
  reg unload ('HKU\\' + $joeSid) | Out-Null
}}
Write-Host '[*] Preflight:'
Write-Host '  option.ini:' (Test-Path 'C:\\EFS Software\\Easy File Sharing Web Server\\option.ini')
Write-Host '  vfolders:' (Test-Path 'C:\\vfolders')
Write-Host '  PsExec:' (Test-Path 'C:\\Users\\Public\\PsExec.exe')
Test-Path $userFlag
""",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
