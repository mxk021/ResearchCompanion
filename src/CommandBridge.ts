import type { Socket } from 'node:net'
import type { PromptContentPart } from '@deepseek-ai/dsh-api-session-controller'
import { UnixSocketServer } from './UnixSocketServer.js'
import type { MoodBridgePayload } from './LocalStateBridge.js'
import { windowsPipeAccess, type HarnessInstanceDescriptor } from './HarnessInstance.js'
import { decodeResearchSelection, type ResearchSelection } from './ResearchModels.js'
import { decodeInlineMaterial, type ResearchContext } from './ResearchContext.js'
import { decodePlanningDocument, type PlanningDocument } from './ResearchDocumentPlan.js'
import type { RetirementRequest } from './ResearchRetirement.js'
import type { ResearchHistoryRequest } from './ResearchSessionIndex.js'
import { decodeResearchPDFBatch, type ResearchPDFBatch } from './ResearchHistory.js'

type PromptImageMediaType = Extract<PromptContentPart, { type: 'image' }>['mediaType']

/** A detached workspace projection exposed to DSH Pet.app. */
export interface DshPetWorkspace {
  id: string
  title: string
  path: string
  status: 'ok' | 'missing-dir'
  sessionIds: readonly string[]
}

export interface CreateSessionCommand {
  workspaceId: string
  sessionId: string
  title?: string
}

export interface OpenSessionCommand {
  workspaceId: string
  sessionId: string
}

export interface PromptCommand {
  workspaceId: string
  sessionId: string
  requestId: string
  text: string
  images: readonly PromptImage[]
  expectedSelection?: ResearchSelection
}

export interface PromptImage {
  mediaType: PromptImageMediaType
  data: string
  name?: string
}

/** Deployment-resolved image admission policy exposed by Harness. */
export interface ImageAttachmentLimits {
  maxImageBytes: number
  maxImagesPerMessage: number
  maxMessageImageBytes: number
  maxImagePixels: number
  maxImageDimension: number
  mediaTypes: readonly string[]
}

/** A cold-safe ordinary Session projection for the task cards. */
export interface DshPetTask {
  sessionId: string
  workspaceId: string
  title: string
  cwd?: string
  updatedAt: number
  running: boolean
  blank: boolean
  state: 'disconnected' | 'idle' | 'thinking' | 'toolCalling' | 'waitingApproval' | 'waitingUserAnswer' | 'completed' | 'failed' | 'stopped'
  mood: string
  taskRunning: boolean
  waitingForUser: boolean
  failed: boolean
  completed: boolean
  tool?: string
  message?: string
}

export interface CommandHandlers {
  imageAttachmentLimits: ImageAttachmentLimits
  listWorkspaces: () => Promise<readonly DshPetWorkspace[]>
  listTasks: () => Promise<readonly DshPetTask[]>
  createSession: (request: CreateSessionCommand) => Promise<{ sessionId: string }>
  openSession: (request: OpenSessionCommand) => Promise<{ accepted: true; sessionId: string }>
  prompt: (request: PromptCommand) => Promise<{ accepted: true; sessionId: string }>
  snapshotFor: (sessionId: string) => MoodBridgePayload | undefined | Promise<MoodBridgePayload | undefined>
  conversation?: (request: OpenSessionCommand & { knownHistory?: string; verifyRequestId?: string }) => Promise<unknown>
  modelCatalog?: () => Promise<unknown>
  researchSelectModel?: (request: OpenSessionCommand & { selection: ResearchSelection }) => Promise<unknown>
  researchContext?: () => Promise<unknown>
  researchDocumentPlan?: (request: OpenSessionCommand & { text: string; document: PlanningDocument; selection: ResearchSelection; signal: AbortSignal }) => Promise<unknown>
  researchRetirement?: (request: RetirementRequest) => Promise<unknown>
  researchHistory?: (request: ResearchHistoryRequest) => Promise<unknown>
  researchPrompt?: (request: OpenSessionCommand & { requestId: string; text: string; mode: string; evidencePolicy?: 'discussion'; guidance?: string; pdfBatch?: ResearchPDFBatch; contextKey?: string; includeContext: boolean; expectedSelection?: ResearchSelection; material?: ResearchContext; documentImages: readonly PromptImage[]; userImages: readonly PromptImage[] }) => Promise<unknown>
  capabilities?: () => readonly string[]
  fileCandidates?: (request: OpenSessionCommand & { query: string }) => Promise<{ candidates: readonly { path: string; kind: 'file' | 'directory' }[] }>
  skillCandidates?: (request: OpenSessionCommand) => Promise<{ skills: readonly { name: string; description: string; conflict: boolean }[] }>
  taskPreview?: (request: OpenSessionCommand) => Promise<{ status: 'available' | 'empty' | 'unsupported' | 'migration-required'; text?: string }>
}

