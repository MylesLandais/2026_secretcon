# CysVulnServer

Windows Server 2016 privilege-escalation challenge for the SecretCon range.

| Field | Value |
|---|---|
| OS | Windows Server 2016 |
| Difficulty | Easy / intermediate |
| CWE | CWE-269 — AlwaysInstallElevated misconfiguration |
| Flag 1 | `C:\Users\User_Joe\Desktop\user.txt` (foothold) |
| Flag 2 | `C:\Users\Administrator\Desktop\root.txt` (SYSTEM) |

## Chain summary

1. **Foothold** — Unauthenticated EDB-42256 against Easy File Sharing Web Server 6.9 on HTTP/80. Service runs as `User_Joe`.
2. **Privesc** — `AlwaysInstallElevated` (HKLM + HKCU) plus UAC bypass keys allow silent `msiexec` elevation to SYSTEM.

Player walkthrough: [walkthrough.md](walkthrough.md)

Deploy runbooks: [deploy-cysvuln-multi-hypervisor.md](../runbooks/deploy-cysvuln-multi-hypervisor.md), [deploy-cysvulnserver.md](../runbooks/deploy-cysvulnserver.md)

## Prerequisites (attacker host)

```bash
nix develop
./scripts/check-cysvuln-tooling.sh --default
```

Optional Kali-parity tooling (nmap, msfvenom, evil-winrm):

```bash
nix develop .#kali
./scripts/check-cysvuln-tooling.sh --kali
```

Heavy packages live in [kali.nix](../../kali.nix) — not in the default dev shell.

## Build (local QEMU)

Required inputs: [docs/windows-image-inputs.md](../windows-image-inputs.md)

```bash
./scripts/stage-cysvuln-iso.sh /path/to/Windows_Server_2016_*.ISO
./scripts/fetch-iso.sh server-2016 <url>   # pin sha256 after first good download
./scripts/fetch-cysvuln-artifacts.sh
```

Build (recommended local path):

```bash
export SECRETCON_USER_FLAG='flag{cysvuln-user-local-test}'
export SECRETCON_ROOT_FLAG='flag{cysvuln-root-local-test}'
./scripts/build-cysvuln-local.sh
```

Or via Nix (requires `CYSVULN_ISO_STORE` / impure ISO wiring):

```bash
nix develop
export SECRETCON_USER_FLAG='flag{cysvuln-user-local-test}'
export SECRETCON_ROOT_FLAG='flag{cysvuln-root-local-test}'
nix build .#cysvuln-local
```

Result: `./result/cysvuln.qcow2` (archived under `artifacts/cysvuln/local-qemu/`)

## End-to-end chain validation

### Tier 1 — Config smoke

```bash
WINRM_PORT=15985 ./scripts/verify-cysvuln.sh 127.0.0.1
python3 scripts/validate/audit_aie.py --target 127.0.0.1 --port 15985 \
  --user Administrator --password 'PizzaMan123!' --profile-user User_Joe
```

### Tier 2 — AIE with known User_Joe creds (agent gate)

Skips unauth EFS foothold; uses PsExec/RDP to run `msiexec` in an interactive Joe session:

```bash
./scripts/run-local-cysvuln.sh          # forwards 18080, 15985, 13389 (RDP)
./scripts/validate-cysvuln-aie-joe.sh 127.0.0.1
```

Log: `artifacts/cysvuln/validation-aie-joe.log`

Captured output (2026-05-24 local QEMU, `flag{cysvuln-root-local-test}`):

```
===== validate-cysvuln-aie-joe =====
  5 pass / 0 fail

===== root flag cross-check =====
aie-flag: flag{cysvuln-root-local-test}
root.txt: flag{cysvuln-root-local-test}
[+] PASS: root flag matches aie-flag.txt
```

Prep sets `DisableMSI=0` (required on Server 2016 RDP/terminal sessions) alongside AIE keys. The probe MSI is built per-user (`InstallScope=perUser`).

### Tier 3 — Full player chain

```bash
./scripts/validate-cysvuln-chain.sh 127.0.0.1
# or skip EFS and run Tier 2 only:
CYSVULN_SKIP_EFS=1 ./scripts/validate-cysvuln-chain.sh 127.0.0.1
```

EFS debug harness (after prep):

```bash
./scripts/validate/debug_efs_exploit.sh 127.0.0.1
```

Log: `artifacts/cysvuln/validation-chain.log`

Bootstrap deploys `option.ini` + `C:\vfolders\disk_d` so `/vfolder.ghp` is reachable. Prep re-stages artifacts and PsExec on live VMs until the image is rebuilt.

### Iteration loop

```bash
./scripts/build-cysvuln-local.sh          # after bootstrap changes
./scripts/run-local-cysvuln.sh
./scripts/validate-cysvuln-aie-joe.sh 127.0.0.1     # Tier 2 gate
CYSVULN_SKIP_EFS=1 ./scripts/validate-cysvuln-chain.sh 127.0.0.1
./scripts/validate-cysvuln-chain.sh 127.0.0.1       # full chain (EFS + AIE)
./scripts/validate/debug_efs_exploit.sh 127.0.0.1   # EFS golden tests
```

Captured smoke from a fresh 2026-05-24 build (`flag{cysvuln-user-local-test}` / `flag{cysvuln-root-local-test}`):

```
===== verify-cysvuln results =====
  9 pass / 0 fail
===== audit aie (User_Joe hive) =====
AIE chain response expected: True
```

The EFS USERID overflow → callback → `msiexec` step remains environment-sensitive; see `artifacts/cysvuln/validation-chain.log` for the latest full run.

Reuse an existing artifact:

```bash
ln -sf "$(readlink -f artifacts/cysvuln/local-qemu/cysvuln.qcow2)" result/cysvuln.qcow2
```

## Boot (local QEMU)

Default host forwards (override with env vars):

| Host | Guest | Service |
|---|---|---|
| `127.0.0.1:18080` | `:80` | EFS HTTP |
| `127.0.0.1:15985` | `:5985` | WinRM |
| `127.0.0.1:13389` | `:3389` | RDP (Tier 2 Joe session) |

```bash
./scripts/run-local-cysvuln.sh
./scripts/cysvuln-local-prep.sh 127.0.0.1   # after first boot if EFS is stopped
```

## Smoke validation

```bash
WINRM_PORT=15985 ./scripts/verify-cysvuln.sh 127.0.0.1
```

Expected: 9 pass / 0 fail (Wazuh check skipped without `WAZUH_API_PASSWORD`).

## Exposed services

| Port | Service | Banner / note |
|---|---|---|
| 80 | Easy File Sharing Web Server 6.9 | `Server: Easy File Sharing Web Server v6.9` |
| 5985 | WinRM | Microsoft HTTPAPI 2.0 |

## Credentials (intentional side door)

| Account | Password | Notes |
|---|---|---|
| `User_Joe` | `VeryStrongPassword123!@#` | Seeded on desktop in `Notes.txt` |
| `Administrator` | `PizzaMan123!` | Build / WinRM smoke only |

## Artifacts

- Packer: `infrastructure/packer/cysvuln/local-qemu-cysvuln.pkr.hcl`
- Bootstrap: `provisioning/powershell/bootstrap_cysvuln.ps1`
- Validation: `scripts/validate/`, `scripts/verify-cysvuln.sh`
