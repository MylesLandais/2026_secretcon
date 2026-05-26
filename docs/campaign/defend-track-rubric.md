# Defend track scoring rubric (three-box chain)

Blue-team goals for the integrated **CysVuln → EWS → secretcon.local DC** campaign. Evidence is expected in Wazuh (manager `192.168.61.10`, agent groups `cysvuln`, `ews`, `asrep`). PCAP bonuses require live capture on `crit-capture` (VMID 111, deferred) or replay corpora under `artifacts/`.

Cross-links:

- CysVuln detections: [docs/cysvulnserver/blue-faq-walkthrough.md](../cysvulnserver/blue-faq-walkthrough.md)
- ASREP detections: [docs/asrep/blue-detection-faq.md](../asrep/blue-detection-faq.md)
- Operator runbook: [three-box-chain.md](three-box-chain.md)

## Category 1 — CysVuln foothold (10 pts each artifact)

| Goal | Correct evidence | Wazuh rule |
|---|---|---|
| AIE MSI install | Sysmon Event 1: `msiexec.exe` with `/quiet /i` and AIE payload path | `100510` |
| MSI operational channel | Microsoft-Windows-MSI/Operational events matching rollback/install pattern | `100516`, `100515` |
| Command line / path | `Image` or `CommandLine` field showing MSI path under `C:\Users\Public\` or similar | analyst query on `100510` |

**Not valid for this chain:** MSI Event ID 1033/1034 (wrong channel for the CysVuln AIE path).

## Category 2 — Lateral movement CysVuln → EWS (15 + 20 bonus)

| Goal | Points | Evidence | Wazuh rule |
|---|---|---|---|
| Pass-the-Hash to EWS | 15 | Security **4624** logon type **3**, **NTLM**, target user **Administrator** on EWS agent | `100711` |
| LSASS access on CysVuln | 20 | Sysmon Event **10** — non-system process → `lsass.exe` | `100710` |
| Chain correlation | bonus | AIE (`100510`) then lsass (`100710`) within 30m | `100712` |

**Note:** Rule `100514` (msiexec → lsass) is a deviation detector for meterpreter-class payloads, not the expected secretsdump path.

## Category 3 — ASREP roast EWS → DC (20 + 25 bonus)

| Goal | Points | Evidence | Wazuh rule |
|---|---|---|---|
| AS-REP for `enite` | 20 | DC Security **4768**, `preAuthType 0`, target `enite@` | `100700` |
| Post-roast Kerberos | bonus | **4769** RC4 TGS for `enite` | `100701` |
| PCAP AS-REQ without PA-DATA | 25 | Kerberos AS-REQ to TCP/88 without pre-auth (Arkime / offline PCAP) | conditional |

Chain correlation: PtH (`100711`) then roast (`100700`) within 60m → `100713`.

## Category 4 — Domain compromise (25 pts)

| Goal | Points | Evidence | Wazuh rule |
|---|---|---|---|
| `enite` authentication | 25 | Security **4624** as `enite` (type 3 or 10) | `100702`, `100715` |
| DCSync (optional) | bonus | **4662** with replication GUIDs if players go beyond flag read | analyst query |
| DA membership seed | audit | **4728** member added to Domain Admins (bootstrap baseline) | `100714` |

## Scoring totals

| Track | Max (without PCAP bonus) |
|---|---|
| Red (six flags) | 105 pts (10+20+10+20+15+30) |
| Blue (categories 1–4) | 10×3 + 15 + 20 + 20 + 25 = **90** (+ PCAP bonus 25) |

## Validation commands

```bash
./scripts/wazuh-drain-alerts.sh --since <start> --until <end> --out-dir /tmp/chain-drain
jq -r '.rule.id' /tmp/chain-drain/alerts.json | sort -u | grep -E '^100(510|7[0-1][0-5])$'

./scripts/validate-three-box-chain.sh --siem
./scripts/observability/stress-campaign-chain.sh --iterations 5 --siem
```

## Arkime / PCAP note

Live vmbr1 capture on VMID 111 is **not deployed** in this pass. PCAP bonus goals should be scored from:

- Local replay: [infrastructure/arkime-docker/](../../infrastructure/arkime-docker/)
- Exported corpora under `artifacts/` after adversary emulation runs

Mark PCAP bonuses as **conditional** until `crit-capture` is live.
