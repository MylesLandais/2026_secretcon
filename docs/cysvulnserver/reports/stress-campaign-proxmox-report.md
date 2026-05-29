# CysVuln Proxmox stress-campaign report

Mirror of [defend-faq-walkthrough.md](defend-faq-walkthrough.md) but for the
**Proxmox-hosted** rerun of the 10x stress campaign, not the local QEMU
loop. The blue FAQ documents the chain of telemetry that fires per
walkthrough phase. This report records how that same chain holds up when
the cysvuln box is provisioned natively on the SecretCon Proxmox node
(VMID `119`, vmbr0/192.168.60.x) and the alerts are received by the
production Wazuh manager (VMID `110`, vmbr1/192.168.61.10) rather than
the docker-compose stack on the workstation.

If a phase fires the same alert IDs in the same order on both
platforms, that's our portability proof. If it doesn't, this page is
where the deltas live.

## Status

- **2026-05-27 QA pass** (VMID **118**, vmbr0, DHCP **192.168.60.57**):
  - Live inventory: VMID **119** does not exist; **108** legacy stopped (reference only).
  - `qm rollback 118 baseline` + Tier-1 `verify-cysvuln.sh` via Proxmox SSH tunnel:
    **8 pass / 1 fail** (Wazuh agent lookup uses tunnel IP `127.0.0.1` — expected).
  - Administrator WinRM: **`packer`** on baseline (Packer `winrm_bootstrap` default); set
    `SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD` in `.env` before shared-admin converge.
  - `AGENT_GROUP=cysvuln ./scripts/proxmox/sync-wazuh-rules.sh` pushed
    `shared/cysvuln/agent.conf` (EFS log tail + Sysmon channels).
  - Ansible: [`ansible/playbooks/cysvuln.yml`](../../../ansible/playbooks/cysvuln.yml)
    telemetry tags + [`discover-proxmox-inventory-cysvuln.sh`](../../../scripts/proxmox/discover-proxmox-inventory-cysvuln.sh).
  - Stress rerun: `CYSVULN_PROXMOX_WINRM_TUNNEL=1 ADMIN_PW=packer
    ./scripts/observability/stress-campaign.sh --platform proxmox --vmid 118
    --ip 192.168.60.57 --iterations 1` — run
    **`stress-20260527T165437Z`**: both flags ✓, wall **1013s**, rules
    **`100506`** (foothold-exec) + **`100510`** (privesc); winPEAS/SharpUp rc=5
    (Sysmon allow-list gap unchanged).
  - EFS banner on wire: `Easy File Sharing Web Server v6.9`.
  - Wazuh manager sync: `AGENT_GROUP=cysvuln` (agent active gate still flaky on API).

- 2026-05-25 first attempt: Packer `proxmox-iso` build of VMID 119
  timed out at 32 min waiting for SSH on a never-bound 192.168.60.119.
  Root cause: `setstatic.ps1` ran during autounattend's `specialize`
  pass while the e1000 NIC was still `Status=Disconnected`, so the
  static IP was silently skipped. The race repeats deterministically on
  the 1c/2 GB build VM. Build VM was auto-destroyed by Packer on
  timeout; **VMID 108 (the legacy hand-built CysVulnServer) was never
  touched**.
- 2026-05-25 rewrite: bypassed Packer's all-in-one builder. New
  `scripts/proxmox/deploy-cysvuln.sh` xorrisos its own PROVISION CD
  (with `proxmox-static-ip.txt=DHCP`), `qm create`s VMID 119 with 4 GB
  RAM / 2 cores, lets Windows DHCP, and bootstraps via WinRM through an
  SSH local-forward (`127.0.0.1:15985 -> Proxmox -> 192.168.60.x:5985`).
