/**
 * dsh-mac-pet host plugin — a Harness status bridge (no rendered browser UI, no
 * settings namespace) that tracks agent activity, serves a stable snapshot over
 * HTTP and a local Unix socket, and queues Session-open requests for the tiny
 * browser half.
 * Install
 * via `dsh plugin --profile web add dsh-mac-pet`.
 * @module dsh-mac-pet
 */

import { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-host-webserver'
import type { WebRoute } from '@deepseek-ai/dsh-host-webserver'
import type { PromptContentPart } from '@deepseek-ai/dsh-api-session-controller'
import type {} from '@deepseek-ai/dsh-workspace'
import type { Session } from '@deepseek-ai/dsh-session'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { createHash, randomUUID } from 'node:crypto'
import { basename, join, resolve } from 'node:path'
import { homedir } from 'node:os'
import { mkdir, readFile } from 'node:fs/promises'
import { ResearchRetirement } from './ResearchRetirement.js'
import { decodeResearchHistory, researchPromptMetadata } from './ResearchHistory.js'
import { projectedSessionTitle, researchSessionIndexPage, type ResearchIndexSummary, type ResearchSessionQuery } from './ResearchSessionIndex.js'
import {
  accountProviderAllowed, decodeResearchSelection, researchModelCatalog, sameResearchSelection, verifyResearchSelection,
  type ResearchModelRuntime, type ResearchSelection,
} from './ResearchModels.js'
import { researchDocumentPlan, type PlanningRuntime } from './ResearchDocumentPlan.js'
import { ResearchStream, type AssistantFrame } from './ResearchStream.js'
import { ZoteroContextProvider, researchPrompt, DEFAULT_PERSONA, noMemory } from './ResearchContext.js'
import {
  CommandBridge,
  type ImageAttachmentLimits,
  type DshPetTask,
  type DshPetWorkspace,
} from './CommandBridge.js'
import { LocalStateBridge, type MoodBridgePayload } from './LocalStateBridge.js'
import { detectHostApp } from './InstallDetection.js'
import {
  createHarnessInstanceDescriptor,
  HarnessInstanceManifest,
  instanceDiscoveryDirectory,
  refreshHarnessInstanceWebURL,
  type HarnessInstanceDescriptor,
} from './HarnessInstance.js'

export { CommandBridge } from './CommandBridge.js'
export { LocalStateBridge } from './LocalStateBridge.js'
export {
  createHarnessInstanceDescriptor,
  HarnessInstanceManifest,
  instanceDiscoveryDirectory,
  instanceManifestPath,
  refreshHarnessInstanceWebURL,
} from './HarnessInstance.js'
export type { HarnessInstanceDescriptor, HarnessInstanceKind } from './HarnessInstance.js'

/** Stable cordis plugin name (matches cordis.patch.yml insert id). */
export const name = 'dsh-research-companion'

/** Services required before the status surface can mount. */
export const inject = ['webServer', 'workspaceRegistry', 'sessionController', 'attachments', 'llm', 'agentDefaultModel']

/** The mood the desktop app renders. */
export type DshPetMood =
  | 'idle'
  | 'waiting'
  | 'jumping'
  | 'done'
  | 'failed'
  | 'stopped'
  | 'authorizing'
  | 'questioning'

type DshPetResult = Extract<DshPetMood, 'done' | 'failed' | 'stopped'>

function stateForMood(mood: DshPetMood): DshPetTask['state'] {
  switch (mood) {
    case 'waiting': return 'thinking'
    case 'jumping': return 'toolCalling'
    case 'authorizing': return 'waitingApproval'
    case 'questioning': return 'waitingUserAnswer'
    case 'done': return 'completed'
    case 'failed': return 'failed'
    case 'stopped': return 'stopped'
    case 'idle': return 'idle'
    default: return 'disconnected'
  }
}

function isRunningMood(mood: DshPetMood): boolean {
  return ['waiting', 'jumping', 'authorizing', 'questioning'].includes(mood)
}

/** Write one JSON response. */
function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(body))
}

/**
 * Register the DSH Pet status surface: fold the agent session stream into a
 * stable snapshot, serve it over GET /api/dsh-pet/status, and broadcast the
 * same snapshot through LocalStateBridge. The route is always live while the
 * plugin is loaded — there is no settings namespace to toggle.
 * @param ctx - host root context.
 */
