# ASREP — blue detection FAQ

Quick reference for defenders reviewing AS-REP roast telemetry from the `asrep` Wazuh agent group.

## Custom rules

| Rule | Level | Event | Meaning |
|---|---|---|---|
| `100700` | 9 | Security 4768 | AS-REQ for `enite@` with `preAuthType=0` |
| `100701` | 7 | Security 4769 | TGS-REQ for `enite@` with RC4 (`0x17`) |
| `100702` | 6 | Security 4624 | Interactive logon as `enite` after crack |

Rules live in `infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml` under group `secretcon,asrep,windows`.

## Expected fire order (attack path)

1. Attacker runs `GetNPUsers` — **`100700`** fires on the DC (no credentials required).
2. Optional follow-on Kerberos usage may produce **`100701`**.
3. After password recovery, logon as `enite` may produce **`100702`**.

## Automated QC

Local docker stack:

```bash
./scripts/wazuh-docker-up.sh
./scripts/run-local-asrep.sh
./scripts/validate-asrep-siem.sh
```

Stress campaign (10× reproducibility):

```bash
./scripts/observability/stress-campaign-asrep.sh --iterations 10
```

Inspect `artifacts/asrep/stress-campaign/<run-id>/campaign-summary.csv`:

| Column | Pass criteria |
|---|---|
| `hash_ok` | `1` every iteration |
| `fired_100700` | `1` every iteration |
| `fired_100701` | `1` when TGS follows roast in same window |

Per-iteration blue scorecards: `iter-N/blue-scorecard.json`.

## Dashboard search hints

- Filter rule ID: `100700`
- Filter username: `enite@SECRETCON.LOCAL`
- Event ID: `4768` with `preAuthType: 0`

## Agent group

Agents must be in group **`asrep`** to receive Security + Sysmon + PowerShell Operational subscriptions (`shared/asrep/agent.conf`).

Local QEMU guests dial manager **`10.0.3.2:1514`** (QEMU user-net gateway on `10.0.3.0/24`).

Proxmox range guests dial **`192.168.61.10`** (native manager on vmbr1).

## False positives

Decoy users (`jdoe`, `asmith`, etc.) do **not** have `DoesNotRequirePreAuth` — rule `100700` should only match `enite@`. Generic chain8 rule `100603` (any AS-REP) is separate; ASREP-specific detection is `100700`.
