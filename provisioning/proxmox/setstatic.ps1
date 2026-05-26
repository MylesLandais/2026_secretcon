$ErrorActionPreference = 'SilentlyContinue'

# Configurable IPv4 binding for the Packer build window. Reads the
# config from `proxmox-static-ip.txt` on the same PROVISION CD this
# script was launched from (autounattend.xml hunts D..K for setstatic.ps1
# and executes it from whichever drive it found).
#
# Format of proxmox-static-ip.txt (single line):
#   IPv4|PrefixLen|Gateway|Dns1[,Dns2,...]   -- static bind
#   DHCP                                     -- leave the adapter on DHCP
#                                               (deploy-cysvuln.sh discovers
#                                               the assigned address via
#                                               the Proxmox bridge ARP cache)
#
# If the file is missing or unparseable we fall back to the historical
# hardcoded 192.168.60.109 binding so older VMID 108-style builds keep
# working unchanged.
#
# Adapter-status quirk: at autounattend's `specialize` pass on a
# memory-constrained VM the e1000 NIC can still be `Status=Disconnected`,
# which made the original Get-NetAdapter | Where Status -eq Up call
# return $null and silently skip the bind. We now poll for up to ~60s.

$defaultIp        = '192.168.60.109'
$defaultPrefix    = 24
$defaultGateway   = '192.168.60.254'
$defaultDns       = @('192.168.60.1','192.168.60.254')

$mode    = 'static'
$ip      = $defaultIp
$prefix  = $defaultPrefix
$gateway = $defaultGateway
$dns     = $defaultDns

$cfg = $null
foreach ($drive in 'D','E','F','G','H','I','J','K') {
    $candidate = "${drive}:\proxmox-static-ip.txt"
    if (Test-Path $candidate) {
        $cfg = $candidate
        break
    }
}

if ($cfg) {
    try {
        $line = (Get-Content $cfg -ErrorAction Stop | Where-Object {
            $_ -and -not $_.StartsWith('#')
        } | Select-Object -First 1).Trim()
        if ($line) {
            if ($line -match '^(?i)DHCP$') {
                $mode = 'dhcp'
            } else {
                $parts = $line.Split('|')
                if ($parts.Length -ge 4) {
                    $ip      = $parts[0].Trim()
                    $prefix  = [int]($parts[1].Trim())
                    $gateway = $parts[2].Trim()
                    $dns     = $parts[3].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                }
            }
        }
    } catch {
        Write-Host "[setstatic] could not parse $cfg, falling back to defaults: $($_.Exception.Message)"
    }
}

# Wait for the first physical-ish adapter to negotiate link. Get-NetAdapter
# returns disconnected adapters too; filter on Status=Up before binding.
$adapter = $null
for ($i = 0; $i -lt 30; $i++) {
    $adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' } |
        Sort-Object ifIndex |
        Select-Object -First 1
    if ($adapter) { break }
    Start-Sleep -Seconds 2
}

if (-not $adapter) {
    Write-Host "[setstatic] no Up adapter after 60s; falling back to first adapter regardless of status"
    $adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Sort-Object ifIndex |
        Select-Object -First 1
}

if (-not $adapter) {
    Write-Host "[setstatic] no physical adapter visible at all; aborting"
    exit
}

if ($mode -eq 'dhcp') {
    Write-Host "[setstatic] DHCP mode: ensuring ifIndex $($adapter.ifIndex) is on DHCP for v4 + DNS"
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
} else {
    Write-Host "[setstatic] STATIC mode: binding $ip/$prefix gw=$gateway dns=$($dns -join ',') on ifIndex $($adapter.ifIndex)"
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gateway -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dns
}
