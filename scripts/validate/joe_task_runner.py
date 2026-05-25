#!/usr/bin/env python3
"""
Shared harness for running a Windows enumeration tool as User_Joe on the
CysVuln VM.

Why Administrator WinRM + Task Scheduler?
  By default Windows only allows members of Administrators / Remote
  Management Users to authenticate to WinRM, so we cannot connect as
  User_Joe directly. We open the WinRM session as Administrator (same
  transport as audit_aie.py), then register a one-shot scheduled task
  /RU User_Joe that runs the tool in Joe's token. PsExec -u Joe and
  Start-Process -Credential both fail from a WinRM remote shell because
  the network-logon token cannot assign a primary token for another
  user; Task Scheduler stores Joe's credential at registration time and
  starts the task with a local logon, which sidesteps the limitation.

Consumers (winPEAS, SharpUp, ...) build a `ToolSpec` and either call
`run_as_joe(spec, args)` directly or extend the parser from
`build_common_parser(spec)` before calling it.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import functools
import hashlib
import http.server
import ntpath
import os
import pathlib
import re
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass

import winrm

# Strip ANSI CSI escape sequences. Some tools emit color codes even with
# their "no colors" flag set, so we sanitize the captured output.
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# QEMU user-mode networking exposes the host at 10.0.2.2 inside the guest.
# Override when running against a non-QEMU target (real hardware, hyper-v, etc).
DEFAULT_HOST_FROM_GUEST = "10.0.2.2"

TASK_POLL_INTERVAL = 5.0
TASK_TIMEOUT = 600.0


@dataclass(frozen=True)
class ToolSpec:
    """Per-tool constants consumed by the shared harness."""

    name: str
    """Human-readable tool name (used in log messages and stdout banner)."""

    victim_bin: str
    """Absolute Windows path where the binary lives on the victim."""

    victim_out: str
    """Absolute Windows path where the tool's stdout is redirected."""

    task_name: str
    """Scheduled-task name; must be unique per concurrent run."""

    default_args: str
    """Default argument string passed to the tool."""

    default_cache: pathlib.Path
    """Attacker-side cache path for the binary."""

    serve_name: str
    """Filename exposed to the guest via the HTTP staging server."""

    env_prefix: str
    """Uppercased env-var prefix (e.g. ``WINPEAS``, ``SHARPUP``)."""

    vendored: pathlib.Path | None = None
    """Optional in-repo vendored binary path (preferred over URL fetch)."""

    default_url: str | None = None
    """Optional default upstream download URL."""


