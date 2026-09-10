#!/usr/bin/env node
/**
 * Hermes version-compat soak test driver (交付物 B)
 * ---------------------------------------------------
 * Continuously drives one-shot conversations against a Hermes install
 * (`hermes -z "<prompt>"`) and reports a structured JSON verdict:
 * passed / failed with per-round stats and failure details.
 *
 * Zero runtime dependencies — only Node.js built-ins.
 *
 * Exit codes:
 *   0   soak passed (all requested rounds completed successfully, version OK)
 *   1   soak failed (round failures, truncated/aborted run, version mismatch)
 *   2   invalid arguments
 *   130 interrupted by SIGINT
 *   143 interrupted by SIGTERM
 *
 * Human-readable progress goes to stderr; the final JSON verdict is the
 * only thing written to stdout (so `docker logs`/CI can consume it).
 */
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";

const TOOL = "hermes-version-compat-soak";
const TOOL_VERSION = "1.0.0";
// 单条模式（未传 --conversation）时的默认提示词：一句友好问候，并明确禁止 Hermes
// 使用工具 / 搜索 / 创建或执行任务 / 修改文件 / 主动帮忙，只验证它能正常对话。
// 注意：镜像默认走多轮剧本（conversation.jsonl），此提示词仅在 --prompt 单条模式下生效。
const DEFAULT_PROMPT =
  "Hello Hermes! Just saying a friendly hello. Reply with one short, natural sentence — a simple greeting, " +
  "nothing more. Do not use any tools, do not search or browse, do not create, edit, or run any task, project, " +
  "or file, and do not offer to help with anything.";

const USAGE = `Usage: node soak.mjs [options]

Options:
  --hermes <path>                 Hermes executable (default: "hermes")
  --rounds <n>                    Total conversation rounds (default: 10)
  --interval <seconds>            Wait between rounds (default: 5)
  --max-total-seconds <n>         Hard cap on total soak wall-clock time (default: 600)
  --per-round-timeout-ms <n>      Per-round timeout, kills hung rounds (default: 180000)
  --max-consecutive-failures <n>  Abort after N consecutive failures (default: 3)
  --prompt <text>                 Prompt sent each round (default: "${DEFAULT_PROMPT}")
  --conversation <path>           Multi-turn script: one user turn per non-empty line; each
                                  round sends the NEXT turn (cycles if rounds > turns). Enables
                                  a realistic dialogue that grows the 4-layer memory (L0-L3).
  --expected-version <v>          e.g. v2026.8.18 — verified via \`hermes --version\`;
                                  mismatch makes the overall verdict fail
  --result-file <path>            Also write the JSON verdict to this file
  --usage-dir <path>              Dir for per-round --usage-file JSON (default: OS tmp)
  -h, --help                      Show this help
`;

let interrupted = null;
process.on("SIGINT", () => { interrupted = "SIGINT"; });
process.on("SIGTERM", () => { interrupted = "SIGTERM"; });

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------
function parseIntArg(raw, name, { min = 0 } = {}) {
  const n = Number.parseInt(String(raw), 10);
  if (!Number.isFinite(n) || n < min) {
    throw new Error(`invalid --${name} value: "${raw}" (must be an integer >= ${min})`);
  }
  return n;
}

