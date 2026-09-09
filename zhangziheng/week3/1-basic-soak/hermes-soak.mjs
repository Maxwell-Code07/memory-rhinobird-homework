#!/usr/bin/env node

import fs from "node:fs"
import fsp from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const MAX_CAPTURE_CHARS = 256_000

const DEFAULT_PROMPTS = [
  { label: "greeting", message: "你好！请用一句话介绍你能提供什么帮助。" },
  { label: "reasoning", message: "请计算 17 × 23，并简要说明计算过程。" },
  { label: "writing", message: "请把“持续测试能够提前发现稳定性问题”改写得更简洁。" },
  { label: "summary", message: "请用三个要点总结保持软件服务稳定的常见做法。" },
  { label: "context", message: "我们正在进行自动化稳定性测试。请确认你仍能正常回复。" },
]

function loadDotEnv(filePath) {
  if (!fs.existsSync(filePath)) return
  const content = fs.readFileSync(filePath, "utf8")
  for (const rawLine of content.split(/\r?\n/u)) {
    const line = rawLine.trim()
    if (!line || line.startsWith("#")) continue
    const separator = line.indexOf("=")
    if (separator < 1) continue
    const key = line.slice(0, separator).trim()
    let value = line.slice(separator + 1).trim()
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1)
    }
    if (process.env[key] === undefined) process.env[key] = value
  }
}

function usage() {
  console.log(`Hermes soak 自动对话脚本

用法：
  node hermes-soak.mjs [参数]

核心参数：
  --rounds <n>                 最大对话轮次（默认 20）
  --interval-ms <ms>           两轮开始之间的等待时间（默认 1000）
  --duration-minutes <min>     总对话时间上限，支持小数（默认 30）
  --request-timeout-ms <ms>    单轮超时时间（默认 120000）
  --output <dir>               输出目录（默认 workspace/run-时间戳）
  --prompts <file>             JSON/JSONL/纯文本 prompts 文件
  --session <id>               从已有 Hermes session ID 开始（默认新建并自动捕获）
  --model <name>               可选 Hermes 模型覆盖
  --provider <name>            可选 Hermes provider 覆盖
  --toolsets <names>           Hermes 工具集（默认 context_engine，即纯对话）

高级/测试参数：
  --command <path>             Hermes 可执行命令（默认 hermes）
  --command-arg <value>        命令前置参数，可重复传入
  --help                       显示帮助

配置优先级：命令行 > 环境变量 > 默认值。环境变量见 .env.example。`)
}

function parseArgs(argv) {
  const options = { commandArgs: [] }
  const valueOptions = new Map([
    ["--rounds", "rounds"],
    ["--interval-ms", "intervalMs"],
    ["--duration-minutes", "durationMinutes"],
    ["--request-timeout-ms", "requestTimeoutMs"],
    ["--output", "outputDir"],
    ["--prompts", "promptsFile"],
    ["--session", "session"],
    ["--model", "model"],
    ["--provider", "provider"],
    ["--toolsets", "toolsets"],
    ["--command", "command"],
  ])

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === "--help" || argument === "-h") {
      usage()
      process.exit(0)
    }
    if (argument === "--command-arg") {
      if (index + 1 >= argv.length) throw new Error("--command-arg 缺少参数值")
      options.commandArgs.push(argv[++index])
      continue
    }
    const key = valueOptions.get(argument)
    if (!key) throw new Error(`未知参数：${argument}（使用 --help 查看帮助）`)
    if (index + 1 >= argv.length) throw new Error(`${argument} 缺少参数值`)
    options[key] = argv[++index]
  }
  return options
}

function positiveNumber(value, name, { integer = false } = {}) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed <= 0 || (integer && !Number.isInteger(parsed))) {
    throw new Error(`${name} 必须是${integer ? "正整数" : "大于 0 的数字"}`)
  }
  return parsed
}

function nonNegativeNumber(value, name) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed < 0) throw new Error(`${name} 必须是大于等于 0 的数字`)
  return parsed
}

function timestampForPath(date = new Date()) {
  return date.toISOString().replace(/[-:]/gu, "").replace(/\.\d{3}Z$/u, "Z")
}

