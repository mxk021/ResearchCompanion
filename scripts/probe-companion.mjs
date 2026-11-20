#!/usr/bin/env node
/**
 * Live, owner-local bridge probe. Default mode makes read-only requests only.
 * Generation is opt-in and uses a new session in an explicitly named workspace.
 * Never reads credentials, selects a model, or falls back to another provider.
 *
 * node scripts/probe-companion.mjs --socket /tmp/...-c.sock
 * node scripts/probe-companion.mjs --socket /tmp/...-c.sock --workspace ID --generate
 * Add --research to verify a source-backed answer against Zotero's live context.
 */
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { lstat, readFile, writeFile } from 'node:fs/promises'
import { connect } from 'node:net'
import { dirname, isAbsolute } from 'node:path'
import { pathToFileURL } from 'node:url'

const MAX_RESPONSE_BYTES = 4 * 1024 * 1024

export function parseArgs(argv) {
  const options = { generate: false, research: false, timeoutMs: 90_000 }
  for (let i = 0; i < argv.length; i++) {
    const name = argv[i]
    if (name === '--generate') options.generate = true
    else if (name === '--research') options.research = true
    else if (['--socket', '--manifest', '--workspace', '--output', '--timeout-ms'].includes(name)) {
      const value = argv[++i]
      if (!value || value.startsWith('--')) throw new Error(`Missing value for ${name}`)
      const key = { '--socket': 'socket', '--manifest': 'manifest', '--workspace': 'workspaceId', '--output': 'output', '--timeout-ms': 'timeoutMs' }[name]
      options[key] = name === '--timeout-ms' ? Number(value) : value
    } else throw new Error(`Unknown argument: ${name}`)
  }
  if (Boolean(options.socket) === Boolean(options.manifest)) throw new Error('Supply exactly one --socket or --manifest')
  if (!Number.isSafeInteger(options.timeoutMs) || options.timeoutMs < 1000 || options.timeoutMs > 300_000) throw new Error('--timeout-ms must be between 1000 and 300000')
  if (options.generate && !options.workspaceId) throw new Error('--generate requires an explicit --workspace ID')
  if (options.research && !options.generate) throw new Error('--research requires --generate')
  return options
}

export async function verifyPrivateSocket(path) {
  if (!isAbsolute(path)) throw new Error('Socket path must be absolute')
  const [socket, directory] = await Promise.all([lstat(path), lstat(dirname(path))])
  const uid = process.getuid?.()
  if (!socket.isSocket() || socket.isSymbolicLink()) throw new Error('The target must be a Unix socket, not a symlink')
  if (!directory.isDirectory() || directory.isSymbolicLink()) throw new Error('Socket parent must be a real private directory')
  if ((socket.mode & 0o077) !== 0 || (directory.mode & 0o077) !== 0) throw new Error('Refusing a socket or directory accessible to another account')
  if (uid !== undefined && (socket.uid !== uid || directory.uid !== uid)) throw new Error('Socket and parent must belong to the current account')
}

export class BridgeClient {
  pending = new Map()
  buffer = ''
  socket
  connected

  constructor(path) {
    this.socket = connect(path)
    this.socket.setEncoding('utf8')
    this.connected = new Promise((resolve, reject) => {
      this.socket.once('connect', resolve)
      this.socket.once('error', reject)
    })
    this.socket.on('data', chunk => {
      this.buffer += chunk
      if (Buffer.byteLength(this.buffer) > MAX_RESPONSE_BYTES) return this.fail(new Error('Bridge response exceeds the probe limit'))
      let newline
      while ((newline = this.buffer.indexOf('\n')) >= 0) {
        const line = this.buffer.slice(0, newline)
        this.buffer = this.buffer.slice(newline + 1)
        if (!line.trim()) continue
        let value
        try { value = JSON.parse(line) } catch { this.fail(new Error('Invalid JSON received from bridge')); return }
        const pending = this.pending.get(value.id)
        if (!pending) continue // Unsolicited status events are not RPC replies.
        this.pending.delete(value.id)
        clearTimeout(pending.timer)
        if (value.ok !== true) pending.reject(new Error(`${value.error?.code ?? 'bridge-error'}: ${value.error?.message ?? 'Request rejected'}`))
        else pending.resolve(value)
      }
    })
    this.socket.on('error', error => this.fail(error))
    this.socket.on('close', () => this.fail(new Error('Bridge connection closed')))
  }

