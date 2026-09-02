#!/usr/bin/env node
/**
 * soak.mjs — Week3 基础要求：Hermes soak 自动对话脚本（零依赖，只需 Node.js）
 *
 * 通过 `hermes -z "<prompt>"` 单轮模式驱动 Hermes 一轮接一轮地自动对话，
 * 结束后输出结构化 JSON 判定（明确 pass / fail，含轮次与耗时统计）。
 *
 * 满足四条硬要求：
 *   1. 可配置参数：--rounds 对话轮次 / --interval 对话间隔 / --max-total-seconds 总对话时间
 *   2. 结构化结果：stdout 输出 JSON 判定；同时落盘 result.json + report.txt + conversation.jsonl
 *   3. 自动持续对话：无需人工干预，逐轮发送剧本（或固定提示词），循环往复
 *   4. 异常容错：单轮超时 kill、非零退出码、空响应、报错回复识别（HTTP 401 等）、
 *      连续失败熔断、总时长到点截断、Ctrl+C / SIGTERM 中断时仍输出已跑部分的结果
 *
 * 用法示例：
 *   node soak.mjs --hermes hermes --conversation conversation-chat.txt --rounds 10
 *   node soak.mjs --hermes hermes --prompt "Hi!" --rounds 5 --interval 2
 *   node soak.mjs --hermes hermes --conversation /opt/soak/conversation-facts.txt \
 *       --rounds 12 --interval 5 --max-total-seconds 1200 --out-dir /opt/soak/out
 *
 * 退出码：0=通过  1=失败  2=参数错误  130=SIGINT 中断  143=SIGTERM 中断
 */
import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

const TOOL = "hermes-soak";
const TOOL_VERSION = "1.0.0";

// 单条模式（未传 --conversation）时的默认提示词：一句友好问候，并明确禁止
// Hermes 使用工具 / 搜索 / 创建或执行文件与任务，只验证"能不能正常对话"。
const DEFAULT_PROMPT =
  "Hi Hermes! Just a friendly hello. Please reply with one short, natural sentence. " +
  "Do not use any tools, do not search or browse, do not create, edit, or run any file or task, " +
  "and do not offer to help with anything.";

const USAGE = `Usage: node soak.mjs [options]

选项：
  --hermes <path>                  Hermes 可执行文件（默认 "hermes"）
  --rounds <n>                     对话总轮次（默认 10）
  --interval <seconds>             相邻两轮之间的间隔秒数（默认 5）
  --max-total-seconds <n>          总对话时长上限（秒），到点即止（默认 600）
  --per-round-timeout-ms <n>       单轮超时（毫秒），超时 kill 并记失败（默认 240000）
  --max-consecutive-failures <n>   连续失败 N 轮后熔断终止（默认 3）
  --prompt <text>                  单条模式：每轮发送同一句固定提示词
  --conversation <path>            多轮剧本：一行一句，每轮发下一句；轮数多于句数则循环
  --expected-version <v>           期望的 Hermes 版本（如 v2026.8.27），不符则整体判 fail
  --out-dir <path>                 结果输出目录（默认 ./soak-out），生成：
                                      conversation.jsonl   逐轮对话记录（每轮一行 JSON）
                                      result.json          最终结构化判定
                                      report.txt           人类可读报告
  -h, --help                       显示本帮助

退出码：0=通过  1=失败  2=参数错误  130/143=被中断
`;

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------
const log = (msg) => process.stderr.write(`[soak] ${msg}\n`);

let interrupted = null;
process.on("SIGINT", () => { interrupted = "SIGINT"; });
process.on("SIGTERM", () => { interrupted = "SIGTERM"; });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Windows 下 .cmd/.bat 不能被 spawn 直接执行，需经 cmd.exe 转发（Linux 下不生效） */
function buildSpawnSpec(bin, args) {
  const useShell = process.platform === "win32" && /\.(cmd|bat)$/i.test(bin);
  if (!useShell) return { command: bin, args, shell: false };
  const quote = (x) => `"${String(x).replace(/"/g, '""')}"`;
  return { command: [bin, ...args].map(quote).join(" "), args: [], shell: true };
}

