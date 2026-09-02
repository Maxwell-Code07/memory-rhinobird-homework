# Hermes Agent Docker 镜像

本目录中的 `Dockerfile` 使用 Debian 12 基础镜像 `node:22-bookworm-slim`，根据构建参数安装指定版本的 [Hermes Agent](https://github.com/NousResearch/hermes-agent)。

## 镜像内容

- Debian 12
- Node.js 22，构建时验证版本不低于 22.16.0
- Python 3.11 和 Hermes 核心运行依赖
- 从 Hermes 官方 Git 仓库浅克隆与输入版本严格匹配的标签源码

镜像只安装 Hermes 核心依赖，也安装TencentDB记忆插件。镜像设置了 `HERMES_DISABLE_LAZY_INSTALLS=1`，防止运行时自动安装可选插件。

## 构建镜像

`HERMES_VERSION` 没有默认值，必须使用 `--build-arg` 指定。版本格式必须为 `0.x.x`：

```powershell
docker build --progress=plain --build-arg HERMES_VERSION=0.20.6 -t hermes:0.20.6 .
```

保存完整构建日志：

```powershell
docker build --progress=plain --build-arg HERMES_VERSION=0.20.6 -t hermes:0.20.6 . 2>&1 |
  Tee-Object -FilePath .\docker-build-0.20.6.log
```

Hermes 的 GitHub 标签使用日期版本，例如 Hermes `0.20.6` 对应 `v2026.8.27`。Dockerfile 会读取官方 Git 标签，并检查各标签中 `pyproject.toml` 的版本来找到准确源码，不依赖 GitHub API 配额。不存在或不匹配的版本会让构建失败。

构建时需要能够访问 GitHub 和 Python 包索引。

## 查询版本

```powershell
docker run --rm hermes:0.20.6 --version
```

进一步验证 Node.js 与 Python 包版本：

```powershell
docker run --rm --entrypoint node hermes:0.20.6 --version
docker run --rm --entrypoint python hermes:0.20.6 -c "import importlib.metadata as m; print(m.version('hermes-agent'))"
```

## 启动 Hermes

镜像默认执行 `hermes --cli`。交互式启动：

```powershell
docker run --rm -it hermes:0.20.6
```

建议使用 Docker 数据卷保存配置、会话和其他运行数据：

```powershell
docker run --rm -it `
  -v hermes-data:/opt/data `
  hermes:0.20.6
```

如需使用 OpenAI 等模型提供商，通过环境变量或进入 Hermes 配置流程提供凭据，不要把密钥写进 Dockerfile：

```powershell
docker run --rm -it `
  -v hermes-data:/opt/data `
  -e OPENAI_API_KEY=$env:OPENAI_API_KEY `
  hermes:0.20.6
```

## 启动状态验收

使用 TTY 在后台启动 Hermes：

```powershell
docker run --name hermes-smoke -dit hermes:0.20.6
docker top hermes-smoke
docker logs --tail 100 hermes-smoke
docker stop hermes-smoke
docker rm hermes-smoke
```

## 负向测试

未传版本号时构建必须失败：

```powershell
docker build --progress=plain -t hermes:missing-version .
```

不存在的版本也必须失败并显示明确错误：

```powershell
docker build --progress=plain --build-arg HERMES_VERSION=0.999.999 -t hermes:invalid .
```
