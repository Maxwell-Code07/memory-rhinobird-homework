@echo off
rem ============================================================================
rem  Hermes 版本兼容检测 - 一键构建 + 自动对话（Windows 双击运行）
rem  注意：本文件必须以 GBK/ANSI（代码页 936）编码 + CRLF 行尾保存，
rem        请不要用 UTF-8 重新保存，否则中文会乱码、脚本会解析失败。
rem
rem  流程：输入 Hermes 版本号 -> docker build（构建该版本基线镜像）
rem        -> docker run（自动对话 soak，--rm 容器跑完即删）
rem        -> 清理敏感信息（密钥不写盘、环境变量用完即清）
rem
rem  所有交互项都支持"环境变量预置"跳过提问（便于 CI / 非交互）：
rem    HERMES_VERSION   例如 2026.8.18 / v2026.8.18
rem    MODEL_API_KEY / MODEL_BASE_URL / MODEL_NAME / MODEL_PROVIDER
rem    SOAK_ROUNDS / SOAK_INTERVAL / SOAK_MAX_TOTAL_SECONDS
rem    PROXY_ADDR       如 http://host.docker.internal:7890（仅作为 --build-arg 传给构建）
rem    NO_PAUSE=1       结束时自动关闭窗口（CI 用）
rem
rem  国内网络构建如失败（GitHub 限流/不通），可用 PROXY_ADDR 或交互输入代理地址；
rem  只作 build-arg，不设客户端 env（避免 Docker Desktop 改写代理导致拉基础镜像失败）。
rem ============================================================================
setlocal
cd /d "%~dp0"

echo.
echo  ============================================================
echo    Hermes 版本兼容检测 — 一键构建 + 自动对话
echo  ============================================================
echo.

rem ---- 0. 定位 docker（PATH 或 Docker Desktop 默认安装位置）-------------------
where docker >nul 2>nul
if errorlevel 1 (
    if exist "%ProgramFiles%\Docker\Docker\resources\bin\docker.exe" (
        set "PATH=%ProgramFiles%\Docker\Docker\resources\bin;%PATH%"
    ) else (
        echo [错误] 未找到 docker 命令，请先安装并启动 Docker Desktop。
        if not defined NO_PAUSE pause
        exit /b 1
    )
)

rem ---- 1. 输入 Hermes 版本号（格式不对则提示并重新输入，可 Ctrl+C 退出）--------
rem 注意：空值必须先 goto 跳过子串判断——cmd 对空变量的
rem "%V:~0,1%" 与 "%V:~1%" 同现会解析崩溃（块内尤其如此）
:ask_version
set "VERSION_IN="
if defined HERMES_VERSION set "VERSION_IN=%HERMES_VERSION%"
if not defined VERSION_IN set /p VERSION_IN=您选择的 Hermes 版本为（注意：Hermes 版本号是日期格式 YYYY.M.D，例如 2026.8.18；v 前缀可省略）：
set "V=%VERSION_IN%"
if not defined VERSION_IN goto version_invalid
if "%V:~0,1%"=="v" set "V=%V:~1%"
echo %V%| findstr /r "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9.]*$" >nul
if not errorlevel 1 goto version_ok
:version_invalid
echo [错误] 版本号格式不正确："%VERSION_IN%"
echo        正确格式：日期 YYYY.M.D，例如 2026.8.18（v 前缀可省略，如 v2026.8.18 也行）
echo        可用版本查看：https://github.com/NousResearch/hermes-agent/tags
echo.
if defined HERMES_VERSION (
    echo [错误] 环境变量 HERMES_VERSION 预置的版本号无效，已退出。
    if not defined NO_PAUSE pause
    exit /b 1
)
goto ask_version
:version_ok
set "VERSION=v%V%"
echo [信息] 将构建 Hermes 版本：%VERSION%
echo.

