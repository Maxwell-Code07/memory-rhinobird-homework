#!/usr/bin/env node
/**
 * Unit tests for soak.mjs using a mock `hermes` CLI.
 * No Docker / no real Hermes needed. Run:
 *   node test/test-soak.mjs
 */
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SOAK = join(ROOT, "soak.mjs");
const MOCK = join(ROOT, "test", "mock-hermes.cmd");

let passed = 0;
let failed = 0;
const failures = [];

function runSoak(extraArgs = [], env = {}, opts = {}) {
  const tmp = mkdtempSync(join(tmpdir(), "soak-test-"));
  const args = [
    SOAK,
    "--hermes", MOCK,
    "--rounds", "3",
    "--interval", "0",
    "--max-total-seconds", "60",
    "--usage-dir", tmp,
    "--result-file", join(tmp, "result.json"),
    ...extraArgs,
  ];
  const res = spawnSync(process.execPath, args, {
    encoding: "utf8",
    env: { ...process.env, ...env, MOCK_STATE_DIR: tmp },
    timeout: 30_000,
  });
  let verdict = null;
  try { verdict = JSON.parse(res.stdout); } catch { /* non-JSON stdout */ }
  return { res, verdict, tmp };
}

function check(name, cond, detail = "") {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    failures.push(name);
    console.log(`  ✗ ${name} ${detail}`);
  }
}

function cleanup(list) {
  for (const t of list) {
    try { rmSync(t.tmp, { recursive: true, force: true }); } catch { /* noop */ }
  }
}

const tmpDirs = [];
const run = (extra, env, opts) => {
  const t = runSoak(extra, env, opts);
  tmpDirs.push(t);
  return t;
};

// ---------------------------------------------------------------------------
console.log("T1 happy path: all rounds pass, version verified");
{
  const { res, verdict } = run(["--expected-version", "v2026.8.18"]);
  check("exit 0", res.status === 0, `status=${res.status}`);
  check("passed=true", verdict?.passed === true, JSON.stringify(verdict?.passed));
  check("rounds 3/3", verdict?.rounds?.executed === 3 && verdict?.rounds?.failed === 0);
  check("version verified", verdict?.hermes_version?.verified === true);
  check("version release date", verdict?.hermes_version?.releaseDate === "2026.8.18");
  check("termination completed", verdict?.termination_reason === "completed");
}

// ---------------------------------------------------------------------------
console.log("T2 version mismatch: expected v2026.7.7, installed 2026.8.18");
{
  const { res, verdict } = run(["--expected-version", "v2026.7.7"]);
  check("exit 1", res.status === 1, `status=${res.status}`);
  check("passed=false", verdict?.passed === false);
  check("version verified=false", verdict?.hermes_version?.verified === false);
}

// ---------------------------------------------------------------------------
console.log("T3 one round fails (exit 1), others pass");
{
  const { res, verdict } = run([], { MOCK_FAIL_FIRST_N: "1" });
  check("exit 1", res.status === 1);
  check("passed=false", verdict?.passed === false);
  check("rounds executed=3 failed=1", verdict?.rounds?.executed === 3 && verdict?.rounds?.failed === 1);
  check("failure recorded", Array.isArray(verdict?.failures) && verdict.failures.length === 1);
  check("failure round=1", verdict?.failures?.[0]?.round === 1);
}

// ---------------------------------------------------------------------------
console.log("T4 per-round timeout: mock sleeps 3s, timeout 1s");
{
  const { res, verdict } = run(["--per-round-timeout-ms", "1000"], { MOCK_SLEEP_MS: "3000" });
  check("exit 1", res.status === 1);
  check("passed=false", verdict?.passed === false);
  check("all 3 rounds failed", verdict?.rounds?.failed === 3);
  check("timeout error captured", /killed after 1000ms/.test(verdict?.failures?.[0]?.error ?? ""));
}

