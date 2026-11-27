/** The owner-visible transcript, decoded from DSH 0.2.2-rc.3 history records. */
export interface ResearchHistoryMessage {
  role: 'user' | 'assistant'
  text: string
  id: string
  plainQuestion?: true
  reply?: {
    question: string
    questionId: string
    requestId?: string
    time?: number
    material?: ResearchPromptMetadata['material']
  }
}

type JsonRecord = Record<string, unknown>
interface DisplayEntry extends ResearchHistoryMessage { order: number }

export interface ResearchPDFBatch {
  id: string
  stage: 'work' | 'translation' | 'result'
  index?: number
  count?: number
}

export function decodeResearchPDFBatch(value: unknown): ResearchPDFBatch | undefined {
  const item = record(value)
  if (!item || typeof item.id !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/iu.test(item.id) ||
    (item.stage !== 'work' && item.stage !== 'translation' && item.stage !== 'result')) return undefined
  if (item.index === undefined && item.count === undefined && item.stage !== 'translation') return { id: item.id, stage: item.stage }
  const { index, count } = item
  if (typeof index !== 'number' || typeof count !== 'number' || !Number.isSafeInteger(index) || !Number.isSafeInteger(count) ||
    index < 1 || count > 40 || index > count) return undefined
  return { id: item.id, stage: item.stage, index, count }
}

export interface ResearchPromptMetadata {
  question: string
  prepared?: true
  pdfBatch?: ResearchPDFBatch
  material?: {
    key: string; title: string; text: string
    source?: string; scope?: string; url?: string; pageLabel?: string; pageIndex?: number
  }
}

/** Inspect the exact bridge envelope. Content parsed here never determines an executable command. */
export function researchPromptMetadata(text: string): ResearchPromptMetadata | undefined {
  const marker = /\n\n【(?:材料|论文)原文，JSON 引用数据】\n([^\n]*)\n\n【用户问题】\n/u.exec(text)
  if (!marker || marker.index === undefined) return undefined
  const question = text.slice(marker.index + marker[0].length).trim()
  if (!question) return undefined
  try {
    const header = /\n\n【问答说明，JSON】\n([^\n]*)$/u.exec(text.slice(0, marker.index))
    const preparation = header && record(JSON.parse(header[1]))
    const prepared = preparation ? { prepared: true as const, pdfBatch: decodeResearchPDFBatch(preparation.pdfBatch) } : {}
    const data = record(JSON.parse(marker[1]))
    if (!data) return marker[1] === 'null' ? { question, ...prepared } : undefined
    if (typeof data.key !== 'string' || typeof data.title !== 'string' ||
        typeof data.text !== 'string' || !data.text.trim() || data.text.length > 24_000) return undefined
    const optional = (field: string) => typeof data[field] === 'string' ? data[field] as string : undefined
    return { question, ...prepared, material: {
      key: data.key, title: data.title, text: data.text,
      source: optional('source'), scope: optional('scope'), url: optional('url'), pageLabel: optional('page'),
      pageIndex: typeof data.pageIndex === 'number' && Number.isSafeInteger(data.pageIndex) && data.pageIndex >= 0
        ? data.pageIndex : undefined,
    } }
  } catch { return undefined }
}

function record(value: unknown): JsonRecord | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as JsonRecord : undefined
}

function visibleText(content: unknown): string {
  if (!Array.isArray(content)) return ''
  return content.flatMap(block => {
    const item = record(block)
    return item?.type === 'text' && typeof item.text === 'string' ? [item.text] : []
  }).join('\n')
}

function messageId(message: JsonRecord, fallback: string): string {
  return typeof message.id === 'string' && message.id !== '' ? message.id : fallback
}

/**
 * Decode actual user prompts and visible assistant text without exposing the
 * Agent's runtime-context, skills, metadata, or reasoning messages.
 *
 * The inbox is authoritative at admission: prompts are first logged in
 * `agent/inbox/spliced`, and may later also occur as `user/message` under the
 * same MessageId. Replay both inbox targets (including invisible messages),
 * so queue edits and cancellations use their real indexes. A canceled splice
 * cancels the removed items, not its replacement `inserted` messages. Normal
 * consumption removes queue items but retains their transcript entries.
 *
 * This is a pure projection: no storage, model calls, or mutation of records.
 * It also accepts raw events for diagnostics, besides the public {event}
 * history wrapper. Partial pages are decoded conservatively; callers retain
 * the host's hasMore/cursor metadata and must not imply missing older pages
 * have been decoded.
 */
export function decodeResearchHistory(records: readonly unknown[]): ResearchHistoryMessage[] {
  return projectResearchHistory(records).messages
}

