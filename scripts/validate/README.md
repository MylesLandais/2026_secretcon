# scripts/validate

Lab tooling to prove CysVulnServer images match the documented kill chain. Not shipped to players.

## Layout

```
validate/
  request_builder/     EFS 6.9 USERID overflow payload (ROP + shellcode)
  templates/           WiX template for AIE probe MSI
  tests/               pytest unit tests
  reference/           Upstream EDB PoCs for diffing
  audit_aie.py         WinRM AIE/UAC registry audit
  check_aie_response.py  Build validation MSI (wixl)
  check_efs69_response.py  Trigger EFS foothold
  run_aie_via_efs_callback.py  End-to-end AIE as User_Joe
```

## Typical flow

1. `./scripts/verify-cysvuln.sh <ip>` — config smoke
2. `python3 scripts/validate/audit_aie.py ...` — registry audit
3. `python3 scripts/validate/check_efs69_response.py --mode callback` — foothold
4. `python3 scripts/validate/run_aie_via_efs_callback.py` — privesc proof

Or: `./scripts/validate-cysvuln-chain.sh 127.0.0.1` after `run-local-cysvuln.sh`.

## Dependencies

Run inside `nix develop` (pywinrm, keystone-engine, pytest, wixl).

Agent skill: `.claude/skills/validate-aie/SKILL.md`

Walkthrough: [docs/cysvulnserver/walkthrough.md](../../docs/cysvulnserver/walkthrough.md)