export function apply(ctx: Context): void {
  // All pet commands are scoped to one new workspace; existing sessions stay private.
  const legacyWorkspace = join(homedir(), 'Documents', 'Codex', 'ResearchCompanionWorkspace')
  const registeredLegacy = ctx.workspaceRegistry.list().some(workspace => workspace.path === legacyWorkspace)
  const researchWorkspacePath = resolve(process.env.DSH_RESEARCH_WORKSPACE ?? (registeredLegacy ? legacyWorkspace
    : join(homedir(), 'Library', 'Application Support', 'Research Companion', 'Workspace')))
  let researchWorkspaceId: string | undefined
  let researchCanonicalPath = researchWorkspacePath
  const workspaceReady = mkdir(researchWorkspacePath, { recursive: true, mode: 0o700 })
    .then(() => ctx.workspaceRegistry.create(researchWorkspacePath, '科研助手')).then(workspace => { researchWorkspaceId = String(workspace.id); researchCanonicalPath = workspace.path; return workspace })
  const contextProvider = new ZoteroContextProvider()
  const persona = async (): Promise<string> => {
    try {
      const data = JSON.parse(await readFile(join(researchWorkspacePath, 'persona.json'), 'utf8'))
      return typeof data.instruction === 'string' ? data.instruction.slice(0, 8000) : DEFAULT_PERSONA
    } catch { return DEFAULT_PERSONA }
  }
  const isResearchWorkspace = (id: string): boolean => {
    const workspace = ctx.workspaceRegistry.get(id as never)
    return workspace !== undefined && String(workspace.id) === researchWorkspaceId
  }
  const requireResearchSession = (sessionId: string): void => {
    if (!ctx.workspaceRegistry.list().some(w => String(w.id) === researchWorkspaceId && w.sessionIds.some(id => String(id) === sessionId))) {
      throw new Error('This companion only accesses its dedicated research workspace')
    }
  }
  interface SessionMoodState {
    sessionId?: string
    workspaceId?: string
    mood: DshPetMood
    holdUntil: number
    questionActive: boolean
    /** Last terminal result stays on the task card until its next turn. */
    lastResult?: DshPetResult
    tool?: string
    message?: string
  }

  const globalState: SessionMoodState = {
    mood: 'idle',
    holdUntil: 0,
    questionActive: false,
  }
  const sessionStates = new Map<string, SessionMoodState>()
  const unconfirmedSessions = new Set<string>()
  const sessionOperations = new Map<string, Promise<void>>()
  const pendingModelRuns = new Map<string, { requestId: string; selection: ResearchSelection; turn?: number }>()
  // One non-durable fingerprint per recent session, observable only by exact
  // request ID. This is the DSH adapter-entry request, not a server receipt.
  const dispatchEvidence = new Map<string, {requestId: string; selection: ResearchSelection; sha256: string; utf16Length: number}>()
  const recentModelReceipts = new Map<string, { requestId: string; selection: ResearchSelection }>()
  const streams = new Map<string, { stream: ResearchStream; revision: number; publishTimer?: ReturnType<typeof setTimeout> }>()
  let streamRevision = 0
  let taskSnapshot: DshPetTask[] = []
  let taskRefreshTimer: ReturnType<typeof setTimeout> | undefined
  // Task cards only need a coarse refresh cadence. Rapid semantic events are
  // coalesced, and streaming chunks are ignored by the caller.
  const taskRefreshDelayMs = 500
  let refreshTaskSnapshot: ((timeoutMs?: number) => Promise<readonly DshPetTask[]>) | undefined
  let activeSessionId: string | undefined
  let commandBridge: CommandBridge | undefined
  const instance: HarnessInstanceDescriptor = createHarnessInstanceDescriptor(ctx)
  const instanceManifest = new HarnessInstanceManifest(
    instance,
    process.env.DSH_PET_INSTANCE_DIRECTORY ?? instanceDiscoveryDirectory(),
  )
  let statusReady = false
  let commandReady = false
  let originRetryTimer: ReturnType<typeof setTimeout> | undefined
  let instanceManifestPublished = false
  const publishInstanceManifest = (): void => {
    if (!statusReady || !commandReady || instanceManifestPublished) return
    const hasOriginGetter = typeof (ctx as unknown as { webServer?: { getOrigin?: unknown } }).webServer?.getOrigin === 'function'
    if (instance.kind === 'web' && hasOriginGetter && !refreshHarnessInstanceWebURL(instance, ctx)) {
      originRetryTimer ??= setTimeout(() => {
        originRetryTimer = undefined
        publishInstanceManifest()
      }, 100)
      return
    }
    refreshHarnessInstanceWebURL(instance, ctx)
    try {
      instanceManifest.publish()
      instanceManifestPublished = true
    } catch (error) {
      console.warn(`[dsh-pet] instance discovery unavailable: ${String(error)}`)
    }
  }

  const stateFor = (sessionId: string, workspaceId?: string): SessionMoodState => {
    const existing = sessionStates.get(sessionId)
    if (existing) {
      if (workspaceId) existing.workspaceId = workspaceId
      return existing
    }
    const created: SessionMoodState = {
      sessionId,
      workspaceId,
      mood: 'idle',
      holdUntil: 0,
      questionActive: false,
    }
    sessionStates.set(sessionId, created)
    return created
  }

  const workspaceForSession = (sessionId: string): string | undefined => {
    const workspace = ctx.workspaceRegistry.list().find(candidate =>
      candidate.sessionIds.some(candidateSessionId => String(candidateSessionId) === sessionId),
    )
    return workspace ? String(workspace.id) : undefined
  }

  const snapshotOf = (state: SessionMoodState): MoodBridgePayload => ({
    instanceId: instance.instanceId,
    state: stateForMood(state.mood),
    mood: state.mood,
    ...(state.sessionId ? { sessionId: state.sessionId } : {}),
    ...(state.workspaceId ? { workspaceId: state.workspaceId } : {}),
    taskRunning: ['waiting', 'jumping', 'authorizing', 'questioning'].includes(state.mood),
    waitingForUser: state.mood === 'authorizing' || state.mood === 'questioning',
    failed: state.mood === 'failed',
    completed: state.mood === 'done',
    ...(state.tool ? { tool: state.tool } : {}),
    ...(state.message ? { message: state.message } : {}),
    updatedAt: Date.now(),
  })

  const snapshotForSession = (sessionId: string): MoodBridgePayload =>
    snapshotOf(stateFor(sessionId, workspaceForSession(sessionId)))

  const snapshotForTask = (task: DshPetTask): MoodBridgePayload => ({
    ...snapshotForSession(task.sessionId),
    state: task.state,
    mood: task.mood as DshPetMood,
    taskRunning: task.taskRunning,
    waitingForUser: task.waitingForUser,
    failed: task.failed,
    completed: task.completed,
  })

  const snapshot = (): MoodBridgePayload =>
    activeSessionId === undefined
      ? snapshotOf(globalState)
      : snapshotForSession(activeSessionId)

  const localBridge = new LocalStateBridge(snapshot, instance.statusSocketPath)

  const workspaceForSummary = (sessionId: string) => ctx.workspaceRegistry.list().find(workspace =>
    workspace.sessionIds.some(candidate => String(candidate) === sessionId),
  )

  const titleForSummary = (summary: ResearchIndexSummary, workspace: { title: string }): string => {
    const durableTitle = projectedSessionTitle(summary)
    if (durableTitle) return durableTitle
    const serviceContext = ctx as unknown as {
      get?: (name: string, strict?: boolean) => unknown
    }
    const sessions = serviceContext.get?.('sessions', false) as { get(id: string): Session | undefined } | undefined
    const titleService = serviceContext.get?.('sessionTitle', false) as {
      get(session: Session): { title?: string } | undefined
    } | undefined
    const liveSession = sessions?.get(summary.sessionId)
    const title = liveSession === undefined ? undefined : titleService?.get(liveSession)?.title
    if (title !== undefined && title.trim() !== '') return title

    const directory = summary.cwd === undefined ? '' : basename(summary.cwd)
    const suffix = summary.sessionId.slice(-8)
    return directory !== '' && directory !== workspace.title
      ? `${directory} · 会话 ${suffix}`
      : `会话 ${suffix}`
  }

  const tasksFromSummaries = (summaries: readonly ResearchIndexSummary[]): DshPetTask[] => summaries.flatMap(summary => {
    // The task center is for ordinary user sessions only. Child Agent rows
    // remain visible inside Harness and must not compete with their parent.
    if (summary.origin === 'subagent') return []
    const workspace = workspaceForSummary(summary.sessionId)
    if (workspace === undefined) return []

    const state = stateFor(summary.sessionId, String(workspace.id))
    let mood = state.mood
    if (summary.running && !isRunningMood(mood)) mood = 'waiting'
    if (!summary.running && isRunningMood(mood)) mood = 'idle'
    if (!summary.running && state.lastResult !== undefined) mood = state.lastResult
    const projected = snapshotOf({ ...state, mood, workspaceId: String(workspace.id) })
    return [{
      sessionId: summary.sessionId,
      workspaceId: String(workspace.id),
      title: titleForSummary(summary, workspace),
      ...(summary.cwd === undefined ? {} : { cwd: summary.cwd }),
      updatedAt: summary.updatedAt,
      running: summary.running,
      blank: summary.blank,
      state: projected.state as DshPetTask['state'],
      mood: projected.mood,
      taskRunning: summary.running || projected.taskRunning,
      waitingForUser: projected.waitingForUser,
      failed: projected.failed,
      completed: projected.completed,
      ...(projected.tool === undefined ? {} : { tool: projected.tool }),
      ...(projected.message === undefined ? {} : { message: projected.message }),
    }]
  })

  const scheduleTaskRefresh = (): void => {
    if (taskRefreshTimer !== undefined) return
    taskRefreshTimer = setTimeout(() => {
      taskRefreshTimer = undefined
      void refreshTaskSnapshot?.().catch(error => {
        console.warn(`[dsh-pet] task list refresh failed: ${String(error)}`)
      })
    }, taskRefreshDelayMs)
  }

  const publish = (state: SessionMoodState, refreshTasks = true): void => {
    localBridge.publish()
    if (state.sessionId) {
      const snapshot = snapshotOf(state)
      commandBridge?.publish(state.sessionId, unconfirmedSessions.has(state.sessionId)
        ? { ...snapshot, taskRunning: true, message: '无法确认任务状态，暂不可发送' }
        : snapshot)
    }
    if (refreshTasks) scheduleTaskRefresh()
  }

  // A transient mood (done / failed / stopped) holds for `ms` before reverting
  // to idle, so the colored reaction is visible instead of being swallowed by
  // the immediately following `activity/status` idle phase.
  const setTransient = (state: SessionMoodState, next: DshPetMood, ms: number): void => {
    state.mood = next
    if (next === 'done' || next === 'failed' || next === 'stopped') state.lastResult = next
    state.holdUntil = Date.now() + ms
    publish(state)
    setTimeout(() => {
      if (state.mood === next) {
        state.mood = 'idle'
        publish(state)
      }
    }, ms)
  }

  // Track each session independently. The global HTTP/socket snapshot follows
  // the most recently active session, while command subscribers receive only
  // the session they explicitly selected.
  ctx.on('session/event', (_session: Session, event: { type: string; data?: unknown }) => {
    const info = _session as unknown as { id?: string; sessionId?: string; workspaceId?: string }
    const sessionId = info.id ?? info.sessionId
    if (!sessionId || !isResearchWorkspace(info.workspaceId ?? workspaceForSession(sessionId) ?? '')) return
    const state = sessionId === undefined
      ? globalState
      : stateFor(sessionId, info.workspaceId ?? workspaceForSession(sessionId))
    if (sessionId) activeSessionId = sessionId

    if (event.type === 'turn/start' || event.type === 'step/start' || event.type === 'assistant/chunk') {
      state.lastResult = undefined
      state.mood = 'waiting'
      state.holdUntil = 0
      state.message = undefined
    } else if (event.type === 'tool/call') {
      state.lastResult = undefined
      const call = (event.data ?? {}) as { name?: string }
      state.tool = call.name
      if (call.name === 'ask_user_question') {
        state.questionActive = true
        state.mood = 'questioning'
        state.holdUntil = 0
      } else {
        state.mood = 'jumping'
        state.holdUntil = 0
      }
    } else if (event.type === 'tool/result') {
      const result = (event.data ?? {}) as { error?: { code?: string } }
      if (state.questionActive) {
        state.questionActive = false
        if (result.error !== undefined) setTransient(state, 'stopped', 1500)
        else {
          state.mood = 'waiting'
          state.holdUntil = 0
        }
      } else {
        state.mood = 'waiting'
        state.holdUntil = 0
      }
    } else if (event.type === 'approval/asked') {
      state.lastResult = undefined
      state.mood = 'authorizing'
      state.holdUntil = 0
    } else if (event.type === 'approval/decided') {
      const payload = (event.data ?? {}) as { outcome?: string; result?: string }
      const outcome = payload.outcome ?? payload.result
      if (outcome === 'allowed-once') {
        state.lastResult = undefined
        state.mood = 'waiting'
        state.holdUntil = 0
      } else if (outcome === 'rejected' || outcome === 'cancelled' || outcome === 'unavailable') {
        setTransient(state, 'failed', 3000)
      }
    } else if (event.type === 'activity/status') {
      const payload = (event.data ?? {}) as { phase?: string }
      if (payload.phase === undefined) return
      switch (payload.phase) {
        case 'waiting':
        case 'thinking':
          state.lastResult = undefined
          state.mood = 'waiting'
          state.holdUntil = 0
          state.message = undefined
          break
        case 'tool':
          if (state.questionActive) return
          state.lastResult = undefined
          state.mood = 'jumping'
          state.holdUntil = 0
          break
        case 'done':
          setTransient(state, 'done', 2500)
          break
        case 'idle':
          if (Date.now() < state.holdUntil) return
          state.mood = 'idle'
          state.tool = undefined
          state.message = undefined
          break
        default:
          break
      }
    } else if (event.type === 'turn/end') {
      // A turn without a pre-step (for example cancelled before dispatch) also
      // releases the bridge's admission fence.
      pendingModelRuns.delete(sessionId)
      state.questionActive = false
      const payload = (event.data ?? {}) as { reason?: { kind?: string } }
      const kind = payload.reason?.kind
      if (kind === 'error') setTransient(state, 'failed', 3000)
      else if (kind === 'completed') setTransient(state, 'done', 2500)
      else if (kind !== undefined) setTransient(state, 'stopped', 3000)
    }
    // Streaming chunks update the live pet/status immediately, but must not
    // trigger a session-list query per token. Turn/tool/approval boundaries
    // still refresh the task projection.
    publish(state, event.type !== 'assistant/chunk')
  })

  // Recheck the route at every step, including queued work after a global default change.
  ctx.on('agent/pre-step', async (request: any, next: () => Promise<any>) => {
    const sessionId = String(request.agent?.session?.id ?? request.agent?.id ?? '')
    const cwd = request.agent?.session?.header?.cwd ?? request.agent?.session?.cwd
    const scoped = isResearchWorkspace(workspaceForSession(sessionId) ?? '') || (typeof cwd === 'string' && (resolve(cwd) === researchCanonicalPath || resolve(cwd).startsWith(researchCanonicalPath + '/')))
    if (scoped && !accountProviderAllowed(request.modelSelection?.provider, llm())) {
      throw new Error('Research Companion refuses API-key model routes; check the DSH account or ChatGPT subscription.')
    }
    const pin = pendingModelRuns.get(sessionId)
    if (scoped && pin) {
      const isOurTurn = (pin.turn !== undefined && pin.turn === request.turn) || request.messages?.some(
        (message: { source?: { rpcId?: string } }) => message.source?.rpcId === pin.requestId,
      )
      if (isOurTurn) pin.turn = request.turn
      if (isOurTurn && !sameResearchSelection(pin.selection, decodeResearchSelection(request.modelSelection))) {
        throw new Error('会话模型在等待期间发生变化。本轮停止，未切换到其他模型。')
      }
    }
    return next()
  })

  ctx.on('llm/stream', (request, next) => {
    const sessionId = request.sessionId
    const pin = sessionId && pendingModelRuns.get(sessionId)
    if (sessionId && pin && request.provider === pin.selection.provider && request.model === pin.selection.model) {
      const message = request.messages.find(message => message.role === 'user' &&
        message.source && 'rpcId' in message.source && message.source.rpcId === pin.requestId)
      const selection = decodeResearchSelection(request)
      if (message && selection) {
        for (const block of message.content) {
          if (block.type !== 'text') continue
          const evidence = researchPromptMetadata(block.text)?.material
          if (evidence) {
            dispatchEvidence.set(sessionId, {requestId:pin.requestId, selection,
              sha256:createHash('sha256').update(evidence.text).digest('hex'), utf16Length:evidence.text.length})
            if (dispatchEvidence.size > 128) dispatchEvidence.delete(dispatchEvidence.keys().next().value!)
            break
          }
        }
      }
    }
    return next()
  })
  ctx.on('session/created', () => { scheduleTaskRefresh() })
  ctx.on('session/disposed', session => {
    const sessionId = String(session.id)
    sessionStates.delete(sessionId)
    pendingModelRuns.delete(sessionId)
    recentModelReceipts.delete(sessionId)
    dispatchEvidence.delete(sessionId)
    const active = streams.get(sessionId)
    if (active?.publishTimer) clearTimeout(active.publishTimer)
    streams.delete(sessionId)
    scheduleTaskRefresh()
  })

  ctx.on('agent/assistant-stream', ({ agent, frame }: {
    agent: { session: { id: string } }; frame: AssistantFrame;
  }) => {
    const sessionId = String(agent.session.id)
    if (!isResearchWorkspace(workspaceForSession(sessionId) ?? '')) return
    let active = streams.get(sessionId)
    if (frame.type === 'start') {
      if (active?.publishTimer) clearTimeout(active.publishTimer)
      active = { stream: new ResearchStream(frame.attemptId), revision: ++streamRevision }
      streams.set(sessionId, active)
      // Retain the previous displayed text until the corresponding history
      // arrives. A successful first delta replaces it below.
      return
    }
    if (!active || !active.stream.accept(frame)) return
    const changed = active
    changed.revision = ++streamRevision
    const publish = () => {
      changed.publishTimer = undefined
      commandBridge?.publishResearchStream(sessionId, visibleStream(sessionId))
    }
    if (changed.stream.closed) {
      if (changed.publishTimer) clearTimeout(changed.publishTimer)
      publish()
      if (changed.stream.finalSeq === undefined) streams.delete(sessionId)
    } else {
      changed.publishTimer ??= setTimeout(publish, 80)
    }
  }, { global: true })

  const retirement = new ResearchRetirement()
  type ConnectionGate = { on(name: 'connection/request', handler: (request: unknown, response: ServerResponse, next: () => Promise<void>) => Promise<unknown>): unknown }
  ;(ctx as unknown as ConnectionGate).on('connection/request', async (_request, response, next) => {
    if (retirement.quiescing) { response.writeHead(503); response.end(); return }
    return retirement.trackRequest(next)
  })
  const serializeSession = <T>(sessionId: string, operation: () => Promise<T>): Promise<T> => {
    if (retirement.quiescing) return Promise.reject(new Error('DSH 正在为已确认的会话删除准备正常退出。'))
    const previous = sessionOperations.get(sessionId) ?? Promise.resolve()
    const result = previous.then(operation)
    const settled = result.then(() => undefined, () => undefined)
    sessionOperations.set(sessionId, settled)
    void settled.then(() => {
      if (sessionOperations.get(sessionId) === settled) sessionOperations.delete(sessionId)
    })
    return result
  }

  interface PendingSessionOpen {
    requestId: string
    workspaceId: string
    sessionId: string
    deliveredAt?: number
    timer: ReturnType<typeof setTimeout>
    resolve: (accepted: boolean) => void
  }

  const pendingSessionOpens = new Map<string, PendingSessionOpen>()

  const settlePendingSessionOpen = (requestId: string, accepted: boolean): boolean => {
    const pending = pendingSessionOpens.get(requestId)
    if (pending === undefined) return false
    clearTimeout(pending.timer)
    pendingSessionOpens.delete(requestId)
    pending.resolve(accepted)
    return true
  }

  const requestSessionOpen = (workspaceId: string, sessionId: string): Promise<boolean> => {
    const requestId = randomUUID()
    return new Promise<boolean>(resolve => {
      const timer = setTimeout(() => {
        pendingSessionOpens.delete(requestId)
        resolve(false)
      }, 8_000)
      pendingSessionOpens.set(requestId, {
        requestId,
        workspaceId,
        sessionId,
        timer,
        resolve,
      })
    })
  }

  const optionalService = (name: string): unknown =>
    (ctx as unknown as { get?: (name: string, strict?: boolean) => unknown }).get?.(name, false)
  const researchSessionQuery = (): ResearchSessionQuery | undefined => {
    const value = optionalService('sessionQuery') as ResearchSessionQuery | undefined
    return typeof value?.observeSession === 'function' ? value : undefined
  }
  const archiveSessionIDs = (): readonly string[] | undefined => {
    const value = (ctx.workspaceRegistry as unknown as { archivedSessionIds?: readonly string[] }).archivedSessionIds
    return Array.isArray(value) ? value : undefined
  }
  const planningRuntime = () => optionalService('llm') as (ResearchModelRuntime & PlanningRuntime) | undefined
  const llm = (): ResearchModelRuntime | undefined => optionalService('llm') as ResearchModelRuntime | undefined
  const platformDefault = (): ResearchSelection | undefined => decodeResearchSelection(
    (optionalService('agentDefaultModel') as { currentSelection?: () => unknown } | undefined)?.currentSelection?.(),
  )
  // The development lock carries rc.1 declarations while the bridge's
  // supported runtime is rc.3, whose audited cold query surface is larger.
  type SessionState = { running?: boolean | { active?: boolean }; queue?: unknown[] | null }
  const coldQueries = ctx.sessionController as unknown as {
    state(request: { sessionId: string }, signal: AbortSignal): Promise<SessionState>
    events(request: { address: { kind: 'session'; sessionId: string }; maxMessages: number }, signal: AbortSignal):
      Promise<{ records?: unknown[]; cursor?: number; hasMore?: boolean }>
  }

  const requireWorkspaceSession = (workspaceId: string, sessionId: string): void => {
    const workspace = ctx.workspaceRegistry.get(workspaceId as never)
    if (workspace === undefined || !isResearchWorkspace(workspaceId) || !workspace.sessionIds.some(candidate => String(candidate) === sessionId)) {
      throw new Error(`session "${sessionId}" is not attached to workspace "${workspaceId}"`)
    }
  }

  const resolveAgent = async (sessionId: string): Promise<unknown> => {
    const controller = ctx.sessionController as unknown as {
      resolveAgent?: (id: string) => Promise<{ agent?: unknown; error?: unknown }>
    }
    if (typeof controller.resolveAgent !== 'function') throw new Error('Harness agent resolution is unavailable')
    const result = await controller.resolveAgent(sessionId)
    if (result.error !== undefined) throw result.error
    if (result.agent === undefined) throw new Error('Harness agent is unavailable')
    return result.agent
  }

  type ResearchAgent = { model?: { current?: () => unknown; select?: (selection: ResearchSelection) => void } }

  const requireIdle = async (sessionId: string): Promise<void> => {
    const state = await coldQueries.state({ sessionId }, AbortSignal.timeout(8_000))
    if (state.running === true || (typeof state.running === 'object' && state.running?.active === true)
      || (state.queue?.length ?? 0) > 0) {
      throw new Error('当前会话正在生成或还有待处理消息，请等本轮结束。')
    }
  }

  const installSessionSelection = (agent: ResearchAgent, selection: ResearchSelection): void => {
    const model = agent.model
    if (typeof model?.select !== 'function') throw new Error('当前 DSH 不能保存会话模型。')
    // The SessionController's GUI selectModel also writes the GLOBAL default
    // on rc.3. AgentModel.select only appends the native Session event.
    model.select(selection)
  }

  const admitResearchPrompt = async (request: {
    sessionId: string; requestId: string; expectedSelection?: ResearchSelection
  }, content: PromptContentPart[]) => {
    const prior = recentModelReceipts.get(request.sessionId)
    if (prior?.requestId === request.requestId) {
      return { accepted: true as const, sessionId: request.sessionId, selection: prior.selection }
    }
    const agent = await resolveAgent(request.sessionId) as ResearchAgent
    const original = decodeResearchSelection(agent.model?.current?.())
    if (!original || !accountProviderAllowed(original.provider, llm())) {
      throw new Error('科研助手仅允许已有 DSH 账号模型和 ChatGPT 订阅，已阻止 API Key 路由。')
    }
    if (request.expectedSelection && !sameResearchSelection(original, request.expectedSelection)) {
      throw new Error('会话模型已变化，请核对右上方的模型及强度后重新发送。')
    }
    const selection = await verifyResearchSelection(llm(), original)
    await requireIdle(request.sessionId)
    if (!sameResearchSelection(original, decodeResearchSelection(agent.model?.current?.()))) {
      throw new Error('会话模型已变化，请刷新后重新发送。')
    }
    if (!sameResearchSelection(original, selection)) installSessionSelection(agent, selection)
    const pin = { requestId: request.requestId, selection }
    pendingModelRuns.set(request.sessionId, pin)
    try {
      await ctx.sessionController.prompt({ requestId: request.requestId as never, sessionId: request.sessionId as never,
        mode: 'queue', content }, AbortSignal.timeout(30_000))
      recentModelReceipts.set(request.sessionId, { requestId: request.requestId, selection })
      if (recentModelReceipts.size > 128) recentModelReceipts.delete(recentModelReceipts.keys().next().value!)
      return { accepted: true as const, sessionId: request.sessionId, selection }
    } catch (error) {
      if (pendingModelRuns.get(request.sessionId) === pin) pendingModelRuns.delete(request.sessionId)
      throw error
    }
  }

  function visibleStream(sessionId: string, cursor?: number) {
    const active = streams.get(sessionId)
    if (!active) return { revision: streamRevision, message: null, settled: false }
    const done = active.stream.finalSeq !== undefined
    const consumed = done && cursor !== undefined && cursor >= active.stream.finalSeq!
    if (consumed) streams.delete(sessionId)
    return { revision: active.revision, message: consumed ? null : active.stream.visible(),
      settled: active.stream.closed, failed: active.stream.closed && !done }
  }

  const optionalCapabilities = (): string[] => {
    const resolveAvailable = typeof (ctx.sessionController as unknown as { resolveAgent?: unknown }).resolveAgent === 'function'
    const files = optionalService('sessionFileReferences') as { list?: unknown } | undefined
    const skills = optionalService('sessionSkillCatalog') as { list?: unknown } | undefined
    const commands = optionalService('commands') as { list?: unknown } | undefined
    return [
      ...(resolveAvailable && typeof files?.list === 'function' ? ['fileCandidates'] : []),
      ...(resolveAvailable && typeof skills?.list === 'function' && typeof commands?.list === 'function' ? ['skillCandidates'] : []),
      ...(typeof (ctx.sessionController as unknown as { projections?: unknown }).projections === 'function' ? ['taskPreview'] : []),
      'researchContext', 'researchPrompt', 'conversation', 'researchStream', 'researchMaterial',
      ...(researchSessionQuery() !== undefined && archiveSessionIDs() !== undefined ? ['researchHistory'] : []),
      ...(retirement.available(optionalService) ? ['researchSafeDelete','research.retirement.offline.v1'] : []),
      ...(retirement.onlineAvailable(optionalService) ? ['research.retirement.online.v1'] : []),
      ...(resolveAvailable && llm() ? ['modelCatalog', 'researchSelectModel'] : []),
      ...(resolveAvailable && typeof planningRuntime()?.stream === 'function' ? ['researchDocumentPlan'] : []),
    ]
  }

  commandBridge = new CommandBridge({
    imageAttachmentLimits: (ctx as unknown as {
      attachments: { imageLimits: ImageAttachmentLimits }
    }).attachments.imageLimits,
    listWorkspaces: async (): Promise<readonly DshPetWorkspace[]> => { await workspaceReady; return Promise.all(
      ctx.workspaceRegistry.list().filter(w => isResearchWorkspace(String(w.id))).map(async workspace => ({
        id: String(workspace.id),
        title: workspace.title,
        path: workspace.path,
        status: await workspace.status(),
        sessionIds: workspace.sessionIds.map(String),
      })),
    ) },
    listTasks: async (): Promise<readonly DshPetTask[]> => {
      if (refreshTaskSnapshot !== undefined) return refreshTaskSnapshot()
      return taskSnapshot
    },
    researchRetirement: async request => {
      const workspace=await workspaceReady
      const runtime=ctx as unknown as { waterfall(name:string, payload:{sessionId:string}, next:()=>Promise<unknown[]>): Promise<{kind:string}[]> }
      return retirement.plan(request,{
        workspaceId:String(workspace.id), cwd:researchCanonicalPath, sessionIds:workspace.sessionIds.map(String),
        service:optionalService, anyBridgeWork:()=>sessionOperations.size>0,
        hasScheduledWork:async id=>(await runtime.waterfall('workspace/session-activity',{sessionId:id},async()=>[])).some(e=>e.kind==='schedule'),
      })
    },
    researchHistory: async request => {
      await workspaceReady
      const workspace = ctx.workspaceRegistry.get(request.workspaceId as never)
      if (!workspace || !isResearchWorkspace(request.workspaceId)) throw new Error('仅可查询科研工作区历史。')
      const query = researchSessionQuery()
      const archiveIDs = archiveSessionIDs()
      if (!query || !archiveIDs) throw new Error('当前 DSH 无法读取完整历史或归档状态。')
      const signal = AbortSignal.timeout(8_000)
      const summaries = await ctx.sessionController.list({}, signal)
      return researchSessionIndexPage({
        request, summaries: summaries.items, membership: new Set(workspace.sessionIds.map(String)),
        archived: new Set(archiveIDs.map(String)), titleFor: summary => titleForSummary(summary, workspace),
        query, signal, stillInWorkspace: (id, wasArchived) => {
          const current = ctx.workspaceRegistry.get(request.workspaceId as never)
          return isResearchWorkspace(request.workspaceId) === true
            && (current?.sessionIds.some(candidate => String(candidate) === id) ?? false)
            && (archiveSessionIDs()?.some(candidate => String(candidate) === id) ?? false) === wasArchived
        },
      })
    },
    createSession: request => serializeSession(request.sessionId, async () => {
      const workspace = ctx.workspaceRegistry.get(request.workspaceId as never)
      if (workspace === undefined || !isResearchWorkspace(request.workspaceId)) throw new Error("Only the research workspace is available")
      const alreadyAttached = workspace.sessionIds.some(id => String(id) === request.sessionId)
      const result = await ctx.sessionController.create({
        workspaceId: workspace.id,
        sessionId: request.sessionId as never,
      })
      stateFor(String(result.sessionId), String(workspace.id)).workspaceId = String(workspace.id)
      if (request.title !== undefined && !alreadyAttached && String(result.sessionId) === request.sessionId) {
        // An explicitly named new Session never triggers an auxiliary model call
        // for automatic titles. Older Sessions are intentionally left untouched.
        await ctx.sessionController.rename({ sessionId: result.sessionId, title: request.title })
      }
      return { sessionId: String(result.sessionId) }
    }),
    openSession: async request => {
      const workspace = ctx.workspaceRegistry.get(request.workspaceId as never)
      if (workspace === undefined || !isResearchWorkspace(request.workspaceId)) throw new Error("Only the research workspace is available")
      if (!workspace.sessionIds.some(candidate => String(candidate) === request.sessionId)) {
        throw new Error(`session "${request.sessionId}" is not attached to workspace "${request.workspaceId}"`)
      }
      if (!await requestSessionOpen(request.workspaceId, request.sessionId)) {
        const error = new Error('Harness client did not acknowledge the session open')
        Object.assign(error, { code: 'desktop-client-unavailable' })
        throw error
      }
      return { accepted: true as const, sessionId: request.sessionId }
    },
    prompt: request => serializeSession(request.sessionId, async () => {
      const workspace = ctx.workspaceRegistry.get(request.workspaceId as never)
      if (workspace === undefined || !isResearchWorkspace(request.workspaceId)) throw new Error("Only the research workspace is available")
      if (!workspace.sessionIds.some(candidate => String(candidate) === request.sessionId)) {
        throw new Error(`session "${request.sessionId}" is not attached to workspace "${request.workspaceId}"`)
      }
      const content: PromptContentPart[] = [
        ...(request.text.trim() === '' ? [] : [{ type: 'text' as const, text: request.text }]),
        ...request.images.map(image => ({ type: 'image' as const, ...image })),
      ]
      return admitResearchPrompt(request, content)
    }),
    modelCatalog: async () => ({ ...(await researchModelCatalog(llm())), defaultSelection: platformDefault() }),
    researchDocumentPlan: request => serializeSession(request.sessionId, async () => {
      requireWorkspaceSession(request.workspaceId, request.sessionId)
      const runtime = planningRuntime()
      if (!runtime?.stream) throw new Error('当前 DSH 未提供文档取证模型接口。')
      const agent = await resolveAgent(request.sessionId) as ResearchAgent
      const current = () => decodeResearchSelection(agent.model?.current?.())
      if (!sameResearchSelection(request.selection, current())) throw new Error('会话模型已变化，请重新提交文件问题。')
      const selection = await verifyResearchSelection(runtime, request.selection)
      await requireIdle(request.sessionId)
      request.signal.throwIfAborted()
      if (!sameResearchSelection(request.selection, current())) throw new Error('会话模型已变化，已取消取证。')
      const plan = await researchDocumentPlan(runtime, selection, request.document, request.text, request.signal)
      request.signal.throwIfAborted()
      if (!sameResearchSelection(request.selection, current())) throw new Error('会话模型已变化，已丢弃旧取证请求。')
      return {plan, documentId:request.document.id, selection}
    }),
    researchSelectModel: request => serializeSession(request.sessionId, async () => {
      requireWorkspaceSession(request.workspaceId, request.sessionId)
      const selection = await verifyResearchSelection(llm(), request.selection)
      const agent = await resolveAgent(request.sessionId) as ResearchAgent
      await requireIdle(request.sessionId)
      installSessionSelection(agent, selection)
      return { selected: selection }
    }),
    researchContext: async () => {
      try { return { context: await contextProvider.current() } }
      catch (error) { return { context: { key: '', title: '', text: '', available: false, error: String(error instanceof Error ? error.message : error) } } }
    },
    conversation: async ({ workspaceId, sessionId, knownHistory, verifyRequestId }) => {
      requireWorkspaceSession(workspaceId, sessionId)
      const [result, state, projection] = await Promise.all([
        coldQueries.events({ address: { kind: 'session', sessionId }, maxMessages: 100 }, AbortSignal.timeout(15_000)),
        coldQueries.state({ sessionId }, AbortSignal.timeout(15_000)),
        ctx.sessionController.projections({ sessionId: sessionId as never }, AbortSignal.timeout(15_000)),
      ]) as unknown as [any, any, any]
      const messages = decodeResearchHistory(result.records ?? [])
      const historyRevision = createHash('sha256').update(JSON.stringify(messages)).digest('base64url')
      const lastUsed = decodeResearchSelection(projection.values?.modelSelection?.lastUsed)
      const selection = decodeResearchSelection(projection.values?.modelSelection?.next) ?? lastUsed ?? platformDefault()
      const lastEnd = (result.records ?? []).slice().sort((a: any, b: any) => ((b.event ?? b).seq ?? -1) - ((a.event ?? a).seq ?? -1)).find((r: any) => (r.event ?? r).type === 'turn/end')
      const reason = (lastEnd?.event ?? lastEnd)?.data?.reason
      return { ...(knownHistory === historyRevision ? { historyUnchanged: true } : { messages }),
        ...(verifyRequestId ? {dispatchEvidence: dispatchEvidence.get(sessionId)?.requestId === verifyRequestId
          ? dispatchEvidence.get(sessionId) : null} : {}),
        historyRevision, hasMore: result.hasMore === true, cursor: result.cursor,
        running: state.running === true || (typeof state.running === 'object' && state.running?.active === true)
          || (state.queue?.length ?? 0) > 0,
        model: selection ? `${selection.provider} / ${selection.model}` : undefined,
        selection, lastUsed, stream: visibleStream(sessionId, result.cursor),
        ...(reason?.kind === 'error' ? { error: JSON.stringify(reason) } : {}) }
    },
    researchPrompt: request => serializeSession(request.sessionId, async () => {
      requireWorkspaceSession(request.workspaceId, request.sessionId)
      if (request.includeContext && !request.contextKey && !request.material) throw new Error('请先预览所选材料，再选择带入原文。普通聊天可关闭带入材料。')
      const context = request.includeContext ? request.material ?? await contextProvider.current() : null
      if (request.contextKey && context?.key !== request.contextKey) throw new Error('当前 Zotero 原文或选区已变化，请核对预览再发。')
      // The memory seam is disabled; no invisible retention or autonomous actions.
      await noMemory.recall(request.text)
      const text = researchPrompt(request.text, request.mode, context, await persona())
      return admitResearchPrompt(request, [{ type: 'text', text }])
    }),
    capabilities: optionalCapabilities,
    fileCandidates: async ({ workspaceId, sessionId, query }) => {
      requireWorkspaceSession(workspaceId, sessionId)
      const files = optionalService('sessionFileReferences') as {
        list: (agent: unknown, query: string, signal: AbortSignal) => Promise<readonly { path: string; kind: 'file' | 'directory' }[]>
      } | undefined
      if (files === undefined) throw new Error('Harness file reference service is unavailable')
      return { candidates: await files.list(await resolveAgent(sessionId), query, AbortSignal.timeout(15_000)) }
    },
    skillCandidates: async ({ workspaceId, sessionId }) => {
      requireWorkspaceSession(workspaceId, sessionId)
      const catalog = optionalService('sessionSkillCatalog') as {
        list: (request: { sessionId: string }, signal: AbortSignal) => Promise<{ skills: readonly { name: string; description: string }[] }>
      } | undefined
      const commands = optionalService('commands') as { list: (agent: unknown) => readonly { name: string }[] } | undefined
      if (catalog === undefined || commands === undefined) throw new Error('Harness skill or command service is unavailable')
      const agent = await resolveAgent(sessionId)
      const [listed, commandList] = await Promise.all([
        catalog.list({ sessionId }, AbortSignal.timeout(15_000)),
        Promise.resolve(commands.list(agent)),
      ])
      const names = new Set(commandList.map(command => command.name))
      return { skills: listed.skills.map(skill => ({ name: skill.name, description: skill.description, conflict: names.has(skill.name) })) }
    },
    taskPreview: async ({ workspaceId, sessionId }) => {
      requireWorkspaceSession(workspaceId, sessionId)
      const result = await ctx.sessionController.projections({ sessionId: sessionId as never }, AbortSignal.timeout(15_000)) as unknown as {
        kind?: string; values?: { turnOutline?: unknown }
      } | null
      if (result?.kind === 'migration-required') return { status: 'migration-required' as const }
      const outline = result?.values?.turnOutline
      if (!Array.isArray(outline)) return { status: 'unsupported' as const }
      const last = outline.at(-1) as { response?: unknown } | undefined
      if (typeof last?.response !== 'string' || last.response.trim() === '') return { status: 'empty' as const }
      return { status: 'available' as const, text: last.response }
    },
    snapshotFor: async sessionId => {
      requireResearchSession(sessionId)
      const snapshot = snapshotForSession(sessionId)
      let task: DshPetTask | undefined
      try {
        task = (await refreshTaskSnapshot?.(5_000))?.find(candidate => candidate.sessionId === sessionId)
      } catch (error) {
        console.warn(`[dsh-pet] unable to confirm session state: ${String(error)}`)
      }
      if (task !== undefined) return snapshotForTask(task)
      unconfirmedSessions.add(sessionId)
      return { ...snapshot, taskRunning: true, message: '无法确认任务状态，暂不可发送' }
    },
  }, instance.commandSocketPath, instance)

  refreshTaskSnapshot = async (timeoutMs = 15_000): Promise<readonly DshPetTask[]> => {
    await workspaceReady
    const listed = await ctx.sessionController.list({}, AbortSignal.timeout(timeoutMs))
    taskSnapshot = tasksFromSummaries(listed.items).filter(task => isResearchWorkspace(task.workspaceId))
    commandBridge?.publishTasks(taskSnapshot)
    for (const task of taskSnapshot) {
      if (unconfirmedSessions.delete(task.sessionId)) {
        commandBridge?.publish(task.sessionId, snapshotForTask(task))
      }
    }
    return taskSnapshot
  }

  ctx.effect(() => {
    const projections = optionalService('sessionProjections') as {
      onChanged?: (listener: (session: Session, key: string) => void) => () => void
    } | undefined
    const dispose = projections?.onChanged?.((session, key) => {
      if (key === 'turnOutline' && isResearchWorkspace(workspaceForSession(String(session.id)) ?? '')) commandBridge?.publishTaskPreviewChange(String(session.id))
    })
    return () => { dispose?.() }
  }, 'dsh-pet: reply projection updates')

  ctx.effect(() => {
    statusReady = false
    commandReady = false
    localBridge.start(() => {
      statusReady = true
      publishInstanceManifest()
    })
    commandBridge?.start(() => {
      commandReady = true
      publishInstanceManifest()
    })
    void refreshTaskSnapshot?.().catch(error => {
      console.warn(`[dsh-pet] initial task list unavailable: ${String(error)}`)
    })
    return () => {
      if (taskRefreshTimer !== undefined) clearTimeout(taskRefreshTimer)
      taskRefreshTimer = undefined
      for (const stream of streams.values()) if (stream.publishTimer) clearTimeout(stream.publishTimer)
      streams.clear()
      pendingModelRuns.clear()
      recentModelReceipts.clear()
      dispatchEvidence.clear()
      commandBridge?.stop()
      localBridge.stop()
      if (originRetryTimer !== undefined) clearTimeout(originRetryTimer)
      originRetryTimer = undefined
      instanceManifest.remove()
      instanceManifestPublished = false
      statusReady = false
      commandReady = false
    }
  }, 'dsh-pet: local bridges')

  /**
   * Named webServer routes bypass Harness's global authentication. Mirror the
   * install-status boundary on every route that exposes or mutates local state:
   * fail closed when the connection service is unavailable, and let its
   * requestRejection return 401/403 before the handler runs.
   */
  const rejectUnauthorizedRequest = (
    req: IncomingMessage,
    res: ServerResponse,
    unavailableBody: unknown,
  ): boolean => {
    let connection: { requestRejection?: (request: IncomingMessage) => number | undefined } | undefined
    try {
      connection = ctx.get('connection') as typeof connection
    } catch {
      json(res, 503, unavailableBody)
      return true
    }
    if (typeof connection?.requestRejection !== 'function') {
      json(res, 503, unavailableBody)
      return true
    }
    let rejection: number | undefined
    try {
      rejection = connection.requestRejection(req)
    } catch {
      json(res, 503, unavailableBody)
      return true
    }
    if (rejection !== undefined) {
      res.writeHead(rejection)
      res.end()
      return true
    }
    return false
  }

  const sessionOpenPendingRoute: WebRoute = {
    kind: 'exact',
    path: '/api/dsh-pet/session-open/pending',
    handler: (req: IncomingMessage, res: ServerResponse): void => {
      if (rejectUnauthorizedRequest(req, res, { ok: false, error: 'authorization-unavailable' })) return
      if (req.method !== 'GET') {
        json(res, 405, { ok: false, error: 'method-not-allowed' })
        return
      }
      const now = Date.now()
      const pending = [...pendingSessionOpens.values()].find(candidate =>
        candidate.deliveredAt === undefined || now - candidate.deliveredAt > 2_000)
      if (pending === undefined) {
        json(res, 200, { request: null })
        return
      }
      pending.deliveredAt = now
      json(res, 200, {
        request: {
          requestId: pending.requestId,
          workspaceId: pending.workspaceId,
          sessionId: pending.sessionId,
        },
      })
    },
  }

  const sessionOpenAckRoute: WebRoute = {
    kind: 'exact',
    path: '/api/dsh-pet/session-open/ack',
    handler: async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
      if (rejectUnauthorizedRequest(req, res, { ok: false, error: 'authorization-unavailable' })) return
      if (req.method !== 'POST') {
        json(res, 405, { ok: false, error: 'method-not-allowed' })
        return
      }
      let body = ''
      for await (const chunk of req) {
        body += String(chunk)
        if (Buffer.byteLength(body) > 4_096) {
          json(res, 413, { ok: false, error: 'request-too-large' })
          return
        }
      }
      let requestId: unknown
      try {
        requestId = JSON.parse(body).requestId
      } catch {
        requestId = undefined
      }
      if (typeof requestId !== 'string' || requestId === '') {
        json(res, 400, { ok: false, error: 'invalid-request' })
        return
      }
      if (!settlePendingSessionOpen(requestId, true)) {
        json(res, 404, { ok: false, error: 'unknown-request' })
        return
      }
      json(res, 200, { ok: true })
    },
  }

  const statusRoute: WebRoute = {
    kind: 'exact',
    path: '/api/dsh-pet/status',
    handler: (req: IncomingMessage, res: ServerResponse): void => {
      if (rejectUnauthorizedRequest(req, res, { ok: false, error: 'authorization-unavailable' })) return
      if (req.method !== 'GET') {
        json(res, 405, { ok: false, error: 'method-not-allowed' })
        return
      }
      json(res, 200, { ok: true, enabled: true, ...snapshot() })
    },
  }

  const installationStatusTtlMs = 45_000
  let installationCache: {
    status: Awaited<ReturnType<typeof detectHostApp>>
    checkedAt: number
  } | undefined
  let installationCheck: {
    promise: ReturnType<typeof detectHostApp>
    fresh: boolean
  } | undefined

  const detectInstallationStatus = async (
    fresh: boolean,
  ): Promise<Awaited<ReturnType<typeof detectHostApp>>> => {
    if (!fresh && installationCache !== undefined
      && Date.now() - installationCache.checkedAt < installationStatusTtlMs) {
      return installationCache.status
    }
    if (installationCheck !== undefined) {
      const inFlight = installationCheck
      const status = await inFlight.promise
      // A manual probe still gets a new osascript run when an automatic probe
      // was already in flight; concurrent manual requests share a fresh probe.
      if (!fresh || inFlight.fresh) return status
    }
    const check = { promise: detectHostApp(), fresh }
    installationCheck = check
    try {
      const status = await check.promise
      installationCache = { status, checkedAt: Date.now() }
      return status
    } finally {
      if (installationCheck === check) installationCheck = undefined
    }
  }

  const installationRoute: WebRoute = {
    kind: 'exact',
    path: '/api/dsh-pet/install-status',
    handler: async (req, res): Promise<void> => {
      if (rejectUnauthorizedRequest(req, res, { status: 'unknown' })) return
      if (req.method !== 'GET') {
        json(res, 405, { ok: false, error: 'method-not-allowed' })
        return
      }
      const manual = new URL(req.url ?? '/', 'http://localhost').searchParams.get('refresh') === '1'
      const status = await detectInstallationStatus(manual)
      res.setHeader('cache-control', 'no-store')
      json(res, 200, { status })
    },
  }

  // Route is always live: there is no settings namespace, so nothing can take
  // it down while the plugin is loaded.
  ctx.effect(() => {
    const dispose = ctx.webServer.register(statusRoute)
    const disposeInstallation = ctx.webServer.register(installationRoute)
    const disposePending = ctx.webServer.register(sessionOpenPendingRoute)
    const disposeAck = ctx.webServer.register(sessionOpenAckRoute)
    return () => {
      disposeAck()
      disposePending()
      for (const pending of pendingSessionOpens.values()) {
        clearTimeout(pending.timer)
        pending.resolve(false)
      }
      pendingSessionOpens.clear()
      disposeInstallation()
      dispose()
    }
  }, 'dsh-pet: status and session-open routes')
}
