# 第二周验收证据：Hermes Dockerfile

以下内容保留本地终端的原始输出，命令在 `wuyue/week2` 目录执行。

## 1. 根据指定版本成功构建镜像

```text
user@userdeMacBook-Pro-2 week2 % cd /Users/user/Documents/Codex/2026-08-25/du/memory-rhinobird-homework/wuyue/week2
user@userdeMacBook-Pro-2 week2 % docker build --progress=plain \
  --build-arg HERMES_VERSION=2026.8.27 \
  -t hermes:2026.8.27 .
#0 building with "desktop-linux" instance using docker driver

#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 2.83kB done
#1 DONE 0.0s

#2 [internal] load metadata for public.ecr.aws/docker/library/node:22-bookworm-slim
#2 DONE 0.0s

#3 [internal] load .dockerignore
#3 transferring context: 2B done
#3 DONE 0.0s

#4 [1/4] FROM public.ecr.aws/docker/library/node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5
#4 resolve public.ecr.aws/docker/library/node:22-bookworm-slim@sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5 0.0s done
#4 DONE 0.0s

#5 [2/4] WORKDIR /opt
#5 CACHED

#6 [3/4] RUN test -n "2026.8.27" || (echo "HERMES_VERSION is required" >&2; exit 1) && ...
#6 CACHED

#7 [4/4] WORKDIR /opt/data
#7 CACHED

#8 exporting to image
#8 exporting layers done
#8 exporting manifest sha256:091a747b1a56490583cbcc37550897185b7bb0ae686df1bb500dafe6054286a2 done
#8 exporting config sha256:a1230695d19823f8eb83072fd1184390c5698b947d73859478931e614b3a5f0d done
#8 exporting attestation manifest sha256:a97da1c5af926376553c350cdbb709d4473568d13f02e0fba64519ca211b0115 done
#8 exporting manifest list sha256:e31f8692f70542d48ce03d8c29736b5091aa4da48548c8f9b31ef86d965d3294 done
#8 naming to docker.io/library/hermes:2026.8.27 done
#8 unpacking to docker.io/library/hermes:2026.8.27 done
#8 DONE 0.1s
```

构建结果：成功生成镜像 `hermes:2026.8.27`。

## 2. 容器内 Hermes 版本与输入版本一致

```text
user@userdeMacBook-Pro-2 week2 % docker run --rm hermes:2026.8.27 hermes --version
Hermes Agent v0.20.6 (2026.8.27)
Install directory: /opt/hermes-src
Install method: unknown
Python: 3.11.2
OpenAI SDK: 2.24.0
```

输入参数是 `HERMES_VERSION=2026.8.27`，版本输出中包含 `(2026.8.27)`，两者一致。

## 3. Node.js 版本验证

```text
user@userdeMacBook-Pro-2 week2 % docker run --rm hermes:2026.8.27 node --version
v22.23.2
```

Node.js `v22.23.2` ≥ 要求的 `22.16.0`。

## 4. Hermes 进程启动验证

```text
user@userdeMacBook-Pro-2 week2 % docker run --rm hermes:2026.8.27 hermes --help
usage: hermes [-h] [--version] [-z PROMPT] [--usage-file PATH] [-m MODEL]
              [--provider PROVIDER] [--reasoning LEVEL] [-t TOOLSETS]
              [--resume SESSION] [--no-restore-cwd] [--in DIR]
              [--continue [SESSION_NAME]] [--worktree] [--accept-hooks]
              [--skills SKILLS] [--yolo] [--pass-session-id]
              [--ignore-user-config] [--ignore-rules] [--safe-mode] [--tui]
              [--cli] [--dev]
              {chat,model,moa,fallback,worktree,browser,secrets,egress,migrate,gateway,proxy,lsp,setup,whatsapp,whatsapp-cloud,slack,send,login,logout,auth,status,pause,resume,cron,sync,webhook,peer,portal,kanban,project,hooks,doctor,verify,security,approvals,dump,debug,backup,checkpoints,import,import-agent,config,skin,console,pairing,skills,bundles,plugins,curator,pets,journey,learning,memory-graph,memory,tools,computer-use,mcp,sessions,insights,monitoring,claw,update,uninstall,acp,profile,completion,dashboard,serve,desktop,gui,logs,prompt-size}
              ...

Hermes Agent - AI assistant with tool-calling capabilities

positional arguments:
  {chat,model,moa,fallback,worktree,browser,secrets,egress,migrate,gateway,proxy,lsp,setup,whatsapp,whatsapp-cloud,slack,send,login,logout,auth,status,pause,resume,cron,sync,webhook,peer,portal,kanban,project,hooks,doctor,verify,security,approvals,dump,debug,backup,checkpoints,import,import-agent,config,skin,console,pairing,skills,bundles,plugins,curator,pets,journey,learning,memory-graph,memory,tools,computer-use,mcp,sessions,insights,monitoring,claw,update,uninstall,acp,profile,completion,dashboard,serve,desktop,gui,logs,prompt-size}
                        Command to run
    chat                Interactive chat with the agent
    model               Select default provider/model
    gateway             Run messaging gateway
    setup               Run setup wizard
    sessions            Manage session history
    memory              Configure external memory provider
    tools               Configure which tools are enabled per platform
    skills              Search, install, configure, and manage Hermes skills
```

帮助命令正常返回 Hermes CLI 内容，证明容器内 Hermes 进程可以启动。

## 作业要求核对

| 要求 | 结果 | 依据 |
|---|---|---|
| 版本号参数化 | 符合 | Dockerfile 声明 `ARG HERMES_VERSION`，构建命令使用 `--build-arg` |
| 干净镜像 | 符合 | 只安装 Hermes 运行所需依赖，未安装 TencentDB-Agent-Memory |
| 不 COPY 本仓库源码 | 符合 | Dockerfile 没有 `COPY` 作业仓库的指令，源码从上游按版本下载 |
| 预装 Node.js | 符合 | 基础镜像为 Node 22 Bookworm slim，实测 `v22.23.2` |
| Dockerfile 有使用说明 | 符合 | Dockerfile 顶部注释和 `README.md` 均给出构建、运行命令 |

