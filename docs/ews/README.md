# EWS (Easy File Sharing successor box)

Windows 10 LTSC challenge: weak TightVNC credentials, unquoted service path LPE, campaign pivot to AS-REP DC.

| Field | Value |
|---|---|
| OS | Windows 10 LTSC |
| Foothold | TightVNC TCP/5900 (`patrick` / `FELDTECH_VNC`) |
| Privesc | Unquoted service path `SecretConEwsSync` |
| Campaign IP (vmbr1) | `192.168.61.20` |

## Challenge components

| Component | Document |
|---|---|
| Attack walkthrough | [attack-faq-walkthrough.md](attack-faq-walkthrough.md) |
| Defender walkthrough | [defend-faq-walkthrough.md](defend-faq-walkthrough.md) |
| Deployment | [deploy-windowsvm.md](../runbooks/deploy-windowsvm.md), [infrastructure/packer/ews/README.md](../../infrastructure/packer/ews/README.md) |
| Operator emulation | [ews-vnc-adversary-emulation.md](../runbooks/ews-vnc-adversary-emulation.md) |
| NSM analyst track | [opnsense-vnc-brute-analyst-challenge.md](../runbooks/opnsense-vnc-brute-analyst-challenge.md) |
| Campaign pivot | [ews-asrep-pivot-runbook.md](../campaign/ews-asrep-pivot-runbook.md) |
| PCAP side challenge | [targets/ews-vnc-pcap-forensics/README.md](../../targets/ews-vnc-pcap-forensics/README.md) |
| VNC PCAP / Wireshark | [vnc-pcap-wireshark-analysis.md](vnc-pcap-wireshark-analysis.md) |

## Quick validation

```bash
nix develop
# Resolve live IP (DHCP on vmbr1 changes after reboot — do not assume .109 or .20)
./scripts/proxmox/discover-ews-ip.sh
nmap -Pn "$(./scripts/proxmox/discover-ews-ip.sh)" -p 5900,22

./scripts/verify-ews.sh 192.168.61.20
./scripts/validate/validate-vnc-public-attack.sh
```

### Service discovery (WireGuard / Kali)

Discovery only knew two fixed IPs; the guest often lands on **DHCP** (e.g. `192.168.61.158`) after reboot on `vmbr1`. Use:

```bash
./scripts/proxmox/discover-proxmox-inventory.sh   # ARP by VM MAC + VNC probe
```

To pin campaign address: set `EWS_STATIC_IP=192.168.61.20` in `.env`, then `converge-ews.sh` (runs `ews_network` role).

Build-subnet static from Packer is `192.168.60.109` (`provisioning/proxmox/proxmox-static-ip.txt`) and applies at install only — not after bridge moves.

## Lab-only Windows activation (opt-in)

The `windows_activation` Ansible role can run a third-party activation script when explicitly enabled. This is for **internal lab images only** — not production, not CI. Licensing compliance is the operator’s responsibility.

```bash
# After converge; guest needs outbound HTTPS
EWS_WINDOWS_ACTIVATION=1 ./scripts/proxmox/converge-ews.sh --ews-host <IP>
# Or:
ansible-playbook playbooks/ews.yml --tags windows_activation \
  -e windows_activation_enabled=true
```

Default converge leaves activation off (`EWS_WINDOWS_ACTIVATION=0` in [example.env](../../example.env)).

## VNC desktop and Proxmox guest agent

- **ews_vnc_desktop** — disables sleep, lock screen, and screensaver so TightVNC stays usable after idle (works with **autologon**).
- **proxmox_guest_agent** — installs virtio-win QEMU guest agent; pair with OpenTofu `agent.enabled` for correct memory in the Proxmox UI.

Apply order on an existing VM: `./scripts/proxmox/converge-ews.sh` runs guest `ews.yml` then `playbooks/proxmox/ews-hypervisor.yml`. See [ansible-proxmox-migration.md](../refactor/ansible-proxmox-migration.md).

See [docs/conventions.md](../conventions.md) for the three-part doc spec shared across SecretCon boxes.
