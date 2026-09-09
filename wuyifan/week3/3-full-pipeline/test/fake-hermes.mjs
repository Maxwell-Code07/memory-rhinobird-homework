#!/usr/bin/env node

const SESSION_ID = "20260903_100000_test01";
const args = process.argv.slice(2);

const queryIndex = args.indexOf("-q");
const resumeIndex = args.indexOf("--resume");

if (queryIndex === -1 || !args[queryIndex + 1]) {
  console.error("fake-hermes: 缺少 -q 参数");
  process.exit(2);
}

if (resumeIndex === -1) {
  console.error(`session_id: ${SESSION_ID}`);
} else {
  const receivedSessionId = args[resumeIndex + 1];

  if (receivedSessionId !== SESSION_ID) {
    console.error(
      `fake-hermes: 错误的 session_id ${receivedSessionId}`
    );
    process.exit(3);
  }
}

const prompt = args[queryIndex + 1];

if (prompt === "SIMULATE_TIMEOUT") {
  setInterval(() => {}, 1000);
} else if (prompt === "SIMULATE_FAILURE") {
  console.error("fake-hermes: 模拟调用失败");
  process.exit(7);
} else {
  console.log(`模拟回答：${prompt}`);
}