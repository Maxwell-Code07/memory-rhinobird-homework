#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));

function formatTimestamp(date = new Date()) {
  return date
    .toISOString()
    .replaceAll(":", "")
    .replaceAll("-", "")
    .replace(/\.\d{3}Z$/, "Z");
}

function printUsage() {
  console.log(`
Hermes Soak Test

Usage:
  node hermes-soak.mjs [options]

Options:
  --rounds <N>                    最大对话轮数，默认 10
  --interval <ms>                 每轮之间的等待毫秒数，默认 1000
  --duration <sec>                最大运行秒数，默认 300
  --timeout <sec>                 单轮超时秒数，默认 120
  --max-consecutive-failures <N>  连续失败停止阈值，默认 3
  --prompts <path>                对话剧本路径
  --output <path>                 测试结果输出目录
  --hermes-command <path>         Hermes 命令或可执行文件路径
  --container <name>              通过 docker exec 调用容器内 Hermes
  --help, -h                      显示帮助信息
`);
}

function failArgument(message) {
  console.error(`参数错误：${message}`);
  process.exit(2);
}

function readPositiveInteger(rawValue, optionName) {
  const value = Number(rawValue);

  if (!Number.isInteger(value) || value <= 0) {
    failArgument(`${optionName} 必须是正整数`);
  }

  return value;
}

function readNonNegativeInteger(rawValue, optionName) {
  const value = Number(rawValue);

  if (!Number.isInteger(value) || value < 0) {
    failArgument(`${optionName} 必须是非负整数`);
  }

  return value;
}

function readPositiveNumber(rawValue, optionName) {
  const value = Number(rawValue);

  if (!Number.isFinite(value) || value <= 0) {
    failArgument(`${optionName} 必须是正数`);
  }

  return value;
}

function readRequiredValue(args, index, optionName) {
  const value = args[index + 1];

  if (!value || value.startsWith("--")) {
    failArgument(`${optionName} 必须提供一个值`);
  }

  return value;
}

function parseArgs(args) {
  const config = {
    rounds: 10,
    intervalMs: 1000,
    durationSeconds: 300,
    timeoutSeconds: 120,
    maxConsecutiveFailures: 3,
    promptsPath: path.join(SCRIPT_DIR, "prompts.json"),
    outputDir: path.join(
      SCRIPT_DIR,
      "results",
      `soak-${formatTimestamp()}-${process.pid}`
    ),
    hermesCommand: null,
    container: null
  };

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];

    switch (argument) {
      case "--help":
      case "-h":
        printUsage();
        process.exit(0);

      case "--rounds":
        config.rounds = readPositiveInteger(
          readRequiredValue(args, index, "--rounds"),
          "--rounds"
        );
        index += 1;
        break;

      case "--interval":
        config.intervalMs = readNonNegativeInteger(
          readRequiredValue(args, index, "--interval"),
          "--interval"
        );
        index += 1;
        break;

      case "--duration":
        config.durationSeconds = readPositiveNumber(
          readRequiredValue(args, index, "--duration"),
          "--duration"
        );
        index += 1;
        break;

      case "--timeout":
        config.timeoutSeconds = readPositiveNumber(
          readRequiredValue(args, index, "--timeout"),
          "--timeout"
        );
        index += 1;
        break;

      case "--max-consecutive-failures":
        config.maxConsecutiveFailures = readPositiveInteger(
          readRequiredValue(
            args,
            index,
            "--max-consecutive-failures"
          ),
          "--max-consecutive-failures"
        );
        index += 1;
        break;

      case "--prompts":
        config.promptsPath = path.resolve(
          readRequiredValue(args, index, "--prompts")
        );
        index += 1;
        break;

      case "--output":
        config.outputDir = path.resolve(
          readRequiredValue(args, index, "--output")
        );
        index += 1;
        break;

      case "--hermes-command":
        config.hermesCommand = readRequiredValue(
          args,
          index,
          "--hermes-command"
        );
        index += 1;
        break;

      case "--container":
        config.container = readRequiredValue(
          args,
          index,
          "--container"
        );
        index += 1;
        break;

      default:
        failArgument(`未知参数 ${argument}`);
    }
  }

  return config;
}

