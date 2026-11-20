import assert from 'node:assert/strict'
import { chmod, mkdtemp, rm } from 'node:fs/promises'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { BridgeClient, parseArgs, probe, verifyPrivateSocket, waitForAssistant } from '../scripts/probe-companion.mjs'

async function withSocket(responder, action) {
  const root = await mkdtemp(join(tmpdir(), 'companion-probe-'))
  await chmod(root, 0o700)
  const path = join(root, 'command.sock')
  const sockets = new Set()
  const server = createServer(socket => {
    sockets.add(socket)
    socket.setEncoding('utf8')
    let buffer = ''
    socket.on('data', chunk => {
      buffer += chunk
      let newline
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const request = JSON.parse(buffer.slice(0, newline))
        buffer = buffer.slice(newline + 1)
        const result = responder(request)
        if (result !== undefined) socket.write(`${JSON.stringify({ id: request.id, ...result })}\n`)
      }
    })
    socket.on('close', () => sockets.delete(socket))
  })
  let client
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(path, resolve) })
    await chmod(path, 0o600)
    client = new BridgeClient(path)
    await action(client, path, root)
  } finally {
    client?.close()
    for (const socket of sockets) socket.destroy()
    if (server.listening) await new Promise(resolve => server.close(resolve))
    await rm(root, { recursive: true, force: true })
  }
}

test('generation requires explicit opt-in and workspace; research never enables it implicitly', () => {
  assert.equal(parseArgs(['--socket', '/tmp/x']).generate, false)
  assert.throws(() => parseArgs(['--socket', '/tmp/x', '--generate']), /explicit --workspace/)
  assert.throws(() => parseArgs(['--socket', '/tmp/x', '--research']), /requires --generate/)
  assert.throws(() => parseArgs(['--socket', '/tmp/x', '--manifest', '/tmp/y']), /exactly one/)
})

test('default probe sends only read-only actions and reports no fabricated generation success', async () => {
  const actions = []
  await withSocket(request => {
    actions.push(request.action)
    switch (request.action) {
      case 'capabilities': return { ok: true, protocolVersion: 1, supports: ['modelCatalog', 'researchContext'] }
      case 'workspaces': return { ok: true, workspaces: [] }
      case 'modelCatalog': return { ok: true, catalog: { default: { provider: 'deepseek-account', model: 'deepseek-flash' }, groups: [], failures: [] } }
      case 'researchContext': return { ok: true, context: null }
      default: assert.fail(`Unexpected action in a read-only probe: ${request.action}`)
    }
  }, async client => {
    const report = await probe(client, { generate: false })
    assert.deepEqual(actions, ['capabilities', 'workspaces', 'modelCatalog', 'researchContext'])
    assert.equal(report.mode, 'read-only')
    assert.equal(report.checks.zotero.ok, false)
    assert.equal(report.checks.directConversation, undefined)
    assert.equal(report.sessionId, undefined)
  })
})

test('owner-only socket probe rejects a group-readable socket before any RPC', async () => {
  await withSocket(() => assert.fail('No RPC should be sent'), async (_client, path) => {
    await verifyPrivateSocket(path)
    await chmod(path, 0o660)
    await assert.rejects(verifyPrivateSocket(path), /accessible to another account/)
  })
})

test('failed Agent state is reported as failure, never filled with a mock answer', async () => {
  await withSocket(request => {
    if (request.action === 'conversation') return { ok: true, messages: [], running: false }
    if (request.action === 'tasks') return { ok: true, tasks: [{ sessionId: 'test-session', state: 'failed', failed: true, message: 'ACCOUNT_SIGN_IN_REQUIRED' }] }
    assert.fail(`Unexpected action ${request.action}`)
  }, async client => {
    await assert.rejects(waitForAssistant(client, 'research-workspace', 'test-session', new Set(), 1000), /ACCOUNT_SIGN_IN_REQUIRED/)
  })
})

test('existing API-key default is refused before creating a test session', async () => {
  const actions = []
  await withSocket(request => {
    actions.push(request.action)
    if (request.action === 'capabilities') return { ok: true, protocolVersion: 1, supports: ['modelCatalog', 'conversation'] }
    if (request.action === 'workspaces') return { ok: true, workspaces: [{ id: 'research' }] }
    if (request.action === 'modelCatalog') return { ok: true, default: { provider: 'deepseek', model: 'deepseek-chat' }, groups: [], failures: [] }
    assert.fail(`Forbidden mutation: ${request.action}`)
  }, async client => {
    await assert.rejects(probe(client, { generate: true, workspaceId: 'research' }), /existing DSH account provider/)
    assert.deepEqual(actions, ['capabilities', 'workspaces', 'modelCatalog'])
  })
})

test('bridge rejection is an error with the original code, not a successful protocol reply', async () => {
  await withSocket(() => ({ ok: false, error: { code: 'session/model-unavailable', message: 'No available account models' } }), async client => {
    await assert.rejects(client.request('modelCatalog'), /session\/model-unavailable/)
  })
})
