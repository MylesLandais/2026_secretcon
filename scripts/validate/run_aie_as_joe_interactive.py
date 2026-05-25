#!/usr/bin/env python3
"""
Run AlwaysInstallElevated validation as User_Joe in an interactive session.

Non-interactive WinRM/CIM logon types fail msiexec with 1601. This script uses
PsExec -i (primary) and xfreerdp session bootstrap (fallback) to run
C:\\secretcon\\validate-aie.ps1, then cross-checks aie-flag.txt vs root.txt.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time

from joe_task_runner import quote_ps_single, run_ps, winrm_session

DEFAULT_FLAG_PATH = r"C:\Users\Public\aie-flag.txt"
DEFAULT_RESULT_PATH = r"C:\Users\Public\aie-validation-result.txt"
DEFAULT_MSI_PATH = r"C:\Users\Public\aie-validation-payload.msi"
DEFAULT_LOG_PATH = r"C:\Users\Public\aie-joe-validation.log"
ROOT_PATH = r"C:\Users\Administrator\Desktop\root.txt"
VALIDATE_SCRIPT = r"C:\secretcon\validate-aie.ps1"
PSEXEC = r"C:\Users\Public\PsExec.exe"


def clear_artifacts(session, flag_path: str, result_path: str) -> None:
    ps = f"""
Remove-Item '{flag_path}','{result_path}' -Force -ErrorAction SilentlyContinue
"""
    run_ps(session, ps)


def query_joe_session(session) -> str | None:
    code, out, _ = run_ps(
        session,
        r"""
$rows = query user 2>$null | Select-String 'User_Joe'
foreach ($row in $rows) {
  $parts = ($row.ToString().Trim() -split '\s+') | Where-Object { $_ }
  $id = $parts | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
  $state = $parts | Where-Object { $_ -match '^(Active|Disc|Idle)' } | Select-Object -First 1
  if ($id) { Write-Host "$id|$state"; exit 0 }
}
exit 1
""",
    )
    if code != 0:
        return None
    line = out.strip().splitlines()[-1].strip()
    if "|" in line:
        sid, _state = line.split("|", 1)
        if sid.isdigit():
            return sid
    return None


def psexec_launch(
    session,
    joe_password: str,
    session_id: str | None,
    *,
    detach: bool,
    msi_path: str,
    log_path: str,
) -> tuple[int, str]:
    joe_pw = quote_ps_single(joe_password)
    i_args = f"-i {session_id}" if session_id else "-i"
    d_flag = "-d " if detach else ""
    ps = f"""
$psexec = '{PSEXEC}'
if (-not (Test-Path $psexec)) {{ Write-Host 'PsExec missing'; exit 10 }}
& $psexec -accepteula -u User_Joe -p '{joe_pw}' {i_args} {d_flag}\\\\localhost cmd.exe /c "msiexec /quiet /norestart /i {msi_path} /l*v {log_path}" 2>&1 | ForEach-Object {{ Write-Host $_ }}
Write-Host "[*] PsExec msiexec finished ({i_args})"
exit 0
"""
    code, out, err = run_ps(session, ps)
    if err.strip():
        out = out + "\n" + err
    return code, out


def rdp_bootstrap(target: str, rdp_port: int, joe_password: str, wait: float) -> subprocess.Popen | None:
    cmd = [
        "xfreerdp",
        f"/v:{target}:{rdp_port}",
        "/u:User_Joe",
        f"/p:{joe_password}",
        "/cert:ignore",
        "/size:1024x768",
        "/timeout:30000",
        "/auto-reconnect-max-retries:0",
    ]
    print(f"[*] RDP session bootstrap: {target}:{rdp_port}")
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        print("[!] xfreerdp not found (add freerdp to nix develop)", file=sys.stderr)
        return None
    time.sleep(wait)
    return proc


def poll_flag(
    session,
    timeout: float,
    *,
    flag_path: str,
    result_path: str,
    interval: float = 5.0,
) -> tuple[bool, str]:
    deadline = time.monotonic() + timeout
    last_out = ""
    while time.monotonic() < deadline:
        code, out, _ = run_ps(
            session,
            f"""
