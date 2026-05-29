# Challenge: VNC PCAP Forensics

**Category:** Forensics / Network
**Difficulty:** easy/medium
**Author:** SecretCon 2026

## Scenario

Your network sensor caught a brute-force attack against a public-facing
TightVNC server on TCP `5900`. Forty-one back-to-back authentication
attempts came in from a single source over ~2 minutes; one of them
succeeded.

You have:

- [`vnc_auth.pcap`](vnc_auth.pcap) — the raw capture (69 KB, 873 packets).
- [`wordlist.txt`](wordlist.txt) — the attacker's wordlist (the SecLists
  `vnc-betterdefaultpasslist.txt`, 41 entries).

Operators publishing the same bundle as a GitHub Release asset should use
[`docs/runbooks/ews-vnc-pcap-release.md`](../../docs/runbooks/ews-vnc-pcap-release.md).

Recover the password the attacker used to log in. Wrap it in
`flag{...}`.

## Background

The Remote Framebuffer (RFB / VNC) authentication exchange on protocol
`3.8` is:

1. Server sends `RFB 003.008\n` and a list of security types.
2. Client picks `VNC Authentication` (type `2`).
3. Server sends a 16-byte random challenge.
4. Client encrypts the challenge with a DES key derived from the
   password (bit-reversed, NULL-padded to 8 bytes — only the first 8
   characters of the password are used) and sends the 16-byte response.
5. Server replies with a 4-byte `SecurityResult` (`0` = ok,
   `1` = failed, `2` = too many tries).

Because steps 3-4 are a chosen-plaintext exchange — the same DES
algorithm used live for auth can be inverted offline against a wordlist —
RFB auth captured on the wire is recoverable when the password is weak.

## What good looks like

Your write-up should describe:

1. How you identified the one TCP stream that succeeded.
2. The 16-byte challenge and 16-byte response from that stream.
3. The cracking method (algorithm, key derivation, wordlist).
4. The recovered password and its wrapped flag.

## Hints

<details><summary>Hint 1 — finding the success</summary>

In Wireshark, filter for `vnc.auth_result == 0`. Be aware of a TightVNC
quirk: failed sessions also send a reason-string after the
`SecurityResult` byte, and Wireshark's dissector re-parses parts of that
string as additional `vnc.auth_result` frames. The *first*
`vnc.auth_result` frame in each TCP stream is the canonical server
reply; use `tcp.stream` to group.

Alternative: filter for streams where the connection stayed open after
the server's `Authentication result` (success keeps the socket alive;
failure FIN-ACKs immediately).

</details>

<details><summary>Hint 2 — extracting the chal/resp pair</summary>

```bash
tshark -r vnc_auth.pcap -Y vnc \
  -T fields -e tcp.stream -e vnc.auth_challenge -e vnc.auth_response \
  -e vnc.auth_result
```

</details>

<details><summary>Hint 3 — cracking the response</summary>

Any RFB-aware cracker works. Two reference implementations:

- `vncpwd` (C, from the TightVNC source tree).
- `vncpasswd.py` (Python, single file — search PyPI / GitHub).
- The repo ships [`scripts/observability/vnc-cred-tool.py`](../../scripts/observability/vnc-cred-tool.py)
  with a `crack` subcommand:

  ```bash
  nix develop --command python3 scripts/observability/vnc-cred-tool.py crack \
      --challenge <16-byte-hex> --response <16-byte-hex> \
      --wordlist  targets/ews-vnc-pcap-forensics/wordlist.txt
  ```

The algorithm to implement yourself (~30 lines):

1. Pad/truncate the password to 8 bytes.
2. Bit-reverse each byte (RealVNC quirk inherited from a 1990s
   typo).
3. Use the result as a single-DES key in ECB mode.
4. Encrypt the two 8-byte halves of the challenge.
5. Compare to the captured response.

</details>

## Files

| File          | Purpose                              | Size  |
|---------------|--------------------------------------|-------|
| `vnc_auth.pcap` | Forty-one RFB authentication attempts (one success). | 69 KB |
| `wordlist.txt`  | The attacker's dictionary (SecLists `vnc-betterdefaultpasslist.txt`). | 330 B |

## Notes for instructors

Instructor walkthrough and the flag are in
[`solution.md`](solution.md) — keep that file out of the player
download. The pcap was generated against the live SecretCon 2026 EWS
lab (Win10 LTSC + TightVNC `2.8.87`); reproduce with
[`scripts/observability/vnc-public-attack.sh`](../../scripts/observability/vnc-public-attack.sh).