/** 识别"退出码 0 但输出其实是报错文本"的假成功（如 HTTP 401: not authorized） */
const ERROR_REPLY_RE = new RegExp(
  [
    "HTTP\\s+[45]\\d{2}",                                  // HTTP 401 / 500 ...
    "status[ :]?[45]\\d{2}",
    "\\b(401|403|404|429|500|502|503|504)\\b",
    "unauthorized|not authorized|invalid(\\s|_)?api[\\s_-]*key",
    "api[\\s_-]*key.*(invalid|incorrect|missing)",
    "rate[\\s_-]*limit|quota",
    "connection\\s+(refused|reset|timed?\\s*out|error)",
    "failed\\s+to\\s+(connect|fetch|resolve)",
    "internal\\s+server\\s+error",
    "traceback|exception:",
  ].join("|"),
  "i",
);

function percentile(sortedValues, p) {
  if (!sortedValues.length) return null;
  const idx = Math.min(sortedValues.length - 1, Math.ceil(sortedValues.length * p) - 1);
  return sortedValues[idx];
}

function loadConversation(path) {
  const text = readFileSync(path, "utf8");
  const turns = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (!turns.length) throw new Error(`剧本文件 "${path}" 中没有非空行`);
  return turns;
}

// ---------------------------------------------------------------------------
// 参数解析
// ---------------------------------------------------------------------------
function parseCli() {
  let parsed;
  try {
    parsed = parseArgs({
      options: {
        hermes: { type: "string", default: "hermes" },
        rounds: { type: "string", default: "10" },
        interval: { type: "string", default: "5" },
        "max-total-seconds": { type: "string", default: "600" },
        "per-round-timeout-ms": { type: "string", default: "240000" },
        "max-consecutive-failures": { type: "string", default: "3" },
        prompt: { type: "string", default: DEFAULT_PROMPT },
        conversation: { type: "string" },
        "expected-version": { type: "string" },
        "out-dir": { type: "string", default: "soak-out" },
        help: { type: "boolean", default: false },
      },
      allowPositionals: false,
    });
  } catch (err) {
    console.error(`[soak] 参数错误：${err.message}\n\n${USAGE}`);
    process.exit(2);
  }
  if (parsed.values.help) {
    console.log(USAGE);
    process.exit(0);
  }

  const int = (raw, name, min) => {
    const n = Number.parseInt(String(raw), 10);
    if (!Number.isFinite(n) || n < min) {
      console.error(`[soak] 参数错误：--${name} 的值 "${raw}" 必须是 >= ${min} 的整数\n\n${USAGE}`);
      process.exit(2);
    }
    return n;
  };

  const v = parsed.values;
  return {
    hermes: v.hermes,
    rounds: int(v.rounds, "rounds", 1),
    intervalSeconds: int(v.interval, "interval", 0),
    maxTotalSeconds: int(v["max-total-seconds"], "max-total-seconds", 1),
    perRoundTimeoutMs: int(v["per-round-timeout-ms"], "per-round-timeout-ms", 1000),
    maxConsecutiveFailures: int(v["max-consecutive-failures"], "max-consecutive-failures", 1),
    prompt: v.prompt,
    conversationFile: v.conversation ?? null,
    expectedVersion: v["expected-version"] ?? null,
    outDir: v["out-dir"],
  };
}

// ---------------------------------------------------------------------------
// 子进程执行
// ---------------------------------------------------------------------------

/** 跑一条命令并捕获输出；返回 { code, stdout, stderr, durationMs, spawnError, timedOut } */
function runCapture(bin, args, timeoutMs) {
  return new Promise((resolve) => {
    const started = Date.now();
    const spec = buildSpawnSpec(bin, args);
    const child = spawn(spec.command, spec.args, { stdio: ["ignore", "pipe", "pipe"], shell: spec.shell });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
    }, timeoutMs);
    child.stdout?.on("data", (d) => { stdout += d; });
    child.stderr?.on("data", (d) => { stderr += d; });
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ code: null, stdout, stderr, durationMs: Date.now() - started, spawnError: err.message, timedOut: false });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, durationMs: Date.now() - started, spawnError: null, timedOut });
    });
  });
}

