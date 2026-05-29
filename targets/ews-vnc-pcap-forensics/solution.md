# Solution — VNC PCAP Forensics

> **Flag: `flag{FELDTECH_VNC}`**
>
> Keep this file out of any player-facing distribution.

## Overview

- **PCAP:** [`vnc_auth.pcap`](vnc_auth.pcap) (69 137 bytes, 873 packets,
  capture window ~2 min, attacker `192.168.2.12` → victim
  `192.168.60.109:5900`).
- **Wordlist:** [`wordlist.txt`](wordlist.txt) — the SecLists
  `Passwords/Default-Credentials/vnc-betterdefaultpasslist.txt`, 41
  entries, ASCII LF-terminated.
- **Answer:** `FELDTECH_VNC` (wordlist entry #2). Wrapped: `flag{FELDTECH_VNC}`.

The pcap was produced live against the SecretCon 2026 EWS lab on
2026-05-26 via [`scripts/observability/vnc-public-attack.sh`](../../scripts/observability/vnc-public-attack.sh)
and reused into Arkime with
[`scripts/proxmox/sync-arkime-pcap.sh`](../../scripts/proxmox/sync-arkime-pcap.sh).
All five assertions of [`scripts/validate/validate-vnc-public-attack.sh`](../../scripts/validate/validate-vnc-public-attack.sh)
pass against this exact pcap.

## Reference walkthrough

### 1. Identify the one successful TCP stream

```bash
tshark -r vnc_auth.pcap -Y 'vnc.auth_response' -T fields -e tcp.stream | wc -l
# -> 41 authentication response frames (one per attempt)
```

The naive filter `vnc.auth_result == 0` returns **41 matches**, which is
a red herring — TightVNC sends a reason-string after the result on
failure, and Wireshark's dissector re-parses parts of that string as
extra `vnc.auth_result` frames. The correct logic is *the first*
`vnc.auth_result` frame per `tcp.stream`:

```bash
tshark -r vnc_auth.pcap -Y 'vnc.auth_result' \
  -T fields -e tcp.stream -e vnc.auth_result \
| awk -F'\t' '!seen[$1]++ { if ($2 == "False" || $2 == "0") print $1 }'
# -> 1
```

That single stream is the second attempt of the brute force
(wordlist entry #2 = `FELDTECH_VNC`).

### 2. Extract the chal/resp pair

```bash
tshark -r vnc_auth.pcap -Y 'tcp.stream == 1 and (vnc.auth_challenge or vnc.auth_response)' \
  -T fields -e vnc.auth_challenge -e vnc.auth_response
# -> ccd03faca6a6cd118ee85bb013788db3  (server -> client challenge)
# -> (next row)                         8361102fb04a6fddae7676935c46665c  (client -> server response)
```

### 3. Crack the response

```bash
nix develop --command python3 scripts/observability/vnc-cred-tool.py crack \
  --challenge ccd03faca6a6cd118ee85bb013788db3 \
  --response  8361102fb04a6fddae7676935c46665c \
  --wordlist  targets/ews-vnc-pcap-forensics/wordlist.txt
# -> FELDTECH_VNC
```

## Algorithm reference (RealVNC / TightVNC challenge-response)

```python
from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
from cryptography.hazmat.primitives.ciphers import Cipher, modes

def bitrev(b):
    b = ((b & 0x55) << 1) | ((b >> 1) & 0x55)
    b = ((b & 0x33) << 2) | ((b >> 2) & 0x33)
    b = ((b & 0x0F) << 4) | ((b >> 4) & 0x0F)
    return b & 0xFF

def vnc_response(password: bytes, challenge: bytes) -> bytes:
    key = bytes(bitrev(b) for b in password.ljust(8, b'\0')[:8])
    cipher = Cipher(TripleDES(key), modes.ECB()).encryptor()
    return cipher.update(challenge) + cipher.finalize()
```

The wordlist is iterated; the entry whose `vnc_response(pw, chal)`
equals the captured response is the password.

## Instructor crib sheet

| Item                              | Value                                                       |
|-----------------------------------|-------------------------------------------------------------|
| Attacker IP                       | `192.168.2.12`                                              |
| Victim IP / port                  | `192.168.60.109:5900`                                       |
| Successful `tcp.stream`           | `1` (second attempt of brute force)                         |
| 16-byte challenge (hex)           | `ccd03faca6a6cd118ee85bb013788db3`                          |
| 16-byte response (hex)            | `8361102fb04a6fddae7676935c46665c`                          |
| Password (wordlist entry #2)      | `FELDTECH_VNC`                                              |
| Stored-blob (TightVNC `HKLM` `Password`) | `52-E6-65-4C-7A-A1-88-5F` (DES-ECB of `b"FELDTECH"` under key `E8 4A D6 60 C4 72 1A E0`) |
| Flag                              | `flag{FELDTECH_VNC}`                                        |

## Why `FELDTECH_VNC` and not `FELDTECH`?

TightVNC truncates passwords to 8 bytes at storage and at auth, so the
DES key derived from `FELDTECH_VNC` and `FELDTECH` is identical. The
canonical flag uses the *as-typed* value to match the wordlist entry
players will recover.

## Reproducing the pcap

```bash
# from repo root:
nix develop
./scripts/observability/vnc-public-attack.sh \
    --target 192.168.60.109 \
    --wordlist provisioning/wordlists/vnc-betterdefaultpasslist.txt
```

Live capture takes ~2 min (41 attempts paced with periodic
`tvnserver` service restarts to keep the in-memory blacklist clear).
The orchestrator chains: emulation → Arkime push → analyzer → validator
→ `INDEX.md`.

## Common player wrong-turns

1. **Hydra**: `hydra -P wordlist.txt vnc://target` produces non-standard
   probe responses (a leading "is this VNC?" packet with a garbage
   response) that won't decode to any wordlist entry. Tell players to
   use a pure RFB-3.8 client (or the included
   `scripts/observability/vnc-cred-tool.py`).
2. **The `vnc.auth_result == 0` filter trap**: see step 1 above. The
   dissector quirk makes the naïve filter return 41 matches. This is
   intentional teaching — assertion #3 of the validator goes out of
   its way to demonstrate the workaround.
3. **Decoding the registry-blob format**: `HKLM:\Software\TightVNC\Server\Password`
   is `DES_ECB_ENCRYPT(password_padded, key=E84AD660C4721AE0)`. This is
   a *different* operation from the auth-time chal/resp. Players who
   capture the blob from a memory dump need this distinction; the
   challenge can stop at the chal/resp recovery.
