---
name: nix
description: Nix flake dev shells and local package builds for the SecretCon lab
---

# Nix

## When this skill applies

Reach for this skill when you need:

- The pinned toolchain on a contributor workstation (`packer`, `qemu`, `python3` + validation deps).
- A reproducible local QEMU build via `nix build` without hand-installing packages.
- The optional Kali-parity shell for walkthrough tooling (`msfvenom`, `nmap`, etc.).

Terraform and Proxmox-native builds still run on the lab host; Nix here is primarily the dev shell and the QEMU artifact derivations.

## Conventions in this repo

- Entry point is [flake.nix](flake.nix) at the repo root. Input pin: `nixpkgs` on `nixos-unstable`.
- `nix develop` — default shell: Packer, QEMU, xorriso, msitools (`wixl`), Python 3 with `pywinrm`, `pytest`, `jinja2`, `keystone-engine`, and `pkgsCross.mingwW64.buildPackages.gcc` for cross-compile experiments.
- `nix develop .#kali` — default shell plus packages from [kali.nix](kali.nix) (`nmap`, `metasploit`, `evil-winrm`, `exploitdb`). Heavy tools stay out of the default shell on purpose.
- `allowUnfree = true` in the flake import because some Windows-adjacent tooling may need unfree licenses in nixpkgs.
- Package outputs (not dev shells):
  - `.#win10-ews-local` — QEMU Packer build for Win10 LTSC EWS.
  - `.#cysvuln-local` — QEMU Packer build for CysVulnServer (requires staged Server 2016 ISO).
  - `.#win10-ews-proxmox` / `.#wazuh-siem-proxmox` — Proxmox-target derivations (need live Proxmox creds).
- `result` and `result/` are gitignored Nix output symlinks. Do not commit qcow2 artifacts.

## Canonical examples

- [flake.nix](flake.nix)
- [kali.nix](kali.nix)
- [docs/windows-image-inputs.md](docs/windows-image-inputs.md)
- [scripts/test-local.sh](scripts/test-local.sh) — cheap checks after `nix develop`

## Common pitfalls

- Running `nix build .#cysvuln-local` without `infrastructure/packer/iso/cysvuln-server-2016.iso` fails by design. Run `./scripts/stage-cysvuln-iso.sh` or `./scripts/fetch-iso.sh server-2016 <url>` first.
- Mixing system Python with flake Python breaks `import winrm` / `keystone`. Always enter `nix develop` before validation scripts.
- `kali.nix` only exports a package list. Do not add a second `mkShell` there; extend `devShells.kali` in `flake.nix` instead.
- Proxmox Packer builds from a laptop over WireGuard are slow and brittle. Prefer Nix-local QEMU iteration, then Proxmox-native bake on the host.

## References

- NixOS flake manual: https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html
- See also `packer/SKILL.md` for recipe layout and `validate-aie/SKILL.md` for Python exploit validation deps.
