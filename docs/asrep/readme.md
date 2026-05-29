# ASREP demo DC

Standalone Windows Server 2016 domain controller for AS-REP roasting demos in the SecretCon range.

| Field | Value |
|---|---|
| OS | Windows Server 2016 |
| Domain | `secretcon.local` |
| NetBIOS | `SECRETCON` |
| DC hostname | `ASREP-DC` |
| Attack | AS-REP roast of `enite` (`DoesNotRequirePreAuth`) |
| Flag | `C:\Users\Public\enite-flag.txt` |
| MITRE | T1558.004 |

Independent of the Hack Academy AD Chain 8 reproduction (`hackerblueprint.local`).
That lab is **local-only WIP** — see [scripts/validate/README.md](../../scripts/validate/README.md#chain-8-local-only-wip).
The integrated SecretCon campaign uses `secretcon.local` via the three-box chain.

## Chain summary

1. **Enumeration** — Build a user list (decoy accounts plus `enite`).
2. **AS-REP roast** — `impacket-GetNPUsers` against `secretcon.local` with no credentials.
3. **Offline crack** — `hashcat -m 18200` against rockyou (password `stud87`).
4. **Detection** — Wazuh rule `100700` fires on Security EID 4768 with `preAuthType=0` for `enite@`.

## Hypervisor support

| Feature | QEMU (Nix) | Proxmox |
|---|---|---|
| Packer build | yes (`nix build .#asrep-local`) | yes (`infrastructure/packer/asrep/proxmox-vm-asrep.pkr.hcl`) |
| Boot / validate | yes (`scripts/run-local-asrep.sh`) | yes (`scripts/proxmox/deploy-asrep.sh`) |
| Local Wazuh docker SIEM | yes (agent group `asrep`, manager `10.0.3.2` on QEMU user-net) | native manager `192.168.61.10` |

## Quality control (local QEMU)

Full gate:

```bash
./scripts/wazuh-docker-up.sh
export WAZUH_MANAGER=10.0.3.2 SECRETCON_ASREP_FLAG='flag{asrep-local-test}'
./scripts/build-asrep-local.sh
./scripts/run-local-asrep.sh
./scripts/verify-asrep.sh 127.0.0.1
nix develop .#kali -c ./scripts/validate-asrep.sh
./scripts/validate-asrep-siem.sh
./scripts/observability/stress-campaign-asrep.sh --iterations 10
```

See [attack-faq-walkthrough.md](attack-faq-walkthrough.md) goal checklist and [defend-faq-walkthrough.md](defend-faq-walkthrough.md).

## Challenge components

| Component | Document |
|---|---|
| Attack walkthrough | [attack-faq-walkthrough.md](attack-faq-walkthrough.md) |
| Blue detection FAQ | [defend-faq-walkthrough.md](defend-faq-walkthrough.md) |
| Proxmox deploy | [reports/proxmox-deploy-recon.md](reports/proxmox-deploy-recon.md) |
| Infrastructure | this file |
| Wazuh rules | `infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml` IDs `100700`-`100702` |
| Agent group | `infrastructure/wazuh-docker/config/wazuh_cluster/shared/asrep/agent.conf` |

## Prerequisites (attacker host)

```bash
nix develop
# AS-REP tooling lives in the kali-parity shell:
nix develop .#kali
```

## Build (local QEMU)

Reuses the same Server 2016 ISO as CysVulnServer:

```bash
./scripts/stage-cysvuln-iso.sh /path/to/Windows_Server_2016_*.ISO
export SECRETCON_ASREP_FLAG='flag{asrep-local-test}'
export AD_SAFEMODE_PASSWORD='PizzaMan123!'
./scripts/build-asrep-local.sh
```

Or via Nix:

```bash
export SECRETCON_ASREP_FLAG='flag{asrep-local-test}'
nix build .#asrep-local
```

Result: `./result/asrep.qcow2` (archived under `artifacts/asrep/local-qemu/`)

## Boot (local QEMU)

| Host | Guest | Service |
|---|---|---|
| `127.0.0.1:18088` | `:88` | Kerberos (host forward; used by validate when guest IP is unrouted) |
| `127.0.0.1:15986` | `:5985` | WinRM |
| `127.0.0.1:13390` | `:3389` | RDP |

```bash
./scripts/run-local-asrep.sh
```

QEMU user-net assigns the guest `10.0.3.15` on `10.0.3.0/24` (avoids `br-chain8` on `10.0.2.0/24`). `./scripts/validate-asrep.sh` falls back to the `127.0.0.1:18088` forward when the guest IP is not routed on the host.

```bash
./scripts/validate-asrep.sh
```

Checks: Kerberos `:88` reachable, `$krb5asrep$` hash for `enite`, optional hashcat crack, optional WinRM logon.

## Credentials (intentional)

| Account | Password | Notes |
|---|---|---|
| `enite` | `stud87` | AS-REP target; crackable with rockyou |
| `Administrator` | `PizzaMan123!` | Domain admin after promotion; build / WinRM smoke |

Decoy users (`jdoe`, `asmith`, `bwilson`, `clee`, `dpark`) have random passwords and do not roast.

## SIEM

Bring up the local docker stack:

```bash
./scripts/wazuh-docker-up.sh
```

Sync custom rules (includes `100700`-`100702`):

```bash
./scripts/proxmox/sync-wazuh-rules.sh   # Proxmox manager
# or restart local docker manager after editing local_rules.xml
```

Expected alert after GetNPUsers:

| Rule | Event | Signal |
|---|---|---|
| `100700` | Security 4768 | AS-REQ for `enite@` with `preAuthType=0` |
| `100701` | Security 4769 | TGS for `enite@` with RC4 `0x17` |
| `100702` | Security 4624 | Logon as `enite` after crack |

## Artifacts

- Packer: `infrastructure/packer/asrep/local-qemu-asrep.pkr.hcl`
- Bootstrap: `provisioning/powershell/bootstrap_asrep.ps1`
- Post-promote verify: `provisioning/asrep/verify-post-promote.ps1`
- Validation: `scripts/validate-asrep.sh`, `scripts/validate-asrep-siem.sh`
- Config smoke: `scripts/verify-asrep.sh`
- Observability: `scripts/observability-loop-asrep.sh`, `scripts/observability/stress-campaign-asrep.sh`
- Proxmox: `scripts/proxmox/deploy-asrep.sh`, `scripts/proxmox/baseline-snapshot-asrep.sh`
