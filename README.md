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
```

## Targets

| VM   | Role               | IP              | Notes                     |
|------|--------------------|-----------------|---------------------------|
| 101  | Wazuh SIEM         | 192.168.61.10   | Blue team log aggregation |
| 102  | Win11 EWS          | 192.168.61.20   | Red team pivot target     |

## Local Build (Cerberus NixOS)

Prerequisites: Windows 11 LTSC Eval ISO + virtio-win.iso in `~/Downloads/`

Don't have the ISO? Use Fido:

```bash
./scripts/fetch-iso.sh          # interactive
./scripts/fetch-iso.sh "Windows 11" "23H2" "Enterprise LTSC" "English"
```

Build:
```bash
nix build .#win11-ews-local
```

Run the resulting qcow2:
```bash
./scripts/run-local-vm.sh result/win11-ews-local.qcow2
```

RDP to `localhost:3389`, WinRM on `localhost:5985`.

## Proxmox Build

```bash
nix build .#win11-ews-proxmox
```

Requires `PROXMOX_URL`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET`, `WINRM_PASSWORD`.

## NixOS Integration

Import the local VM test module into your system config:

```nix
# ~/.config/nixos/configuration.nix
imports = [
  # ... your existing imports
  /home/warby/Workspace/2026_secretcon/infrastructure/nix/local-vm-test.nix
];
```

Then `sudo nixos-rebuild switch`.

## Conventional Commits

- `feat(infra):`
- `fix(packer):`
- `docs(targets):`
