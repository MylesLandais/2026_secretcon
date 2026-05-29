# Runbook: Wazuh dataset export and replay

Turn the output of a `scripts/observability-loop.sh` run into:

1. A **portable forensic dataset** that an analyst (human or LLM-driven)
   can grep for proof artefacts - flag tokens, `aie-flag.txt` creations,
   the SYSTEM-integrity child of `msiexec.exe`, etc.
2. A **replayable corpus** that gets re-ingested into a *different*
   Wazuh manager - typically the SecretCon production-lab manager on
   Proxmox (`192.168.61.10`, VMID `110`) - so SIEM dashboards, custom
   rules, and saved searches can be exercised against captured attack
   traffic without re-running the validator chain on that system.

Source scripts:

- [`scripts/wazuh-export-dataset.sh`](../../scripts/wazuh-export-dataset.sh)
- [`scripts/wazuh-replay-to-proxmox.sh`](../../scripts/wazuh-replay-to-proxmox.sh)

## 0. Pre-requisites

| What | Where |
| --- | --- |
| A completed loop run | `artifacts/cysvuln/observability-loop/<run-id>/` |
| Local docker stack still up | `docker ps` shows `wazuh.manager`, `wazuh.indexer`, `wazuh.dashboard` |
| `jq`, `zstd`, `python3-winrm`, `python3` | `nix develop` shell |
| Proxmox Wazuh reachable (for replay only) | `ping 192.168.61.10` from the workstation via WireGuard, or via the Proxmox host tunnel |

For maximum-fidelity datasets, make sure the manager has
`<logall_json>yes</logall_json>` enabled (the in-tree config does, as of
this commit). Without it, `archives/archives.json` will be empty and the
dataset is alerts-only - still useful, but Sysmon EID 1/3/11/13 events
that did not trigger a rule will not be in the corpus.

## 1. Export the dataset

The simplest invocation - capture *everything* the local manager
currently has, trimmed to the union of iteration time windows, and
tarball the result:

```
./scripts/wazuh-export-dataset.sh \
    --run-id loop-20260525T035312Z \
    --window-from-loop \
    --tarball
```

Output:

```
artifacts/cysvuln/observability-loop/loop-20260525T035312Z/dataset/
  alerts/alerts.json            # newline-delimited; one alert per line
  alerts/alerts.log             # human-readable mirror
  archives/archives.json        # every decoded event (logall_json=yes)
  archives/archives.log
  manager/ossec.conf
  manager/local_rules.xml       # SecretCon custom rules 100501-100517
  agent/agent.conf              # shared/ews/agent.conf at export time
  agent/agents.json             # manager API /agents
  agent/groups.json
  indexer/indices.txt           # _cat/indices
  indexer/health.json           # _cluster/health
  loop/summary.csv              # iter,start,end,chain_exit,alert_count,...
  loop/raw-notes.md
  loop/iter-N/{summary.json,msiexec-timeline.json,chain.log,ossec.log.tail}
  MANIFEST.md                   # what / when / how to grep
  sha256sums.txt                # tamper-evident manifest

artifacts/cysvuln/observability-loop/loop-20260525T035312Z/dataset.tar.zst
artifacts/cysvuln/observability-loop/loop-20260525T035312Z/dataset.tar.zst.sha256
```

Crucially, `flags.env` is **deliberately not copied** into the dataset.
The whole point of the corpus is for an analyst to *recover* the flag
tokens (or to prove they are unrecoverable from SIEM data alone, which
is the realistic outcome for file-content based flags).

### Common export variants

- **Just alerts, no archives (the small, cheap dataset)**

  ```
  ./scripts/wazuh-export-dataset.sh --run-id <id> --no-archives
  ```

- **One iteration only**: trim the window manually:

  ```
  ./scripts/wazuh-export-dataset.sh --run-id <id> \
      --window-from-loop \
      --out-dir artifacts/cysvuln/observability-loop/<id>/dataset-iter-1
  # then manually edit alerts/archives to keep only iter-1's window, or
  # supply a custom start/end via wazuh-drain-alerts.sh first.
  ```

