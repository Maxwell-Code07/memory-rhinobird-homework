#!/usr/bin/env node
/**
 * soak.js — Hermes Agent 自动多轮对话脚本（week3 基础要求）
 *
 * 通过 Hermes 的 OpenAI 兼容 HTTP 接口（/v1/chat/completions）让 Hermes
 * 连续回答多轮问题，每轮记录状态、结构化输出 JSON 报告，遇到超时/鉴权
 * 失败/连接拒绝时落库为 fail，不让脚本崩溃。
 *
 * 用法：
 *   node soak.js [options]
 *
 * 参数（命令行 > 环境变量 > 默认值）：
 *   --rounds <n>          目标轮次（默认 30）
 *   --interval <ms>       每轮间隔毫秒（默认 1000）
 *   --duration <s>        总时长上限秒（默认 0 = 不限，到 duration 提前停）
 *   --model <name>        模型名（默认 hermes-agent）
 *   --base-url <url>      Hermes API Server（默认 http://127.0.0.1:8642/v1）
 *   --api-key <key>       本地 API Server Key（默认从 env HERMES_API_KEY 读）
 *   --prompt <text>       单一 prompt（默认用内置 20 条池轮换）
 *   --prompt-file <path>  每行一条 prompt（覆盖 --prompt）
 *   --out-dir <path>      输出目录（默认 ./soak-out/<ts>）
 *   --timeout-ms <ms>     单轮 HTTP 超时（默认 60000）
 *   --bad-key             故意用错 Key 演示容错
 *
 * 输出：
 *   <out-dir>/turns.jsonl   每行一轮结果
 *   <out-dir>/meta.json     元信息 + 总体 pass/fail + P50/P95
 *   <out-dir>/report.txt    人类可读汇总
 *
 * 退出码：
 *   0 = 至少一轮成功
 *   2 = 所有轮次都失败（用于验收 --bad-key 的演示）
 */

'use strict';

const fs    = require('fs');
const path  = require('path');
const http  = require('http');
const https = require('https');
const { URL } = require('url');

// ---------- 参数解析 ----------

function parseArgs(argv) {
  const env = process.env;
  const out = {
    rounds:     30,
    intervalMs: 1000,
    durationS:  0,
    model:      'hermes-agent',
    baseUrl:    env.HERMES_BASE_URL || 'http://127.0.0.1:8642/v1',
    apiKey:     env.HERMES_API_KEY || 'soak-test-key-2026-dongbowen-dbrh',
    prompt:     null,
    promptFile: null,
    outDir:     null,
    timeoutMs:  60000,
    badKey:     false,
  };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    const v = argv[i + 1];
    switch (k) {
      case '--rounds':      out.rounds = parseInt(v, 10); i++; break;
      case '--interval':    out.intervalMs = parseInt(v, 10); i++; break;
      case '--duration':    out.durationS = parseInt(v, 10); i++; break;
      case '--model':       out.model = v; i++; break;
      case '--base-url':    out.baseUrl = v; i++; break;
      case '--api-key':     out.apiKey = v; i++; break;
      case '--prompt':      out.prompt = v; i++; break;
      case '--prompt-file': out.promptFile = v; i++; break;
      case '--out-dir':     out.outDir = v; i++; break;
      case '--timeout-ms':  out.timeoutMs = parseInt(v, 10); i++; break;
      case '--bad-key':     out.badKey = true; break;
      case '-h':
      case '--help':
        console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0]);
        process.exit(0);
    }
  }
  if (!out.apiKey)  out.apiKey  = env.HERMES_API_KEY || '';
  if (out.badKey)   out.apiKey  = 'definitely-wrong-key-' + Date.now();
  if (!out.outDir)  out.outDir  = path.join('soak-out', String(Date.now()));
  return out;
}

// ---------- 默认 prompt 池（20 条） ----------

