$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Log($msg) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg)
}

function Wait-Port([int]$port, [string]$name, [int]$sec = 30) {
    for ($i = 0; $i -lt $sec; $i++) {
        try {
            $r = Invoke-WebRequest ("http://127.0.0.1:{0}/health" -f $port) -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -eq 200) { Log ("OK " + $name + " (" + $port + "): " + $r.Content); return $true }
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

Log '=== 1. 等 Docker daemon ==='
$daemonOk = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Log 'Docker daemon alive'; $daemonOk = $true; break }
    } catch {}
    if ($i -eq 0) { Log 'Docker daemon not ready — 请确认 Docker Desktop 已启动' }
    Start-Sleep -Seconds 2
}
if (-not $daemonOk) { Log 'FAIL: docker daemon 30s 内未上线'; Read-Host '回车退出'; exit 1 }

Log '=== 2. 起容器 hermes-week3-runner ==='
$exists = docker ps -a --filter name=hermes-week3-runner --format '{{.Names}}' 2>&1
if ($exists -eq 'hermes-week3-runner') {
    docker start hermes-week3-runner 2>&1 | Out-Null
} else {
    Log '首次启动，创建容器'
    docker run -d --name hermes-week3-runner --restart unless-stopped `
        -p 8642:8642 -p 8420:8420 hermes-week3:0.20.5 `
        sh -c 'echo starting; exec sleep infinity' 2>&1 | Out-Null
}
Start-Sleep -Seconds 3
$state = docker ps --filter name=hermes-week3-runner --format '{{.Names}} {{.Status}}'
Log ("容器: " + $state)

Log '=== 3. 装 aiohttp 到 hermes venv（如果没装）==='
$checkCmd = '/opt/hermes-agent/.venv/bin/python -c "import aiohttp; print(aiohttp.__version__)"'
$check = docker exec hermes-week3-runner bash -c $checkCmd 2>&1
if ($LASTEXITCODE -ne 0) {
    Log '补装 pip + aiohttp'
    docker exec hermes-week3-runner bash -c '/opt/hermes-agent/.venv/bin/python -m ensurepip --upgrade --default-pip' 2>&1 | Out-Null
    docker exec hermes-week3-runner bash -c '/opt/hermes-agent/.venv/bin/python -m pip install --quiet aiohttp' 2>&1 | Out-Null
} else {
    Log ("aiohttp OK: " + $check)
}

Log '=== 4. 清 stale 进程 + 启动 8642 hermes gateway ==='
$killCmd = 'for p in $(ls /proc/ 2>/dev/null | grep -E "^[0-9]+$"); do c=$(cat /proc/$p/comm 2>/dev/null); if echo "$c" | grep -iE "hermes|tsx" > /dev/null; then kill -9 $p 2>/dev/null; fi; done; rm -f /root/.hermes/gateway.pid /root/.hermes/gateway.lock'
docker exec hermes-week3-runner bash -c $killCmd 2>&1 | Out-Null
Start-Sleep -Seconds 1

$startCmd = 'export API_SERVER_HOST=0.0.0.0 API_SERVER_PORT=8642 API_SERVER_KEY=soak-test-key-2026-dongbowen-dbrh; nohup hermes gateway run > /tmp/gateway.log 2>&1 &'
docker exec -d hermes-week3-runner bash -c $startCmd 2>&1 | Out-Null

if (-not (Wait-Port 8642 'hermes gateway')) {
    Log 'FAIL: 8642 启动失败，看容器日志'
    docker logs --tail 30 hermes-week3-runner 2>&1 | Out-String | Write-Host
    Read-Host '回车退出'
    exit 1
}

Log '=== 5. 启动 8420 memory gateway ==='
Get-NetTCPConnection -LocalPort 8420 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

$env:MEMORY_TENCENTDB_GATEWAY_PORT = '8420'
$env:MEMORY_TENCENTDB_GATEWAY_HOST = '127.0.0.1'
$env:NODE_PATH = 'C:\Users\35348\.memory-tencentdb\tdai-memory-openclaw-plugin\node_modules'

$nodeExe = 'C:\Users\35348\.workbuddy\binaries\node\versions\22.22.2-2\node.exe'
$proc = Start-Process -FilePath $nodeExe `
    -ArgumentList @('--import','tsx','C:\Users\35348\.memory-tencentdb\tdai-memory-openclaw-plugin\src\gateway\server.ts') `
    -WorkingDirectory 'C:\Users\35348\.memory-tencentdb\tdai-memory-openclaw-plugin' `
    -RedirectStandardOutput 'C:\Users\35348\AppData\Local\Temp\mem-gw-out.log' `
    -RedirectStandardError  'C:\Users\35348\AppData\Local\Temp\mem-gw-err.log' `
    -WindowStyle Hidden -PassThru
Log ("memory gateway PID=" + $proc.Id)

if (-not (Wait-Port 8420 'memory gateway')) {
    Log 'FAIL: 8420 启动失败，看 stderr 日志'
    if (Test-Path 'C:\Users\35348\AppData\Local\Temp\mem-gw-err.log') {
        Get-Content 'C:\Users\35348\AppData\Local\Temp\mem-gw-err.log' -Tail 20 -ErrorAction SilentlyContinue | Write-Host
    }
    Read-Host '回车退出'
    exit 1
}

Log ''
Log '=========================================='
Log 'OK: 全部 ready'
Log '   http://127.0.0.1:8642/health  (hermes gateway)'
Log '   http://127.0.0.1:8420/health  (memory gateway)'
Log '=========================================='
Log '重要: 必须保持这个 PowerShell 窗口开着 — gateway 进程依附于此 session'
Log '回车会退出当前进程组（gateway 仍会以独立进程继续运行）'
Read-Host '回车退出'
