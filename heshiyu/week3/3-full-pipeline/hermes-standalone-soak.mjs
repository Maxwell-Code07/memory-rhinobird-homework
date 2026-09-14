#!/usr/bin/env node

/**
 * Hermes standalone soak runner.
 *
 * Adapted from the structure of openclaw-soak-tool:
 * - bounded conversation loop with immediate JSONL persistence
 * - configurable rounds / interval / duration
 * - plant -> recall memory probes
 * - driver resource and optional log monitoring
 * - meta snapshot and text report on every completion path
 *
 * The transport is Hermes CLI, not OpenClaw's HTTP chat-completions API.
 */

import { spawn } from "node:child_process";
import {
  appendFileSync,
  closeSync,
  existsSync,
  fstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  statSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const TOOL = "hermes-standalone-soak";
const VERSION = "2.1.0";
const ANSI = /\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g;
const ERROR = /(?:\bHTTP\s*[45]\d\d\b|\b(?:401|403|408|429|500|502|503|504)\b|unauthori[sz]ed|invalid\s+(?:api\s*)?key|api\s*key[^\n]*(?:invalid|incorrect|expired)|rate\s*limit|connection\s+(?:refused|reset|timed\s*out)|failed\s+to\s+connect|service\s+unavailable|traceback|uncaught\s+exception|\berror\s*:)/i;

const DEFAULT_SCENARIO = {
  name: "basic-conversation",
  turns: [
    { id: "health", prompt: "这是 Hermes 稳定性测试第 {{round}} 轮。请只用一句中文确认你能正常响应。", min_chars: 2 },
    { id: "continuity", prompt: "承接上一轮，请用一句话说明多轮对话测试验证了什么。", min_chars: 6 },
    { id: "summary", prompt: "请用一句话概括当前测试，必须包含“稳定性测试”。", expect_all: ["稳定性测试"] },
    { id: "sequence", prompt: "请确认这是连续会话而不是孤立问答，只回复一句话。", min_chars: 6 },
  ],
};

const PROBES = [
  {
    id: "database-preference",
    plant: "请记住：我叫 LinXiao，偏好使用 Python 和 PowerShell 写自动化脚本。请简短确认。",
    recall: "请回忆刚才我叫什么，以及偏好的两种脚本语言。只回答事实。",
    expected: ["LinXiao", "Python", "PowerShell"],
    gateway_query: "我的职业、脚本语言偏好、周末习惯和生产部署约束是什么？",
  },
  {
    id: "deployment-constraint",
    plant: "请记住：生产数据库变更必须先有备份和回滚方案，不接受周五晚上部署。请简短确认。",
    recall: "请回忆生产数据库变更的约束，以及不接受的部署时间。只回答事实。",
    expected: ["备份", "回滚", "周五"],
    gateway_query: "生产数据库变更有哪些约束？",
  },
];

function timestamp() { return new Date().toISOString(); }
function log(message) { process.stderr.write(`[${timestamp()}] ${message}\n`); }
function sleep(ms, signal) {
  return new Promise((resolveSleep) => {
    if (signal?.aborted) { resolveSleep(); return; }
    const finish = () => { clearTimeout(timer); signal?.removeEventListener("abort", finish); resolveSleep(); };
    const timer = setTimeout(finish, ms);
    signal?.addEventListener("abort", finish, { once: true });
  });
}
function strip(value) { return String(value ?? "").replace(ANSI, "").replace(/\r/g, "").trim(); }
function writeJson(path, value) { writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, "utf8"); }
function appendJsonl(path, value) { appendFileSync(path, `${JSON.stringify(value)}\n`, "utf8"); }
function percentile(values, percentileValue) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.max(0, Math.ceil(sorted.length * percentileValue / 100) - 1)];
}
function formatMs(value) { return value == null ? "n/a" : value < 1000 ? `${value}ms` : `${(value / 1000).toFixed(2)}s`; }

function loadDotEnv(directory) {
  const path = join(directory, ".env");
  if (!existsSync(path)) return;
  for (const rawLine of readFileSync(path, "utf8").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!match || process.env[match[1]] !== undefined) continue;
    let value = match[2].trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    process.env[match[1]] = value;
  }
}

