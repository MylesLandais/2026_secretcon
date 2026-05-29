# SecretCon 2026 - Win11 EWS Packer handoff (thin bootstrap)
# In-VM challenge state is converged by ansible/playbooks/ews.yml.
# Retains only build-time settings that must exist before Ansible connects.

$secretconLib = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Join-Path $_.Root "SecretCon.Bootstrap.psm1" } |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1
if (-not $secretconLib) {
    $secretconLib = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "lib\SecretCon.Bootstrap.psm1"
}
Import-Module $secretconLib -Force -ErrorAction Stop

Write-Host "[*] EWS thin bootstrap (Ansible converges challenge state)"

# Long Paths - required before some tooling paths during bake
Set-ItemProperty `
  -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
  -Name 'LongPathsEnabled' -Value 1

# OpenSSH must stay up for Packer SSH + Ansible
$sshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
if (-not $sshd) {
    throw "OpenSSH sshd service not found - autounattend must install OpenSSH"
}
if ($sshd.Status -ne 'Running') {
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
}
if ($sshd.StartType -ne 'Automatic') {
    Set-Service -Name sshd -StartupType Automatic
}

Write-Host "[*] Thin bootstrap complete - run ansible/playbooks/ews.yml next"
