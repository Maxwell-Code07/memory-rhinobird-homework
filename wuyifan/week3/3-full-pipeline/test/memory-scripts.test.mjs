import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const TEST_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_DIR = path.dirname(TEST_DIR);
const VERIFY_SCRIPT = path.join(PROJECT_DIR, "verify-memory.sh");
const INSTALL_SCRIPT = path.join(PROJECT_DIR, "install-memory.sh");
const CONFIG_PATH = path.join(PROJECT_DIR, "tdai-gateway.json");
const MARKER = "rhinobird-memory-lighthouse-0907";

async function runScript(script, args = []) {
  try {
    const result = await execFileAsync("bash", [script, ...args], {
      cwd: PROJECT_DIR,
      timeout: 10_000
    });
    return { ...result, exitCode: 0 };
  } catch (error) {
    return {
      stdout: error.stdout ?? "",
      stderr: error.stderr ?? "",
      exitCode: error.code
    };
  }
}

function createMemoryData({ includePersona = true } = {}) {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), "memory-proof-"));
  fs.mkdirSync(path.join(dataDir, "conversations"), { recursive: true });
  fs.mkdirSync(path.join(dataDir, "records"), { recursive: true });
  fs.mkdirSync(path.join(dataDir, "scene_blocks"), { recursive: true });
  fs.writeFileSync(
    path.join(dataDir, "conversations", "test.jsonl"),
    `${JSON.stringify({ content: MARKER })}\n`
  );
  fs.writeFileSync(
    path.join(dataDir, "records", "test.jsonl"),
    `${JSON.stringify({ content: `marker ${MARKER}` })}\n`
  );
  fs.writeFileSync(
    path.join(dataDir, "scene_blocks", "project.md"),
    `# Project\n\n${MARKER}\n`
  );
  if (includePersona) {
    fs.writeFileSync(
      path.join(dataDir, "persona.md"),
      `# Persona\n\n${MARKER}\n`
    );
  }
  return dataDir;
}

async function withRecallServer(callback) {
  const server = http.createServer((request, response) => {
    if (request.method !== "POST" || request.url !== "/recall") {
      response.writeHead(404).end();
      return;
    }
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      const parsed = JSON.parse(body);
      assert.equal(parsed.query, MARKER);
      assert.ok(parsed.session_key);
      response.writeHead(200, { "content-type": "application/json" });
      response.end(JSON.stringify({
        code: 0,
        context: `remembered ${MARKER}`,
        memory_count: 1,
        strategy: "keyword"
      }));
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  try {
    await callback(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

test("Gateway config uses short-cycle keyword recall without embeddings", () => {
  const config = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  assert.equal(config.memory.recall.strategy, "keyword");
  assert.equal(config.memory.embedding.enabled, false);
  assert.equal(config.memory.pipeline.enableWarmup, false);
  assert.equal(config.memory.pipeline.everyNConversations, 1);
  assert.ok(config.memory.pipeline.l1IdleTimeoutSeconds <= 10);
  assert.ok(config.memory.persona.triggerEveryN <= 2);
});

test("the first memory prompt carries the unique recall marker", () => {
  const prompts = JSON.parse(
    fs.readFileSync(path.join(PROJECT_DIR, "memory-prompts.json"), "utf8")
  );
  assert.match(prompts[0].prompt, new RegExp(MARKER));
});

test("memory scripts expose help without Docker side effects", async () => {
  for (const script of [INSTALL_SCRIPT, VERIFY_SCRIPT]) {
    const result = await runScript(script, ["--help"]);
    assert.equal(result.exitCode, 0, `${script}\n${result.stderr}`);
    assert.match(result.stdout, /用法|Usage/);
  }
});

test("install script keeps stdin open when sending its heredoc into Docker", () => {
  const source = fs.readFileSync(INSTALL_SCRIPT, "utf8");
  assert.match(source, /docker exec -i -u root/);
});

test("install script reuses the dependency tree resolved by the package install", () => {
  const source = fs.readFileSync(INSTALL_SCRIPT, "utf8");
  assert.match(source, /mv node_modules "\$plugin_dir\/node_modules"/);
  assert.doesNotMatch(source, /cd "\$plugin_dir"\s+npm install/s);
});

test("provider copy source remains anchored at the installed plugin root", () => {
  const source = fs.readFileSync(INSTALL_SCRIPT, "utf8");
  assert.match(
    source,
    /cp -R "\$plugin_dir\/hermes-plugin\/memory\/memory_tencentdb" "\$provider_dir"/
  );
});

test("npm package download retries transient network failures", () => {
  const source = fs.readFileSync(INSTALL_SCRIPT, "utf8");
  assert.match(source, /for attempt in 1 2 3/);
  assert.match(source, /npm install "\$\{package\}@\$\{version\}"/);
});

test("verification passes only when L0-L3 and recall all have evidence", async () => {
  const dataDir = createMemoryData();
  const outputPath = path.join(dataDir, "verification-summary.json");

  await withRecallServer(async (gatewayUrl) => {
    const result = await runScript(VERIFY_SCRIPT, [
      "--data-dir", dataDir,
      "--gateway-url", gatewayUrl,
      "--marker", MARKER,
      "--session-key", "test-session",
      "--output", outputPath
    ]);
    assert.equal(result.exitCode, 0, result.stderr);
  });

  const summary = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(summary.status, "pass");
  for (const layer of ["l0", "l1", "l2", "l3", "recall"]) {
    assert.equal(summary.checks[layer].status, "pass");
  }
});

test("verification fails and still writes a summary when L3 is missing", async () => {
  const dataDir = createMemoryData({ includePersona: false });
  const outputPath = path.join(dataDir, "verification-summary.json");

  await withRecallServer(async (gatewayUrl) => {
    const result = await runScript(VERIFY_SCRIPT, [
      "--data-dir", dataDir,
      "--gateway-url", gatewayUrl,
      "--marker", MARKER,
      "--session-key", "test-session",
      "--output", outputPath
    ]);
    assert.notEqual(result.exitCode, 0);
  });

  const summary = JSON.parse(fs.readFileSync(outputPath, "utf8"));
  assert.equal(summary.status, "fail");
  assert.equal(summary.checks.l3.status, "fail");
});
