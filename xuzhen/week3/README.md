# 第三周作业：Hermes soak 与记忆验证

本周交付按统一目录分为三层：

|目录|内容|状态|
|---|---|---|
|`1-basic-soak`|可配置轮次/间隔/总时长的自动对话脚本、JSONL 和 JSON 结果|必交，真实 30/30 PASS；错误 Key 5/5 FAIL 已验证|
|`2-memory-l0l3`|事实型对话剧本与 L0-L3/`/recall` 验证器|必交，L0-L3 非空且 `/recall` 成功|
|`3-full-pipeline`|build → run → 安装插件 → Gateway → soak 的一键流水线|选交，已独立全流程实测：30/30 PASS，L0–L3 均生成|

## 本次测试做了什么

本作业测试的是 Hermes 在真实模型调用下的稳定性，以及多轮对话能否由记忆插件沉淀为可召回的长期记忆。

1. **基础 soak**：脚本以 `hermes --oneshot` 自动发起独立请求，循环记录每轮结果。测试使用 30 轮真实对话，验证轮次、间隔、总时长三个参数，输出 JSONL、JSON 和文本报告，并统计 P50/P95 延迟。
2. **异常容错**：使用隔离的错误 API Key 执行 5 轮。每轮均被正确判为 FAIL，但脚本继续完成其余轮次并写出结构化结果，不会崩溃或假通过。
3. **记忆验证**：以包含身份、职业、偏好、习惯和约束的事实剧本驱动已安装记忆插件的 Hermes。每轮 LLM 请求独立，但共享同一个 Gateway 和记忆数据目录，因此对话会依次形成 L0 conversations、L1 records、L2 scene blocks 和 L3 persona.md，并通过 `/recall` 验证关键词召回。
4. **完整流水线（选交）**：`run_pipeline.py` 复用第二周 Dockerfile，根据 Hermes 版本构建干净镜像，在新容器运行时安装 Provider 和 Gateway，运行 30 条事实 soak，最后导出结果并自动检查 L0–L3。

## 最小验收

```bash
cd 1-basic-soak
python soak.py --rounds 3 --interval 1 --duration 60 --timeout 30 --output results
cat results/result.json
```

没有模型凭据时可用 `--dry-run` 验证循环和结果格式；错误命令/API Key 会输出 `FAIL`，但仍写完结果文件。真实 Hermes 调用使用 `hermes --oneshot`，也可以通过 `--hermes-command` 指向容器内的 `docker exec` 命令。

进阶目录中的插件安装命令、Provider、Gateway 和记忆目录因个人环境不同，均通过参数或 README 指定，不把密钥写入仓库。

## 统一环境变量

```bash
cp .env.example .env
# 在 .env 中填写同一个 OpenAI 兼容服务的密钥：
# OPENAI_API_KEY=...
# DEEPSEEK_API_KEY=... # DeepSeek 时与 OPENAI_API_KEY 填同一把 Key
# TDAI_LLM_API_KEY=...
```

启动第二周镜像时使用同一份文件，Hermes 和记忆 Gateway 会继承其中的配置：

```bash
docker run --name hermes-soak -dit --env-file .env hermes:0.20.6
```

其中 `TDAI_LLM_API_KEY` 供 TencentDB-Agent-Memory Gateway 的 L1-L3 抽取使用。若使用 DeepSeek，Hermes 读取 `DEEPSEEK_API_KEY`，它与 `OPENAI_API_KEY`、`TDAI_LLM_API_KEY` 都填同一服务的 Key；`DEEPSEEK_BASE_URL`、`HERMES_INFERENCE_PROVIDER` 和 `HERMES_INFERENCE_MODEL` 用于指定 Hermes 的 DeepSeek 调用。密钥只保存在本机 `.env`。

如果已经有 Hermes 的其他 `.env`，可让两者直接共用它：

```bash
python 1-basic-soak/soak.py --env-file /path/to/hermes/.env ...
python 3-full-pipeline/pipeline.py --env-file /path/to/hermes/.env ...
```

流水线会将指定文件作为 Docker `--env-file`，所以容器内 Hermes 和记忆 Gateway 读取的是同一份环境变量。

## 已验证结果

- 基础真实对话：[`1-basic-soak/evidence/real-pass-30/result.json`](1-basic-soak/evidence/real-pass-30/result.json)，30/30 PASS，包含 P50/P95 延迟。
- 基础异常容错：[`1-basic-soak/evidence/invalid-api-key-5rounds/result.json`](1-basic-soak/evidence/invalid-api-key-5rounds/result.json)，隔离无效 Key 后 5/5 FAIL，脚本仍完整输出结果。
- 进阶 1：[`2-memory-l0l3/evidence/memory-report-final.json`](2-memory-l0l3/evidence/memory-report-final.json)，L0-L3 和 `/recall` 均为 PASS。
- 进阶 2：[`3-full-pipeline/evidence/pass-30rounds-retry/soak-results/result.json`](3-full-pipeline/evidence/pass-30rounds-retry/soak-results/result.json) 为 30/30 PASS；[`3-full-pipeline/evidence/pass-30rounds-retry/memory-report.json`](3-full-pipeline/evidence/pass-30rounds-retry/memory-report.json) 确认新容器导出的 L0–L3 均存在。

## 各阶段说明

- [基础 soak：脚本、30/30 结果与错误 Key 容错](1-basic-soak/README.md)
- [进阶 1：L0-L3 与 recall](2-memory-l0l3/README.md)
- [进阶 2：完整流水线](3-full-pipeline/README.md)

## 验收截图

![基础 soak：30/30 PASS 与参数](assets/s1-basic-pass-and-config.png)

*图 1：真实 Hermes soak 完成 30/30 轮。截图显示轮次 30、轮间隔 1 秒、总时长 900 秒、成功 30、失败 0 以及 P50/P95 延迟。*

![错误 Key：5/5 FAIL](assets/s2-invalid-key.png)

*图 2：隔离错误 API Key 场景完成 5 轮，全部被判为 FAIL，脚本仍正常输出完整统计，证明异常容错有效。*

![L0 conversations 与 L1 records](assets/s3-l0-l1.png)

*图 3：L0 `conversations` 与 L1 `records` 目录均存在 JSONL 文件，证明原始对话和抽取出的事实均已落库。*

![L2 scene blocks 与 L3 persona](assets/s4-l2-l3.png)

*图 4：L2 已生成 scene block；L3 `persona.md` 已生成“小陈”“软件测试工程师”等用户画像内容。*

![recall 与四层总检](assets/s5-recall-and-memory-report.png)

*图 5：记忆总检为 PASS，L0–L3 均为 `present: true`；`/recall` 命中“小陈、Python、上海”，没有缺失关键词。*

![完整流水线：L0-L3 已导出验证](assets/s6-pipeline-30-pass.png)

*图 6：完整流水线的延迟统计和记忆检查结果。新容器完成 30/30 PASS，并自动导出、验证 L0 conversations、L1 records、L2 scene blocks、L3 persona.md。*
