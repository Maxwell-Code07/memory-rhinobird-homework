# build.bat edge-case test suite (fake docker.exe => instant flow)
# Run with Windows PowerShell:  powershell -File bat-edge-tests.ps1
$ErrorActionPreference = 'Stop'
$repo = 'G:\claude codex_workspace\开源计划\腾讯犀牛鸟开源计划\TencentDB-Agent-Memory'
$compat = Join-Path $repo 'docker\hermes-version-compat'
$fakeDir = Join-Path $env:TEMP 'fakebin-bat'
New-Item -ItemType Directory -Force $fakeDir | Out-Null

# fake docker as a REAL .exe (a .cmd/.bat fake would transfer control away
# from build.bat — the classic batch gotcha) — logs args, exits 0.
if (-not (Test-Path (Join-Path $fakeDir 'docker.exe'))) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
class FakeDocker {
    static void Main(string[] args) {
        File.AppendAllText(Path.Combine(Path.GetTempPath(), "fake-docker.log"),
            "FAKE_DOCKER " + string.Join(" ", args) + Environment.NewLine);
    }
}
'@ -OutputAssembly (Join-Path $fakeDir 'docker.exe') -OutputType ConsoleApplication -ErrorAction Stop
}

$pass = 0; $fail = 0
function Check($name, $cond, $detail) {
    if ($cond) { $script:pass++; Write-Host "  PASS  $name" }
    else { $script:fail++; Write-Host "  FAIL  $name  -> $detail" }
}

function Run-Bat([string[]]$inputLines, [hashtable]$envs) {
    @('HERMES_VERSION','MODEL_API_KEY','MODEL_BASE_URL','MODEL_NAME','MODEL_PROVIDER',
      'SOAK_ROUNDS','SOAK_INTERVAL','SOAK_MAX_TOTAL_SECONDS','HTTP_PROXY','HTTPS_PROXY','NO_PAUSE') | ForEach-Object { Remove-Item "env:$_" -ErrorAction SilentlyContinue }
    $env:PATH = "$fakeDir;" + (Get-Item env:Path).Value
    $env:NO_PAUSE = '1'
    foreach ($k in $envs.Keys) { Set-Item "env:$k" $envs[$k] }
    $inFile = Join-Path $env:TEMP 'bat-edge-in.txt'
    if ($null -eq $inputLines -or $inputLines.Count -eq 0) { $inputLines = @('') }
    Set-Content -Path $inFile -Value ($inputLines -join "`r`n") -Encoding ASCII
    Remove-Item "$env:TEMP\fake-docker.log" -ErrorAction SilentlyContinue
    Push-Location $compat
    cmd /c "build.bat < `"$inFile`" > `"$env:TEMP\bat-edge-out.log`" 2>&1"
    $rc = $LASTEXITCODE
    Pop-Location
    $log = if (Test-Path "$env:TEMP\bat-edge-out.log") { Get-Content "$env:TEMP\bat-edge-out.log" -Raw } else { '' }
    $dockerLog = if (Test-Path "$env:TEMP\fake-docker.log") { Get-Content "$env:TEMP\fake-docker.log" -Raw } else { '' }
    return @{ rc = $rc; log = $log; dockerLog = $dockerLog }
}

Write-Host '== C1 happy path: valid version + preset key (fake docker full flow) =='
$r = Run-Bat @('v2026.8.18') @{ MODEL_API_KEY = 'sk-test-123' }
Check 'RC=0' ($r.rc -eq 0) "rc=$($r.rc)"
Check 'docker build called with version' ($r.dockerLog -match 'build --build-arg HERMES_VERSION=v2026.8.18') $r.dockerLog
Check 'docker run --rm -e MODEL_API_KEY (no value)' ($r.dockerLog -match 'run --rm -e MODEL_API_KEY(?!=)') $r.dockerLog
Check 'no key leak in command line' ($r.dockerLog -notmatch 'sk-test-123')