const DEFAULT_PROMPTS = [
  '你好，自我介绍下你是谁？',
  '今天天气不错，你最近在忙什么？',
  '你觉得什么样的程序员是好程序员？',
  '推荐一本你读过的书给我。',
  '如果让你选一个超能力，你会选什么？',
  '解释一下什么是 API Gateway。',
  '你说说 Hermes Agent 主要做什么？',
  '用一句话总结强化学习的核心思想。',
  '如果你能去世界上任何一个城市，你会去哪里？',
  '给我讲一个冷知识。',
  '工作了一天，你通常怎么放松？',
  '你对未来 5 年 AI 怎么看？',
  '如何向 5 岁小孩解释神经网络？',
  '写一段 Python 快速排序代码。',
  '解释一下 Docker 镜像和容器的区别。',
  '推荐一部适合周末看的电影。',
  '什么是离散数学里的群？',
  '你喜欢猫还是狗？',
  '给我出一道脑筋急转弯。',
  '如果只能保留一种编程语言，你选哪个？',
];

function loadPrompts(opts) {
  if (opts.promptFile) {
    const lines = fs.readFileSync(opts.promptFile, 'utf8')
      .split(/\r?\n/).map(s => s.trim()).filter(Boolean);
    if (lines.length === 0) throw new Error('--prompt-file 是空的');
    return lines;
  }
  if (opts.prompt) return [opts.prompt];
  return DEFAULT_PROMPTS;
}

// ---------- HTTP 调用（零依赖） ----------

function postJson({ baseUrl, apiKey, body, timeoutMs }) {
  return new Promise((resolve) => {
    let u;
    try { u = new URL(baseUrl); }
    catch (e) { return resolve({ ok: false, status: 0, error: 'bad-url: ' + e.message, ms: 0 }); }

    const lib  = u.protocol === 'https:' ? https : http;
    const data = Buffer.from(JSON.stringify(body));
    const start = Date.now();

    const req = lib.request({
      method: 'POST',
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname.replace(/\/?$/, '/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + apiKey,
        'Content-Length': data.length,
      },
      timeout: timeoutMs,
    }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const ms = Date.now() - start;
        const status = res.statusCode || 0;
        const text = Buffer.concat(chunks).toString('utf8');
        if (status >= 200 && status < 300) {
          let parsed = null;
          try { parsed = JSON.parse(text); }
          catch (e) { return resolve({ ok: false, status, error: 'bad-json', raw: text.slice(0, 500), ms }); }
          const msg = parsed && parsed.choices && parsed.choices[0]
            && parsed.choices[0].message && parsed.choices[0].message.content || '';
          resolve({ ok: true, status, ms, reply: msg, usage: parsed.usage || null, id: parsed.id || null });
        } else {
          resolve({ ok: false, status, error: 'http-' + status, raw: text.slice(0, 500), ms });
        }
      });
    });
    req.on('timeout', () => { req.destroy(new Error('timeout')); });
    req.on('error', (e) => {
      resolve({ ok: false, status: 0, error: e.code || e.message, ms: Date.now() - start });
    });
    req.write(data);
    req.end();
  });
}

// ---------- 单轮对话 ----------

async function oneTurn(opts, prompts, idx) {
  const prompt = prompts[idx % prompts.length];
  const r = await postJson({
    baseUrl: opts.baseUrl,
    apiKey: opts.apiKey,
    body: { model: opts.model, messages: [{ role: 'user', content: prompt }], stream: false },
    timeoutMs: opts.timeoutMs,
  });
  return {
    round: idx + 1,
    ts: new Date().toISOString(),
    prompt,
    ok: !!r.ok,
    status: r.status,
    ms: r.ms,
    reply: r.reply || null,
    error: r.error || null,
    raw:   r.raw || null,
    usage: r.usage || null,
    id:    r.id || null,
  };
}

// ---------- 汇总 ----------

function summarize(turns) {
  const ok   = turns.filter(t => t.ok);
  const fail = turns.filter(t => !t.ok);
  const lats = ok.map(t => t.ms).sort((a, b) => a - b);
  const pct = (p) => {
    if (lats.length === 0) return 0;
    const i = Math.min(lats.length - 1, Math.floor((p / 100) * lats.length));
    return lats[i];
  };
  const errByStatus = {};
  for (const t of fail) {
    const k = String(t.status || t.error || 'unknown');
    errByStatus[k] = (errByStatus[k] || 0) + 1;
  }
  return {
    total: turns.length,
    pass: ok.length,
    fail: fail.length,
    pass_rate: turns.length === 0 ? 0 : Number((ok.length / turns.length).toFixed(4)),
    latency_p50_ms: pct(50),
    latency_p95_ms: pct(95),
    latency_max_ms: lats.length === 0 ? 0 : lats[lats.length - 1],
    error_breakdown: errByStatus,
  };
}