- 2026-05-25 16:55-17:30 UTC: rewrite end-to-end:
  - DHCP lease: **192.168.60.55**, MAC `bc:24:11:0d:83:89`, hostname
    `WIN10-EWS`.
  - WinRM bootstrap (`scripts/proxmox/winrm_bootstrap.py`) uploaded
    `bootstrap_cysvuln.ps1` in 2 KB base64 chunks (cmd.exe 8191-char
    cap), then ran it. Bootstrap reported
    `Bootstrap complete. Both flags seeded, Defender disabled, AIE keys set.`
  - Wazuh agent didn't auto-enroll (manager required a known entry); we
    injected the existing manager-side key for `003 WIN10-EWS` into
    `client.keys` and restarted `WazuhSvc`.
  - Manager `agent_control -l` shows `ID: 003, Name: WIN10-EWS,
    IP: any, Active`; 92 / 300 last alerts originate from agent 003,
    with 32 Sysmon-provider events confirmed.
  - `qm snapshot 119 baseline` taken on the populated (post-bootstrap,
    enrolled) state; `qm rollback 119 baseline` will return to the
    Wazuh-active baseline at any time.
- 2026-05-26 02:48-03:04 UTC: VMID 119 destroyed; rebuilt on VMID 118
  with Desktop Experience SKU, 8000 MB / 1 core / `x86-64-v2-AES`,
  disk on `ide0`, boot order `ide0;ide2;net0`, `firewall=1`. Agent
  re-enrolled under the unique name **`WIN10-EWS-118`** (ID 007, group
  `ews`) to escape the `WIN10-EWS` key-conflict from VMIDs 108/109 (see
  [`proxmox-deploy-recon.md`](proxmox-deploy-recon.md#wazuh-agent-enrollment-fix)).
  First clean 1-iter campaign:
  `artifacts/cysvuln/stress-campaign/stress-20260526T024804Z/`. Both
  flags recovered (red ✓). Blue coverage is partial — see the parity
  matrix below and the Sysmon allow-list note that follows.

See [proxmox-deploy-recon.md](proxmox-deploy-recon.md) for the recon
notes that drove the rewrite, and [attack-faq-walkthrough.md](attack-faq-walkthrough.md)
for the attacker chain this report mirrors from the defender side.

## Range topology (Proxmox)

| Component             | VMID | Bridge | Address          | Notes                                  |
|-----------------------|------|--------|------------------|----------------------------------------|
| OPNsense (router)     | 100  | vmbr0/1| 192.168.60.254   | DHCP server for vmbr0                  |
| Wazuh manager         | 110  | vmbr1  | 192.168.61.10    | native install; sshd via `dadmin`      |
| CysVuln (legacy ref)  | 108  | vmbr0  | static .109      | hand-built; untouched by this campaign |
| CysVuln (this report) | 118  | vmbr0  | DHCP `.57`       | spun from `deploy-cysvuln.sh`; agent `WIN10-EWS-118` ID 007 |

## Per-platform parity matrix

The local-qemu numbers are pulled from the 10x run referenced in
`defend-faq-walkthrough.md` (`stress-20260525T*`). The Proxmox column is
the 2026-05-26 single-iteration shakedown
(`artifacts/cysvuln/stress-campaign/stress-20260526T024804Z/iter-1/`)
on VMID 118. Filling the full 10x column is gated on closing the
Sysmon allow-list gap noted below.

### Red team (attacker) — per phase exit code & alert volume

| Phase                          | Local QEMU 10x | Proxmox 1-iter (118) | Δ |
|--------------------------------|----------------|----------------------|---|
| 00 — noise                     | TBD            | rc=0, 17 alerts      |   |
| 03 — smoke                     | TBD            | rc=1, 29 alerts      | rc=1 is the verify script's expected non-fatal exit when the EFS service hasn't been probed yet. |
| 04a — foothold-callback        | TBD            | SKIPPED (no CB_LHOST)| n/a |
| 04b — foothold-exec            | TBD            | rc=0, 22 alerts      |   |
| 05 — user-flag                 | TBD            | rc=0, 28 alerts      |   |
| 06 — aie-audit                 | TBD            | rc=0, 34 alerts      |   |
| 06a — winPEAS                  | TBD            | rc=5, 39 alerts      | rc=5 from `run-joe-tool.sh winpeas` — Defender is disabled but the SwiftOnSecurity Sysmon config does not log `winPEAS*.exe`, so no Sysmon EID 1 receipt makes it to the manager. |
| 06b — SharpUp                  | TBD            | rc=5, 41 alerts      | same root cause as winPEAS. |
| 07 — privesc (AIE msiexec)     | TBD            | rc=1, 175 alerts     | rc=1 is `validate-cysvuln-aie-joe.sh`'s post-elevation cleanup exit; the chain itself completes. |
| 08 — root-flag                 | TBD            | rc=0, 28 alerts      |   |
| **wall time**                  | TBD            | **947s**             | well inside the 25-min budget. |
| **total alerts to manager**    | TBD            | **413**              |   |
| **user.txt + root.txt**        | TBD            | **both recovered ✓** | red track is green. |

### Blue team — SecretCon rule coverage (`100xxx`)

| Rule  | Description                                          | Local 10x | Proxmox 1-iter |
|-------|------------------------------------------------------|-----------|----------------|
| 100501 | `msiexec.exe /quiet` (AIE precondition)             | TBD       | 0 — superseded by 100510 in scorecard; the 100510 hit (same chain) also matches `if_group sysmon_event1` |
| 100502 | `cmd.exe copy …root.txt` (privesc receipt)          | TBD       | **0 — gap** (see below) |
| 100503 | Sysmon EID 3 inbound TCP/80 → `fswsService.exe`     | TBD       | **0 — gap** (Sysmon EID 3 entirely absent) |
| 100506 | EFS HTTP access log NCSA tail                       | TBD       | **0 — gap** (no `EFS Software\…\log\*.txt` events ingested) |
| 100507 | App-log EID 1000 `fswsService.exe` access violation | TBD       | **0 — gap** (EID 1000 never raised this iter) |
| 100508 | winPEAS executed                                    | TBD       | **0 — gap** (SwiftOnSecurity Sysmon allow-list — see below) |
| 100509 | SharpUp executed                                    | TBD       | **0 — gap** (same) |
| 100510 | `msiexec /quiet /i …` AIE chain                     | TBD       | **1 ✓**        |
| 100511 | `cmd.exe` child of `msiexec.exe`                    | TBD       | 0              |
| 100512 | `msiexec.exe` SYSTEM-integrity child                | TBD       | **0 — gap**    |
| 100520 | Sysmon EID 11 read of `user.txt`                    | TBD       | **0 — gap** (EID 11 reaches manager 36 times, none for user.txt path) |
| 100530 | `100508|100509` → `100510` correlation              | TBD       | 0 — requires 100508/100509 first; blocked by the gap above |
| 100711 | NTLM type-3 logon as local Administrator (bonus)    | TBD       | **53 ✓**       | not in the plan list; fires off the campaign's WinRM/SSH connectivity, not the chain. |

**Headline:** 1 of 7 explicitly-tracked SecretCon rules fired on
Proxmox; both flags recovered. The Sysmon-side telemetry IS reaching
the manager (141 `Microsoft-Windows-Sysmon` events in this iter,
across EIDs 1/11/13), but the chain-specific events the rules look
for are absent. This is consistent across every gap.

### Why the blue gaps exist

The agent on VMID 118 is correctly subscribed to
`Microsoft-Windows-Sysmon/Operational` via `shared/ews/agent.conf`
and the events flow — the `merged.mg` rendered on the box matches
the manager's source-of-truth. The gaps are entirely upstream of
Wazuh:

1. **SwiftOnSecurity Sysmon config has a tight EID 1 allow-list.**
   Of all process creates observed during the 947s iter,
   `Microsoft-Windows-Sysmon` EID 1 only logged three images:
   `cmd.exe`, `msiexec.exe`, `powershell.exe`. `winPEASx64.exe`,
   `SharpUp.exe`, `fswsService.exe`, and the privesc child shells
   never appear because the Sysmon config drops them at the kernel
   driver. That's why 100508 / 100509 / 100511 / 100512 / 100502 all
   come up empty.
2. **No Sysmon EID 3 (network connect) events** were ingested this
   iter. The SwiftOnSecurity config heavily restricts EID 3 by
   destination port / image, and `fswsService.exe` (the EFS web
   server) is not on its allow-list. 100503 cannot fire without
   tuning the Sysmon config to whitelist `fswsService.exe`.
3. **Sysmon EID 11 ingests 36 events but none target `user.txt`.**
   SwiftOnSecurity's `FileCreate` rules drop file reads on user
   desktops as low-signal noise. 100520 needs a manager-side
   complement (e.g. a Wazuh `localfile` audit subscription on the
   user desktop) or a custom Sysmon include for desktop flag files.
4. **EFS HTTP access log is empty.** No HTTP requests during this
   iter reached the EFS server with a request line that the EFS log
   formatter wrote to `log\YYYYMMDD.txt`. Either `Savelog=1` wasn't
   honored on this build (worth re-verifying bootstrap's `option.ini`
   patch) or the foothold-exec phase short-circuits before the
   request is logged. 100506 will fire as soon as one tailable line
   lands.

None of these are bugs in `local_rules.xml`. The two ways forward:

- **Recommended:** drop a SecretCon-tuned Sysmon config (Olaf
  Hartong's modular config + a CysVuln include that whitelists
  `winPEAS*`, `SharpUp*`, `fswsService.exe`, and desktop flag-file
  reads) into `provisioning/sysmon/` and have
  `Install-SecretConSysmon` install it instead of the stock
  SwiftOnSecurity config.
- Quicker but coarser: also fold a Wazuh `localfile`
  `<log_format>full_command</log_format>` block into
  `shared/ews/agent.conf` that polls
  `Get-Process winPEAS*,SharpUp* | Select-Object …` every 30s, so the
  presence/absence of the enum tools surfaces without needing Sysmon
  EID 1 at all.

Both are out of scope for the
[`reconcile_118_vs_108`](../../.cursor/plans/reconcile_118_vs_108,_validate_flags_+_wazuh_aaea0304.plan.md)
plan; this report captures the gap so the next planning pass picks
up an accurate baseline.

## Notable deltas (so far)

- **Bootstrap path**: on Proxmox the bootstrap is invoked **post-install
  over SSH** rather than embedded in Packer's `windows-shell` provisioner;
  Sysmon + Wazuh agent install order is otherwise identical.
- **Manager transport**: alerts land in `/var/ossec/logs/alerts/alerts.json`
  on the native manager and are drained over `ssh sudo cat` (via
  `scripts/wazuh-drain-alerts.sh --manager-ssh`) instead of `docker exec`.
- **Rules**: same `local_rules.xml` shipped by
  `scripts/proxmox/sync-wazuh-rules.sh`; no per-rule fork is expected.

## Where to look for evidence

- raw iter alerts: `artifacts/cysvuln/stress-campaign/<stamp>/iter-N/iter-alerts.jsonl`
- per-phase drains: `artifacts/cysvuln/stress-campaign/<stamp>/iter-N/phase-*/`
- red/blue scorecards: `…/iter-N/red-scorecard.json` + `blue-scorecard.json`
- campaign summary CSV: `…/campaign-summary.csv`
- VMID 118 baseline snapshot log: `artifacts/cysvuln/proxmox-deploy/baseline-118-final.log`

For the 2026-05-26 1-iter on VMID 118:
`artifacts/cysvuln/stress-campaign/stress-20260526T024804Z/`.

## Next steps

1. Tune the on-host Sysmon config to whitelist the SecretCon chain
   tooling (winPEAS, SharpUp, fswsService.exe, desktop flag-file
   reads) so the 7 SecretCon rules in the parity matrix can fire on
   Proxmox the way they do on local QEMU. Track as a follow-up;
   see [Why the blue gaps exist](#why-the-blue-gaps-exist) above.
2. Fold the `WIN10-EWS-${VMID}` agent-name convention into
   `bootstrap_cysvuln.ps1` so future rebuilds never collide with the
   stock `WIN10-EWS` registration used by VMIDs 108/109.
3. Run the full 10x rerun once (1) lands; fill the `Local QEMU 10x`
   column from `defend-faq-walkthrough.md` and re-populate the Proxmox
   10x column from the new run.
4. Sync any new rules back upstream if a Proxmox-only false negative
   surfaces once the chain telemetry actually flows.
