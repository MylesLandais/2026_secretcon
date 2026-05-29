# scripts/validate

Lab tooling to prove challenge images and campaign pipelines match documented behaviour. Not shipped to players.

## Layout

```
validate/
  request_builder/     EFS 6.9 USERID overflow payload (ROP + shellcode)
  templates/           WiX template for AIE probe MSI
  tests/               pytest unit tests (CI-safe)
  reference/           Upstream EDB PoCs for diffing
  audit_aie.py         WinRM AIE/UAC registry audit
  check_aie_response.py  Build validation MSI (wixl)
  check_efs69_response.py  Trigger EFS foothold
  run_aie_via_efs_callback.py  End-to-end AIE as User_Joe
  validate-vnc-public-attack.sh   VNC PCAP + credential recovery acceptance
  validate-opnsense-vnc-pipeline.sh  OPNsense mirror + Suricata + Arkime acceptance
```

Top-level campaign validators live in `scripts/` (not under `validate/`):

| Script | Scope |
|--------|-------|
| `validate-cysvuln-chain.sh` | Full CysVuln AIE chain (host-side) |
| `validate-cysvuln-aie-joe.sh` | Joe-tier subset (prefer `--joe-only` on chain script) |
| `validate-three-box-chain.sh` | CysVuln → EWS → ASREP integrated campaign |
| `validate-asrep.sh` | Standalone ASREP DC smoke |
| `validate-chain8.sh` | **Local-only** Hack Academy Chain 8 (see below) |

## Validation tiers

| Tier | When | Command |
|------|------|---------|
| CI-safe | Every PR; no lab | `./scripts/test-local.sh` |
| Unit | Python helpers | `python3 -m pytest scripts/validate/tests -q` |
| Ansible syntax | Touching `ansible/` | `ansible-playbook --syntax-check ansible/playbooks/ews.yml` |
| VM smoke | Single box up | `./scripts/verify-cysvuln.sh <ip>`, `./scripts/verify-ews.sh <ip>`, `./scripts/verify-asrep.sh <ip>` |
| Campaign | Multi-box on vmbr1 | `./scripts/validate-three-box-chain.sh [--siem] [--pivot]` |
| VNC pipeline | EWS brute + PCAP | `./scripts/validate/validate-vnc-public-attack.sh --run-id <id>` |
| OPNsense NSM | Mirror + Suricata | `./scripts/validate/validate-opnsense-vnc-pipeline.sh --run-id <id> --target 192.168.61.20` |
| Prod proof | Live EWS over WG | `EWS_HOST=192.168.60.109 ./scripts/proxmox/reproduce-ews-prod-proof.sh` |

Hosted CI runs the CI-safe tier only.

## CysVuln AIE flow

1. `./scripts/verify-cysvuln.sh <ip>` — config smoke
2. `python3 scripts/validate/audit_aie.py ...` — registry audit
3. `python3 scripts/validate/check_efs69_response.py --mode callback` — foothold
4. `python3 scripts/validate/run_aie_via_efs_callback.py` — privesc proof

Or: `./scripts/validate-cysvuln-chain.sh 127.0.0.1` after `run-local-cysvuln.sh`.

## Chain 8 (local-only WIP)

`scripts/validate-chain8.sh` and `scripts/chain8-bridge-*.sh` are public
entrypoints for a **maintainer-local** Hack Academy AD Chain 8 lab
(`hackerblueprint.local`). The implementation under `scripts/ad-chain8/` is
gitignored and not shipped in fresh clones.

If you have the local checkout with `scripts/ad-chain8/` present, run:

```bash
./scripts/validate-chain8.sh preflight
./scripts/validate-chain8.sh runtime --strict
```

Otherwise use the three-box campaign validators above (`secretcon.local`).

## Dependencies

Run inside `nix develop` (pywinrm, keystone-engine, pytest, wixl, hydra, tshark).

Agent skill: `.claude/skills/validate-aie/SKILL.md`

Interactive debugging only (not a validation tier): `scripts/validate/debug_efs_exploit.sh`

Walkthrough: [docs/cysvulnserver/attack-faq-walkthrough.md](../../docs/cysvulnserver/attack-faq-walkthrough.md)