function parseDuration(value, option) {
  const match = String(value ?? "").trim().match(/^(\d+(?:\.\d+)?)(ms|s|m|h)?$/i);
  if (!match || Number(match[1]) < 0) throw new Error(`${option} must be a non-negative duration, for example 500ms, 2s, 10m.`);
  const multiplier = { ms: 1, s: 1000, m: 60_000, h: 3_600_000 }[(match[2] ?? "ms").toLowerCase()];
  return Math.round(Number(match[1]) * multiplier);
}

function requireValue(args, index, name) {
  if (index + 1 >= args.length || args[index + 1].startsWith("--")) throw new Error(`${name} needs a value.`);
  return args[index + 1];
}

function help() {
  return `Hermes Standalone Soak v${VERSION}

Usage:
  node hermes-standalone-soak.mjs [options]

Core options:
  --rounds <N>                 Maximum conversation rounds (default: 10)
  --interval <duration>        Wait after each round, e.g. 2s (default: 2s)
  --duration <duration>        Total time cap, e.g. 10m (default: 10m)
  --round-timeout <duration>   One Hermes request cap (default: 180s)
  --scenario <json>            Conversation scenario JSON
  --output <dir>               Result directory

Hermes options:
  --hermes <command>           Hermes executable (default: hermes)
  --hermes-arg <arg>           Prefix argument; repeatable
  --transport <chat|oneshot>   chat keeps a Hermes session (default: chat)
  --session <name>             Fixed chat session name
  --expected-version <0.x.x>   Fail if Hermes version differs

Reference-template features:
  --memory-probe-every <N>     Plant then recall every N rounds (0 disables; default: 0)
  --probe-mode <chat|gateway>  Recall via Hermes chat or Gateway /recall
  --gateway-url <url>          Required for gateway probe mode
  --probe-wait <duration>      Gateway probe retry window (default: 0s)
  --probe-poll <duration>      Gateway retry interval (default: 3s)
  --resource-interval <time>   Driver resource sampling interval (default: 5s)
  --log-file <path>            Optional Gateway log to monitor

Failure handling:
  --max-consecutive-failures <N>  Stop after N failures (default: 3)
  --max-failure-rate <0..1>       Allowed final failure rate (default: 0)
  --round-retries <N>             Retry timeout/service rounds (default: 0)
  --help
`;
}

