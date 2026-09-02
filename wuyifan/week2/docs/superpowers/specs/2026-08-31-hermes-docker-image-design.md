# Hermes Docker 镜像设计说明

## 一、作业目标

构建一个干净的 Docker 镜像，镜像中安装用户指定的 Hermes Agent 版本。
该版本必须是已经发布到 PyPI 的版本。镜像不得包含 TencentDB 记忆插件，
也不得复制本作业仓库中的任何文件。

## 二、需求拆解

1. 通过 `ARG HERMES_VERSION` 接收 Hermes 版本号。
2. 安装的版本必须与输入版本完全一致；版本缺失或无效时应立即构建失败。
3. 使用 `node:22-bookworm-slim` 作为基础镜像，同时获得 Debian 12 和 Node.js 22。
4. Dockerfile 不使用 `COPY` 或 `ADD`。
5. 不安装 TencentDB 记忆插件。
6. 最终交付 `Dockerfile` 和 `README.md`。

## 三、版本来源和支持范围

Dockerfile 通过下面的精确版本要求，从 Python Package Index（PyPI）
安装 Hermes：

```text
hermes-agent==${HERMES_VERSION}
```

这种方式保证输入版本号能唯一对应到已发布的安装包，不会默认安装最新版。

本方案只支持已发布到 PyPI 的 Hermes 版本。设计时可用版本为 `0.13.0`
至 `0.19.0`，README 使用 `0.19.0` 作为示例。由于源码版 `0.20.4`
尚无对应的 PyPI 发布包或 Git tag，因此不在本次作业实现范围内。

## 四、镜像设计

- **基础镜像**：`node:22-bookworm-slim`。
- **系统依赖**：安装 `python3`、`python3-venv` 和 `ca-certificates`。
  Python 虚拟环境会初始化 pip，不需要污染系统 Python 环境。
- **Python 隔离**：在 `/opt/hermes-venv` 创建虚拟环境，并将它的
  `bin` 目录放到 `PATH` 最前面。
- **Hermes 安装**：使用 pip 安装与 `HERMES_VERSION` 完全一致的
  `hermes-agent` 包，并禁用 pip 下载缓存以减小镜像。
- **构建期验证**：读取已安装的 Python 包元数据，与 `HERMES_VERSION`
  比较；两者不一致时使构建失败。
- 
- **运行用户**：使用无特权的 `hermes` 用户运行程序，并为其提供
  可写的用户主目录。

## 五、构建数据流

```text
docker build --build-arg HERMES_VERSION=0.19.0
  → Docker 接收 ARG
  → pip 安装 hermes-agent==0.19.0
  → 构建阶段确认安装版本是 0.19.0
  → 生成标签为 hermes:0.19.0 的镜像
  → docker run hermes:0.19.0 --version
  → Hermes 输出 0.19.0
```

## 六、失败处理

- 未传入 `HERMES_VERSION`：构建应尽早失败，并显示明确提示。
- 传入未发布的版本：pip 安装失败，而不是偷偷改为最新版。
- 实际安装版本与输入不同：构建期断言失败。
- API Key 和模型配置不写入镜像，而是在容器运行时由用户提供。

## 七、验收设计

README 将给出命令，分别验证：

1. 传入 `HERMES_VERSION=0.19.0` 时能够成功构建。
2. 镜像内 `hermes --version` 输出与输入版本一致。
3. 镜像内 Node.js 版本不低于 `22.16.0`。
4. 容器能启动 Hermes 可执行程序。
5. 镜像内没有 TencentDB 记忆插件。
6. Dockerfile 中没有 `COPY` 或 `ADD` 指令。

## 八、交付物

- `Dockerfile`：定义可重复构建的 Hermes 镜像。
- `README.md`：面向初学者说明构建、运行、验收和常见问题，
  并明确说明 PyPI 版本支持范围。