rem ---- 2. 模型配置（已设环境变量则跳过提问；API Key 掩码输入）----------------
if defined MODEL_API_KEY (
    set "APIKEY=%MODEL_API_KEY%"
) else (
    for /f "usebackq delims=" %%K in (`powershell -NoProfile -Command "$s=Read-Host -AsSecureString 'MODEL_API_KEY (input hidden):';$b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);[Runtime.InteropServices.Marshal]::PtrToStringUni($b)"`) do set "APIKEY=%%K"
    if not defined APIKEY (
        echo [错误] 未输入 API Key，无法进行自动对话。
        if not defined NO_PAUSE pause
        exit /b 1
    )
)
if defined MODEL_BASE_URL ( set "BASEURL=%MODEL_BASE_URL%" ) else (
    set /p BASEURL=请输入 MODEL_BASE_URL（回车默认 https://api.deepseek.com）：
    if not defined BASEURL set "BASEURL=https://api.deepseek.com"
)
if defined MODEL_NAME ( set "MODELNAME=%MODEL_NAME%" ) else (
    set /p MODELNAME=请输入 MODEL_NAME（回车默认 deepseek-v4-flash）：
    if not defined MODELNAME set "MODELNAME=deepseek-v4-flash"
)
if defined MODEL_PROVIDER ( set "PROVIDER=%MODEL_PROVIDER%" ) else (
    set /p PROVIDER=请输入 MODEL_PROVIDER（回车默认 custom）：
    if not defined PROVIDER set "PROVIDER=custom"
)
echo [信息] 模型配置：%MODELNAME% @ %BASEURL% (provider: %PROVIDER%)
echo.

rem ---- 2b. 自动对话（soak）参数，回车用默认值 -----------------------------------
if defined SOAK_ROUNDS ( set "S_ROUNDS=%SOAK_ROUNDS%" ) else ( set /p S_ROUNDS=对话轮次（回车默认 10）： & if not defined S_ROUNDS set "S_ROUNDS=10" )
if defined SOAK_INTERVAL ( set "S_INTERVAL=%SOAK_INTERVAL%" ) else ( set /p S_INTERVAL=每轮间隔（秒，回车默认 5）： & if not defined S_INTERVAL set "S_INTERVAL=5" )
if defined SOAK_MAX_TOTAL_SECONDS ( set "S_TOTAL=%SOAK_MAX_TOTAL_SECONDS%" ) else ( set /p S_TOTAL=总对话时长上限（秒，回车默认 600）： & if not defined S_TOTAL set "S_TOTAL=600" )
rem 校验非负整数，非法则回退默认
echo %S_ROUNDS%| findstr /r "^[0-9][0-9]*$" >nul || set "S_ROUNDS=10"
echo %S_INTERVAL%| findstr /r "^[0-9][0-9]*$" >nul || set "S_INTERVAL=5"
echo %S_TOTAL%| findstr /r "^[0-9][0-9]*$" >nul || set "S_TOTAL=600"
set "SOAK_ROUNDS=%S_ROUNDS%"
set "SOAK_INTERVAL=%S_INTERVAL%"
set "SOAK_MAX_TOTAL_SECONDS=%S_TOTAL%"
echo [信息] soak 参数：轮次=%SOAK_ROUNDS%  间隔=%SOAK_INTERVAL%s  总时长上限=%SOAK_MAX_TOTAL_SECONDS%s
echo.

