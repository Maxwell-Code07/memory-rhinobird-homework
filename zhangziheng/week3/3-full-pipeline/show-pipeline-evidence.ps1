param(
  [string]$RunDir = ""
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($RunDir)) {
  $RunDir = Get-ChildItem (Join-Path $PSScriptRoot "runs") -Directory |
    Sort-Object Name -Descending |
    Where-Object { Test-Path (Join-Path $_.FullName "pipeline-summary.json") } |
    Select-Object -First 1 -ExpandProperty FullName
}

$summary = Get-Content -Raw -Encoding UTF8 (Join-Path $RunDir "pipeline-summary.json") | ConvertFrom-Json
$verify = Get-Content -Raw -Encoding UTF8 (Join-Path $RunDir "evidence\verification.json") | ConvertFrom-Json

Write-Host "ONE-COMMAND PIPELINE EVIDENCE" -ForegroundColor Yellow
Write-Host ".\3-full-pipeline\run-pipeline.ps1 -HermesVersion '$($summary.hermesVersion)' -Rounds $($summary.soak.config.rounds) -KeepContainer" -ForegroundColor Cyan
Write-Host ""
Write-Host "run_id              $($summary.runId)"
Write-Host "status              $($summary.status.ToUpper())" -ForegroundColor Green
Write-Host "bootstrap           $($summary.phases.bootstrap.status) ($($summary.phases.bootstrap.detail))"
Write-Host "build               $($summary.phases.build.status)"
Write-Host "fresh container     $($summary.phases.prepare.status)"
Write-Host "plugin + gateway    $($summary.phases.install_plugin.status) / $($summary.phases.gateway.status)"
Write-Host "real soak           $($summary.soak.statistics.successfulRounds)/$($summary.soak.statistics.attemptedRounds) PASS"
Write-Host "L0 / L1 / L2 / L3   $($verify.l0.records) / $($verify.l1.records) / $($verify.l2.sceneFiles) / $($verify.l3.personaBytes) bytes"
Write-Host "recall query        $($verify.recall.query)"
Write-Host "recall matched      $($verify.recall.matched)"
Write-Host "Dockerfile SHA256   $($summary.dockerfileSha256)"
