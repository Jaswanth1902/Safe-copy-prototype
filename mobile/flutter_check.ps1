Write-Host "Running Flutter devices check..." -ForegroundColor Cyan
Push-Location
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path)

try {
    flutter devices
} catch {
    Write-Warning "Failed to run 'flutter devices'. Ensure Flutter is installed and on PATH.";
    Pop-Location
    exit 1
}

Write-Host "\nIf a device is listed, run the app using (replace <deviceId> with the id from flutter devices):" -ForegroundColor Green
Write-Host "  flutter run -d <deviceId>"

Write-Host "\nIf you want to run on the default connected device, run:" -ForegroundColor Green
Write-Host "  flutter run"

Pop-Location
