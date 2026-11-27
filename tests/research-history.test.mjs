import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { test } from 'node:test'

// Node 24 runs the pure TypeScript source directly; no bundled test-only copy.
import { decodeResearchHistory, projectResearchHistory } from '../src/ResearchHistory.ts'
import { researchPrompt } from '../src/ResearchContext.ts'

const user = (id, text, kind = 'user') => ({ id, content: [{ type: 'text', text }], source: { kind, rpcId: `request-${id}` } })
const event = (seq, type, data) => ({ type: 'event', event: { seq, type, data } })
const splice = (seq, target, start, removedCount, inserted, outcome) => event(seq, 'agent/inbox/spliced', { target, start, ...(removedCount === undefined ? {} : { removedCount }), inserted, ...(outcome === undefined ? {} : { outcome }) })
const answer = (seq, id, text, extras = []) => event(seq, 'assistant/message', { message: { id, content: [{ type: 'text', text }, ...extras], source: { kind: 'model', provider: 'deepseek-account', model: 'deepseek-flash' } } })

test('real rc.3 queued prompt is displayed once after its later user/message admission', () => {
  const prompt = user('msg-human', '真正的科研问题')
  const records = [
    splice(1, 'next-turn', 0, undefined, [prompt]),
    splice(2, 'next-turn', 0, 1, []), // claim/consume is not cancellation
    event(3, 'user/message', user('runtime', '<system-reminder>skills and timestamp</system-reminder>', 'runtime-context')),
    event(4, 'user/message', prompt),
    answer(5, 'reply', '基于原文的真实回复', [{ type: 'thinking', text: 'private reasoning' }]),
  ]
  assert.deepEqual(decodeResearchHistory(records), [
    { role: 'user', text: '真正的科研问题', id: 'msg-human' },
    { role: 'assistant', text: '基于原文的真实回复', id: 'reply' },
  ])
})

test('queued actual prompt is present even when this page has only internal user/message records', () => {
  assert.deepEqual(decodeResearchHistory([
    splice(1, 'next-turn', 0, undefined, [user('real', '翻译这个选中文本')]),
    event(2, 'user/message', user('meta', 'skills\ncurrent timestamp\nworkspace paths', 'runtime-context')),
  ]), [{ role: 'user', text: '翻译这个选中文本', id: 'real' }])
})

test('canceled pending prompts disappear, while normal consumption retains the human transcript', () => {
  assert.deepEqual(decodeResearchHistory([
    splice(1, 'next-turn', 0, undefined, [user('canceled', '不要发送我'), user('kept', '保留我的问题')]),
    splice(2, 'next-turn', 0, 1, [], 'canceled'),
    splice(3, 'next-turn', 0, 1, []),
    answer(4, 'reply', '回答保留的问题'),
  ]), [{ role: 'user', text: '保留我的问题', id: 'kept' }, { role: 'assistant', text: '回答保留的问题', id: 'reply' }])
})

test('canceled replacement removes the old queued prompt and inserts the new valid prompt', () => {
  const replacement = user('new', '编辑后的真正问题')
  assert.deepEqual(decodeResearchHistory([
    splice(1, 'next-turn', 0, undefined, [user('old', '旧问题')]),
    splice(2, 'next-turn', 0, 1, [replacement], 'canceled'),
    event(3, 'user/message', replacement),
  ]), [{ role: 'user', text: '编辑后的真正问题', id: 'new' }])
})

test('invisible messages still occupy their actual queue indexes and both targets stay independent', () => {
  assert.deepEqual(decodeResearchHistory([
    splice(1, 'next-turn', 0, undefined, [user('hidden', 'internal', 'runtime-context'), user('cancel', '取消的真实问题'), user('keep', '下一个真实问题')]),
    splice(2, 'next-step', 0, undefined, [user('steer', '用户追加说明')]),
    splice(3, 'next-turn', 1, 1, [], 'canceled'),
    splice(4, 'next-step', 0, 1, []),
  ]), [{ role: 'user', text: '下一个真实问题', id: 'keep' }, { role: 'user', text: '用户追加说明', id: 'steer' }])
})

