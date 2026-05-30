# EWS — defend FAQ walkthrough

Defender mirror of [attack-faq-walkthrough.md](attack-faq-walkthrough.md). How to prove VNC brute-force, registry tampering, and unquoted-service abuse from telemetry alone.

Manager: `192.168.61.10` (agent group `ews`). Custom rules in [`local_rules.xml`](../../infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml) group `secretcon,ews,windows`.

---

## TL;DR

- **Endpoint (Wazuh agent + Sysmon):** rules `100800`–`100807` cover VNC connection bursts, legacy `tvnserver.log` failures, registry reads/sets, exfil receipts, and velocity correlation.
- **LPE (unquoted `SecretConEwsSync`):** rules `100808`–`100809`, `100817`–`100819` cover FIM/Sysmon `EWS.exe` hijack, `sc.exe config` tamper, SYSTEM execution, and chain correlation. OPS webhook via `custom-ops-queue` integration — see [ops-challenge-reset.md](../runbooks/ops-challenge-reset.md).
- **Network (OPNsense Suricata + pf):** rules `100810`–`100816` cover brute-force detection, failed-auth-then-success correlation, and filterlog fallback on the SPAN mirror.
- **PCAP (Arkime):** successful RFB auth yields DES challenge/response for offline crack — does not replace endpoint proof of execution.

---

## Expected fire order (attack path)

1. Many TCP/5900 connections → **`100800`** (Sysmon EID 3 burst).
2. Failed auth lines in `tvnserver.log` → **`100801`**.
3. Registry query of TightVNC password key → **`100802`** / SACL **`100805`**.
4. Optional password SET → **`100803`**.
5. Exfil file `C:\Users\Public\vnc-pwd-dump.txt` → **`100804`** / hex receipt **`100806`**.
6. Velocity wrapper **`100807`** when burst precedes registry/exfil within 15 minutes.

Parallel NSM track (if mirror enabled):

- Suricata SID `2400001`/`2400002` → Wazuh **`100810`**/**`100811`**, correlated by **`100812`** for probe+failure confirmation.
- Suricata SID `2400003` → Wazuh **`100816`** for successful VNC auth; **`100813`** correlates failed auths followed by success from the same source.
- pf fallback remains **`100815`**.

---

## Rule reference (endpoint)

| Rule | Level | Source | Meaning |
|---|---|---|---|
| `100800` | 10 | Sysmon EID 3 | VNC connection burst to :5900 |
| `100801` | 8 | `tvnserver.log` | Authentication failure |
| `100802` | 8 | Sysmon / process | Registry read TightVNC Server key |
| `100803` | 10 | Registry SET | Password value change |
| `100804` | 9 | Sysmon EID 11 | `vnc-pwd-dump.txt` created |
| `100805` | 8 | Security 4663 | SACL audit on TightVNC key |
| `100806` | 12 | Custom log | Hex blob exfil receipt |
| `100807` | 13 | Correlation | Burst then tamper/exfil |

### Unquoted service path (LPE)

| Rule | Level | Source | Meaning |
|---|---|---|---|
| `100808` | 12 | Syscheck FIM | `EWS.exe` hijack payload added/changed |
| `100809` | 10 | Sysmon EID 11 | Same path file create |
| `100817` | 11 | Sysmon EID 1 | `sc.exe config SecretConEwsSync` |
| `100818` | 13 | Sysmon EID 1 | `EWS.exe` running as SYSTEM |
| `100819` | 14 | Correlation | Hijack drop then SYSTEM exec within 15 min |

Validate: `./scripts/validate/test-ews-lpe-clean.sh --target <IP>` (mutates VM). OPS reset: [ops-challenge-reset.md](../runbooks/ops-challenge-reset.md).

Agent local config: [`shared/ews/agent.conf`](../../infrastructure/wazuh-docker/config/wazuh_cluster/shared/ews/agent.conf) (logcollector paths, command tailer).

---

## Operator reproduction

Generate a fresh dataset (Proxmox campaign):

```bash
./scripts/observability/vnc-public-attack.sh --target 192.168.61.20
./scripts/wazuh-drain-alerts.sh --since-minutes 30
```

Full NSM pipeline (OPNsense + mirror + Arkime):

```bash
./scripts/observability/opnsense-vnc-challenge.sh
./scripts/validate/validate-opnsense-vnc-pipeline.sh
```

Synthetic round-trip proofs (no live VM):

```bash
./scripts/observability/vnc-wazuh-proof.sh
./scripts/observability/vnc-pcap-proof.sh
```

Documented in [scripts/observability/README.md](../../scripts/observability/README.md).

---

## Wireshark (local PCAP)

Canonical capture: [`targets/ews-vnc-pcap-forensics/vnc_auth.pcap`](../../targets/ews-vnc-pcap-forensics/vnc_auth.pcap).

```bash
./scripts/open-ews-vnc-pcap.sh
# or: nix shell nixpkgs#wireshark --command wireshark targets/ews-vnc-pcap-forensics/vnc_auth.pcap
```

Step-by-step display filters, finding the one successful `tcp.stream`, and
offline crack with `vnc-cred-tool.py`:
[vnc-pcap-wireshark-analysis.md](vnc-pcap-wireshark-analysis.md).

## Arkime pivot

Production viewer: `http://192.168.61.11:8005` (`crit-capture`, VMID 111).

```bash
./scripts/proxmox/verify-arkime-capture.sh
./scripts/proxmox/sync-arkime-pcap.sh artifacts/ews/latest/vnc_auth.pcap
```

Local docker stack: [infrastructure/arkime-docker/readme.md](../../infrastructure/arkime-docker/readme.md).

Query example: destination port 5900 sessions after a campaign run; export SPI for `vnc-cred-tool.py crack`.

---

## Scoring tie-in

Integrated campaign rubric: [defend-track-rubric.md](../campaign/defend-track-rubric.md) Category 2 (EWS lateral / VNC).

---

## Related runbooks

- [ews-vnc-adversary-emulation.md](../runbooks/ews-vnc-adversary-emulation.md) — artefact layout
- [opnsense-vnc-brute-analyst-challenge.md](../runbooks/opnsense-vnc-brute-analyst-challenge.md) — NSM track procedure
- [three-box-chain.md](../campaign/three-box-chain.md) — full chain observability rules `100710`–`100715`
