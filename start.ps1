# PowerShell helper script to compile and run the Load Balancer
Write-Host "Creating ebin directory..." -ForegroundColor Cyan
if (!(Test-Path -Path "ebin")) {
    New-Item -ItemType Directory -Path "ebin" | Out-Null
}

Write-Host "Compiling Erlang modules..." -ForegroundColor Cyan
erlc -o ebin src/*.erl

if ($LASTEXITCODE -ne 0) {
    Write-Host "Compilation failed. Ensure Erlang (erl, erlc) is installed and added to your PATH." -ForegroundColor Red
    exit 1
}

# Copy app resource file
Copy-Item "src/load_balancer.app.src" "ebin/load_balancer.app" -Force

Write-Host "Starting Erlang Load Balancer..." -ForegroundColor Green
Write-Host "Listening on: http://localhost:8080" -ForegroundColor Yellow
Write-Host "Rate limit: 10 requests / minute (1 req / 6000ms)" -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop." -ForegroundColor White

erl -pa ebin -config config/sys -s lb_app start

