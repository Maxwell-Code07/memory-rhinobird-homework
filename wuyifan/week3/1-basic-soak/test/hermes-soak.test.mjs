import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));
const SOAK_SCRIPT = path.resolve(TEST_DIR, "../hermes-soak.mjs");
const FAKE_HERMES = path.join(TEST_DIR, "fake-hermes.mjs");
const TIMEOUT_PROMPTS = path.join(
  TEST_DIR,
  "timeout-prompts.json"
);
const FAILURE_PROMPTS = path.join(
  TEST_DIR,
  "failure-prompts.json"
);

test("--help 显示三个核心参数并正常退出", () => {
  const result = spawnSync(
    process.execPath,
    [SOAK_SCRIPT, "--help"],
    { encoding: "utf8" }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /--rounds/);
  assert.match(result.stdout, /--interval/);
  assert.match(result.stdout, /--duration/);
});

test("拒绝不是正整数的对话轮数", () => {
  const result = spawnSync(
    process.execPath,
    [SOAK_SCRIPT, "--rounds", "0"],
    { encoding: "utf8" }
  );

  assert.equal(result.status, 2);
  assert.match(result.stderr, /--rounds.*正整数/);
});

test("接受轮数、间隔和总时长三个核心参数", () => {
  const result = spawnSync(
    process.execPath,
    [
      SOAK_SCRIPT,
      "--rounds", "3",
      "--interval", "0",
      "--duration", "1.5"
    ],
    { encoding: "utf8" }
  );

  assert.equal(result.status, 0, result.stderr);
});

test("拒绝负数对话间隔", () => {
  const result = spawnSync(
    process.execPath,
    [SOAK_SCRIPT, "--interval", "-1"],
    { encoding: "utf8" }
  );

  assert.equal(result.status, 2);
  assert.match(result.stderr, /--interval.*非负整数/);
});

test("拒绝不大于零的总时长", () => {
  const result = spawnSync(
    process.execPath,
    [SOAK_SCRIPT, "--duration", "0"],
    { encoding: "utf8" }
  );

  assert.equal(result.status, 2);
  assert.match(result.stderr, /--duration.*正数/);
});

test("剧本文件不存在时给出明确错误", () => {
  const missingFile = path.join(
    TEST_DIR,
    "missing-prompts.json"
  );

  const result = spawnSync(
    process.execPath,
    [
      SOAK_SCRIPT,
      "--prompts", missingFile
    ],
    { encoding: "utf8" }
  );

  assert.equal(result.status, 2);
  assert.match(result.stderr, /剧本文件不存在/);
});

test("自动完成两轮并恢复同一个 Hermes 会话", () => {
  const result = spawnSync(
    process.execPath,
    [
      SOAK_SCRIPT,
      "--rounds", "2",
      "--interval", "0",
      "--duration", "10",
      "--hermes-command", FAKE_HERMES
    ],
    { encoding: "utf8" }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\[round 1\/2\] pass/);
  assert.match(result.stdout, /\[round 2\/2\] pass/);
  assert.match(
    result.stdout,
    /session_id=20260903_100000_test01/
  );
});

