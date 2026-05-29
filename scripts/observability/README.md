# Observability scripts

Operator and acceptance-test harnesses for adversary emulation, SIEM drains, and synthetic proofs.

## Production paths

| Script | Purpose |
|--------|---------|
| `vnc-adversary-emulation.sh` | Live VNC brute + WinRM exfil + optional capture |
| `vnc-public-attack.sh` | Orchestrator: emulation → analyze → validate → INDEX |
| `opnsense-vnc-challenge.sh` | Full NSM track (mirror + Suricata + Arkime) |
| `ews-asrep-pivot.sh` | EWS → DC AS-REP pivot campaign demo |
| `stress-campaign*.sh` | Repeatable SIEM capture loops |

## Synthetic proofs (offline)

These validate crypto/log pipelines **without** a live VM:

| Script | Proves |
|--------|--------|
| `vnc-wazuh-proof.sh` | Wazuh rule `100806` round-trip via logtest |
| `vnc-pcap-proof.sh` | PCAP → `vnc-cred-tool.py crack` → `FELDTECH_VNC` |

Linked from [docs/ews/defend-faq-walkthrough.md](../../docs/ews/defend-faq-walkthrough.md).

## Shared libraries

- [`scripts/lib/vnc-lab.sh`](../lib/vnc-lab.sh) — wordlist + port defaults
- [`scripts/lib/stress-campaign.sh`](../lib/stress-campaign.sh) — campaign logging scaffold
- [`scripts/lib/evidence-harness.sh`](../lib/evidence-harness.sh) — numbered assertions
