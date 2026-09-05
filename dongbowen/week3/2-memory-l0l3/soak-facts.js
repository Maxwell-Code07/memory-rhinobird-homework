#!/usr/bin/env node
/**
 * soak-facts.js — 进阶1：富含事实的对话剧本
 *
 * 与 1-basic-soak/soak.js 同结构，但 prompt 池换成"富含可提取事实"的内容：
 *   姓名 / 职业 / 学校 / 爱好 / 偏好 / 习惯 / 强约束
 * 这样记忆系统的 L1（事实）/ L2（scene）/ L3（persona）才有内容可抽取。
 *
 * 用法：
 *   node soak-facts.js [--rounds 30] [--interval 1000] [--duration 600]
 *                     [--bad-key] [--prompt-file PATH]
 *                     [--base-url URL] [--api-key KEY]
 */

'use strict';

const fs   = require('fs');
const path = require('path');

// 直接 require 基础脚本提供的实现（parseArgs / oneTurn / summarize）
const base = require('../1-basic-soak/soak.js');

// ---------- 富含事实的剧本（30 条） ----------

const FACT_PROMPTS = [
  // 身份 / 工作 → L1 事实 / L3 persona
  '你好，我叫董博文，是一名 AI Agent 工程师，住在海南海口。',
  '我在腾讯犀牛鸟人才培养计划做 Hermes Agent 的相关项目。',
  '我的工作主要是做 AI 智能体和强化学习相关的研究。',
  '我是海南大学 2024 级本科生，专业是计算机科学与技术。',
  '我现在主修 Java，正在准备期末考试，同时也用 Python 做 AI 项目。',

  // 偏好 / 习惯 → L1 偏好 / L2 scene
  '我喜欢用 VSCode 写代码，主题是浅色的，字体用 Consolas。',
  '我的代码风格倾向于函数式，强调纯函数和不可变数据结构。',
  '我习惯用 GitHub Flow 做版本管理，提交信息写中文。',
  '我做笔记喜欢用 Markdown，标题用 ## 三级结构。',
  '我周末一般去图书馆或者咖啡厅，喜欢安静的编程环境。',

  // 项目经验 / 技能 → L1 经历 / L3 persona
  '我做过 ESG 智评通项目，是一个对企业 ESG 表现进行智能评估的系统，已在海南大学经管专业作为教学工具。',
  '我参与过腾讯开悟强化学习比赛，训练 AI Agent 在模拟环境中决策。',
  '我用 Python + PyTorch 做过 MLP 癌症预测模型，准确率超过 95%。',
  '我做了一个 AI 销售机器人项目，是校级立项，准备 2026 年申请升级省级。',
  '我会用 Docker 打包镜像，理解 docker build / run / exec 的区别。',

  // 学习 / 工具栈 → L1 偏好
  '我正在学离散数学下册，包括代数系统、群、环、域、布尔代数。',
  '我习惯用 DeepSeek API 作为大模型底座，性价比高、推理能力强。',
  '我日常工作流里用 Hermes Agent 跑本地 AI 任务，搭配 memory 插件做长期记忆。',
  '我的笔记软件用腾讯文档，在线协作方便，也方便给老师审阅。',
  '我学新东西喜欢看官方文档，辅以中文博客和动手实验。',

  // 强偏好 / 约束 → L1 强偏好
  '我沟通风格很直接，遇到问题会催进度，喜欢一次性完整输出，不要分批。',
  '我不喜欢低质量项目展示，项目经历里要突出成果，不要堆砌技术名词。',
  '我做简历坚持一页式布局，不写 GitHub 链接，不写学号和绩点。',
  '我做的所有文档都要附通俗解释和例子，纯定义没人看得懂。',
  '我给老师交作业的截图命名喜欢口语化风格，比如"01-自我介绍.png"。',

  // 校园 / 生活 → L2 scene 沉淀
  '我住在海南海口，海南大学是 211，学校环境很好，椰子树很多。',
  '我在准备 Java 期末考试，题型覆盖单选、判断、简答、程序阅读、程序设计。',
  '我的作息是晚上 22 点休息，早晨 7 点起床，中午会午休半小时。',
  '我喜欢听周杰伦的歌，写代码的时候放《七里香》效率最高。',
  '我每周跑步三次，每次 3 公里，目的是保持精力。',
];

function loadFactsPrompts(opts) {
  if (opts.promptFile) {
    const lines = fs.readFileSync(opts.promptFile, 'utf8')
      .split(/\r?\n/).map(s => s.trim()).filter(Boolean);
    if (lines.length === 0) throw new Error('--prompt-file 是空的');
    return lines;
  }
  return FACT_PROMPTS;
}

// ---------- 主流程 ----------

async function main() {
  const opts = base.parseArgs(process.argv);
  const prompts = loadFactsPrompts(opts);
  fs.mkdirSync(opts.outDir, { recursive: true });

  console.log('=== Hermes Soak (Facts Story · 进阶1) ===');
  console.log('base-url :', opts.baseUrl);
  console.log('model    :', opts.model);
  console.log('rounds   :', opts.rounds);
  console.log('interval :', opts.intervalMs, 'ms');
  console.log('duration :', opts.durationS, 's');
  console.log('out-dir  :', path.resolve(opts.outDir));
  console.log('bad-key  :', opts.badKey);
  console.log('prompts  :', prompts.length, '条（含事实）');

  const startedAt = Date.now();
  const turnStream = fs.createWriteStream(path.join(opts.outDir, 'turns.jsonl'), { flags: 'w' });
  const turns = [];

  for (let i = 0; i < opts.rounds; i++) {
    const t = await base.oneTurn(opts, prompts, i);
    turnStream.write(JSON.stringify(t) + '\n');
    turns.push(t);
    const tag = t.ok ? 'PASS' : 'FAIL';
    console.log(`[round ${String(t.round).padStart(3, ' ')}] ${tag} status=${t.status} ms=${t.ms} prompt="${t.prompt.slice(0, 28)}..."`);

    if (opts.durationS > 0 && (Date.now() - startedAt) / 1000 >= opts.durationS) {
      console.log(`(到 duration=${opts.durationS}s 上限，提前结束)`);
      break;
    }
    if (i + 1 < opts.rounds && opts.intervalMs > 0) {
      await new Promise(r => setTimeout(r, opts.intervalMs));
    }
  }
  turnStream.end();

  const summary = base.summarize(turns);
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
      prompt_source: opts.promptFile ? opts.promptFile : 'soak-facts.js 内置 30 条事实剧本',
    },
    summary,
    overall_pass: overallPass,
  };
  fs.writeFileSync(path.join(opts.outDir, 'meta.json'), JSON.stringify(meta, null, 2));

  const report = [
    'Hermes Soak Report (Facts Story · 进阶1)',
    '========================================',
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
    'prompt   : ' + (opts.promptFile || '内置 facts 池 (30 条)'),
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