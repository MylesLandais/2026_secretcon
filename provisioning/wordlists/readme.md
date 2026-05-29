# Wordlists

Vendored slices of public wordlists, kept in tree so the proof and
adversary-emulation scripts work offline.

## vnc-betterdefaultpasslist.txt

41-entry default-credential list for VNC servers. Mirrored from
SecLists `Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt`
at the upstream master branch. The planted EWS credential
`FELDTECH_VNC` appears on line 2.

Regenerate from upstream with:

```bash
curl -sf \
  https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt \
  -o provisioning/wordlists/vnc-betterdefaultpasslist.txt
```

Consumers:

- `scripts/observability/vnc-cred-tool.py decode --wordlist ...`
- `scripts/observability/vnc-cred-tool.py crack --wordlist ...`
- `scripts/observability/vnc-wazuh-proof.sh`
- `scripts/observability/vnc-pcap-proof.sh`
- `scripts/observability/vnc-adversary-emulation.sh` (auto-detects)

Upstream license: MIT (SecLists). Mirrored content remains under
upstream terms.
