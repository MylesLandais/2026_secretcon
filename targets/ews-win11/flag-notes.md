# EWS Win11 Flags

## Low-Priv User
- User: `patrick`
- Flag: `crit-low-priv-patrick`
- Path: `C:\Users\patrick\Desktop\flag.txt`
- Foothold: TightVNC on TCP `5900`
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
1. VNC brute force with default VNC password list → `patrick` desktop → user flag
2. Unquoted service path → LocalSystem → root flag
3. ARP poison / AiTM on VLAN 10 (EtherNet/IP to PLC)
4. NanoKVM OOB HID hijack → Studio 5000 ladder rewrite

## PLC Access
- Studio 5000 / RSLogix / CCW for CompactLogix
- Fallback: pycomm3 Python scripts
