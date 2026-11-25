import { createHash, randomUUID } from 'node:crypto'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  lstatSync,
  readFileSync,
  realpathSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { WindowsPipeAccess, type WindowsPipeIdentity } from './WindowsPipeAccess.js'

export type HarnessInstanceKind = 'desktop' | 'web' | 'unknown'

/** The on-disk discovery contract consumed by DSH Pet.app. */
export interface HarnessInstanceDescriptor {
  protocolVersion: 1
  instanceId: string
  kind: HarnessInstanceKind
  profile?: string
  /** Stable hash of a known Harness profile/home target; never the raw path. */
  targetId?: string
  pid: number
  startedAt: number
  webURL?: string
  statusSocketPath: string
  commandSocketPath: string
  transport?: WindowsPipeIdentity
}

export const INSTANCE_PROTOCOL_VERSION = 1 as const

const MAX_UNIX_SOCKET_PATH_BYTES = 103
const windowsInstanceKeys = new WeakMap<HarnessInstanceDescriptor, WindowsPipeAccess>()

export function windowsPipeAccess(instance: HarnessInstanceDescriptor | undefined): WindowsPipeAccess | undefined {
  return instance && windowsInstanceKeys.get(instance)
}

interface HarnessContextHints {
  name?: unknown
  profile?: unknown
  kind?: unknown
  type?: unknown
  profileContext?: { name?: unknown; dir?: unknown; home?: unknown }
  resolvedProfile?: { profile?: unknown }
  dir?: unknown
  profileDir?: unknown
  home?: unknown
  webServer?: {
    getOrigin?: () => string
    protocol?: unknown
    host?: unknown
    hostname?: unknown
    port?: unknown
  }
  get?: (name: string, strict?: boolean) => unknown
}

/**
 * Build a per-plugin identity. The plugin gets no reliable process-name based
 * signal, so kind stays unknown unless the host supplies an explicit profile or
 * kind. This avoids presenting a guessed Desktop/Web label in the settings UI.
 */
export function createHarnessInstanceDescriptor(context?: unknown): HarnessInstanceDescriptor {
  const hints = context as HarnessContextHints | undefined
  const profileContext = readHint(hints, 'profileContext')
  const resolvedProfile = readHint(hints, 'resolvedProfile')
  const profileValue = firstNonEmptyString(
    process.env.DSH_PET_PROFILE,
    process.env.DSH_PROFILE,
    profileContext?.name,
    readHint(hints, 'profile'),
    resolvedProfile?.profile,
    profileFromArgv(),
  )
  const profile = profileValue ?? profileName(resolvedProfile?.profile)
  const explicitKind = normalizeKind(firstNonEmptyString(
    process.env.DSH_PET_HARNESS_KIND,
    process.env.DSH_PET_HARNESS_TYPE,
    readHint(hints, 'kind'),
    readHint(hints, 'type'),
    readServiceString(hints, 'harnessKind'),
  ))
  const kind: HarnessInstanceKind = explicitKind
    ?? (profile === 'desktop' ? 'desktop' : profile === 'web' ? 'web' : 'unknown')
  const windows = process.platform === 'win32' ? WindowsPipeAccess.create() : undefined
  const instanceId = randomUUID().replaceAll('-', '').slice(0, windows ? 24 : 12)
  const [statusSocketPath, commandSocketPath] = windows
    ? [windows.path(instanceId, 's'), windows.path(instanceId, 'c')]
    : unixInstancePaths(instanceId)

  const webURL = safeLoopbackURL(
    process.env.DSH_PET_WEB_URL
      ?? process.env.DSH_WEB_URL
      ?? contextOrigin(hints)
      ?? contextWebURL(hints),
  )
  const targetId = targetIdentity(profile, hints)
  const instance: HarnessInstanceDescriptor = {
    protocolVersion: INSTANCE_PROTOCOL_VERSION,
    instanceId,
    kind,
    ...(profile === undefined ? {} : { profile }),
    ...(targetId === undefined ? {} : { targetId }),
    pid: process.pid,
    startedAt: Math.floor(Date.now() / 1000),
    ...(webURL === undefined ? {} : { webURL }),
    statusSocketPath,
    commandSocketPath,
    ...(windows === undefined ? {} : { transport: windows.identity }),
  }
  if (windows) windowsInstanceKeys.set(instance, windows)
  return instance
}

