# Runbook: secrets scan POC

This repo intentionally contains CTF credentials, flags, domains, and lab
addresses. A secrets scanner is still useful, but the first pass should be
manual and report-only so reviewers can separate intended challenge material
from real infrastructure secrets.

## Run gitleaks locally

```bash
nix-shell -p gitleaks --run 'gitleaks detect --source . --verbose --redact'
```

For an unredacted maintainer-only review:

```bash
nix-shell -p gitleaks --run 'gitleaks detect --source . --verbose'
```

Do not paste unredacted findings into public issues or PR comments.

## Triage

Expected CTF material:

- `FELDTECH_VNC` in wordlists, EWS walkthroughs, and validation tests.
- `crit-low-priv-patrick` and `crit-root-system-privs` in challenge notes.
- Example lab defaults in `example.env`, Packer autounattend files, and
  player-facing docs.
- Public lab IP ranges, domains, and usernames that are part of the scenario.

Unexpected real secrets:

- `.env` or copied environment files.
- Private keys such as `provisioning/ssh/packer_ed25519`.
- Live Proxmox, OPNsense, Wazuh, GitHub, or cloud API tokens.
- Unsanitized OPNsense `config.xml` exports containing API keys,
  certificate private keys, or password hashes.

## Report format

For now, attach a short maintainer-only note with:

```text
scanner: gitleaks
command: gitleaks detect --source . --verbose --redact
date: YYYY-MM-DD
result: pass with expected CTF findings / fail with unexpected secret
unexpected findings:
- path:line, secret type, rotation status
```

## Future CI gate

Do not add a GitHub Actions gate until the intentional CTF material has a
reviewed allowlist. A useful next step is a committed gitleaks config that
allows only documented challenge strings and still fails on `.env`, private
keys, and unsanitized infrastructure exports.
