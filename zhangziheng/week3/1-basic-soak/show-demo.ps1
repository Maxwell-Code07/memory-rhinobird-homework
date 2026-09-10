$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Hermes Basic Soak - REAL Multi-turn Result"

Write-Host "=== Docker container ===" -ForegroundColor Cyan
docker ps --filter "name=^/hermes-real-demo$" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"

Write-Host "`n=== Hermes and Node versions ===" -ForegroundColor Cyan
docker exec hermes-real-demo hermes --version
docker exec hermes-real-demo node --version

Write-Host "`n=== REAL Hermes conversations (not mock) ===" -ForegroundColor Cyan
$roundsPath = Join-Path $PSScriptRoot "workspace\real-pass-demo\conversations.jsonl"
$metaPath = Join-Path $PSScriptRoot "workspace\real-pass-demo\meta.json"
Get-Content -Encoding UTF8 -LiteralPath $roundsPath | ForEach-Object {
    $round = $_ | ConvertFrom-Json
    [pscustomobject]@{
        Round = $round.round
        Status = $round.status
        DurationMs = $round.durationMs
        SessionId = $round.sessionId
        Prompt = $round.prompt
        Response = $round.response
    }
} | Format-List

Write-Host "=== Structured PASS summary (meta.json) ===" -ForegroundColor Yellow
Get-Content -Raw -Encoding UTF8 -LiteralPath $metaPath

Write-Host "Result file: $metaPath" -ForegroundColor Green
Write-Host "The container remains running for further inspection." -ForegroundColor Green
