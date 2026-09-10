const query = process.argv[2] || '我负责的青松灯塔-7429项目目标是什么？'
const sessionKey = process.argv[3] || '20260909_002212_652bc3'
const response = await fetch('http://127.0.0.1:8420/recall', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ query, session_key: sessionKey }),
})
const body = await response.json()
console.log(`query=${query}`)
console.log(`session_key=${sessionKey}`)
console.log(`HTTP ${response.status}`)
console.log(`strategy=${body.strategy} memory_count=${body.memory_count}`)
const context = String(body.context || '')
const lines = context.split(/\r?\n/u)
const hits = lines.filter((line) => /青松灯塔-7429|告警误报率|规则引擎|可观测性/u.test(line))
console.log('matched lines:')
console.log(hits.slice(0, 12).join('\n'))