test('already admitted user text survives later canceled queue references', () => {
  const prompt = user('admitted', '已经发送的真实问题')
  assert.deepEqual(decodeResearchHistory([
    splice(1, 'next-turn', 0, undefined, [prompt]),
    event(2, 'user/message', prompt),
    splice(3, 'next-turn', 0, 1, [], 'canceled'),
  ]), [{ role: 'user', text: prompt.content[0].text, id: prompt.id }])
})

test('message identity is stable across growing history windows and input records remain unchanged', () => {
  const prompt = user('stable-id', '原文问题')
  const insertion = splice(10, 'next-turn', 0, undefined, [prompt])
  const before = [insertion]
  const after = [answer(30, 'assistant-stable', '真实回答'), event(20, 'user/message', prompt), insertion]
  const saved = JSON.stringify(after)
  assert.equal(decodeResearchHistory(before)[0].id, decodeResearchHistory(after)[0].id)
  assert.deepEqual(decodeResearchHistory(after).map(message => message.id), ['stable-id', 'assistant-stable'])
  assert.equal(JSON.stringify(after), saved)
})

test('internal sources never render, while literal reminder text from a real human remains valid', () => {
  const internals = ['runtime-context', 'model-selection', 'skill-invocation', 'agent-message', 'user-question-reply', 'retry', 'tool-registry']
  const records = internals.map((kind, index) => event(index, 'user/message', user(`internal-${index}`, `hidden ${kind}`, kind)))
  records.push(event(20, 'user/message', user('human-quote', '请解释原文中的 <system-reminder> 这个词。')))
  records.push(event(21, 'user/message', { id: 'no-source', content: [{ type: 'text', text: 'Unknown metadata' }] }))
  assert.deepEqual(decodeResearchHistory(records), [{ role: 'user', text: '请解释原文中的 <system-reminder> 这个词。', id: 'human-quote' }])
})

test('assistant output includes complete text blocks but never thinking, tool arguments or image metadata', () => {
  const long = '可核对的原文解释 '.repeat(500)
  const records = [answer(3, 'assistant', long, [{ type: 'thinking', text: 'secret' }, { type: 'tool-call', name: 'shell', arguments: { secret: 'not for transcript' } }, { type: 'text', text: '完整结尾' }])]
  assert.deepEqual(decodeResearchHistory(records), [{ role: 'assistant', id: 'assistant', text: `${long}\n完整结尾` }])
})

test('malformed/partial diagnostic records do not throw or introduce internal text', () => {
  assert.deepEqual(decodeResearchHistory([null, [], false, {}, { event: null }, event(1, 'agent/inbox/spliced', { target: 'invalid', inserted: [user('bad', 'ignore')] }), event(2, 'user/message', { id: 'empty', source: { kind: 'user' }, content: [{ type: 'text', text: ' ' }] })]), [])
  assert.deepEqual(decodeResearchHistory([{ seq: 8, type: 'assistant/message', data: { message: { content: [{ type: 'text', text: 'partial-page answer' }] } } }]), [{ role: 'assistant', id: '8', text: 'partial-page answer' }])
})

test('research excerpts remain paired to their consumed turns, regardless of another queued prompt', () => {
  const prompt = (token, title, pageIndex) => {
    const message = user('question-' + token, researchPrompt('请解释公式。', 'ask',
      { key: 'item-' + token, title, text: '摘录 ' + token + '\n\n【用户问题】\n里面也是正文', pageIndex,
        pageLabel: 'iv', scope: '选区', source: 'Zotero', available: true }, '科研伙伴'))
    message.source.rpcId = 'dsh-pet-00000000-0000-0000-0000-00000000000' + token
    return message
  }
  const left = prompt('1', '原论文 A', 3)
  const right = prompt('2', '新论文 B', 10)
  const reply = (seq, id, turn) => {
    const projected = answer(seq, id, '模型正文')
    projected.event.data.turn = turn
    return projected
  }
  const messages = decodeResearchHistory([
    splice(1, 'next-turn', 0, undefined, [left]),
    event(2, 'turn/start', { turn: 1 }),
    event(3, 'user/message', left),
    splice(4, 'next-turn', 0, undefined, [right]),
    reply(5, 'answer-a', 1),
    event(6, 'turn/end', { turn: 1 }),
    event(7, 'turn/start', { turn: 2 }),
    event(8, 'user/message', right),
    reply(9, 'answer-b', 2),
    event(10, 'turn/end', { turn: 2 }),
  ])
  const first = messages.find(row => row.id === 'answer-a').reply
  const second = messages.find(row => row.id === 'answer-b').reply
  assert.equal(first.requestId, left.source.rpcId)
  assert.equal(first.question, '请解释公式。')
  assert.equal(first.material.title, '原论文 A')
  assert.equal(first.material.pageIndex, 3)
  assert.equal(first.material.pageLabel, 'iv')
  assert.match(first.material.text, /【用户问题】\n里面也是正文/u)
  assert.equal(second.material.title, '新论文 B')
})