function resolveConfig(cli) {
  return {
    rounds: positiveNumber(cli.rounds ?? process.env.SOAK_ROUNDS ?? 20, "rounds", { integer: true }),
    intervalMs: nonNegativeNumber(cli.intervalMs ?? process.env.SOAK_INTERVAL_MS ?? 1000, "interval-ms"),
    durationMinutes: positiveNumber(
      cli.durationMinutes ?? process.env.SOAK_DURATION_MINUTES ?? 30,
      "duration-minutes",
    ),
    requestTimeoutMs: positiveNumber(
      cli.requestTimeoutMs ?? process.env.SOAK_REQUEST_TIMEOUT_MS ?? 120_000,
      "request-timeout-ms",
      { integer: true },
    ),
    outputDir: path.resolve(
      cli.outputDir ??
        process.env.SOAK_OUTPUT_DIR ??
        path.join(SCRIPT_DIR, "workspace", `run-${timestampForPath()}`),
    ),
    promptsFile: cli.promptsFile ?? process.env.SOAK_PROMPTS_FILE ?? "",
    session: cli.session ?? process.env.SOAK_SESSION ?? "",
    model: cli.model ?? process.env.SOAK_MODEL ?? "",
    provider: cli.provider ?? process.env.SOAK_PROVIDER ?? "",
    toolsets: cli.toolsets ?? process.env.SOAK_TOOLSETS ?? "context_engine",
    command: cli.command ?? process.env.SOAK_HERMES_COMMAND ?? "hermes",
    commandArgs: cli.commandArgs,
  }
}

function normalizePrompt(item, index) {
  if (typeof item === "string" && item.trim()) {
    return { label: `prompt-${index + 1}`, message: item.trim() }
  }
  if (item && typeof item === "object" && typeof item.message === "string" && item.message.trim()) {
    return {
      label: typeof item.label === "string" && item.label.trim() ? item.label.trim() : `prompt-${index + 1}`,
      message: item.message.trim(),
    }
  }
  throw new Error(`prompts 中第 ${index + 1} 项无效`)
}

async function loadPrompts(filePath) {
  if (!filePath) return DEFAULT_PROMPTS
  const resolved = path.resolve(filePath)
  const content = await fsp.readFile(resolved, "utf8")
  let items
  if (resolved.toLowerCase().endsWith(".json")) {
    items = JSON.parse(content)
    if (!Array.isArray(items)) throw new Error("JSON prompts 文件顶层必须是数组")
  } else if (resolved.toLowerCase().endsWith(".jsonl")) {
    items = content
      .split(/\r?\n/u)
      .filter((line) => line.trim())
      .map((line) => JSON.parse(line))
  } else {
    items = content.split(/\r?\n/u).filter((line) => line.trim() && !line.trim().startsWith("#"))
  }
  if (items.length === 0) throw new Error("prompts 文件中没有可用对话")
  return items.map(normalizePrompt)
}

function appendLimited(current, chunk) {
  if (current.length >= MAX_CAPTURE_CHARS) return current
  return (current + chunk).slice(0, MAX_CAPTURE_CHARS)
}

function extractSessionId(text) {
  const machineReadable = text.match(/^\s*session_id:\s*([^\s]+)\s*$/imu)
  if (machineReadable) return machineReadable[1]
  const displayStyle = text.match(/Session ID:\s*`?([A-Za-z0-9._-]+)`?/iu)
  return displayStyle?.[1] ?? null
}

