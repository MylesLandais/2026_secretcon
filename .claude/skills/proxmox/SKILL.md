---
name: proxmox
description: Managing VMs, templates, cloud-init, and bridges on the SecretCon Proxmox host
---

# Proxmox

## When this skill applies

Reach for this skill any time you are:

- Creating, cloning, or tearing down lab VMs.
- Writing or editing cloud-init payloads under `provisioning/cloud-init/`.
- Touching the build / deploy / verify script trio for a SIEM or
  challenge VM.
- Choosing storage, bridge, or VMID for a new artifact.

If you are baking a fresh image from an ISO, that is a Packer task. See
`packer/SKILL.md`.

## Conventions in this repo

- Single Proxmox node, name `manage`, at `https://192.168.60.1:8006`.
- Storage: `local` holds ISOs, imports, and templates. `local-lvm` holds
  VM disks.
- Bridges: `vmbr0` is the management VLAN `192.168.60.0/24`, gateway
  `.254`. `vmbr1` is the challenge VLAN `192.168.61.0/24`, gateway `.1`.
- VMID ranges: 100s for challenge VMs, 9000s for templates. New VMIDs
  pick the next free slot; do not reuse retired IDs without checking.
- IaC scripts use the three-script pattern:

  1. `build-<target>-template.sh` runs on the Proxmox host. It pulls
     the base image and creates a Proxmox template at a fixed VMID.
  2. `deploy-<target>.sh` runs from a workstation with SSH access to the
     host. It tears down the existing VM, clones the template, seeds
     cloud-init, and waits for first boot to complete.
  3. `verify-<target>.sh` runs an acceptance test (ports, services,
     custom rule presence, agent group membership).

- Cloud-init payloads live under `provisioning/cloud-init/<target>/` and
  follow the NoCloud format (`user-data`, `meta-data`, optional
  `network-config`).
- WireGuard reachability to `192.168.61.0/24` is patchy from the
  workstation. SSH through the host with `ProxyJump=root@192.168.60.1`
  rather than fighting routing.

## Canonical examples

- `scripts/proxmox/build-wazuh-template.sh`
- `scripts/proxmox/deploy-wazuh-siem.sh`
- `scripts/proxmox/verify-wazuh-siem.sh`
- `provisioning/cloud-init/wazuh/user-data`

## Common pitfalls

- Live-server autoinstall via Packer hangs on console keystrokes. We
  switched to cloud-image + cloud-init for Ubuntu targets. Do not
  reintroduce the autoinstall path.
- `qm set --net1 ...` does not move the cloud-init seed. If you change
  networking after first boot, regenerate cloud-init or update the VM
  config and reboot.
- Importing a qcow2 over the WireGuard tunnel runs at about 1.2 MB/s.
  Always build on the host, not the workstation.
- `searchdomain secret-ctf.com` matters: agents that resolve short
  hostnames depend on it. Keep it in the cloud-init network config.

## Debugging tips

- `qm config <vmid>` is the source of truth for the VM's current
  Proxmox-side configuration.
- `journalctl -u qemu-server@<vmid>` on the host shows boot-time
  failures that the UI hides.
- Cloud-init inside the guest writes to `/var/log/cloud-init-output.log`.
  Read it first when "the bootstrap script did not run."

## References

- VM inventory and subnet layout in `docs/architecture.md`.
- Wazuh deploy runbook: `docs/runbooks/deploy-wazuh.md`.
- See also `wazuh/SKILL.md` and `packer/SKILL.md`.
