import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_DIR = path.dirname(TEST_DIR);
const PIPELINE = path.join(PROJECT_DIR, "pipeline.sh");

function cleanEnvironment() {
  const env = { ...process.env };
  for (const key of [
    "HERMES_API_KEY",
    "HERMES_BASE_URL",
    "HERMES_MODEL",
    "TDAI_LLM_API_KEY",
    "TDAI_LLM_BASE_URL",
    "TDAI_LLM_MODEL",
    "SOAK_ENV_FILE"
  ]) {
    delete env[key];
  }
  env.SOAK_ENV_FILE = path.join(os.tmpdir(), "week3-env-does-not-exist");
  return env;
}

test("pipeline --help 不构建镜像且正常退出", () => {
  const result = spawnSync("bash", [PIPELINE, "--help"], {
    cwd: PROJECT_DIR,
    encoding: "utf8",
    env: cleanEnvironment()
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /用法|Usage/);
  assert.match(result.stdout, /--cleanup/);
});

test("缺少模型凭证时在 Docker 前失败并写出流水线汇总", () => {
  const outputDir = fs.mkdtempSync(
    path.join(os.tmpdir(), "pipeline-validation-")
  );
  try {
    const result = spawnSync(
      "bash",
      [
        PIPELINE,
        "--version", "0.19.0",
        "--output", outputDir
      ],
      {
        cwd: PROJECT_DIR,
        encoding: "utf8",
        env: cleanEnvironment()
      }
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /HERMES_API_KEY/);

    const summaryPath = path.join(outputDir, "pipeline-summary.json");
    assert.equal(fs.existsSync(summaryPath), true);
    const summary = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
    assert.equal(summary.status, "fail");
    assert.equal(summary.stages.build, "not_run");
    assert.match(summary.error, /HERMES_API_KEY/);
  } finally {
    fs.rmSync(outputDir, { recursive: true, force: true });
  }
});

test("pipeline 在读取结果 JSON 前把输出目录规范化为绝对路径", () => {
  const source = fs.readFileSync(PIPELINE, "utf8");
  assert.match(source, /OUTPUT_DIR="\$\(cd "\$OUTPUT_DIR" && pwd\)"/);
});