def log(msg: str) -> None:
    print(f"[*] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"[!] {msg}", flush=True)


def fail(msg: str, code: int = 1) -> int:
    print(f"[!] {msg}", file=sys.stderr, flush=True)
    return code


def sha256_path(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _fail_str_with_hash(observed: str, expected: str) -> str:
    raise SystemExit(
        f"sha256 mismatch: observed {observed} != expected {expected}"
    )


def fetch_binary(
    url: str, dest: pathlib.Path, expected_sha256: str | None, label: str
) -> str:
    """Download `url` to `dest` (cache-hit aware); verify pin if given."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        observed = sha256_path(dest)
        if expected_sha256 and observed != expected_sha256:
            warn(
                f"cached {dest} sha256={observed} does not match pin "
                f"{expected_sha256}; re-downloading"
            )
            dest.unlink()
        else:
            log(f"cache hit: {dest} ({dest.stat().st_size} bytes, sha256={observed})")
            return observed
    log(f"downloading {label} from {url}")
    req = urllib.request.Request(url, headers={"User-Agent": f"secretcon-{label}/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = resp.read()
    dest.write_bytes(data)
    observed = sha256_path(dest)
    log(f"wrote {dest} ({len(data)} bytes, sha256={observed})")
    if expected_sha256 and observed != expected_sha256:
        return _fail_str_with_hash(observed, expected_sha256)
    if not expected_sha256:
        warn(
            "no --sha256 pin; pin the above hash after a trusted first download"
        )
    return observed


def winrm_admin(target: str, port: int, password: str) -> winrm.Session:
    return winrm.Session(
        f"http://{target}:{port}/wsman",
        auth=("Administrator", password),
        transport="ntlm",
        operation_timeout_sec=600,
        read_timeout_sec=620,
    )


def run_ps(session: winrm.Session, script: str) -> tuple[int, str, str]:
    r = session.run_ps(script)
    return (
        r.status_code,
        r.std_out.decode(errors="replace"),
        r.std_err.decode(errors="replace"),
    )


def remote_sha256(session: winrm.Session, path: str) -> str | None:
    code, out, _ = run_ps(
        session,
        f"(Get-FileHash -Algorithm SHA256 -Path '{path}').Hash.ToLower()",
    )
    if code != 0:
        return None
    return out.strip().splitlines()[-1] if out.strip() else None


def remove_remote(session: winrm.Session, *paths: str) -> None:
    joined = ",".join(f"'{p}'" for p in paths)
    run_ps(
        session,
        f"Remove-Item -Force -ErrorAction SilentlyContinue -Path {joined}",
    )


@contextlib.contextmanager
def serve_directory(directory: pathlib.Path, port: int = 0):
    """Serve `directory` over HTTP on a free port; yield the bound port."""

    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, format, *args):  # noqa: A002
            return

    handler = functools.partial(QuietHandler, directory=str(directory))
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
    bound_port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield bound_port
    finally:
        server.shutdown()
        server.server_close()


def upload_binary_via_http(
    session: winrm.Session,
    local: pathlib.Path,
    *,
    victim_bin: str,
    serve_name: str,
    host_from_guest: str,
    serve_port: int | None,
) -> str:
    """Stage `local` on a temp HTTP server and have the guest pull it.

    WinRM's ``MaxEnvelopeSize`` (HTTP 413) makes chunked base64 uploads of
    multi-MiB binaries painful; the QEMU host-from-guest gateway is the
    fast path. Returns the verified SHA-256.
    """
    log(
        f"uploading {local.name} to {victim_bin} ({local.stat().st_size} bytes) "
        f"via guest -> {host_from_guest} pull"
    )
    remove_remote(session, victim_bin)
    code, _, err = run_ps(
        session,
        f"New-Item -ItemType Directory -Force -Path "
        f"'{ntpath.dirname(victim_bin)}' | Out-Null",
    )
    if code != 0:
        raise SystemExit(f"failed to ensure target dir: {err.strip()}")

    local_hash = sha256_path(local)
    stage = pathlib.Path("/tmp") / f"joe-stage-{os.getpid()}-{serve_name}"
    stage.mkdir(parents=True, exist_ok=True)
    staged = stage / serve_name
    staged.write_bytes(local.read_bytes())
    try:
        with serve_directory(stage, port=serve_port or 0) as port:
            url = f"http://{host_from_guest}:{port}/{serve_name}"
            log(f"serving {staged} at {url}")
            ps = (
                f"$ErrorActionPreference='Stop';"
                f"[Net.ServicePointManager]::SecurityProtocol="
                f"[Net.SecurityProtocolType]::Tls12;"
                f"$wc=New-Object Net.WebClient;"
                f"$wc.DownloadFile('{url}','{victim_bin}');"
                f"(Get-FileHash -Algorithm SHA256 -Path '{victim_bin}').Hash.ToLower()"
            )
            code, out, err = run_ps(session, ps)
            if code != 0:
                raise SystemExit(
                    f"victim download failed: rc={code} err={err.strip()[:300]}"
                )
            remote_hash = (out.strip().splitlines() or [""])[-1].strip()
    finally:
        try:
            staged.unlink()
            stage.rmdir()
        except OSError:
            pass

    if remote_hash != local_hash:
        raise SystemExit(
            f"upload hash mismatch: local={local_hash} remote={remote_hash}"
        )
    log(f"upload verified: sha256={remote_hash}")
    return remote_hash


def grant_batch_logon(session: winrm.Session, joe_user: str) -> None:
    """Grant SeBatchLogonRight to `joe_user` so schtasks /RU works.

    Task Scheduler refuses to start a task whose principal lacks the
    "Log on as a batch job" user right. We grant it via secedit and keep
    the existing rights intact. The grant is *not* revoked by this
    module; consumers who care can call ``secedit`` again afterwards.
    """
    log(f"granting SeBatchLogonRight to {joe_user} (secedit)")
    ps = rf"""
$ErrorActionPreference = 'Stop'
$user = '{joe_user}'
$exp  = Join-Path $env:TEMP 'joe-secpol-export.cfg'
$apply= Join-Path $env:TEMP 'joe-secpol-apply.inf'
$db   = Join-Path $env:TEMP 'joe-secedit.sdb'
secedit /export /cfg $exp /quiet | Out-Null
$txt = Get-Content $exp -Raw
$current = ''
if ($txt -match '(?m)^SeBatchLogonRight\s*=\s*(.*)$') {{
    $current = $matches[1].Trim()
}}
if ($current -split ',' | Where-Object {{ $_.Trim() -ieq $user }}) {{
    Write-Host "[*] $user already has SeBatchLogonRight"
    exit 0
}}
$new = if ($current) {{ "$current,$user" }} else {{ $user }}
$inf = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
Revision=1
[Privilege Rights]
SeBatchLogonRight = $new
"@
[IO.File]::WriteAllText($apply, $inf, [System.Text.Encoding]::Unicode)
secedit /configure /db $db /cfg $apply /areas USER_RIGHTS /quiet
Write-Host "[*] SeBatchLogonRight now: $new"
"""
    code, out, err = run_ps(session, ps)
    if out.strip():
        print(out.strip())
    if code != 0:
        raise SystemExit(
            f"secedit grant failed: rc={code} err={err.strip()[:300]}"
        )


def run_via_scheduled_task(
    session: winrm.Session,
    *,
    spec: ToolSpec,
    joe_user: str,
    joe_password: str,
    tool_args: str,
) -> int:
    """Register, run, poll, and clean up a one-shot scheduled task."""
    grant_batch_logon(session, joe_user)
    log(f"scheduling {spec.name} as {joe_user} via Task Scheduler")
    remove_remote(session, spec.victim_out)
    joe_pw_escaped = joe_password.replace("'", "''")
    cmdline = (
        f'cmd.exe /c \\"\\"{spec.victim_bin}\\" {tool_args} '
        f'> \\"{spec.victim_out}\\" 2>&1\\"'
    )
    ps = f"""
$ErrorActionPreference = 'Continue'

# C:\\Users\\Public is writable by all users by default. Pre-create the
# output file so Joe can write to it without inheriting odd ACLs.
Set-Content -Path '{spec.victim_out}' -Value '' -Encoding ASCII -Force
try {{
    $acl = Get-Acl '{spec.victim_out}'
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        '{joe_user}','FullControl','Allow')
    $acl.SetAccessRule($rule)
    Set-Acl -Path '{spec.victim_out}' -AclObject $acl
}} catch {{
    Write-Host "[!] ACL set warning: $($_.Exception.Message)"
}}

# schtasks writes a "not found" stderr line if the task is absent; that
# isn't fatal, so wrap in cmd to swallow stderr.
cmd /c "schtasks /Delete /TN {spec.task_name} /F 2>nul" | Out-Null

$createOut = & schtasks /Create /TN '{spec.task_name}' `
    /TR '{cmdline}' `
    /SC ONCE /ST 23:59 /SD 01/01/2030 `
    /RU '{joe_user}' /RP '{joe_pw_escaped}' `
    /RL LIMITED /F 2>&1
$createRc = $LASTEXITCODE
Write-Host "[*] schtasks /Create rc=$createRc"
$createOut | ForEach-Object {{ Write-Host "    $_" }}
if ($createRc -ne 0) {{ exit 90 }}

$runOut = & schtasks /Run /TN '{spec.task_name}' 2>&1
$runRc = $LASTEXITCODE
Write-Host "[*] schtasks /Run rc=$runRc"
$runOut | ForEach-Object {{ Write-Host "    $_" }}
if ($runRc -ne 0) {{
    cmd /c "schtasks /Delete /TN {spec.task_name} /F 2>nul" | Out-Null
    exit 91
}}

$deadline = (Get-Date).AddSeconds({int(TASK_TIMEOUT)})
$lastStatus = ''
$lastResult = $null
while ((Get-Date) -lt $deadline) {{
    Start-Sleep -Seconds {int(TASK_POLL_INTERVAL)}
    $info = & schtasks /Query /TN '{spec.task_name}' /FO LIST /V 2>$null
    $statusLine = ($info | Select-String -Pattern '^Status:' | Select-Object -First 1)
    $lastResultLine = ($info | Select-String -Pattern '^Last Result:' | Select-Object -First 1)
    $status = if ($statusLine) {{ ($statusLine.ToString().Split(':',2)[1]).Trim() }} else {{ '' }}
    $lr = if ($lastResultLine) {{ ($lastResultLine.ToString().Split(':',2)[1]).Trim() }} else {{ '' }}
    if ($status -ne $lastStatus) {{
        Write-Host "[*] status=$status last_result=$lr"
        $lastStatus = $status
    }}
    if ($status -eq 'Ready' -and $lr -ne '267009') {{
        # 267009 = SCHED_S_TASK_HAS_NOT_RUN (still pre-run)
        $lastResult = $lr
        break
    }}
}}

cmd /c "schtasks /Delete /TN {spec.task_name} /F 2>nul" | Out-Null

if ($null -eq $lastResult) {{
    Write-Host "[!] timed out waiting for task to finish (last status: $lastStatus)"
    exit 92
}}

Write-Host "[*] {spec.name} task Last Result: $lastResult"
exit ([int]$lastResult)
"""
    code, out, err = run_ps(session, ps)
    if out.strip():
        print(out.strip())
    if err.strip():
        print(err.strip(), file=sys.stderr)
    return code


def fetch_remote_output(session: winrm.Session, victim_out: str) -> str:
    log(f"fetching {victim_out}")
    code, out, err = run_ps(
        session,
        f"""
if (-not (Test-Path '{victim_out}')) {{ exit 7 }}
$bytes = [IO.File]::ReadAllBytes('{victim_out}')
[Convert]::ToBase64String($bytes)
""",
    )
    if code != 0:
        raise SystemExit(
            f"failed to read {victim_out}: rc={code} err={err.strip()[:200]}"
        )
    b64 = "".join(out.split())
    try:
        return base64.b64decode(b64).decode("utf-8", errors="replace")
    except Exception as exc:
        raise SystemExit(f"failed to decode remote output: {exc}") from exc


def resolve_binary(args: argparse.Namespace, spec: ToolSpec) -> pathlib.Path:
    """Pick the local binary to upload, in priority order.

    1. ``--local <path>`` (or ``$<PREFIX>_LOCAL``)
    2. ``spec.vendored`` (in-repo vendored binary)
    3. ``spec.default_cache`` (existing fetched copy)
    4. ``--url <url>`` / ``spec.default_url`` download to ``--cache``
    """
    if args.local:
        local = pathlib.Path(args.local)
        if not local.is_file():
            raise SystemExit(f"--local path does not exist: {local}")
        observed = sha256_path(local)
        log(f"using local {local} (sha256={observed})")
        if args.sha256 and observed != args.sha256:
            raise SystemExit(
                f"--local sha256 {observed} does not match pin {args.sha256}"
            )
        return local

    if spec.vendored and spec.vendored.is_file():
        observed = sha256_path(spec.vendored)
        log(f"using vendored {spec.vendored} (sha256={observed})")
        if args.sha256 and observed != args.sha256:
            raise SystemExit(
                f"vendored sha256 {observed} does not match pin {args.sha256}"
            )
        return spec.vendored

    cache = pathlib.Path(args.cache)
    url = args.url or spec.default_url
    if not url and not cache.is_file():
        raise SystemExit(
            f"{spec.name} binary not available: vendored path "
            f"({spec.vendored}) missing, cache ({cache}) missing, no URL set"
        )
    if url:
        fetch_binary(url, cache, args.sha256, spec.name)
    elif args.sha256:
        observed = sha256_path(cache)
        if observed != args.sha256:
            raise SystemExit(
                f"cache sha256 {observed} does not match pin {args.sha256}"
            )
    return cache


def build_common_parser(spec: ToolSpec) -> argparse.ArgumentParser:
    """ArgumentParser with the flags every joe-task tool shares."""
    pre = spec.env_prefix
    p = argparse.ArgumentParser(description=f"Run {spec.name} as User_Joe.")
    p.add_argument("--target", required=True)
    p.add_argument("--winrm-port", type=int, default=15985)
    p.add_argument("--admin-password", required=True)
    p.add_argument("--joe-user", default="User_Joe")
    p.add_argument("--joe-password", required=True)
    p.add_argument(
        "--url",
        default=os.environ.get(f"{pre}_URL", spec.default_url),
        help=f"{spec.serve_name} download URL",
    )
    p.add_argument(
        "--sha256",
        default=os.environ.get(f"{pre}_SHA256") or None,
        help=f"Pin expected SHA-256 of {spec.serve_name}",
    )
    p.add_argument(
        "--local",
        default=os.environ.get(f"{pre}_LOCAL") or None,
        help=f"Use a pre-downloaded {spec.serve_name} (skip resolution)",
    )
    p.add_argument(
        "--cache",
        default=str(spec.default_cache),
        help=f"Attacker-side cache path (default: {spec.default_cache})",
    )
    p.add_argument(
        "--args",
        dest="tool_args",
        default=os.environ.get(f"{pre}_ARGS", spec.default_args),
        help=f"Argument string passed to {spec.name} (default: {spec.default_args!r})",
    )
    p.add_argument(
        "--keep",
        action="store_true",
        help=f"Leave {spec.serve_name} + stdout file on the victim after run",
    )
    p.add_argument(
        "--host-from-guest",
        default=os.environ.get(
            f"{pre}_HOST_FROM_GUEST", DEFAULT_HOST_FROM_GUEST
        ),
        help=(
            "Address the guest uses to reach the attacker host (default "
            f"{DEFAULT_HOST_FROM_GUEST}; QEMU user-mode gateway)"
        ),
    )
    p.add_argument(
        "--serve-port",
        type=int,
        default=int(os.environ.get(f"{pre}_SERVE_PORT", "0") or 0),
        help="Local HTTP staging port (0 = random free port)",
    )
    return p


def run_as_joe(spec: ToolSpec, args: argparse.Namespace) -> int:
    """End-to-end: resolve binary, upload, schedule, fetch, cleanup."""
    try:
        local = resolve_binary(args, spec)
    except SystemExit as exc:
        return fail(str(exc), 3)

    session = winrm_admin(args.target, args.winrm_port, args.admin_password)

    try:
        upload_binary_via_http(
            session,
            local,
            victim_bin=spec.victim_bin,
            serve_name=spec.serve_name,
            host_from_guest=args.host_from_guest,
            serve_port=args.serve_port or None,
        )
    except SystemExit as exc:
        return fail(str(exc), 5)

    started = time.monotonic()
    rc = run_via_scheduled_task(
        session,
        spec=spec,
        joe_user=args.joe_user,
        joe_password=args.joe_password,
        tool_args=args.tool_args,
    )
    elapsed = time.monotonic() - started
    log(f"{spec.name} finished in {elapsed:.1f}s (task rc={rc})")

    try:
        body = fetch_remote_output(session, spec.victim_out)
    except SystemExit as exc:
        return fail(str(exc), 6)

    body = ANSI_RE.sub("", body)
    banner = f"===== {spec.name} stdout (User_Joe) ====="
    print()
    print(banner)
    print(body)
    print("=" * len(banner))

    if not args.keep:
        log("cleaning up victim artifacts")
        remove_remote(session, spec.victim_bin, spec.victim_out)
    else:
        log(f"keeping {spec.victim_bin} and {spec.victim_out} on victim")

    return 0 if rc == 0 else rc
