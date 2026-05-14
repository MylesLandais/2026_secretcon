# Contributing

Thanks for your interest in the SecretCon 2026 adversarial-sim threat range.
This repo is a working CTF lab. Contributions that improve reproducibility,
documentation, and detection coverage are especially welcome.

## Ground rules

This is a CTF training environment. By design, certain credentials, IP
ranges, and challenge spoilers live in the repo as OSINT material for
participants of [secretconctf.com](https://secretconctf.com/). Do not file
issues asking us to scrub them. Real production secrets (keys, sops files,
.env, dashboard admin passwords) must never land in this repo.

If you find a secret that should not be there, open a private security
advisory on the repo rather than a public issue.

## Development workflow

1. Fork the repo or create a feature branch off `main`.
2. Make your changes. Run `nix develop` to enter the dev shell.
3. Open a pull request against `main`. Squash-merge is the default.
4. CI will run `commit-lint` and `flake-check` on your PR.

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

## Agent skills

If you use Claude Code, Cursor, or another AI coding assistant on this
repo, the `.claude/skills/` directory holds skill definitions scoped to the
tools we use (Packer, Proxmox, Wazuh, Terraform). Add new skills under
this directory using the same vendor-named layout.

If you contribute a new tool to the stack, please add a matching skill
folder. The skills are part of the contribution surface, not an
afterthought.

## Reporting issues

Bug reports, lab access requests, and challenge ideas all go in GitHub
Issues. Lab-access requests should include your handle on the SecretCon
Discord or other community channel so we can verify membership.

## Code of conduct

By participating you agree to the [Contributor Covenant](CODE_OF_CONDUCT.md).
