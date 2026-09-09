#!/usr/bin/env node

/** Verify that TencentDB Agent Memory produced non-empty L0-L3 artifacts. */

import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, extname, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const HELP = `用法: node verify-memory.mjs [选项]

  --data-dir <目录>          memory-tdai 数据目录（必填）
  --gateway-url <URL>        默认 http://127.0.0.1:8420
  --query <文本>             /recall 查询文本
  --query-file <UTF-8文件>    从文件读取查询，避免 PowerShell 中文参数编码问题
  --expect <关键词>          召回结果必含关键词，可重复
  --session-key <值>         /recall session_key，默认 week3-memory-verification
  --gateway-api-key <值>     可选 Bearer token（也可用 TDAI_GATEWAY_API_KEY）
  --wait <时长>              等待异步 L1-L3 生成，默认 180s
  --poll <时长>              轮询间隔，默认 3s
  --output <JSON文件>        可选输出文件
  --help                     显示帮助
`;

function parseDuration(raw) {
  const match = String(raw).trim().match(/^(\d+(?:\.\d+)?)\s*(ms|s|m)?$/i);
  if (!match) throw new Error(`时长格式无效: ${raw}`);
  const factor = { ms: 1, s: 1000, m: 60_000 }[(match[2] || "s").toLowerCase()];
  return Math.round(Number(match[1]) * factor);
}

function parseArgs(argv) {
  const out = { expect: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--help" || token === "-h") { out.help = true; continue; }
    const value = argv[++i];
    if (value === undefined) throw new Error(`${token} 缺少值`);
    if (token === "--expect") {
      if (!value.trim()) throw new Error("--expect 不能为空");
      out.expect.push(value);
    }
    else if (token === "--data-dir") out.dataDir = value;
    else if (token === "--gateway-url") out.gatewayUrl = value;
    else if (token === "--query") out.query = value;
    else if (token === "--query-file") out.queryFile = value;
    else if (token === "--session-key") out.sessionKey = value;
    else if (token === "--gateway-api-key") out.gatewayApiKey = value;
    else if (token === "--wait") out.wait = value;
    else if (token === "--poll") out.poll = value;
    else if (token === "--output") out.output = value;
    else throw new Error(`未知选项: ${token}`);
  }
  if (!out.help && !out.dataDir) throw new Error("必须指定 --data-dir");
  if (out.query !== undefined && out.queryFile !== undefined) throw new Error("--query 与 --query-file 不能同时使用");
  if (out.queryFile !== undefined) out.query = new TextDecoder("utf-8", { fatal: true }).decode(readFileSync(out.queryFile)).trim();
  if (out.query !== undefined && !out.query.trim()) throw new Error("查询文本不能为空");
  return out;
}

function walkFiles(root) {
  if (!existsSync(root)) return [];
  const files = [];
  const stack = [root];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const full = join(current, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile()) files.push(full);
    }
  }
  return files;
}

function relativeFileInfo(root, files) {
  return files.map((file) => ({
    path: file.slice(root.length).replace(/^[/\\]+/, ""),
    bytes: statSync(file).size,
    modified_at: statSync(file).mtime.toISOString(),
    preview: readFileSync(file, "utf8").slice(0, 2800),
    preview_truncated: readFileSync(file, "utf8").length > 2800,
  }));
}

function nonEmptyFiles(root, predicate) {
  return walkFiles(root).filter((file) => statSync(file).size > 0 && predicate(file));
}

function countJsonlRows(files, layer) {
  let count = 0;
  let invalid = 0;
  for (const file of files) {
    for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
      if (!line.trim()) continue;
      try {
        const record = JSON.parse(line);
        const validMessage = (message) => message && ["user", "assistant"].includes(message.role)
          && typeof message.content === "string" && message.content.trim().length > 0;
        const valid = record && typeof record === "object" && !Array.isArray(record)
          && (layer === "L0"
            ? validMessage(record) || (Array.isArray(record.messages) && record.messages.length > 0 && record.messages.every(validMessage))
            : typeof record.content === "string" && record.content.trim().length > 0);
        if (valid) count += 1;
        else invalid += 1;
      } catch { invalid += 1; }
    }
  }
  return { records: count, invalid_records: invalid };
}

function hasMarkdownBody(file) {
  const body = readFileSync(file, "utf8")
    .replace(/^\uFEFF/, "")
    .replace(/\r\n/g, "\n")
    .split("---\n## 🗺️ Scene Navigation (Scene Index)")[0]
    .replace(/^---\s*\n[\s\S]*?\n---\s*(?:\n|$)/, "")
    .replace(/<scene-navigation>[\s\S]*?<\/scene-navigation>/gi, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .split("\n").filter((line) => !/^\s*#/.test(line)).join("\n");
  return /[\p{L}\p{N}]/u.test(body);
}

async function fetchJson(url, options, timeoutMs = 5000) {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(timeoutMs) });
  const text = await response.text();
  let body = null;
  try { body = JSON.parse(text); } catch { body = { raw: text }; }
  return { ok: response.ok, status: response.status, body };
}

