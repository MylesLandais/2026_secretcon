#!/usr/bin/env python3
"""Push bootstrap_cysvuln.ps1 to a Proxmox cysvuln VM over WinRM.

Used by scripts/proxmox/deploy-cysvuln.sh once the new DHCP+lookup flow
has discovered the VM's IP. SSH bring-up via setup-openssh.ps1 turned
out to be unreliable in the Proxmox build window (WinRM:5985 was open
out of the box, but sshd never started; firewall + drive-letter race),
so this helper sidesteps SSH entirely.

Connection model mirrors scripts/validate/joe_task_runner.py: WinRM
over HTTP/5985, NTLM transport, Administrator / packer.

Usage:
    ./winrm_bootstrap.py --target 192.168.60.55 \
        --admin-password packer \
        --wazuh-manager 192.168.61.10 \
        --user-flag '<flag>' --root-flag '<flag>'
"""
from __future__ import annotations

import argparse
import base64
import os
import sys
import time
from pathlib import Path

try:
    import winrm
except ImportError:
    sys.exit("pywinrm not available; run inside `nix develop`")


def session(target: str, port: int, password: str) -> "winrm.Session":
    return winrm.Session(
        f"http://{target}:{port}/wsman",
        auth=("Administrator", password),
        transport="ntlm",
        operation_timeout_sec=900,
        read_timeout_sec=920,
    )


def run_ps(s: "winrm.Session", script: str) -> tuple[int, str, str]:
    r = s.run_ps(script)
    return r.status_code, r.std_out.decode("utf-8", "replace"), r.std_err.decode("utf-8", "replace")


