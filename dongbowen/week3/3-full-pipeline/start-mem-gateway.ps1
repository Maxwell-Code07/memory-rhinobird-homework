$ErrorActionPreference = 'Continue'
$env:MEMORY_TENCENTDB_GATEWAY_PORT = '8420'
$env:MEMORY_TENCENTDB_GATEWAY_HOST = '127.0.0.1'
$env:NODE_PATH = 'C:\Users\35348\.memory-tencentdb\tdai-memory-openclaw-plugin\node_modules'

Get-NetTCPConnection -LocalPort 8420 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$nodeExe = 'C:\Users\35348\.workbuddy\binaries\node\versions\22.22.2-2\node.exe'
$args    = '--import tsx C:\Users\35348\.memory-tencentdb\tdai-memory-openclaw-plugin\src\gateway\server.ts'

$proc = Start-Process -FilePath $nodeExe -ArgumentList $args -WorkingDirectory 'C:\Users\35348\.memory-tencentdb\tdai-memory-openclaw-plugin' -WindowStyle Hidden -PassThru
Write-Host ('memory gateway PID=' + $proc.Id)

$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:8420/health' -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { Write-Host ('8420 OK: ' + $r.Content); $ready = $true; break }
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $ready) { Write-Host 'FAIL: 8420 not ready in 30s' }
exit 0