function parseArgsOrExit() {
  let parsed;
  try {
    parsed = parseArgs({
      options: {
        hermes: { type: "string", default: "hermes" },
        rounds: { type: "string", default: "10" },
        interval: { type: "string", default: "5" },
        "max-total-seconds": { type: "string", default: "600" },
        "per-round-timeout-ms": { type: "string", default: "180000" },
        "max-consecutive-failures": { type: "string", default: "3" },
        prompt: { type: "string", default: DEFAULT_PROMPT },
        "conversation": { type: "string" },
        "expected-version": { type: "string" },
        "result-file": { type: "string" },
        "usage-dir": { type: "string", default: tmpdir() },
        help: { type: "boolean", default: false },
      },
      allowPositionals: false,
    });
  } catch (err) {
    console.error(`[soak] argument error: ${err.message}\n\n${USAGE}`);
    process.exit(2);
  }
  if (parsed.values.help) {
    console.log(USAGE);
    process.exit(0);
  }
  try {
    return {
      hermes: parsed.values.hermes,
      rounds: parseIntArg(parsed.values.rounds, "rounds", { min: 1 }),
      interval: parseIntArg(parsed.values.interval, "interval"),
      maxTotalSeconds: parseIntArg(parsed.values["max-total-seconds"], "max-total-seconds", { min: 1 }),
      perRoundTimeoutMs: parseIntArg(parsed.values["per-round-timeout-ms"], "per-round-timeout-ms", { min: 1000 }),
      maxConsecutiveFailures: parseIntArg(parsed.values["max-consecutive-failures"], "max-consecutive-failures", { min: 1 }),
      prompt: parsed.values.prompt,
      conversationFile: parsed.values["conversation"] ?? null,
      expectedVersion: parsed.values["expected-version"] ?? null,
      resultFile: parsed.values["result-file"] ?? null,
      usageDir: parsed.values["usage-dir"],
    };
  } catch (err) {
    console.error(`[soak] argument error: ${err.message}\n\n${USAGE}`);
    process.exit(2);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const log = (msg) => process.stderr.write(`[soak] ${msg}\n`);

function normalizeVersion(v) {
  return String(v ?? "").trim().replace(/^v/i, "");
}

// .cmd/.bat cannot be spawned directly on Windows — run them through the
// shell with proper cmd.exe-style quoting (only used by the mock tests).
function buildSpawnSpec(bin, args) {
  const useShell = process.platform === "win32" && /\.(cmd|bat)$/i.test(bin);
  if (!useShell) return { command: bin, args, shell: false };
  const quote = (x) => `"${String(x).replace(/"/g, '""')}"`;
  return { command: [bin, ...args].map(quote).join(" "), args: [], shell: true };
}

/** Run a command, capture stdout/stderr, resolve {code, stdout, stderr, spawnError}. */
function runCapture(bin, args, timeoutMs) {
  return new Promise((resolve) => {
    const started = Date.now();
    const spec = buildSpawnSpec(bin, args);
    const child = spawn(spec.command, spec.args, {
      stdio: ["ignore", "pipe", "pipe"],
      shell: spec.shell,
    });
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
      resolve({ code: null, stdout, stderr, timedOut: false, durationMs: Date.now() - started, spawnError: err.message });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr, timedOut, durationMs: Date.now() - started, spawnError: null });
    });
  });
}

function detectHermesVersion(bin) {
  return runCapture(bin, ["--version"], 60_000);
}

/** Load a multi-turn script: one user turn per non-empty line. */
function loadConversation(path) {
  if (!path) return [];
  const text = readFileSync(path, "utf8");
  const turns = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l !== "");
  if (!turns.length) throw new Error(`conversation file "${path}" has no turns`);
  return turns;
}

/**
 * Parse the parenthesized release date from `hermes --version` output,
 * e.g. `Hermes Agent v0.20.4 (2026.8.18)` -> "2026.8.18".
 */
function parseReleaseDate(raw) {
  const m = String(raw ?? "").match(/\(([0-9]{4}\.[0-9]+(?:\.[0-9]+)*)\)/);
  return m ? m[1] : null;
}

/** Run one conversation round via `hermes -z "<prompt>" --usage-file <file>`. */
function runRound(cfg, roundIndex, prompt) {
  return new Promise((resolve) => {
    const started = Date.now();
    const usageFile = join(cfg.usageDir, `usage-${Date.now()}-${Math.round(Math.random() * 1e9)}.json`);
    const args = ["-z", prompt, "--usage-file", usageFile];
    const spec = buildSpawnSpec(cfg.hermes, args);
    const child = spawn(spec.command, spec.args, { stdio: ["ignore", "pipe", "pipe"], shell: spec.shell });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
    }, cfg.perRoundTimeoutMs);
    child.stdout?.on("data", (d) => { stdout += d; });
    child.stderr?.on("data", (d) => { stderr += d; });
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({
        ok: false,
        round: roundIndex,
        exitCode: null,
        durationMs: Date.now() - started,
        error: `spawn failed: ${err.message}`,
        stdout, stderr, usageFile,
      });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const durationMs = Date.now() - started;
      if (timedOut) {
        resolve({
          ok: false, round: roundIndex, exitCode: code, durationMs,
          error: `no response, killed after ${cfg.perRoundTimeoutMs}ms`,
          stdout, stderr, usageFile,
        });
        return;
      }
      if (code !== 0) {
        resolve({
          ok: false, round: roundIndex, exitCode: code, durationMs,
          error: `hermes exited with code ${code}`,
          stdout, stderr, usageFile,
        });
        return;
      }
      if (!stdout.trim()) {
        resolve({
          ok: false, round: roundIndex, exitCode: 0, durationMs,
          error: "hermes exited 0 but produced an empty response",
          stdout, stderr, usageFile,
        });
        return;
      }
      if (looksLikeErrorReply(stdout)) {
        resolve({
          ok: false, round: roundIndex, exitCode: 0, durationMs,
          error: `reply looks like an error: ${truncate(stdout.trim(), 80)}`,
          stdout, stderr, usageFile,
        });
        return;
      }
      resolve({ ok: true, round: roundIndex, exitCode: 0, durationMs, error: null, stdout, stderr, usageFile });
    });
  });
}