function unixInstancePaths(instanceId: string): [string, string] {
  const uid = typeof process.getuid === 'function' ? process.getuid() : process.pid
  const socketDir = join('/tmp', `dsh-pet-${uid}`)
  mkdirSync(socketDir, { recursive: true, mode: 0o700 })
  const directoryInfo = lstatSync(socketDir)
  if (!directoryInfo.isDirectory() || directoryInfo.isSymbolicLink() || directoryInfo.uid !== uid) {
    throw new Error('Refusing an unsafe research companion socket directory')
  }
  chmodSync(socketDir, 0o700)
  const statusSocketPath = join(socketDir, `${instanceId}-s.sock`)
  const commandSocketPath = join(socketDir, `${instanceId}-c.sock`)
  assertSocketPath(statusSocketPath)
  assertSocketPath(commandSocketPath)
  return [statusSocketPath, commandSocketPath]
}

/** Refresh the origin after WebServer has finished listening. */
export function refreshHarnessInstanceWebURL(descriptor: HarnessInstanceDescriptor, context?: unknown): boolean {
  const hints = context as HarnessContextHints | undefined
  const webURL = safeLoopbackURL(contextOrigin(hints) ?? contextWebURL(hints))
  if (webURL === undefined) return false
  descriptor.webURL = webURL
  return true
}

/** The default discovery directory shared by Desktop and Web Harness hosts. */
export function instanceDiscoveryDirectory(home = homedir()): string {
  if (process.platform === 'win32') return join(process.env.LOCALAPPDATA || join(home, 'AppData', 'Local'), 'Research Companion', 'instances')
  return join(home, 'Library', 'Application Support', 'Research Companion', 'instances')
}

export function instanceManifestPath(instanceId: string, home = homedir()): string {
  return join(instanceDiscoveryDirectory(home), `${instanceId}.json`)
}

/** Publishes and removes only the manifest belonging to one generated identity. */
export class HarnessInstanceManifest {
  private published = false

  constructor(
    private readonly descriptor: HarnessInstanceDescriptor,
    private readonly directory = instanceDiscoveryDirectory(),
  ) {}

  get path(): string {
    return join(this.directory, `${this.descriptor.instanceId}.json`)
  }

  publish(): void {
    mkdirSync(this.directory, { recursive: true, mode: 0o700 })
    const info = lstatSync(this.directory)
    if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('Unsafe instance discovery directory')
    const windows = windowsPipeAccess(this.descriptor)
    if (process.platform === 'win32') {
      if (!windows || realpathSync.native(this.directory).toLowerCase() !== resolve(this.directory).toLowerCase()) {
        throw new Error('Unsafe Windows instance discovery directory')
      }
    } else if (info.uid !== process.getuid?.()) throw new Error('Unsafe instance discovery directory')
    const temporary = `${this.path}.${process.pid}.${randomUUID()}.tmp`
    const manifest = windows ? { ...this.descriptor, protectedCredential: windows.protectedCredential } : this.descriptor
    try {
      writeFileSync(temporary, `${JSON.stringify(manifest)}\n`, { flag: 'wx', mode: 0o600 })
      if (!windows) chmodSync(temporary, 0o600)
      renameSync(temporary, this.path)
      if (!windows) chmodSync(this.path, 0o600)
    } finally {
      if (existsSync(temporary)) unlinkSync(temporary)
    }
    this.published = true
  }

  remove(): void {
    if (!this.published || !existsSync(this.path)) return
    try {
      if (lstatSync(this.path).isSymbolicLink()) return
      const current = JSON.parse(readFileSync(this.path, 'utf8')) as { instanceId?: unknown }
      if (current.instanceId !== this.descriptor.instanceId) return
      unlinkSync(this.path)
      this.published = false
    } catch {
      // A concurrently removed or replaced manifest is not ours to delete.
    }
  }
}

