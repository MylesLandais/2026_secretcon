#!/usr/bin/env python3
"""Push bootstrap_asrep.ps1 and run DC promotion passes over WinRM."""
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

REPO = Path(__file__).resolve().parents[2]


def session(target: str, port: int, password: str) -> winrm.Session:
    return winrm.Session(
        f"http://{target}:{port}/wsman",
        auth=("Administrator", password),
        transport="ntlm",
        operation_timeout_sec=900,
        read_timeout_sec=920,
    )


def run_ps(s: winrm.Session, script: str) -> tuple[int, str, str]:
    r = s.run_ps(script)
    return r.status_code, r.std_out.decode("utf-8", "replace"), r.std_err.decode("utf-8", "replace")


def upload_via_b64(s: winrm.Session, local: Path, remote: str) -> None:
    data = local.read_bytes()
    b64 = base64.b64encode(data).decode("ascii")
    chunk_size = 2 * 1024
    chunks = [b64[i : i + chunk_size] for i in range(0, len(b64), chunk_size)]
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


def wait_winrm(target: str, port: int, password: str, timeout: int = 600) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = session(target, port, password)
            code, _, _ = run_ps(s, "hostname")
            if code == 0:
                return
        except Exception:
            pass
        time.sleep(10)
    sys.exit(f"WinRM never returned at {target}:{port}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", required=True)
    p.add_argument("--port", type=int, default=5985)
    p.add_argument("--admin-password", default=os.environ.get("ADMIN_PASSWORD", "packer"))
    p.add_argument("--wazuh-manager", default=os.environ.get("WAZUH_MANAGER_HOST", "192.168.61.10"))
    p.add_argument("--asrep-user", default=os.environ.get("SECRETCON_ASREP_USER", "enite"))
    p.add_argument("--asrep-password", default=os.environ.get("SECRETCON_ASREP_PASSWORD", "stud87"))
    p.add_argument("--asrep-flag", default=os.environ.get("SECRETCON_ASREP_FLAG", "asrep-flag-placeholder"))
    p.add_argument("--dc-user-flag", default=os.environ.get("SECRETCON_DC_USER_FLAG", ""))
    p.add_argument("--dc-root-flag", default=os.environ.get("SECRETCON_DC_ROOT_FLAG", "asrep-root-flag-placeholder"))
    p.add_argument("--enite-da", default=os.environ.get("SECRETCON_ASREP_ENITE_DA", "1"))
    p.add_argument("--ad-domain", default=os.environ.get("AD_DOMAIN", "secretcon.local"))
    p.add_argument("--ad-netbios", default=os.environ.get("AD_NETBIOS", "SECRETCON"))
    p.add_argument("--ad-safemode-password", default=os.environ.get("AD_SAFEMODE_PASSWORD", "PizzaMan123!"))
    p.add_argument("--wazuh-optional", action="store_true")
    args = p.parse_args()
    dc_user_flag = args.dc_user_flag or args.asrep_flag

    boot_path = REPO / "provisioning" / "powershell" / "bootstrap_asrep.ps1"
    runtime_path = REPO / "provisioning" / "asrep" / "asrep-bootstrap-runtime.ps1"
    verify_path = REPO / "provisioning" / "asrep" / "verify-post-promote.ps1"

    s = session(args.target, args.port, args.admin_password)
    print(f"[*] WinRM against http://{args.target}:{args.port}/wsman")

    upload_via_b64(s, boot_path, r"C:\Windows\Temp\bootstrap_asrep.ps1")
    upload_via_b64(s, runtime_path, r"C:\secretcon\asrep-bootstrap.ps1")

    env = (
        f"$env:WAZUH_MANAGER='{args.wazuh_manager}';"
        f"$env:AD_DOMAIN='{args.ad_domain}';"
        f"$env:AD_NETBIOS='{args.ad_netbios}';"
        f"$env:AD_SAFEMODE_PASSWORD='{args.ad_safemode_password}';"
        f"$env:SECRETCON_ASREP_USER='{args.asrep_user}';"
        f"$env:SECRETCON_ASREP_PASSWORD='{args.asrep_password}';"
        f"$env:SECRETCON_ASREP_FLAG='{args.asrep_flag}';"
        f"$env:SECRETCON_DC_USER_FLAG='{dc_user_flag}';"
        f"$env:SECRETCON_DC_ROOT_FLAG='{args.dc_root_flag}';"
        f"$env:SECRETCON_ASREP_ENITE_DA='{args.enite_da}';"
    )
    if args.wazuh_optional:
        env += "$env:WAZUH_ENROLLMENT_OPTIONAL='1';"

    print("[*] bootstrap_asrep.ps1")
    code, out, err = run_ps(s, f"{env} & 'C:\\Windows\\Temp\\bootstrap_asrep.ps1'")
    if code != 0:
        print(out[-4000:], err[-4000:])
        return code

    print("[*] reboot after bootstrap staging")
    run_ps(s, "Restart-Computer -Force")
    time.sleep(60)
    wait_winrm(args.target, args.port, args.admin_password)
    s = session(args.target, args.port, args.admin_password)

    for pass_n in (1, 2):
        print(f"[*] asrep-bootstrap pass {pass_n}")
        code, out, err = run_ps(
            s,
            f"{env}$env:SECRETCON_ASREP_PACKER='1'; & 'C:\\secretcon\\asrep-bootstrap.ps1'",
        )
        if code != 0:
            print(out[-4000:], err[-4000:])
            return code
        print("[*] reboot after promotion/seed pass")
        run_ps(s, "Restart-Computer -Force")
        time.sleep(90)
        wait_winrm(args.target, args.port, args.admin_password)
        s = session(args.target, args.port, args.admin_password)

    upload_via_b64(s, verify_path, r"C:\Windows\Temp\verify-post-promote.ps1")
    code, out, err = run_ps(
        s,
        f"{env} & 'C:\\Windows\\Temp\\verify-post-promote.ps1'",
    )
    print(out.strip())
    if code != 0:
        print(err[-2000:])
        return code

    print("[+] ASREP Proxmox bootstrap complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