/** 执行一轮对话：`hermes -z "<prompt>"`；返回带 ok 判定的结果 */
function runRound(hermes, prompt, timeoutMs) {
  return new Promise((resolve) => {
    const started = Date.now();
    const spec = buildSpawnSpec(hermes, ["-z", prompt]);
    const child = spawn(spec.command, spec.args, { stdio: ["ignore", "pipe", "pipe"], shell: spec.shell });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
    }, timeoutMs);
    child.stdout?.on("data", (d) => { stdout += d; });
    child.stderr?.on("data", (d) => { stderr += d; });
    const finish = (result) => { clearTimeout(timer); resolve(result); };
    child.on("error", (err) => finish({
      ok: false, exitCode: null, durationMs: Date.now() - started, timedOut: false,
      error: `无法启动 hermes：${err.message}`, stdout, stderr,
    }));
    child.on("close", (code) => {
      const durationMs = Date.now() - started;
      const reply = stdout.trim();
      if (timedOut) {
        return finish({ ok: false, exitCode: code, durationMs, timedOut: true,
          error: `单轮超时（超过 ${timeoutMs}ms 无响应），已强制终止`, stdout, stderr });
      }
      if (code !== 0) {
        return finish({ ok: false, exitCode: code, durationMs, timedOut: false,
          error: `hermes 退出码 ${code}`, stdout, stderr });
      }
      if (!reply) {
        return finish({ ok: false, exitCode: 0, durationMs, timedOut: false,
          error: "hermes 退出码 0 但输出为空（无响应）", stdout, stderr });
      }
      if (ERROR_REPLY_RE.test(reply)) {
        return finish({ ok: false, exitCode: 0, durationMs, timedOut: false,
          error: `回复疑似报错文本：${reply.slice(0, 120)}`, stdout, stderr });
      }
      finish({ ok: true, exitCode: 0, durationMs, timedOut: false, error: null, stdout, stderr });
    });
  });
}

/**
 * 从 `hermes --version` 输出解析括号里的日期式版本号，
 * 如 "Hermes Agent v0.20.6 (2026.8.27)" → "2026.8.27"。
 */
