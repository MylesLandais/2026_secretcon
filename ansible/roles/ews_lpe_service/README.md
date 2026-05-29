# ews_lpe_service

Unquoted `SecretConEwsSync` service path for EWS privilege escalation.

**Parity step_ids:** ews-011

**Verify:** `scripts/proxmox/probe-ews.sh` (ImagePath unquoted, Users modify on parent).

**Reset after solve:** the `ews_reset_task` role installs an in-guest
`SecretCon-EWS-Reset` scheduled task that removes
`C:\Program Files\SecretCon\EWS.exe`, restarts `SecretConEwsSync`,
restarts UltraVNC, and reseeds Patrick's user flag every 30 minutes by
default. Operators can force the same cleanup with
`(cd ansible && ansible-playbook playbooks/ews.yml -l ews-prod --tags ews_lpe_reset)`.
