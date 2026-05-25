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

$CysvulnDir = Join-Path $RepoRoot "infrastructure\packer\cysvuln"
$manifests = @(
    (Join-Path $CysvulnDir "provision-manifest-cysvuln.txt"),
    (Join-Path $CysvulnDir "provision-manifest-shared.txt")
)

# Same semantics as scripts/lib/read-provision-manifest.sh (bash) used by build-provision-iso.sh.
function Read-ManifestLines {
    param([string]$Path)
    Get-Content $Path | ForEach-Object {
        $line = ($_ -split '#', 2)[0].Trim()
        if ($line) { $line }
    }
}

$stage = Join-Path $env:TEMP ("provision-stage-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    foreach ($manifest in $manifests) {
        foreach ($rel in (Read-ManifestLines $manifest)) {
            $src = Join-Path $RepoRoot ($rel -replace '/', '\')
            if (-not (Test-Path $src)) { throw "Missing: $src" }
            Copy-Item $src -Destination $stage
        }
    }

    & $Oscdimg -lPROVISION -j1 -m $stage $Out
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed: $LASTEXITCODE" }
    Write-Host "[*] $Out"
}
finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
