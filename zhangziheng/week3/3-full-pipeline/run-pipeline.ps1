param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$HermesVersion,
    [string]$Week2Dir = "",
    [string]$PluginDir = "",
    [string]$ConfigVolume = "hermes-real-home",
    [int]$Rounds = 8,
    [switch]$KeepContainer,
    [switch]$OfflineDependencies
)

$ErrorActionPreference = "Stop"
$pipelineRoot = $PSScriptRoot
$thirdWeekRoot = Split-Path $pipelineRoot -Parent
$openSourceRoot = Split-Path $thirdWeekRoot -Parent
$planRoot = Split-Path $openSourceRoot -Parent
if (-not $Week2Dir) { $Week2Dir = $pipelineRoot }
if (-not $PluginDir) { throw "Pass -PluginDir explicitly." }
if (-not (Test-Path -LiteralPath (Join-Path $Week2Dir "Dockerfile"))) {
    throw "Week 2 Dockerfile not found in: $Week2Dir"
}
$advancedSource = Join-Path $pipelineRoot "..\2-memory-l0l3"
$basicSource = Join-Path $pipelineRoot "..\1-basic-soak"
$runId = Get-Date -Format "yyyyMMdd_HHmmss"
$outputDir = Join-Path $pipelineRoot "runs\$runId"
$evidenceDir = Join-Path $outputDir "evidence"
$runtimeDir = Join-Path $evidenceDir "runtime-data"
$imageTag = "hermes:week3-pipeline-$HermesVersion"
$containerName = "hermes-pipeline-$runId"
$homeVolume = "hermes-pipeline-home-$runId"
$sourceArchive = Join-Path $outputDir "tdai-source.tgz"
$summaryPath = Join-Path $outputDir "pipeline-summary.json"
$startedAt = Get-Date
$phaseResults = [ordered]@{}
$containerCreated = $false

New-Item -ItemType Directory -Force -Path $evidenceDir, $runtimeDir | Out-Null