function parseArgs(argv) {
  const config = {
    rounds: Number(process.env.SOAK_ROUNDS ?? 10),
    intervalMs: parseDuration(process.env.SOAK_INTERVAL ?? "2s", "SOAK_INTERVAL"),
    durationMs: parseDuration(process.env.SOAK_DURATION ?? "10m", "SOAK_DURATION"),
    roundTimeoutMs: parseDuration(process.env.SOAK_ROUND_TIMEOUT ?? "180s", "SOAK_ROUND_TIMEOUT"),
    hermes: process.env.HERMES_COMMAND ?? "hermes",
    hermesArgs: [],
    transport: process.env.SOAK_TRANSPORT ?? "chat",
    session: process.env.SOAK_SESSION ?? "",
    scenario: process.env.SOAK_SCENARIO ?? "",
    output: process.env.SOAK_OUTPUT ?? "",
    expectedVersion: process.env.SOAK_EXPECTED_VERSION ?? "",
    probeEvery: Number(process.env.SOAK_MEMORY_PROBE_EVERY ?? 0),
    probeMode: process.env.SOAK_PROBE_MODE ?? "chat",
    gatewayUrl: process.env.SOAK_GATEWAY_URL ?? "",
    probeWaitMs: parseDuration(process.env.SOAK_PROBE_WAIT ?? "0s", "SOAK_PROBE_WAIT"),
    probePollMs: parseDuration(process.env.SOAK_PROBE_POLL ?? "3s", "SOAK_PROBE_POLL"),
    resourceIntervalMs: parseDuration(process.env.SOAK_RESOURCE_INTERVAL ?? "5s", "SOAK_RESOURCE_INTERVAL"),
    logFile: process.env.SOAK_LOG_FILE ?? "",
    maxConsecutiveFailures: Number(process.env.SOAK_MAX_CONSECUTIVE_FAILURES ?? 3),
    maxFailureRate: Number(process.env.SOAK_MAX_FAILURE_RATE ?? 0),
    roundRetries: Number(process.env.SOAK_ROUND_RETRIES ?? 0),
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--help" || argument === "-h") return { help: true };
    if (argument === "--rounds") config.rounds = Number(requireValue(argv, index++, argument));
    else if (argument === "--interval") config.intervalMs = parseDuration(requireValue(argv, index++, argument), argument);
    else if (argument === "--duration") config.durationMs = parseDuration(requireValue(argv, index++, argument), argument);
    else if (argument === "--round-timeout") config.roundTimeoutMs = parseDuration(requireValue(argv, index++, argument), argument);
    else if (argument === "--hermes") config.hermes = requireValue(argv, index++, argument);
    else if (argument === "--hermes-arg") config.hermesArgs.push(requireValue(argv, index++, argument));
    else if (argument === "--transport") config.transport = requireValue(argv, index++, argument);
    else if (argument === "--session") config.session = requireValue(argv, index++, argument);
    else if (argument === "--scenario") config.scenario = requireValue(argv, index++, argument);
    else if (argument === "--output") config.output = requireValue(argv, index++, argument);
    else if (argument === "--expected-version") config.expectedVersion = requireValue(argv, index++, argument);
    else if (argument === "--memory-probe-every") config.probeEvery = Number(requireValue(argv, index++, argument));
    else if (argument === "--probe-mode") config.probeMode = requireValue(argv, index++, argument);
    else if (argument === "--gateway-url") config.gatewayUrl = requireValue(argv, index++, argument).replace(/\/$/, "");
    else if (argument === "--probe-wait") config.probeWaitMs = parseDuration(requireValue(argv, index++, argument), argument);
    else if (argument === "--probe-poll") config.probePollMs = parseDuration(requireValue(argv, index++, argument), argument);
    else if (argument === "--resource-interval") config.resourceIntervalMs = parseDuration(requireValue(argv, index++, argument), argument);
    else if (argument === "--log-file") config.logFile = requireValue(argv, index++, argument);
    else if (argument === "--max-consecutive-failures") config.maxConsecutiveFailures = Number(requireValue(argv, index++, argument));
    else if (argument === "--max-failure-rate") config.maxFailureRate = Number(requireValue(argv, index++, argument));
    else if (argument === "--round-retries") config.roundRetries = Number(requireValue(argv, index++, argument));
    else throw new Error(`Unknown option: ${argument}`);
  }
  if (!Number.isInteger(config.rounds) || config.rounds <= 0) throw new Error("--rounds must be a positive integer.");
  if (!Number.isInteger(config.probeEvery) || config.probeEvery < 0) throw new Error("--memory-probe-every must be a non-negative integer.");
  if (!["chat", "oneshot"].includes(config.transport)) throw new Error("--transport must be chat or oneshot.");
  if (!["chat", "gateway"].includes(config.probeMode)) throw new Error("--probe-mode must be chat or gateway.");
  if (config.probeEvery > 0 && config.probeMode === "gateway" && !config.gatewayUrl) throw new Error("--gateway-url is required when --probe-mode gateway.");
  if (!Number.isInteger(config.maxConsecutiveFailures) || config.maxConsecutiveFailures < 1) throw new Error("--max-consecutive-failures must be at least 1.");
  if (!(config.maxFailureRate >= 0 && config.maxFailureRate <= 1)) throw new Error("--max-failure-rate must be between 0 and 1.");
  if (!Number.isInteger(config.roundRetries) || config.roundRetries < 0) throw new Error("--round-retries must be a non-negative integer.");
  return config;
}

function loadScenario(input) {
  if (!input) return { ...DEFAULT_SCENARIO, path: null };
  const path = resolve(input);
  const scenario = JSON.parse(readFileSync(path, "utf8"));
  if (!scenario || !Array.isArray(scenario.turns) || scenario.turns.length === 0) throw new Error("Scenario must contain a non-empty turns array.");
  for (const turn of scenario.turns) {
    if (!turn || typeof turn.prompt !== "string" || !turn.prompt.trim()) throw new Error("Each scenario turn needs a non-empty prompt.");
  }
  return { ...scenario, path };
}