function parseReleaseDate(raw) {
  const m = String(raw ?? "").match(/\((\d{4}\.\d+(?:\.\d+)*)\)/);
  return m ? m[1] : null;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
async function main() {
  const cfg = parseCli();
  const startedAt = new Date();

  let turns = [];
  if (cfg.conversationFile) {
    try {
      turns = loadConversation(cfg.conversationFile);
    } catch (err) {
      console.error(`[soak] 剧本读取失败：${err.message}\n`);
      process.exit(2);
    }
  }

  mkdirSync(cfg.outDir, { recursive: true });
  const jsonlPath = join(cfg.outDir, "conversation.jsonl");
  writeFileSync(jsonlPath, ""); // 每次运行重新记录

  log(`${TOOL} v${TOOL_VERSION} 启动`);
  log(`配置：hermes=${cfg.hermes} rounds=${cfg.rounds} interval=${cfg.intervalSeconds}s ` +
      `max-total=${cfg.maxTotalSeconds}s per-round-timeout=${cfg.perRoundTimeoutMs}ms ` +
      `expected-version=${cfg.expectedVersion ?? "(不校验)"}`);
  if (turns.length) log(`剧本：${cfg.conversationFile}（${turns.length} 句，循环取用）`);

  // ---- 预检：版本探测与校验 -------------------------------------------------
  const vprobe = await runCapture(cfg.hermes, ["--version"], 60_000);
  const versionInfo = {
    raw: (vprobe.stdout + vprobe.stderr).trim() || null,
    release_date: null,
    expected: cfg.expectedVersion ? cfg.expectedVersion.replace(/^v/i, "") : null,
    verified: false,
    spawn_error: vprobe.spawnError ?? null,
  };
  if (vprobe.spawnError) {
    log(`警告：无法执行 ${cfg.hermes} --version（${vprobe.spawnError}）`);
  } else {
    versionInfo.release_date = parseReleaseDate(versionInfo.raw);
    if (versionInfo.expected && versionInfo.release_date === versionInfo.expected) {
      versionInfo.verified = true;
    }
    log(`Hermes 版本：${versionInfo.raw}`);
    if (versionInfo.expected) {
      log(versionInfo.verified
        ? `版本校验通过：${versionInfo.release_date} == ${versionInfo.expected}`
        : `版本不匹配：实际 ${versionInfo.release_date ?? "(解析失败)"} != 期望 ${versionInfo.expected}`);
    }
  }

  // ---- soak 循环 ------------------------------------------------------------
  const t0 = Date.now();
  const totalBudgetMs = cfg.maxTotalSeconds * 1000;
  const latencies = [];
  const failures = [];
  let executed = 0;
  let consecutiveFailures = 0;
  let terminationReason = "completed";

  for (let round = 1; round <= cfg.rounds; round++) {
    if (interrupted) {
      terminationReason = `interrupted_${interrupted}`;
      log(`收到 ${interrupted}，停止循环（已执行 ${executed} 轮）`);
      break;
    }
    if (Date.now() - t0 >= totalBudgetMs) {
      terminationReason = "max_total_seconds_reached";
      log(`总时长上限（${cfg.maxTotalSeconds}s）已到，停止循环（已执行 ${executed} 轮）`);
      break;
    }

    const prompt = turns.length ? turns[(round - 1) % turns.length] : cfg.prompt;
    log(`第 ${round}/${cfg.rounds} 轮：${prompt.slice(0, 40)}${prompt.length > 40 ? "…" : ""}`);
    executed++;

    const res = await runRound(cfg.hermes, prompt, cfg.perRoundTimeoutMs);
    latencies.push(res.durationMs);

    // 逐轮落盘 JSONL（即使中断，已跑的记录也不丢）
    appendFileSync(jsonlPath, JSON.stringify({
      round,
      ts: new Date().toISOString(),
      prompt,
      ok: res.ok,
      duration_ms: res.durationMs,
      exit_code: res.exitCode,
      error: res.error,
      reply: res.stdout.trim().slice(0, 2000),
    }) + "\n");

    if (res.ok) {
      consecutiveFailures = 0;
      log(`  ✓ 通过（${res.durationMs}ms）回复：${res.stdout.trim().slice(0, 60).replace(/\n/g, " ")}`);
    } else {
      consecutiveFailures++;
      failures.push({
        round,
        exit_code: res.exitCode,
        duration_ms: res.durationMs,
        error: res.error,
        stderr_tail: res.stderr.trim().slice(-400),
      });
      log(`  ✗ 失败（${res.durationMs}ms）${res.error}`);
      if (consecutiveFailures >= cfg.maxConsecutiveFailures) {
        terminationReason = "circuit_breaker";
        log(`连续失败 ${consecutiveFailures} 轮（上限 ${cfg.maxConsecutiveFailures}），熔断终止`);
        break;
      }
    }

    // 轮间等待（最后一轮不等；不超过剩余总预算）
    if (round < cfg.rounds && !interrupted) {
      const remaining = totalBudgetMs - (Date.now() - t0);
      const wait = Math.min(cfg.intervalSeconds * 1000, Math.max(0, remaining));
      if (wait > 0) await sleep(wait);
    }
  }

  // ---- 结构化判定 ------------------------------------------------------------
  const completedAt = new Date();
  const totalMs = Date.now() - t0;
  const sortedLat = [...latencies].sort((a, b) => a - b);
  const versionOk = !cfg.expectedVersion || versionInfo.verified;

  // 判定 pass 的条件：至少跑了 1 轮 && 所有已执行轮次全部成功 && 版本校验通过 && 正常跑完（未被截断/熔断/中断）
  const passed =
    executed >= 1 &&
    failures.length === 0 &&
    versionOk &&
    terminationReason === "completed";

  const verdict = {
    tool: TOOL,
    tool_version: TOOL_VERSION,
    passed,
    hermes_version: versionInfo,
    config: {
      hermes: cfg.hermes,
      rounds: cfg.rounds,
      interval_seconds: cfg.intervalSeconds,
      max_total_seconds: cfg.maxTotalSeconds,
      per_round_timeout_ms: cfg.perRoundTimeoutMs,
      max_consecutive_failures: cfg.maxConsecutiveFailures,
      prompt: turns.length ? null : cfg.prompt,
      conversation_file: cfg.conversationFile ?? null,
      conversation_turns: turns.length || null,
      expected_version: cfg.expectedVersion,
      out_dir: cfg.outDir,
    },
    rounds: {
      total: cfg.rounds,
      executed,
      passed: executed - failures.length,
      failed: failures.length,
    },
    stats: {
      total_duration_seconds: +(totalMs / 1000).toFixed(2),
      avg_round_ms: latencies.length ? Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length) : null,
      p50_round_ms: percentile(sortedLat, 0.50),
      p95_round_ms: percentile(sortedLat, 0.95),
      min_round_ms: latencies.length ? sortedLat[0] : null,
      max_round_ms: latencies.length ? sortedLat[sortedLat.length - 1] : null,
    },
    failures,
    termination_reason: terminationReason,
    started_at: startedAt.toISOString(),
    completed_at: completedAt.toISOString(),
  };

  const json = JSON.stringify(verdict, null, 2);

  // 落盘 result.json 与 report.txt
  try {
    writeFileSync(join(cfg.outDir, "result.json"), json + "\n", "utf8");
    writeFileSync(join(cfg.outDir, "report.txt"), renderReport(verdict), "utf8");
    log(`结果已写入 ${join(cfg.outDir, "result.json")} 与 report.txt`);
  } catch (err) {
    log(`警告：结果文件写入失败（${err.message}），JSON 仍会打印到 stdout`);
  }

  // stdout 只输出最终 JSON（供 docker logs / CI 消费）
  process.stdout.write(json + "\n");

  log(passed ? "RESULT: PASSED" : "RESULT: FAILED");
  if (interrupted === "SIGINT") process.exit(130);
  if (interrupted === "SIGTERM") process.exit(143);
  process.exit(passed ? 0 : 1);
}

