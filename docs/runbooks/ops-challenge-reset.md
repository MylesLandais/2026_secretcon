# OPS challenge reset runbook

Operator workflow when Wazuh **custom-ops-queue** integration fires on exploit-path rules.

## Alert → action matrix

| Rule | VM | Meaning | Soft reset | Hard reset |
|------|-----|---------|------------|------------|
| 100808 / 100809 | EWS | `EWS.exe` hijack planted | `ews_lpe_reset` tag | `qm rollback 109 baseline` |
| 100818 / 100819 | EWS | SYSTEM ran hijack payload | `ews_lpe_reset` tag | snapshot rollback |
| 100507 | CysVuln | `fswsService` crash (exec stager) | `watchdog_agent` auto / prep script | snapshot rollback |
| 100821 | CysVuln | `fswsService` stopped | `watchdog_agent` / converge | snapshot rollback |
| 100822 | CysVuln | EFS foothold → AIE privesc chain | optional full converge | `qm rollback 119 baseline` |
| 100512 | CysVuln | AIE privesc receipt | verify flags, schedule reset | snapshot rollback |

## Soft reset commands

```bash
# EWS — remove hijack, restart SecretConEwsSync + VNC, reseed user flag
(cd ansible && ansible-playbook playbooks/ews.yml -l ews-prod --tags ews_lpe_reset)

# CysVuln — deploy/restart EFS watchdog + telemetry
./scripts/proxmox/converge-cysvuln.sh --cysvuln-host <IP>
```

## Hard reset (Proxmox)

```bash
# EWS VMID 109 (prefers ctf-baseline, falls back to baseline)
./scripts/host/ctf-baseline-reset.sh --dry-run --vmid 109
CTF_SCHEDULED_RESET_ENABLED=1 ./scripts/host/ctf-baseline-reset.sh --vmid 109
# or: qm rollback 109 ctf-baseline && qm start 109
./scripts/proxmox/converge-ews.sh --ews-host <IP>

# CysVuln VMID 119
CTF_SCHEDULED_RESET_ENABLED=1 ./scripts/host/ctf-baseline-reset.sh --vmid 119
./scripts/proxmox/converge-cysvuln.sh --cysvuln-host <IP>
```

## Guest unhealthy marker (Layer 4)

Watchdog writes `C:\secretcon\watchdog-unhealthy.marker` (no hypervisor secrets on guest).

```bash
./scripts/host/challenge-orchestrator.sh --once
./scripts/host/challenge-failover.sh --to standby   # operator
./scripts/host/challenge-failover.sh --to primary   # rollback
```

## OPS webhook configuration

Set in `.env` (never commit real URLs with secrets):

```bash
WAZUH_OPS_WEBHOOK_URL=https://hooks.example.com/secretcon-ops
WAZUH_OPS_AUTO_RESET=0   # keep 0 — reset is operator-driven
```

Local docker stack: edit `hook_url` in `infrastructure/wazuh-docker/config/wazuh_cluster/wazuh_manager.conf` integration block or inject at deploy time.

Integration script: `infrastructure/wazuh-docker/integrations/custom-ops-queue`

Dry-run:

```bash
echo '{"rule":{"id":"100808","level":12,"description":"test"},"agent":{"name":"ews","ip":"192.168.61.20"},"timestamp":"2026-01-01T00:00:00Z"}' \
  | WAZUH_OPS_WEBHOOK_URL="$WAZUH_OPS_WEBHOOK_URL" \
    infrastructure/wazuh-docker/integrations/custom-ops-queue
```

## Validation before/after reset

```bash
./scripts/validate/test-ews-lpe-clean.sh --target <IP>
./scripts/validate/test-cysvuln-efs-clean.sh <IP>
./scripts/verify-ews.sh <IP>
WINRM_PORT=5985 ./scripts/verify-cysvuln.sh <IP>
```

Local QEMU gate:

```bash
nix develop
./scripts/validate/resilience-local-qemu.sh
```