function runProcess(command, args, timeoutMs, signal) {
  return new Promise((resolveProcess) => {
    const started = Date.now();
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    let child;
    let timer;
    let killTimer;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(killTimer);
      signal?.removeEventListener("abort", terminate);
      resolveProcess({ ...result, latencyMs: Date.now() - started, stdout: strip(stdout), stderr: strip(stderr), timedOut, abortReason: signal?.aborted ? signal.reason : null });
    };
    const terminate = () => {
      if (settled || !child?.pid) return;
      try {
        if (process.platform === "win32") {
          const killer = spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], { windowsHide: true, stdio: "ignore" });
          killer.on("error", () => child.kill());
        } else {
          process.kill(-child.pid, "SIGKILL");
        }
      } catch { child.kill(); }
      killTimer ??= setTimeout(() => {
        child.kill("SIGKILL");
        child.stdout.destroy();
        child.stderr.destroy();
        child.unref();
        finish({ exitCode: null, signal: "SIGKILL", spawnError: null });
      }, 1500);
    };
    if (signal?.aborted) { finish({ exitCode: null, signal: null, spawnError: null }); return; }
    try {
      child = spawn(command, args, { windowsHide: true, detached: process.platform !== "win32", stdio: ["ignore", "pipe", "pipe"] });
      child.stdout.on("data", (chunk) => { stdout += chunk; });
      child.stderr.on("data", (chunk) => { stderr += chunk; });
      child.on("error", (error) => finish({ exitCode: null, signal: null, spawnError: error.message }));
      child.on("close", (exitCode, signal) => finish({ exitCode, signal, spawnError: null }));
      signal?.addEventListener("abort", terminate, { once: true });
      timer = setTimeout(() => { timedOut = true; terminate(); }, timeoutMs);
    } catch (error) {
      finish({ exitCode: null, signal: null, spawnError: error.message });
    }
  });
}

function failureFrom(result) {
  const diagnostics = `${result.stdout}\n${result.stderr}\n${result.spawnError ?? ""}`.trim();
  if (result.abortReason) return { kind: result.abortReason, message: `Hermes action cancelled: ${result.abortReason}.` };
  if (result.timedOut) return { kind: "timeout", message: "Hermes did not finish before the round timeout." };
  if (result.spawnError) return { kind: "spawn", message: result.spawnError };
  if (ERROR.test(diagnostics)) return { kind: /401|403|unauthori[sz]ed|api\s*key/i.test(diagnostics) ? "authentication" : "service", message: diagnostics.slice(0, 700) };
  if (result.exitCode !== 0) return { kind: "process", message: `Hermes exited ${result.exitCode}: ${diagnostics.slice(0, 700)}` };
  return null;
}

function usableReply(stdout) {
  const lines = strip(stdout).split("\n").map((line) => line.trim()).filter(Boolean);
  const reply = lines.filter((line) => !/^session_id\s*:/i.test(line) && !/^warning[:\s]/i.test(line)).join("\n").trim();
  return reply || "";
}

function validateTurn(turn, reply) {
  if (!reply) return "Empty Hermes reply.";
  if (Number.isFinite(turn.min_chars) && reply.length < turn.min_chars) return `Reply is shorter than min_chars=${turn.min_chars}.`;
  if (Array.isArray(turn.expect_all) && !turn.expect_all.every((keyword) => reply.includes(keyword))) return `Reply missed required keyword(s): ${turn.expect_all.filter((keyword) => !reply.includes(keyword)).join(", ")}.`;
  if (Array.isArray(turn.expect_any) && !turn.expect_any.some((keyword) => reply.includes(keyword))) return `Reply missed all accepted keywords: ${turn.expect_any.join(", ")}.`;
  return null;
}

class ResourceMonitor {
  constructor(outputPath, intervalMs) {
    this.outputPath = outputPath;
    this.intervalMs = intervalMs;
    this.samples = [];
    this.timer = null;
  }
  sample() {
    const usage = process.memoryUsage();
    const cpu = process.cpuUsage();
    const item = { at: timestamp(), driver_pid: process.pid, rss_bytes: usage.rss, heap_used_bytes: usage.heapUsed, external_bytes: usage.external, cpu_user_us: cpu.user, cpu_system_us: cpu.system };
    this.samples.push(item);
    appendJsonl(this.outputPath, item);
  }
  start() { this.sample(); this.timer = setInterval(() => this.sample(), this.intervalMs); }
  stop() { if (this.timer) clearInterval(this.timer); this.sample(); }
  summary() {
    const rss = this.samples.map((sample) => sample.rss_bytes);
    return { samples: this.samples.length, driver_pid: process.pid, rss_initial_bytes: rss[0] ?? null, rss_peak_bytes: rss.length ? Math.max(...rss) : null, rss_final_bytes: rss.at(-1) ?? null };
  }
}

