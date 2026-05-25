# CysVuln baseline SIEM observability

Per-phase SIEM footprint for every step in
[walkthrough.md](walkthrough.md), produced by
[`scripts/observability/run-baseline-tour.sh`](../../scripts/observability/run-baseline-tour.sh).
Each phase runs sequentially against one boot (with `SECRETCON-PHASE-*`
sentinel markers for slicing), then Wazuh drains `alerts.json` and
`archives.json` for that window.

This document is the analyst-facing companion to two campaign-level
reports:

- [`blue-team-report.md`](blue-team-report.md) — 3x chain validator from
  the original SIEM capture loop (pre-rule-enrichment).
- [`stress-campaign-report.md`](stress-campaign-report.md) — 10x full
  walkthrough with the enriched rule pack (100507–100530) and dual
  red/blue scorecards; supersedes this single-run matrix for
  chain-coverage questions.

The baseline tour still owns the *per-tool* footprint question (what
does winPEAS alone look like, what does the chain look like with the
broken executor patched, etc.); the stress campaign answers the
*reproducibility* question (does it always look like that).

## Methodology

| Field | Value |
|---|---|
| Primary run ID | `baseline-20260525T053658Z` |
| Phase 04 redo (EFS logging enabled) | `baseline-20260525T152700Z-phase04redo` |
| Stack | `infrastructure/wazuh-docker/` 4.14.5, `logall_json=yes` |
| VM | `artifacts/cysvuln/local-qemu/cysvuln.qcow2`, reverted to `baseline` snapshot before tour |
| Agent group | `ews` (`shared/ews/agent.conf`: Sysmon, MSI/Operational, `aie-*.log`, EFS `log\*.txt`) |
| Noise floor | Phase 00: 60s idle → **12 alerts / 19 archives** (~0.2 alerts/s) |
| Artifacts | `artifacts/cysvuln/observability-baseline/<run-id>/` (gitignored) |

### Coverage matrix

Noise-adjusted counts subtract the phase-00 rate (~12 alerts/min) where
noted. SecretCon custom rules are `100501`–`100517`.

