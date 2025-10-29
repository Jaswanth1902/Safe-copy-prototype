param(
    [int]$Port = 5000,
    [string]$FlaskEntry = "server.py"   # adjust if you normally use a different entrypoint
)

Write-Host "`n== SafeCopy helper: start server + test /server-pub ==" -ForegroundColor Cyan

# 1) Show candidate IPv4 addresses (exclude loopback and link-local)
$ips = Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -ne "127.0.0.1" -and -not ($_.IPAddress.StartsWith("169.254")) } |
       Select-Object -ExpandProperty IPAddress -Unique

if (-not $ips) {
    Write-Warning "No non-loopback IPv4 addresses found. Check your network connection."
} else {
    Write-Host "`nDetected IPv4 addresses (use one for mobile):"
    $ips | ForEach-Object { Write-Host "  - $_" }
}

# 2) Start Flask server in a new PowerShell window so it remains visible
$cwd = Get-Location
Write-Host "`nStarting Flask dev server in a new PowerShell window (working dir: $cwd)..." -ForegroundColor Green

# Build command to run in new window. We use python -m flask run, setting FLASK_APP to $FlaskEntry.
$escapedCwd = $cwd.Path -replace "'", "''"
$runCommand = "Set-Location -LiteralPath '$escapedCwd'; " +
              "$env:FLASK_APP='$FlaskEntry'; " +
              "python -m flask run --host=0.0.0.0 --port $Port"

Start-Process powershell -ArgumentList "-NoExit", "-Command", $runCommand

# 3) Wait for server to initialize
Write-Host "Waiting 4 seconds for the server to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 4

# 4) Test /server-pub on each IP
Write-Host "`nTesting /server-pub on detected IPv4 addresses (http://<ip>:$Port/server-pub):" -ForegroundColor Cyan

foreach ($ip in $ips) {
    $url = "http://${ip}:$Port/server-pub"
    Write-Host "`nTesting $url" -ForegroundColor Gray
    try {
        $resp = Invoke-RestMethod -Method GET -Uri $url -UseBasicParsing -TimeoutSec 5
        Write-Host "SUCCESS for $ip — response (trimmed):"
        $respStr = $resp | ConvertTo-Json -Depth 4
        if ($respStr.Length -gt 800) { $respStr = $respStr.Substring(0,800) + "...(truncated)" }
        Write-Host $respStr
    } catch {
        Write-Warning "Failed to GET $url — $_"
    }
}

# 5) Also try localhost (useful if you run server locally)
$localUrl = "http://127.0.0.1:$Port/server-pub"
Write-Host "`nTesting $localUrl" -ForegroundColor Gray
try {
    $resp = Invoke-RestMethod -Method GET -Uri $localUrl -UseBasicParsing -TimeoutSec 5
    Write-Host "Local SUCCESS — response (trimmed):"
    $resp | ConvertTo-Json -Depth 4 | ForEach-Object {
        $s = $_
        if ($s.Length -gt 800) { $s = $s.Substring(0,800) + "...(truncated)" }
        Write-Host $s
    }
} catch {
    Write-Warning "Local GET failed: $_"
}

# 6) Show browser URL(s) for phone testing
Write-Host "`n== Browser/test URLs to open from your phone ==" -ForegroundColor Cyan
foreach ($ip in $ips) {
    Write-Host "  http://${ip}:$Port/server-pub"
    Write-Host "  http://${ip}:$Port/cache/<job-id>   (replace <job-id> with the printed job id after sending)"
}

# 7) Optional: firewall command (requires Admin). Print it and optionally run it.
$fwCmd = "New-NetFirewallRule -DisplayName 'Allow Python $Port' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port"
Write-Host "`nIf your phone cannot reach the PC, run this in an elevated PowerShell to allow TCP $Port through the Windows Firewall:"
Write-Host "  $fwCmd" -ForegroundColor Yellow

Write-Host "`nDone. If the endpoint test above failed, copy the server window output (the new PowerShell)"