function Invoke-DockerChecked {
    param([string[]]$Arguments)
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Set-Phase {
    param([string]$Name, [string]$Status, [string]$Detail = "")
    $phaseResults[$Name] = [ordered]@{ status = $Status; detail = $Detail }
    Write-Host "[$Status] $Name $Detail"
}

try {
    if (-not (Test-Path -LiteralPath (Join-Path $Week2Dir "Dockerfile"))) { throw "第二周 Dockerfile 不存在：$Week2Dir" }
    if (-not (Test-Path -LiteralPath (Join-Path $PluginDir "package.json"))) { throw "插件源码不存在：$PluginDir" }
    if (-not (Test-Path -LiteralPath (Join-Path $advancedSource "fact-prompts.json"))) { throw "事实 prompts 不存在：$advancedSource" }

    Set-Phase "build" "running" "image=$imageTag"
    Invoke-DockerChecked @("build", "--progress=plain", "--build-arg", "HERMES_VERSION=$HermesVersion", "-t", $imageTag, $Week2Dir)
    $dockerfileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Week2Dir "Dockerfile")).Hash
    Set-Phase "build" "pass" "dockerfile_sha256=$dockerfileHash"

    Set-Phase "prepare" "running" "container=$containerName"
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    tar --exclude=node_modules --exclude=.git -czf $sourceArchive -C $PluginDir .
    Invoke-DockerChecked @("volume", "create", $homeVolume)
    Invoke-DockerChecked @("run", "--rm", "-v", "${ConfigVolume}:/source:ro", "-v", "${homeVolume}:/target", $imageTag, "sh", "-c", "cp /source/.env /target/.env; cp /source/config.yaml /target/config.yaml")
    Invoke-DockerChecked @("run", "--name", $containerName, "-dit", "-v", "${homeVolume}:/opt/hermes-home", "-v", "${runtimeDir}:/opt/tdai-data", "-w", "/workspace/advanced", $imageTag, "sh")
    $containerCreated = $true
    Invoke-DockerChecked @("cp", "${advancedSource}\\.", "${containerName}:/workspace/advanced")
    Invoke-DockerChecked @("cp", "${basicSource}\\.", "${containerName}:/workspace/soak")
    Invoke-DockerChecked @("cp", $sourceArchive, "${containerName}:/tmp/tdai-source.tgz")
    Invoke-DockerChecked @("exec", $containerName, "sh", "-c", "mkdir -p /source/tdai /workspace/advanced; tar -xzf /tmp/tdai-source.tgz -C /source/tdai")
    Invoke-DockerChecked @("exec", $containerName, "sh", "-c", "cp /workspace/advanced/npx-offline-wrapper.sh /usr/local/bin/npx; chmod +x /usr/local/bin/npx")
    Set-Phase "prepare" "pass" "fresh_container=true"

    Set-Phase "install_plugin" "running"
    $installEnv = @()
    if ($OfflineDependencies) {
        $offlineNodeModules = Join-Path $advancedSource "linux-install\package\node_modules"
        if (-not (Test-Path -LiteralPath $offlineNodeModules)) { throw "-OfflineDependencies 指定了离线模式，但未找到 $offlineNodeModules" }
        Invoke-DockerChecked @("exec", $containerName, "sh", "-c", "mkdir -p /opt/hermes-home/tdai-memory-plugin")
        Invoke-DockerChecked @("cp", $offlineNodeModules, "${containerName}:/opt/hermes-home/tdai-memory-plugin/node_modules")
        $installEnv = @("-e", "TDAI_SKIP_NPM_INSTALL=1")
    }
    Invoke-DockerChecked (@("exec") + $installEnv + @($containerName, "sh", "/workspace/advanced/install-plugin-in-container.sh"))
    Set-Phase "install_plugin" "pass" "provider=memory_tencentdb"

    Set-Phase "gateway" "running"
    Invoke-DockerChecked @("exec", "-d", $containerName, "sh", "/workspace/advanced/start-gateway-in-container.sh")
    $health = $null
    $healthy = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $health = & docker exec $containerName node /workspace/advanced/health-check.mjs 2>$null
        if ($LASTEXITCODE -eq 0) { $healthy = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $healthy) { throw "Gateway health check failed after 60s: $($health -join ' ')" }
    Set-Phase "gateway" "pass" $health

    Set-Phase "soak" "running" "rounds=$Rounds"
    Invoke-DockerChecked @("exec", $containerName, "node", "/workspace/advanced/../soak/hermes-soak.mjs", "--rounds", "$Rounds", "--interval-ms", "1000", "--duration-minutes", "20", "--request-timeout-ms", "180000", "--toolsets", "context_engine,memory", "--prompts", "/workspace/advanced/fact-prompts.json", "--output", "/workspace/advanced/evidence/soak")
    Set-Phase "soak" "pass" "meta.json generated"

    $metaRaw = & docker exec $containerName sh -c "cat /workspace/advanced/evidence/soak/meta.json"
    if ($LASTEXITCODE -ne 0) { throw "无法读取 soak meta.json" }
    $meta = ($metaRaw -join "`n") | ConvertFrom-Json
    if ($meta.status -ne "pass") { throw "soak status=$($meta.status)" }
    $sessionId = $meta.finalSessionId
    Set-Phase "verify_memory" "running" "session=$sessionId"
    Invoke-DockerChecked @("exec", $containerName, "node", "/workspace/advanced/verify-memory.mjs", "--session", $sessionId, "--timeout-seconds", "180")
    Set-Phase "verify_memory" "pass" "L0-L3 and recall passed"

    Invoke-DockerChecked @("cp", "${containerName}:/workspace/advanced/evidence/.", $evidenceDir)
    $finishedAt = Get-Date
    $summary = [ordered]@{
        schemaVersion = 1
        status = "pass"
        runId = $runId
        image = $imageTag
        hermesVersion = $HermesVersion
        container = $containerName
        dockerfile = (Join-Path $Week2Dir "Dockerfile")
        dockerfileSha256 = $dockerfileHash
        startedAt = $startedAt.ToUniversalTime().ToString("o")
        finishedAt = $finishedAt.ToUniversalTime().ToString("o")
        elapsedMs = [int](($finishedAt - $startedAt).TotalMilliseconds)
        phases = $phaseResults
        soak = $meta
        evidenceDir = $evidenceDir
        keptContainer = [bool]$KeepContainer
    }
    $summary | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
    Write-Host "PIPELINE PASS: $summaryPath" -ForegroundColor Green
}
catch {
    $phaseResults["error"] = [ordered]@{
        status = "fail"
        detail = $_.Exception.Message
    }
    $failedSummary = [ordered]@{
        schemaVersion = 1
        status = "fail"
        runId = $runId
        image = $imageTag
        container = $containerName
        phases = $phaseResults
    }
    $failedSummary | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
    Write-Error $_
    exit 1
}
finally {
    if ($containerCreated -and -not $KeepContainer) {
        & docker rm -f $containerName 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $sourceArchive) {
        Remove-Item -LiteralPath $sourceArchive -Force
    }
}