test("--container 通过 docker exec 驱动容器内 Hermes", () => {
  const fakeBinDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "fake-docker-bin-")
  );
  const fakeDocker = path.join(fakeBinDir, "docker");
  const outputDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "hermes-container-test-")
  );
  const dockerSource = `#!/usr/bin/env node
import { spawnSync } from "node:child_process";
const args = process.argv.slice(2);
if (args[0] !== "exec" || args[1] !== "test-container" || args[2] !== "hermes") {
  console.error("unexpected docker args: " + JSON.stringify(args));
  process.exit(9);
}
const result = spawnSync(${JSON.stringify(process.execPath)}, [${JSON.stringify(FAKE_HERMES)}, ...args.slice(3)], { stdio: "inherit" });
process.exit(result.status ?? 1);
`;

  try {
    fs.writeFileSync(fakeDocker, dockerSource, { mode: 0o755 });
    const result = spawnSync(
      process.execPath,
      [
        SOAK_SCRIPT,
        "--rounds", "2",
        "--interval", "0",
        "--duration", "10",
        "--output", outputDir,
        "--container", "test-container"
      ],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${fakeBinDir}${path.delimiter}${process.env.PATH}`
        }
      }
    );

    assert.equal(result.status, 0, result.stderr);
    const summary = JSON.parse(
      fs.readFileSync(path.join(outputDir, "summary.json"), "utf8")
    );
    assert.equal(summary.sessionId, "20260903_100000_test01");
    assert.equal(summary.container, "test-container");
  } finally {
    fs.rmSync(fakeBinDir, { recursive: true, force: true });
    fs.rmSync(outputDir, { recursive: true, force: true });
  }
});

test("Hermes 无响应时记录 timeout 并结束", () => {
  const result = spawnSync(
    process.execPath,
    [
      SOAK_SCRIPT,
      "--rounds", "1",
      "--interval", "0",
      "--duration", "5",
      "--timeout", "0.05",
      "--prompts", TIMEOUT_PROMPTS,
      "--hermes-command", FAKE_HERMES
    ],
    {
      encoding: "utf8",
      timeout: 2000
    }
  );

  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stdout, /\[round 1\/1\] fail/);
  assert.match(result.stdout, /errorType=timeout/);
});

test("成功运行后生成 JSONL、summary.json 和 report.txt", () => {
  const outputDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "hermes-soak-test-")
  );

  try {
    const result = spawnSync(
      process.execPath,
      [
        SOAK_SCRIPT,
        "--rounds", "2",
        "--interval", "0",
        "--duration", "10",
        "--output", outputDir,
        "--hermes-command", FAKE_HERMES
      ],
      { encoding: "utf8" }
    );

    assert.equal(result.status, 0, result.stderr);

    const conversationsPath = path.join(
      outputDir,
      "conversations.jsonl"
    );
    const summaryPath = path.join(
      outputDir,
      "summary.json"
    );
    const reportPath = path.join(
      outputDir,
      "report.txt"
    );

    assert.equal(fs.existsSync(conversationsPath), true);
    assert.equal(fs.existsSync(summaryPath), true);
    assert.equal(fs.existsSync(reportPath), true);

    const conversationLines = fs
      .readFileSync(conversationsPath, "utf8")
      .trim()
      .split("\n");

    assert.equal(conversationLines.length, 2);

    const firstRound = JSON.parse(conversationLines[0]);
    assert.equal(firstRound.round, 1);
    assert.equal(firstRound.status, "pass");
    assert.equal(
      firstRound.sessionId,
      "20260903_100000_test01"
    );
    assert.equal(typeof firstRound.latencyMs, "number");

    const summary = JSON.parse(
      fs.readFileSync(summaryPath, "utf8")
    );

    assert.equal(summary.status, "pass");
    assert.equal(summary.completedRounds, 2);
    assert.equal(summary.successfulRounds, 2);
    assert.equal(summary.failedRounds, 0);
    assert.equal(typeof summary.elapsedMs, "number");
    assert.equal(typeof summary.latencyMs.p50, "number");

    const report = fs.readFileSync(
      reportPath,
      "utf8"
    );

    assert.match(report, /Status:\s+pass/);
    assert.match(report, /Completed rounds:\s+2/);
  } finally {
    fs.rmSync(outputDir, {
      recursive: true,
      force: true
    });
  }
});
test("连续失败达到阈值后提前停止", () => {
  const outputDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "hermes-soak-failure-")
  );

  try {
    const result = spawnSync(
      process.execPath,
      [
        SOAK_SCRIPT,
        "--rounds", "5",
        "--interval", "0",
        "--duration", "10",
        "--timeout", "1",
        "--max-consecutive-failures", "2",
        "--prompts", FAILURE_PROMPTS,
        "--output", outputDir,
        "--hermes-command", FAKE_HERMES
      ],
      { encoding: "utf8" }
    );

    assert.equal(result.status, 1, result.stderr);

    const summary = JSON.parse(
      fs.readFileSync(
        path.join(outputDir, "summary.json"),
        "utf8"
      )
    );

    assert.equal(summary.status, "fail");
    assert.equal(summary.completedRounds, 2);
    assert.equal(summary.failedRounds, 2);
    assert.equal(
      summary.stopReason,
      "consecutive_failure_limit"
    );
  } finally {
    fs.rmSync(outputDir, {
      recursive: true,
      force: true
    });
  }
});