  fail(error) {
    for (const item of this.pending.values()) { clearTimeout(item.timer); item.reject(error) }
    this.pending.clear()
    this.socket.destroy()
  }

  async request(action, fields = {}, timeoutMs = 20_000) {
    await this.connected
    const id = randomUUID()
    const response = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`Bridge action ${action} timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      this.pending.set(id, { resolve, reject, timer })
    })
    this.socket.write(`${JSON.stringify({ ...fields, id, action })}\n`)
    return response
  }

  close() { this.socket.destroy() }
}

export async function waitForAssistant(client, workspaceId, sessionId, previousAssistantIds, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const conversation = await client.request('conversation', { workspaceId, sessionId })
    assert.ok(Array.isArray(conversation.messages), 'conversation.messages must be an array')
    if (conversation.error && conversation.running !== true) throw new Error(`Actual DSH Agent failed: ${conversation.error}`)
    const messages = conversation.messages.filter(message => message.role === 'assistant' && !previousAssistantIds.has(message.id))
    const complete = messages.filter(message => typeof message.text === 'string' && message.text.trim())
    if (complete.length && conversation.running !== true) return { ...conversation, newAssistantMessages: complete }
    const { tasks = [] } = await client.request('tasks')
    const task = tasks.find(candidate => candidate.sessionId === sessionId)
    if (task?.failed || task?.state === 'failed') throw new Error(`Actual DSH Agent failed: ${task.message ?? 'see DSH session for error'}`)
    if (task?.waitingForUser || ['waitingApproval', 'waitingUserAnswer'].includes(task?.state)) throw new Error('Actual DSH Agent requires user input; the probe will not bypass it')
    await new Promise(resolve => setTimeout(resolve, 400))
  }
  throw new Error('No completed real assistant response before the deadline; no simulated response was used')
}

export async function probe(client, options) {
  const result = { mode: options.generate ? 'live-generation' : 'read-only', startedAt: new Date().toISOString(), checks: {} }
  const capabilities = await client.request('capabilities')
  assert.equal(capabilities.protocolVersion, 1)
  assert.ok(Array.isArray(capabilities.supports))
  result.checks.capabilities = { ok: true, supports: capabilities.supports, instanceId: capabilities.instance?.instanceId, profile: capabilities.instance?.profile }
  const workspaces = await client.request('workspaces')
  assert.ok(Array.isArray(workspaces.workspaces))
  result.checks.workspaces = { ok: true, items: workspaces.workspaces.map(({ id, title }) => ({ id, title })) }

  let catalog
  if (capabilities.supports.includes('modelCatalog')) {
    const reply = await client.request('modelCatalog')
    catalog = reply.catalog ?? reply
    assert.ok(Array.isArray(catalog.groups), 'modelCatalog.groups must be an array')
    result.checks.models = { ok: true, default: catalog.default, groups: catalog.groups.map(group => ({ id: group.id, models: group.models.map(model => ({ id: model.id, name: model.name })) })), failures: catalog.failures ?? [] }
  } else result.checks.models = { ok: false, reason: 'modelCatalog is not advertised' }

  let context
  if (capabilities.supports.includes('researchContext')) {
    const reply = await client.request('researchContext')
    context = reply.context
    result.checks.zotero = { ok: Boolean(context?.available !== false && (context?.text || context?.selection)), key: context?.key, title: context?.title, pageLabel: context?.pageLabel, textCharacters: context?.text?.length ?? 0, selectionCharacters: context?.selection?.length ?? 0, error: context?.error }
  } else result.checks.zotero = { ok: false, reason: 'researchContext is not advertised' }

  if (!options.generate) return result
  assert.ok(catalog, 'Generation requires a successfully read model catalog')
  assert.equal(catalog.default?.provider, 'deepseek-account', 'The live smoke test permits only the existing DSH account provider, never an API-key route')
  assert.ok(catalog.groups.some(group => group.id === 'deepseek-account' && group.models.some(model => model.id === catalog.default.model)), 'Current default is not in the available account model catalog')
  assert.ok(workspaces.workspaces.some(workspace => workspace.id === options.workspaceId), 'The explicitly named workspace is not registered')
  assert.ok(capabilities.supports.includes('conversation'), 'Full real conversation action is required')
  if (options.research) assert.ok(context && context.available !== false && (context.text || context.selection), 'Research mode requires live source text from Zotero')

  const requestedSessionId = `session-companion-probe-${randomUUID()}`
  const created = await client.request('createSession', { workspaceId: options.workspaceId, sessionId: requestedSessionId })
  const sessionId = created.sessionId
  assert.equal(typeof sessionId, 'string')
  result.sessionId = sessionId // Retained intentionally as a reviewable test conversation.
  const baseline = await client.request('conversation', { workspaceId: options.workspaceId, sessionId })
  const prior = new Set((baseline.messages ?? []).filter(message => message.role === 'assistant').map(message => message.id))
  const marker = `COMPANION_LIVE_${randomUUID().replaceAll('-', '').slice(0, 10)}`
  const firstPrompt = `请只输出 ${marker}。不要调用工具，不要读取文件或访问网络。`
  await client.request('prompt', { workspaceId: options.workspaceId, sessionId, requestId: randomUUID(), text: firstPrompt })
  const first = await waitForAssistant(client, options.workspaceId, sessionId, prior, options.timeoutMs)
  assert.ok(first.newAssistantMessages.some(message => message.text.includes(marker)), 'The actual assistant response did not contain the one-time verification marker')
  result.checks.directConversation = { ok: true, responseMessages: first.newAssistantMessages.length, model: first.model ?? catalog.default }
  for (const message of first.messages) if (message.role === 'assistant') prior.add(message.id)
  await client.request('prompt', { workspaceId: options.workspaceId, sessionId, requestId: randomUUID(), text: '上一条我要求你复述的完整英文短语是什么？只输出该短语，不要调用工具。' })
  const second = await waitForAssistant(client, options.workspaceId, sessionId, prior, options.timeoutMs)
  assert.ok(second.newAssistantMessages.some(message => message.text.includes(marker)), 'The real second response did not retain the previous turn')
  result.checks.continuity = { ok: true, responseMessages: second.newAssistantMessages.length }

  if (options.research) {
    assert.ok(capabilities.supports.includes('researchPrompt'), 'researchPrompt is not advertised')
    for (const message of second.messages) if (message.role === 'assistant') prior.add(message.id)
    await client.request('researchPrompt', { workspaceId: options.workspaceId, sessionId, requestId: randomUUID(), text: '请根据当前论文原文，用中文解释其主要研究问题，并引用一处原文。只基于提供的原文；材料不足时明确说明。不要使用外部工具。', mode: 'ask', contextKey: context.key, includeContext: true })
    const research = await waitForAssistant(client, options.workspaceId, sessionId, prior, options.timeoutMs)
    result.checks.sourceBackedRequest = { ok: true, sourceKey: context.key, responseCharacters: research.newAssistantMessages.map(message => message.text).join('\n').length, semanticGroundingRequiresHumanReview: true }
  }
  return result
}

async function main() {
  const options = parseArgs(process.argv.slice(2))
  if (options.manifest) {
    const manifestStat = await lstat(options.manifest)
    if (!manifestStat.isFile() || manifestStat.isSymbolicLink() || (manifestStat.mode & 0o077) !== 0 || (process.getuid && manifestStat.uid !== process.getuid())) throw new Error('Manifest must be an owner-only regular file')
    options.socket = JSON.parse(await readFile(options.manifest, 'utf8')).commandSocketPath
  }
  await verifyPrivateSocket(options.socket)
  const client = new BridgeClient(options.socket)
  try {
    const report = await probe(client, options)
    const serialized = `${JSON.stringify(report, null, 2)}\n`
    if (options.output) await writeFile(options.output, serialized, { mode: 0o600 })
    process.stdout.write(serialized)
  } finally { client.close() }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch(error => { process.stderr.write(`Companion live probe failed: ${error.message}\n`); process.exitCode = 1 })
}