- **Different stack name**:

  ```
  WAZUH_MANAGER_CONTAINER=wazuh-prod.manager \
      ./scripts/wazuh-export-dataset.sh --run-id <id>
  ```

## 2. Analyst-side: find proof in the dataset

The intended analyst workflow on a dataset:

```
ds=artifacts/cysvuln/observability-loop/<id>/dataset

# Every msiexec spawn (process create), in time order
jq -c 'select(
        (.data.win.eventdata.image // "" | test("(?i)msiexec\\.exe$"))
     or (.data.win.eventdata.parentImage // "" | test("(?i)msiexec\\.exe$"))
       )
       | {ts:.timestamp, parent:.data.win.eventdata.parentImage,
          image:.data.win.eventdata.image,
          cmd:.data.win.eventdata.commandLine,
          il:.data.win.eventdata.integrityLevel}' \
    $ds/archives/archives.json | head

# Any access to the AIE flag drop file
grep -E 'aie-flag\.txt' $ds/alerts/alerts.log $ds/archives/archives.log

# Any line containing a SecretCon flag token (only present if the flag
# crossed a logged process arg or file path)
grep -E 'flag\{(user|root)-[0-9a-f]+\}' \
    $ds/alerts/alerts.log $ds/archives/archives.log || \
    echo "[no direct flag tokens in SIEM logs - expected for file-content flags]"

# Sysmon EID 11 file create on user/root flag txts
jq -c 'select(.data.win.system.eventID == "11"
              and (.data.win.eventdata.targetFilename // "" |
                   test("(?i)(user\\.txt|root\\.txt|aie-flag\\.txt)$")))' \
    $ds/archives/archives.json
```

If your validator chain leaks a flag into a base64-encoded PowerShell
command line (`-EncodedCommand`), grep with:

```
jq -r '.data.win.eventdata.commandLine // empty' $ds/archives/archives.json \
  | grep -Eo '[-]EncodedCommand [A-Za-z0-9+/=]+' \
  | awk '{print $2}' | while read enc; do
        echo "---"; echo "$enc" | base64 -d 2>/dev/null
    done
```

Then grep the decoded output for `flag{`.

## 3. Replay the dataset into the Proxmox Wazuh manager

The Proxmox-side production manager already has the Wazuh API, indexer,
and dashboard. We just need to enable a syslog receiver, ship the
events, and verify the same custom rules fire there too.

### 3a. Enable a syslog `<remote>` block on the Proxmox manager

