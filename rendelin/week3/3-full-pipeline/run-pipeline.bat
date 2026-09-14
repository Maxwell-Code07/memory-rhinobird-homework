@echo off
setlocal enabledelayedexpansion
REM ============================================================================
REM  Week3 Advanced2 - Windows one-click pipeline (double-click to run)
REM  Flow: docker build -> run container -> auto install plugin + start Gateway
REM        -> soak conversation -> verify L0-L3
REM  Output: results\result.json (soak verdict) + results\l0l3.json (L0-L3 check)
REM          memory-data\ (L0 conversations / L1 records / L2 scene_blocks / L3 persona.md)
REM  Proxy: default http://host.docker.internal:7890
REM  Reach host Clash from inside Docker. Do NOT use 127.0.0.1 (that is the container itself).
REM  Enter NONE or 0 to disable proxy (direct connect).
REM  Note: GitHub raw 429 is common. If build 429s, switch Clash node or use the proxy.
REM        If apt reports Could not connect, the proxy is wrong or Clash is off.
REM ============================================================================

echo.
echo  ============================================================
echo    Hermes + Memory Plugin : one-click pipeline
echo    (build - run - install plugin - soak - verify L0-L3)
echo  ============================================================
echo.

REM ---- 0. check docker ------------------------------------------------------
docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker Desktop is not running. Please start Docker Desktop first.
  pause
  exit /b 1
)

REM ---- 1. collect config ----------------------------------------------------
set /p VERSION="Hermes version (e.g. 2026.8.19, 'v' optional; default 2026.8.19): "
if "%VERSION%"=="" set VERSION=2026.8.19
set /p MODEL_API_KEY="Model API Key (required): "
if "%MODEL_API_KEY%"=="" (
  echo [ERROR] MODEL_API_KEY is required.
  pause
  exit /b 1
)
set /p MODEL_BASE_URL="Model BASE_URL (default https://api.deepseek.com/v1): "
if "%MODEL_BASE_URL%"=="" set MODEL_BASE_URL=https://api.deepseek.com/v1
set /p MODEL_NAME="Model name (default deepseek-v4-flash): "
if "%MODEL_NAME%"=="" set MODEL_NAME=deepseek-v4-flash
set /p MODEL_PROVIDER="Model provider (default deepseek; other OpenAI-compat use custom): "
if "%MODEL_PROVIDER%"=="" set MODEL_PROVIDER=deepseek
set /p SOAK_ROUNDS="soak rounds (default 10): "
if "%SOAK_ROUNDS%"=="" set SOAK_ROUNDS=10
set /p SOAK_INTERVAL="soak interval sec (default 5): "
if "%SOAK_INTERVAL%"=="" set SOAK_INTERVAL=5
set /p SOAK_WAIT_AFTER="soak post-wait sec for memory settle (default 120): "
if "%SOAK_WAIT_AFTER%"=="" set SOAK_WAIT_AFTER=120

REM ---- proxy: default host.docker.internal:7890, configurable -----------------
echo.
echo  Proxy. ENTER = use http://host.docker.internal:7890 (default); NONE/0 = no proxy.
set PROXY_ADDR=
set /p PROXY_ADDR="> Proxy [default http://host.docker.internal:7890 / NONE]: "
set "USE_PROXY=1"
if /i "%PROXY_ADDR%"=="NONE" set "USE_PROXY=0"
if "%PROXY_ADDR%"=="0" set "USE_PROXY=0"
if "%USE_PROXY%"=="1" if "!PROXY_ADDR!"=="" set PROXY_ADDR=http://host.docker.internal:7890
if "%USE_PROXY%"=="1" (
  set "PROXY_ARGS=--build-arg INSTALL_PROXY=!PROXY_ADDR! --build-arg HTTP_PROXY=!PROXY_ADDR! --build-arg HTTPS_PROXY=!PROXY_ADDR!"
  echo    [proxy] !PROXY_ADDR!
) else (
  set "PROXY_ARGS="
  echo    [proxy] none
)

set "IMG=hermes-memory:v%VERSION%"
set "DIR=%~dp0"
set "RESULT=%DIR%results"
set "MEMDATA=%DIR%memory-data"
if not exist "%RESULT%" mkdir "%RESULT%"
if not exist "%MEMDATA%" mkdir "%MEMDATA%"

echo.
echo  [config] version=%VERSION% rounds=%SOAK_ROUNDS% interval=%SOAK_INTERVAL%s wait=%SOAK_WAIT_AFTER%s model=%MODEL_NAME%
echo.

REM ---- 2. build image -------------------------------------------------------
echo [1/5] building image %IMG% ...
docker build --build-arg HERMES_VERSION=v%VERSION% !PROXY_ARGS! -t %IMG% .
if errorlevel 1 (
  echo [ERROR] image build failed.
  echo         If it says 429 / RPC failed on GitHub - switch Clash node then retry.
  echo         If it says Could not connect / timeout - check proxy or start Clash.
  pause
  exit /b 1
)
echo [1/5] image built OK
echo.

REM ---- 3. run container (auto: plugin + Gateway + soak + L0-L3) -------------
echo [2/5~5/5] running container; Gateway will start and soak will run inside...
echo           memory will be written to: %MEMDATA%
echo.
docker rm -f hermes-memory-run 2>nul
docker run --rm --name hermes-memory-run ^
  -e MODEL_API_KEY="%MODEL_API_KEY%" ^
  -e MODEL_BASE_URL="%MODEL_BASE_URL%" ^
  -e MODEL_NAME="%MODEL_NAME%" ^
  -e MODEL_PROVIDER="%MODEL_PROVIDER%" ^
  -e TDAI_LLM_API_KEY="%MODEL_API_KEY%" ^
  -e TDAI_LLM_BASE_URL="%MODEL_BASE_URL%" ^
  -e TDAI_LLM_MODEL="%MODEL_NAME%" ^
  -e SOAK_ROUNDS=%SOAK_ROUNDS% ^
  -e SOAK_INTERVAL=%SOAK_INTERVAL% ^
  -e SOAK_MAX_TOTAL_SECONDS=600 ^
  -e SOAK_WAIT_AFTER=%SOAK_WAIT_AFTER% ^
  -e HERMES_HOME=/opt/data ^
  -e TDAI_DATA_DIR=/opt/data ^
  -e MEMORY_TENCENTDB_GATEWAY_HOST=127.0.0.1 ^
  -e MEMORY_TENCENTDB_GATEWAY_PORT=8420 ^
  -p 8420:8420 ^
  -v "%RESULT%:/results" ^
  -v "%MEMDATA%:/opt/data" ^
  %IMG%
set RC=%errorlevel%

echo.
echo ============================================================
if %RC%==0 (
  echo  [RESULT] PASSED
) else (
  echo  [RESULT] FAILED (exit code %RC%)
)
echo  results file : %RESULT%\result.json   %RESULT%\l0l3.json
echo  memory data  : %MEMDATA%\  (conversations / records / scene_blocks / persona.md)
echo ============================================================
echo.
pause
exit /b %RC%
