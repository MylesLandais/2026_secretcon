$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\setup-openssh.log'
Start-Transcript -Path $log -Force

$src = (Get-Volume | Where-Object FileSystemLabel -eq 'PROVISION' | Select-Object -First 1).DriveLetter
if (-not $src) {
  $src = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path "$($_.Root)setup-openssh.ps1" } | Select-Object -First 1).Name
}
if (-not $src) { throw "PROVISION media not found" }
$root = "${src}:\"
Write-Host "[setup-openssh] using provisioning media at $root"

$zip = Join-Path $root 'OpenSSH-Win64.zip'
$dst = 'C:\Program Files\OpenSSH'
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
Expand-Archive -Path $zip -DestinationPath 'C:\Program Files' -Force
Rename-Item 'C:\Program Files\OpenSSH-Win64' $dst

& powershell -NoProfile -ExecutionPolicy Bypass -File "$dst\install-sshd.ps1"

if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH SSH Server' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

$key = (Get-Content (Join-Path $root 'packer_ed25519.pub') -Raw).Trim()
$akf = 'C:\ProgramData\ssh\administrators_authorized_keys'
New-Item -ItemType Directory -Force -Path 'C:\ProgramData\ssh' | Out-Null
Set-Content -Path $akf -Value $key -Encoding ASCII
icacls $akf /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'

New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
  -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
  -PropertyType String -Force | Out-Null

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

Write-Host "[setup-openssh] done"
Stop-Transcript