interface ClientState {
  socket: Socket
  buffer: string
  bufferBytes: number
  discardingOversizedLine: boolean
  subscriptions: Set<string>
  taskSubscription: boolean
  operationTail: Promise<void>
}

interface CommandRequest {
  id?: unknown
  action?: unknown
  createdAt?: unknown
  workspaceId?: unknown
  sessionId?: unknown
  title?: unknown
  requestId?: unknown
  text?: unknown
  images?: unknown
  userImages?: unknown
  query?: unknown
  mode?: unknown
  guidance?: unknown
  pdfBatch?: unknown
  contextKey?: unknown
  includeContext?: unknown
  evidencePolicy?: unknown
  material?: unknown
  document?: unknown
  selection?: unknown
  knownHistory?: unknown
  historyTitle?: unknown
  historyMaterial?: unknown
  historyStatus?: unknown
  historyOffset?: unknown
  historyRevision?: unknown
}

const COMMAND_METADATA_BYTES = 1024 * 1024

class CommandError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message)
    this.name = 'CommandError'
  }
}

/**
 * User-local command and session-status transport.
 *
 * This socket is intentionally separate from LocalStateBridge. Older DSH Pet
 * clients continue to receive the global read-only snapshot, while new
 * clients can issue authenticated-by-file-permission commands and subscribe
 * to one selected session without mixing command responses into that stream.
 */
export class CommandBridge {
  private readonly handlers: CommandHandlers
  private readonly instance: HarnessInstanceDescriptor | undefined
  private readonly maxCommandBytes: number
  private readonly socketServer: UnixSocketServer
  private clients = new Set<ClientState>()

  constructor(
    handlers: CommandHandlers,
    socketPath: string,
    instance?: HarnessInstanceDescriptor,
  ) {
    this.handlers = handlers
    this.instance = instance
    this.maxCommandBytes = maxCommandBytes(handlers.imageAttachmentLimits)
    this.socketServer = new UnixSocketServer({
      socketPath,
      label: 'command bridge',
      windowsAccess: windowsPipeAccess(instance),
      onConnection: socket => this.attachClient(socket),
      onStop: () => {
        for (const client of this.clients) client.socket.destroy()
        this.clients.clear()
      },
    })
  }

  start(onReady?: () => void): void {
    this.socketServer.start(onReady)
  }

  private attachClient(socket: Socket): void {
    const client: ClientState = {
      socket,
      buffer: '',
      bufferBytes: 0,
      discardingOversizedLine: false,
      subscriptions: new Set(),
      taskSubscription: false,
      operationTail: Promise.resolve(),
    }
    this.clients.add(client)
    socket.setNoDelay(true)
    socket.setEncoding('utf8')
    socket.on('data', chunk => {
      let text = String(chunk)
      if (client.discardingOversizedLine) {
        const newline = text.indexOf('\n')
        if (newline < 0) return
        client.discardingOversizedLine = false
        text = text.slice(newline + 1)
      }
      client.buffer += text
      client.bufferBytes += Buffer.byteLength(text)
      this.consume(client)
    })
    socket.on('close', () => this.clients.delete(client))
    socket.on('error', () => this.clients.delete(client))
  }

  /** Push a replacement snapshot to clients subscribed to this session. */
  publish(sessionId: string, snapshot: MoodBridgePayload): void {
    for (const client of this.clients) {
      if (!client.subscriptions.has(sessionId)) continue
      this.write(client.socket, {
        event: 'status',
        sessionId,
        snapshot,
      })
    }
  }

  /** Publish a visible-only replacement for the currently assembling answer. */
  publishResearchStream(sessionId: string, state: unknown): void {
    for (const client of this.clients) {
      if (client.subscriptions.has(sessionId)) this.write(client.socket, { event: 'researchStream', sessionId, state })
    }
  }

  /** Push a replacement task projection to clients that requested task updates. */
  publishTasks(tasks: readonly DshPetTask[]): void {
    for (const client of this.clients) {
      if (!client.taskSubscription) continue
      this.write(client.socket, { event: 'tasks', tasks })
    }
  }