Write-Host '== C2 empty version (just Enter) -> retry =='
$r = Run-Bat @('', '2026.8.18') @{ MODEL_API_KEY = 'sk-test-123' }
Check 'RC=0' ($r.rc -eq 0) "rc=$($r.rc)"
Check 'format hint shown' ($r.log -match 'YYYY.M.D')
Check 'final version v2026.8.18' ($r.dockerLog -match 'HERMES_VERSION=v2026.8.18')

Write-Host '== C3 multi-segment version 2026.8.16.2 =='
$r = Run-Bat @('2026.8.16.2') @{ MODEL_API_KEY = 'sk-test-123' }
Check 'RC=0' ($r.rc -eq 0) "rc=$($r.rc)"
Check 'version v2026.8.16.2' ($r.dockerLog -match 'HERMES_VERSION=v2026.8.16.2')

Write-Host '== C4 too-short 2026.8 (missing day) -> error + retry =='
$r = Run-Bat @('2026.8', '2026.8.18') @{ MODEL_API_KEY = 'sk-test-123' }
Check 'RC=0 (passes after retry)' ($r.rc -eq 0) "rc=$($r.rc)"
Check 'error message shown' ($r.log -match 'correct format|YYYY.M.D')
Check 'tags URL shown' ($r.log -match 'hermes-agent/tags')

Write-Host '== C5 version with letters 2026.8.1a -> error + retry =='
$r = Run-Bat @('2026.8.1a', 'v2026.8.18') @{ MODEL_API_KEY = 'sk-test-123' }
Check 'RC=0' ($r.rc -eq 0) "rc=$($r.rc)"
Check 'rejected (no build for bad version)' ($r.dockerLog -match 'HERMES_VERSION=v2026.8.18')

Write-Host '== C6 env-preset invalid version -> fast fail =='
$r = Run-Bat @() @{ HERMES_VERSION = 'abc'; MODEL_API_KEY = 'sk-test-123' }
Check 'RC=1' ($r.rc -eq 1) "rc=$($r.rc)"
Check 'no docker call' ($r.dockerLog -eq '')

Write-Host '== C7 env-preset valid version -> prompt skipped =='
$r = Run-Bat @() @{ HERMES_VERSION = 'v2026.8.18'; MODEL_API_KEY = 'sk-test-123' }
Check 'RC=0' ($r.rc -eq 0) "rc=$($r.rc)"
Check 'build v2026.8.18' ($r.dockerLog -match 'HERMES_VERSION=v2026.8.18')

Write-Host '== C8 preset empty MODEL_BASE_URL etc -> defaults applied =='
$r = Run-Bat @('2026.8.18') @{ MODEL_API_KEY = 'sk-test-123' }
Check 'defaults deepseek passed to run' ($r.dockerLog -match 'MODEL_BASE_URL=https://api.deepseek.com') $r.dockerLog
Check 'default model name passed' ($r.dockerLog -match 'MODEL_NAME=deepseek-v4-flash')

Write-Host '== C9 SOAK_* env preset -> forwarded to run =='
$r = Run-Bat @('2026.8.18') @{ MODEL_API_KEY = 'sk-test-123'; SOAK_ROUNDS = '7'; SOAK_INTERVAL = '3'; SOAK_MAX_TOTAL_SECONDS = '99' }
Check 'SOAK_ROUNDS forwarded' ($r.dockerLog -match 'SOAK_ROUNDS=7')
Check 'SOAK_INTERVAL forwarded' ($r.dockerLog -match 'SOAK_INTERVAL=3')
Check 'SOAK_MAX_TOTAL_SECONDS forwarded' ($r.dockerLog -match 'SOAK_MAX_TOTAL_SECONDS=99')

Write-Host ''
Write-Host "SUMMARY: $pass passed, $fail failed"
exit $(if ($fail -eq 0) { 0 } else { 1 })
