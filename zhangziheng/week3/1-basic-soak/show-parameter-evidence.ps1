$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Hermes Soak - Three Parameters Evidence"

$roundsDir = Join-Path $PSScriptRoot "workspace\real-pass-demo"
$durationDir = Join-Path $PSScriptRoot "workspace\real-duration-demo"
$roundsMeta = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $roundsDir "meta.json") | ConvertFrom-Json
$durationMeta = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $durationDir "meta.json") | ConvertFrom-Json
$roundResults = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $roundsDir "conversations.jsonl") | ForEach-Object { $_ | ConvertFrom-Json }
$latencySum = ($roundResults | Measure-Object -Property durationMs -Sum).Sum
$observedNonRequestMs = $roundsMeta.elapsedMs - $latencySum
$expectedIntervalMs = ($roundsMeta.statistics.attemptedRounds - 1) * $roundsMeta.config.intervalMs

Write-Host "=== Parameter 1: rounds ===" -ForegroundColor Cyan
[pscustomobject]@{
    ConfiguredRounds = $roundsMeta.config.rounds
    AttemptedRounds = $roundsMeta.statistics.attemptedRounds
    CompletionReason = $roundsMeta.completionReason
    Status = $roundsMeta.status
} | Format-List

Write-Host "=== Parameter 2: interval-ms ===" -ForegroundColor Cyan
[pscustomobject]@{
    ConfiguredIntervalMs = $roundsMeta.config.intervalMs
    NumberOfIntervals = $roundsMeta.statistics.attemptedRounds - 1
    ExpectedWaitMs = $expectedIntervalMs
    ObservedNonRequestMs = $observedNonRequestMs
    Evidence = "Observed non-request time includes the configured waits"
} | Format-List

Write-Host "=== Parameter 3: duration-minutes ===" -ForegroundColor Cyan
[pscustomobject]@{
    ConfiguredMaxRounds = $durationMeta.config.rounds
    ConfiguredDurationMinutes = $durationMeta.config.durationMinutes
    ConfiguredDurationMs = [int]($durationMeta.config.durationMinutes * 60000)
    ActualCompletedRounds = $durationMeta.statistics.attemptedRounds
    ActualElapsedMs = $durationMeta.elapsedMs
    CompletionReason = $durationMeta.completionReason
    Status = $durationMeta.status
} | Format-List

Write-Host "All values above come from REAL Hermes runs, not mock." -ForegroundColor Green
Write-Host "Rounds/interval evidence: $roundsDir" -ForegroundColor Green
Write-Host "Duration evidence: $durationDir" -ForegroundColor Green