  /** Notify task subscribers that a session's reply projection changed. */
  publishTaskPreviewChange(sessionId: string): void {
    for (const client of this.clients) {
      if (client.taskSubscription) this.write(client.socket, { event: 'taskPreviewChanged', sessionId })
    }
  }

  stop(): void {
    this.socketServer.stop()
  }

  private consume(client: ClientState): void {
    while (true) {
      const newline = client.buffer.indexOf('\n')
      if (newline < 0) {
        if (client.bufferBytes > this.maxCommandBytes) {
          client.buffer = ''
          client.bufferBytes = 0
          client.discardingOversizedLine = true
          this.rejectOversizedRequest(client.socket)
        }
        return
      }
      const line = client.buffer.slice(0, newline)
      client.buffer = client.buffer.slice(newline + 1)
      client.bufferBytes -= Buffer.byteLength(`${line}\n`)
      if (line.trim() === '') continue
      if (Buffer.byteLength(line) > this.maxCommandBytes) {
        this.rejectOversizedRequest(client.socket)
        continue
      }
      client.operationTail = client.operationTail
        .then(() => this.handle(client, line))
        .catch(error => {
          this.write(client.socket, {
            id: null,
            ok: false,
            error: { code: 'internal-error', message: errorMessage(error) },
          })
        })
    }
  }

  private rejectOversizedRequest(socket: Socket): void {
    this.write(socket, {
      id: null,
      ok: false,
      error: { code: 'request-too-large', message: 'command request exceeds the deployment image limits' },
    })
  }

