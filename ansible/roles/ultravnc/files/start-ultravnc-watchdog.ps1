# Keep UltraVNC listening on TCP/5900 (winvnc -run in application mode).
$ErrorActionPreference = 'SilentlyContinue'
$exe = 'C:\Program Files\uvnc bvba\UltraVNC\winvnc.exe'
while ($true) {
    $listening = Get-NetTCPConnection -LocalPort 5900 -State Listen -ErrorAction SilentlyContinue
    if (-not $listening) {
        Get-Process winvnc -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1
        Start-Process -FilePath $exe -ArgumentList '-run'
    }
    Start-Sleep -Seconds 15
}
