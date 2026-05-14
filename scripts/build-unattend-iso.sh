#!/usr/bin/env bash
# Repack the Windows 11 install ISO with autounattend.xml at its root.
# This is required for Win11 24H2's modern setup wizard, which only reads
# autounattend when present on the install media itself (not on a separate
# CD/floppy). The output ISO preserves UEFI boot.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ISO="${SRC_ISO:-$HOME/Downloads/26100.1742.240906-0331.ge_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso}"
AUTOUNATTEND_XML="${AUTOUNATTEND_XML:-$REPO_ROOT/provisioning/autounattend.xml}"
OUT_ISO="${OUT_ISO:-$HOME/Downloads/win11-ltsc-24h2-unattended.iso}"
STAGE="${STAGE:-/tmp/win11-iso-stage}"

[ -f "$SRC_ISO" ] || { echo "missing source ISO: $SRC_ISO" >&2; exit 1; }
[ -f "$AUTOUNATTEND_XML" ] || { echo "missing autounattend.xml: $AUTOUNATTEND_XML" >&2; exit 1; }

echo "[*] staging at $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "[*] extracting $SRC_ISO (UDF; using 7z)"
nix-shell -p p7zip --run "7z x -y -o'$STAGE' '$SRC_ISO'" >/dev/null 2>&1
chmod -R u+w "$STAGE"

echo "[*] copying autounattend.xml to ISO root"
cp "$AUTOUNATTEND_XML" "$STAGE/autounattend.xml"

# 7z extracts a synthetic [BOOT] dir containing the El Torito boot images;
# we want the real on-disk paths, not those.
rm -rf "$STAGE/[BOOT]"

echo "[*] injecting autounattend.xml into boot.wim (WinPE images 1 and 2)"
# 24H2 modern setup only reads autounattend from X:\ (WinPE root), so it must
# live inside boot.wim. Image 2 (Setup) is the booted one; image 1 (WinPE)
# is included for safety / Shift+F10 contexts.
WIM_CMDS="$STAGE/wim-update-cmds.txt"
printf 'add %s /autounattend.xml\n' "$AUTOUNATTEND_XML" > "$WIM_CMDS"
nix-shell -p wimlib --run "wimupdate '$STAGE/sources/boot.wim' 1 < '$WIM_CMDS'" 2>&1 | tail -3
nix-shell -p wimlib --run "wimupdate '$STAGE/sources/boot.wim' 2 < '$WIM_CMDS'" 2>&1 | tail -3
rm -f "$WIM_CMDS"

echo "[*] injecting OEM-style WinPE installer (startnet.cmd + diskpart.txt) into boot.wim image 2"
# 24H2 LTSC's setup.exe is just a UWP wizard launcher — /unattend: is ignored
# (Attempt 6 in ~/Vault/2026-04-30-win11-24h2-autounattend-blocker.md).
# Instead, we bypass setup entirely: WinPE's startnet.cmd runs diskpart +
# dism + bcdboot directly (the OEM/factory pattern). autounattend.xml is
# staged into C:\Windows\Panther\unattend.xml so specialize + oobeSystem
# passes execute on first boot.
STARTNET_SRC="$REPO_ROOT/provisioning/winpe-startnet.cmd"
DISKPART_SRC="$REPO_ROOT/provisioning/winpe-diskpart.txt"
PROBE_SRC="$REPO_ROOT/provisioning/winpe-probe.txt"
[ -f "$STARTNET_SRC" ] || { echo "missing $STARTNET_SRC" >&2; exit 1; }
[ -f "$DISKPART_SRC" ] || { echo "missing $DISKPART_SRC" >&2; exit 1; }
[ -f "$PROBE_SRC" ] || { echo "missing $PROBE_SRC" >&2; exit 1; }

# Convert LF -> CRLF for Windows; place into staging.
STARTNET_STAGED="$STAGE/startnet.cmd"
DISKPART_STAGED="$STAGE/diskpart.txt"
PROBE_STAGED="$STAGE/probe.txt"
sed 's/$/\r/' "$STARTNET_SRC" > "$STARTNET_STAGED"
sed 's/$/\r/' "$DISKPART_SRC" > "$DISKPART_STAGED"
sed 's/$/\r/' "$PROBE_SRC" > "$PROBE_STAGED"

# winpeshl.exe defaults to launching setup.exe (the UWP wizard) when no
# winpeshl.ini is present. We add one that explicitly runs cmd /c startnet.cmd
# so our OEM install script actually executes.
WINPESHL_STAGED="$STAGE/winpeshl.ini"
printf '[LaunchApps]\r\n%%SYSTEMROOT%%\\System32\\cmd.exe, "/c X:\\Windows\\System32\\startnet.cmd"\r\n' > "$WINPESHL_STAGED"

WIM_CMDS="$STAGE/wim-oem-cmds.txt"
{
    printf 'delete --force /Windows/System32/startnet.cmd\n'
    printf 'add %s /Windows/System32/startnet.cmd\n' "$STARTNET_STAGED"
    printf 'add %s /diskpart.txt\n' "$DISKPART_STAGED"
    printf 'add %s /probe.txt\n' "$PROBE_STAGED"
    printf 'add %s /Windows/System32/winpeshl.ini\n' "$WINPESHL_STAGED"
} > "$WIM_CMDS"
nix-shell -p wimlib --run "wimupdate '$STAGE/sources/boot.wim' 2 < '$WIM_CMDS'" 2>&1 | tail -5
rm -f "$WIM_CMDS" "$STARTNET_STAGED" "$DISKPART_STAGED" "$PROBE_STAGED" "$WINPESHL_STAGED"

echo "[*] repacking to $OUT_ISO (UEFI boot preserved, no-prompt)"
nix-shell -p libisoburn --run "xorriso -as mkisofs \
    -iso-level 4 -J -joliet-long -rational-rock \
    -V 'CESE_X64FREE_EN-US_DV9' \
    -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -hide boot.catalog \
    -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys_noprompt.bin -no-emul-boot \
    -o '$OUT_ISO' '$STAGE'" 2>&1 | tail -10

echo "[*] result: $(ls -lh "$OUT_ISO")"