  private async handle(client: ClientState, line: string): Promise<void> {
    let request: CommandRequest
    try {
      request = JSON.parse(line) as CommandRequest
    } catch {
      this.write(client.socket, {
        id: null,
        ok: false,
        error: { code: 'invalid-json', message: 'request must be one JSON object per line' },
      })
      return
    }

    const id = typeof request.id === 'string' && request.id !== '' ? request.id : null
    const action = request.action
    try {
      if (action === 'capabilities') {
        this.respond(client.socket, id, {
          protocolVersion: 1,
          commandSocket: true,
          statusSubscription: true,
          supports: [
            'workspaces', 'tasks', 'subscribeTasks', 'unsubscribeTasks',
            'createSession', 'openSession', 'prompt', 'imageAttachments', 'subscribe', 'unsubscribe',
            ...(this.handlers.capabilities?.() ?? []),
          ],
          attachmentLimits: this.handlers.imageAttachmentLimits,
          maxCommandBytes: this.maxCommandBytes,
          ...(this.instance === undefined ? {} : { instance: this.instance }),
        })
        return
      }
      if (action === 'modelCatalog' && this.handlers.modelCatalog) {
        this.respond(client.socket, id, { catalog: await this.handlers.modelCatalog() }); return
      }
      if (action === 'researchDocumentPlan' && this.handlers.researchDocumentPlan) {
        const selection = selectionField(request.selection)
        if (!selection) throw new CommandError('invalid-request', '文档取证需要已绑定的模型。')
        const document = decodePlanningDocument(request.document)
        const abort = new AbortController()
        const closed = () => abort.abort()
        if (client.socket.destroyed) return
        client.socket.once('close', closed)
        try {
          this.respond(client.socket, id, await this.handlers.researchDocumentPlan({
            workspaceId: stringField(request.workspaceId, 'workspaceId'), sessionId: stringField(request.sessionId, 'sessionId'),
            text: stringField(request.text, 'text'), document, selection, signal: AbortSignal.any([abort.signal, AbortSignal.timeout(85_000)]),
          }))
        } finally { client.socket.off('close', closed) }
        return
      }
      if (action === 'researchSelectModel' && this.handlers.researchSelectModel) {
        const selection = selectionField(request.selection)
        if (!selection) throw new CommandError('invalid-request', 'selection is required')
        this.respond(client.socket, id, await this.handlers.researchSelectModel({
          workspaceId: stringField(request.workspaceId, 'workspaceId'), sessionId: stringField(request.sessionId, 'sessionId'),
          selection,
        })); return
      }
      if (action === 'researchContext' && this.handlers.researchContext) {
        this.respond(client.socket, id, await this.handlers.researchContext()); return
      }
      if (typeof action === 'string' && ['research-retirement-plan', 'research-retirement-prepare', 'research-retirement-online-plan', 'research-retirement-online-commit'].includes(action) && this.handlers.researchRetirement) {
        const targetTime=request.createdAt
        if (targetTime!==undefined && (typeof targetTime!=='number'||!Number.isSafeInteger(targetTime)||targetTime<0)) {
          throw new CommandError('invalid-request', '无效的会话时间。')
        }
        this.respond(client.socket,id,await this.handlers.researchRetirement({
          workspaceId:stringField(request.workspaceId,'workspaceId'),sessionId:stringField(request.sessionId,'sessionId'),
          ...(typeof targetTime==='number'?{createdAt:targetTime}:{}),prepare:action==='research-retirement-prepare' || action==='research-retirement-online-commit',
          ...(action.startsWith('research-retirement-online-') ? {online:true} : {}),
        }))
        return
      }
      if (action === 'researchHistory' && this.handlers.researchHistory) {
        const status = request.historyStatus
        const offset = request.historyOffset
        const revision = optionalStringField(request.historyRevision, 'historyRevision')
        const title = optionalStringField(request.historyTitle, 'historyTitle') ?? ''
        const material = optionalStringField(request.historyMaterial, 'historyMaterial') ?? ''
        if ((status !== 'active' && status !== 'archived' && status !== 'all')
          || typeof offset !== 'number' || !Number.isSafeInteger(offset) || offset < 0
          || title.length > 1_024 || material.length > 1_024
          || (revision !== undefined && !/^[A-Za-z0-9_-]{43}$/.test(revision))
          || (offset > 0 && revision === undefined)) {
          throw new CommandError('invalid-request', '无效的科研历史筛选条件。')
        }
        this.respond(client.socket, id, await this.handlers.researchHistory({
          workspaceId: stringField(request.workspaceId, 'workspaceId'), title, material, status, offset, revision,
        })); return
      }
      if (action === 'conversation' && this.handlers.conversation) {
        const candidate = request.knownHistory
        const knownHistory = typeof candidate === 'string' && /^[A-Za-z0-9_-]{43}$/.test(candidate)
          ? candidate : undefined
        this.respond(client.socket, id, await this.handlers.conversation({
          workspaceId: stringField(request.workspaceId, 'workspaceId'), sessionId: stringField(request.sessionId, 'sessionId'),
          ...(knownHistory ? { knownHistory } : {}),
          ...(request.requestId === undefined ? {} : {verifyRequestId: stringField(request.requestId, 'requestId')}),
        })); return
      }
      if (action === 'researchPrompt' && this.handlers.researchPrompt) {
        if (request.includeContext !== undefined && typeof request.includeContext !== 'boolean') throw new CommandError('invalid-request', 'includeContext must be boolean')
        const mode = optionalStringField(request.mode, 'mode') ?? 'ask'
        const evidencePolicy = request.evidencePolicy
        if (evidencePolicy !== undefined && (evidencePolicy !== 'discussion' || mode === 'translate')) {
          throw new CommandError('invalid-request', '材料核验策略无效。')
        }
        const contextKey = optionalStringField(request.contextKey, 'contextKey')
        const guidance = optionalStringField(request.guidance, 'guidance')?.trim()
        if (guidance && (guidance.length > 6000 || guidance.includes('\0'))) {
          throw new CommandError('invalid-request', 'guidance exceeds limit or contains invalid characters')
        }
        const pdfBatch = decodeResearchPDFBatch(request.pdfBatch)
        if (request.pdfBatch !== undefined && !pdfBatch) throw new CommandError('invalid-request', 'Invalid PDF batch')
        let material: ResearchContext | undefined
        if (request.material !== undefined) {
          if (contextKey || request.includeContext !== true) throw new CommandError('invalid-request', '材料不能与其他来源同时提交，且需明确开启带入。')
          try { material = decodeInlineMaterial(request.material) }
          catch (error) { throw new CommandError('invalid-request', error instanceof Error ? error.message : '材料无效。') }
        }
        const crops = imageArray(request.images, 'images')
        const attached = imageArray(request.userImages, 'userImages')
        if (crops.length > 4) {
          throw new CommandError('invalid-request', '原页裁图最多四处。')
        }
        const images = imageFields([...crops, ...attached], this.handlers.imageAttachmentLimits)
        const expectedSelection = selectionField(request.selection)
        if (pdfBatch && (!material || !expectedSelection)) {
          throw new CommandError('invalid-request', 'PDF tasks must bind an exact model and this segment’s material')
        }
        if (images.length && (!material || !expectedSelection)) {
          throw new CommandError('invalid-request', '联合问答的图片必须绑定确切模型和本轮原文。')
        }
        this.respond(client.socket, id, await this.handlers.researchPrompt({
          workspaceId: stringField(request.workspaceId, 'workspaceId'), sessionId: stringField(request.sessionId, 'sessionId'),
          requestId: stringField(request.requestId, 'requestId'), text: optionalStringField(request.text, 'text') ?? '',
          mode, evidencePolicy, guidance, pdfBatch, contextKey,
          includeContext: request.includeContext !== false, ...(material ? { material } : {}),
          expectedSelection, documentImages: images.slice(0, crops.length), userImages: images.slice(crops.length),
        })); return
      }
      if (action === 'workspaces') {
        this.respond(client.socket, id, { workspaces: await this.handlers.listWorkspaces() })
        return
      }
      if (action === 'tasks') {
        this.respond(client.socket, id, { tasks: await this.handlers.listTasks() })
        return
      }
      if (action === 'subscribeTasks') {
        client.taskSubscription = true
        this.respond(client.socket, id, { tasks: await this.handlers.listTasks() })
        return
      }
      if (action === 'unsubscribeTasks') {
        client.taskSubscription = false
        this.respond(client.socket, id, {})
        return
      }
      if (action === 'createSession') {
        const workspaceId = stringField(request.workspaceId, 'workspaceId')
        const sessionId = stringField(request.sessionId, 'sessionId')
        const title = optionalStringField(request.title, 'title')
        if (title !== undefined && (title.trim() === '' || title.length > 120)) {
          throw new CommandError('invalid-request', 'title must be a nonempty string of at most 120 characters')
        }
        const result = await this.handlers.createSession({ workspaceId, sessionId, ...(title === undefined ? {} : { title }) })
        this.respond(client.socket, id, result)
        return
      }
      if (action === 'openSession') {
        const workspaceId = stringField(request.workspaceId, 'workspaceId')
        const sessionId = stringField(request.sessionId, 'sessionId')
        const result = await this.handlers.openSession({ workspaceId, sessionId })
        this.respond(client.socket, id, result)
        return
      }
      if (action === 'fileCandidates' || action === 'skillCandidates' || action === 'taskPreview') {
        const workspaceId = stringField(request.workspaceId, 'workspaceId')
        const sessionId = stringField(request.sessionId, 'sessionId')
        if (!this.handlers.capabilities?.().includes(action)) {
          throw new CommandError('unsupported', `${action} is unavailable`)
        }
        if (action === 'fileCandidates' && this.handlers.fileCandidates !== undefined) {
          const query = optionalStringField(request.query, 'query') ?? ''
          this.respond(client.socket, id, await this.handlers.fileCandidates({ workspaceId, sessionId, query }))
        } else if (action === 'skillCandidates' && this.handlers.skillCandidates !== undefined) {
          this.respond(client.socket, id, await this.handlers.skillCandidates({ workspaceId, sessionId }))
        } else if (action === 'taskPreview' && this.handlers.taskPreview !== undefined) {
          this.respond(client.socket, id, await this.handlers.taskPreview({ workspaceId, sessionId }))
        } else {
          throw new CommandError('unsupported', `${action} is unavailable`)
        }
        return
      }
      if (action === 'prompt') {
        const workspaceId = stringField(request.workspaceId, 'workspaceId')
        const sessionId = stringField(request.sessionId, 'sessionId')
        const requestId = stringField(request.requestId, 'requestId')
        const text = optionalStringField(request.text, 'text') ?? ''
        const images = imageFields(request.images, this.handlers.imageAttachmentLimits)
        if (text.trim() === '' && images.length === 0) {
          throw new CommandError('empty-prompt', 'prompt must include non-whitespace text or an image')
        }
        const result = await this.handlers.prompt({ workspaceId, sessionId, requestId, text, images, expectedSelection: selectionField(request.selection) })
        this.respond(client.socket, id, result)
        return
      }
      if (action === 'subscribe') {
        const sessionId = stringField(request.sessionId, 'sessionId')
        const snapshot = await this.handlers.snapshotFor(sessionId)
        client.subscriptions.add(sessionId)
        this.respond(client.socket, id, { sessionId, snapshot: snapshot ?? null })
        return
      }
      if (action === 'unsubscribe') {
        const sessionId = stringField(request.sessionId, 'sessionId')
        client.subscriptions.delete(sessionId)
        this.respond(client.socket, id, { sessionId })
        return
      }
      throw new CommandError('unknown-action', 'unsupported DSH Pet command')
    } catch (error) {
      this.write(client.socket, {
        id,
        ok: false,
        error: {
          code: commandErrorCode(error),
          message: errorMessage(error),
        },
      })
    }
  }

