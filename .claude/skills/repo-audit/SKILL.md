---
name: repo-audit
description: Walk every file and line in the SecretCon repo; emit JSON/Markdown audit reports for docs, DRY, env vars, manifests, and Ansible migration parity.
---

# Repo audit

## When to use

- Before or after a cleanup/refactor pass (compare `audit/reports/` to `audit/reports/baseline/`).
- When checking whether a challenge box has deployment + attack + defend FAQs.
- When scoping the Ansible migration (see `ansible-migration-coverage` report).
- When finding scripts that should adopt `scripts/lib/*` helpers.

## Run

From the repository root:

```bash
python3 .claude/skills/repo-audit/audit.py
python3 .claude/skills/repo-audit/audit.py env-coverage
python3 .claude/skills/repo-audit/audit.py --baseline   # snapshot to audit/reports/baseline/
```

Dimensions: `box-doc-coverage`, `dry-clusters`, `env-coverage`, `manifest-parity`, `local-proxmox-pairing`, `cross-references`, `ephemeral-flags`, `ansible-migration-coverage`, or `all` (default).

Reports land in `audit/reports/*.json` and `audit/reports/*.md` (gitignored except `baseline/` if you choose to commit a snapshot).

## Interpreting reports

| Report | Use |
|--------|-----|
| `box-doc-coverage` | Per-box `attack-faq-walkthrough.md` / `defend-faq-walkthrough.md` / deployment presence |
| `dry-clusters` | Library adoption gaps; duplicate line clusters in `scripts/` |
| `env-coverage` | Vars referenced in code but missing from `example.env` |
| `manifest-parity` | Proxmox vs QEMU provision manifest set-diff per box |
| `local-proxmox-pairing` | Which `scripts/proxmox/*` scripts lack a local/QEMU counterpart |
| `cross-references` | Orphan candidates (in-degree 0) under `scripts/`, `docs/`, `provisioning/` |
| `ephemeral-flags` | probe/reproduce/proof/dated-note filename patterns |
| `ansible-migration-coverage` | PowerShell concern → Ansible role status (COVERED/PARTIAL/MISSING) |

## Related docs

- Per-box doc convention: [`docs/conventions.md`](../../docs/conventions.md)
- Ansible migration: [`docs/refactor/ansible-opentofu-migration.md`](../../docs/refactor/ansible-opentofu-migration.md)
- Parity matrix: [`docs/refactor/ansible-parity-matrix.md`](../../docs/refactor/ansible-parity-matrix.md)
