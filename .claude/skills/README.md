# Agent skills

This directory holds skill definitions for AI coding assistants working in
this repo. The aim is that an agent landing here picks up the same dialect
of Packer, Proxmox, Wazuh, OPNsense, and our writing style as the
maintainers.

## How agents use these files

Skills are loaded as project context by AI coding assistants (Claude
Code, Cursor, etc.) when they open the repo. An agent working on a Wazuh
rule reads `wazuh/SKILL.md`; an agent touching a firewall rule reads
`opnsense/SKILL.md`. Contributors do not need to invoke skills directly
— they are background context, not a runtime dependency.

The rule for human contributors: if your PR touches tool X, update
`.claude/skills/<X>/SKILL.md` in the same PR. Skills drift fast when
treated as documentation; treat them as part of the code surface.

See `CONTRIBUTING.md` for the full contribution policy.

## Layout

One folder per vendor or tool. Each folder contains a single `SKILL.md`.

```
.claude/skills/
  README.md              this file
  nix/SKILL.md
  packer/SKILL.md
  proxmox/SKILL.md
  wazuh/SKILL.md
  windows-bootstrap/SKILL.md
  validate-aie/SKILL.md
  hyperv/SKILL.md
  opnsense/SKILL.md
  terraform/SKILL.md
```

Skills are named for the underlying tool, not for an abstract role. If we
swap out a tool, the skill folder is renamed alongside the swap.

## Adding a skill

1. Create `.claude/skills/<tool>/SKILL.md`.
2. Follow the template below.
3. Reference the canonical files in this repo that demonstrate the skill.
4. Add an entry to the list above and update `CONTRIBUTING.md` if the new
   tool changes the contributor workflow.

## Template

```
---
name: <tool>
description: When and how to use <tool> in this repo
---

# <Tool>

## When this skill applies

Describe the situations in which an agent should reach for <tool> rather
than something else.

## Conventions in this repo

List the patterns we use: file locations, naming, idioms, gotchas.

## Canonical examples

Point at the files in this repo that demonstrate the pattern cleanly.

## Common pitfalls

What goes wrong in practice and how to recognize it.

## References

External docs, version pins, related skills.
```

## Style

Match the repo style: plain text, no emoji, no decorative formatting.
See `CONTRIBUTING.md`.
