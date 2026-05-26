#!/usr/bin/env python3
"""Run GetNPUsers with optional non-default KDC port (QEMU host forward)."""
from __future__ import annotations

import os
import runpy
import shutil
import sys

import impacket.krb5.kerberosv5 as kv5

kdc_port = int(os.environ.get("ASREP_KDC_PORT", "88"))
if kdc_port != 88:
    _orig = kv5.sendReceive

    def _send_receive(data, host, kdc_host, port=kdc_port):
        return _orig(data, host, kdc_host, port=port)

    kv5.sendReceive = _send_receive

getnpusers = shutil.which("GetNPUsers.py")
if not getnpusers:
    sys.stderr.write("GetNPUsers.py not found — run: nix develop .#kali\n")
    sys.exit(2)

wrapped = os.path.join(os.path.dirname(getnpusers), ".GetNPUsers.py-wrapped")
if not os.path.isfile(wrapped):
    sys.stderr.write(f"missing impacket wrapper: {wrapped}\n")
    sys.exit(2)

runpy.run_path(wrapped, run_name="__main__")
