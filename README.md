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
cp example.env .env   # edit with your lab values; never commit .env
./scripts/test-local.sh
```

Drops you into a shell with Packer, QEMU, Python validation tools, and
xorriso on `PATH`.

Windows ISOs are not in git. See [docs/windows-image-inputs.md](docs/windows-image-inputs.md).

### CysVulnServer (Server 2016 + EFS)

Required inputs: Server 2016 ISO, CysVuln artifacts (fetch script), optional flags.

```
./scripts/fetch-iso.sh server-2016 <url>
./scripts/fetch-cysvuln-artifacts.sh
```

Build path (pick one):

| Platform | Command / doc |
|----------|----------------|
| QEMU (Nix) | `nix build .#cysvuln-local` then `scripts/run-local-cysvuln.sh` |
| Proxmox | [docs/runbooks/deploy-cysvulnserver.md](docs/runbooks/deploy-cysvulnserver.md) |
| VMware | [docs/runbooks/deploy-cysvuln-multi-hypervisor.md](docs/runbooks/deploy-cysvuln-multi-hypervisor.md) |
| Hyper-V | `scripts/build-provision-iso.ps1` then Packer in `infrastructure/packer/cysvuln/` |

Validate after boot: `./scripts/verify-cysvuln.sh <target-ip>`

### EWS challenge (Win10 LTSC)

```
./scripts/fetch-iso.sh win10-ltsc <url>
nix build .#win10-ews-local
./scripts/run-local-vm.sh result/win10-ews-local.qcow2
```

Proxmox-native: `cd infrastructure/packer/ews && packer build -only=proxmox-iso.win10-ews .` with
`PROXMOX_URL`, `PROXMOX_USERNAME`, `PROXMOX_PASSWORD` from `.env`.
See [docs/runbooks/deploy-windowsvm.md](docs/runbooks/deploy-windowsvm.md).

### Wazuh SIEM

```
ssh root@<proxmox-host> bash -s < scripts/proxmox/build-wazuh-template.sh
bash scripts/proxmox/deploy-wazuh-siem.sh
bash scripts/proxmox/verify-wazuh-siem.sh
```

See [docs/runbooks/deploy-wazuh.md](docs/runbooks/deploy-wazuh.md).

## Security research notice

This repo ships intentional CTF footholds, flags, and validation exploits for
[secretconctf.com](https://secretconctf.com/). Real infrastructure secrets
(`.env`, Wazuh cred dumps, private keys) must never be committed. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a PR.

Highlights:

- Conventional Commits required.
- Commits or docs with emoji will be rejected by CI.
- Local validation: `./scripts/test-local.sh` (hosted CI does not boot VMs).
- Runbooks under `docs/runbooks/` follow `deploy-<target>.md`.

## License

MIT, see [LICENSE](LICENSE).
