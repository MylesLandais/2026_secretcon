# SecretCon documentation conventions

Each challenge box in the lab should expose three documentation surfaces:

| Surface | Canonical filename | Audience |
|---------|-------------------|----------|
| Deployment | `docs/runbooks/deploy-*.md` and/or `infrastructure/packer/<box>/README.md` | Operators building or refreshing VMs |
| Attack walkthrough | `attack-faq-walkthrough.md` | Players / red team (VulnHub / HTB style) |
| Defend walkthrough | `defend-faq-walkthrough.md` | Defenders / blue team (rules, telemetry, triage) |

## Box doc indexes

| Box | Index | Attack | Defend |
|-----|-------|--------|--------|
| CysVuln | [docs/cysvulnserver/readme.md](cysvulnserver/readme.md) | [attack-faq-walkthrough.md](cysvulnserver/attack-faq-walkthrough.md) | [defend-faq-walkthrough.md](cysvulnserver/defend-faq-walkthrough.md) |
| EWS | [docs/ews/README.md](ews/README.md) | [attack-faq-walkthrough.md](ews/attack-faq-walkthrough.md) | [defend-faq-walkthrough.md](ews/defend-faq-walkthrough.md) |
| AS-REP / AD | [docs/asrep/readme.md](asrep/readme.md) | [attack-faq-walkthrough.md](asrep/attack-faq-walkthrough.md) | [defend-faq-walkthrough.md](asrep/defend-faq-walkthrough.md) |

Legacy names (`walkthrough.md`, `defend-faq-walkthrough.md`, `defend-faq-walkthrough.md`) remain as redirect stubs only.

## EWS vs tvn naming

The Windows VNC challenge box remains **EWS** in inventory, Packer,
Ansible, Proxmox, and player docs. `tvn` / `tvnserver` is legacy
telemetry naming from the old TightVNC implementation and should only be
used when referring to historical log paths or compatibility rules.
Do not rename the machine, VM, inventory host, or docs tree to `tvn`.

## Repo hygiene

- Run [repo-audit skill](../.claude/skills/repo-audit/SKILL.md) before and after refactors.
- Ephemeral notes belong under `docs/notes/archive/` or a dedicated skill, not beside player FAQs.
- In-VM configuration is migrating from Packer/PowerShell to Ansible; see [ansible-opentofu-migration.md](refactor/ansible-opentofu-migration.md) (ACTIVE), [ansible-parity-matrix.md](refactor/ansible-parity-matrix.md), [opentofu-proxmox-scope.md](refactor/opentofu-proxmox-scope.md).
