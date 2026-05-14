$ErrorActionPreference = 'SilentlyContinue'
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1
if ($adapter) {
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress '192.168.60.109' -PrefixLength 24 -DefaultGateway '192.168.60.254'
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses '192.168.60.1','192.168.60.254'
}
