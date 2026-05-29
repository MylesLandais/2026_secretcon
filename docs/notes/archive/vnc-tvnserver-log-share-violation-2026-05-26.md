# TightVNC tvnserver.log share-mode lock blocks Wazuh agent reads

**Historical incident note (2026-05-26).** Durable troubleshooting steps
live in
[`docs/runbooks/ews-vnc-adversary-emulation.md`](../runbooks/ews-vnc-adversary-emulation.md#troubleshooting-wazuh-rule-100801-silent-tvnserverlog).
Keep this file for the full diagnosis timeline.

Captured 2026-05-26. Origin session: the SecLists VNC wordlist run against
EWS (VMID 109) produced zero `100800/100801` alerts despite a fully
configured pipeline. Two-layer root cause documented below so the next
visitor does not chase the same red herrings.

## TL;DR

1. **Layer 1 (fixed today):** `provisioning/powershell/bootstrap_win.ps1`
   installed TightVNC 2.8.87 with `SET_USEVNCAUTHENTICATION` /
   `VALUE_OF_PASSWORD` but omitted `SET_LOGLEVEL` and
   `SET_SAVELOGTOALLUSERSPATH`. TightVNC honors logging settings ONLY
   when they arrive via MSI properties (or the offline-config GUI).
   Post-install `Set-ItemProperty HKLM:\SOFTWARE\TightVNC\Server\LogLevel`
   is silently dropped — so the service ran with `LogLevel=0` and never
   created `tvnserver.log`. Wazuh rule 100801 cannot match a file that
   does not exist. **Fix: add the four MSI properties below; no version
   downgrade is required.** A brief detour through TightVNC 2.7.10
   confirmed both versions log fine when called with the right flags.

2. **Layer 2 (NOT fixed today — needs follow-up):** Once the log file
   exists, TightVNC opens it with `FILE_SHARE_NONE` (exclusive write
   lock). Wazuh's Windows logcollector uses libc `fopen("rb", ...)`,
   which on Win32 requests `FILE_SHARE_READ | FILE_SHARE_WRITE` — but
   that still loses to TightVNC's exclusive handle. The agent's
   `(1950): Analyzing file: ...` line in `ossec.log` fires at registration,
   not at first successful read. Subsequent open attempts fail with a
   sharing violation that the agent does not surface in `ossec.log`. The
   net effect: `tvnserver.log` is registered but never tailed. It does
   not appear in `wazuh-logcollector.state`, no content lines reach
   `archives.json` even with `<logall_json>yes</logall_json>`, and rule
   100801 stays silent.

## How the second layer was diagnosed

The smoking-gun test, run from EWS PowerShell while the service was
running and `tvnserver.log` was being actively appended:

```powershell
try {
  $fs = [System.IO.File]::Open(
    "C:\ProgramData\TightVNC\tvnserver.log",
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read
  )
  Write-Output "OPEN OK"
  $fs.Close()
} catch {
  Write-Output "OPEN FAIL: $($_.Exception.Message)"
}
```

Result on 2026-05-26 23:08Z:

```
OPEN FAIL (FileShare=Read): Exception calling "Open" with "4" argument(s):
"The process cannot access the file 'C:\ProgramData\TightVNC\tvnserver.log'
because it is being used by another process."
OPEN FAIL (FileShare=None): same error.
```

`Get-Content` works because the cmdlet opens with `FileShare.ReadWrite`
explicitly. The C runtime fopen used by Wazuh does not.

`wazuh-logcollector.state` after a full Wazuh agent restart, post-fix:

```
files: [
  "Microsoft-Windows-Sysmon/Operational",  events: 211,
  "active-response\\active-responses.log", events: 0,
  "System",      events: 0,
  "Security",    events: 196,
  "Application", events: 87,
  "logcollector", events: 2
]
```

`C:\ProgramData\TightVNC\tvnserver.log` is **absent** from the state
file. The agent registered the watch (`(1950): Analyzing file: ...`) but
never accumulated a single byte from it.

## Why the SIEM still produced *some* tvnserver noise

The agent did forward one related event: rule 591 ("Log file rotated.")
fires from the OSSEC-internal rotation watcher (which uses inode/size
comparisons on the directory listing, not file content). That is why
`alerts.json` contains:

```
{"rule":{"id":"591","description":"Log file rotated."},
 "full_log":"ossec: File rotated (inode changed): 'C:\\ProgramData\\TightVNC\\tvnserver.log'."}
```

despite zero content events.

## Resolution (shipped same session)

Option 1 (PowerShell `<command>` localfile) implemented end-to-end. The
moving parts:

1. **`provisioning/powershell/assets/wazuh-tvnserver-tail.ps1`** — opens
   tvnserver.log with `FileShare.ReadWrite | Delete` to bypass TightVNC's
   exclusive write lock, tracks read offset in
   `C:\ProgramData\WazuhTail\tvnserver.pos`, emits new lines on stdout.
   Forces `[Console]::OutputEncoding = ASCII` because PowerShell's
   default redirected-stdout encoding is UTF-16 LE — the Wazuh agent's
   command-localfile reader treats stdout as 8-bit and the embedded NUL
   after each char makes every line arrive as an empty body. ASCII is a
   safe subset for tvnserver.log content.

2. **Packer manifests** (`provision-manifest-{qemu,proxmox}.txt`) — the
   tailer rides the provisioning ISO next to `sysmonconfig.xml`.

3. **`provisioning/powershell/bootstrap_win.ps1`** — `Find-ProvisionFile`
   the tailer and `Copy-Item` it to `C:\secretcon\wazuh-tvnserver-tail.ps1`
   right after the TightVNC blacklist tuning block.

4. **`provisioning/powershell/lib/SecretCon.Bootstrap.psm1`** —
   `Install-SecretConWazuhAgent` now writes
   `logcollector.remote_commands=1` into
   `C:\Program Files (x86)\ossec-agent\local_internal_options.conf`
   before starting `WazuhSvc`. Wazuh ships with manager-pushed
   `<command>` localfiles default-denied as an RCE-hardening measure;
   the opt-in MUST live on the agent itself (it cannot be set by the
   shared agent.conf, for exactly that reason). Without this the agent
   logs `ERROR: Remote commands are not accepted from the manager.
   Ignoring it on the agent.conf` and silently drops the `<command>`
   block.

5. **`.../shared/ews/agent.conf`** — `<localfile>` switched from
   `<log_format>syslog</log_format>` (which fails due to the lock) to
   `<log_format>command</log_format>` with
   `<command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\secretcon\wazuh-tvnserver-tail.ps1"</command>`,
   `<alias>tvnserver-tail</alias>`, and `<frequency>30</frequency>`.

6. **`.../local_rules.xml` id=100801** — chains off Wazuh built-in
   rule 530 (`<if_sid>530</if_sid>`). Rule 530 is the parent rule that
   the manager's "ossec" decoder feeds when it sees
   `ossec: output: '<alias>': ...` lines from a command localfile. The
   `<match>` regex keeps the original literal `Authentication failed`
   alternation; `<location>` regex is kept as `(tvnserver-tail$|tvnserver\.log$)`
   so any future direct-tail consumer (file replay, an archive ingest,
   a different VNC server) still hits the same rule.

## Verification

End-to-end on the live EWS at 2026-05-26 23:36Z:

```
$ sudo grep -c '"id":"100801"' /var/ossec/logs/alerts/alerts.json
10
$ sudo grep '"id":"100801"' /var/ossec/logs/alerts/alerts.json \
    | grep -oE 'Authentication failed from [0-9.]+' | sort | uniq -c
     10 Authentication failed from 192.168.2.12
```

`wazuh-logtest -l tvnserver-tail` with a representative line produces
`Alert to be generated.` matching `rule:100801 level:8`.

The full SecLists `vnc-betterdefaultpasslist.txt` run still terminates at
the second password (`FELDTECH_VNC`) because Hydra exits on first hit per
host; the failed-auth tail comes from the early-list rejections and from
the standalone single-shot probes in this session. To get the full 40-fail
trail in one run, drop `FELDTECH_VNC` from the wordlist before invoking
hydra.

## What this note leaves correct in the repo

- `provisioning/powershell/bootstrap_win.ps1` — pinned at TightVNC
  2.8.87, MSI args carry `SET_LOGLEVEL=1`, `VALUE_OF_LOGLEVEL=5`,
  `SET_SAVELOGTOALLUSERSPATH=1`, `VALUE_OF_SAVELOGTOALLUSERSPATH=1`,
  and stages the tailer into `C:\secretcon\`.
- `provisioning/powershell/lib/SecretCon.Bootstrap.psm1` — writes
  `logcollector.remote_commands=1` to `local_internal_options.conf` as
  part of agent install.
- `provisioning/powershell/assets/wazuh-tvnserver-tail.ps1` — new asset,
  ASCII-encoded stdout, FileShare.ReadWrite, position-file tracking.
- `infrastructure/packer/ews/provision-manifest-{qemu,proxmox}.txt` —
  manifest entry added so a Packer bake includes the tailer on the
  provision ISO.
- `infrastructure/wazuh-docker/config/wazuh_cluster/shared/ews/agent.conf` —
  `<command>` localfile entry replaces the syslog tail.
- `infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml` —
  rule 100801 chains off 530 and matches on `tvnserver-tail` alias.

## What this note leaves open

- Rule 100800 (Sysmon EID 3 brute-force on tcp/5900) still does not fire
  despite Sysmon EID 3 events arriving on the manager. That is a
  separate, decoder/field-naming-shaped problem tracked elsewhere.

## Reference: the bootstrap MSI args block

Current (correct) shape, for posterity:

```powershell
"SET_USEVNCAUTHENTICATION=1", "VALUE_OF_USEVNCAUTHENTICATION=1",
"SET_PASSWORD=1",             "VALUE_OF_PASSWORD=FELDTECH_VNC",
"SET_USECONTROLAUTHENTICATION=1", "VALUE_OF_CONTROLAUTHENTICATION=1",
"SET_CONTROLPASSWORD=1",      "VALUE_OF_CONTROLPASSWORD=FELDTECH_VNC",
"SET_LOGLEVEL=1",             "VALUE_OF_LOGLEVEL=5",
"SET_SAVELOGTOALLUSERSPATH=1","VALUE_OF_SAVELOGTOALLUSERSPATH=1"
```

Same MSI properties work on both 2.7.10 and 2.8.87. Use 2.8.87.
