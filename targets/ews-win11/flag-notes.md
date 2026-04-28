# EWS Win11 Flags

## Low-Priv User
- User: `patrick`
- Flag: `crit-low-priv-patrick`
- Path: `C:\secretcon\flag_lowpriv.txt`

## Attack Paths
1. AD pivot → EWS RDP/WinRM
2. ARP poison / AiTM on VLAN 10 (EtherNet/IP to PLC)
3. NanoKVM OOB HID hijack → Studio 5000 ladder rewrite

## PLC Access
- Studio 5000 / RSLogix / CCW for CompactLogix
- Fallback: pycomm3 Python scripts
