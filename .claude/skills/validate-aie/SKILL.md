---
name: validate-aie
description: Python validators for CysVuln EFS foothold and AlwaysInstallElevated privesc chain
---

# Validate AIE

## When this skill applies

Reach for this skill when:

- Verifying a CysVulnServer image after Packer or QEMU boot.
- Editing exploit/request code under `scripts/validate/`.
- Generating the WiX MSI probe used to prove SYSTEM-context `msiexec` under AIE.

This is lab validation tooling, not player-facing exploit delivery in production events (though the walkthrough reuses it).

## Conventions in this repo

### Package layout (`scripts/validate/request_builder/`)

- `request.py` — HTTP GET `/vfolder.ghp` with `UserID=` cookie; enforces cookie bad bytes (`NUL`, CR, LF, `0xFF`, space, semicolon).
- `rop.py` — EDB-37951 gadget chain against `ImageLoad.dll` in EFS 6.9; constants must stay aligned with the pinned installer hash.
- `shellcode.py` — keystone-assembled WinExec stager (ROR-13 hash `0x0E8AFE98`); `exec` mode forbids spaces in commands.
- `shellcode_callback.py` — reverse shell stager for callback mode.

### CLI tools

| Script | Role |
|--------|------|
| `check_efs69_response.py` | Send EFS USERID overflow (`callback`, `exec`, `dry-run`). |
| `audit_aie.py` | WinRM registry audit for AIE + UAC levers; optional `--profile-user` loads HKCU from NTUSER.DAT. |
| `check_aie_response.py` | Build validation MSI via `wixl` (msitools). |
| `run_aie_via_efs_callback.py` | End-to-end AIE proof as `User_Joe` over EFS callback shell. |

### Shell wrappers

- `scripts/verify-cysvuln.sh` — post-build smoke (WinRM registry + flags + **gated** `fswsService`/HTTP).
- `scripts/validate-cysvuln-chain.sh` — prep + smoke + audit + MSI stage + `run_aie_via_efs_callback.py`.
- `scripts/validate/test-cysvuln-efs-crash.sh` — exec stager crash + recovery gate.
- `scripts/validate/test-cysvuln-efs-clean.sh` — callback foothold without killing HTTP.
- `scripts/validate/resilience-local-qemu.sh` — local QEMU orchestrator (EWS + CysVuln crash/clean pairs).
- `scripts/test-local.sh` — `pytest` on `scripts/validate/tests/`.

### Dependencies

All pinned in `nix develop`: `python3Packages.pywinrm`, `keystone-engine`, `pytest`, `msitools` (`wixl`).

## Canonical examples

- [scripts/validate/run_aie_via_efs_callback.py](scripts/validate/run_aie_via_efs_callback.py)
- [scripts/validate/audit_aie.py](scripts/validate/audit_aie.py)
- [scripts/validate/reference/](scripts/validate/reference/) — upstream EDB PoCs for diffing
- [docs/cysvulnserver/attack-faq-walkthrough.md](docs/cysvulnserver/attack-faq-walkthrough.md)

## Common pitfalls

- `msiexec` via `schtasks` or `Start-Process -Credential` fails with 1601. Match the player path: interactive `User_Joe` after EFS foothold.
- Local QEMU uses port forwards: HTTP `127.0.0.1:18080`, WinRM `15985`. Set `WINRM_PORT` / `CYSVULN_HTTP_PORT` when scripting.
- Callback mode: guest reaches the host at `10.0.2.2` (QEMU user networking gateway), not `127.0.0.1`.
- ROP addresses drift if the EFS installer hash changes. Re-diff against `reference/edb-37951-efs69-userid-bof.py` after any installer update.

## References

- EDB-42256 (HTTP), EDB-37951 (USERID / ROP gadgets)
- See also `nix/SKILL.md`, `windows-bootstrap/SKILL.md`, `packer/SKILL.md`