| Phase | Walkthrough step | Tool | Runtime | Alerts (raw) | Archives | SecretCon rules | Top alert rule | Exit | Analyst takeaway |
|---|---|---|---|---:|---:|---|---|---:|---|
| 00 | — | idle | 60s | 12 | 19 | — | `60106` (2) | 0 | Baseline OS noise: WinRM keepalive, syscheck, Security 4624 |
| 03 | Phase 3 | `verify-cysvuln.sh` | 0s | 10 | 14 | — | `60106` (2) | 1 | **Executor miss**: script defaulted to WinRM **5985**; QEMU forwards **15985**. Re-run with `WINRM_PORT=15985`. |
| 04 | Phase 4 | `check_efs69_response.py --mode exec` | 0s | 10 | 34 | — | `60106` (2) | 126 | **Executor miss** on first tour (`.py` not invoked via `python3`). Redo run: exit 0, see [Phase 04 redo](#phase-04-efs-foothold-redo). |
| 05 | Phase 5 | `read_flag.sh user` | 1s | 12 | 26 | — | `60106` (3) | 1 | First tour used Joe WinRM (401). Fixed helper reads flag as Administrator. |
| 06 | Phase 6 | `audit_aie.py` | 0s | 10 | 14 | — | `60106` (2) | 126 | Same `python3` executor miss as phase 04. |
| 06a | Phase 6a | `run-joe-tool.sh winpeas` | 45s | **72** | **161** | — | `92032` (13) | 0 | **Enumeration burst**: Sysmon EID 1 storm; no custom AIE rule. Tool stdout confirms HKLM AIE. |
| 06b | Phase 6b | `run-joe-tool.sh sharpup` | 17s | **97** | **129** | — | `23505` (22) | 0 | Faster than winPEAS; PowerShell/script-block noise (`23505`). SharpUp stdout: `HKLM: 1` for Always Install Elevated. |
| 07 | Phase 7 | `validate-cysvuln-aie-joe.sh` | 63s | **164** | **380** | **`100510`, `100512`** | `67028` (25) | 0 | **Only phase that fires SecretCon privesc rules.** AIE elevation receipt captured. |
| 08 | Phase 8 | `read_flag.sh root` | 2s | 16 | 22 | — | `60106` (3) | 0 | Post-privesc admin read; no flag token in SIEM (file content not logged). |

## Phase-by-phase observations

### Phase 00 — noise floor

Twelve alerts in 60 seconds, dominated by Wazuh default WinRM / logon
decoders (`60106`, `60137`, `67028`). Archives include syscheck and
agent keepalive traffic. Use this rate when interpreting later phases:
anything under ~15 alerts in a short phase is mostly background.

### Phase 03 — configuration smoke

The smoke script failed immediately because the orchestrator did not
export `WINRM_PORT=15985`. The SIEM slice is indistinguishable from
noise. **Fix applied** in `run-baseline-tour.sh` for future runs.

### Phase 04 — EFS foothold (first tour)

No exploit traffic reached the SIEM: the phase never ran
(`Permission denied` on direct `.py` invocation). Archives count (34)
is slightly above noise from overlapping windows only.

### Phase 04 — EFS foothold (redo)

After enabling EFS HTTP logging (`Savelog=1` in `option.ini`) and
subscribing `C:\EFS Software\Easy File Sharing Web Server\log\*.txt` in
`agent.conf`, a dedicated phase-04 re-run produced actionable telemetry:

| Signal | Source | In alerts? | Notes |
|---|---|---|---|
| Malformed EFS access line | `20260525.txt` via Wazuh syslog tail | archives only | Line shape: `[25/May/2026:15:26:53 - -] "" - - "" "-"` — parser did not match rule `100506` |
| `fswsService.exe` crash | Application EID 1000 | **`60602` (level 9)** | `Exception code: 0xc0000005` after exec stager — exploit triggered memory corruption |
| WerFault child of fsws | Sysmon EID 1 | archives (sub-threshold) | `ParentImage: ...\fswsService.exe`, user `User_Joe` |
| Inbound TCP/80 to fsws | Sysmon EID 3 | no | Rule `100503` still not populated — SwiftOnSecurity network filter gap |
| SecretCon `100506` | EFS log regex | no | Regex expects W3C `METHOD uri`; actual log format differs |

**Analyst pivot:** search archives for `location` containing `EFS Software`
or `full_log` matching `fswsService.exe` + `c0000005`. The crash event
is a stronger foothold indicator than HTTP access lines in this lab.

### Phase 05 — user flag

Reading `user.txt` via Administrator WinRM produces a small alert bump
(~12) with no SecretCon rules. Flag **content** does not appear in
Sysmon or Application logs — only the PowerShell/WinRM wrapper (`92052`,
`92032`). Proof in SIEM is *access to the path*, not the token string.

### Phase 06 — AIE registry audit

`audit_aie.py` did not run on the first tour (executor). When it runs,
expect registry-query activity; custom rule `100505` fires on Sysmon EID
13 **writes**, not reads, so HKLM/HKCU AIE **reads** remain invisible
unless Sysmon config adds `QueryValue` for those keys.

### Phase 06a — winPEAS

**Tool output (ground truth):**

- `AlwaysInstallElevated set to 1 in HKLM!` (HKCU line not in captured stdout snippet; full log under `phase-06a-winpeas/stdout.log`)
- Unquoted service paths, OMNS race probe, modifiable services listed

**SIEM footprint (72 alerts / 161 archives in 45s):**

| Category | Rules / EIDs | Count (approx) | Detection value |
|---|---|---:|---|
| Suspicious cmd.exe | `92032` | 13 | Medium — generic |
| Encoded PowerShell | `92052` | 10 | Medium — PsExec staging noise |
| WinRM / logon | `60106`, `60137`, `67028` | 10 each | Low — baseline |
| winPEAS process | Sysmon EID 1, image `winPEASx64.exe` | 3 archive rows | **High** — name the tool |
| AIE registry read | — | 0 | **Miss** — no Sysmon EID 13 read |

winPEAS is the loudest enumeration phase short of privesc itself. An
analyst agent should grep archives for `winPEAS` / `PEAS` and correlate
with subsequent `100510`/`100512` within 5–10 minutes.

### Phase 06b — SharpUp

**Tool output:**

```
=== Always Install Elevated ===
	HKLM: 1
```

(Modifiable-service checks threw exceptions — see [sharpup.md](sharpup.md).)

**SIEM footprint (97 alerts / 129 archives in 17s):**

| Category | Rules | Count | Notes |
|---|---|---:|---|
| PowerShell / script block | `23505` | 22 | Dominates this phase |
| Same cmd/WinRM noise as winPEAS | `92032`, `92052`, `60106` | ~10 each | |
| SharpUp process | Sysmon EID 1, `SharpUp.exe` | 2 archive rows | Tool attribution |

SharpUp is faster and noisier per second than winPEAS on rule `23505`.
Neither enumeration tool triggers SecretCon custom rules today.

### Phase 07 — privilege escalation (AIE MSI)

The diagnostic phase. Custom rules that fired:

| Time (UTC) | Rule | Level | Signal |
|---|---|---:|---|
| `2026-05-25T05:41:51.993Z` | **100510** | 10 | `msiexec /quiet /norestart /i C:\Users\Public\aie-validation-payload.msi` — integrity **Medium**, parent `cmd.exe` |
| `2026-05-25T05:41:52.024Z` | **100512** | 13 | `cmd.exe /c copy ...\root.txt C:\Users\Public\aie-flag.txt` — integrity **System**, parent **`msiexec.exe`** |

164 alerts / 380 archives in 63s. Most volume is validator staging
(`67028`, `92052`, `92032`). The two SecretCon rows above are the
smoking gun for blue-team proof.

Rule `100511` (cmd child of msiexec) is suppressed in favor of `100512`
(higher level) under Wazuh's highest-level-only semantics — same as the
[blue-team-report](blue-team-report.md) loop analysis.

### Phase 08 — root flag

Short admin read of `root.txt`: 16 alerts, no SecretCon rules, no flag
token in telemetry. Pair with phase 07 `100512` (copy to `aie-flag.txt`)
for end-to-end proof chain.

## Cross-phase analyst playbook

```bash
RUN=artifacts/cysvuln/observability-baseline/baseline-20260525T053658Z

# 1. Privesc receipt (phase 07)
jq -c 'select(.rule.id|tostring|test("^10051[012]$"))' \
  $RUN/phase-07-privesc/alerts.json

# 2. Enumeration tools
jq -c 'select(.data.win.eventdata.image//""|test("(?i)(winpeas|sharpup)"))' \
  $RUN/phase-06a-winpeas/archives.json $RUN/phase-06b-sharpup/archives.json

# 3. EFS crash / app log (phase 04 redo)
REDO=artifacts/cysvuln/observability-baseline/baseline-20260525T152700Z-phase04redo
jq -c 'select(.location//""|test("EFS Software") or (.full_log//""|test("fswsService")))' \
  $REDO/phase-04-foothold/archives.json

# 4. Sentinel markers (slice boundaries)
jq -c 'select(.data.win.eventdata.commandLine//""|test("SECRETCON-PHASE"))' \
  $RUN/phase-*/archives.json
```

## Gaps and recommendations

1. **Executor hygiene** — export `WINRM_PORT`, invoke `.py` via `python3`
   (fixed in orchestrator for phases 03–06).
2. **EFS HTTP log rule `100506`** — tune regex to match actual
   `YYYYMMDD.txt` line format from EFS 6.9 (currently archives-only).
3. **EFS foothold without crash** — add rule on Application EID 1000 +
   `fswsService.exe` as composite foothold signal (observed in redo).
4. **Enumeration → privesc correlation** — velocity rule: `winPEAS` or
   `SharpUp` image followed by `100510` within 15 minutes.
5. **AIE registry reads** — Sysmon config or dedicated audit script
   output forwarded as syslog if HKCU/HKLM reads must appear in SIEM.

## Reproducibility

```bash
./scripts/wazuh-docker-up.sh
qemu-img snapshot -a baseline artifacts/cysvuln/local-qemu/cysvuln.qcow2
./scripts/run-local-cysvuln.sh artifacts/cysvuln/local-qemu/cysvuln.qcow2
# wait for agent active
./scripts/observability/run-baseline-tour.sh --target 127.0.0.1
```

Phase 04 only (after EFS logging enabled on the guest):

```bash
./scripts/observability/run-baseline-tour.sh \
  --run-id baseline-$(date -u +%Y%m%dT%H%M%SZ)-phase04redo \
  --skip-phases 00,03,05,06,06a,06b,07,08
```

## Cross-references

- Orchestrator: [`scripts/observability/run-baseline-tour.sh`](../../scripts/observability/run-baseline-tour.sh)
- Stress-test report: [blue-team-report.md](blue-team-report.md)
- winPEAS FAQ: [winpeas.md](winpeas.md)
- SharpUp FAQ: [sharpup.md](sharpup.md)
- EFS log ingest: [`shared/ews/agent.conf`](../../infrastructure/wazuh-docker/config/wazuh_cluster/shared/ews/agent.conf), rule `100506` in [`local_rules.xml`](../../infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml)
- Dataset export / Proxmox replay: [../runbooks/wazuh-dataset-export-and-replay.md](../runbooks/wazuh-dataset-export-and-replay.md)
