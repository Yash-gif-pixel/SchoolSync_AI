# Build the Flutter app in RELEASE and serve it on :5000.
#
# Use this for demos and for anything where the UI feels slow. `flutter run`
# builds in debug via DDC, which loads ~930 separate scripts and runs the
# whole app unoptimised — on Flutter web that is 5-10x slower than release and
# shows up most obviously as laggy scrolling.
#
# Debug is still the right mode while writing code (hot reload). Release is
# the right mode whenever someone is going to look at it.
#
#   powershell -ExecutionPolicy Bypass -File .\serve-release.ps1

$root = $PSScriptRoot

Write-Host "Stopping anything on :5000 ..." -ForegroundColor Cyan
$pids = (Get-NetTCPConnection -State Listen -LocalPort 5000 -ErrorAction SilentlyContinue).OwningProcess |
    Select-Object -Unique
foreach ($p in $pids) { try { Stop-Process -Id $p -Force } catch {} }
Get-Process -Name dart -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Host "Building release (about 35s) ..." -ForegroundColor Cyan
Push-Location "$root\app"
& C:\dev\flutter\bin\flutter.bat build web --release
$ok = $LASTEXITCODE -eq 0
Pop-Location

if (-not $ok) {
    Write-Host "Build failed." -ForegroundColor Red
    exit 1
}

Write-Host "Serving build\web on http://127.0.0.1:5000 ..." -ForegroundColor Cyan
Start-Process -FilePath "$root\.venv\Scripts\python.exe" `
    -ArgumentList "$root\serve_nocache.py", "5000", "$root\app\build\web" `
    -WindowStyle Hidden

Start-Sleep -Seconds 2
Write-Host ""
Write-Host "  App      http://127.0.0.1:5000" -ForegroundColor Green
Write-Host "  API docs http://127.0.0.1:8000/docs" -ForegroundColor Green
Write-Host ""
Write-Host "  Logins (password Demo@12345):" -ForegroundColor Yellow
Write-Host "    admin@school.test     -> Admin Dashboard"
Write-Host "    hod@school.test       -> Teacher Portal, can approve leave"
Write-Host "    teacher@school.test   -> Teacher Portal"
Write-Host ""
Write-Host "  Note: this serves a fixed build. Re-run this script after code changes." -ForegroundColor DarkGray