class LogMonitor {
  constructor(path, outputPath) { this.path = path; this.outputPath = outputPath; this.position = 0; this.events = []; this.timer = null; }
  poll() {
    if (!this.path || !existsSync(this.path)) return;
    let descriptor;
    try {
      descriptor = openSync(this.path, "r");
      const size = fstatSync(descriptor).size;
      if (size < this.position) this.position = 0;
      if (size === this.position) return;
      const buffer = Buffer.alloc(size - this.position);
      readSync(descriptor, buffer, 0, buffer.length, this.position);
      this.position = size;
      for (const line of buffer.toString("utf8").split(/\r?\n/)) {
        if (!line || !/(?:\berror\b|\bwarn\b|memory[-_ ]?tdai|\bl[0-3]\b)/i.test(line)) continue;
        const event = { at: timestamp(), tag: /memory[-_ ]?tdai|\bl[0-3]\b/i.test(line) ? "memory" : "log", level: /\berror\b/i.test(line) ? "error" : /\bwarn\b/i.test(line) ? "warn" : "info", line: line.slice(0, 2000) };
        this.events.push(event); appendJsonl(this.outputPath, event);
      }
    } catch { /* Log monitoring is optional. */ }
    finally { if (descriptor !== undefined) closeSync(descriptor); }
  }
  start() { if (!this.path) return; this.poll(); this.timer = setInterval(() => this.poll(), 2000); }
  stop() { if (this.timer) clearInterval(this.timer); this.poll(); }
  summary() { return { enabled: Boolean(this.path), events: this.events.length, errors: this.events.filter((event) => event.level === "error").length, warnings: this.events.filter((event) => event.level === "warn").length }; }
}

