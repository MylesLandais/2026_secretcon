# ASREP stress campaign — local QEMU report template

Fill this in after a green `./scripts/observability/stress-campaign-asrep.sh` run.

## Run metadata

| Field | Value |
|---|---|
| Run ID | `asrep-stress-YYYYMMDDTHHMMSSZ` |
| Platform | local-qemu |
| Iterations | 10 |
| QCOW | `artifacts/asrep/local-qemu/asrep.qcow2` |
| Snapshot | `baseline` |
| Wazuh manager | docker @ `127.0.0.1` (guest gateway `10.0.3.2`) |

## Red scorecard (attack)

Source: `artifacts/asrep/stress-campaign/<run-id>/campaign-summary.csv`

| Metric | Target |
|---|---|
| `hash_ok` | 10/10 |
| `crack_ok` | 10/10 (when wordlist present) |

## Blue scorecard (detection)

| Metric | Target |
|---|---|
| `fired_100700` | 10/10 |
| `fired_100701` | ≥ 8/10 (timing window dependent) |

## Example CSV header

```
iter,hash_ok,crack_ok,fired_100700,fired_100701,alert_count,secretcon_rules
```

## Notes

- Rebuild qcow2 with `WAZUH_MANAGER=10.0.3.2` before first campaign if agent enrollment fails.
- Run `./scripts/wazuh-docker-up.sh` to sync `asrep` agent group + rules (duplicate chain8 block removed).
- If `fired_100700=0`, check `iter-N/alerts.json` and guest `C:\Program Files (x86)\ossec-agent\ossec.log`.

## Next steps

- Fold fire rates into [defend-faq-walkthrough.md](defend-faq-walkthrough.md)
- Proxmox replay: `./scripts/proxmox/deploy-asrep.sh` + stress campaign with `--platform proxmox` (future)