// ---------------------------------------------------------------------------
console.log("T5 empty response (exit 0, no stdout)");
{
  const { res, verdict } = run([], { MOCK_EMPTY: "1" });
  check("exit 1", res.status === 1);
  check("passed=false", verdict?.passed === false);
  check("empty-response error captured", /empty response/.test(verdict?.failures?.[0]?.error ?? ""));
}

// ---------------------------------------------------------------------------
console.log("T6 circuit breaker: abort after max-consecutive-failures");
{
  const { res, verdict } = run(
    ["--max-consecutive-failures", "2"],
    { MOCK_FAIL_FIRST_N: "99" },
  );
  check("exit 1", res.status === 1);
  check("termination max_consecutive_failures", verdict?.termination_reason === "max_consecutive_failures");
  check("executed=2 (aborted early)", verdict?.rounds?.executed === 2, `executed=${verdict?.rounds?.executed}`);
}

// ---------------------------------------------------------------------------
console.log("T7 max-total-seconds truncation: budget 1s, rounds take 2s each");
{
  const { res, verdict } = run(
    ["--max-total-seconds", "1", "--rounds", "5"],
    { MOCK_SLEEP_MS: "2000" },
  );
  check("exit 1 (incomplete soak)", res.status === 1);
  check("termination max_total_seconds_reached", verdict?.termination_reason === "max_total_seconds_reached");
  check("not all rounds executed", verdict?.rounds?.executed < 5, `executed=${verdict?.rounds?.executed}`);
  check("passed=false (incomplete)", verdict?.passed === false);
}

// ---------------------------------------------------------------------------
console.log("T8 result file written with valid JSON");
{
  const { res, verdict, tmp } = run([]);
  const { readFileSync } = await import("node:fs");
  const fileOk = (() => {
    try {
      const parsed = JSON.parse(readFileSync(join(tmp, "result.json"), "utf8"));
      return parsed.passed === true;
    } catch { return false; }
  })();
  check("result file exists & parsed", fileOk);
}

// ---------------------------------------------------------------------------
console.log("T9 invalid args rejected");
{
  const { res, verdict } = run(["--rounds", "abc"]);
  check("exit 2", res.status === 2, `status=${res.status}`);
  check("no verdict emitted", verdict === null);
}

// ---------------------------------------------------------------------------
console.log("T10 error-looking reply (HTTP 401) counted as failure, not OK");
{
  const { res, verdict } = run([], { MOCK_ERROR_REPLY: "1" });
  check("exit 1", res.status === 1, `status=${res.status}`);
  check("passed=false", verdict?.passed === false);
  check("all rounds failed (error reply)", verdict?.rounds?.failed === 3, `failed=${verdict?.rounds?.failed}`);
  check("failure mentions error", /looks like an error|401/.test(verdict?.failures?.[0]?.error ?? ""), verdict?.failures?.[0]?.error);
}

// ---------------------------------------------------------------------------
console.log("T11 multi-turn conversation: cycles a script, all rounds pass");
{
  const dir = mkdtempSync(join(tmpdir(), "soak-conv-"));
  const conv = join(dir, "conv.jsonl");
  writeFileSync(conv, "Hello, I am rainforest, a full-stack engineer.\nI prefer Rust and concise reviews.\n", "utf8");
  const r = runSoak(["--conversation", conv, "--rounds", "4"], {});
  check("exit 0 (cycles 2 turns over 4 rounds)", r.res.status === 0, `status=${r.res.status}`);
  check("passed=true", r.verdict?.passed === true);
  check("all 4 rounds executed/passed", r.verdict?.rounds?.executed === 4 && r.verdict?.rounds?.failed === 0, `ex=${r.verdict?.rounds?.executed} f=${r.verdict?.rounds?.failed}`);
  check("conversation_turns recorded", r.verdict?.config?.conversation_turns === 2, `turns=${r.verdict?.config?.conversation_turns}`);
  rmSync(dir, { recursive: true, force: true });
}

cleanup(tmpDirs);

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.log(`failures: ${failures.join(", ")}`);
  process.exit(1);
}
