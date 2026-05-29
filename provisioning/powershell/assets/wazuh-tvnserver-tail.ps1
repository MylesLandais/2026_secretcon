# Wazuh agent <command> localfile helper for TightVNC's tvnserver.log.
#
# Why this exists: TightVNC opens its log with FILE_SHARE_NONE, so the
# Wazuh agent's libc fopen("rb", ...) loses the share-mode race and
# never tails the file. .NET FileStream lets us request FILE_SHARE_RW
# explicitly. This script reads new bytes since its last invocation,
# writes the new offset to a state file, and prints each new line to
# stdout. Wazuh's <log_format>command</log_format> picks those lines
# off stdout and feeds them through the rule pipeline like any other
# log source.
#
# See docs/notes/vnc-tvnserver-log-share-violation-2026-05-26.md for
# the full diagnosis. Paired with:
#   - bootstrap_win.ps1                  (stages this file)
#   - .../shared/ews/agent.conf          (<command> localfile entry)
#   - .../local_rules.xml id=100801      (<location> regex matches alias)

[CmdletBinding()]
param(
    [string]$Source    = 'C:\ProgramData\TightVNC\tvnserver.log',
    [string]$StateDir  = 'C:\ProgramData\WazuhTail',
    [string]$StateName = 'tvnserver.pos',
    [int]   $MaxLines  = 5000
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Force ASCII stdout. PowerShell's default OutputEncoding when stdout is
# redirected (which is exactly how Wazuh invokes us via cmd.exe /c
# powershell.exe -File) is UTF-16 LE. The Wazuh agent's command-localfile
# reader treats stdout as 8-bit text and the embedded NUL bytes terminate
# every emitted line at the first character — so each line arrives at the
# manager as `ossec: output: 'tvnserver-tail': ` with an empty body. The
# OEM/console codepage on a default Windows install is CP-437; ASCII is a
# safe subset for tvnserver.log's ASCII-only content.
[Console]::OutputEncoding = [System.Text.Encoding]::ASCII
$OutputEncoding           = [System.Text.Encoding]::ASCII

if (-not (Test-Path -LiteralPath $StateDir)) {
    [void](New-Item -ItemType Directory -Path $StateDir -Force)
}
$posFile = Join-Path $StateDir $StateName

if (-not (Test-Path -LiteralPath $Source)) {
    return
}

# Open with FileShare.ReadWrite|Delete so we coexist with TightVNC's
# exclusive write handle. Without this the open fails with a sharing
# violation (verified on 2026-05-26 against TightVNC 2.8.87).
$share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
$stream = [System.IO.File]::Open(
    $Source,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    $share
)

try {
    $size = $stream.Length

    [long]$pos = 0
    if (Test-Path -LiteralPath $posFile) {
        $raw = (Get-Content -LiteralPath $posFile -Raw -ErrorAction SilentlyContinue)
        if ($raw) {
            [void][long]::TryParse($raw.Trim(), [ref]$pos)
        }
    }

    # Rotation guard: if the file shrank (rotated) replay from byte 0.
    if ($pos -gt $size) { $pos = 0 }
    if ($pos -eq $size) {
        # Nothing new since last invocation.
        return
    }

    [void]$stream.Seek($pos, [System.IO.SeekOrigin]::Begin)
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true, 4096, $true)

    $emitted = 0
    while (-not $reader.EndOfStream -and $emitted -lt $MaxLines) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { break }
        if ($line.Length -eq 0) { continue }
        Write-Output $line
        $emitted++
    }

    $newPos = $stream.Position
    $reader.Close()
    Set-Content -LiteralPath $posFile -Value "$newPos" -Encoding ASCII -NoNewline
}
finally {
    $stream.Close()
}
