#!/usr/bin/env node
/**
 * soak.js — Hermes Agent 长稳自动对话（soak）工具（第三周作业·基础要求）
 *
 * 结构对齐参考脚本 openclaw-soak-tool/standalone-soak.mjs（零依赖 Node.js），
 * 接口从 OpenClaw HTTP /v1/chat/completions 适配为 Hermes CLI headless：
 *   `hermes chat -q <消息> -Q`（非 TTY 下回答后自动退出，用退出码 + stdout 判定）
 *
 * 参考结构 → 本脚本映射：
 *   ┌─ 参考 standalone-soak.mjs ───────────────┬─ Hermes 适配（本文件）─────────┐
 *   │ 同一 sessionKey 连续对话（session pin）   │ --session-mode same: 首轮解析  │
 *   │                                          │   session_id，后续轮 --resume    │
 *   │ 多话题循环（六类话题池）                  │ 内置 TOPICS 中文话题池轮换       │
 *   │ 记忆探针 植入→回忆→关键词核对             │ RECALL_PROBES 中文探针 + 自定义  │
 *   │ Gateway 日志监控（error/warn/tdai 事件）  │ --log-files 增量轮询（2s）       │
 *   │ 进程资源监控（RSS/CPU/FD，10s）           │ /proc 实现（容器内 ps/lsof 缺失  │
 *   │                                          │   时仍可用）                     │
 *   │ 每 100 轮落盘 + meta-snapshot             │ 流式 JSONL + --flush-every 快照  │
 *   │ conversations/resources/log-events/       │ 同名输出文件 + meta/probes.json  │
 *   │   probes + meta + report                  │   + report.txt                  │
 *   └──────────────────────────────────────────┴─────────────────────────────────┘
 *
 * 作业 4 条硬要求：可配置参数 / 结构化结果(pass-fail+统计) / 自动持续对话 / 异常容错。
 * 零第三方依赖（Node >= 18 内置模块）。
 *
 * 用法：
 *   node soak.js --rounds 30 --interval-ms 8000 --duration-sec 600
 *   node soak.js --rounds 47 --message-file ./scenario.txt --probe-every 8 \
 *                --resource-interval-ms 5000 --log-files /opt/data/logs/agent.log
 * 入口脚本（读 .env + 常用简写参数）：./run-hermes-soak.sh
 */
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");

// ===========================================================================
// 内置话题池（六类，对应参考脚本 TOPICS 的 Hermes 中文版）
// ===========================================================================
const TOPICS = [
  { label: "tech-stack", category: "技术背景", message: "我最近在调研 Go 微服务的可观测性方案，想听听你对 OpenTelemetry 和 Prometheus 选型的看法，简单说说就行。" },
  { label: "daily-routine", category: "日常习惯", message: "聊聊你今天的工作流吧——你平时处理一个编程任务时，第一步会做什么？" },
  { label: "preference-coffee", category: "个人偏好", message: "我早上习惯先喝一杯黑咖啡再开始写代码，你觉得咖啡因对编程效率的影响大吗？" },
  { label: "event-release", category: "近期事件", message: "我们项目下周三要做大版本发布，我负责灰度方案，发布前你建议重点检查哪些风险点？" },
  { label: "instruction-review", category: "行为指令", message: "以后我给你的代码评审请求，请先看单元测试覆盖再谈实现细节，按这个顺序来。可以吗？" },
  { label: "career-growth", category: "情感成长", message: "我明年想开始带小团队，你觉得从技术骨干转技术管理，最先要补的能力是什么？" },
  { label: "tech-db", category: "技术背景", message: "我们的 MySQL 分库分表后遇到跨库查询的麻烦，除了汇总表还有什么常见的解法？" },
  { label: "habit-sleep", category: "日常习惯", message: "我平时十一点前睡觉，早上七点起。如果我偶尔熬夜到十二点半，第二天该怎么调整状态？" },
  { label: "preference-music", category: "个人偏好", message: "我最近在循环陈奕迅的老歌，你推荐一首适合写代码时听的歌吧。" },
  { label: "event-sports", category: "近期事件", message: "周五晚上我们羽毛球俱乐部有年度赛，我要打双打，赛前两天的训练量怎么安排比较合理？" },
  { label: "instruction-format", category: "行为指令", message: "以后给我方案建议时，控制在五条以内，每条配一句理由。记住这个偏好。" },
  { label: "learning-plan", category: "情感成长", message: "我今年计划读完十二本技术书，目前已读八本，最后四个月你会怎么帮我安排剩余的四本？" },
];

