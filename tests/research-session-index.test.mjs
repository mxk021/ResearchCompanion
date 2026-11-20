import assert from 'node:assert/strict'
import { test } from 'node:test'
import { indexResearchSession, projectedSessionTitle, researchSessionIndexPage } from '../lib/ResearchSessionIndex.js'
import { DEFAULT_PERSONA, researchPrompt } from '../lib/ResearchContext.js'

const capture = (title, source, url) => ({
  available: true, kind: 'inline', key: 'material-fixture', title, source, url,
  text: 'Private excerpt fixture must stay out of the search result.',
})
const prompt = (seq, context, kind = 'user', rpcId = 'dsh-pet-00000000-0000-4000-8000-000000000001') => ({
  seq, type: 'user/message', data: {
    id: `prompt-${seq}`, source: { kind, rpcId }, content: [{
      type: 'text', text: researchPrompt('Private synthetic question', 'ask', context, DEFAULT_PERSONA),
    }],
  },
})
const title = (seq, value) => ({ seq, type: 'session/title', data: { title: value } })

test('reads only saved source labels, authentic human turns, and the newest durable title', () => {
  const log = [
    title(0, '原题'),
    prompt(1, capture('论文甲', 'Zotero')),
    prompt(2, capture('假材料', 'runtime'), 'runtime-context'),
    prompt(3, capture('浏览器甲', 'Safari', 'https://example.org/paper')),
    prompt(4, capture('论文甲', 'Zotero')),
    title(5, '已重命名'),
    prompt(6, capture('非本应用', 'Other'), 'user', 'genuine-other-client'),
  ]
  assert.deepEqual(indexResearchSession(log), {
    title: '已重命名',
    materials: [{ title: '论文甲', source: 'Zotero' }, { title: '浏览器甲', source: 'Safari · https://example.org/paper' }],
  })
  assert.equal(projectedSessionTitle({ projections: { values: { title: '冷会话标题' } } }), '冷会话标题')
  assert.equal(projectedSessionTitle({ projections: { values: { title: null } } }), undefined)
})

function fixture() {
  const ids = Array.from({ length: 26 }, (_, i) => String(i))
  const membership = new Set([...ids, 'fork', 'worker'])
  const archived = new Set(['25', 'outside'])
  const logs = new Map([
    ['25', [
      title(0, '匹配标题'), prompt(1, capture('历史论文', 'Web', 'https://example.org/visible')),
      ...Array.from({ length: 120 }, (_, i) => prompt(i + 2, null)),
    ]],
  ])
  const summaries = [...ids, 'fork', 'outside', 'worker'].map((sessionId, i) => ({
    sessionId, updatedAt: 1_000_000 - i, running: false, blank: false,
    ...(sessionId === 'fork' ? { parentSessionId: '0' } : {}),
    ...(sessionId === 'worker' ? { parentSessionId: '0', origin: 'subagent' } : {}),
  }))
  const request = { workspaceId: 'research', status: 'all', title: '', material: '', offset: 0 }
  const admitted = []
  const options = {
    request, summaries, membership, archived, titleFor: () => '普通标题',
    signal: new AbortController().signal,
    query: { observeSession: async (sessionId, { signal, projectionMode }) => {
      assert.equal(projectionMode, 'none')
      assert.ok(signal instanceof AbortSignal)
      admitted.push(sessionId)
      if (sessionId === '2') throw new Error('unavailable synthetic observation')
      return { events: logs.get(sessionId) ?? [], [Symbol.dispose]() {} }
    } },
    stillInWorkspace: (id, wasArchived) => membership.has(id) && archived.has(id) === wasArchived,
  }
  return { options, admitted }
}

test('title and source filters scan all pages including old turns; outside and worker IDs are never read', async () => {
  const { options, admitted } = fixture()
  options.request = { ...options.request, title: '匹配', material: 'EXAMPLE.ORG' }
  const first = await researchSessionIndexPage(options)
  assert.equal(first.totalToScan, 27)
  assert.equal(first.scanned, 24)
  assert.equal(first.unreadable, 1)
  assert.deepEqual(first.matches, [])
  const last = await researchSessionIndexPage({
    ...options, request: { ...options.request, offset: first.nextOffset, revision: first.revision },
  })
  assert.equal(last.nextOffset, null)
  assert.deepEqual(last.matches.map(row => [row.sessionId, row.title, row.archived]), [['25', '匹配标题', true]])
  const serialized = JSON.stringify(last)
  assert.doesNotMatch(serialized, /Private synthetic question|Private excerpt fixture/)
  assert.ok(!admitted.includes('outside') && !admitted.includes('worker'))
  assert.ok(admitted.includes('fork'))
})

test('archive state follows DSH registry; revision notices external unarchiving and ignores unchanged metadata', async () => {
  const { options, admitted } = fixture()
  options.request = { ...options.request, status: 'archived' }
  const first = await researchSessionIndexPage(options)
  assert.deepEqual(first.matches.map(row => row.sessionId), ['25'])
  const same = await researchSessionIndexPage({ ...options, request: { ...options.request, revision: first.revision } })
  assert.deepEqual(same, { unchanged: true })
  assert.deepEqual(admitted, ['25'])
  options.archived.delete('25')
  const refreshed = await researchSessionIndexPage({ ...options, request: { ...options.request, revision: first.revision } })
  assert.deepEqual(refreshed.matches, [])
})

test('changed membership invalidates paging and never returns a removed row from an in-flight read', async () => {
  const { options } = fixture()
  const first = await researchSessionIndexPage(options)
  assert.equal(first.matches.filter(row => row.title === '普通标题').length, 24)
  assert.equal(new Set(first.matches.map(row => row.sessionId)).size, 24)
  assert.equal(new Set(first.matches.map(row => row.updatedAt)).size, 24)
  options.membership.delete('25')
  assert.deepEqual(await researchSessionIndexPage({
    ...options, request: { ...options.request, offset: first.nextOffset, revision: first.revision },
  }), { stale: true })
  const observeSession = options.query.observeSession
  options.query.observeSession = async (...args) => {
    const results = await observeSession(...args)
    options.membership.delete('1')
    return results
  }
  assert.deepEqual(await researchSessionIndexPage(options), { stale: true })
})

test('public observation leases are bounded and released on cancellation without leaking partial results', async () => {
  const { options } = fixture()
  const controller = new AbortController()
  let opened = 0
  let released = 0
  let maxActive = 0
  options.signal = controller.signal
  options.query.observeSession = async () => {
    opened++
    maxActive = Math.max(maxActive, opened - released)
    await new Promise(resolve => setImmediate(resolve))
    if (released === 0) controller.abort()
    return {
      events: [],
      [Symbol.dispose]() { released++ },
    }
  }
  await assert.rejects(researchSessionIndexPage(options), { name: 'AbortError' })
  assert.equal(maxActive, 4)
  assert.equal(released, 4)
})
