import { randomUUID } from 'node:crypto'
import { connect, createServer, type Server, type Socket } from 'node:net'
import { chmodSync, existsSync, lstatSync, mkdirSync, renameSync, unlinkSync, type Stats } from 'node:fs'
import { dirname } from 'node:path'
import { isWindowsPipePath, type WindowsPipeAccess } from './WindowsPipeAccess.js'

interface SocketIdentity {
  dev: number
  ino: number
}

export interface UnixSocketServerOptions {
  socketPath: string
  /** Used in diagnostics: "command bridge" or "local bridge". */
  label: string
  onConnection: (socket: Socket) => void
  onStop: () => void
  windowsAccess?: WindowsPipeAccess
}

/**
 * Owns one user-local endpoint. Unix sockets retain stale-owner and replacement
 * protection; Windows pipes authenticate each connection before protocol data.
 * The command and status protocols stay in their respective bridge classes.
 */
export class UnixSocketServer {
  private readonly socketPath: string
  private readonly label: string
  private readonly onConnection: (socket: Socket) => void
  private readonly onStop: () => void
  private readonly windowsAccess: WindowsPipeAccess | undefined
  private handshakes = new Set<Socket>()
  private server: Server | undefined
  private ownsSocket = false
  private probeGeneration = 0
  private probing = false
  private socketIdentity: SocketIdentity | undefined

  constructor(options: UnixSocketServerOptions) {
    this.socketPath = options.socketPath
    this.label = options.label
    this.onConnection = options.onConnection
    this.onStop = options.onStop
    this.windowsAccess = options.windowsAccess
  }

  start(onReady?: () => void): void {
    if (this.server || this.probing) return
    if (process.platform === 'win32') {
      this.listenWindows(onReady)
      return
    }
    mkdirSync(dirname(this.socketPath), { recursive: true })

    if (existsSync(this.socketPath)) {
      const stat = lstatSync(this.socketPath)
      if (!stat.isSocket()) {
        console.warn(`[dsh-pet] ${this.label} path is not a socket: ${this.socketPath}`)
        return
      }
      const staleIdentity = socketIdentity(this.socketPath)
      // Probe before reclaiming an existing path. ECONNREFUSED means the Unix
      // socket is stale; a successful connection means another owner is live.
      const generation = ++this.probeGeneration
      this.probing = true
      const probe = connect(this.socketPath)
      probe.once('connect', () => {
        probe.destroy()
        this.probing = false
        console.warn(`[dsh-pet] ${this.label} path is already active: ${this.socketPath}`)
      })
      probe.once('error', error => {
        probe.destroy()
        this.probing = false
        if (generation !== this.probeGeneration) return
        const code = 'code' in error ? (error as Error & { code?: string }).code : undefined
        if (code !== 'ECONNREFUSED' && code !== 'ENOENT') {
          console.warn(`[dsh-pet] ${this.label} unavailable: ${error.message}`)
          return
        }
        if (!sameSocketIdentity(staleIdentity, socketIdentity(this.socketPath))) return
        try { unlinkSync(this.socketPath) } catch { /* another owner may have won the race */ }
        this.listen(onReady)
      })
      return
    }

    this.listen(onReady)
  }

  stop(): void {
    this.probeGeneration += 1
    this.probing = false
    this.onStop()
    for (const socket of this.handshakes) socket.destroy()
    this.handshakes.clear()
    const server = this.server
    this.server = undefined
    if (!server) return
    if (process.platform === 'win32') {
      server.close()
      return
    }
    const replacement = preserveReplacement(this.socketPath, this.socketIdentity)
    server.close()
    if (replacement !== undefined) {
      try { renameSync(replacement, this.socketPath) } catch { /* replacement was removed independently */ }
    } else if (this.ownsSocket) {
      unlinkIfSame(this.socketPath, this.socketIdentity)
    }
    this.ownsSocket = false
    this.socketIdentity = undefined
  }

  private listenWindows(onReady?: () => void): void {
    const access = this.windowsAccess
    if (!access || !isWindowsPipePath(this.socketPath)) {
      throw new Error('Refusing an unauthenticated Windows bridge pipe')
    }
    const generation = this.probeGeneration
    const server = createServer(socket => {
      this.handshakes.add(socket)
      socket.once('close', () => this.handshakes.delete(socket))
      access.authorize(socket, this.socketPath, () => {
        this.handshakes.delete(socket)
        if (generation === this.probeGeneration) this.onConnection(socket)
        else socket.destroy()
      })
    })
    server.maxConnections = 32
    server.on('error', error => {
      console.warn(`[dsh-pet] ${this.label} unavailable: ${error.message}`)
    })
    server.listen(this.socketPath, () => {
      if (generation === this.probeGeneration) onReady?.()
      else server.close()
    })
    this.server = server
  }

  private listen(onReady?: () => void): void {
    const generation = this.probeGeneration
    const server = createServer(this.onConnection)
    // Create the socket without the process umask's group/other permissions.
    // The chmod below is still kept as a belt-and-braces check.
    let restoredUmask = false
    const previousUmask = process.umask(0o077)
    const restoreUmask = (): void => {
      if (restoredUmask) return
      restoredUmask = true
      process.umask(previousUmask)
    }
    server.on('error', error => {
      restoreUmask()
      console.warn(`[dsh-pet] ${this.label} unavailable: ${error.message}`)
    })
    try {
      server.listen(this.socketPath, () => {
        restoreUmask()
        const identity = socketIdentity(this.socketPath)
        if (generation !== this.probeGeneration) {
          server.close()
          unlinkIfSame(this.socketPath, identity)
          return
        }
        this.ownsSocket = true
        this.socketIdentity = identity
        try { chmodSync(this.socketPath, 0o600) } catch { /* best effort */ }
        onReady?.()
      })
    } catch (error) {
      restoreUmask()
      throw error
    }
    this.server = server
  }
}

function socketIdentity(path: string): SocketIdentity | undefined {
  try {
    const stat: Stats = lstatSync(path)
    return stat.isSocket() ? { dev: stat.dev, ino: stat.ino } : undefined
  } catch {
    return undefined
  }
}

function sameSocketIdentity(left: SocketIdentity | undefined, right: SocketIdentity | undefined): boolean {
  return left !== undefined && right !== undefined && left.dev === right.dev && left.ino === right.ino
}

function unlinkIfSame(path: string, identity: SocketIdentity | undefined): void {
  if (!sameSocketIdentity(identity, socketIdentity(path))) return
  try { unlinkSync(path) } catch { /* already removed */ }
}

function preserveReplacement(path: string, owner: SocketIdentity | undefined): string | undefined {
  if (owner === undefined) return undefined
  const current = socketIdentity(path)
  if (sameSocketIdentity(owner, current) || current === undefined) return undefined
  const backup = `${path}.dsh-pet-preserve-${randomUUID()}`
  try {
    renameSync(path, backup)
    return backup
  } catch {
    return undefined
  }
}
