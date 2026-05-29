# EWS Win10 LTSC Flags

## Low-Priv User
- User: `patrick`
- Flag: `crit-low-priv-patrick`
- Path: `C:\Users\patrick\Desktop\flag.txt`
- Foothold: UltraVNC on TCP `5900`
- VNC password: `FELDTECH_VNC`
- Wordlist source: SecLists `Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt`

## Root Flag
- Flag: `crit-root-system-privs`
- Path: `C:\Users\Administrator\Desktop\root.txt`

## Priv Esc
- Service: `SecretConEwsSync`
- Display name: `SecretCon EWS Sync`
- Type: unquoted service path
- ImagePath: `C:\Program Files\SecretCon\EWS Sync\ews_sync.exe`
- Writable parent: `C:\Program Files\SecretCon\`
- Intended hijack path: `C:\Program Files\SecretCon\EWS.exe`

## Attack Paths
1. VNC brute force with default VNC password list -> `patrick` desktop -> user flag
2. Unquoted service path -> LocalSystem -> root flag

### Alternative credential-recovery side paths (no flag relocation)

The following artefacts only recover the planted `FELDTECH_VNC`
credential; the flags themselves stay where the rows above describe.
See [`docs/runbooks/ews-vnc-adversary-emulation.md`](../../docs/runbooks/ews-vnc-adversary-emulation.md)
for the generate / replay procedure.

3. **PCAP path (Arkime + standalone bundle).** A staged VNC auth
   handshake lives in the local-lab Arkime stack at
   `http://127.0.0.1:8005`. Extract the 16-byte challenge + 16-byte
   response from the RFB SPI view and recover the plaintext with
   `vncpasswd.py -d -C <chal> -R <resp>`. The same pcap is also
   committed as a standalone player-facing analyst challenge under
   [`targets/ews-vnc-pcap-forensics/`](../ews-vnc-pcap-forensics/README.md)
   (41 attempts, 1 success, validates 5/5 against
   `scripts/validate/validate-vnc-public-attack.sh`).
4. **SIEM forensic path (Wazuh).** A "previous adversary" trail in
   alerts.json shows brute-force burst (rule `100800`), audited
   registry read (rule `100805`), and an exfil receipt
   (`C:\Users\Public\vnc-pwd-dump.txt`, rule `100806`) whose
   `full_log` field carries the password hex blob. Feed to
   `vncpasswd.py -d -H <hex>` to recover the same plaintext.

## SIEM rules (rule pack `100800-100807`)

Custom rules in
[`infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml`](../../infrastructure/wazuh-docker/config/wazuh_cluster/local_rules.xml)
under group `secretcon,ews,windows,`:

- `100800` - VNC connection burst (10 connects in 60s, Sysmon EID 3)
- `100801` - legacy `tvnserver.log` authentication failure
- `100802` - `reg.exe query ... TightVNC\Server` or equivalent VNC password key read
- `100803` - VNC password registry value SET (baseline + rotation)
- `100804` - `vnc-pwd-dump.txt` file create (Sysmon EID 11)
- `100805` - Security EID 4663 Object Access on VNC password key (SACL audit)
- `100806` - hex blob exfil receipt (full_log carries the password bytes)
- `100807` - velocity correlation (`100800` then `100802/100804/100805` within 15 min)
