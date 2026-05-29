Generated: 2026-05-27T13:45:42Z

# Local vs Proxmox script pairing

- `scripts/proxmox/deploy-cysvuln.sh` -> `scripts/build-cysvuln-local.sh` (ok)
- `scripts/proxmox/deploy-asrep.sh` -> `scripts/build-asrep-local.sh` (ok)
- `scripts/proxmox/baseline-snapshot-cysvuln.sh` -> `scripts/observability/baseline-snapshot.sh` (ok)
- `scripts/proxmox/baseline-snapshot-asrep.sh` -> `scripts/observability/baseline-snapshot-asrep.sh` (ok)
- `scripts/proxmox/deploy-wazuh-siem.sh` -> `scripts/wazuh-docker-up.sh` (ok)
- `scripts/proxmox/deploy-arkime-capture.sh` -> `scripts/arkime-docker-up.sh` (ok)
- `scripts/proxmox/sync-arkime-pcap.sh` -> `scripts/arkime-import-pcap.sh` (ok)
- `scripts/proxmox/verify-wazuh-siem.sh` -> `MISSING` (ok)
- `scripts/proxmox/verify-arkime-capture.sh` -> `scripts/observability/vnc-pcap-proof.sh` (ok)
- `scripts/proxmox/rebuild-ews.sh` -> `scripts/hyperv/Build-SecretConEwsVhdx.ps1` (ok)

## Unpaired Proxmox scripts (14)
- scripts/proxmox/build-wazuh-template.sh
- scripts/proxmox/configure-chain-dns.sh
- scripts/proxmox/deploy-dc.sh
- scripts/proxmox/disable-vmbr1-mirror.sh
- scripts/proxmox/enable-vmbr1-mirror.sh
- scripts/proxmox/enable-wazuh-replay-listener.sh
- scripts/proxmox/opnsense-apply-config.sh
- scripts/proxmox/opnsense-export-pcap.sh
- scripts/proxmox/preflight-ews-prod.sh
- scripts/proxmox/probe-ews.sh
- scripts/proxmox/reproduce-ews-prod-proof.sh
- scripts/proxmox/rollback-vmbr1-mirror.sh
- scripts/proxmox/snapshot-before-mirror.sh
- scripts/proxmox/sync-wazuh-rules.sh
