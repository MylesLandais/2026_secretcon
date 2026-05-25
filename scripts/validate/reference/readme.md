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

- Source: Metasploit module for EFS FTP Server 7.2 (different product line)
- Use: reference only; the 2026 chain targets EFS Web Server 6.9 on HTTP/80
- Not part of the default validation path

## Validate

Run from repo root inside `nix develop`:

```
python3 scripts/validate/check_efs69_response.py --help
./scripts/verify-cysvuln.sh <target-ip>
```

## Cleanup

No artifacts written by these reference files. Edit host/port in the Python
script before manual use.
