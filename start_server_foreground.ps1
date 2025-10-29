param(
    [int]$Port = 5000,
    [switch]$InstallRequirements
)

Write-Host "`n== SafeCopy: start server (foreground) helper ==" -ForegroundColor Cyan

# show candidate IPv4 addresses
$ips = Get-NetIPAddress -AddressFamily IPv4 |
      Where-Object { $_.IPAddress -ne '127.0.0.1' -and -not ($_.IPAddress.StartsWith('169.254')) } |
      Select-Object -ExpandProperty IPAddress -Unique

if (-not $ips) {
    Write-Warning "No non-loopback IPv4 addresses found. Check your network connection."
} else {
    Write-Host "Detected IPv4 addresses (use one for mobile):"
    foreach ($ip in $ips) { Write-Host "  - $ip" }
}

if ($InstallRequirements) {
    Write-Host "`nInstalling Python requirements..." -ForegroundColor Yellow
    python -m pip install -r "server\requirements.txt"
}

Write-Host "`nOpen this URL from your phone's browser once the server is running:" -ForegroundColor Cyan
foreach ($ip in $ips) { Write-Host ("  http://" + $ip + ":" + $Port + "/server-pub") }

Write-Host "`nStarting server in foreground (ctrl+C to stop)..." -ForegroundColor Green
# Change to server directory and run server.py directly so the module is found
$serverDir = Join-Path (Get-Location) 'server'
if (Test-Path $serverDir) {
    Set-Location $serverDir
    Write-Host "Running: python server.py (working dir: $serverDir)" -ForegroundColor Green
    python server.py
} else {
    Write-Warning "Could not find 'server' directory; attempting to run server.py in current directory."
    python server.py
}
