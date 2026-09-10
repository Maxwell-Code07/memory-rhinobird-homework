#!/usr/bin/env node
/**
 * Mock `hermes` CLI used ONLY by the soak unit tests (test/test-soak.mjs).
 * Simulates the subset of the real CLI that soak.mjs relies on:
 *
 *   mock-hermes --version            -> "Hermes Agent v0.20.4 (2026.8.18)"
 *   mock-hermes -z <prompt> --usage-file <path>
 *                                     -> writes usage JSON, prints "pong"
 *
 * Behavior knobs (env vars, read fresh on every invocation):
 *   MOCK_VER_DATE    version date printed in parentheses (default 2026.8.18)
 *   MOCK_SLEEP_MS    sleep this long before responding (tests timeouts)
 *   MOCK_EMPTY       exit 0 but print nothing (tests empty-response handling)
 *   MOCK_EXIT_CODE   exit with this code instead of 0 (tests non-zero handling)
 *   MOCK_FAIL_FIRST_N  fail (exit 1) for the first N -z calls, then succeed
 *   MOCK_STATE_DIR   dir for the invocation counter file (required by FAIL_FIRST_N)
 */
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { mkdirSync } from "node:fs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function nextCount(stateDir) {
  mkdirSync(stateDir, { recursive: true });
  const f = join(stateDir, "count.txt");
  let n = 0;
  try {
    n = Number(readFileSync(f, "utf8")) || 0;
  } catch { /* first call */ }
  const next = n + 1;
  writeFileSync(f, String(next), "utf8");
  return next;
}

const args = process.argv.slice(2);

if (args.includes("--version")) {
  const date = process.env.MOCK_VER_DATE || "2026.8.18";
  process.stdout.write(`Hermes Agent v0.20.4 (${date})\n`);
  process.exit(0);
}

// One-shot mode: -z <prompt> [--usage-file <path>]
const zIdx = args.indexOf("-z");
if (zIdx !== -1) {
  const prompt = args[zIdx + 1];
  const ufIdx = args.indexOf("--usage-file");
  const usageFile = ufIdx !== -1 ? args[ufIdx + 1] : null;

  // Env-driven failure modes
  if (process.env.MOCK_SLEEP_MS) await sleep(Number(process.env.MOCK_SLEEP_MS));
  const failFirstN = Number(process.env.MOCK_FAIL_FIRST_N || 0);
  let count = 1;
  if (failFirstN > 0) {
    count = nextCount(process.env.MOCK_STATE_DIR || process.env.TEMP || "/tmp");
  }
  if (usageFile) {
    try {
      writeFileSync(usageFile, JSON.stringify({
        model: "mock-model", provider: "mock", completed: true,
        failed: false, input_tokens: 10, output_tokens: 5, total_tokens: 15,
      }, null, 2));
    } catch { /* usage file is best-effort */ }
  }
  if (process.env.MOCK_EXIT_CODE) {
    process.exit(Number(process.env.MOCK_EXIT_CODE));
  }
  if (failFirstN > 0 && count <= failFirstN) {
    process.stderr.write("mock hermes: simulated failure\n");
    process.exit(1);
  }
  if (process.env.MOCK_EMPTY) {
    process.exit(0); // empty stdout
  }
  if (process.env.MOCK_ERROR_REPLY) {
    // Simulate `hermes -z` exiting 0 but printing an HTTP/auth error text.
    process.stdout.write("HTTP 401: not authorized\n");
    process.exit(0);
  }
  process.stdout.write(`pong:${prompt.slice(0, 12)}\n`);
  process.exit(0);
}

process.stderr.write("mock hermes: unknown args\n");
process.exit(2);