function firstNonEmptyString(...values: readonly unknown[]): string | undefined {
  return values.find(value => typeof value === 'string' && value.trim() !== '') as string | undefined
}

function normalizeKind(value: string | undefined): HarnessInstanceKind | undefined {
  if (value === 'desktop' || value === 'web' || value === 'unknown') return value
  return undefined
}

function readHint<K extends keyof HarnessContextHints>(context: HarnessContextHints | undefined, name: K): HarnessContextHints[K] | undefined {
  try {
    // Cordis throws on undeclared property reads, even with optional chaining.
    return (context?.get?.(name, false) ?? context?.[name]) as HarnessContextHints[K] | undefined
  } catch {
    return undefined
  }
}

function readServiceString(context: HarnessContextHints | undefined, name: string): string | undefined {
  try {
    return context?.get?.(name, false) as string | undefined
  } catch {
    return undefined
  }
}

function profileFromArgv(): string | undefined {
  const args = process.argv.slice(1)
  const flag = args.indexOf('--profile')
  const value = flag >= 0 ? args[flag + 1] : undefined
  return value !== undefined && value !== '' && !value.startsWith('-') ? value : undefined
}

function contextOrigin(context: HarnessContextHints | undefined): string | undefined {
  try {
    return readHint(context, 'webServer')?.getOrigin?.()
  } catch {
    return undefined
  }
}

function contextWebURL(context: HarnessContextHints | undefined): string | undefined {
  const server = readHint(context, 'webServer')
  if (server === undefined) return undefined
  const protocol = typeof server.protocol === 'string' ? server.protocol : undefined
  const host = firstNonEmptyString(server.host, server.hostname)
  const port = typeof server.port === 'number' && Number.isInteger(server.port) ? server.port : undefined
  if (protocol === undefined || host === undefined || port === undefined) return undefined
  return `${protocol}//${host}:${port}`
}

function profileName(value: unknown): string | undefined {
  if (value === null || typeof value !== 'object') return undefined
  const name = (value as { name?: unknown }).name
  return typeof name === 'string' && name.trim() !== '' ? name : undefined
}

function targetIdentity(profile: string | undefined, context: HarnessContextHints | undefined): string | undefined {
  const explicit = firstNonEmptyString(
    process.env.DSH_PET_TARGET_ID,
    readServiceString(context, 'targetId'),
  )
  if (explicit !== undefined) return explicit
  const profileContext = readHint(context, 'profileContext')
  const profileObject = readHint(context, 'resolvedProfile')?.profile
  const profileDir = firstNonEmptyString(
    profileContext?.dir,
    readHint(context, 'profileDir'),
    profileObject !== null && typeof profileObject === 'object'
      ? (profileObject as { dir?: unknown }).dir
      : undefined,
  )
  const home = firstNonEmptyString(process.env.DSH_HOME, profileContext?.home, readHint(context, 'home'))
  const source = profileDir ?? (home !== undefined && profile !== undefined ? `${home}\u0000${profile}` : undefined)
  if (source === undefined) return undefined
  return `target-${createHash('sha256').update(source).digest('hex').slice(0, 16)}`
}

function safeLoopbackURL(value: string | undefined): string | undefined {
  if (value === undefined) return undefined
  try {
    const url = new URL(value)
    if (!['http:', 'https:'].includes(url.protocol)) return undefined
    if (!['127.0.0.1', 'localhost', '[::1]', '::1'].includes(url.hostname)) return undefined
    if (url.username !== '' || url.password !== '' || url.search !== '' || url.hash !== '') return undefined
    if (url.pathname !== '' && url.pathname !== '/') return undefined
    return url.origin
  } catch {
    return undefined
  }
}

function assertSocketPath(path: string): void {
  if (Buffer.byteLength(path) > MAX_UNIX_SOCKET_PATH_BYTES) {
    throw new Error(`DSH Pet instance socket path exceeds Unix limit: ${path}`)
  }
}
