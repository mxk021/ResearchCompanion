/** The fork ships only owner-session navigation, without an auto-installer UI. */
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'
import vm from 'node:vm'

const request = { requestId: 'open-one', workspaceId: 'research-workspace', sessionId: 'research-session' }
async function setup({ responses = [{ request: null }], openError = false } = {}) {
  const code = await readFile(new URL('../lib/client.js', import.meta.url), 'utf8')
  let registration, cleanup
  const calls = [], opened = [], warnings = [], modules = [], timers = new Map()
  let token = 0
  const sandbox = {
    window: { __ModuleLoader__: { load(value) { registration = value } } },
    document: { baseURI: 'dsh-app://app/' }, URL,
    console: { warn: (...args) => warnings.push(args) },
    fetch: async (url, init) => {
      calls.push({ url, init })
      if (url.endsWith('/ack')) return { ok: true, json: async () => ({ ok: true }) }
      const response = responses.shift() ?? { request: null }
      if (response.throw) throw new Error('Temporary host outage')
      return { ok: response.ok !== false, json: async () => response }
    },
    setTimeout(callback) { const id = ++token; timers.set(id, callback); return id },
    clearTimeout(id) { timers.delete(id) },
  }
  vm.runInNewContext(code, sandbox)
  assert.equal(registration.id, 'dsh-research-companion')
  const client = registration.factory(name => { modules.push(name); throw new Error(`Unnecessary module requested: ${name}`) })
  client.apply({
    uiWorkspace: { openSession(id) { opened.push(id); if (openError) throw new Error('UI not ready') } },
    inject() { throw new Error('The navigation client must not mount an installation panel') },
    effect(fn) { cleanup = fn() },
  })
  const flush = () => new Promise(resolve => setImmediate(resolve))
  await flush()
  return { client, calls, opened, warnings, modules, timers, flush, close: () => cleanup(),
    async next() { const [id, callback] = timers.entries().next().value ?? []; assert.ok(callback, 'A retry must be scheduled'); timers.delete(id); callback(); await flush() },
  }
}

test('browser client registers the fork module without unreviewed installer UI or dependencies', async () => {
  const fixture = await setup()
  try {
    assert.deepEqual(Array.from(fixture.client.inject), ['uiWorkspace'])
    assert.deepEqual(fixture.modules, [])
    assert.equal(fixture.calls.length, 1)
    assert.equal(fixture.calls[0].url, 'dsh-app://app/api/dsh-pet/session-open/pending')
    assert.equal(fixture.calls.some(call => /install|github|releases/.test(call.url)), false)
  } finally { fixture.close() }
})

test('owner navigation opens the requested session and acknowledges only its opaque request id', async () => {
  const fixture = await setup({ responses: [{ request }] })
  try {
    assert.deepEqual(fixture.opened, ['research-session'])
    assert.equal(fixture.calls[0].init.cache, 'no-store')
    const ack = fixture.calls[1]
    assert.equal(ack.url, 'dsh-app://app/api/dsh-pet/session-open/ack')
    assert.equal(ack.init.method, 'POST')
    assert.equal(ack.init.cache, 'no-store')
    assert.deepEqual(JSON.parse(ack.init.body), { requestId: 'open-one' })
    assert.equal(Object.hasOwn(ack.init, 'credentials'), false)
  } finally { fixture.close() }
})

test('empty and malformed pending responses never open or acknowledge a session', async () => {
  for (const malformed of [null, {}, { sessionId: 'no-request-id' }, { requestId: 'no-session-id' }, 'invalid']) {
    const fixture = await setup({ responses: [{ request: malformed }] })
    try { assert.deepEqual(fixture.opened, []); assert.equal(fixture.calls.length, 1) } finally { fixture.close() }
  }
})

test('an unauthenticated or unavailable host response is retried without navigating', async () => {
  const fixture = await setup({ responses: [{ ok: false, request }, { request }] })
  try {
    assert.deepEqual(fixture.opened, [])
    await fixture.next()
    assert.deepEqual(fixture.opened, ['research-session'])
    assert.equal(fixture.calls.filter(call => call.url.endsWith('/ack')).length, 1)
  } finally { fixture.close() }
})

test('temporary host fetch failure keeps retrying without inventing a request', async () => {
  const fixture = await setup({ responses: [{ throw: true }, { request }] })
  try {
    assert.deepEqual(fixture.opened, [])
    await fixture.next()
    assert.deepEqual(fixture.opened, ['research-session'])
    assert.equal(fixture.calls.filter(call => call.url.endsWith('/ack')).length, 1)
  } finally { fixture.close() }
})

test('UI navigation failure never acknowledges a request as successfully opened', async () => {
  const fixture = await setup({ responses: [{ request }, { request }], openError: true })
  try {
    assert.deepEqual(fixture.opened, ['research-session'])
    assert.equal(fixture.calls.filter(call => call.url.endsWith('/ack')).length, 0)
    await fixture.next()
    assert.equal(fixture.opened.length, 2)
    assert.equal(fixture.warnings.length, 2)
    assert.equal(fixture.calls.filter(call => call.url.endsWith('/ack')).length, 0)
  } finally { fixture.close() }
})

test('disposing the client cancels its poll without leaving a background timer', async () => {
  const fixture = await setup()
  assert.equal(fixture.timers.size, 1)
  fixture.close()
  assert.equal(fixture.timers.size, 0)
  await fixture.flush()
  assert.equal(fixture.calls.length, 1)
})
