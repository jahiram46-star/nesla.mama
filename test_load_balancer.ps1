# PowerShell test script to verify Rate-Pacing and Backend Dispatching
$baseUrl = "http://localhost:8080"

Write-Host "=== 1. Checking Load Balancer Health & Backends ===" -ForegroundColor Cyan
try {
    $health = Invoke-RestMethod -Uri "$baseUrl/health" -Method Get
    $health | ConvertTo-Json -Depth 5
} catch {
    Write-Host "Could not connect to Load Balancer at $baseUrl. Ensure it is running!" -ForegroundColor Red
    exit 1
}

Write-Host "`n=== 2. Sending 5 Rapid Requests to Test Line-by-Line Queue Pacing ===" -ForegroundColor Cyan
Write-Host "Rate limit is 10 requests / 1 minute (1 dispatch every 6 seconds)." -ForegroundColor Yellow
Write-Host "Notice how requests wait in queue and are dispatched line-by-line!`n" -ForegroundColor Yellow

1..5 | ForEach-Object {
    $id = $_
    $timeStart = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$timeStart] Sending Request #$id..." -ForegroundColor Green
    
    $job = Start-Job -ScriptBlock {
        param($url, $id)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-WebRequest -Uri "$url/get?test_id=$id" -Method Get -TimeoutSec 70
            $sw.Stop()
            [PSCustomObject]@{
                RequestId = $id
                StatusCode = $resp.StatusCode
                Backend = $resp.Headers["X-Served-By-Backend"]
                BackendType = $resp.Headers["X-Backend-Type"]
                ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            }
        } catch {
            [PSCustomObject]@{
                RequestId = $id
                Error = $_.Exception.Message
            }
        }
    } -ArgumentList $baseUrl, $id
}

Write-Host "Waiting for queue to process and responses to return..." -ForegroundColor Cyan
Get-Job | Wait-Job | Receive-Job | Format-Table -AutoSize
Get-Job | Remove-Job

Write-Host "`n=== 3. Final Health & Queue Statistics ===" -ForegroundColor Cyan
Invoke-RestMethod -Uri "$baseUrl/health" -Method Get | ConvertTo-Json -Depth 5

