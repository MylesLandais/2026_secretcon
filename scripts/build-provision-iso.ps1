# Build the PROVISION ISO for the Hyper-V cysvuln Packer build.
# Uses oscdimg.exe from the Windows ADK (Deployment Tools).
#
# Default oscdimg path matches Windows ADK 10:
#   C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe

[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$Out      = "",
    [string]$Oscdimg  = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
)

$ErrorActionPreference = "Stop"

if (-not $Out) {
    $Out = Join-Path $RepoRoot "infrastructure\packer\cysvuln\provision.iso"
}

if (-not (Test-Path $Oscdimg)) {
    throw "oscdimg.exe not found at $Oscdimg. Install Windows ADK Deployment Tools, or pass -Oscdimg <path>."
}

$stage = Join-Path $env:TEMP ("provision-stage-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    $files = @(
        "provisioning\cysvuln\autounattend.xml",
        "provisioning\openssh\setup-openssh.ps1",
        "provisioning\openssh\OpenSSH-Win64.zip",
        "provisioning\ssh\packer_ed25519.pub",
        "infrastructure\artifacts\cysvuln\60f3ff1f3cd34dec80fba130ea481f31-efssetup.exe",
        "infrastructure\artifacts\cysvuln\joe-notes.txt",
        "infrastructure\artifacts\cysvuln\admin-notes.txt",
        "infrastructure\artifacts\cysvuln\option.ini"
    )

    foreach ($rel in $files) {
        $src = Join-Path $RepoRoot $rel
        if (-not (Test-Path $src)) { throw "Missing: $src" }
        Copy-Item $src -Destination $stage
    }

    & $Oscdimg -lPROVISION -j1 -m $stage $Out
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed: $LASTEXITCODE" }
    Write-Host "[*] $Out"
}
finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
