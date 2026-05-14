# SecretCon 2026 Threat Range

Infrastructure-as-code for the 2026 SecretCon capture-the-flag
environment. This repo is also the reference implementation for the
adversarial-simulation training range we run year-round.

The lab pairs a Windows engineering workstation (EWS) with a Wazuh SIEM,
deployed on Proxmox. Players foothold via a known-bad VNC default and
pivot through an unquoted-service-path local privilege escalation.
Blue-team telemetry lands in Wazuh from Sysmon, Suricata, and the Wazuh
agent.

An OT segment with a CompactLogix PLC was scoped for 2026 but pruned
for resources. See `docs/architecture.md` for the deferred design.

For event participation see [secretconctf.com](https://secretconctf.com/).

## What this repo gives you

- Packer recipes that build a Win10 LTSC challenge VM, locally under QEMU or
  natively on Proxmox.
- Three-script Proxmox deploy pattern for the Wazuh SIEM (template, deploy,
  verify) with cloud-init.
- Windows post-install bootstrap that installs TightVNC, the Wazuh agent,
  and Sysmon.
- NixOS dev shell with `packer`, `terraform`, `qemu`, `sops`, `age`, and
  `xorriso` pinned.
- Agent skills under `.claude/skills/` so AI assistants in the repo speak
  the same dialect of Packer, Proxmox, and Wazuh as the maintainers.

## Lab topology

```
Internet
   |
   v
[ WireGuard gateway (UniFi OS) ]----[ Primary DNS 172.16.130.2 ]
   |
   +-- 192.168.2.0/24      tunnel
   +-- 192.168.60.0/24     management VLAN
   |     +-- 192.168.60.1    Proxmox (manage.secret-ctf.com)
   |     +-- 192.168.60.253  Mgmt server
   +-- 192.168.61.0/24     challenge VLAN
   |     +-- 192.168.61.10   Wazuh SIEM (VM 110)
   |     +-- 192.168.61.20   Win10 EWS    (VM 109)
   +-- 172.16.30.0/24      DC subnet, dc01.care-secllc.com
```

Full architecture in [docs/architecture.md](docs/architecture.md).

## Quick start

```
nix develop
```

Drops you into a shell with all build tooling on `PATH`.

### Build the EWS challenge VM locally (QEMU)

Prereqs: Windows 10 LTSC eval ISO and `virtio-win.iso` in `~/Downloads/`.

```
nix build .#win10-ews-local
./scripts/run-local-vm.sh result/win10-ews-local.qcow2
```

The running VM exposes RDP on `localhost:3389`, WinRM on `5985`, and a guest
VNC on `5900`.

### Build the EWS challenge VM on Proxmox

ISOs are downloaded directly on the Proxmox host. Tunnel uplink is too slow
to push a baked qcow2 across.

```
packer init  infrastructure/packer/proxmox-vm.pkr.hcl
packer build infrastructure/packer/proxmox-vm.pkr.hcl
```

Requires `PROXMOX_URL`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET`.

### Deploy the Wazuh SIEM

```
ssh root@<proxmox-host> bash -s < scripts/proxmox/build-wazuh-template.sh
bash scripts/proxmox/deploy-wazuh-siem.sh
bash scripts/proxmox/verify-wazuh-siem.sh
```

See [docs/runbooks/deploy-wazuh.md](docs/runbooks/deploy-wazuh.md) for the
full sequence and verification checks.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR.

Highlights:

- Conventional Commits required.
- Commits or docs with emoji will be rejected by CI.
- Skills under `.claude/skills/` follow vendor naming, one folder per tool.
- Runbooks under `docs/runbooks/` follow `deploy-<target>.md`.

By contributing you agree to the [Contributor Covenant](CODE_OF_CONDUCT.md).

## License

MIT, see [LICENSE](LICENSE).
