# 第 2 周作业 —— 交付物 A：Hermes 版本兼容检测 Dockerfile

## 项目说明

按传入的 Hermes 版本号，构建一个装好了那个版本 Hermes 的干净基线镜像：

- 预装 **Node.js 26 LTS**（Hermes 要求 ≥26；记忆插件 Gateway 要求 ≥22.16）
- 用官方 `install.sh --branch <tag>` 无头安装目标版本（非交互）
- **构建期版本断言**：装完跑 `hermes --version`，解析出的 release 日期必须等于 `HERMES_VERSION`
- **镜像启动自动跑自动对话**：`CMD` 跑 `entrypoint.sh` → 生成模型配置 → 跑 `soak.mjs`
```bash
# 构建（版本号用带 v 前缀的 git tag）
docker build --build-arg HERMES_VERSION=v2026.8.19 -t hermes-version-compat:v2026.8.19 .
```

## 跨周依赖（重要）

题目要求交付物 A"镜像启动后自动执行自动对话（交付物 B）"，所以 Dockerfile 里 COPY 了三个文件、并在启动时运行它们：

```
COPY soak.mjs /opt/hermes-version-compat/soak.mjs
COPY entrypoint.sh /opt/hermes-version-compat/entrypoint.sh
COPY conversation.jsonl /opt/hermes-version-compat/conversation.jsonl
CMD ["bash", "/opt/hermes-version-compat/entrypoint.sh"]
```

这三个文件属于**第 3 周交付物**，放在第 3 周作业文件夹里。所以：

- 只拿这一份 Dockerfile 单独放，`docker build` 会因为缺少 COPY 的文件而失败。这是题目"第 2 周只交 Dockerfile、但 Dockerfile 又要自动跑第 3 周 soak"带来的必然情况。
- 实际构建时，把第 3 周的 `soak.mjs`、`entrypoint.sh`、`conversation.jsonl` 放到与本 Dockerfile 同目录（或者直接在第 3 周文件夹里构建），然后：

  ```bash
  docker build --build-arg HERMES_VERSION=v2026.8.19 -t hermes-version-compat:v2026.8.19 .
  docker run --rm -e MODEL_API_KEY=.. -e MODEL_BASE_URL=.. -e MODEL_NAME=.. -e MODEL_PROVIDER=custom \
    -e SOAK_ROUNDS=14 hermes-version-compat:v2026.8.19
  ```

网络方面：国内打不开 GitHub 时要用代理（见第 3 周 README 的代理说明；构建时用 `--build-arg HTTP_PROXY/HTTPS_PROXY=<可达地址>`，Docker Desktop 用 `http://host.docker.internal:7890`）。

感谢老师评阅