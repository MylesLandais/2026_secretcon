# Packer SSH key

This directory holds the keypair Packer uses as its SSH communicator into the Win10 LTSC build VM. The keys themselves are gitignored (see `.gitignore`); regenerate locally:

```
ssh-keygen -t ed25519 -N '' -C 'packer@secretcon-build' \
  -f provisioning/ssh/packer_ed25519
```

Both `packer_ed25519` and `packer_ed25519.pub` are required:

- `packer_ed25519` — referenced by `infrastructure/packer/local-qemu.pkr.hcl` (`ssh_private_key_file`)
- `packer_ed25519.pub` — bundled onto the provisioning CD (`cd_files`); installed to `C:\ProgramData\ssh\administrators_authorized_keys` by `provisioning/setup-openssh.ps1`

## TODO / Open issue: secrets management

Today the keypair lives unencrypted on disk per developer. That is fine for a build-only key (it never leaves the lab and authorizes only into a throwaway VM), but the project will need a real story before we cut shareable templates or run CI:

- Decide between sops-nix, age, or a Vault/1Password-backed fetch step.
- Move the key out of the repo tree entirely (e.g., `~/.config/secretcon/`) and reference via Packer var.
- Document key rotation cadence and revocation path (replace `administrators_authorized_keys` on the golden image, rebuild).

Tracked here until we have a `docs/secrets.md` worth pointing at.
