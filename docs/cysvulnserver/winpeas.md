# CysVulnServer — winPEAS enumeration (User_Joe POV)

[winPEAS](https://github.com/peass-ng/PEASS-ng/tree/master/winPEAS) run from
the player perspective (`User_Joe`) against the local QEMU CysVuln build.
The headline finding (`AlwaysInstallElevated` HKLM=1 + HKCU=1) lines up with
the AIE chain documented in [walkthrough.md](walkthrough.md).

| Field | Value |
|---|---|
| Tool | `winPEASx64.exe` (peass-ng, latest release) |
| Binary SHA-256 | `e0df786b764ce9635236e37c5676f525eb60193ce737ddf352eadb53ff366f80` |
| Run date | 2026-05-25 02:15 UTC |
| Target | local QEMU CysVuln build (`127.0.0.1:15985`) |
| Identity | `WIN-UB5Q52138VG\User_Joe` |
| Transport | Administrator WinRM → one-shot scheduled task `/RU User_Joe` |
| Modules | `notcolors quiet systeminfo userinfo applicationsinfo eventsinfo servicesinfo processinfo` |
| Raw log | `artifacts/cysvuln/winpeas-joe-<timestamp>.log` (gitignored) |

## Reproduce

```bash
nix develop
./scripts/run-local-cysvuln.sh
./scripts/cysvuln-local-prep.sh 127.0.0.1     # if first boot
./scripts/run-winpeas.sh 127.0.0.1
```

Env knobs documented at the top of
[scripts/run-winpeas.sh](../../scripts/run-winpeas.sh):

| Env | Default | Purpose |
|---|---|---|
| `WINRM_PORT` | `15985` | Forwarded WinRM port on host |
| `ADMIN_PW` | `PizzaMan123!` | Administrator password (WinRM transport) |
| `JOE_USER` | `User_Joe` | Account winPEAS impersonates |
| `JOE_PW` | `VeryStrongPassword123!@#` | `JOE_USER` password |
| `WINPEAS_URL` | upstream latest | Download URL for `winPEASx64.exe` |
| `WINPEAS_SHA256` | — | Pin the cached binary hash |
| `WINPEAS_LOCAL` | — | Skip download, use a pre-fetched file |
| `WINPEAS_KEEP` | `0` | Leave `C:\Users\Public\winPEASx64.exe` + stdout on victim |
| `WINPEAS_HOST_FROM_GUEST` | `10.0.2.2` | Address the guest uses to pull the binary |

## How execution context is set up

| Step | Why |
|---|---|
| WinRM session as `Administrator` | `User_Joe` is not in `Administrators` or `Remote Management Users`, so direct WinRM auth is rejected (401). |
| HTTP staging server on a free local port | A 11 MiB `winPEASx64.exe` exceeds WinRM's default `MaxEnvelopeSize` (HTTP 413 on chunked base64 upload); the victim pulls via `Invoke-WebRequest`/`WebClient` to QEMU's host-from-guest gateway (`10.0.2.2`). |
| `secedit /configure` adds `SeBatchLogonRight` to `User_Joe` | Required for Task Scheduler `/RU User_Joe`; without it, the task registers but never runs (`Last Result 267011` SCHED_S_TASK_HAS_NOT_RUN). |
| One-shot scheduled task `SecretConWinPEASJoe` (`/RU User_Joe`, `/RL LIMITED`) | `PsExec -u` and `Start-Process -Credential` both fail with "Access is denied" from a WinRM remote shell because the network-logon token cannot assign a primary token for another user. Task Scheduler stores Joe's credential at registration time and starts the task with a local logon. |
| Output redirected to `C:\Users\Public\winpeas-joe-stdout.txt` | Public is world-writable; the worker pre-creates the file with an ACE granting Joe full control to avoid surprises. |
| Stdout fetched back via `Get-FileHash`/`ReadAllBytes` + base64 over WinRM | Reliable for the ~100 KiB report; the script also strips ANSI CSI sequences before printing. |

## Headline findings

The four observations that the AIE chain in
[walkthrough.md](walkthrough.md) hangs on are all visible from `User_Joe`'s
token, and winPEAS surfaces them in the first ~290 lines of output.

### UAC — bypass posture is wide open

```
====== UAC Status (T1548.002)
    ConsentPromptBehaviorAdmin: 0 - No prompting
    EnableLUA: 1
    LocalAccountTokenFilterPolicy:
    FilterAdministratorToken:
      [*] LocalAccountTokenFilterPolicy set to 0 and FilterAdministratorToken != 1.
      [-] Only the RID-500 local admin account can be used for lateral movement.
```

`ConsentPromptBehaviorAdmin = 0` is the load-bearing setting that lets
`msiexec` auto-elevate non-interactively under AIE — see the discussion in
`provisioning/powershell/bootstrap_cysvuln.ps1` (lines 222–235).
`EnableLUA = 1` keeps UAC formally "on" so the misconfiguration looks
realistic.

### AlwaysInstallElevated — both hives flagged

```
====== Checking AlwaysInstallElevated (T1548.002)
*  https://book.hacktricks.wiki/en/windows-hardening/windows-local-privilege-escalation/index.html#alwaysinstallelevated
    AlwaysInstallElevated set to 1 in HKLM!
    AlwaysInstallElevated set to 1 in HKCU!
```

Matches the audit produced by
[scripts/validate/audit_aie.py](../../scripts/validate/audit_aie.py) — once
both hives are set, an MSI installed by `User_Joe` runs as `SYSTEM`.

### Easy File Sharing Web Server — the foothold service

```
====== Services Information (T1543.003,T1574.011)
    Easy File Sharing Web Server(EFS Software, Inc. - Easy File Sharing Web Server)
        [C:\EFS Software\Easy File Sharing Web Server\fswsService.exe]
        - Autoload - No quotes and Space detected
    Possible DLL Hijacking in binary folder:
        C:\EFS Software\Easy File Sharing Web Server
        (Users [Allow: AppendData/CreateDirectories WriteData/CreateFiles])
```

The unquoted service path is a *secondary* privesc surface that the lab
doesn't intend to exercise — the canonical chain is EDB-42256 → AIE. Worth
calling out because winPEAS highlights it red and a player might be
distracted by it.

### User_Joe's token — confirms AIE is the real path

```
====== Users (T1087.001)
  Current user: User_Joe
  Current groups: Domain Users, Everyone, Users, Builtin\Remote Desktop Users,
                  Batch, Console Logon, Authenticated Users, This Organization,
                  Local account, Local, NTLM Authentication

    WIN-UB5Q52138VG\User_Joe: CysVuln low-priv operator
        |->Groups: Users,Remote Desktop Users
        |->Password: CanChange-NotExpi-NotReq

====== Current Token privileges (T1134.001)
    SeChangeNotifyPrivilege: SE_PRIVILEGE_ENABLED_BY_DEFAULT, SE_PRIVILEGE_ENABLED
    SeIncreaseWorkingSetPrivilege: DISABLED
```

No `SeImpersonate`, `SeAssignPrimaryToken`, `SeBackup`, `SeRestore`, or
`SeDebug`. The only enabled privilege is the default `SeChangeNotify`. This
rules out the usual token-abuse paths (PrintSpoofer / RoguePotato / juicy
potato) and steers the player back to the AIE registry settings.

Note: `Batch` shows up in the group list because the run-as-Joe transport
adds `SeBatchLogonRight` to Joe (see "How execution context is set up"
above). In a player-natural EFS callback shell that group is absent.

### Side observations

- AutoLogon entry: `DefaultUserName = Administrator` (no `DefaultPassword`
  populated — registry value is empty on this build).
- Sysmon driver loaded (`Sysinternals Sysmon - 15.20`, `SysmonDrv.sys`) and
  visible to non-admin users; Sysmon's config is pushed by
  `provisioning/powershell/assets/sysmonconfig.xml` and forwards to the
  Wazuh agent.
- `C:\Users\User_Joe\Desktop\Notes.txt` (player hint sheet with creds and
  the EDB-42256 link) is **not** in this run's output: it lives in
  the `filesinfo` / `fileanalysis` modules, which we skipped to keep the
  report under 100 KiB. Add `WINPEAS_LOCAL=… ./scripts/run-winpeas.sh ...`
  with a modified args set if you want to see it surfaced.

## Limitations

- Run as `User_Joe`, not via the EFS callback shell. Findings that depend
  on a process tree inside `fswsService.exe` (e.g. inherited handles) will
  not appear here.
- Domain / AD-style checks are empty — this is a workgroup box
  (`PartOfDomain: False`, `Tenant is NOT Azure AD Joined`).
- The Task Scheduler harness adds `SeBatchLogonRight` to `User_Joe` to be
  able to launch the task. That right is *not* present on a fresh box; a
  player landing via EFS would not see it in their token. The right is
  not revoked by the script.
- `fileanalysis`, `filesinfo`, `networkinfo`, `windowscreds`, and
  `browserinfo` modules are skipped by the default invocation — re-run
  with `WINPEAS_LOCAL=… ./scripts/run-winpeas.sh ...` after editing
  `WINPEAS_ARGS` in
  [scripts/validate/run_winpeas_as_joe.py](../../scripts/validate/run_winpeas_as_joe.py)
  to capture them.

## Cross-references

- [docs/cysvulnserver/walkthrough.md](walkthrough.md) — full chain
  (EFS → AIE → SYSTEM)
- [scripts/validate/audit_aie.py](../../scripts/validate/audit_aie.py) —
  programmatic equivalent of the AIE indicators above
- [provisioning/powershell/bootstrap_cysvuln.ps1](../../provisioning/powershell/bootstrap_cysvuln.ps1)
  — where the AIE + UAC keys are written at build time
