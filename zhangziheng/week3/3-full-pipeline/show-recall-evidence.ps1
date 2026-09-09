param(
  [string]$EvidenceDir = ""
)

if ([string]::IsNullOrWhiteSpace($EvidenceDir)) {
  $EvidenceDir = Join-Path $PSScriptRoot "runs\20260909_093223\evidence"
}

$result = Get-Content -Encoding UTF8 (Join-Path $EvidenceDir "recall-result.json") -Raw | ConvertFrom-Json
$defaultQuery = ([char]0x9752) + ([char]0x677e) + ([char]0x706f) + ([char]0x5854) + "-7429"
$query = if ($result.query -and $result.query -notmatch "闈掓澗|青松") { $result.query } else { $defaultQuery }
$context = if ($result.body.context) { $result.body.context } else { "" }

Write-Host "query = $query" -ForegroundColor Cyan
Write-Host "HTTP status = $($result.status)" -ForegroundColor Cyan
Write-Host "matched = $($result.matched)" -ForegroundColor Cyan
Write-Host "memory_count = $($result.body.memory_count)" -ForegroundColor Cyan
Write-Host "----- recalled context -----" -ForegroundColor Yellow
Write-Output $context