class HermesSoak {
  constructor(config, scenario, outputDir) {
    this.config = config;
    this.scenario = scenario;
    this.outputDir = outputDir;
    this.startedAt = Date.now();
    this.session = config.session || `soak-${this.startedAt}`;
    this.rounds = [];
    this.probes = [];
    this.consecutiveFailures = 0;
    this.stopReason = "completed";
    this.abortRequested = false;
    this.controller = new AbortController();
    this.files = { conversations: join(outputDir, "conversations.jsonl"), resources: join(outputDir, "resources.jsonl"), logs: join(outputDir, "log-events.jsonl"), probes: join(outputDir, "probes.json"), meta: join(outputDir, "meta.json"), snapshot: join(outputDir, "meta-snapshot.json"), report: join(outputDir, "report.txt") };
  }
  elapsed() { return Date.now() - this.startedAt; }
  overDeadline() { return this.elapsed() >= this.config.durationMs; }
  remainingMs() { return Math.max(0, this.config.durationMs - this.elapsed()); }
  requestStop(reason) {
    if (this.controller.signal.aborted) return;
    this.stopReason = reason;
    this.abortRequested = true;
    this.controller.abort(reason);
  }
  canContinue() {
    if (this.overDeadline()) this.requestStop("duration_reached");
    return !this.controller.signal.aborted;
  }
  commandFor(prompt, freshSession = false) {
    const prefix = [...this.config.hermesArgs];
    if (this.config.transport === "oneshot") return { command: this.config.hermes, args: [...prefix, "-z", prompt] };
    const session = freshSession ? `${this.session}-probe-${Date.now()}` : this.session;
    const args = [...prefix, "chat", "-Q", "--query", prompt, "--continue", session, "--no-restore-cwd", "--source", "tool"];
    if (!this.chatCreated && !freshSession) { args.push("--create-if-missing"); this.chatCreated = true; }
    return { command: this.config.hermes, args };
  }
  async callHermes(prompt, turn, kind = "conversation", freshSession = false, logicalId = null, attempt = 1) {
    const invocation = this.commandFor(prompt, freshSession);
    const startedAt = timestamp();
    const raw = await runProcess(invocation.command, invocation.args, this.config.roundTimeoutMs, this.controller.signal);
    const response = usableReply(raw.stdout);
    let error = failureFrom(raw);
    if (!error && kind !== "probe_plant") {
      const validation = validateTurn(turn, response);
      if (validation) error = { kind: "assertion", message: validation };
    }
    if (!error && kind === "probe_plant" && !response) error = { kind: "empty_reply", message: "Probe plant had no Hermes reply." };
    const record = { at: startedAt, finished_at: timestamp(), sequence: this.rounds.length + 1, logical_id: logicalId, attempt, kind, turn_id: turn.id, status: error ? "fail" : "pass", latency_ms: raw.latencyMs, prompt, response, response_chars: response.length, hermes: { command: invocation.command, args: invocation.args.map((argument) => argument === prompt ? "<prompt>" : argument), exit_code: raw.exitCode, signal: raw.signal, timed_out: raw.timedOut }, diagnostics: raw.stderr.slice(0, 2000), error };
    this.rounds.push(record); appendJsonl(this.files.conversations, record);
    return record;
  }
  async callWithRetry(prompt, turn, kind, freshSession, logicalId) {
    let record;
    for (let attempt = 1; attempt <= this.config.roundRetries + 1; attempt += 1) {
      record = await this.callHermes(prompt, turn, kind, freshSession, logicalId, attempt);
      if (!this.canContinue()) return record;
      if (record.status === "pass") return record;
      const retryable = ["timeout", "service", "spawn", "process"].includes(record.error?.kind);
      if (!retryable || attempt > this.config.roundRetries) return record;
      log(`${logicalId}: retry ${attempt}/${this.config.roundRetries} after [${record.error.kind}]`);
    }
    return record;
  }
  async runGatewayProbe(probe) {
    const started = Date.now();
    let last = null;
    do {
      if (!this.canContinue()) return { ok: false, error: this.stopReason, found: [] };
      try {
        const signal = AbortSignal.any([this.controller.signal, AbortSignal.timeout(Math.max(1, Math.min(this.config.roundTimeoutMs, 30_000)))]);
        const response = await fetch(`${this.config.gatewayUrl}/recall`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ query: probe.gateway_query, session_key: `${this.session}-probe-${Date.now()}` }), signal });
        const text = await response.text();
        let body; try { body = JSON.parse(text); } catch { body = { raw: text }; }
        const context = typeof body.context === "string" ? body.context : "";
        const found = probe.expected.filter((keyword) => context.toLowerCase().includes(keyword.toLowerCase()));
        last = { ok: response.ok && !body.error && (body.code === undefined || body.code === 0) && found.length === probe.expected.length, http_status: response.status, context, found, body };
        if (last.ok) return last;
      } catch (error) { last = { ok: false, error: error.message, found: [] }; }
      if (!this.canContinue() || Date.now() - started >= this.config.probeWaitMs) return last;
      await sleep(Math.max(0, Math.min(this.config.probePollMs, this.remainingMs(), this.config.probeWaitMs - (Date.now() - started))), this.controller.signal);
    } while (true);
  }
  async runProbe(round) {
    if (this.config.probeEvery === 0 || !this.canContinue()) return;
    const phase = round % this.config.probeEvery;
    const probe = PROBES[Math.floor((round - 1) / this.config.probeEvery) % PROBES.length];
    if (this.config.probeEvery === 1 || phase === Math.ceil(this.config.probeEvery / 2)) {
      const plant = await this.callHermes(probe.plant, { id: `plant-${probe.id}`, min_chars: 1 }, "probe_plant");
      this.probes.push({ id: probe.id, planted_at: timestamp(), plant_status: plant.status, expected: probe.expected });
      log(`probe ${probe.id}: planted (${plant.status})`);
    }
    if (phase !== 0 || !this.canContinue()) return;
    const item = this.probes.findLast((candidate) => candidate.id === probe.id && !candidate.recalled_at);
    if (!item) return;
    if (item.plant_status !== "pass") { item.status = "fail"; item.recalled_at = timestamp(); item.found = []; return; }
    if (this.config.probeMode === "gateway") {
      const result = await this.runGatewayProbe(probe);
      item.recalled_at = timestamp(); item.mode = "gateway"; item.found = result?.found ?? []; item.status = result?.ok ? "pass" : "fail"; item.http_status = result?.http_status ?? null; item.response = String(result?.context ?? result?.error ?? "").slice(0, 2000);
    } else {
      const recall = await this.callHermes(probe.recall, { id: `recall-${probe.id}`, expect_all: probe.expected }, "probe_recall");
      item.recalled_at = timestamp(); item.mode = "chat"; item.found = probe.expected.filter((keyword) => recall.response.includes(keyword)); item.status = recall.status; item.response = recall.response;
    }
    log(`probe ${probe.id}: recall ${item.status} (${item.found.length}/${item.expected.length} keyword(s))`);
  }
  snapshot(resourceSummary, logSummary) {
    const regular = this.latestRegularRounds();
    writeJson(this.files.snapshot, { note: "Intermediate snapshot. conversations.jsonl is appended after each action.", at: timestamp(), session: this.session, elapsed_ms: this.elapsed(), regular_rounds: regular.length, passed: regular.filter((round) => round.status === "pass").length, failed: regular.filter((round) => round.status === "fail").length, probes: this.probes, resource: resourceSummary, logs: logSummary });
  }
  summary(resourceSummary, logSummary) {
    const regular = this.latestRegularRounds();
    const passed = regular.filter((round) => round.status === "pass");
    const failed = regular.filter((round) => round.status === "fail");
    const failedProbes = this.probes.filter((probe) => probe.status === "fail");
    const pendingProbes = this.probes.filter((probe) => !probe.status);
    const failureRate = failed.length / Math.max(1, regular.length);
    const passedAll = regular.length === this.config.rounds && this.stopReason === "completed" && !this.abortRequested && failureRate <= this.config.maxFailureRate && failedProbes.length === 0 && pendingProbes.length === 0;
    return { status: passedAll ? "pass" : "fail", passed: passedAll, started_at: new Date(this.startedAt).toISOString(), completed_at: timestamp(), elapsed_ms: this.elapsed(), termination_reason: this.stopReason, session: this.session, config: { ...this.config, hermesArgs: this.config.hermesArgs }, scenario: { name: this.scenario.name, path: this.scenario.path ?? null, turns: this.scenario.turns.length }, rounds: { requested: this.config.rounds, executed: regular.length, attempts: this.rounds.filter((round) => round.kind === "conversation").length, passed: passed.length, failed: failed.length, failure_rate: failureRate }, latency_ms: { min: passed.length ? Math.min(...passed.map((round) => round.latency_ms)) : null, avg: passed.length ? Math.round(passed.reduce((total, round) => total + round.latency_ms, 0) / passed.length) : null, p50: percentile(passed.map((round) => round.latency_ms), 50), p95: percentile(passed.map((round) => round.latency_ms), 95), max: passed.length ? Math.max(...passed.map((round) => round.latency_ms)) : null }, probes: { enabled: this.config.probeEvery > 0, total: this.probes.length, passed: this.probes.filter((probe) => probe.status === "pass").length, failed: failedProbes.length, pending: pendingProbes.length, results: this.probes }, resources: resourceSummary, logs: logSummary, artifacts: this.files };
  }
  latestRegularRounds() {
    return [
      ...this.rounds
        .filter((round) => round.kind === "conversation")
        .reduce((latest, round) => latest.set(round.logical_id ?? String(round.sequence), round), new Map())
        .values(),
    ];
  }
  report(meta) {
    const lines = [
      "Hermes Standalone Soak Report",
      "============================",
      `Result: ${meta.status.toUpperCase()}`,
      `Started: ${meta.started_at}`,
      `Elapsed: ${formatMs(meta.elapsed_ms)}`,
      `Session: ${meta.session}`,
      `Scenario: ${meta.scenario.name}`,
      `Rounds: requested=${meta.rounds.requested}, executed=${meta.rounds.executed}, passed=${meta.rounds.passed}, failed=${meta.rounds.failed}`,
      `Latency: p50=${formatMs(meta.latency_ms.p50)}, p95=${formatMs(meta.latency_ms.p95)}, avg=${formatMs(meta.latency_ms.avg)}`,
      `Memory probes: enabled=${meta.probes.enabled}, passed=${meta.probes.passed}/${meta.probes.total}, failed=${meta.probes.failed}`,
      `Driver RSS: initial=${meta.resources.rss_initial_bytes ?? "n/a"}, peak=${meta.resources.rss_peak_bytes ?? "n/a"}, final=${meta.resources.rss_final_bytes ?? "n/a"}`,
      `Log monitor: enabled=${meta.logs.enabled}, errors=${meta.logs.errors}, warnings=${meta.logs.warnings}`,
      `Termination: ${meta.termination_reason}`,
      "",
      `JSONL: ${basename(this.files.conversations)}`,
      `Resources: ${basename(this.files.resources)}`,
      `Probes: ${basename(this.files.probes)}`,
      `Meta: ${basename(this.files.meta)}`,
    ];
    return lines.join("\n");
  }
  async preflight() {
    const preflight = await runProcess(this.config.hermes, [...this.config.hermesArgs, "--version"], this.config.expectedVersion ? 20_000 : 5_000, this.controller.signal);
    if (!this.canContinue()) return false;
    const version = `${preflight.stdout}\n${preflight.stderr}`.match(/v?(0\.\d+\.\d+)/)?.[1] ?? null;
    if (preflight.exitCode !== 0 || preflight.spawnError || preflight.timedOut) {
      if (this.config.expectedVersion) {
        this.stopReason = "preflight_failed";
        log(`preflight failed: ${(preflight.spawnError ?? preflight.stderr ?? "version command timed out").slice(0, 300)}`);
        return false;
      }
      log("preflight version command was unavailable; expected version was not set, continuing with actual conversations.");
      return true;
    }
    if (this.config.expectedVersion && version !== this.config.expectedVersion) { this.stopReason = "preflight_failed"; log(`preflight version mismatch: expected=${this.config.expectedVersion}, actual=${version ?? "unknown"}`); return false; }
    log(`Hermes version: ${version ?? "unknown"}`);
    return true;
  }
  async run(resourceMonitor, logMonitor) {
    const deadline = setTimeout(() => this.requestStop("duration_reached"), this.remainingMs());
    try {
      if (!this.canContinue() || !await this.preflight()) return;
      for (let round = 1; round <= this.config.rounds; round += 1) {
        if (!this.canContinue()) break;
        const turn = this.scenario.turns[(round - 1) % this.scenario.turns.length];
        const prompt = turn.prompt.replaceAll("{{round}}", String(round));
        log(`round ${round}/${this.config.rounds}: ${turn.id}`);
        const record = await this.callWithRetry(prompt, turn, "conversation", false, `round-${round}`);
        if (record.status === "pass") { this.consecutiveFailures = 0; log(`round ${round}/${this.config.rounds}: PASS ${formatMs(record.latency_ms)}`); }
        else { this.consecutiveFailures += 1; log(`round ${round}/${this.config.rounds}: FAIL [${record.error.kind}] ${record.error.message.slice(0, 160)}`); }
        if (this.canContinue()) await this.runProbe(round);
        this.snapshot(resourceMonitor.summary(), logMonitor.summary());
        if (!this.canContinue()) break;
        if (this.consecutiveFailures >= this.config.maxConsecutiveFailures) { this.stopReason = "consecutive_failures"; break; }
        if (round < this.config.rounds) await sleep(Math.min(this.config.intervalMs, this.remainingMs()), this.controller.signal);
      }
    } finally { clearTimeout(deadline); }
  }
}