function loadPrompts(promptsPath) {
  if (!fs.existsSync(promptsPath)) {
    failArgument(`剧本文件不存在：${promptsPath}`);
  }

  let prompts;

  try {
    prompts = JSON.parse(
      fs.readFileSync(promptsPath, "utf8")
    );
  } catch (error) {
    failArgument(`剧本文件不是有效 JSON：${error.message}`);
  }

  if (!Array.isArray(prompts) || prompts.length === 0) {
    failArgument("剧本文件必须是非空 JSON 数组");
  }

  const invalidPrompt = prompts.find((item) => {
    return (
      typeof item?.id !== "string" ||
      item.id.trim() === "" ||
      typeof item?.prompt !== "string" ||
      item.prompt.trim() === ""
    );
  });

  if (invalidPrompt) {
    failArgument("每条剧本都必须包含非空的 id 和 prompt");
  }

  return prompts;
}

function extractSessionId(stderr) {
  const match = stderr.match(/session_id:\s*([^\s]+)/i);
  return match?.[1] ?? null;
}

function runHermesRound({
  hermesCommand,
  container,
  prompt,
  sessionId,
  timeoutSeconds
}) {
  const command = container ? "docker" : hermesCommand;
  const args = container
    ? ["exec", container, "hermes", "chat", "-Q"]
    : ["chat", "-Q"];

  if (sessionId) {
    args.push("--resume", sessionId);
  }

  args.push("-q", prompt, "--source", "tool");

  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["ignore", "pipe", "pipe"]
    });

    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;

    const finish = (result) => {
      if (settled) {
        return;
      }

      settled = true;
      clearTimeout(timeoutTimer);
      resolve(result);
    };

    const timeoutTimer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");

      const forceKillTimer = setTimeout(() => {
        if (!settled) {
          child.kill("SIGKILL");
        }
      }, 1000);

      forceKillTimer.unref();
    }, timeoutSeconds * 1000);

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => {
      finish({
        exitCode: null,
        stdout,
        stderr,
        error,
        timedOut
      });
    });

    child.on("close", (exitCode) => {
      finish({
        exitCode,
        stdout,
        stderr,
        error: null,
        timedOut
      });
    });
  });
}

function determineErrorType(result, sessionId) {
  if (result.timedOut) {
    return "timeout";
  }

  if (result.error) {
    return "spawn_error";
  }

  if (result.exitCode !== 0) {
    return "nonzero_exit";
  }

  if (result.stdout.trim() === "") {
    return "empty_response";
  }

  if (!sessionId) {
    return "missing_session_id";
  }

  return null;
}

function sleep(milliseconds) {
  return new Promise((resolve) => {
    setTimeout(resolve, milliseconds);
  });
}

function percentile(values, percentage) {
  if (values.length === 0) {
    return null;
  }

  const sorted = [...values].sort((left, right) => {
    return left - right;
  });

  const index = Math.max(
    0,
    Math.ceil((percentage / 100) * sorted.length) - 1
  );

  return sorted[index];
}

function calculateLatencyStats(roundResults) {
  const values = roundResults
    .filter((round) => round.status === "pass")
    .map((round) => round.latencyMs);

  if (values.length === 0) {
    return {
      min: null,
      mean: null,
      p50: null,
      p95: null,
      max: null
    };
  }

  const total = values.reduce((sum, value) => {
    return sum + value;
  }, 0);

  return {
    min: Math.min(...values),
    mean: Math.round(total / values.length),
    p50: percentile(values, 50),
    p95: percentile(values, 95),
    max: Math.max(...values)
  };
}

function appendJsonLine(filePath, value) {
  fs.appendFileSync(
    filePath,
    `${JSON.stringify(value)}\n`,
    "utf8"
  );
}

function buildReport(summary) {
  return [
    "Hermes Soak Test Report",
    "=======================",
    `Status: ${summary.status}`,
    `Stop reason: ${summary.stopReason}`,
    `Configured rounds: ${summary.configuredRounds}`,
    `Completed rounds: ${summary.completedRounds}`,
    `Successful rounds: ${summary.successfulRounds}`,
    `Failed rounds: ${summary.failedRounds}`,
    `Failure rate: ${(summary.failureRate * 100).toFixed(1)}%`,
    `Elapsed: ${summary.elapsedMs} ms`,
    `Session ID: ${summary.sessionId ?? "none"}`,
    `Latency min: ${summary.latencyMs.min ?? "n/a"} ms`,
    `Latency mean: ${summary.latencyMs.mean ?? "n/a"} ms`,
    `Latency P50: ${summary.latencyMs.p50 ?? "n/a"} ms`,
    `Latency P95: ${summary.latencyMs.p95 ?? "n/a"} ms`,
    `Latency max: ${summary.latencyMs.max ?? "n/a"} ms`,
    ""
  ].join("\n");
}

