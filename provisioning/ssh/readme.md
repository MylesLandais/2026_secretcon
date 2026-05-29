# Packer SSH key

This directory holds the keypair Packer uses as its SSH communicator into the Win10 LTSC build VM. The keys themselves are gitignored (see `.gitignore`); regenerate locally:

```
ssh-keygen -t ed25519 -N '' -C 'packer@secretcon-build' \
  -f provisioning/ssh/packer_ed25519
```

Both `packer_ed25519` and `packer_ed25519.pub` are required:

- `packer_ed25519` — referenced by Packer QEMU/Hyper-V/VMware recipes (`ssh_private_key_file`)
- `packer_ed25519.pub` — bundled on the PROVISION CD/floppy; installed to `C:\ProgramData\ssh\administrators_authorized_keys` by [`provisioning/openssh/setup-openssh.ps1`](../openssh/setup-openssh.ps1)

EWS QEMU recipe: [`infrastructure/packer/ews/local-qemu-ews.pkr.hcl`](../../infrastructure/packer/ews/local-qemu-ews.pkr.hcl)

## TODO / Open issue: secrets management

Today the keypair lives unencrypted on disk per developer. That is fine for a build-only key (it never leaves the lab and authorizes only into a throwaway VM), but the project will need a real story before we cut shareable templates or run CI:

- Decide between sops-nix, age, or a Vault/1Password-backed fetch step.
- Move the key out of the repo tree entirely (e.g., `~/.config/secretcon/`) and reference via Packer var.
- Document key rotation cadence and revocation path (replace `administrators_authorized_keys` on the golden image, rebuild).

Tracked here until we have a `docs/secrets.md` worth pointing at.
