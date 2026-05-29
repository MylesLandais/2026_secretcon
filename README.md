# SecretCon 2026 Threat Range

Infrastructure-as-code for the DEF CON Village / SecretCon adversarial-simulation lab: a **three-box campaign** (CysVuln → EWS → AS-REP DC) plus a **monitoring stack** (Wazuh, OPNsense/Suricata, Arkime, Kali demo VM).

Players chain footholds across Windows challenge VMs; defenders consume Sysmon, agent, IDS, and PCAP telemetry. See [docs/architecture.md](docs/architecture.md) for topology.

For event participation see [secretconctf.com](https://secretconctf.com/).

## Per-box documentation

Each box ships deployment runbooks plus canonical player/defender walkthroughs ([docs/conventions.md](docs/conventions.md)).

| Box | Deploy | Attack FAQ | Defend FAQ |
|-----|--------|------------|------------|
| CysVuln | [readme](docs/cysvulnserver/readme.md) | [attack-faq-walkthrough.md](docs/cysvulnserver/attack-faq-walkthrough.md) | [defend-faq-walkthrough.md](docs/cysvulnserver/defend-faq-walkthrough.md) |
| EWS | [README](docs/ews/README.md) | [attack-faq-walkthrough.md](docs/ews/attack-faq-walkthrough.md) | [defend-faq-walkthrough.md](docs/ews/defend-faq-walkthrough.md) |
| AS-REP / AD | [readme](docs/asrep/readme.md) | [attack-faq-walkthrough.md](docs/asrep/attack-faq-walkthrough.md) | [defend-faq-walkthrough.md](docs/asrep/defend-faq-walkthrough.md) |

Integrated campaign: [docs/campaign/three-box-chain.md](docs/campaign/three-box-chain.md).

## Experimental labs (separate branches)

| Lab | Branch | Domain | Notes |
|-----|--------|--------|-------|
| Hack Academy AD Chain 8 | `lab/ad-chain8` | `hackerblueprint.local` | QEMU three-VM reproduction, offline forensics, walkthrough capture — not part of the shipped campaign |

```bash
git fetch origin lab/ad-chain8 2>/dev/null || true
git checkout lab/ad-chain8
```

Sources are gitignored on `main`; see commit history on that branch for docs and scripts.

## Monitoring stack

| Component | Role | Docs |
|-----------|------|------|
| Wazuh SIEM | Agent + Sysmon + custom rules | [deploy-wazuh.md](docs/runbooks/deploy-wazuh.md), [wazuh-docker](infrastructure/wazuh-docker/readme.md) |
| OPNsense | SPAN mirror, Suricata, filterlog | [provisioning/opnsense](provisioning/opnsense/README.md) |
| Arkime | PCAP review (`crit-capture` VMID 111) | [arkime-docker](infrastructure/arkime-docker/readme.md) |
| Kali (VMID 104) | Demo attack origin on vmbr1 | [docs/architecture.md](docs/architecture.md) |

## What this repo gives you

- Packer recipes per hypervisor (QEMU, Proxmox, Hyper-V, VMware) — **transitional**; see provisioning direction below.
- Three-script Proxmox deploy pattern (template / deploy / verify) for SIEM and capture VMs.
- PowerShell bootstrap + experimental Ansible roles for in-VM state.
- Nix dev shell with `packer`, `ansible`, `qemu`, `pytest`, and observability tooling.
- Agent skills under `.claude/skills/` including [repo-audit](.claude/skills/repo-audit/SKILL.md) for cleanup inventories.

## Provisioning direction

Packer re-bakes are too slow for incremental registry/policy changes. **Ansible** owns in-guest convergence and Proxmox VM lifecycle (`community.proxmox`). Active plan: [ansible-proxmox-migration.md](docs/refactor/ansible-proxmox-migration.md), [ansible-opentofu-migration.md](docs/refactor/ansible-opentofu-migration.md), [ansible-parity-matrix.md](docs/refactor/ansible-parity-matrix.md).

Do not deepen dual-source drift: read the migration doc before editing `bootstrap_win.ps1` or `scripts/proxmox/rebuild-*.sh`.

Parallel track: `heliumsupply.local` two-DC forest ([deploy-dc.md](docs/runbooks/deploy-dc.md)) — future / out of campaign scope.

An OT segment with a CompactLogix PLC was scoped for 2026 but pruned for resources. See `docs/architecture.md` for the deferred design.

## Lab topology

```
Internet
   |
   v
[ WireGuard gateway (UniFi OS) ]----[ Primary DNS 172.16.130.2 ]
   |
   +-- 192.168.2.0/24      tunnel
   +-- 192.168.60.0/24     management VLAN (live/prod layout)
   |     +-- 192.168.60.1    Proxmox (manage.secret-ctf.com)
   |     +-- 192.168.60.109  Win10 EWS live box (VM 109 on vmbr0)
   +-- 192.168.61.0/24     challenge VLAN (campaign layout)
   |     +-- 192.168.61.10   Wazuh SIEM (VM 110)
   |     +-- 192.168.61.20   Win10 EWS campaign NIC (VM 109 on vmbr1)
   |     +-- 192.168.61.11   Arkime crit-capture (VM 111)
   |     +-- 192.168.61.253  OPNsense SPAN sensor
   +-- 172.16.30.0/24      DC subnet, dc01.care-secllc.com
```

Full architecture in [docs/architecture.md](docs/architecture.md).

## Known refactor backlog

Configuration management is **Packer + Ansible** (in-guest roles and `playbooks/proxmox/` for the hypervisor). See [`ansible/`](ansible/README.md) and [ansible-proxmox-migration.md](docs/refactor/ansible-proxmox-migration.md).

Repo hygiene: run `python3 .claude/skills/repo-audit/audit.py` before/after refactors.

## How to validate

Validation is tiered. Pick the narrowest tier that matches your change.

| Tier | When | Command |
|------|------|---------|
| CI-safe | Every PR; no lab required | `nix develop -c ./scripts/test-local.sh` |
| Unit | Python helpers | `nix develop -c python3 -m pytest scripts/validate/tests -q` |
| Ansible syntax | Touching `ansible/` | `nix develop -c ansible-playbook --syntax-check ansible/playbooks/ews.yml` |
| VM smoke | Single box reachable | `./scripts/verify-cysvuln.sh <ip>`, `./scripts/verify-ews.sh <ip>`, `./scripts/verify-asrep.sh <ip>` |
| Campaign | Multi-box chain on vmbr1 | `./scripts/validate-three-box-chain.sh [--siem] [--pivot]` |
| VNC pipeline | EWS brute + PCAP + Wazuh | `./scripts/validate/validate-vnc-public-attack.sh --run-id <id>` |
| OPNsense NSM | Mirror + Suricata + Arkime | `./scripts/validate/validate-opnsense-vnc-pipeline.sh --run-id <id>` |
| Prod proof | Live EWS over WireGuard | `EWS_HOST=192.168.60.109 ./scripts/proxmox/reproduce-ews-prod-proof.sh` |

Full matrix: [scripts/validate/README.md](scripts/validate/README.md).
Hosted CI runs the CI-safe tier only; it does not boot VMs.

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

Build path (pick one — all four covered by [docs/runbooks/deploy-cysvuln-multi-hypervisor.md](docs/runbooks/deploy-cysvuln-multi-hypervisor.md)):

| Platform | Command | Skill |
|----------|---------|-------|
| QEMU (Nix) | `nix build .#cysvuln-local` then `scripts/run-local-cysvuln.sh` | [`.claude/skills/nix/SKILL.md`](.claude/skills/nix/SKILL.md) |
| Proxmox | see [docs/runbooks/deploy-cysvulnserver.md](docs/runbooks/deploy-cysvulnserver.md) | [`.claude/skills/proxmox/SKILL.md`](.claude/skills/proxmox/SKILL.md) |
| Hyper-V | `scripts/build-provision-iso.ps1` then `packer build -only=hyperv-iso.cysvuln-hyperv .` | [`.claude/skills/hyperv/SKILL.md`](.claude/skills/hyperv/SKILL.md) |
| VMware Workstation/Fusion | `packer build -only=vmware-iso.cysvuln-vmware .` | [`.claude/skills/vmware/SKILL.md`](.claude/skills/vmware/SKILL.md) |

Validate after boot: `./scripts/verify-cysvuln.sh <target-ip>`. The SIEM capture loops (`scripts/observability-loop.sh`, `scripts/observability/*`) are QEMU-only; on other hypervisors run the validation chain manually — see the runbook's "Snapshot lifecycle and observability scope" section.

### ASREP demo DC (Server 2016 + secretcon.local)

Standalone AS-REP roasting box (`enite` / `stud87`). Reuses the CysVuln Server 2016 ISO.

```
./scripts/stage-cysvuln-iso.sh /path/to/server-2016.iso
export SECRETCON_ASREP_FLAG='flag{asrep-local-test}'
./scripts/build-asrep-local.sh
./scripts/run-local-asrep.sh
ASREP_DC_IP=10.0.2.15 ./scripts/validate-asrep.sh
```

Docs: [docs/asrep/readme.md](docs/asrep/readme.md), [docs/asrep/attack-faq-walkthrough.md](docs/asrep/attack-faq-walkthrough.md).

### Full chain campaign (CysVuln → EWS → secretcon.local DC)

Three-box Proxmox campaign on `vmbr1` with shared local Administrator password, AS-REP domain compromise, and cross-box Wazuh rules `100710`–`100715`.

```
export SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD='PizzaMan123!'
export SECRETCON_DC_USER_FLAG='...' SECRETCON_DC_ROOT_FLAG='...'
./scripts/proxmox/deploy-asrep.sh --vmid 112 --ip 192.168.61.52
./scripts/proxmox/deploy-cysvuln.sh --vmid 119 --ip 192.168.61.51
./scripts/proxmox/configure-chain-dns.sh
./scripts/validate-three-box-chain.sh
./scripts/observability/ews-asrep-pivot.sh   # demo: 7-step EWS->DC checklist + telemetry
./scripts/validate-three-box-chain.sh --pivot --siem
```

Runbook: [docs/campaign/three-box-chain.md](docs/campaign/three-box-chain.md). Blue scoring: [docs/campaign/defend-track-rubric.md](docs/campaign/defend-track-rubric.md). Pivot demo: [docs/campaign/ews-asrep-pivot-runbook.md](docs/campaign/ews-asrep-pivot-runbook.md).

### EWS challenge (Win10 LTSC)

```
./scripts/fetch-iso.sh win10-ltsc <url>
nix build .#win10-ews-local
./scripts/run-local-vm.sh result/win10-ews-local.qcow2
```

A **standalone analyst track** built from the same EWS box is committed
to [`targets/ews-vnc-pcap-forensics/`](targets/ews-vnc-pcap-forensics/README.md) —
no VM required, just `tshark`, a wordlist, and an RFB-aware password
cracker. Players recover the foothold password from 41 captured
TightVNC auth attempts and submit `flag{FELDTECH_VNC}`. Regenerate
with [`scripts/observability/vnc-public-attack.sh`](scripts/observability/vnc-public-attack.sh)
and validate with [`scripts/validate/validate-vnc-public-attack.sh`](scripts/validate/validate-vnc-public-attack.sh).

Build path (pick one):

| Platform | Command | Skill |
|----------|---------|-------|
| QEMU (Nix) | `nix build .#win10-ews-local` | [`.claude/skills/nix/SKILL.md`](.claude/skills/nix/SKILL.md) |
| Proxmox | `cd infrastructure/packer/ews && packer build -only=proxmox-iso.win10-ews .` (needs `PROXMOX_URL/USERNAME/PASSWORD` in `.env`); see [docs/runbooks/deploy-windowsvm.md](docs/runbooks/deploy-windowsvm.md) | [`.claude/skills/proxmox/SKILL.md`](.claude/skills/proxmox/SKILL.md) |
| Hyper-V | `scripts/hyperv/Build-SecretConEwsVhdx.ps1` (Windows PowerShell, runs Packer end-to-end) | [`.claude/skills/hyperv/SKILL.md`](.claude/skills/hyperv/SKILL.md) |
| VMware Workstation/Fusion | `cd infrastructure/packer/ews && packer build -only=vmware-iso.win10-ews-vmware .` | [`.claude/skills/vmware/SKILL.md`](.claude/skills/vmware/SKILL.md) |

#### VNC tracks (pick one)

| Track | Requires | Driver script | Docs |
|-------|----------|---------------|------|
| Offline PCAP CTF | PCAP + wordlist only | — | [`targets/ews-vnc-pcap-forensics/`](targets/ews-vnc-pcap-forensics/README.md) |
| Full lab emulation | EWS + Wazuh + Arkime | [`vnc-adversary-emulation.sh`](scripts/observability/vnc-adversary-emulation.sh) | [ews-vnc-adversary-emulation runbook](docs/runbooks/ews-vnc-adversary-emulation.md) |
| Public attack + validate | Campaign EWS on vmbr1 | [`vnc-public-attack.sh`](scripts/observability/vnc-public-attack.sh) | same runbook |
| OPNsense NSM extension | Mirror + OPNsense + crit-capture | [`opnsense-vnc-challenge.sh`](scripts/observability/opnsense-vnc-challenge.sh) | [opnsense-vnc-brute runbook](docs/runbooks/opnsense-vnc-brute-analyst-challenge.md) |
| Prod reproduction | WireGuard + live EWS | [`reproduce-ews-prod-proof.sh`](scripts/proxmox/reproduce-ews-prod-proof.sh) | set `EWS_HOST=192.168.60.109` |

Helper scripts (`vnc-pcap-analyze.sh`, `vnc-pcap-proof.sh`, `vnc-wazuh-proof.sh`,
`vnc-replay-on-deploy.sh`) are internal steps called by the drivers above.

### OPNsense + Arkime (NSM analyst track)

Live `vmbr1` mirror through OPNsense Suricata, Wazuh correlation, and
Arkime PCAP ingest on VMID 111.

```
./scripts/observability/opnsense-vnc-challenge.sh
./scripts/validate/validate-opnsense-vnc-pipeline.sh --run-id <id>
```

Runbook: [docs/runbooks/opnsense-vnc-brute-analyst-challenge.md](docs/runbooks/opnsense-vnc-brute-analyst-challenge.md).
Capture pipeline detail: [docs/architecture.md](docs/architecture.md).

Local Arkime docker (offline PCAP lab, no Proxmox):

```
./scripts/arkime-docker-up.sh
./scripts/arkime-import-pcap.sh infrastructure/arkime-docker/pcaps/vnc_auth.pcap
```

### Wazuh SIEM

```
ssh root@<proxmox-host> bash -s < scripts/proxmox/build-wazuh-template.sh
bash scripts/proxmox/deploy-wazuh-siem.sh
bash scripts/proxmox/verify-wazuh-siem.sh
```

See [docs/runbooks/deploy-wazuh.md](docs/runbooks/deploy-wazuh.md).

Dataset export and replay for fidelity testing:
[docs/runbooks/wazuh-dataset-export-and-replay.md](docs/runbooks/wazuh-dataset-export-and-replay.md).

Local docker stack (QEMU lab only):

```
./scripts/wazuh-docker-up.sh
./scripts/wazuh-docker-down.sh          # stop, keep volumes
./scripts/wazuh-docker-down.sh --wipe   # stop + delete volumes
```

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