export function projectResearchHistory(records: readonly unknown[], verifyRequestId?: string) {
  const events = records.flatMap((value, index) => {
    const wrapper = record(value)
    const event = record(wrapper?.event) ?? wrapper
    if (typeof event?.type !== 'string') return []
    const seq = typeof event.seq === 'number' && Number.isSafeInteger(event.seq) && event.seq >= 0
      ? event.seq : Number.MAX_SAFE_INTEGER
    return [{ event, seq, index }]
  }).sort((left, right) => left.seq - right.seq || left.index - right.index)

  const queues: Record<'next-turn' | 'next-step', string[]> = {
    'next-turn': [], 'next-step': [],
  }
  const display = new Map<string, DisplayEntry>()
  const admitted = new Set<string>()
  const translations = new Map<string, {
    count: number; parts: Map<number, string>; entry?: DisplayEntry
  }>()
  let turn: unknown
  let turnQuestions = new Map<string, { reply: NonNullable<ResearchHistoryMessage['reply']>; batch?: ResearchPDFBatch }>()
  let batchText: string[] = []
  let completedPart: { requestId: string; text: string } | undefined
  let order = 0

  const add = (role: ResearchHistoryMessage['role'], message: JsonRecord, fallback: string): string => {
    const id = messageId(message, fallback)
    const content = visibleText(message.content)
    const requestId = record(message.source)?.rpcId
    const metadata = role === 'user' && typeof requestId === 'string' && /^dsh-pet-[0-9a-f-]{36}$/iu.test(requestId)
      ? researchPromptMetadata(content) : undefined
    const batch = metadata?.pdfBatch
    if (batch?.stage === 'work') return id
    const displayId = batch?.stage === 'translation' ? 'pdf-' + batch.id : id
    const question = metadata?.prepared ? metadata.question : undefined
    const text = question ?? content
    if (!text.trim()) return id
    const key = `${role}\0${displayId}`
    const existing = display.get(key)
    if (existing !== undefined) existing.text = text
    else display.set(key, { role, text, id: displayId, order: order++, ...(question ? { plainQuestion: true } : {}) })
    return id
  }

  const currentQuestion = () => turnQuestions.size === 1 ? turnQuestions.values().next().value : undefined
  for (const { event, seq, index } of events) {
    const data = record(event.data)
    if (!data) continue
    const fallback = seq === Number.MAX_SAFE_INTEGER ? `unsequenced-${index}` : String(seq)
    if (event.type === 'turn/start') {
      turn = data.turn
      turnQuestions = new Map()
      batchText = []
    } else if (event.type === 'turn/end') {
      const current = currentQuestion()
      const batch = current?.batch
      const text = batchText.join('\n\n')
      if (batch && current && text.trim() && record(data.reason)?.kind === 'completed') {
        if (current.reply.requestId === verifyRequestId && verifyRequestId) completedPart = { requestId: verifyRequestId, text }
        if (batch.stage === 'translation' && batch.index !== undefined && batch.count !== undefined) {
          const group = translations.get(batch.id) ?? {count: batch.count, parts: new Map<number, string>()}
          if (group.count === batch.count) {
            group.parts.set(batch.index, text)
            const id = 'pdf-' + batch.id
            group.entry ??= { role: 'assistant', text: '', id, order: order++, reply: current.reply }
            if (batch.index === 1) group.entry.reply = current.reply
            translations.set(batch.id, group)
            display.set(`assistant\0${id}`, group.entry)
          }
        }
      }
      turn = undefined
      turnQuestions.clear()
      batchText = []
    } else if (event.type === 'user/message') {
      const source = record(data.source)
      if (source?.kind !== 'user') continue
      const id = messageId(data, fallback)
      admitted.add(id)
      add('user', data, fallback)
      if (turn === undefined || turn === null) continue
      const text = visibleText(data.content)
      const requestId = typeof source.rpcId === 'string' && /^dsh-pet-[0-9a-f-]{36}$/iu.test(source.rpcId)
        ? source.rpcId : undefined
      const evidence = requestId ? researchPromptMetadata(text) : undefined
      turnQuestions.set(id, { batch: evidence?.pdfBatch, reply: {
        question: evidence?.question ?? text, questionId: id, requestId,
        time: typeof event.time === 'number' && Number.isFinite(event.time) ? event.time : undefined,
        material: evidence?.material,
      } })
    } else if (event.type === 'assistant/message') {
      const message = record(data.message)
      if (message) {
        const current = turn !== undefined && turn !== null && data.turn === turn ? currentQuestion() : undefined
        if (current?.batch) {
          const text = visibleText(message.content)
          if (text.trim()) batchText.push(text)
          if (current.batch.stage !== 'result') continue
        }
        const id = add('assistant', message, fallback)
        const entry = display.get(`assistant\0${id}`)
        if (entry && current) entry.reply = current.reply
      }
    } else if (event.type === 'agent/inbox/spliced') {
      if (data.target !== 'next-turn' && data.target !== 'next-step') continue
      if (!Array.isArray(data.inserted)) continue
      const queue = queues[data.target]
      const start = typeof data.start === 'number' && Number.isSafeInteger(data.start) && data.start >= 0
        ? Math.min(data.start, queue.length) : queue.length
      const removedCount = typeof data.removedCount === 'number' && Number.isSafeInteger(data.removedCount) && data.removedCount >= 0
        ? data.removedCount : 0
      const inserted = data.inserted.map((item, offset) => {
        const message = record(item)
        return { message, id: message ? messageId(message, `${fallback}:inbox:${offset}`) : `${fallback}:invalid:${offset}` }
      })
      const removed = queue.splice(start, removedCount, ...inserted.map(item => item.id))
      if (data.outcome === 'canceled') {
        for (const id of removed) if (!admitted.has(id)) display.delete(`user\0${id}`)
      }
      for (const { message, id } of inserted) {
        if (message && record(message.source)?.kind === 'user') add('user', message, id)
      }
    }
  }

  for (const { count, parts, entry } of translations.values()) {
    if (!entry) continue
    entry.text = [...parts].sort(([left], [right]) => left - right).map(([, text]) => text).join('\n\n')
    if (parts.size < count) entry.text += `\n\n已取得 ${parts.size}/${count} 段翻译。`
  }
  const messages = [...display.values()].sort((left, right) => left.order - right.order)
    .map(({ role, text, id, reply, plainQuestion }) => ({
      role, text, id, ...(plainQuestion ? { plainQuestion } : {}), ...(reply ? { reply } : {}),
    }))
  return { messages, completedPart }
}
