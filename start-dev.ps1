# Starts the API and the Flutter web app in separate windows.
#   powershell -ExecutionPolicy Bypass -File .\start-dev.ps1

$root = $PSScriptRoot

Write-Host "Starting FastAPI on http://127.0.0.1:8000 ..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList @(
    '-NoExit', '-Command',
    "Set-Location '$root\api'; & '$root\.venv\Scripts\python.exe' -m uvicorn app.main:app --reload --host 127.0.0.1 --port 8000"
)

Start-Sleep -Seconds 3

Write-Host "Starting Flutter web on http://127.0.0.1:5000 ..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList @(
    '-NoExit', '-Command',
    "Set-Location '$root\app'; & C:\dev\flutter\bin\flutter.bat run -d chrome --web-port 5000"
)

Write-Host ""
Write-Host "  App      http://127.0.0.1:5000" -ForegroundColor Green
Write-Host "  API docs http://127.0.0.1:8000/docs" -ForegroundColor Green
Write-Host ""
Write-Host "  Logins (password Demo@12345):" -ForegroundColor Yellow
Write-Host "    admin@school.test          -> Admin Dashboard"
Write-Host "    ishaan.reddy@school.test   -> Teacher Portal"
