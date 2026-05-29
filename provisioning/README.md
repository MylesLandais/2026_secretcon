# Provisioning

Post-install payloads consumed by Packer, cloud-init, or deploy scripts. Nothing here runs on the host directly except during image bake or first boot.

## Layout

| Path | Used by |
|------|---------|
| asrep/ | ASREP bootstrap runtime (`asrep-bootstrap-runtime.ps1`) |
| bash/ | Ubuntu Wazuh SIEM bootstrap (`bootstrap-wazuh-ubuntu.sh`) |
| cloud-init/ | NoCloud seeds (Wazuh template clone, Arkime capture VM) |
| cloud-init/arkime/ | crit-capture VM bootstrap (Docker + Arkime compose) |
| cysvuln/ | CysVuln autounattend + in-guest AIE validation helpers |
| local/ | QEMU-local Win10 autounattend |
| openssh/ | Windows OpenSSH bundle for Packer SSH communicator |
| opnsense/ | Suricata rules, config snapshot, setup instructions |
| powershell/ | Windows challenge bootstraps + shared `lib/` module |
| proxmox/ | Proxmox-target autounattend + static IP scripts |
| proxmox/dc1/, dc2/ | Domain controller autounattend per role |
| wordlists/ | VNC brute wordlists for adversary emulation |
| tightvnc/ | TightVNC MSI for EWS (gitignored binary) |
| ssh/ | Packer ed25519 keypair (private key gitignored; see [ssh/readme.md](ssh/readme.md)) |

Packer SSH public key is also referenced from manifests as
`provisioning/ssh/packer_ed25519.pub`. OpenSSH bundle zips live under
`provisioning/openssh/`.

## Packer mapping

- EWS Win10: `bootstrap_win.ps1` + `local/` or `proxmox/` autounattend (recipes in `infrastructure/packer/ews/`)
- CysVuln: `bootstrap_cysvuln.ps1` + `cysvuln/autounattend.xml`
- ASREP DC: `bootstrap_asrep.ps1` + ASREP autounattend (recipes in `infrastructure/packer/asrep/`)
- DC pair: `bootstrap_dc.ps1` + `proxmox/dc1|dc2/`
- Wazuh: `bash/bootstrap-wazuh-ubuntu.sh` + `cloud-init/wazuh/`
- Arkime capture: `cloud-init/arkime/` + `infrastructure/arkime-docker/`

See [powershell/README.md](powershell/README.md) for bootstrap env vars.