  private respond(socket: Socket, id: string | null, result: unknown): void {
    this.write(socket, { id, ok: true, ...asObject(result) })
  }

  private write(socket: Socket, payload: unknown): void {
    if (!socket.destroyed) socket.write(`${JSON.stringify(payload)}\n`)
  }
}

function stringField(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new CommandError('invalid-request', `${name} must be a non-empty string`)
  }
  return value
}

function optionalStringField(value: unknown, name: string): string | undefined {
  if (value === undefined) return undefined
  if (typeof value !== 'string') throw new CommandError('invalid-request', `${name} must be a string`)
  return value
}

function selectionField(value: unknown): ResearchSelection | undefined {
  if (value === undefined) return
  const selection = decodeResearchSelection(value)
  if (!selection || [selection.provider, selection.model, selection.reasoningEffort].some(item => (item?.length ?? 0) > 200)) {
    throw new CommandError('invalid-request', 'selection must specify an exact provider and model')
  }
  return selection
}

function imageArray(value: unknown, field: string): readonly unknown[] {
  if (value === undefined) return []
  if (!Array.isArray(value)) throw new CommandError('invalid-request', `${field} must be an array`)
  return value
}

function imageFields(value: unknown, limits: ImageAttachmentLimits): readonly PromptImage[] {
  const images = imageArray(value, 'images')
  if (images.length > limits.maxImagesPerMessage) {
    throw new CommandError('session/attachment-invalid', 'Image batch exceeds the configured image-count limit.')
  }

  let aggregateBytes = 0
  return images.map((candidate, index) => {
    if (candidate === null || typeof candidate !== 'object' || Array.isArray(candidate)) {
      throw new CommandError('invalid-request', `images[${index}] must be an object`)
    }
    const image = candidate as Record<string, unknown>
    const mediaType = stringField(image.mediaType, `images[${index}].mediaType`)
    if (!limits.mediaTypes.includes(mediaType)) {
      throw new CommandError(
        'session/attachment-invalid',
        `Image type ${mediaType} is not accepted by this deployment.`,
      )
    }
    const data = stringField(image.data, `images[${index}].data`)
    const name = optionalStringField(image.name, `images[${index}].name`)
    const bytes = canonicalBase64Bytes(data)
    if (bytes > limits.maxImageBytes) {
      throw new CommandError('session/attachment-invalid', 'Image exceeds the configured image-byte limit.')
    }
    aggregateBytes += bytes
    if (aggregateBytes > limits.maxMessageImageBytes) {
      throw new CommandError('session/attachment-invalid', 'Image batch exceeds the configured aggregate image-byte limit.')
    }
    return { mediaType: mediaType as PromptImageMediaType, data, ...(name === undefined ? {} : { name }) }
  })
}

function canonicalBase64Bytes(data: string): number {
  if (data.length === 0 || data.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)) {
    throw new CommandError('session/attachment-invalid', 'Image upload is not canonical base64.')
  }
  const padding = data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0
  return (data.length / 4) * 3 - padding
}

function maxCommandBytes(limits: ImageAttachmentLimits): number {
  const aggregateBytes = Math.min(
    limits.maxMessageImageBytes,
    limits.maxImageBytes * limits.maxImagesPerMessage,
  )
  const base64Bytes = Math.ceil(aggregateBytes / 3) * 4
  return Math.min(Number.MAX_SAFE_INTEGER, base64Bytes + COMMAND_METADATA_BYTES)
}

function commandErrorCode(error: unknown): string {
  if (error instanceof CommandError) return error.code
  if (error !== null && typeof error === 'object' && 'code' in error) {
    const code = (error as { code?: unknown }).code
    if (typeof code === 'string' && code !== '') return code
  }
  return 'command-failed'
}

function asObject(value: unknown): Record<string, unknown> {
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, unknown>
  }
  return { value }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
