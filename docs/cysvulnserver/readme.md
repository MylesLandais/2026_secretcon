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

## Challenge components

Every SecretCon box ships four pieces. CysVuln's are:

| Component | Document |
|---|---|
| Attack walkthrough (red FAQ) | [walkthrough.md](walkthrough.md) |
| Defender walkthrough (blue FAQ) | [blue-faq-walkthrough.md](blue-faq-walkthrough.md) |
| Tool knowledge | [winpeas.md](winpeas.md), [sharpup.md](sharpup.md), [msfvenom.md](msfvenom.md) |
| Infrastructure deployment | this file + [`infrastructure/wazuh-docker/readme.md`](../../infrastructure/wazuh-docker/readme.md) |
| AI agent skill (bonus) | [`.claude/skills/wazuh/SKILL.md`](../../.claude/skills/wazuh/SKILL.md) |

Deploy runbooks: [deploy-cysvuln-multi-hypervisor.md](../runbooks/deploy-cysvuln-multi-hypervisor.md), [deploy-cysvulnserver.md](../runbooks/deploy-cysvulnserver.md).

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

### Manual enumeration — winPEAS as User_Joe

```bash
./scripts/run-joe-tool.sh winpeas 127.0.0.1
```

Captures `winPEASx64.exe` output (run as `User_Joe` via a one-shot
scheduled task driven from the Administrator WinRM session) and tees it
to `artifacts/cysvuln/winpeas-joe-<timestamp>.log`. Curated findings and
the headline AlwaysInstallElevated / UAC indicators are written up in
[winpeas.md](winpeas.md).

### Manual enumeration — SharpUp as User_Joe

```bash
./scripts/fetch-cysvuln-artifacts.sh   # warns if SharpUp.exe absent
./scripts/run-joe-tool.sh sharpup 127.0.0.1
```

GhostPack's focused C# privesc auditor. Same execution harness as the
winPEAS runner (shared via `scripts/validate/joe_task_runner.py`).
Binary is vendored at `infrastructure/artifacts/cysvuln/SharpUp.exe` —
build instructions are in [sharpup.md](sharpup.md), which also has the
curated findings (AIE, AutoLogons, Unattend.xml, unquoted service
paths).

### Manual privesc — msfvenom MSI as User_Joe

```bash
nix develop .#kali
./scripts/run-joe-tool.sh msfvenom-aie 127.0.0.1
```

Builds an `windows/exec` MSI with stock msfvenom, stages it on the
victim, and triggers it under an interactive `User_Joe` session via
PsExec/RDP (the `msiexec` 1601 interactive-logon constraint is
documented in walkthrough Phase 7). Confirms `AlwaysInstallElevated`
end-to-end by copying SYSTEM-only `root.txt` into a public path that
User_Joe can read. Full curated writeup in [msfvenom.md](msfvenom.md).

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

## SIEM capture loop (blue team observability)

For the analyst tier — randomize flags, rebuild the VM with the Wazuh
agent pointed at a local-lab docker SIEM, then run the full validation
chain three times under snapshot-restore and drain alerts for analyst
review:

```bash
./scripts/observability-loop.sh         # green-field run (~75-90 min)
./scripts/observability-loop.sh --skip-rebuild --skip-baseline  # re-iter
```

The orchestrator writes one directory per run under
`artifacts/cysvuln/observability-loop/<run-id>/` (gitignored), with
per-iteration `alerts.json`, raw `archives.json`, a curated
`msiexec-timeline.json` (the single artifact a downstream analyst LLM
should read first), `summary.json`, and a chain stdout log. A top-level
`summary.csv` and `raw-notes.md` seed the canonical defender FAQ at
[blue-faq-walkthrough.md](blue-faq-walkthrough.md).

Stack lives under [infrastructure/wazuh-docker/](../../infrastructure/wazuh-docker/);
bring up / tear down with `./scripts/wazuh-docker-up.sh` /
`./scripts/wazuh-docker-down.sh`. Dashboard: <https://127.0.0.1:1443>.

### Export and replay the dataset

A completed loop run can be turned into a portable analyst dataset
(alerts + every decoded event + manager config + agent metadata +
tamper-evident manifest) and optionally replayed into the production
Wazuh manager on Proxmox:

```bash
./scripts/wazuh-export-dataset.sh --run-id <run-id> --window-from-loop --tarball
./scripts/wazuh-replay-to-proxmox.sh \
    --dataset artifacts/cysvuln/observability-loop/<run-id>/dataset \
    --target 192.168.61.10:514 --source archives
```

Full procedure (including the Proxmox-side syslog `<remote>` block):
[../runbooks/wazuh-dataset-export-and-replay.md](../runbooks/wazuh-dataset-export-and-replay.md).

### Baseline observability tour (per-phase SIEM footprint)

Maps each walkthrough step (including winPEAS, SharpUp, EFS foothold)
to drained Wazuh alerts/archives so analyst agents know what each action
looks like in isolation:

```bash
./scripts/observability/run-baseline-tour.sh --target 127.0.0.1
```

Artifacts under `artifacts/cysvuln/observability-baseline/<run-id>/`.
Per-tool footprint analysis is folded into
[blue-faq-walkthrough.md](blue-faq-walkthrough.md).

### 10x stress campaign (red + blue scorecards)

Runs the full walkthrough under snapshot-restore for N iterations (default
10), with the enriched rule pack (100507-100530) and dual scorecards so
both CTF and SOC teams read the same dataset:

```bash
./scripts/observability/stress-campaign.sh --iterations 10
./scripts/wazuh-export-dataset.sh \
    --run-id <campaign-id> \
    --source-dir artifacts/cysvuln/stress-campaign/<campaign-id> \
    --window-from-loop --tarball
```

Artifacts under `artifacts/cysvuln/stress-campaign/<run-id>/`. The latest
campaign hit 10/10 on both flags and 10/10 on the four AIE-leg rules;
the dual scorecards and reproducibility analysis live in
[blue-faq-walkthrough.md](blue-faq-walkthrough.md).

## Artifacts

- Packer: `infrastructure/packer/cysvuln/local-qemu-cysvuln.pkr.hcl`
- Bootstrap: `provisioning/powershell/bootstrap_cysvuln.ps1`
- Validation: `scripts/validate/`, `scripts/verify-cysvuln.sh`
- SIEM stack: `infrastructure/wazuh-docker/`
- Observability loop: `scripts/observability-loop.sh`, `scripts/observability/`
- Baseline tour: `scripts/observability/run-baseline-tour.sh`, [blue-faq-walkthrough.md](blue-faq-walkthrough.md)
- Stress campaign: `scripts/observability/stress-campaign.sh`, [blue-faq-walkthrough.md](blue-faq-walkthrough.md)
