#!/usr/bin/env bash
# Suppress WU / Server Manager overlays on a running CysVuln (local QEMU or Proxmox).
#
# Usage:
#   ./scripts/hotfix-cysvuln-prompts.sh [host] [winrm_port]
#   ./scripts/hotfix-cysvuln-prompts.sh 127.0.0.1 15985

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-127.0.0.1}"
PORT="${2:-15985}"
ADMIN_PW="${SECRETCON_SHARED_LOCAL_ADMIN_PASSWORD:-PizzaMan123!}"

read -r -d '' PS <<'EOF' || true
$ErrorActionPreference = 'Continue'
$machineReg = @(
  @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU','NoAutoUpdate','REG_DWORD','1'),
  @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','DoNotConnectToWindowsUpdateInternetLocations','REG_DWORD','1'),
  @('HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate','SetDisableUXWUAccess','REG_DWORD','1'),
  @('HKLM\SOFTWARE\Microsoft\ServerManager','DoNotOpenServerManagerAtLogon','REG_DWORD','1'),
  @('HKCU\SOFTWARE\Microsoft\ServerManager','DoNotOpenServerManagerAtLogon','REG_DWORD','1')
)
foreach ($entry in $machineReg) {
  & reg.exe add $entry[0] /v $entry[1] /t $entry[2] /d $entry[3] /f | Out-Null
}
& reg.exe add 'HKCU\SOFTWARE\Microsoft\ServerManager\Roles' /v RefreshFrequency /t REG_SZ /d '00:00:00' /f | Out-Null
foreach ($svc in @('wuauserv','UsoSvc','WaaSMedicSvc')) {
  Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
  Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
}
Get-Process -Name 'ServerManager','MusNotification','MusNotificationUx' -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue
Write-Output 'prompt suppression applied'
EOF

echo "[*] Applying update/Server Manager suppression on ${HOST}:${PORT} via WinRM..."

nix develop "${REPO_ROOT}" -c ansible "${HOST}" \
    -i "${HOST}," \
    -e "ansible_port=${PORT}" \
    -e "ansible_user=Administrator" \
    -e "ansible_password=${ADMIN_PW}" \
    -e "ansible_connection=winrm" \
    -e "ansible_winrm_scheme=http" \
    -e "ansible_winrm_server_cert_validation=ignore" \
    -m ansible.windows.win_shell \
    -a "${PS}"

echo "[+] Done — use one console: ./scripts/open-local-vm-desktops.sh --cysvuln"