async function runSoak(config, prompts) {
  fs.mkdirSync(config.outputDir, {
    recursive: true
  });

  const conversationsPath = path.join(
    config.outputDir,
    "conversations.jsonl"
  );

  const summaryPath = path.join(
    config.outputDir,
    "summary.json"
  );

  const reportPath = path.join(
    config.outputDir,
    "report.txt"
  );

  fs.writeFileSync(conversationsPath, "", "utf8");

  const startedAtMs = Date.now();
  const startedAt = new Date(startedAtMs).toISOString();
  const durationMs = config.durationSeconds * 1000;

  let sessionId = null;
  let successCount = 0;
  let failureCount = 0;
  let consecutiveFailures = 0;
  let stopReason = "round_limit";

  const roundResults = [];

  for (
    let roundIndex = 0;
    roundIndex < config.rounds;
    roundIndex += 1
  ) {
    if (Date.now() - startedAtMs >= durationMs) {
      stopReason = "duration_limit";
      break;
    }

    const prompt = prompts[roundIndex % prompts.length];
    const roundStartedAtMs = Date.now();

    const result = await runHermesRound({
      hermesCommand: config.hermesCommand,
      container: config.container,
      prompt: prompt.prompt,
      sessionId,
      timeoutSeconds: config.timeoutSeconds
    });

    const roundEndedAtMs = Date.now();
    const latencyMs = roundEndedAtMs - roundStartedAtMs;

    if (!sessionId && result.exitCode === 0) {
      sessionId = extractSessionId(result.stderr);
    }

    const errorType = determineErrorType(
      result,
      sessionId
    );

    const passed = errorType === null;

    if (passed) {
      successCount += 1;
      consecutiveFailures = 0;

      console.log(
        `[round ${roundIndex + 1}/${config.rounds}] ` +
        `pass session_id=${sessionId}`
      );
    } else {
      failureCount += 1;
      consecutiveFailures += 1;

      console.log(
        `[round ${roundIndex + 1}/${config.rounds}] ` +
        `fail errorType=${errorType}`
      );

      if (result.error) {
        console.error(result.error.message);
      } else if (
        !result.timedOut &&
        result.stderr.trim() !== ""
      ) {
        console.error(result.stderr.trim());
      }
    }

    const roundRecord = {
      round: roundIndex + 1,
      promptId: prompt.id,
      prompt: prompt.prompt,
      response: result.stdout.trim(),
      status: passed ? "pass" : "fail",
      errorType,
      errorMessage: result.error?.message ?? null,
      exitCode: result.exitCode,
      latencyMs,
      sessionId,
      startedAt: new Date(roundStartedAtMs).toISOString(),
      endedAt: new Date(roundEndedAtMs).toISOString()
    };

    roundResults.push(roundRecord);
    appendJsonLine(conversationsPath, roundRecord);

    if (
      consecutiveFailures >=
      config.maxConsecutiveFailures
    ) {
      stopReason = "consecutive_failure_limit";
      break;
    }

    const hasNextRound =
      roundIndex + 1 < config.rounds;

    const durationReached =
      Date.now() - startedAtMs >= durationMs;

    if (
      hasNextRound &&
      !durationReached &&
      config.intervalMs > 0
    ) {
      await sleep(config.intervalMs);
    }
  }

  const endedAtMs = Date.now();
  const completedRounds = roundResults.length;

  const failureRate = completedRounds === 0
    ? 1
    : failureCount / completedRounds;

  const status =
    completedRounds > 0 &&
    successCount > 0 &&
    failureRate <= 0.2
      ? "pass"
      : "fail";

  const summary = {
    status,
    stopReason,
    configuredRounds: config.rounds,
    completedRounds,
    successfulRounds: successCount,
    failedRounds: failureCount,
    failureRate,
    maxConsecutiveFailures:
      config.maxConsecutiveFailures,
    startedAt,
    endedAt: new Date(endedAtMs).toISOString(),
    elapsedMs: endedAtMs - startedAtMs,
    sessionId,
    container: config.container,
    latencyMs: calculateLatencyStats(roundResults),
    outputDir: config.outputDir
  };

  fs.writeFileSync(
    summaryPath,
    `${JSON.stringify(summary, null, 2)}\n`,
    "utf8"
  );

  fs.writeFileSync(
    reportPath,
    buildReport(summary),
    "utf8"
  );

  console.log(`summary=${summaryPath}`);
  console.log(`report=${reportPath}`);

  return status === "pass" ? 0 : 1;
}

const config = parseArgs(process.argv.slice(2));
const prompts = loadPrompts(config.promptsPath);

if (config.hermesCommand || config.container) {
  process.exitCode = await runSoak(config, prompts);
}