SSH to the manager VM (via the Proxmox host's tunnel for routing):

```
ssh -J root@192.168.60.1 wazuh@192.168.61.10
sudo -i
```

Add a second `<remote>` block to `/var/ossec/etc/ossec.conf` (alongside
the existing `<connection>secure</...>` block on 1514):

```xml
<remote>
  <connection>syslog</connection>
  <protocol>tcp</protocol>
  <port>514</port>
  <!-- limit to the workstation that will run wazuh-replay-to-proxmox.sh.
       If you are on WireGuard, allow your tunnel CIDR; otherwise
       allow the host you are running the replay from. -->
  <allowed-ips>192.168.60.0/24</allowed-ips>
  <local_ip>192.168.61.10</local_ip>
</remote>
```

Make sure the SecretCon custom rules exist on the production manager too
so re-decoded events trigger the same alerts:

```
scp -J root@192.168.60.1 \
    infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml \
    wazuh@192.168.61.10:/tmp/local_rules.xml

ssh -J root@192.168.60.1 wazuh@192.168.61.10 \
    "sudo install -o root -g wazuh -m 0640 \
        /tmp/local_rules.xml /var/ossec/etc/rules/local_rules.xml && \
     sudo systemctl restart wazuh-manager"
```

Verify the listener:

```
ssh -J root@192.168.60.1 wazuh@192.168.61.10 \
    "sudo ss -tlnp | grep ':514'"
```

You should see `wazuh-remoted` bound to `192.168.61.10:514`.

### 3b. Dry-run the replay

From the workstation (with the dataset locally available):

```
./scripts/wazuh-replay-to-proxmox.sh \
    --dataset artifacts/cysvuln/observability-loop/<id>/dataset \
    --target 192.168.61.10:514 \
    --source archives \
    --rate 200 \
    --dry-run
```

This prints the first three wire-format messages without opening a
socket. Each message looks like:

```
<134>1 2026-05-25T04:21:13.701+0000 my-host wazuh-replay - loop-<id> \
[SECRETCON-REPLAY run_id=loop-<id> orig_ts=2026-05-25T04:21:13.701+0000 source=archives] \
{"timestamp":"2026-05-25T...","rule":{"id":"100512",...},"data":{"win":{...}}}
```

Inspect the structured-data tag and the trailing JSON; the receiving
manager's `json_log` decoder parses the JSON object and your custom
rules 100510-100517 re-fire on the production indexer.

### 3c. Live replay

Drop `--dry-run`:

```
./scripts/wazuh-replay-to-proxmox.sh \
    --dataset artifacts/cysvuln/observability-loop/<id>/dataset \
    --target 192.168.61.10:514 \
    --source archives \
    --rate 200
```

Progress prints to stderr every five seconds (`sent N (errors=0, X.X eps)`).
For a typical 4 MB / ~1200-event alerts.json corpus this completes in
~6 seconds at 200 eps; for a 100 MB archives.json plan on tens of
minutes.

### 3d. Verify on the production dashboard

```
ssh -N -L 8443:192.168.61.10:443 root@192.168.60.1
# open https://localhost:8443 (admin / dashboard pw)
```

In the dashboard:

- Set the time range to **Last 15 minutes**.
- Discover -> filter `rule.groups: secretcon` to see your replayed
  events (the custom rules 100501-100517 fire again).
- Search the structured-data tag in the raw message field for
  `SECRETCON-REPLAY run_id=loop-<id>` to confirm provenance.

## 4. Restore - drop a dataset back into a fresh local lab

If you tore down the local docker stack (`./scripts/wazuh-docker-down.sh
--wipe`) and want to inspect an older dataset interactively:

```
./scripts/wazuh-docker-up.sh
# replay the dataset into the local manager (note: target is the
# host-bound port 514? - the local stack does NOT expose 514 by
# default; either:
#   - add a syslog <remote> block + port mapping to docker-compose.yml,
#   - or simply load the JSON files into a separate analysis tool
#     (jq / DuckDB / OpenSearch direct ingest):
)
```

For local analysis without a re-ingest, `jq` + the manifest on the
dataset itself is usually enough; the OpenSearch indexer is only worth
restoring into for dashboard/visualisation work, in which case the
production Proxmox manager (steps 3a-3d) is the better target.

## 5. Operational caveats

- **Timestamps**: the receiving manager stamps its own ingestion time.
  We preserve the original `timestamp` field inside the JSON payload
  and an `orig_ts=...` structured-data tag, so analysts can pivot in
  either dimension.
- **Rule re-firing volume**: replaying `archives.json` will multiply
  alert volume on the production indexer roughly by the original
  capture rate. Throttle with `--rate` and use `--limit` for smoke
  testing.
- **Allowed-ips**: do not leave the `<remote>` syslog block open to
  `0.0.0.0/0` once replay testing is done.
- **Rule parity**: if you tweak `local_rules.xml` in-tree, re-`scp` it
  to the Proxmox manager and restart `wazuh-manager` before the next
  replay - otherwise rule IDs will mismatch.
- **Flag content in SIEM**: file-content flags (`flag{user-...}` inside
  `C:\Users\Joe\Desktop\user.txt`) do not appear in Sysmon. The dataset
  proves *access*, not *content*. If you want content-grade telemetry,
  add a Wazuh `<localfile>` block targeting the flag file's full path
  as `syslog` format on the agent side - but consider whether you want
  the solution in the SIEM logs at all.

## References

- [`infrastructure/wazuh-docker/`](../../infrastructure/wazuh-docker/)
- [`docs/cysvulnserver/defend-faq-walkthrough.md`](../cysvulnserver/defend-faq-walkthrough.md)
- [`scripts/observability-loop.sh`](../../scripts/observability-loop.sh)
- Wazuh syslog ingestion:
  <https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/remote.html>
