# Runbook: EWS VNC PCAP release

Use this when publishing the standalone VNC forensics capture as a GitHub
Release asset. The committed challenge bundle remains under
[`targets/ews-vnc-pcap-forensics/`](../../targets/ews-vnc-pcap-forensics/);
the release asset is the convenient download for participants who do not
clone the repo.

## Inputs

| File | Purpose |
|---|---|
| `targets/ews-vnc-pcap-forensics/vnc_auth.pcap` | Canonical capture: 41 auth attempts, 1 success |
| `targets/ews-vnc-pcap-forensics/wordlist.txt` | Matching SecLists VNC wordlist |
| `infrastructure/arkime-docker/pcaps/vnc_auth.pcap` | Local Arkime staging copy |

Keep the public PCAP small enough for easy browser download. The current
capture is about 69 KB; keep future releases under 5 MB unless the
challenge explicitly needs more traffic.

## Regenerate

For the synthetic proof capture:

```bash
./scripts/observability/vnc-pcap-proof.sh
cp artifacts/ews/proof/<run-id>/vnc_auth.pcap targets/ews-vnc-pcap-forensics/vnc_auth.pcap
cp targets/ews-vnc-pcap-forensics/vnc_auth.pcap infrastructure/arkime-docker/pcaps/vnc_auth.pcap
```

For a live lab capture, use the adversary-emulation output:

```bash
./scripts/observability/vnc-adversary-emulation.sh \
  --target 192.168.61.20 \
  --vnc-port 5900 \
  --winrm-port 5985 \
  --capture-iface any

cp artifacts/ews/vnc-foothold/<run-id>/vnc_auth.pcap targets/ews-vnc-pcap-forensics/vnc_auth.pcap
cp targets/ews-vnc-pcap-forensics/vnc_auth.pcap infrastructure/arkime-docker/pcaps/vnc_auth.pcap
```

Validate before publishing:

```bash
./scripts/validate/validate-vnc-public-attack.sh \
  --pcap targets/ews-vnc-pcap-forensics/vnc_auth.pcap \
  --wordlist targets/ews-vnc-pcap-forensics/wordlist.txt

sha256sum targets/ews-vnc-pcap-forensics/vnc_auth.pcap \
  targets/ews-vnc-pcap-forensics/wordlist.txt
```

## Arkime import

Local docker stack:

```bash
./scripts/arkime-docker-up.sh
./scripts/arkime-import-pcap.sh targets/ews-vnc-pcap-forensics/vnc_auth.pcap
```

Production `crit-capture`:

```bash
./scripts/proxmox/sync-arkime-pcap.sh targets/ews-vnc-pcap-forensics/vnc_auth.pcap
```

Viewer URLs:

- Local: `https://127.0.0.1:8005`
- Production: `http://192.168.61.11:8005`

## Publish Release Asset

Create or update a dated release. Include both the PCAP and wordlist so
participants can solve offline without cloning the repo.

```bash
TAG="vnc-pcap-forensics-$(date -u +%Y-%m)"
gh release create "$TAG" \
  --title "EWS VNC PCAP Forensics $(date -u +%Y-%m)" \
  --notes "Standalone EWS VNC authentication capture and matching wordlist. Recover the weak VNC password from the successful RFB challenge-response exchange." \
  targets/ews-vnc-pcap-forensics/vnc_auth.pcap \
  targets/ews-vnc-pcap-forensics/wordlist.txt
```

If the release already exists:

```bash
TAG="vnc-pcap-forensics-$(date -u +%Y-%m)"
gh release upload "$TAG" \
  targets/ews-vnc-pcap-forensics/vnc_auth.pcap \
  targets/ews-vnc-pcap-forensics/wordlist.txt \
  --clobber
```
