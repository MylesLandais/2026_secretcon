# ews_reset_task

Deploys an in-guest scheduled task that resets shared EWS challenge state.

Default cadence is every 30 minutes, running as `SYSTEM`:

- removes `C:\Program Files\SecretCon\EWS.exe`
- verifies `SecretConEwsSync` points at the legitimate unquoted service binary
- restarts `SecretConEwsSync`
- deletes and reseeds Patrick's user flag via `C:\secretcon\seed-user-flag.ps1`
- restarts UltraVNC / `winvnc` state

Override with `ews_reset_task_interval_minutes` for round-based events.
