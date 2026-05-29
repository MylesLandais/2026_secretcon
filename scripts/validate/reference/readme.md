# Reference exploit scripts

Upstream proof-of-concept copies for the CysVuln EFS challenge. Prefer the
maintainer validation tools in `scripts/validate/` for automated checks.

## Purpose

Document public exploit-db sources and provide optional manual reproduction.
These are not invoked by Packer or verify scripts.

## edb-37951-efs69-userid-bof.py

- Source: Exploit-DB 37951 (EFS Web Server 6.9 USERID buffer overflow)
- Use: manual HTTP foothold testing against a running challenge VM
- Automated alternative: `scripts/validate/check_efs69_response.py`

## edb-42256-efs-ftp72-msf.rb

- Source: [Exploit-DB 42256](https://www.exploit-db.com/exploits/42256) — Easy File Sharing **HTTP** Server 7.2 POST buffer overflow (`POST /sendemail.ghp`). The Metasploit description text says “FTP Server”; ignore that — the module targets HTTP/80.
- Use: player-facing hint (seeded in `Notes.txt`) and optional manual MSF reproduction
- Automated validation uses **EDB-37951** USERID cookie overflow on the **pinned 6.9** installer (`check_efs69_response.py`); gadget overlap is documented in `scripts/validate/request_builder/rop.py`

## Validate

Run from repo root inside `nix develop`:

```
python3 scripts/validate/check_efs69_response.py --help
./scripts/verify-cysvuln.sh <target-ip>
```

## Cleanup

No artifacts written by these reference files. Edit host/port in the Python
script before manual use.