/** 生成人类可读报告 */
function renderReport(v) {
  const lines = [];
  const bar = "=".repeat(60);
  lines.push(bar);
  lines.push(` ${TOOL} v${TOOL_VERSION} — Hermes Soak 测试报告`);
  lines.push(bar);
  lines.push(` 测试时间 : ${v.started_at}  →  ${v.completed_at}`);
  lines.push(` 总判定   : ${v.passed ? "PASS ✓" : "FAIL ✗"}（termination: ${v.termination_reason}）`);
  lines.push(` 版本     : ${v.hermes_version.raw ?? "(未知)"}` +
    (v.config.expected_version
      ? v.hermes_version.verified ? "  [版本校验通过]" : "  [版本不匹配/未校验]"
      : "  [未要求校验]"));
  lines.push("");
  lines.push(" 配置");
  lines.push(`   轮次/间隔/总时长 : ${v.config.rounds} 轮 / ${v.config.interval_seconds}s / 上限 ${v.config.max_total_seconds}s`);
  lines.push(`   剧本             : ${v.config.conversation_file ? `${v.config.conversation_file}（${v.config.conversation_turns} 句，循环）` : "固定单条 --prompt"}`);
  lines.push(`   单轮超时         : ${v.config.per_round_timeout_ms}ms；连续失败熔断：${v.config.max_consecutive_failures}`);
  lines.push("");
  lines.push(" 轮次结果");
  lines.push(`   执行 ${v.rounds.executed} / 计划 ${v.rounds.total}，通过 ${v.rounds.passed}，失败 ${v.rounds.failed}`);
  lines.push("");
  lines.push(" 耗时统计");
  lines.push(`   总耗时 ${v.stats.total_duration_seconds}s；` +
    `单轮 avg ${v.stats.avg_round_ms}ms / p50 ${v.stats.p50_round_ms}ms / p95 ${v.stats.p95_round_ms}ms / ` +
    `min ${v.stats.min_round_ms}ms / max ${v.stats.max_round_ms}ms`);
  lines.push("");
  lines.push(" 失败明细");
  if (!v.failures.length) {
    lines.push("   （无）");
  } else {
    for (const f of v.failures) {
      lines.push(`   #${f.round} 退出码 ${f.exit_code ?? "null"}，${f.duration_ms}ms：${f.error}`);
    }
  }
  lines.push(bar);
  return lines.join("\n") + "\n";
}

main().catch((err) => {
  console.error(`[soak] 致命错误：${err.stack || err}`);
  process.exit(1);
});