test('a clipped or ambiguous turn does not assign another prompt as a source', () => {
  const current = answer(5, 'model', '真正的模型正文')
  current.event.data.turn = 1
  const questions = [event(3, 'user/message', user('a', '甲')), event(4, 'user/message', user('b', '乙'))]
  for (const prefix of [questions, [event(2, 'turn/start', { turn: 1 }), ...questions]]) {
    assert.equal(decodeResearchHistory([...prefix, current]).at(-1).reply, undefined)
  }
})

test('prepared research turns display and copy only the user question', () => {
  const question = '概括论文。\n\n【用户问题】\n这是问题的一部分。'
  const context = { key: 'example', title: 'Example', text: 'Verified excerpt.', available: true }
  const preparation = 'Internal preparation\n\n【用户问题】\nDo not expose'
  const prompt = user('guided', researchPrompt(question, 'ask', context, 'Persona', undefined, preparation))
  prompt.source.rpcId = 'dsh-pet-00000000-0000-0000-0000-000000000001'
  const result = answer(4, 'result', 'Matched answer')
  result.event.data.turn = 1
  for (const records of [[splice(1, 'next-turn', 0, undefined, [prompt])],
    [event(2, 'turn/start', { turn: 1 }), event(3, 'user/message', prompt), result]]) {
    const decoded = decodeResearchHistory(records)
    assert.deepEqual(decoded[0], { role: 'user', id: 'guided', text: question, plainQuestion: true })
    assert.equal(JSON.stringify(decoded).includes('Internal preparation'), false)
    if (decoded[1]) assert.equal(decoded[1].reply.material.text, 'Verified excerpt.')
  }
})

test('background PDF turns stay out of history and ordered translations share one answer', () => {
  const batch = { id: '46e05000-1234-4000-8000-38717c5900ff', count: 2 }
  const question = '请翻译全部。'
  const part = (seq, stage, index, content, finish = 'completed') => {
    const id = 'dsh-pet-00000000-0000-0000-0000-00000000000' + index
    const material = { key: 'segment-' + index, title: 'Example', text: 'Original page ' + index, available: true }
    const prompt = user('part-' + index, researchPrompt(question, 'ask', material, 'Persona', undefined,
      'Internal processing', { ...batch, stage, index }))
    prompt.source.rpcId = id
    const reply = answer(seq + 3, 'reply-' + index, content)
    reply.event.data.turn = seq
    return [
      splice(seq, 'next-turn', 0, undefined, [prompt]), event(seq + 1, 'turn/start', { turn: seq }),
      event(seq + 2, 'user/message', prompt), reply, event(seq + 4, 'turn/end', { reason: { kind: finish } }),
    ]
  }
  const preparation = part(1, 'work', 1, 'Internal reply')
  const first = part(10, 'translation', 1, '第一段。')
  const second = part(20, 'translation', 2, '第二段。')
  const requestId = 'dsh-pet-00000000-0000-0000-0000-000000000002'
  assert.deepEqual(decodeResearchHistory(preparation), [])
  const incomplete = projectResearchHistory([...preparation, ...first, ...second.slice(0, -1)], requestId)
  assert.equal(incomplete.messages[1].text, '第一段。\n\n已取得 1/2 段翻译。')
  assert.equal(incomplete.completedPart, undefined)
  const complete = projectResearchHistory([...preparation, ...first, ...second], requestId)
  assert.equal(complete.messages.length, 2)
  assert.equal(complete.messages[0].text, question)
  assert.equal(complete.messages[1].text, '第一段。\n\n第二段。')
  assert.equal(complete.messages[1].reply.material.text, 'Original page 1')
  assert.deepEqual(complete.completedPart, {requestId, text: '第二段。'})
  const clipped = decodeResearchHistory(second)
  assert.equal(clipped[1].text, '第二段。\n\n已取得 1/2 段翻译。')
})