export async function inspectOnce(cfg) {
  const dataDir = cfg.dataDir;
  const l0Files = nonEmptyFiles(join(dataDir, "conversations"), (file) => extname(file).toLowerCase() === ".jsonl");
  const l1Files = nonEmptyFiles(join(dataDir, "records"), (file) => extname(file).toLowerCase() === ".jsonl");
  const l2Files = [
    ...nonEmptyFiles(join(dataDir, "scene_blocks"), (file) => extname(file).toLowerCase() === ".md"),
    ...nonEmptyFiles(join(dataDir, "profiles"), (file) => relative(join(dataDir, "profiles"), file).split(/[/\\]/).includes("scene_blocks") && extname(file).toLowerCase() === ".md"),
  ];
  const l3Files = [join(dataDir, "persona.md")].filter((file) => existsSync(file) && statSync(file).isFile());
  const l0Rows = countJsonlRows(l0Files, "L0");
  const l1Rows = countJsonlRows(l1Files, "L1");
  const headers = { "content-type": "application/json" };
  if (cfg.gatewayApiKey) headers.authorization = `Bearer ${cfg.gatewayApiKey}`;
  let health = null;
  let recall = null;
  try {
    health = await fetchJson(`${cfg.gatewayUrl}/health`, { method: "GET", headers });
  } catch (error) {
    health = { ok: false, status: null, error: error.message };
  }
  try {
    recall = await fetchJson(`${cfg.gatewayUrl}/recall`, {
      method: "POST",
      headers,
      body: JSON.stringify({ query: cfg.query, session_key: cfg.sessionKey }),
    }, 15_000);
  } catch (error) {
    recall = { ok: false, status: null, error: error.message };
  }
  const recallText = typeof recall?.body?.context === "string" ? recall.body.context : "";
  const recallKeywords = cfg.expect.map((keyword) => ({ keyword, found: recallText.toLowerCase().includes(keyword.toLowerCase()) }));
  const recallPassed = Boolean(recall?.ok) && (recall.body?.code === undefined || recall.body.code === 0)
    && !recall.body?.error && recallText.trim().length > 0 && recallKeywords.every((item) => item.found);
  const result = {
    checked_at: new Date().toISOString(),
    data_dir: dataDir,
    evidence_scope: "Artifact structure and recall content only; freshness, source linkage and factual correctness require an isolated fresh run and inspection.",
    status: "fail",
    passed: false,
    layers: {
      L0: { passed: l0Rows.records > 0 && l0Rows.invalid_records === 0, ...l0Rows, files: relativeFileInfo(dataDir, l0Files) },
      L1: { passed: l1Rows.records > 0 && l1Rows.invalid_records === 0, ...l1Rows, files: relativeFileInfo(dataDir, l1Files) },
      L2: { passed: l2Files.some(hasMarkdownBody), files: relativeFileInfo(dataDir, l2Files) },
      L3: { passed: l3Files.some(hasMarkdownBody), files: relativeFileInfo(dataDir, l3Files) },
    },
    gateway: { health, recall: { passed: recallPassed, query: cfg.query, session_key: cfg.sessionKey, expected_keywords: recallKeywords, response: recall?.body ?? null, http_status: recall?.status ?? null } },
  };
  result.passed = Object.values(result.layers).every((layer) => layer.passed) && recallPassed && Boolean(health?.ok);
  result.status = result.passed ? "pass" : "fail";
  return result;
}

async function main() {
  let args;
  try { args = parseArgs(process.argv.slice(2)); }
  catch (error) {
    process.stderr.write(`[memory-verify] 参数错误: ${error.message}\n\n${HELP}`);
    return 2;
  }
  if (args.help) { process.stdout.write(HELP); return 0; }
  const cfg = {
    dataDir: resolve(args.dataDir),
    gatewayUrl: String(args.gatewayUrl ?? "http://127.0.0.1:8420").replace(/\/$/, ""),
    query: args.query ?? "我的职业、脚本语言偏好、周末习惯和生产部署约束是什么？",
    expect: args.expect,
    sessionKey: args.sessionKey ?? "week3-memory-verification",
    gatewayApiKey: args.gatewayApiKey ?? process.env.TDAI_GATEWAY_API_KEY ?? "",
    waitMs: parseDuration(args.wait ?? "180s"),
    pollMs: parseDuration(args.poll ?? "3s"),
    output: args.output ? resolve(args.output) : null,
  };
  const started = Date.now();
  let result;
  do {
    result = await inspectOnce(cfg);
    const states = Object.entries(result.layers).map(([name, layer]) => `${name}=${layer.passed ? "ok" : "empty"}`).join(" ");
    process.stderr.write(`[memory-verify] ${states} recall=${result.gateway.recall.passed ? "ok" : "miss"}\n`);
    if (result.passed || Date.now() - started >= cfg.waitMs) break;
    await new Promise((done) => setTimeout(done, cfg.pollMs));
  } while (true);
  result.waited_ms = Date.now() - started;
  if (cfg.output) {
    mkdirSync(dirname(cfg.output), { recursive: true });
    writeFileSync(cfg.output, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  }
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  return result.passed ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  process.exitCode = await main();
}