// Detect output that is really an HTTP/auth/network error text rather than a
// real model reply — `hermes -z` can print "HTTP 401: not authorized" yet still
// exit 0, which would otherwise be counted as a successful round.
function looksLikeErrorReply(text) {
  return /(^|\b)(HTTP\s+\d{3}|\b(401|403|429|500|502|503)\b|not authorized|unauthorized|rate\s*limit|invalid(|\s+)api key|api key.*(invalid|incorrect)|failed to connect|connection (refused|timed out|error)|internal server error|error:|exception)/i.test(String(text));
}

function p95(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1);
  return sorted[idx];
}

function sleepMs(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const cfg = parseArgsOrExit();
  const startedAt = Date.now();
  const failures = [];
  const latencies = [];
  let conversation = [];
  try {
    conversation = loadConversation(cfg.conversationFile);
  } catch (err) {
    console.error(`[soak] argument error: ${err.message}\n\n${USAGE}`);
    process.exit(2);
  }

  log(`${TOOL} v${TOOL_VERSION} — Hermes soak start`);
  log(`config: hermes=${cfg.hermes} rounds=${cfg.rounds} interval=${cfg.interval}s ` +
      `max-total=${cfg.maxTotalSeconds}s per-round-timeout=${cfg.perRoundTimeoutMs}ms ` +
      `expected-version=${cfg.expectedVersion ?? "(none)"}`);
  if (conversation.length) {
    log(`conversation: ${conversation.length} turns from ${cfg.conversationFile} (cycles per round)`);
  }

  // ---- Preflight: version detection + verification -----------------------
  const versionProbe = await detectHermesVersion(cfg.hermes);
  let versionInfo = {
    raw: (versionProbe.stdout + versionProbe.stderr).trim() || null,
    releaseDate: null,
    expected: cfg.expectedVersion ? normalizeVersion(cfg.expectedVersion) : null,
    verified: false,
    spawnError: versionProbe.spawnError ?? null,
  };
  if (versionProbe.spawnError) {
    log(`ERROR: cannot run ${cfg.hermes}: ${versionProbe.spawnError}`);
  } else if (versionProbe.code !== 0) {
    log(`ERROR: ${cfg.hermes} --version exited ${versionProbe.code}`);
  } else {
    versionInfo.releaseDate = parseReleaseDate(versionInfo.raw);
    if (versionInfo.expected && versionInfo.releaseDate === versionInfo.expected) {
      versionInfo.verified = true;
    }
    log(`hermes version: ${versionInfo.raw}`);
    if (cfg.expectedVersion) {
      log(versionInfo.verified
        ? `version OK: release ${versionInfo.releaseDate} matches expected ${versionInfo.expected}`
        : `version MISMATCH: release ${versionInfo.releaseDate ?? "(unparsed)"} != expected ${versionInfo.expected}`);
    }
  }

  const totalBudgetMs = cfg.maxTotalSeconds * 1000;
  let terminationReason = "completed";
  let executedRounds = 0;
  let consecutiveFailures = 0;

  // ---- Soak loop ----------------------------------------------------------
  for (let round = 1; round <= cfg.rounds; round++) {
    if (interrupted) {
      terminationReason = `interrupted_${interrupted}`;
      log(`interrupted (${interrupted}) — stopping after ${executedRounds} executed rounds`);
      break;
    }
    const elapsed = Date.now() - startedAt;
    if (elapsed >= totalBudgetMs) {
      terminationReason = "max_total_seconds_reached";
      log(`max-total-seconds (${cfg.maxTotalSeconds}s) reached — stopping after ${executedRounds} executed rounds`);
      break;
    }

    const prompt = conversation.length ? conversation[(round - 1) % conversation.length] : cfg.prompt;
    log(`round ${round}/${cfg.rounds} ... ${truncate(prompt, 40)}`);
    executedRounds++;
    const res = await runRound(cfg, round, prompt);
    latencies.push(res.durationMs);
    if (res.ok) {
      consecutiveFailures = 0;
      log(`round ${round}/${cfg.rounds} OK (${res.durationMs}ms) — reply: ${truncate(res.stdout.trim(), 60)}`);
    } else {
      consecutiveFailures++;
      failures.push({
        round: res.round,
        exit_code: res.exitCode,
        duration_ms: res.durationMs,
        error: res.error,
        stderr_tail: tail(res.stderr.trim(), 500),
      });
      log(`round ${round}/${cfg.rounds} FAILED (${res.durationMs}ms): ${res.error}`);
      if (consecutiveFailures >= cfg.maxConsecutiveFailures) {
        terminationReason = "max_consecutive_failures";
        log(`aborting: ${consecutiveFailures} consecutive failures (limit ${cfg.maxConsecutiveFailures})`);
        break;
      }
    }

    // Wait between rounds (unless this was the last round / loop will exit)
    if (round < cfg.rounds && !interrupted) {
      const remaining = totalBudgetMs - (Date.now() - startedAt);
      const wait = Math.min(cfg.interval * 1000, Math.max(0, remaining));
      if (wait > 0) await sleepMs(wait);
    }
  }

  const totalDurationMs = Date.now() - startedAt;

  // ---- Verdict ------------------------------------------------------------
  const roundCount = {
    total: cfg.rounds,
    executed: executedRounds,
    passed: executedRounds - failures.length,
    failed: failures.length,
  };

  const versionOk = !cfg.expectedVersion || versionInfo.verified;
  // Passed only when: every executed round succeeded, at least one round ran,
  // the version check passed, and the soak ran to completion (not truncated).
  const passed =
    failures.length === 0 &&
    executedRounds >= 1 &&
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
      interval_seconds: cfg.interval,
      max_total_seconds: cfg.maxTotalSeconds,
      per_round_timeout_ms: cfg.perRoundTimeoutMs,
      max_consecutive_failures: cfg.maxConsecutiveFailures,
      prompt: conversation.length ? null : cfg.prompt,
      conversation_file: cfg.conversationFile ?? null,
      conversation_turns: conversation.length || null,
      expected_version: cfg.expectedVersion,
    },
    rounds: {
      total: roundCount.total,
      executed: roundCount.executed,
      passed: roundCount.passed,
      failed: roundCount.failed,
    },
    stats: {
      total_duration_seconds: +(totalDurationMs / 1000).toFixed(2),
      avg_round_ms: latencies.length ? Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length) : null,
      min_round_ms: latencies.length ? Math.min(...latencies) : null,
      max_round_ms: latencies.length ? Math.max(...latencies) : null,
      p95_round_ms: p95(latencies),
    },
    failures,
    termination_reason: terminationReason,
    completed_at: new Date().toISOString(),
  };

  const json = JSON.stringify(verdict, null, 2);

  if (cfg.resultFile) {
    try {
      mkdirSync(dirname(cfg.resultFile), { recursive: true });
      writeFileSync(cfg.resultFile, json + "\n", "utf8");
      log(`verdict written to ${cfg.resultFile}`);
    } catch (err) {
      log(`WARNING: could not write result file ${cfg.resultFile}: ${err.message}`);
    }
  }

  process.stdout.write(json + "\n");

  log(passed ? "RESULT: PASSED" : "RESULT: FAILED");
  if (interrupted === "SIGINT") process.exit(130);
  if (interrupted === "SIGTERM") process.exit(143);
  process.exit(passed ? 0 : 1);
}

function truncate(s, n) {
  return s.length > n ? `${s.slice(0, n)}…` : s;
}
function tail(s, n) {
  return s.length > n ? `…${s.slice(-n)}` : s;
}

main().catch((err) => {
  console.error(`[soak] fatal: ${err.stack || err}`);
  process.exit(1);
});
