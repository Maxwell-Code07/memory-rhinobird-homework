$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "Hermes Soak - Error Handling Evidence"

Write-Host "=== Evidence A: real Hermes + intentionally wrong API key ===" -ForegroundColor Cyan
Write-Host "Expected: two failed rounds, HTTP 401, final JSON status=fail, process does not crash.`n"

$roundsPath = Join-Path $PSScriptRoot "workspace\error-api-demo\conversations.jsonl"
$metaPath = Join-Path $PSScriptRoot "workspace\error-api-demo\meta.json"

Get-Content -Encoding UTF8 -LiteralPath $roundsPath | ForEach-Object {
    $round = $_ | ConvertFrom-Json
    [pscustomobject]@{
        Round = $round.round
        Status = $round.status
        ErrorType = $round.error.type
        ExitCode = $round.exitCode
        Response = $round.response
    }
} | Format-List

Write-Host "=== Structured failure summary (meta.json) ===" -ForegroundColor Yellow
Get-Content -Raw -Encoding UTF8 -LiteralPath $metaPath

Write-Host "=== Evidence B: invalid parameter is rejected explicitly ===" -ForegroundColor Cyan
Write-Host "Command: node hermes-soak.mjs --rounds 0 --interval-ms 1000 --duration-minutes 1`n"
docker exec hermes-basic-demo node hermes-soak.mjs --rounds 0 --interval-ms 1000 --duration-minutes 1
$invalidExitCode = $LASTEXITCODE
Write-Host "`nInvalid-parameter exit code: $invalidExitCode (expected non-zero)" -ForegroundColor Yellow

Write-Host "`nEvidence files:" -ForegroundColor Green
Write-Host $roundsPath
Write-Host $metaPath
Write-Host "The Hermes demo container remains running." -ForegroundColor Green