function runHermesRound(config, prompt, timeoutMs, resumeSessionId, setActiveChild) {
  const hermesArgs = [
    ...config.commandArgs,
    "chat",
    "--quiet",
    "--source",
    "tool",
    "-q",
    prompt,
  ]
  if (resumeSessionId) hermesArgs.push("--resume", resumeSessionId)
  if (config.toolsets) hermesArgs.push("--toolsets", config.toolsets)
  if (config.model) hermesArgs.push("--model", config.model)
  if (config.provider) hermesArgs.push("--provider", config.provider)

  return new Promise((resolve) => {
    const startedAt = Date.now()
    let stdout = ""
    let stderr = ""
    let settled = false
    let didTimeout = false
    let child

    const finish = (result) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      setActiveChild(null)
      resolve({
        ...result,
        stdout: stdout.trim(),
        stderr: stderr.trim(),
        sessionId: extractSessionId(`${stderr}\n${stdout}`),
        durationMs: Date.now() - startedAt,
      })
    }

    try {
      child = spawn(config.command, hermesArgs, {
        env: process.env,
        stdio: ["pipe", "pipe", "pipe"],
        windowsHide: true,
      })
      setActiveChild(child)
    } catch (error) {
      resolve({ ok: false, errorType: "spawn_error", errorMessage: error.message, stdout, stderr, durationMs: 0 })
      return
    }

    const timer = setTimeout(() => {
      didTimeout = true
      child.kill("SIGTERM")
      setTimeout(() => {
        if (!settled) child.kill("SIGKILL")
      }, 1500).unref()
    }, timeoutMs)

    child.stdout.on("data", (chunk) => {
      stdout = appendLimited(stdout, chunk.toString("utf8"))
    })
    child.stderr.on("data", (chunk) => {
      stderr = appendLimited(stderr, chunk.toString("utf8"))
    })
    child.on("error", (error) => {
      finish({ ok: false, errorType: "spawn_error", errorMessage: error.message, exitCode: null, signal: null })
    })
    child.on("close", (exitCode, signal) => {
      if (didTimeout) {
        finish({
          ok: false,
          errorType: "timeout",
          errorMessage: `Hermes 单轮超过 ${timeoutMs} ms`,
          exitCode,
          signal,
        })
        return
      }
      if (exitCode !== 0) {
        const processOutput = [stderr.trim(), stdout.trim()].filter(Boolean).join("\n")
        finish({
          ok: false,
          errorType: "nonzero_exit",
          errorMessage: processOutput || `Hermes 退出码为 ${exitCode}`,
          exitCode,
          signal,
        })
        return
      }
      if (!stdout.trim()) {
        finish({
          ok: false,
          errorType: "empty_response",
          errorMessage: "Hermes 没有返回有效文本",
          exitCode,
          signal,
        })
        return
      }
      finish({ ok: true, errorType: null, errorMessage: null, exitCode, signal })
    })

    child.stdin.end()
  })
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function percentile(sortedValues, percentileValue) {
  if (sortedValues.length === 0) return null
  const index = Math.max(0, Math.ceil((percentileValue / 100) * sortedValues.length) - 1)
  return sortedValues[index]
}

function summarize(results, config, startedAt, finishedAt, completionReason) {
  const successes = results.filter((result) => result.status === "pass")
  const failures = results.filter((result) => result.status === "fail")
  const latencies = successes.map((result) => result.durationMs).sort((a, b) => a - b)
  const errors = {}
  for (const result of failures) {
    const key = result.error?.type ?? "unknown"
    errors[key] = (errors[key] ?? 0) + 1
  }
  const passed = results.length > 0 && failures.length === 0 && completionReason !== "interrupted"
  return {
    schemaVersion: 1,
    test: "hermes-basic-soak",
    status: passed ? "pass" : "fail",
    completionReason,
    startedAt: new Date(startedAt).toISOString(),
    finishedAt: new Date(finishedAt).toISOString(),
    elapsedMs: finishedAt - startedAt,
    config: {
      rounds: config.rounds,
      intervalMs: config.intervalMs,
      durationMinutes: config.durationMinutes,
      requestTimeoutMs: config.requestTimeoutMs,
      initialSessionId: config.session || null,
      model: config.model || null,
      provider: config.provider || null,
      toolsets: config.toolsets || null,
      promptsFile: config.promptsFile ? path.resolve(config.promptsFile) : null,
      command: config.command,
    },
    statistics: {
      attemptedRounds: results.length,
      successfulRounds: successes.length,
      failedRounds: failures.length,
      successRate: results.length === 0 ? 0 : Number((successes.length / results.length).toFixed(4)),
      latencyMs: {
        min: latencies.length ? latencies[0] : null,
        mean: latencies.length
          ? Math.round(latencies.reduce((sum, value) => sum + value, 0) / latencies.length)
          : null,
        p50: percentile(latencies, 50),
        p95: percentile(latencies, 95),
        max: latencies.length ? latencies.at(-1) : null,
      },
      errors,
    },
  }
}

