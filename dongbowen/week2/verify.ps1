# Hermes 镜像验证脚本
# 用法: .\verify.ps1  （构建完成后跑一遍，确认镜像没问题）
$ErrorActionPreference = "Stop"

Write-Host "========== 1. 镜像列表 ==========" -ForegroundColor Cyan
docker images hermes:0.20.5
if ($LASTEXITCODE -ne 0) { Write-Host "镜像不存在!" -ForegroundColor Red; exit 1 }

Write-Host "`n========== 2. 版本验证（容器内 hermes --version）==========" -ForegroundColor Cyan
docker run --rm hermes:0.20.5 hermes --version
if ($LASTEXITCODE -ne 0) { Write-Host "版本验证失败!" -ForegroundColor Red; exit 1 }

Write-Host "`n========== 3. 容器启动验证 ==========" -ForegroundColor Cyan
docker run -it --rm hermes:0.20.5 bash -c "echo '[容器启动成功]'; hermes --version"
if ($LASTEXITCODE -ne 0) { Write-Host "容器启动失败!" -ForegroundColor Red; exit 1 }

Write-Host "`n========== 全部通过 ==========" -ForegroundColor Green
