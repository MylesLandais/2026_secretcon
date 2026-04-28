# 2026 SecretCon CTF Infrastructure

Monorepo for the 2026 SecretCon ICS/OT red-blue CTF environment.

## Quick Start

```bash
nix develop
```

## Structure

```
infrastructure/      # IaC — Packer, Terraform, NixOS modules
provisioning/        # Bootstrap scripts for all targets
targets/             # CTF-specific configs, flags, logic
docs/                # Architecture diagrams, runbooks
```

## Targets

| VM   | Role               | IP              | Notes                     |
|------|--------------------|-----------------|---------------------------|
| 101  | Wazuh SIEM         | 192.168.61.10   | Blue team log aggregation |
| 102  | Win11 EWS          | 192.168.61.20   | Red team pivot target     |

## Build

Proxmox Win11 EWS image:
```bash
nix build .#win11-ews-artifact
```

## Conventional Commits

- `feat(infra):`
- `fix(packer):`
- `docs(targets):`
