#!/usr/bin/env python3
"""
AlwaysInstallElevated indicator audit over WinRM.

Queries the registry keys and policy values that signal an exploitable AIE
configuration on a Windows target. Emits JSON or a human summary; exit code
reflects whether the documented misconfiguration response is present.

Indicators checked:
  HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\Installer\\AlwaysInstallElevated
  HKCU\\SOFTWARE\\Policies\\Microsoft\\Windows\\Installer\\AlwaysInstallElevated
  HKLM\\...\\Policies\\System\\ConsentPromptBehaviorAdmin
  HKLM\\...\\Policies\\System\\PromptOnSecureDesktop
  msiexec.exe presence + version
  Whether the connecting account can write to %TEMP%
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass

import winrm


PS = r"""
$out = [ordered]@{}
function Get-RegInt($path, $name) {
    try { return (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name }
    catch { return $null }
}
$out.aie_hklm = Get-RegInt 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' 'AlwaysInstallElevated'
$out.aie_hkcu = Get-RegInt 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Installer' 'AlwaysInstallElevated'
$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$out.consent_prompt_behavior_admin = Get-RegInt $uacKey 'ConsentPromptBehaviorAdmin'
$out.prompt_on_secure_desktop = Get-RegInt $uacKey 'PromptOnSecureDesktop'
$msi = Get-Command msiexec.exe -ErrorAction SilentlyContinue
$out.msiexec_path = if ($msi) { $msi.Source } else { $null }
$out.msiexec_version = if ($msi) { (Get-Item $msi.Source).VersionInfo.FileVersion } else { $null }
$temp = [Environment]::GetEnvironmentVariable('TEMP')
$probe = Join-Path $temp ('aie_audit_probe_' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    Set-Content -Path $probe -Value 'probe' -ErrorAction Stop
    Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
    $out.temp_writable = $true
    $out.temp_dir = $temp
} catch {
    $out.temp_writable = $false
    $out.temp_dir = $temp
}
$out.identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$out | ConvertTo-Json -Compress
"""

PS_HIVE = r"""
param([string]$ProfileUser)
$out = [ordered]@{}
function Get-RegInt($path, $name) {
    try { return (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name }
    catch { return $null }
}
$out.aie_hklm = Get-RegInt 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer' 'AlwaysInstallElevated'
$out.aie_hkcu = $null
$out.aie_hkcu_profile = $null
$uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$out.consent_prompt_behavior_admin = Get-RegInt $uacKey 'ConsentPromptBehaviorAdmin'
$out.prompt_on_secure_desktop = Get-RegInt $uacKey 'PromptOnSecureDesktop'
$msi = Get-Command msiexec.exe -ErrorAction SilentlyContinue
$out.msiexec_path = if ($msi) { $msi.Source } else { $null }
$out.msiexec_version = if ($msi) { (Get-Item $msi.Source).VersionInfo.FileVersion } else { $null }
$out.temp_writable = $true
$out.temp_dir = $env:TEMP
$out.identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$sid = (New-Object System.Security.Principal.NTAccount($ProfileUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$hive = "C:\Users\$ProfileUser\NTUSER.DAT"
if (Test-Path $hive) {
    reg load "HKU\$sid" $hive | Out-Null
    $out.aie_hkcu_profile = Get-RegInt "Registry::HKU\$sid\SOFTWARE\Policies\Microsoft\Windows\Installer" 'AlwaysInstallElevated'
    reg unload "HKU\$sid" | Out-Null
}
$out | ConvertTo-Json -Compress
"""


@dataclass
class AieReport:
    target: str
    user: str
    identity: str | None
    aie_hklm: int | None
    aie_hkcu: int | None
    consent_prompt_behavior_admin: int | None
    prompt_on_secure_desktop: int | None
    msiexec_path: str | None
    msiexec_version: str | None
    temp_dir: str | None
    temp_writable: bool
    chain_response_expected: bool
    aie_hkcu_profile: int | None = None

    @property
    def summary(self) -> str:
        ok = lambda b: "PASS" if b else "FAIL"
        hkcu_effective = self.aie_hkcu if self.aie_hkcu is not None else self.aie_hkcu_profile
        lines = [
            f"target  : {self.target}",
            f"identity: {self.identity}",
            f"  AIE HKLM = {self.aie_hklm}                {ok(self.aie_hklm == 1)}",
            f"  AIE HKCU = {hkcu_effective}                {ok(hkcu_effective == 1)}",
        ]
        if self.aie_hkcu_profile is not None and self.aie_hkcu != self.aie_hkcu_profile:
            lines.append(
                f"  AIE HKCU ({self.user} hive) = {self.aie_hkcu_profile}  {ok(self.aie_hkcu_profile == 1)}"
            )
        lines.extend([
            f"  CPBA     = {self.consent_prompt_behavior_admin}                {ok(self.consent_prompt_behavior_admin == 0)}",
            f"  POSD     = {self.prompt_on_secure_desktop}                {ok(self.prompt_on_secure_desktop == 0)}",
            f"  msiexec  = {self.msiexec_path} (v{self.msiexec_version})",
            f"  %TEMP%   = {self.temp_dir} writable={self.temp_writable}",
            "",
            f"AIE chain response expected: {self.chain_response_expected}",
        ])
        return "\n".join(lines)


def evaluate(data: dict, target: str, user: str) -> AieReport:
    hklm = data.get("aie_hklm")
    hkcu = data.get("aie_hkcu")
    hkcu_profile = data.get("aie_hkcu_profile")
    hkcu_effective = hkcu if hkcu is not None else hkcu_profile
    cpba = data.get("consent_prompt_behavior_admin")
    posd = data.get("prompt_on_secure_desktop")
    temp_writable = bool(data.get("temp_writable"))
    chain = (
        hklm == 1
        and hkcu_effective == 1
        and cpba == 0
        and posd == 0
        and data.get("msiexec_path") is not None
        and temp_writable
    )
    return AieReport(
        target=target,
        user=user,
        identity=data.get("identity"),
        aie_hklm=hklm,
        aie_hkcu=hkcu,
        consent_prompt_behavior_admin=cpba,
        prompt_on_secure_desktop=posd,
        msiexec_path=data.get("msiexec_path"),
        msiexec_version=data.get("msiexec_version"),
        temp_dir=data.get("temp_dir"),
        temp_writable=temp_writable,
        chain_response_expected=chain,
        aie_hkcu_profile=hkcu_profile,
    )


def query(
    target: str,
    user: str,
    password: str,
    port: int = 5985,
    profile_user: str | None = None,
) -> dict:
    s = winrm.Session(
        f"http://{target}:{port}/wsman",
        auth=(user, password),
        transport="ntlm",
    )
    if profile_user:
        ps = "\n".join(
            line for line in PS_HIVE.splitlines() if not line.strip().startswith("param(")
        )
        r = s.run_ps(f"$ProfileUser = '{profile_user}';\n{ps}")
    else:
        r = s.run_ps(PS)
    if r.status_code != 0:
        raise RuntimeError(
            f"WinRM PS exited {r.status_code}: {r.std_err.decode(errors='replace')}"
        )
    raw = r.std_out.decode().strip()
    return json.loads(raw)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--target", required=True)
    p.add_argument("--user", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--port", type=int, default=5985)
    p.add_argument(
        "--profile-user",
        help="Load HKCU AlwaysInstallElevated from this local user's NTUSER.DAT (admin WinRM)",
    )
    p.add_argument("--json", action="store_true", help="emit JSON instead of text")
    args = p.parse_args()

    data = query(
        args.target,
        args.user,
        args.password,
        args.port,
        profile_user=args.profile_user,
    )
    report_user = args.profile_user or args.user
    report = evaluate(data, args.target, report_user)

    if args.json:
        print(json.dumps(asdict(report), indent=2))
    else:
        print(report.summary)

    return 0 if report.chain_response_expected else 1


if __name__ == "__main__":
    sys.exit(main())