// ===========================================================================
// 内置记忆探针（对应参考 RECALL_PROBES：植入 → 回忆 → 关键词核对）
// 命中口径与参考一致：命中的关键词 >= ceil(总数/2) 即 recalled
// ===========================================================================
const RECALL_PROBES = [
  {
    id: "probe-family-trip",
    plantMessage: "跟你同步一个行程：我订好了 10 月 12 号带爸妈去云南的机票，从深圳出发先到昆明，当晚住大理古城边的民宿，钱已经付了。",
    recallQuestion: "我 10 月有一次家庭旅行，帮我确认一下：哪天出发、去哪里、和谁一起去？",
    expectedKeywords: ["大理", "10月12", "爸妈"],
  },
  {
    id: "probe-cat-incident",
    plantMessage: "跟你说个好玩的事：我家的布偶猫雪球上周三自己扒开阳台门溜出去了，在楼道里转悠了一圈，被邻居送回来，现在阳台门都上锁了。",
    recallQuestion: "我家猫上周发生了什么？它叫什么名字？",
    expectedKeywords: ["雪球", "阳台", "邻居"],
  },
  {
    id: "probe-work-schedule",
    plantMessage: "确认一下我下周的安排：周三上午和支付网关的同事过灰度发布方案，周五晚上羽毛球俱乐部年度赛我上场打双打。",
    recallQuestion: "我下周有哪些安排？分别在什么时候？",
    expectedKeywords: ["灰度", "羽毛球", "周三"],
  },
];

// ===========================================================================
// 工具
// ===========================================================================
const nowIso = () => new Date().toISOString();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const fmt = (ms) => (ms >= 1000 ? (ms / 1000).toFixed(2) + "s" : ms + "ms");

function percentile(sorted, q) {
  if (!sorted.length) return 0;
  const pos = Math.round((sorted.length - 1) * (q / 100));
  const idx = Math.max(0, Math.min(sorted.length - 1, pos));
  return sorted[idx];
}

