# Provisioning

Post-install payloads consumed by Packer, cloud-init, or deploy scripts. Nothing here runs on the host directly except during image bake or first boot.

## Layout

| Path | Used by |
|------|---------|
| bash/ | Ubuntu Wazuh SIEM bootstrap (`bootstrap-wazuh-ubuntu.sh`) |
| cloud-init/ | NoCloud seeds (Wazuh template clone) |
| cysvuln/ | CysVuln autounattend + in-guest AIE validation helpers |
| local/ | QEMU-local Win10 autounattend |
| openssh/ | Windows OpenSSH bundle for Packer SSH communicator |
| powershell/ | Windows challenge bootstraps + shared `lib/` module |
| proxmox/ | Proxmox-target autounattend + static IP scripts |
| proxmox/dc1/, dc2/ | Domain controller autounattend per role |
| ssh/ | Packer ed25519 key pair (`packer_ed25519`, gitignored private) |
| tightvnc/ | TightVNC MSI for EWS (gitignored binary) |

## Packer mapping

- EWS Win10: `bootstrap_win.ps1` + `local/` or `proxmox/` autounattend (recipes in `infrastructure/packer/ews/`)
- CysVuln: `bootstrap_cysvuln.ps1` + `cysvuln/autounattend.xml`
- DC pair: `bootstrap_dc.ps1` + `proxmox/dc1|dc2/`
- Wazuh: `bash/bootstrap-wazuh-ubuntu.sh` + `cloud-init/wazuh/`

See [powershell/README.md](powershell/README.md) for bootstrap env vars.
