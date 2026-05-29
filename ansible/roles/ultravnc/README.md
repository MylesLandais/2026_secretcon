# UltraVNC role (EWS foothold)

Replaces the legacy `tightvnc` role for EWS. Installs UltraVNC via
Chocolatey, applies a **known-good** `apply-known-good.ps1` script (ini +
password + listener + watchdog), and verifies live RFB VncAuth from the
controller.

## Workflow: hot patch → declarative converge

1. **Iterate fast** while tuning VNC config (~30s per loop):

```bash
./scripts/proxmox/hot-patch-ews-vnc.sh --ews-host <ip>
# or
./scripts/proxmox/converge-ews.sh --ews-host <ip> --hot-vnc
```

Runs only `ultravnc_hot` tasks: encode registry blob → copy/apply known-good
script → controller-side auth probe (no 60s guest waits).

2. **Promote to reproducible** once stable (full role + other EWS roles):

```bash
./scripts/proxmox/converge-ews.sh --ews-host <ip> --no-discover
```

The full path uses the same `apply-known-good.ps1` — edit that file when
changing challenge VNC behavior, then hot-patch to validate before a full
converge.

## Known-good script

`files/apply-known-good.ps1` is the single source of truth for:

- `[admin]` / `[poll]` ini flags (VncAuth, no MS-Logon, port 5900)
- `setpasswd.exe` (first 8 chars of planted password)
- ORL registry blob (Wazuh forensic parity)
- `winvnc -run` listener + startup watchdog scheduled task

## Verify

```bash
python3 ansible/roles/ultravnc/files/check_vnc_auth.py \
  --host <ip> --password FELDTECH_VNC \
  --cred-tool scripts/observability/vnc-cred-tool.py

python3 ansible/roles/ultravnc/files/check_vnc_auth.py \
  --host <ip> --wordlist provisioning/wordlists/vnc-betterdefaultpasslist.txt \
  --delay-seconds 0 --cred-tool scripts/observability/vnc-cred-tool.py
```

Hydra 9.x often fails against UltraVNC's multi security-type handshake; use
`check_vnc_auth.py` or Metasploit `vnc_login` for parallel brute validation.

## Legacy

The `tightvnc` role remains in-tree for reference but is no longer wired
into `playbooks/ews.yml`.