// .env 加载（零依赖；CLI 参数优先级更高）
function loadDotEnv(dir, file = ".env") {
  const p = path.join(dir, file);
  const out = {};
  if (!fs.existsSync(p)) return out;
  for (const raw of fs.readFileSync(p, "utf8").split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const idx = line.indexOf("=");
    if (idx < 0) continue;
    out[line.slice(0, idx).trim()] = line.slice(idx + 1).trim().replace(/^["']|["']$/g, "");
  }
  return out;
}

// ===========================================================================
// 命令行参数
// ===========================================================================
const ENV_KEY_MAP = {
  SOAK_ROUNDS: "rounds", SOAK_INTERVAL_MS: "intervalMs", SOAK_DURATION_SEC: "durationSec",
  SOAK_TIMEOUT_MS: "timeoutMs", SOAK_PASS_RATE: "passRate", SOAK_HERMES: "hermesCmd",
  SOAK_SESSION_MODE: "sessionMode", SOAK_PROBE_EVERY: "probeEvery",
  SOAK_LOG_FILES: "logFiles", SOAK_RESOURCE_INTERVAL_MS: "resourceIntervalMs",
  SOAK_FLUSH_EVERY: "flushEvery", SOAK_MAX_CONSECUTIVE_FAILURES: "maxConsecutiveFailures",
  SOAK_OUTPUT_DIR: "out",
};

function parseArgs(argv) {
  const args = {
    rounds: 10, intervalMs: 5000, durationSec: 0, timeoutMs: 180000,
    passRate: 0.9, probePassRate: 0.5,
    messageFile: null, autoText: null, hermesCmd: "hermes",
    sessionMode: "new",            // new = 每轮新会话; same = 首轮后 --resume 同一 session
    probeEvery: 0,                 // 每 N 轮一组记忆探针（第 N/2 轮植入、第 N 轮验证），0=关闭
    probeFile: null,
    logFiles: null,                // 逗号分隔，增量监控（error/warn/memory-tdai 事件）
    logPollMs: 2000,
    resourceIntervalMs: 10000,     // 进程资源监控间隔，0=关闭
    flushEvery: 100,               // 每 N 轮写 meta-snapshot.json
    maxConsecutiveFailures: 0,     // 连续失败提前退出（0=关闭）
    resumeSid: null, out: null, env: [], quiet: false,
  };

  const env = loadDotEnv(process.cwd());
  for (const [k, v] of Object.entries(ENV_KEY_MAP)) {
    if (env[k] !== undefined && env[k] !== "") {
      const raw = env[k];
      if (["rounds", "intervalMs", "durationSec", "timeoutMs", "probeEvery", "resourceIntervalMs", "flushEvery", "maxConsecutiveFailures"].includes(v)) {
        args[v] = parseInt(raw, 10);
      } else if (v === "passRate" || v === "probePassRate") {
        args[v] = parseFloat(raw);
      } else args[v] = raw;
    }
  }

  const need = (name) => {
    const v = argv[++i];
    if (v === undefined) throw new Error(`missing value for ${name}`);
    return v;
  };
  let i = 0;
  for (; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "--rounds": args.rounds = parseInt(need(a), 10); break;
      case "--interval-ms": args.intervalMs = parseInt(need(a), 10); break;
      case "--duration-sec": args.durationSec = parseInt(need(a), 10); break;
      case "--timeout-ms": args.timeoutMs = parseInt(need(a), 10); break;
      case "--pass-rate": args.passRate = parseFloat(need(a)); break;
      case "--probe-pass-rate": args.probePassRate = parseFloat(need(a)); break;
      case "--message-file": args.messageFile = need(a); break;
      case "--auto-text": args.autoText = need(a); break;
      case "--hermes": args.hermesCmd = need(a); break;
      case "--session-mode": { const v = need(a); if (!["new", "same"].includes(v)) throw new Error("--session-mode: new|same"); args.sessionMode = v; break; }
      case "--probe-every": args.probeEvery = parseInt(need(a), 10); break;
      case "--probe-file": args.probeFile = need(a); break;
      case "--log-files": args.logFiles = need(a).split(",").map((s) => s.trim()).filter(Boolean); break;
      case "--log-poll-ms": args.logPollMs = parseInt(need(a), 10); break;
      case "--resource-interval-ms": args.resourceIntervalMs = parseInt(need(a), 10); break;
      case "--flush-every": args.flushEvery = parseInt(need(a), 10); break;
      case "--max-consecutive-failures": args.maxConsecutiveFailures = parseInt(need(a), 10); break;
      case "--resume-sid": args.resumeSid = need(a); break;
      case "--out": args.out = need(a); break;
      case "--env": args.env.push(need(a)); break;
      case "--quiet": args.quiet = true; break;
      case "-q": args.quiet = true; break;
      case "-h": case "--help": console.log(usage()); process.exit(0); break;
      default:
        throw new Error(`unknown option: ${a}（用 -h 查看全部参数）`);
    }
  }
  for (const n of ["rounds", "intervalMs", "durationSec", "timeoutMs", "probeEvery", "resourceIntervalMs", "flushEvery", "maxConsecutiveFailures"]) {
    if (!Number.isFinite(args[n]) || args[n] < 0) throw new Error(`invalid --${n}`);
  }
  if (args.sessionMode === "same" && args.resumeSid) args.sessionMode = "new"; // 显式 sid 优先
  return args;
}

function usage() {
  return `usage: soak.js [options]    (Hermes 版，结构对齐 openclaw-soak-tool/standalone-soak.mjs)

对话:   --rounds N / --interval-ms N / --duration-sec N / --timeout-ms N
        --message-file F（剧本，一行一轮）/ --auto-text T / --hermes CMD
会话:   --session-mode new|same（默认 new；same=首轮后 --resume 同一 session）
探针:   --probe-every N（每 N 轮: 第 N/2 轮植入、第 N 轮回忆核对）/ --probe-file F
监控:   --log-files a,b（增量收集 error/warn/memory-tdai 事件）
        --resource-interval-ms N（RSS/CPU/FD，0=关）
结果:   --pass-rate R / --probe-pass-rate R / --flush-every N
        --max-consecutive-failures N（0=关）
其他:   --out DIR / --env NAME=VAL / --quiet / -h
输出:   conversations.jsonl resources.jsonl log-events.jsonl probes.json
        meta.json report.txt meta-snapshot.json`;
}

// ===========================================================================
// 单轮结果判定（剔除 session_id/警告行；状态码需 HTTP/status 语境，防"403""500元"误判）
// ===========================================================================
const ERROR_PATTERNS = [
  /(?:^|\n)\s*(?:error|exception|traceback)/i,
  /\bHTTP[^\n]{0,20}?\b(401|402|403|404|408|409|422|429|500|502|503)\b/i,
  /\bstatus[^\n]{0,15}?\b(4\d\d|5\d\d)\b/i,
  /(?:error|failed)[^\n]{0,30}\b(4\d\d|5\d\d)\b/i,
  /invalid.{0,20}api[ _-]?key|api[ _-]?key.{0,30}(invalid|missing|not found|required|incorrect)/i,
  /(authentication|unauthorized|auth error)/i,
  /rate ?limit/i,
  /(connection|socket|network).{0,20}(refused|reset|closed|failed|error)|ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENOTFOUND/i,
  /timed? ?out after|operation timed out|timeout (error|occurred|while)/i,
  /failed to (connect|send|parse|process)/i,
];
const cleanAnsi = (s) => s.replace(/\x1b\[[0-9;]*m/g, "");
const noiseLine = (l) =>
  !l.startsWith("⚠") && !/^session_id:/i.test(l) && !/^[─=—]+$/.test(l) && !/^retrying/i.test(l);

function classifyRound(exitCode, stdout, stderr, timedOut) {
  if (timedOut) return "timeout";
  if (exitCode === null) return "spawn-error";
  if (exitCode !== 0) return "exit-" + String(exitCode);
  const blob = cleanAnsi(stdout + "\n" + stderr).split("\n").filter(noiseLine).join("\n");
  if (!blob.trim()) return "empty-reply";
  return ERROR_PATTERNS.some((re) => re.test(blob)) ? "error-reply" : "ok";
}

function replySnippet(stdout) {
  const lines = cleanAnsi(stdout).trim().split("\n").map((l) => l.trim()).filter(Boolean);
  const meaningful = lines.filter((l) => !l.startsWith("⚠") && !/^session_id:/i.test(l) && !/^[─=—]+$/.test(l));
  return (meaningful[meaningful.length - 1] || "").slice(0, 120);
}

function extractSessionId(stdout, stderr) {
  const m = cleanAnsi(stdout + "\n" + stderr).match(/session_id:\s*(\S+)/i);
  return m ? m[1] : null;
}

// ===========================================================================
// 日志监控（对齐参考 GatewayLogMonitor：2s 增量轮询 + error/warn/tdai 事件）
// ===========================================================================
class LogMonitor {
  constructor(files, pollMs) {
    this.files = (files || []).filter((f) => f && fs.existsSync(f));
    this.missing = (files || []).filter((f) => f && !fs.existsSync(f));
    this.pollMs = pollMs;
    this.offsets = new Map();
    this.events = [];
    this.errorCounts = new Map();
    this.warnCounts = new Map();
    this.totalErrors = 0;
    this.totalWarns = 0;
    this.memoryPatterns = [
      /\[tdai-gateway\]/, /\[memory-tdai\]/, /memory.tencentdb/, /memory_tencentdb/,
      /pipeline[-_]?(l1|l2|l3)|\[pipeline/i, /\[tool\] tdai_/, /Embedding/i, /VectorStore/, /warmup/i,
    ];
  }
  start() {
    for (const f of this.files) {
      try { this.offsets.set(f, fs.statSync(f).size); } catch { this.offsets.set(f, 0); }
    }
    if (this.missing.length) console.warn(`[soak] ⚠ 日志文件不存在，监控跳过: ${this.missing.join(", ")}`);
    if (!this.files.length) return;
    this._timer = setInterval(() => this._pollAll(), this.pollMs);
    this._pollAll();
  }
  stop() { if (this._timer) clearInterval(this._timer); }
  _pollAll() { for (const f of this.files) this._poll(f); }
  _poll(f) {
    try {
      const stat = fs.statSync(f);
      const off = this.offsets.get(f) || 0;
      if (stat.size <= off) return;
      const buf = Buffer.alloc(stat.size - off);
      const fd = fs.openSync(f, "r");
      fs.readSync(fd, buf, 0, buf.length, off);
      fs.closeSync(fd);
      this.offsets.set(f, stat.size);
      for (const line of buf.toString("utf8").split("\n")) {
        if (line.trim()) this._processLine(f, line);
      }
    } catch { /* 日志轮转/被删时忽略 */ }
  }
  _processLine(file, line) {
    const isError = /\berror\b/i.test(line) || /"level"\s*:\s*"error"/i.test(line);
    const isWarn = /\bwarn(ing)?\b/i.test(line) || /"level"\s*:\s*"warn"/i.test(line);
    const isMemory = this.memoryPatterns.some((p) => p.test(line));
    if (isError) {
      this.totalErrors++;
      const sig = line.replace(/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.\d]*(Z|[+-]\d+)?/g, "")
        .replace(/\b\d{5,}\b/g, "NNN").trim().slice(0, 120);
      this.errorCounts.set(sig, (this.errorCounts.get(sig) || 0) + 1);
    }
    if (isWarn) {
      this.totalWarns++;
      const sig = line.replace(/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[.\d]*(Z|[+-]\d+)?/g, "")
        .replace(/\b\d{5,}\b/g, "NNN").trim().slice(0, 120);
      this.warnCounts.set(sig, (this.warnCounts.get(sig) || 0) + 1);
    }
    if (isError || isWarn || isMemory) {
      const ev = { ts: nowIso(), level: isError ? "error" : isWarn ? "warn" : "info",
        tag: isMemory ? "memory-tdai" : "other", file: path.basename(file),
        line: line.length > 300 ? line.slice(0, 300) + "…" : line };
      this.events.push(ev);
      if (this.events.length > 5000) this.events = this.events.slice(-3000);
    }
  }
  summary() {
    const top = (m) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10)
      .map(([signature, count]) => ({ signature, count }));
    return {
      files: this.files,
      totalErrors: this.totalErrors, totalWarns: this.totalWarns,
      topErrors: top(this.errorCounts), topWarns: top(this.warnCounts),
      memoryEvents: this.events.filter((e) => e.tag === "memory-tdai").length,
      totalEvents: this.events.length,
    };
  }
}

// ===========================================================================
// 进程资源监控（对齐参考 ResourceMonitor：RSS/CPU/FD；纯 /proc 实现，容器内可用）
// ===========================================================================
class ResourceMonitor {
  constructor(intervalMs, outFile) {
    this.intervalMs = intervalMs;
    this.outFile = outFile;
    this.pid = null;
    this.desc = "self";
    this.snapshots = [];
    this.startTime = Date.now();
    this._prev = null; // {jiffies, ts}
    this._timer = null;
  }
  discoverGateway() {
    // 找 memory-tencentdb Gateway：node --import tsx .../gateway/server.ts
    try {
      for (const dirent of fs.readdirSync("/proc")) {
        if (!/^\d+$/.test(dirent)) continue;
        let cmdline = "";
        try { cmdline = fs.readFileSync(`/proc/${dirent}/cmdline`, "utf8"); } catch { continue; }
        if (cmdline.includes("server.ts") || cmdline.includes("memory-tencentdb")) {
          this.pid = Number(dirent);
          this.desc = "gateway(" + cmdline.split("\0").slice(-2).join(" ").slice(0, 60) + ")";
          return;
        }
      }
    } catch { /* ignore */ }
  }
  start() {
    if (this.intervalMs <= 0) return;
    this.discoverGateway();
    this._collect();
    this._timer = setInterval(() => this._collect(), this.intervalMs);
    console.log(`[soak] 资源监控启动 interval=${this.intervalMs}ms target=${this.desc}`);
  }
  stop() { if (this._timer) clearInterval(this._timer); }
  _collect() {
    let rssKb = 0, cpuPct = 0, fdCount = 0;
    const pid = this.pid;
    if (pid) {
      try {
        const status = fs.readFileSync(`/proc/${pid}/status`, "utf8");
        const m = status.match(/VmRSS:\s+(\d+)\s+kB/);
        if (m) rssKb = Number(m[1]);
      } catch { /* 进程退出 */ }
      try {
        const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
        const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
        const utime = Number(fields[11]), stime = Number(fields[12]); // 见 man proc: 偏移 14/15
        const now = Date.now();
        if (this._prev) {
          const dj = (utime + stime) - this._prev.jiffies;
          const dt = (now - this._prev.ts) / 1000;
          if (dt > 0) cpuPct = Math.round((dj / 100 / dt) * 1000) / 10; // HZ=100
        }
        this._prev = { jiffies: utime + stime, ts: now };
      } catch { /* ignore */ }
      try { fdCount = fs.readdirSync(`/proc/${pid}/fd`).length; } catch { /* ignore */ }
    } else {
      rssKb = Math.round(process.memoryUsage().rss / 1024);
    }
    const snap = { ts: nowIso(), rssKb, cpuPct, fdCount, elapsedSec: Math.round((Date.now() - this.startTime) / 1000) };
    this.snapshots.push(snap);
    if (this.outFile) {
      try { fs.appendFileSync(this.outFile, JSON.stringify(snap) + "\n"); } catch { /* ignore */ }
    }
    return snap;
  }
  summary() {
    if (!this.snapshots.length) return null;
    const rss = this.snapshots.map((s) => s.rssKb).filter((v) => v > 0);
    const cpu = this.snapshots.map((s) => s.cpuPct).filter((v) => v > 0);
    const fd = this.snapshots.map((s) => s.fdCount).filter((v) => v > 0);
    const last = this.snapshots[this.snapshots.length - 1];
    return {
      target: this.desc, pid: this.pid, snapshotCount: this.snapshots.length,
      durationSec: last.elapsedSec,
      rss: rss.length ? {
        initialMb: (rss[0] / 1024).toFixed(1), peakMb: (Math.max(...rss) / 1024).toFixed(1),
        finalMb: (rss[rss.length - 1] / 1024).toFixed(1),
        growthRatio: rss.length >= 2 ? (rss[rss.length - 1] / rss[0]).toFixed(2) + "x" : "N/A",
      } : null,
      cpu: cpu.length ? { avgPct: (cpu.reduce((a, b) => a + b, 0) / cpu.length).toFixed(1), peakPct: Math.max(...cpu).toFixed(1) } : null,
      fd: fd.length ? { initial: fd[0], peak: Math.max(...fd), final: fd[fd.length - 1] } : null,
    };
  }
}

// ===========================================================================
// 对话驱动（对齐参考 StandaloneSoakDriver.run() 的轮次编排）
// ===========================================================================
async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.out) args.out = "out-" + new Date().toISOString().replace(/[:T]/g, "").slice(0, 15);
  fs.mkdirSync(args.out, { recursive: true });

  const convLog = path.join(args.out, "conversations.jsonl");
  const resLog = path.join(args.out, "resources.jsonl");
  const evtLog = path.join(args.out, "log-events.jsonl");

  let script = null;
  if (args.messageFile) {
    script = fs.readFileSync(args.messageFile, "utf8").split("\n")
      .map((l) => l.replace(/\r$/, "")).filter((l) => l.trim());
    if (!script.length) throw new Error(`--message-file ${args.messageFile} 为空`);
  }

  let probes = [...RECALL_PROBES];
  if (args.probeFile) {
    probes = JSON.parse(fs.readFileSync(args.probeFile, "utf8"));
    if (!Array.isArray(probes) || !probes.length) throw new Error("--probe-file 需要非空数组");
  }

  const envExtra = {};
  for (const kv of args.env) {
    const idx = kv.indexOf("=");
    if (idx < 0) throw new Error(`--env 需要 NAME=VALUE: ${kv}`);
    envExtra[kv.slice(0, idx)] = kv.slice(idx + 1);
  }

  // 日志 & 资源监控（对齐参考：soak 全程旁路采集）
  const logMon = new LogMonitor(args.logFiles, args.logPollMs);
  logMon.start();
  const resMon = new ResourceMonitor(args.resourceIntervalMs, resLog);
  resMon.start();

  const tStart = Date.now();
  const startedAt = nowIso();
  let stopReason = "rounds";
  let earlyExitReason = null;
  let round = 0, consecutiveFailures = 0, successCount = 0, failureCount = 0;
  let totalSuccessDurationMs = 0;
  const successDurations = [];       // 有界，用于分位数
  const topErrors = new Map();
  const probeResults = [];
  const planted = [];                // 已植入、等待验证的探针队列
  let activeSid = args.resumeSid;    // session pinning（same 模式）
  let sidLost = false;

  const cfg = args;
  const flushJsonl = (file, obj) => fs.appendFileSync(file, JSON.stringify(obj) + "\n");
  const writeSnapshot = () => {
    try {
      fs.writeFileSync(path.join(args.out, "meta-snapshot.json"), JSON.stringify({
        _note: "Intermediate snapshot — 若进程被 kill，以此恢复最近状态",
        snapshotAt: nowIso(), startedAt, elapsedSeconds: Math.round((Date.now() - tStart) / 1000),
        sessionMode: cfg.sessionMode, sessionId: activeSid || null,
        round, successCount, failureCount,
        avgLatencyMs: successCount ? Math.round(totalSuccessDurationMs / successCount) : 0,
        consecutiveFailures, probeResults, earlyExitReason,
      }, null, 2) + "\n");
    } catch { /* ignore */ }
  };

  console.log(`[soak] start ts=${startedAt} rounds=${cfg.rounds} interval=${cfg.intervalMs}ms duration=${cfg.durationSec || "inf"}s timeout=${cfg.timeoutMs}ms sessionMode=${cfg.sessionMode} probeEvery=${cfg.probeEvery} hermes=${cfg.hermesCmd} out=${args.out}`);

  async function sendRound(message, label, category) {
    const t0 = Date.now();
    const childArgs = ["chat", "-q", message, "-Q"];
    if (cfg.sessionMode === "same" && activeSid) childArgs.push("--resume", activeSid);
    const proc = spawn(cfg.hermesCmd, childArgs, {
      env: { ...process.env, ...envExtra }, stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "", stderr = "";
    proc.stdout.on("data", (d) => (stdout += d));
    proc.stderr.on("data", (d) => (stderr += d));
    let timedOut = false;
    const killer = setTimeout(() => { timedOut = true; proc.kill("SIGKILL"); }, cfg.timeoutMs);
    const exitCode = await new Promise((resolve) => {
      proc.on("error", (e) => { stderr += `\n[spawn-error] ${e.message}`; resolve(null); });
      proc.on("close", (c) => resolve(c));
    });
    clearTimeout(killer);

    const latencyMs = Date.now() - t0;
    const status = classifyRound(exitCode, stdout, stderr, timedOut);
    const ok = status === "ok";
    const sid = extractSessionId(stdout, stderr);
    if (cfg.sessionMode === "same" && !activeSid && sid) activeSid = sid;
    if (cfg.sessionMode === "same" && activeSid && !sid && !sidLost) {
      sidLost = true;
      console.warn(`[soak] ⚠ 未能从输出解析 session_id（可能会话被重置），本轮起降级为新会话`);
    }
    fs.writeFileSync(path.join(args.out, "rounds", `round-${String(round).padStart(3, "0")}.out.txt`), stdout);
    fs.writeFileSync(path.join(args.out, "rounds", `round-${String(round).padStart(3, "0")}.err.txt`), stderr);

    const entry = {
      round, label, category, success: ok, status,
      durationMs: latencyMs, responseLength: stdout.length,
      reply_snippet: ok ? replySnippet(stdout) : "",
      error: ok ? null : (stderr.trim().slice(0, 200) || status),
      timestamp: nowIso(),
    };
    flushJsonl(convLog, entry);

    if (ok) {
      successCount++;
      totalSuccessDurationMs += latencyMs;
      successDurations.push(latencyMs);
      if (successDurations.length > 5000) successDurations.splice(0, successDurations.length - 5000);
      consecutiveFailures = 0;
    } else {
      failureCount++;
      consecutiveFailures++;
      const key = (entry.error || status).slice(0, 120);
      const ex = topErrors.get(key) || { count: 0, lastRound: 0 };
      ex.count++; ex.lastRound = round;
      topErrors.set(key, ex);
    }
    if (!cfg.quiet) {
      console.log(`[soak] #${round} ${ok ? "PASS" : "FAIL(" + status + ")"} [${label}] ${latencyMs}ms ${ok ? (entry.reply_snippet || "").slice(0, 50) : ""}`);
    }
    return { ok, status, latencyMs };
  }

  async function verifyProbe(probe) {
    const t0 = Date.now();
    console.log(`[soak] 🔍 探针验证 ${probe.id}: ${probe.recallQuestion.slice(0, 40)}...`);
    const r = await sendRound(probe.recallQuestion, `probe-verify-${probe.id}`, "probe");
    const durationMs = Date.now() - t0;
    // 从本轮输出取回复全文做关键词核对
    const f = path.join(args.out, "rounds", `round-${String(round).padStart(3, "0")}.out.txt`);
    const content = cleanAnsi(fs.readFileSync(f, "utf8")).toLowerCase();
    const found = probe.expectedKeywords.filter((kw) => content.includes(kw.toLowerCase()));
    const missing = probe.expectedKeywords.filter((kw) => !content.includes(kw.toLowerCase()));
    const recalled = found.length >= Math.ceil(probe.expectedKeywords.length / 2);
    const rec = { probeId: probe.id, recalled, foundKeywords: found, missingKeywords: missing,
      durationMs, conversationOk: r.ok, mode: cfg.sessionMode, timestamp: nowIso() };
    probeResults.push(rec);
    console.log(`[soak] 🔍 ${probe.id}: ${recalled ? "✅ RECALLED" : "❌ MISSED"} (${found.length}/${probe.expectedKeywords.length} keywords, ${durationMs}ms) missing=${missing.join(",")}`);
  }

  // 每轮输出目录
  fs.mkdirSync(path.join(args.out, "rounds"), { recursive: true });

  for (let r = 1; r <= cfg.rounds; r++) {
    const elapsedSec = (Date.now() - tStart) / 1000;
    if (cfg.durationSec > 0 && elapsedSec >= cfg.durationSec) {
      stopReason = `duration(${cfg.durationSec}s)`; break;   // 已执行 r-1 轮
    }
    if (cfg.maxConsecutiveFailures > 0 && consecutiveFailures >= cfg.maxConsecutiveFailures) {
      stopReason = `max-consecutive-failures(${cfg.maxConsecutiveFailures})`;
      earlyExitReason = `${consecutiveFailures} consecutive failures (threshold ${cfg.maxConsecutiveFailures}) — 疑似服务不可用，提前退出`;
      console.error(`[soak] 🛑 EARLY EXIT: ${earlyExitReason}`); break;
    }
    round = r;  // 本轮实际执行

    const isProbeRound = cfg.probeEvery > 0 && round % cfg.probeEvery === 0;
    if (isProbeRound && planted.length > 0) {
      const probe = planted.shift();
      await verifyProbe(probe);
    } else {
      const shouldPlant = cfg.probeEvery > 0 &&
        round % cfg.probeEvery === Math.floor(cfg.probeEvery / 2) &&
        planted.length < probes.length;
      if (shouldPlant) {
        const probe = probes[planted.length % probes.length];
        await sendRound(probe.plantMessage, `plant-${probe.id}`, "probe");
        planted.push(probe);
      } else if (script) {
        await sendRound(script[(round - 1) % script.length], `script-${(round - 1) % script.length + 1}`, "script");
      } else {
        const topic = TOPICS[(round - 1) % TOPICS.length];
        await sendRound(topic.message, topic.label, topic.category);
      }
    }

    if (round % 10 === 0) {
      const elapsed = Math.round((Date.now() - tStart) / 1000);
      console.log(`[soak] 📊 进度: round=${round}/${cfg.rounds} elapsed=${elapsed}s ok=${successCount} fail=${failureCount} avgLatency=${successCount ? Math.round(totalSuccessDurationMs / successCount) : 0}ms`);
    }
    if (round % cfg.flushEvery === 0) writeSnapshot();

    if (round < cfg.rounds) {
      const budget = cfg.durationSec > 0 ? cfg.durationSec * 1000 - (Date.now() - tStart) : Infinity;
      const wait = Math.min(cfg.intervalMs, Math.max(0, budget));
      if (wait > 0) await sleep(wait);
    }
  }

  logMon.stop();
  resMon.stop();
  writeSnapshot();
  const endedAt = nowIso();
  const durationMs = Date.now() - tStart;

  // 参考式统计（successDurations 只含成功轮）
  const sorted = [...successDurations].sort((a, b) => a - b);
  const latencyStats = sorted.length ? {
    min: sorted[0], max: sorted[sorted.length - 1],
    mean: Math.round(totalSuccessDurationMs / successCount),
    p50: percentile(sorted, 50), p90: percentile(sorted, 90),
    p95: percentile(sorted, 95), p99: percentile(sorted, 99),
  } : null;

  const failureRate = round > 0 ? (failureCount / round) * 100 : 0;
  const successRate = round > 0 ? successCount / round : 0;
  const verdict = round > 0 && successRate >= cfg.passRate ? "pass" : "fail";
  const byType = {};
  // 从 conversations.jsonl 汇总失败分类
  for (const line of fs.readFileSync(convLog, "utf8").trim().split("\n")) {
    if (!line.trim()) continue;
    const r = JSON.parse(line);
    if (!r.success) byType[r.status] = (byType[r.status] || 0) + 1;
  }

  const meta = {
    generator: "soak.js — Hermes 版，结构对齐 openclaw-soak-tool/standalone-soak.mjs",
    started_at: startedAt, ended_at: endedAt, duration_ms: durationMs,
    verdict, stop_reason: stopReason,
    params: {
      rounds: cfg.rounds, interval_ms: cfg.intervalMs, duration_sec: cfg.durationSec,
      timeout_ms: cfg.timeoutMs, pass_rate: cfg.passRate, session_mode: cfg.sessionMode,
      probe_every: cfg.probeEvery, message_source: args.messageFile ? path.basename(args.messageFile) : (cfg.autoText ? "auto-text" : "topic-pool"),
      hermes: cfg.hermesCmd, resource_interval_ms: cfg.resourceIntervalMs,
      log_files: cfg.logFiles || [], flush_every: cfg.flushEvery,
      max_consecutive_failures: cfg.maxConsecutiveFailures,
    },
    // 参考 standalone-soak.mjs 的同名字段
    totalRounds: round, successCount, failureCount,
    failureRate: failureRate.toFixed(1) + "%",
    earlyExitReason, sessionMode: cfg.sessionMode, sessionId: activeSid || null,
    latency: latencyStats,
    topErrors: [...topErrors.entries()].sort((a, b) => b[1].count - a[1].count).slice(0, 5)
      .map(([error, info]) => ({ error, count: info.count, lastRound: info.lastRound })),
    // 作业验收字段（pass/fail + 轮次/耗时统计）
    results: {
      total: round, passed: successCount, failed: failureCount,
      success_rate: Math.round(successRate * 1000) / 1000, failed_by_type: byType,
    },
    probes: probeResults.length ? {
      total: probeResults.length,
      recalled: probeResults.filter((r) => r.recalled).length,
      rate: (probeResults.filter((r) => r.recalled).length / probeResults.length * 100).toFixed(1) + "%",
      details: probeResults,
    } : null,
    resources: resMon.summary(),
    logs: logMon.summary(),
  };
  fs.writeFileSync(path.join(args.out, "meta.json"), JSON.stringify(meta, null, 2) + "\n");
  fs.writeFileSync(path.join(args.out, "probes.json"), JSON.stringify(probeResults, null, 2) + "\n");
  for (const ev of logMon.events) flushJsonl(evtLog, ev);

  // ---- 人类可读报告 ----
  const L = [];
  const bar = "═".repeat(64);
  L.push("╔" + bar + "╗");
  L.push("║        HERMES SOAK TEST REPORT (Hermes CLI headless)");
  L.push("╚" + bar + "╝");
  L.push(`  Duration:        ${(durationMs / 1000).toFixed(1)}s  (stop=${stopReason})`);
  L.push(`  Total rounds:    ${round}`);
  L.push(`  Successes:       ${successCount}`);
  L.push(`  Failures:        ${failureCount} (${meta.failureRate})`);
  L.push(`  Verdict:         ${verdict.toUpperCase()}  (threshold ${(cfg.passRate * 100).toFixed(0)}%)`);
  L.push("");
  L.push("  LATENCY (successful rounds)");
  if (latencyStats) {
    L.push(`  P50 (median):    ${fmt(latencyStats.p50)}`);
    L.push(`  P90:             ${fmt(latencyStats.p90)}`);
    L.push(`  P95:             ${fmt(latencyStats.p95)}`);
    L.push(`  P99:             ${fmt(latencyStats.p99)}`);
    L.push(`  max:             ${fmt(latencyStats.max)}`);
  }
  if (meta.probes) {
    L.push("");
    L.push("  RECALL PROBES (植入→回忆→关键词)");
    L.push(`  Total probes:    ${meta.probes.total}`);
    L.push(`  Recalled:        ${meta.probes.recalled}`);
    L.push(`  Recall rate:     ${meta.probes.rate}`);
  }
  if (meta.resources) {
    const r = meta.resources;
    L.push("");
    L.push(`  RESOURCES (${r.target})`);
    if (r.rss) L.push(`  RSS initial:     ${r.rss.initialMb} MB   peak: ${r.rss.peakMb} MB   growth: ${r.rss.growthRatio}`);
    if (r.cpu) L.push(`  CPU avg:         ${r.cpu.avgPct}%   peak: ${r.cpu.peakPct}%`);
    if (r.fd) L.push(`  FDs initial:     ${r.fd.initial}   peak: ${r.fd.peak}`);
  }
  if (meta.logs && meta.logs.files.length) {
    L.push("");
    L.push(`  LOG MONITOR (${meta.logs.files.join(", ")})`);
    L.push(`  errors: ${meta.logs.totalErrors}   warns: ${meta.logs.totalWarns}   memory-tdai events: ${meta.logs.memoryEvents}`);
  }
  L.push("");
  L.push("  round detail:");
  for (const line of fs.readFileSync(convLog, "utf8").trim().split("\n")) {
    if (!line.trim()) continue;
    const r = JSON.parse(line);
    L.push(`  #${String(r.round).padStart(3, " ")} ${r.success ? "PASS" : "FAIL"} ${String(r.status).padEnd(12)} ${String(r.durationMs).padStart(6)}ms ${(r.reply_snippet || r.error || "").slice(0, 70)}`);
  }
  L.push("");
  fs.writeFileSync(path.join(args.out, "report.txt"), L.join("\n") + "\n");

  console.log(`[soak] done. verdict=${verdict} total=${round} pass=${successCount} fail=${failureCount} rate=${(successRate * 100).toFixed(1)}% duration=${(durationMs / 1000).toFixed(1)}s`);
  console.log(`[soak] outputs: ${path.resolve(args.out)}/{conversations.jsonl,resources.jsonl,log-events.jsonl,probes.json,meta.json,report.txt}`);
  process.exit(verdict === "pass" ? 0 : 1);
}

main().catch((e) => {
  console.error("[soak] fatal:", e.message);
  process.exit(2);
});