rem ---- 2c. 网络代理（构建需访问 GitHub/PyPI；环境变量已预置则跳过提问）------------
rem  “任意电脑可运行”的关键：不同机器代理地址不同（Docker Desktop 用
rem  host.docker.internal；Linux Docker 用宿主机 IP；无代理直接回车）。只作为
rem  build-arg 传给 docker build（不设客户端 env，避免 Docker Desktop 改写代理）。
if defined PROXY_ADDR (
    echo [信息] 检测到预置代理：%PROXY_ADDR%
) else (
    echo 网络代理（构建需访问 GitHub/PyPI）：
    echo 本机 Clash 常用 http://127.0.0.1:7890（就是常见的 **** 端口，按你的实际填）。
    echo Docker Desktop 构建用 http://host.docker.internal:7890；Linux Docker 用宿主机 IP（如 192.168.x.x:7890）。
    echo 你的网络能直连 GitHub 请直接回车；需 Clash/代理则填地址。
    set /p PROXY_ADDR=代理地址（回车=不使用代理）：
)
if not defined PROXY_ADDR (
    echo [信息] 不使用代理构建（直连；若构建卡在 GitHub 说明需要代理，重跑选代理）
) else (
    echo [信息] 使用代理构建：%PROXY_ADDR%
)
echo.

rem ---- 3. 构建镜像 -----------------------------------------------------------
set "IMAGE=hermes-version-compat:%VERSION%"
set "EXTRA_ARGS="
if defined PROXY_ADDR set "EXTRA_ARGS=%EXTRA_ARGS% --build-arg HTTP_PROXY=%PROXY_ADDR% --build-arg HTTPS_PROXY=%PROXY_ADDR%"
if defined NO_PROXY     set "EXTRA_ARGS=%EXTRA_ARGS% --build-arg NO_PROXY=%NO_PROXY%"
echo [信息] 开始构建镜像 %IMAGE% ...
docker build --build-arg HERMES_VERSION=%VERSION% %EXTRA_ARGS% -t %IMAGE% .
if errorlevel 1 (
    echo [错误] 镜像构建失败。
    if not defined NO_PAUSE pause
    exit /b 1
)
echo [信息] 镜像构建成功：%IMAGE% （构建期已断言镜像内 Hermes 版本 = %VERSION%）
echo.

rem ---- 4. 运行自动对话（soak）------------------------------------------------
set "RESULT_DIR=%~dp0results"
if not exist "%RESULT_DIR%" mkdir "%RESULT_DIR%"
echo [信息] 开始自动对话（soak），结果将写入 %RESULT_DIR%\result.json
echo [信息] 轮次：%SOAK_ROUNDS%  间隔：%SOAK_INTERVAL%s  总时长上限：%SOAK_MAX_TOTAL_SECONDS%s
echo.

set "MODEL_API_KEY=%APIKEY%"
set "SOAK_FLAGS="
if defined SOAK_ROUNDS            set "SOAK_FLAGS=%SOAK_FLAGS% -e SOAK_ROUNDS=%SOAK_ROUNDS%"
if defined SOAK_INTERVAL          set "SOAK_FLAGS=%SOAK_FLAGS% -e SOAK_INTERVAL=%SOAK_INTERVAL%"
if defined SOAK_MAX_TOTAL_SECONDS set "SOAK_FLAGS=%SOAK_FLAGS% -e SOAK_MAX_TOTAL_SECONDS=%SOAK_MAX_TOTAL_SECONDS%"
docker run --rm ^
  -e MODEL_API_KEY ^
  -e MODEL_BASE_URL=%BASEURL% ^
  -e MODEL_NAME=%MODELNAME% ^
  -e MODEL_PROVIDER=%PROVIDER% ^
  %SOAK_FLAGS% ^
  -v "%RESULT_DIR%:/results" ^
  %IMAGE%
set "RC=%ERRORLEVEL%"
set "MODEL_API_KEY="
set "APIKEY="

echo.
if "%RC%"=="0" (
    echo [结果] 检测通过：PASSED
) else (
    echo [结果] 检测失败：FAILED （退出码 %RC%）
)
echo [信息] 结果文件：%RESULT_DIR%\result.json
echo [信息] 敏感信息已清理：容器 --rm 已删除（内部含密钥的配置随容器销毁），密钥未写入任何文件，本窗口环境变量已清除。
echo.
if not defined NO_PAUSE pause
exit /b %RC%
