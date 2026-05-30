# CTF scheduled baseline reset

Host-side rollback to known-good Proxmox snapshots between event blocks.

## Tags

- Primary: `ctf-baseline`
- Legacy fallback: `baseline` (existing snapshots)

## Commands

```bash
# List snapshots
./scripts/host/ctf-baseline-reset.sh --list

# Preview (no rollback)
./scripts/host/ctf-baseline-reset.sh --dry-run --vmid 109 --vmid 119

# Execute (requires explicit enable)
CTF_SCHEDULED_RESET_ENABLED=1 ./scripts/host/ctf-baseline-reset.sh --vmid 109
```

## Create EWS baseline

```bash
./scripts/proxmox/baseline-snapshot-ews.sh --vmid 109 --name ctf-baseline
```

## NixOS timer (cerberus-nix)

Copy `provisioning/systemd/ctf-baseline-reset.{service,timer}` and set
`/etc/secretcon/ctf-reset.env` with `CTF_SCHEDULED_RESET_ENABLED=1` only during active play.

Default in `.env`: `CTF_SCHEDULED_RESET_ENABLED=0`.
