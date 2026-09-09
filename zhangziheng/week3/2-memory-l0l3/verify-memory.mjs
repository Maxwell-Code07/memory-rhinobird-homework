#!/usr/bin/env node

import fsp from "node:fs/promises"
import path from "node:path"
import process from "node:process"

function option(name, fallback) {
  const index = process.argv.indexOf(name)
  return index >= 0 ? process.argv[index + 1] : fallback
}

const dataDir = path.resolve(option("--data", "/opt/tdai-data"))
const outputDir = path.resolve(option("--output", "/workspace/advanced/evidence"))
const keyword = option("--keyword", "青松灯塔-7429")
const sessionKey = option("--session", "week3-memory-soak")
const gateway = option("--gateway", "http://127.0.0.1:8420")
const timeoutSeconds = Number(option("--timeout-seconds", "900"))

async function filesWithExtension(directory, extension) {
  try {
    const entries = await fsp.readdir(directory, { withFileTypes: true })
    return entries
      .filter((entry) => entry.isFile() && entry.name.endsWith(extension))
      .map((entry) => path.join(directory, entry.name))
  } catch {
    return []
  }
}

async function nonEmptyLineCount(files) {
  let count = 0
  for (const file of files) {
    const text = await fsp.readFile(file, "utf8")
    count += text.split(/\r?\n/u).filter((line) => line.trim()).length
  }
  return count
}

async function inspect() {
  const l0Files = await filesWithExtension(path.join(dataDir, "conversations"), ".jsonl")
  const l1Files = await filesWithExtension(path.join(dataDir, "records"), ".jsonl")
  const l2Files = await filesWithExtension(path.join(dataDir, "scene_blocks"), ".md")
  const personaPath = path.join(dataDir, "persona.md")
  let persona = ""
  try {
    persona = await fsp.readFile(personaPath, "utf8")
  } catch {}

  let recall = { query: keyword, ok: false, status: null, body: null, error: null }
  try {
    const response = await fetch(`${gateway}/recall`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: keyword, session_key: sessionKey }),
      signal: AbortSignal.timeout(15_000),
    })
    const text = await response.text()
    let body
    try {
      body = JSON.parse(text)
    } catch {
      body = text
    }
    recall = { query: keyword, ok: response.ok, status: response.status, body, error: null }
  } catch (error) {
    recall = { query: keyword, ok: false, status: null, body: null, error: error.message }
  }

  const l0Records = await nonEmptyLineCount(l0Files)
  const l1Records = await nonEmptyLineCount(l1Files)
  const recallMatched = recall.ok && JSON.stringify(recall.body).includes(keyword)
  const result = {
    checkedAt: new Date().toISOString(),
    dataDir,
    keyword,
    status:
      l0Records > 0 && l1Records > 0 && l2Files.length > 0 && persona.trim().length > 0 && recallMatched
        ? "pass"
        : "pending",
    l0: { nonEmpty: l0Records > 0, records: l0Records, files: l0Files },
    l1: { nonEmpty: l1Records > 0, records: l1Records, files: l1Files },
    l2: { nonEmpty: l2Files.length > 0, sceneFiles: l2Files.length, files: l2Files },
    l3: { nonEmpty: persona.trim().length > 0, personaBytes: Buffer.byteLength(persona), path: personaPath },
    recall: { matched: recallMatched, ...recall },
  }
  return result
}

await fsp.mkdir(outputDir, { recursive: true })
const deadline = Date.now() + timeoutSeconds * 1000
let result
do {
  result = await inspect()
  console.log(
    `[${result.checkedAt}] status=${result.status} L0=${result.l0.records} L1=${result.l1.records} ` +
      `L2=${result.l2.sceneFiles} L3=${result.l3.personaBytes}B recall=${result.recall.matched}`,
  )
  if (result.status === "pass") break
  await new Promise((resolve) => setTimeout(resolve, 10_000))
} while (Date.now() < deadline)

await fsp.writeFile(path.join(outputDir, "verification.json"), `${JSON.stringify(result, null, 2)}\n`, "utf8")
await fsp.writeFile(
  path.join(outputDir, "recall-result.json"),
  `${JSON.stringify(result.recall, null, 2)}\n`,
  "utf8",
)

console.log(JSON.stringify(result, null, 2))
process.exitCode = result.status === "pass" ? 0 : 1
