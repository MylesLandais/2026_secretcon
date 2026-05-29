# CysVulnServer — SharpUp enumeration (User_Joe POV)

[SharpUp](https://github.com/GhostPack/SharpUp) is a focused C# privesc
auditor — much tighter output than winPEAS and the same headline
finding (`AlwaysInstallElevated` HKLM=1 + HKCU=1). Run from the player
perspective (`User_Joe`) against the local QEMU CysVuln build.

| Field | Value |
|---|---|
| Tool | `SharpUp.exe` (GhostPack, .NET 3.5+) |
| Vendored at | `infrastructure/artifacts/cysvuln/SharpUp.exe` (gitignored) |
| Binary SHA-256 | `eef019eb5c4d157c0826c23b11d5b346a4f3a70a0089f52e462c57199a577d38` |
| Source of this build | [r3motecontrol/Ghostpack-CompiledBinaries](https://github.com/r3motecontrol/Ghostpack-CompiledBinaries) `SharpUp.exe` (community mirror) — pin via `CYSVULN_SHARPUP_HASH` after a trusted build |
| Run date | 2026-05-25 02:46 UTC |
| Target | local QEMU CysVuln build (`127.0.0.1:15985`) |
| Identity | `WIN-UB5Q52138VG\User_Joe` |
| Transport | Administrator WinRM → one-shot scheduled task `/RU User_Joe` (shared with winPEAS via `scripts/validate/joe_task_runner.py`) |
| Args | `audit` (default) |
| Raw log | `artifacts/cysvuln/sharpup-joe-<timestamp>.log` (gitignored) |

## Reproduce

```bash
nix develop
./scripts/run-local-cysvuln.sh
./scripts/cysvuln-local-prep.sh 127.0.0.1     # if first boot
./scripts/fetch-cysvuln-artifacts.sh          # warns if SharpUp.exe absent
./scripts/run-joe-tool.sh sharpup 127.0.0.1
```

Env knobs (mirrors the `winpeas` flow in [scripts/run-joe-tool.sh](../../scripts/run-joe-tool.sh)):

| Env | Default | Purpose |
|---|---|---|
| `WINRM_PORT` | `15985` | Forwarded WinRM port on host |
| `ADMIN_PW` | `PizzaMan123!` | Administrator password (WinRM transport) |
| `JOE_USER` | `User_Joe` | Account SharpUp impersonates |
| `JOE_PW` | `VeryStrongPassword123!@#` | `JOE_USER` password |
| `SHARPUP_URL` | (unset) | Optional override download URL |
| `SHARPUP_SHA256` | — | Pin the cached binary hash |
| `SHARPUP_LOCAL` | — | Skip resolution, use a pre-fetched file |
| `SHARPUP_ARGS` | `audit` | Override SharpUp argument string |
| `SHARPUP_KEEP` | `0` | Leave `C:\Users\Public\SharpUp.exe` + stdout on victim |
| `SHARPUP_HOST_FROM_GUEST` | `10.0.2.2` | Guest -> attacker gateway |
| `SHARPUP_SERVE_PORT` | random | Local HTTP staging port |

## Vendoring the binary

GhostPack does not publish prebuilt SharpUp releases, so the binary is
not auto-downloaded by default. Two supported paths:

1. **Build from source** (most defensible):
   ```bash
   git clone https://github.com/GhostPack/SharpUp
   cd SharpUp && dotnet build -c Release
   cp bin/Release/net4*/SharpUp.exe \
      infrastructure/artifacts/cysvuln/SharpUp.exe
   ```
2. **Pull from a trusted mirror** (this run used the
   [r3motecontrol/Ghostpack-CompiledBinaries](https://github.com/r3motecontrol/Ghostpack-CompiledBinaries)
   community mirror):
   ```bash
   SHARPUP_URL=https://github.com/r3motecontrol/Ghostpack-CompiledBinaries/raw/master/SharpUp.exe \
     ./scripts/fetch-cysvuln-artifacts.sh
   ```

In either case, pin the resulting SHA-256 via `CYSVULN_SHARPUP_HASH` so
[scripts/fetch-cysvuln-artifacts.sh](../../scripts/fetch-cysvuln-artifacts.sh)
fails on tampering.

## Execution model (shared with winPEAS)

Identical to the winPEAS runner — see
[winpeas.md](winpeas.md#how-execution-context-is-set-up) for the full
table. The summary: WinRM as `Administrator` (because `User_Joe` can't
auth to WinRM), HTTP staging via QEMU's host-from-guest gateway
(`10.0.2.2`), `secedit` grant of `SeBatchLogonRight` to Joe, one-shot
scheduled task `/RU User_Joe`, stdout pulled back over WinRM.

Code lives in
[scripts/validate/joe_task_runner.py](../../scripts/validate/joe_task_runner.py);
the SharpUp-specific bits (binary path, task name, default args) are a
~25-line `ToolSpec` in
[scripts/validate/run_joe_tool.py](../../scripts/validate/run_joe_tool.py).

## Headline findings

Full output for this run is in `artifacts/cysvuln/sharpup-joe-*.log`;
the relevant checks (~25 lines total) are below.

```
=== SharpUp: Running Privilege Escalation Checks ===
[!] Modifialbe scheduled tasks were not evaluated due to permissions.
Registry AutoLogon Found

[X] Unhandled exception in ModifiableServiceRegistryKeys: Exception has been thrown by the target of an invocation.
[X] Unhandled exception in ModifiableServices: Exception has been thrown by the target of an invocation.

=== Always Install Elevated ===
	HKCU: 1
	HKLM: 1


=== Registry AutoLogons ===
	DefaultDomainName: 
	DefaultUserName: Administrator
	DefaultPassword: 
	AltDefaultDomainName: 
	AltDefaultUserName: 
	AltDefaultPassword: 


=== Unattended Install Files ===
	C:\Windows\Panther\Unattend.xml


=== Services with Unquoted Paths ===
	Service 'fswsService' (StartMode: Automatic) has executable 'C:\EFS Software\Easy File Sharing Web Server\fswsService.exe', but 'C:\EFS' is modifable.
	... (one row per modifiable parent path) ...


[*] Completed Privesc Checks in 17 seconds
```

### What lights up

- **`Always Install Elevated` — HKLM=1 + HKCU=1.** This is the canonical
  CysVuln finding; matches [audit_aie.py](../../scripts/validate/audit_aie.py)
  and the AIE block in [winpeas.md](winpeas.md#alwaysinstallelevated-both-hives-flagged).
- **`Registry AutoLogons` — `DefaultUserName=Administrator`.** A
  Panther-leftover from imaging. `DefaultPassword` is empty in the
  registry (`autounattend.xml` does not seed it), so this is informational
  rather than an actionable credential.
- **`Unattended Install Files` — `C:\Windows\Panther\Unattend.xml`.** Joe
  can typically read this file; it does not contain the admin password
  for this build (the autounattend used at install time is cleared by
  Windows after first boot), but it's worth grep'ing
  `<AdministratorPassword>` if you're reproducing the box from a different
  ISO.
- **`Services with Unquoted Paths` — `fswsService`.** SharpUp flags the
  same unquoted-with-space path that winPEAS does, plus calls out each
  modifiable parent directory along the path. The intended privesc path
  on this box is **AIE**, not unquoted-service-path abuse; this finding
  is a red herring that distracts player attention.

### What SharpUp couldn't audit (worth knowing)

- `ModifiableServiceRegistryKeys` and `ModifiableServices` both threw
  `Exception has been thrown by the target of an invocation.` on this
  build. The exception traceback is suppressed by SharpUp, but the most
  common cause is .NET 3.5 trying to enumerate SCM with reduced
  privileges in the scheduled-task context. winPEAS covers the same
  ground (Services Information section) without issues; treat
  SharpUp's findings here as best-effort.
- `Modifialbe scheduled tasks were not evaluated due to permissions.`
  (sic — typo lives upstream). Joe can't read other users' scheduled
  task definitions, expected.

## Limitations

- Run via Task Scheduler in Joe's token (same caveat as winPEAS — the
  `Batch` group is added to Joe by the harness so it can register the
  task; a player landing via EFS callback shell would not see it).
- SharpUp focuses on a narrow, actionable set of checks. For broader
  enumeration (autoruns, scheduled apps, named-pipe ACLs, AMSI/PowerShell
  posture, vulnerable kernel modules, etc.) use winPEAS — see
  [winpeas.md](winpeas.md).
- This run used `audit` with no further arguments (all checks). To run a
  single check (matches the original walkthrough stub):
  ```bash
  SHARPUP_ARGS='audit AlwaysInstallElevated' ./scripts/run-joe-tool.sh sharpup 127.0.0.1
  ```

## Cross-references

- [docs/cysvulnserver/winpeas.md](winpeas.md) — comparable wide-net
  enumeration with the same execution model
- [docs/cysvulnserver/attack-faq-walkthrough.md](walkthrough.md) — full player chain
  (EFS → AIE → SYSTEM); SharpUp slots in at Phase 6b
- [scripts/validate/audit_aie.py](../../scripts/validate/audit_aie.py) —
  programmatic equivalent of the AIE finding above
- [scripts/validate/joe_task_runner.py](../../scripts/validate/joe_task_runner.py)
  — shared harness for both run-as-Joe enumeration tools
