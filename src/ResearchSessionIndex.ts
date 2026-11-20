import { createHash } from 'node:crypto'
import { researchPromptMetadata } from './ResearchHistory.js'

export interface ResearchHistoryRequest {
  workspaceId: string
  title: string
  material: string
  status: 'active' | 'archived' | 'all'
  offset: number
  revision?: string
}

export interface ResearchIndexSummary {
  sessionId: string
  cwd?: string
  updatedAt: number
  running: boolean
  blank: boolean
  origin?: 'subagent'
  parentSessionId?: string
  projections?: { asOfSeq?: number; values?: object }
}

interface MaterialIndexEntry {
  title: string
  source?: string
}

interface IndexedSession {
  title?: string
  materials: MaterialIndexEntry[]
}

/** Installed DSH rc.5 reads the logical live/persisted corpus without activating Agents. */
export interface ResearchSessionQuery {
  observeSession(
    id: string,
    options: { signal: AbortSignal; projectionMode: 'none' },
  ): Promise<{ events: readonly unknown[]; [Symbol.dispose](): void }>
}

const pageSize = 24
const observationConcurrency = 4
const searchKey = (value: string): string => value.normalize('NFKC').trim().toLowerCase()

export function projectedSessionTitle(summary: ResearchIndexSummary): string | undefined {
  const values = summary.projections?.values
  if (!values || !('title' in values)) return undefined
  return typeof values.title === 'string' ? values.title.trim() || undefined : undefined
}

/** Retain only the indexed labels, never prompt excerpts, user questions, or other text. */
export function indexResearchSession(events: readonly unknown[]): IndexedSession {
  let title: string | undefined
  const entries = new Map<string, MaterialIndexEntry>()
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = historyRecord(events[index])
    const data = historyRecord(event?.data)
    if (!data) continue
    if (event?.type === 'session/title' && title === undefined && typeof data.title === 'string') {
      title = data.title.trim()
    }
    // Only a committed human prompt through the research app represents a
    // sent material. Ignore queued/cancelled, tooling, and ordinary DSH text.
    if (event?.type !== 'user/message' || !Array.isArray(data.content)) continue
    const sourceRecord = historyRecord(data.source)
    if (sourceRecord?.kind !== 'user' || typeof sourceRecord.rpcId !== 'string'
      || !/^dsh-pet-[0-9a-f-]{36}$/iu.test(sourceRecord.rpcId)) continue
    const text = data.content.flatMap((value: unknown) => {
      const block = historyRecord(value)
      return block?.type === 'text' && typeof block.text === 'string' ? [block.text] : []
    }).join('\n')
    const snapshot = researchPromptMetadata(text)?.material
    if (!snapshot) continue
    // An explicit capture can have a descriptive source and a distinct URL.
    const source = [snapshot.source, snapshot.url].filter((value, index, values) =>
      value && values.indexOf(value) === index).join(' · ')
    const id = JSON.stringify([snapshot.title, source])
    if (!entries.has(id)) entries.set(id, { title: snapshot.title, ...(source ? { source } : {}) })
  }
  return { ...(title ? { title } : {}), materials: Array.from(entries.values()) }
}

function historyRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : undefined
}

export async function researchSessionIndexPage(options: {
  request: ResearchHistoryRequest
  summaries: readonly ResearchIndexSummary[]
  membership: ReadonlySet<string>
  archived: ReadonlySet<string>
  titleFor: (summary: ResearchIndexSummary) => string
  query: ResearchSessionQuery
  signal: AbortSignal
  stillInWorkspace: (id: string, archived: boolean) => boolean
}) {
  const { request, summaries, membership, archived, titleFor, query, signal } = options
  const titleQuery = searchKey(request.title)
  const materialQuery = searchKey(request.material)
  const rows = summaries
    .filter(summary => membership.has(summary.sessionId) && summary.origin !== 'subagent')
    .map(summary => ({
      summary,
      title: titleFor(summary),
      archived: archived.has(summary.sessionId),
    }))
    .filter(row => request.status === 'all' || row.archived === (request.status === 'archived'))
    .sort((left, right) => right.summary.updatedAt - left.summary.updatedAt
      || left.summary.sessionId.localeCompare(right.summary.sessionId))
  const revision = createHash('sha256').update(JSON.stringify([
    request.title, request.material, request.status,
    rows.map(({ summary, title, archived }) => [
      summary.sessionId, summary.updatedAt, summary.projections?.asOfSeq, title, archived,
    ]),
  ])).digest('base64url')
  if (request.offset && revision !== request.revision) return { stale: true as const }
  if (request.offset === 0 && request.revision === revision) return { unchanged: true as const }
  const candidates = rows.slice(request.offset, request.offset + pageSize)
  const resultsByID = new Map<string, IndexedSession>()
  let nextCandidate = 0
  const readers = Array.from({ length: Math.min(candidates.length, observationConcurrency) }, async () => {
    while (!signal.aborted && nextCandidate < candidates.length) {
      const id = candidates[nextCandidate++].summary.sessionId
      try {
        const observation = await query.observeSession(id, { signal, projectionMode: 'none' })
        try {
          signal.throwIfAborted()
          resultsByID.set(id, indexResearchSession(observation.events))
        } finally {
          observation[Symbol.dispose]()
        }
      } catch {
        // This failed observation is counted below without aborting other rows.
        resultsByID.delete(id)
      }
    }
  })
  await Promise.all(readers)
  signal.throwIfAborted()
  if (candidates.some(row => !options.stillInWorkspace(row.summary.sessionId, row.archived))) {
    return { stale: true as const }
  }
  let unreadable = 0
  const matches = candidates.flatMap(({ summary, title: fallbackTitle, archived }) => {
    const indexed = resultsByID.get(summary.sessionId)
    if (!indexed) unreadable += 1
    const title = indexed?.title ?? fallbackTitle
    if (titleQuery && !searchKey(title).includes(titleQuery)) return []
    const materials = indexed?.materials ?? []
    const matching = materialQuery ? materials.filter(material =>
      [material.title, material.source ?? ''].some(label => searchKey(label).includes(materialQuery))) : materials
    if (materialQuery && !matching.length) return []
    return [{
      sessionId: summary.sessionId, workspaceId: request.workspaceId, title, archived, updatedAt: summary.updatedAt,
      running: summary.running, blank: summary.blank,
      // Complete metadata is used when searching. Only a few labels are
      // necessary to identify the rows in the compact history popover.
      materials: matching.slice(0, 3),
    }]
  })
  const nextOffset = request.offset + candidates.length
  return {
    revision, matches, unreadable, scanned: nextOffset, totalToScan: rows.length,
    nextOffset: nextOffset < rows.length ? nextOffset : null,
  }
}