async function main() {
  loadDotEnv(SCRIPT_DIR); loadDotEnv(process.cwd());
  let config;
  try { config = parseArgs(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`${error.message}\n\n${help()}`); return 2; }
  if (config.help) { process.stdout.write(help()); return 0; }
  let scenario;
  try { scenario = loadScenario(config.scenario); }
  catch (error) { process.stderr.write(`Scenario error: ${error.message}\n`); return 2; }
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const outputDir = resolve(config.output || join(SCRIPT_DIR, "results", `hermes-soak-${stamp}`));
  mkdirSync(outputDir, { recursive: true });
  const runner = new HermesSoak(config, scenario, outputDir);
  const resources = new ResourceMonitor(runner.files.resources, config.resourceIntervalMs);
  const logs = new LogMonitor(config.logFile, runner.files.logs);
  const stop = () => { runner.requestStop("interrupted"); log("interrupt received; cancelling active work and saving a failed result."); };
  process.once("SIGINT", stop); process.once("SIGTERM", stop);
  log(`${TOOL} ${VERSION}; output=${outputDir}`);
  log(`rounds=${config.rounds}; interval=${config.intervalMs}ms; duration=${config.durationMs}ms; probeEvery=${config.probeEvery}; probeMode=${config.probeMode}`);
  resources.start(); logs.start();
  try { await runner.run(resources, logs); }
  catch (error) { runner.requestStop("runtime_error"); log(`Runtime error: ${error.message}`); }
  finally { logs.stop(); resources.stop(); process.removeListener("SIGINT", stop); process.removeListener("SIGTERM", stop); }
  const meta = runner.summary(resources.summary(), logs.summary());
  meta.tool = TOOL;
  meta.tool_version = VERSION;
  writeJson(runner.files.probes, meta.probes.results);
  writeJson(runner.files.meta, meta);
  writeFileSync(runner.files.report, `${runner.report(meta)}\n`, "utf8");
  log(`RESULT: ${meta.status.toUpperCase()}`);
  log(`Artifacts: ${outputDir}`);
  return meta.passed ? 0 : 1;
}

process.exitCode = await main();
