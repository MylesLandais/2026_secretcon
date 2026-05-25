# Contributing

Thanks for your interest in the SecretCon 2026 adversarial-sim threat range.
This repo is a working CTF lab. Contributions that improve reproducibility,
documentation, and detection coverage are especially welcome.

## Ground rules

This is a CTF training environment. Some of what looks like a secret in
this repo is intentional OSINT material for participants of
[secretconctf.com](https://secretconctf.com/):

- The Win10 EWS challenge ships with a known-bad VNC password drawn from
  the public SecLists default-credentials list. That is the intended
  foothold.
- `targets/ews-win11/flag-notes.md` documents the intended kill chain.
- The `SecretConEwsSync` service has an unquoted image path on purpose.
  It is the intended local-privilege-escalation primitive.
- Lab IP ranges, the `secret-ctf.com` and `care-secllc.com` domains, and
  the topology in `docs/architecture.md` are all part of the training
  scenario.

Do not file issues asking us to scrub these.

## Real secrets (not CTF material)

These must never land in git:

- `.env` (copy from `example.env`)
- `wazuh-creds-*.txt`, `*.pem`, `provisioning/ssh/packer_ed25519` (private key)
- Live Proxmox or Wazuh passwords that match committed CTF defaults

Rotate lab infrastructure passwords before making the repo public if they
reuse values like `PizzaMan123!` from challenge autounattend files.

If you find a real secret in history, contact maintainers privately rather
than opening a public issue with the value.

## Development workflow

1. Fork the repo or create a feature branch off `main`.
2. Make your changes. Run `nix develop` to enter the dev shell.
3. Open a pull request against `main`. Squash-merge is the default.
4. CI will run `commit-lint` and `flake-check` on your PR (cheap checks only).
5. Run `./scripts/test-local.sh` before pushing. VM builds are validated on
   your hypervisor (QEMU, Proxmox, VMware, or Hyper-V), not in GitHub Actions.

## Commit message policy

We follow [Conventional Commits](https://www.conventionalcommits.org/).

Format:

```
<type>(<scope>): <description>

[optional body]
```

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `chore`, `ci`.

Rules:

- Imperative mood: "add the thing", not "added the thing".
- Subject line at most 72 characters, no trailing period.
- Body wrapped at 100 characters. Explain why, not what.
- No AI attribution lines, no `Co-Authored-By` claude tags, no marketing
  footer.

**Emoji policy:** Commits whose subject or body contains emoji will be
rejected by CI and blocked by maintainers. This is enforced by the
`commit-lint` workflow. The same rule applies to documentation files in
this repo.

Examples:

```
feat(packer): pivot Win10 LTSC build to SSH communicator
```

```
fix(provisioning): correct UEFI partition layout in autounattend
```

## Writing style for docs

The repo style is plain text, no decorative formatting. Match what you see
in existing files.

- No emoji anywhere.
- No bold or italic for emphasis. Use clear sentences instead.
- No decorative box-drawing, no ASCII art banners.
- Bullet lists are fine in technical reference material. Avoid them in
  prose paragraphs.
- File names: lowercase with hyphens. No `README_FINAL_v2.md`.
- Date-stamped filenames are reserved for incident notes and dated
  discovery logs (for example `docs/proxmox-import-discovery-2026-05-12.md`).
  Living documentation should not carry a date.

## Repo layout

```
infrastructure/      IaC: Packer, Proxmox scripts, Terraform, NixOS modules
provisioning/        Bootstrap scripts and cloud-init payloads
targets/             CTF-specific configs, flag notes, challenge logic
docs/                Architecture and runbooks
scripts/             Local developer scripts
.claude/skills/      AI agent skill definitions, one folder per tool
```

## How agent skills work

`.claude/skills/` holds skill definitions read by AI coding assistants
(Claude Code, Cursor, etc.) when they open the repo. They are loaded as
project context, scoped to a vendor or tool: `nix/`, `packer/`, `proxmox/`,
`wazuh/`, `windows-bootstrap/`, `validate-aie/`, `hyperv/`, `opnsense/`,
`terraform/`.

Contributors do not need to use the skills directly. The expectation is
that PRs touching tool X also update `.claude/skills/<X>/SKILL.md` in
the same PR. Treat skills as part of the code surface, not as separate
documentation. A new tool in the stack means a new skill folder.

The "skill + runbook + canonical script" triad is the shape we aim for:

- `.claude/skills/<tool>/SKILL.md` — conventions and pitfalls.
- `docs/runbooks/deploy-<target>.md` — step-by-step deploy procedure.
- `scripts/<tool>/<verb>-<target>.sh` — the canonical script the
  runbook references.

When any one of those changes, check whether the other two need to move
with it.

## Build paths: Nix-local vs Proxmox

The lab supports two build paths for the Win10 EWS challenge VM:

- **Nix-local** (`flake.nix .#win10-ews-local` plus Packer's QEMU
  builder). Builds a qcow2 on your workstation. Fast iteration, runs in
  software-only QEMU, exposes RDP/WinRM/VNC on `localhost`. Use this
  while developing autounattend changes or bootstrap scripts.
- **Proxmox-native** (`cd infrastructure/packer/ews && packer build -only=proxmox-iso.win10-ews .`).
  Builds directly on the Proxmox host using the `proxmox-iso` builder.
  Slower iteration, produces the actual lab VM on `vmbr1`. Use this
  once the local build is green.

Practical rule: test changes on the Nix-local path first. The Proxmox
build pulls a fresh ISO over the lab uplink and a failed run wastes
real time. The two paths share the same `provisioning/` scripts; if you
change one, the other gets the same code.

## Agent skills

See `.claude/skills/README.md` for the index. New tool in the stack
means a new skill folder.

## Reporting issues

Bug reports, lab access requests, and challenge ideas all go in GitHub
Issues. Lab-access requests should include your handle on the SecretCon
Discord or other community channel so we can verify membership.

## Pre-publish checklist (maintainers)

Before a public push or event handoff:

1. `git status` — never `git add .`
2. Confirm `.env`, `wazuh-creds-*.txt`, `*.qcow2`, and `artifacts/` are not staged
3. `./scripts/test-local.sh`
4. Dry-run one build path per hypervisor you support (see `docs/windows-image-inputs.md`)
5. Rotate live Proxmox/Wazuh passwords away from committed CTF defaults
6. `./scripts/fetch-cysvuln-artifacts.sh` on a fresh clone to verify artifact docs
