import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
const newline = String.fromCharCode(10);
const [mode, root, output] = process.argv.slice(2);
const walk = directory => readdirSync(directory, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? walk(join(directory, entry.name)) : [join(directory, entry.name)]);
if (mode === 'recall') {
  const request = { query: '我的职业、脚本语言偏好、周末习惯和生产部署约束是什么？', session_key: 'independent-' + Date.now() };
  const response = await fetch(root + '/recall', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(request), signal: AbortSignal.timeout(30000) });
  const body = await response.json();
  const context = typeof body.context === 'string' ? body.context : '';
  const keywords = ['LinXiao', 'Python', 'PowerShell'].map(keyword => ({ keyword, found: context.includes(keyword) }));
  const passed = response.ok && !body.error && (body.code === undefined || body.code === 0) && keywords.every(item => item.found);
  const result = { collected_at: new Date().toISOString(), http_status: response.status, request, response: body, keywords, passed };
  if (output) writeFileSync(output, JSON.stringify(result, null, 2) + newline);
  console.log('POST /recall HTTP', response.status, 'new session:', request.session_key);
  console.log('Query:', request.query);
  console.log('Actual recall excerpt (first 300 characters):' + newline + context.slice(0, 300));
  for (const keyword of ['Python', 'PowerShell', '周五']) {
    const index = context.indexOf(keyword);
    console.log('Raw context excerpt around ' + keyword + ':', index < 0 ? 'NOT FOUND' : context.slice(Math.max(0, index - 45), index + 100).split(newline).join(' '));
  }
  console.log(JSON.stringify(keywords));
  console.log('INDEPENDENT_RECALL=' + (passed ? 'PASS' : 'FAIL'));
  process.exitCode = passed ? 0 : 1;
} else {
  if (!['L0-L1', 'L2', 'L3'].includes(mode)) throw Error('Expected L0-L1, L2, L3 or recall');
  const files = walk(root);
  const selected = files.filter(file => {
    const name = relative(root, file).split(sep).join('/');
    return mode === 'L0-L1' ? (name.startsWith('conversations/') || name.startsWith('records/')) && name.endsWith('.jsonl') : mode === 'L2' ? name.startsWith('scene_blocks/') && name.endsWith('.md') : name === 'persona.md';
  });
  const completeLayers = mode !== 'L0-L1' || ['conversations', 'records'].every(directory => selected.some(file => relative(root, file).split(sep)[0] === directory));
  const validFiles = selected.every(file => {
    const text = readFileSync(file, 'utf8').trim();
    if (!text) return false;
    if (mode !== 'L0-L1') return true;
    try {
      return text.split(newline).filter(line => line.trim()).every(line => {
        const record = JSON.parse(line);
        return record && typeof record === 'object' && !Array.isArray(record) && typeof record.content === 'string' && record.content.trim().length > 0;
      });
    } catch { return false; }
  });
  console.log('Read actual memory files:', root);
  console.log('Layer:', mode, 'nonempty files:', selected.filter(file => statSync(file).size > 0).length);
  for (const file of selected.slice(0, 2)) {
    const text = readFileSync(file, 'utf8');
    console.log(newline + 'FILE:', relative(root, file), 'BYTES:', statSync(file).size);
    if (mode === 'L0-L1') {
      const rows = text.trim().split(newline).filter(line => line.trim()).map(line => JSON.parse(line));
      console.log('JSONL records:', rows.length);
      console.log('First record excerpt (600 characters):', JSON.stringify(rows[0]).slice(0, 600));
    } else {
      console.log('Actual excerpt: first 12 nonblank lines, each limited to 90 characters');
      console.log(text.split(newline).filter(line => line.trim()).slice(0, 12).map(line => line.slice(0, 90)).join(newline));
    }
  }
  process.exitCode = selected.length > 0 && completeLayers && validFiles ? 0 : 1;
}
