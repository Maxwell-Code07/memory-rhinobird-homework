<#
pipeline.ps1 — 第三周进阶2：一键流水线
   build → run → 装记忆插件 → 起 gateway → 跑事实剧本 → 验证 L0-L3

参数（默认值参数）：
   -HermesVersion  0.20.5
   -Rounds         30
   -SkipBuild      $false   （本地镜像已存在时跳过 docker build）
   -KeepContainer  $false   （跑完是否保留容器）

退出码：0 = 整条流水线通过；非 0 = 中间任一步失败
#>

[CmdletBinding()]
param(
    [string]$HermesVersion = '0.20.5',
    [int]   $Rounds        = 30,
    [switch]$SkipBuild     = $false,
    [switch]$KeepContainer = $false,
    [string]$ImageTag      = "hermes-week3:$HermesVersion",
    [string]$ApiKey        = 'soak-test-key-2026-dongbowen-dbrh',
    [int]   $GatewayPort   = 8642,
    [int]   $MemoryPort    = 8420
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here        # week3/
$out  = Join-Path $root "pipeline-out" (Get-Date -Format 'yyyyMMdd-HHmmss')
New-Item -ItemType Directory -Force -Path $out | Out-Null
$logFile = Join-Path $out 'pipeline.log'

function Log {
    param([string]$msg)
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $msg"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Step-Header([string]$name) {
    Log ''
    Log '=========================================='
    Log "  $name"
    Log '=========================================='
}

function Stop-ContainerIfAny([string]$name) {
    $existing = docker ps -a --filter "name=$name" --format '{{.ID}}' 2>$null
    if ($existing) {
        Log "  删旧容器 $name ($existing)"
        docker rm -f $name 2>$null | Out-Null
    }
}

# ---------- Step 1: build ----------

if (-not $SkipBuild) {
    Step-Header 'Step 1/5: docker build'
    $dockerfile = Join-Path $here 'Dockerfile'
    if (-not (Test-Path $dockerfile)) {
        Log "[!] 找不到 ./Dockerfile（已按会议总结「内聚性原则」在 3-full-pipeline 下独立副本，未引用 week2/）"
        exit 10
    }
    Log "  Dockerfile=$dockerfile"
    Log "  ARG HERMES_VERSION=$HermesVersion"
    docker build --build-arg "HERMES_VERSION=$HermesVersion" -t $ImageTag -f $dockerfile (Split-Path -Parent $dockerfile)
    if ($LASTEXITCODE -ne 0) { Log '[!] docker build 失败'; exit 11 }
} else {
    Step-Header 'Step 1/5: docker build（跳过，使用本地已有镜像）'
    Log "  假设镜像已存在: $ImageTag"
    docker images $ImageTag --format '{{. .Repository}}:{{.Tag}}'
}

# ---------- Step 2: run container ----------

Step-Header 'Step 2/5: docker run（后台常驻）'
$name = 'hermes-week3-runner'
Stop-ContainerIfAny $name

Log "  image=$ImageTag  name=$name"
Log ('  port mapping: ' + $GatewayPort + '->8642, ' + $MemoryPort + '->8420')
$portMap1 = $GatewayPort.ToString() + ':8642'
$portMap2 = $MemoryPort.ToString() + ':8420'
docker run -d `
    --name $name `
    -p $portMap1 `
    -p $portMap2 `
    $ImageTag `
    sleep infinity
if ($LASTEXITCODE -ne 0) { Log '[!] docker run 失败'; exit 20 }

# 给容器一秒起来
Start-Sleep -Seconds 3

# ---------- Step 3: 装记忆插件 ----------

Step-Header 'Step 3/5: 装记忆插件 + 改 config'

Log '  在容器内安装 memory_tencentdb 插件...'
docker exec $name pip install --quiet /plugins/memory_tencentdb/*.whl 2>$null
if ($LASTEXITCODE -ne 0) {
    # 退化：可能没有 .whl，改用 git+pip
    Log '  fallback: pip install from git'
    docker exec $name pip install --quiet 'git+https://github.com/tencentdb/agent-memory.git#subdirectory=python'
}

# ⚠️ Hermes API Server 依赖 aiohttp。hermes CLI 用 /opt/hermes-agent/.venv/bin/python（隔离 venv）；
# 默认 pip 装到系统 site-packages，所以必须显式装到 venv。
Log '  补 aiohttp 到 hermes venv（否则 api_server adapter 警告 aiohttp not installed）'
docker exec $name /opt/hermes-agent/.venv/bin/python -m ensurepip --upgrade --default-pip 2>$null | Out-Null
docker exec $name /opt/hermes-agent/.venv/bin/python -m pip install --quiet aiohttp 2>$null
if ($LASTEXITCODE -ne 0) { Log '  ⚠️  venv 装 aiohttp 失败，gateway 可能起不来' }

Log "  写 .env 注入 API_KEY=$ApiKey"
$envContent = @"
MEMORY_TENCENTDB_GATEWAY_HOST=127.0.0.1
MEMORY_TENCENTDB_GATEWAY_PORT=8420
API_SERVER_ENABLED=true
API_SERVER_KEY=$ApiKey
"@
$envContent | docker exec -i $name bash -c 'cat > /root/.hermes/.env'

# ---------- Step 4: 起 gateway ----------

Step-Header 'Step 4/5: 起 gateway（容器内后台）'

# ⚠️ hermes 默认 API_SERVER_HOST=127.0.0.1，容器内 127.0.0.1≠宿主机网络接口，
# docker -p 映射不出来。强制绑 0.0.0.0。
# 同时清掉可能的 stale PID（之前的 gateway 关掉不干净会留下 .pid 锁）。
Log '  清理 stale gateway 锁（pid / lock）'
docker exec $name bash -c 'rm -f /root/.hermes/gateway.pid /root/.hermes/gateway.lock 2>/dev/null' 2>$null

Log '  在容器里启动 hermes gateway run（API_SERVER_HOST=0.0.0.0）'
docker exec -d $name bash -c "export API_SERVER_HOST=0.0.0.0 API_SERVER_PORT=8642 API_SERVER_KEY=$ApiKey; nohup hermes gateway run > /tmp/gateway.log 2>&1 &"

# 等 gateway 起来（健康检查）
$ready = $false
for ($i=1; $i -le 30; $i++) {
    Start-Sleep -Seconds 2
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$GatewayPort/health" -TimeoutSec 2 -ErrorAction Sil
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
}
if (-not $ready) {
    Log "[!] gateway 未在 60s 内就绪"
    Log '  容器 gateway 日志：'
    docker exec $name tail -30 /tmp/gateway.log
    exit 40
}
Log "  gateway healthy on :$GatewayPort"

# ---------- Step 5: 跑 soak + 验证 ----------

Step-Header 'Step 5/5: 跑事实剧本 + 验证 L0-L3'

# 5a: 跑事实剧本
Log "  跑 soak-facts.js --rounds=$Rounds"
$soakOut = Join-Path $out 'soak-out'
New-Item -ItemType Directory -Force -Path $soakOut | Out-Null

# 脚本和 facts.txt 需要在容器外（宿主机）跑，调宿主机 8642 上的 gateway
Push-Location $root/2-memory-l0l3
try {
    node soak-facts.js --rounds $Rounds --interval 1000 `
      --base-url "http://127.0.0.1:$GatewayPort/v1" `
      --api-key $ApiKey `
      --out-dir $soakOut
    if ($LASTEXITCODE -ne 0) { Log '[!] soak 失败'; exit 50 }
}
finally { Pop-Location }

# 5b: 验证记忆四层
Log "  跑 verify-memory.py"
Push-Location $root/2-memory-l0l3
try {
    python verify-memory.py `
      --gateway-url "http://127.0.0.1:$MemoryPort" `
      --out-dir $soakOut
    if ($LASTEXITCODE -ne 0) { Log '[!] verify 失败（脚本正常完成但记忆缺失）'; exit 51 }
}
finally { Pop-Location }

# ---------- 收尾 ----------

Step-Header '完成'
Log "  产物目录: $out"
Log "  包含: pipeline.log + soak-out/"
if (-not $KeepContainer) {
    Log "  清理容器 $name"
    Stop-ContainerIfAny $name
} else {
    Log "  容器 $name 保留运行"
}

exit 0