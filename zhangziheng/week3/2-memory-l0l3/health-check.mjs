try {
  const response = await fetch('http://127.0.0.1:8420/health')
  const body = await response.text()
  console.log(body)
  if (!response.ok) process.exit(1)
} catch (error) {
  console.log(JSON.stringify({ status: 'starting', error: String(error?.message || error) }))
  process.exit(1)
}