async function main() {
  loadDotEnv(path.join(SCRIPT_DIR, ".env"))
  const cli = parseArgs(process.argv.slice(2))
  const config = resolveConfig(cli)
  const prompts = await loadPrompts(config.promptsFile)
  await fsp.mkdir(config.outputDir, { recursive: true })

  const conversationsPath = path.join(config.outputDir, "conversations.jsonl")
  const metaPath = path.join(config.outputDir, "meta.json")
  const results = []
  const startedAt = Date.now()
  const deadline = startedAt + config.durationMinutes * 60_000
  let interrupted = false
  let activeChild = null

  const requestStop = () => {
    interrupted = true
    if (activeChild) activeChild.kill("SIGTERM")
  }
  process.once("SIGINT", requestStop)
  process.once("SIGTERM", requestStop)

  console.log("Hermes basic soak started")
  console.log(`rounds=${config.rounds} intervalMs=${config.intervalMs} durationMinutes=${config.durationMinutes}`)
  console.log(`initialSessionId=${config.session || "(create automatically)"}`)
  console.log(`toolsets=${config.toolsets || "(Hermes default)"}`)
  console.log(`output=${config.outputDir}`)

  let currentSessionId = config.session || null
  for (let round = 1; round <= config.rounds && !interrupted; round += 1) {
    const now = Date.now()
    if (now >= deadline) break
    const prompt = prompts[(round - 1) % prompts.length]
    const timeoutMs = Math.max(1, Math.min(config.requestTimeoutMs, deadline - now))
    const roundStartedAt = new Date().toISOString()
    const execution = await runHermesRound(config, prompt.message, timeoutMs, currentSessionId, (child) => {
      activeChild = child
    })
    // If the global duration—not the per-request timeout—ended this in-flight
    // round, it is a normal stop condition rather than a Hermes failure. The
    // incomplete round is intentionally not counted as an attempted dialogue.
    if (
      !execution.ok &&
      execution.errorType === "timeout" &&
      timeoutMs < config.requestTimeoutMs &&
      Date.now() >= deadline
    ) {
      break
    }
    if (execution.ok && !execution.sessionId) {
      execution.ok = false
      execution.errorType = "session_id_missing"
      execution.errorMessage = "Hermes 回复成功，但未输出 session ID，无法保证下一轮连续对话"
    }
    if (execution.ok) currentSessionId = execution.sessionId
    const result = {
      round,
      label: prompt.label,
      startedAt: roundStartedAt,
      finishedAt: new Date().toISOString(),
      durationMs: execution.durationMs,
      status: execution.ok ? "pass" : "fail",
      prompt: prompt.message,
      response: execution.stdout,
      stderr: execution.stderr || null,
      exitCode: execution.exitCode ?? null,
      signal: execution.signal ?? null,
      sessionId: execution.sessionId,
      error: execution.ok
        ? null
        : { type: execution.errorType, message: execution.errorMessage },
    }
    results.push(result)
    await fsp.appendFile(conversationsPath, `${JSON.stringify(result)}\n`, "utf8")
    console.log(
      `[${round}/${config.rounds}] ${result.status.toUpperCase()} ${result.durationMs}ms ${prompt.label}` +
        (result.error ? ` (${result.error.type})` : ""),
    )

    if (round < config.rounds && !interrupted) {
      const remainingMs = deadline - Date.now()
      if (remainingMs <= 0) break
      await sleep(Math.min(config.intervalMs, remainingMs))
    }
  }

  const finishedAt = Date.now()
  const completionReason = interrupted
    ? "interrupted"
    : results.length >= config.rounds
      ? "max_rounds"
      : "max_duration"
  const meta = summarize(results, config, startedAt, finishedAt, completionReason)
  meta.finalSessionId = currentSessionId
  await fsp.writeFile(metaPath, `${JSON.stringify(meta, null, 2)}\n`, "utf8")

  console.log(JSON.stringify(meta, null, 2))
  console.log(`Result: ${meta.status.toUpperCase()} (${metaPath})`)
  process.exitCode = meta.status === "pass" ? 0 : 1
}

main().catch((error) => {
  console.error(`Fatal: ${error.stack ?? error.message}`)
  process.exitCode = 1
})
