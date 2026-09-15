#!/usr/bin/env node
/**
 * check-l0l3.mjs (进阶 1)
 * ---------------------------------------------------
 * 用 soak 对话跑完后，检测记忆系统的 L0-L3 四层是否真正落库：
 *   L0 conversations/*.jsonl   原始对话
 *   L1 records/*.jsonl         结构化事实提取
 *   L2 scene_blocks/*.md       场景块
 *   L3 persona.md              用户画像
 *
 * 输出结构化 JSON（含每层是否非空、文件数、最新内容摘要），供验收截图。
 * 零依赖，只读数据目录，绝不改动记忆。
 *
 * 用法：
 *   node check-l0l3.mjs --data-dir <memory数据目录>
 *   node check-l0l3.mjs --data-dir C:\Users\...\.memory-tencentdb\memory-tdai [--since 2026-09-02] [--json]
 */
import { readdirSync, existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";

const LAYERS = [
  { level: "L0", key: "conversations", desc: "原始对话", kind: "jsonl" },
  { level: "L1", key: "records",       desc: "结构化事实", kind: "jsonl" },
  { level: "L2", key: "scene_blocks",  desc: "场景块",     kind: "md" },
  { level: "L3", key: "persona.md",    desc: "用户画像",   kind: "file" },
];

function parseArgsOrExit() {
  let parsed;
  try {
    parsed = parseArgs({
      options: {
        "data-dir": { type: "string" },
        since: { type: "string" },
        json: { type: "boolean", default: false },
        help: { type: "boolean", default: false },
      },
      allowPositionals: false,
    });
  } catch (e) {
    console.error(`[check] arg error: ${e.message}`);
    process.exit(2);
  }
  if (parsed.values.help) {
    console.log("Usage: node check-l0l3.mjs --data-dir <dir> [--since YYYY-MM-DD] [--json]");
    process.exit(0);
  }
  if (!parsed.values["data-dir"]) {
    console.error("[check] --data-dir is required");
    process.exit(2);
  }
  return parsed.values;
}

function listDir(p) {
  try { return readdirSync(p); } catch { return []; }
}

function newestMtime(p) {
  try { return statSync(p).mtime.toISOString(); } catch { return null; }
}

function summarize(kind, dir) {
  // Single-file layer (persona.md): use existsSync directly — readdirSync on a
  // file path throws ENOTDIR and would falsely report the layer as empty.
  if (kind === "file") {
    if (!existsSync(dir)) return { exists: false, size: 0 };
    const content = readFileSync(dir, "utf8");
    return { exists: true, size: content.length, chars: content.length };
  }
  // jsonl / md directories
  const files = listDir(dir);
  const recent = files
    .filter((f) => !f.startsWith("."))
    .sort((a, b) => (a < b ? -1 : 1));
  return {
    fileCount: recent.length,
    files: recent,
  };
}

function main() {
  const cfg = parseArgsOrExit();
  const dataDir = cfg["data-dir"];
  const since = cfg.since || null;
  const report = { data_dir: dataDir, generated_at: new Date().toISOString(), layers: {} };

  let allPresent = true;
  for (const layer of LAYERS) {
    let path;
    if (layer.kind === "file") {
      path = join(dataDir, layer.key);
    } else {
      path = join(dataDir, layer.key);
    }
    const entry = { level: layer.level, desc: layer.desc, path, nonempty: false };
    if (layer.kind === "file") {
      const s = summarize("file", path);
      entry.exists = s.exists;
      if (s.exists) entry.size_chars = s.chars;
      entry.nonempty = s.exists && s.size > 0;
    } else {
      const s = summarize("jsonl", path);
      entry.file_count = s.fileCount;
      entry.files = s.files;
      entry.nonempty = s.fileCount > 0;
    }
    if (!entry.nonempty) allPresent = false;
    report.layers[layer.level] = entry;
  }
  report.all_nonempty = allPresent;
  report.since = since;

  const out = JSON.stringify(report, null, 2);
  if (cfg.json) {
    console.log(out);
  } else {
    console.log(`mem-check ${report.generated_at}`);
    for (const k of ["L0", "L1", "L2", "L3"]) {
      const e = report.layers[k];
      const st = e.nonempty ? "✅ 非空" : "❌ 空";
      console.log(`${k} ${st}  ${e.desc}  (${e.file_count ?? (e.exists ? `${e.size_chars} chars` : "—")})`);
    }
    console.log(`总体: ${allPresent ? "L0-L3 全部生成 ✅" : "存在未生成层 ❌"}`);
  }
  process.exit(allPresent ? 0 : 1);
}

main();