def upload_via_b64(s: "winrm.Session", local: Path, remote: str) -> None:
    """Write `local` to `remote` on the guest using a base64-chunked
    Out-File pattern. Avoids pywinrm's CopyFile (which we don't bundle)
    and works on plain HTTP/5985 NTLM."""
    data = local.read_bytes()
    b64 = base64.b64encode(data).decode("ascii")
    # cmd.exe caps each invocation at 8191 chars; with PowerShell
    # bootstrap overhead the raw base64 chunk must stay well under that.
    # 2 KB of raw bytes -> ~2730 base64 chars + ~400 char PS wrapper.
    chunk_size = 2 * 1024
    chunks = [b64[i : i + chunk_size] for i in range(0, len(b64), chunk_size)]
    print(f"[+] uploading {local.name} -> {remote} ({len(data)} bytes / {len(chunks)} chunks)")
    init = f"""
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent '{remote}'
if (-not (Test-Path $dir)) {{ New-Item -ItemType Directory -Path $dir | Out-Null }}
if (Test-Path '{remote}') {{ Remove-Item -Force '{remote}' }}
"""
    code, _, err = run_ps(s, init)
    if code != 0:
        raise RuntimeError(f"remote dir init failed: {err}")

    for idx, chunk in enumerate(chunks):
        ps = f"""
$b = [Convert]::FromBase64String('{chunk}')
$fs = [IO.File]::Open('{remote}', [IO.FileMode]::Append)
$fs.Write($b, 0, $b.Length)
$fs.Close()
"""
        code, _, err = run_ps(s, ps)
        if code != 0:
            raise RuntimeError(f"chunk {idx} write failed: {err}")
        if idx % 25 == 0:
            print(f"    chunk {idx}/{len(chunks)}", flush=True)
    # Sanity: verify size on remote.
    code, out, _ = run_ps(s, f"(Get-Item '{remote}').Length")
    if code != 0 or out.strip() != str(len(data)):
        raise RuntimeError(f"remote size mismatch: expected {len(data)}, got {out!r}")
    print(f"    ok ({len(data)} bytes confirmed)")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", required=True, help="VM IP")
    p.add_argument("--port", type=int, default=5985)
    p.add_argument("--admin-password", default=os.environ.get("ADMIN_PASSWORD", "packer"))
    p.add_argument("--wazuh-manager", default="192.168.61.10")
    p.add_argument("--user-flag", default=os.environ.get("SECRETCON_USER_FLAG", "cysvuln-user-flag-placeholder"))
    p.add_argument("--root-flag", default=os.environ.get("SECRETCON_ROOT_FLAG", "cysvuln-root-flag-placeholder"))
    p.add_argument(
        "--shared-local-admin-password",
        default=os.environ.get("SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD", "PizzaMan123!"),
    )
    p.add_argument("--wazuh-optional", action="store_true", help="set WAZUH_ENROLLMENT_OPTIONAL=1")
    p.add_argument(
        "--bootstrap",
        default=str(Path(__file__).resolve().parents[2] / "provisioning" / "powershell" / "bootstrap_cysvuln.ps1"),
    )
    args = p.parse_args()

    boot_path = Path(args.bootstrap)
    if not boot_path.is_file():
        sys.exit(f"bootstrap not found: {boot_path}")

    # Phase 1: connectivity check + capture pre-bootstrap state.
    s = session(args.target, args.port, args.admin_password)
    print(f"[*] WinRM session against http://{args.target}:{args.port}/wsman")
    code, out, err = run_ps(
        s,
        r"$PSVersionTable.PSVersion.ToString(); hostname; (Get-WmiObject -Class Win32_OperatingSystem).Caption",
    )
    if code != 0:
        sys.exit(f"[!] WinRM smoke failed: rc={code} err={err}")
    print(f"[+] WinRM ok:\n{out.strip()}")

    # Phase 2: also try to harden SSH for downstream tools (best-effort).
    print("[*] best-effort: ensure Windows Firewall allows inbound TCP/22 (for later sshd)")
    run_ps(
        s,
        r"""
New-NetFirewallRule -DisplayName 'SecretCon OpenSSH 22' -Direction Inbound `
  -Action Allow -Protocol TCP -LocalPort 22 -Profile Any -ErrorAction SilentlyContinue | Out-Null
""",
    )

    # Phase 3: locate the PROVISION CD on the box (E:/F:) so bootstrap can
    # find its companion artifacts. The cmdlet result is just an info dump.
    code, out, _ = run_ps(
        s,
        r"Get-PSDrive -PSProvider FileSystem | ForEach-Object { '{0}: -> {1}' -f $_.Name, $_.Root }",
    )
    print(f"[*] guest drives:\n{out.strip()}")

    # Phase 4: upload bootstrap_cysvuln.ps1 to C:\Windows\Temp\.
    remote_path = r"C:\Windows\Temp\bootstrap_cysvuln.ps1"
    upload_via_b64(s, boot_path, remote_path)

    # Phase 5: execute bootstrap with env vars set in-process.
    env_block = (
        f"$env:WAZUH_MANAGER='{args.wazuh_manager}';"
        f"$env:SECRETCON_USER_FLAG='{args.user_flag.replace(chr(39), chr(39)*2)}';"
        f"$env:SECRETCON_ROOT_FLAG='{args.root_flag.replace(chr(39), chr(39)*2)}';"
        f"$env:SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD='{args.shared_local_admin_password.replace(chr(39), chr(39)*2)}';"
    )
    if args.wazuh_optional:
        env_block += "$env:WAZUH_ENROLLMENT_OPTIONAL='1';"

    print("[*] launching bootstrap_cysvuln.ps1 (~5-10 min, no live stream)")
    start = time.time()
    code, out, err = run_ps(s, f"{env_block} & '{remote_path}'")
    elapsed = time.time() - start
    print(f"[*] bootstrap exited rc={code} after {elapsed:.0f}s")
    if out:
        print("--- STDOUT (tail) ---")
        print(out[-4000:])
    if err:
        print("--- STDERR (tail) ---")
        print(err[-4000:])
    if code != 0:
        return code

    # Phase 6: quick smoke — Wazuh agent service should be running.
    code, out, _ = run_ps(
        s,
        r"Get-Service -Name 'WazuhSvc' -ErrorAction SilentlyContinue | Format-List Name,Status,StartType",
    )
    print(f"[+] WazuhSvc:\n{out.strip() or '(missing)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
