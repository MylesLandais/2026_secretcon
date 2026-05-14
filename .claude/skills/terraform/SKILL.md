---
name: terraform
description: Placeholder. Terraform is in the dev shell but no code is in tree yet.
---

# Terraform

## Status

Reserved slot. `infrastructure/terraform/` is empty as of 2026-05-13.
Terraform is included in the `nix develop` shell because we expect to
manage Proxmox-side resources and possibly UniFi network configuration
through it once the lab substrate stabilises.

## When this skill will apply

Once code lands, the likely scope is:

- Proxmox VM lifecycle for stateless challenge VMs (replacing the
  bash `deploy-*.sh` scripts for cases where state and drift matter).
- DNS records for internal lab FQDNs.
- WireGuard peer management on the gateway, if the UniFi provider
  matures enough to make that practical.

## Conventions to apply when this skill is fleshed out

- One `*.tf` module per managed substrate (proxmox, dns, wireguard).
- State stored encrypted, never committed. Decide on a backend before
  the first `terraform apply`.
- Variables that look like secrets go through sops-age, not raw `.tfvars`.

## Open questions before adoption

- Backend choice (local-encrypted vs remote)?
- Provider versions: `Telmate/proxmox` vs `bpg/proxmox`?
- Do we replace the bash deploy scripts entirely, or run Terraform on
  top of them for declarative drift detection only?

Update this skill when those questions are answered.
