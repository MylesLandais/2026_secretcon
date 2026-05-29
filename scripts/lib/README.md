# scripts/lib

Bash helpers sourced by verify, deploy, and observability scripts. Not executable on their own.

| File | Purpose | Sourced by |
|------|---------|------------|
| chain_env.sh | Three-box campaign defaults (`CHAIN_*` IPs, shared admin password) | `validate-three-box-chain.sh`, campaign scripts |
| check-harness.sh | `check_init`, `check`, `check_summary` PASS/FAIL accumulator | `verify-*.sh`, `validate-three-box-chain.sh` |
| check-wazuh-agent.sh | Wazuh manager API agent status | verify scripts (after `check` exists) |
| docker-stack.sh | `docker_stack_up`, `docker_stack_down`, `docker_stack_wait_http` | docker *-up/down scripts |
| proxmox-ssh.sh | `proxmox_load_env`, `pxssh`, `pxscp` | `scripts/proxmox/*` mirror/deploy scripts |
| vnc-lab.sh | `vnc_load_env`, `vnc_resolve_wordlist` | VNC observability scripts |
| stress-campaign.sh | `campaign_init`, `campaign_iter_score`, `campaign_finish` | `stress-campaign*.sh` |
| evidence-harness.sh | `evidence_init`, `evidence_record`, `evidence_summary` with optional file | `preflight-ews-prod.sh`, prod-proof scripts |
| load_repo_env.sh | Source repo-root `.env` without clobbering caller exports | Proxmox deploy, VNC, validation scripts |
| loop_lib.sh | QEMU observability loop helpers (enroll, Sysmon wait, snapshot) | `observability-loop*.sh`, baseline snapshots |
| read-provision-manifest.sh | `read_provision_manifest` — repo-relative paths from manifest txt | `test-local.sh`, `build-provision-iso.sh` |
| read_flag.sh | Read flag files from challenge VMs | observability scripts |
| render_autounattend.sh | Token substitution for autounattend XML | Proxmox deploy scripts |
| wait_for_winrm.sh | Poll WinRM until a Windows guest is reachable | deploy/rebuild scripts |
| wazuh-api.sh | Wazuh manager REST helpers (`wazuh_api_wait_token`, etc.) | `wazuh-*` operator scripts |
| wazuh-common.sh | `wazuh_load_env`, `wazuh_require_cmd`, canonical Wazuh env names | `wazuh-docker-up.sh`, export/replay scripts |

Python helpers in this directory: `wazuh_replay.py` (dataset replay).

## Sourcing contract

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/load_repo_env.sh
. "${REPO_ROOT}/scripts/lib/load_repo_env.sh"
load_repo_env "${REPO_ROOT}"

# shellcheck source=scripts/lib/check-harness.sh
. "${REPO_ROOT}/scripts/lib/check-harness.sh"
check_init
check "example" PASS "detail"
check_summary "my verify run"
```

`check-wazuh-agent.sh` requires `check()` to be defined first (from `check-harness.sh`).

`wazuh_load_env` reads `infrastructure/wazuh-docker/.env` and maps docker-compose credential names onto `WAZUH_*` canonical variables. Use it for Wazuh stack scripts; use `load_repo_env` for Proxmox/lab `.env` at repo root.

Manifest reader parity with `scripts/build-provision-iso.ps1` `Read-ManifestLines` is documented in both build scripts.