$aie = Get-Content '{flag_path}' -Raw -EA SilentlyContinue
$root = Get-Content '{ROOT_PATH}' -Raw -EA SilentlyContinue
$log = Get-Content '{result_path}' -Raw -EA SilentlyContinue
if ($aie -and $root) {{
  Write-Host "aie-flag:" $aie.Trim()
  Write-Host "root.txt:" $root.Trim()
  if ($log) {{ Write-Host "--- validation log (tail) ---"; ($log.Trim().Split("`n") | Select-Object -Last 12) -join "`n" }}
  if ($aie.Trim() -eq $root.Trim()) {{ exit 0 }} else {{ exit 2 }}
}}
if ($log) {{ Write-Host "--- in-progress log (tail) ---"; ($log.Trim().Split("`n") | Select-Object -Last 8) -join "`n" }}
exit 3
""",
        )
        last_out = out
        if code == 0:
            return True, out
        if code == 2:
            return False, out
        time.sleep(interval)
    return False, last_out or "timeout waiting for aie-flag.txt"


def main() -> int:
    p = argparse.ArgumentParser(description="AIE validation via interactive User_Joe session")
    p.add_argument("--target", default="127.0.0.1")
    p.add_argument("--winrm-port", type=int, default=15985)
    p.add_argument("--rdp-port", type=int, default=13389)
    p.add_argument("--admin-password", default="PizzaMan123!")
    p.add_argument("--joe-password", default="VeryStrongPassword123!@#")
    p.add_argument("--poll-timeout", type=float, default=120.0)
    p.add_argument("--skip-rdp-bootstrap", action="store_true")
    p.add_argument(
        "--msi-path",
        default=DEFAULT_MSI_PATH,
        help="Victim path of the MSI msiexec should install (default: wixl probe)",
    )
    p.add_argument(
        "--flag-path",
        default=DEFAULT_FLAG_PATH,
        help="Victim path the deferred CustomAction writes (cross-checked against root.txt)",
    )
    p.add_argument(
        "--log-path",
        default=DEFAULT_LOG_PATH,
        help="Victim path msiexec writes its /l*v log to",
    )
    p.add_argument(
        "--result-path",
        default=DEFAULT_RESULT_PATH,
        help="Optional secondary result log surfaced during polling",
    )
    args = p.parse_args()

    session = winrm_session(
        args.target, args.winrm_port, "Administrator", args.admin_password
    )

    print("[*] Clearing prior AIE artifacts...")
    clear_artifacts(session, args.flag_path, args.result_path)

    rdp_proc: subprocess.Popen | None = None
    sid = query_joe_session(session)
    if not sid and not args.skip_rdp_bootstrap:
        rdp_proc = rdp_bootstrap(args.target, args.rdp_port, args.joe_password, wait=25.0)
        sid = query_joe_session(session)
        if sid:
            print(f"[*] User_Joe session after RDP bootstrap: {sid}")
    elif sid:
        print(f"[*] Existing User_Joe session: {sid}")

    print("[*] Running msiexec via PsExec (synchronous)...")
    code, out = psexec_launch(
        session,
        args.joe_password,
        sid,
        detach=False,
        msi_path=args.msi_path,
        log_path=args.log_path,
    )
    print(out)
    if rdp_proc is not None:
        rdp_proc.terminate()
        try:
            rdp_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            rdp_proc.kill()

    if code == 0:
        ok, poll_out = poll_flag(
            session,
            10.0,
            flag_path=args.flag_path,
            result_path=args.result_path,
        )
        if ok:
            print(poll_out)
            print("[+] AIE privesc confirmed via interactive User_Joe")
            return 0

    ok, poll_out = poll_flag(
        session,
        args.poll_timeout,
        flag_path=args.flag_path,
        result_path=args.result_path,
    )
    if ok:
        print(poll_out)
        print("[+] AIE privesc confirmed via interactive User_Joe")
        return 0

    print(poll_out, file=sys.stderr)
    print("[!] AIE validation failed: aie-flag.txt missing or mismatch", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