module.exports = { parseArgs, loadPrompts, postJson, oneTurn, summarize };

// ---------- 主流程（CLI 入口） ----------

async function main() {
  const opts = parseArgs(process.argv);
  fs.mkdirSync(opts.outDir, { recursive: true });
  const prompts = loadPrompts(opts);

  console.log('=== Hermes Soak ===');
  console.log('base-url :', opts.baseUrl);
  console.log('model    :', opts.model);
  console.log('rounds   :', opts.rounds);
  console.log('interval :', opts.intervalMs, 'ms');
  console.log('duration :', opts.durationS, 's');
  console.log('out-dir  :', path.resolve(opts.outDir));
  console.log('bad-key  :', opts.badKey);
  console.log('prompts  :', prompts.length, '条');

  const startedAt = Date.now();
  const turnStream = fs.createWriteStream(path.join(opts.outDir, 'turns.jsonl'), { flags: 'w' });
  const turns = [];

  for (let i = 0; i < opts.rounds; i++) {
    const t = await oneTurn(opts, prompts, i);
    turnStream.write(JSON.stringify(t) + '\n');
    turns.push(t);
    const tag = t.ok ? 'PASS' : 'FAIL';
    console.log(`[round ${String(t.round).padStart(3, ' ')}] ${tag} status=${t.status} ms=${t.ms} prompt="${t.prompt.slice(0, 24)}..."`);
    if (t.error) console.log(`             error: ${t.error}`);

    if (opts.durationS > 0 && (Date.now() - startedAt) / 1000 >= opts.durationS) {
      console.log(`(到 duration=${opts.durationS}s 上限，提前结束)`);
      break;
    }
    if (i + 1 < opts.rounds && opts.intervalMs > 0) {
      await new Promise(r => setTimeout(r, opts.intervalMs));
    }
  }
  turnStream.end();

  const summary = summarize(turns);
  const elapsedMs = Date.now() - startedAt;
  const overallPass = (summary.fail === 0 && summary.pass > 0) ? 'pass' :
                      (summary.pass === 0 ? 'fail' : 'partial');
  const exitCode = summary.pass === 0 ? 2 : 0;

  const meta = {
    started_at: new Date(startedAt).toISOString(),
    finished_at: new Date().toISOString(),
    elapsed_ms: elapsedMs,
    config: {
      base_url: opts.baseUrl,
      model: opts.model,
      rounds_target: opts.rounds,
      interval_ms: opts.intervalMs,
      duration_s: opts.durationS,
      timeout_ms: opts.timeoutMs,
      bad_key: opts.badKey,
    },
    summary,
    overall_pass: overallPass,
  };
  fs.writeFileSync(path.join(opts.outDir, 'meta.json'), JSON.stringify(meta, null, 2));

  const report = [
    'Hermes Soak Report',
    '==================',
    'started  : ' + meta.started_at,
    'finished : ' + meta.finished_at,
    'elapsed  : ' + (elapsedMs / 1000).toFixed(2) + 's',
    '',
    'Summary',
    '-------',
    'overall  : ' + overallPass,
    'total    : ' + summary.total,
    'pass     : ' + summary.pass,
    'fail     : ' + summary.fail,
    'pass_rate: ' + (summary.pass_rate * 100).toFixed(1) + '%',
    'p50 ms   : ' + summary.latency_p50_ms,
    'p95 ms   : ' + summary.latency_p95_ms,
    'max ms   : ' + summary.latency_max_ms,
    'errors   : ' + JSON.stringify(summary.error_breakdown),
    '',
    'Config',
    '------',
    'base_url : ' + opts.baseUrl,
    'model    : ' + opts.model,
    'rounds   : ' + opts.rounds,
    'interval : ' + opts.intervalMs + ' ms',
    'duration : ' + opts.durationS + ' s',
    'bad_key  : ' + opts.badKey,
  ].join('\n');
  fs.writeFileSync(path.join(opts.outDir, 'report.txt'), report);

  console.log('\n' + report);
  console.log('\nDone. exit=' + exitCode);
  process.exit(exitCode);
}

if (require.main === module) {
  main().catch((e) => {
    console.error('FATAL:', e && e.stack || e);
    process.exit(3);
  });
}