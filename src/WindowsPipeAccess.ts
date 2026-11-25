import { execFileSync } from 'node:child_process'
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto'
import type { Socket } from 'node:net'
import { isAbsolute, join } from 'node:path'

export interface WindowsPipeIdentity {
  scheme: 'windows-pipe-v1'
  userSid: string
  sessionId: number
}

const pipePrefix = '\\\\.\\pipe\\'
const sidPattern = /^S-1-\d+(?:-\d+){1,15}$/
const noncePattern = /^[a-f0-9]{64}$/
const maxAuthenticationBytes = 512

// Windows stock PowerShell is used only to protect a fresh key for the current
// Windows account and read its SID and session. The private key enters via
// standard input; only the DPAPI blob leaves the helper.
const protectSecret = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$plain = [Convert]::FromBase64String([Console]::ReadLine())
try {
    $sealed = [Security.Cryptography.ProtectedData]::Protect($plain, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    @{
        userSid = $identity.User.Value
        sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        protectedCredential = [Convert]::ToBase64String($sealed)
    } | ConvertTo-Json -Compress
} finally {
    [Array]::Clear($plain, 0, $plain.Length)
}
`

export class WindowsPipeAccess {
  readonly identity: WindowsPipeIdentity
  readonly protectedCredential: string
  private readonly secret: Buffer

  private constructor(identity: WindowsPipeIdentity, protectedCredential: string, secret: Buffer) {
    this.identity = identity
    this.protectedCredential = protectedCredential
    this.secret = secret
  }

  static create(): WindowsPipeAccess {
    if (process.platform !== 'win32') throw new Error('Windows pipe protection requires Windows')
    const systemRoot = process.env.SystemRoot
    if (!systemRoot || !isAbsolute(systemRoot)) throw new Error('Windows system path is unavailable')
    const secret = randomBytes(32)
    try {
      const shell = join(systemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
      const result = JSON.parse(execFileSync(shell, [
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-EncodedCommand', Buffer.from(protectSecret, 'utf16le').toString('base64'),
      ], {
        encoding: 'utf8',
        input: secret.toString('base64') + '\n',
        stdio: ['pipe', 'pipe', 'ignore'],
        windowsHide: true,
        timeout: 8_000,
        maxBuffer: 16_384,
      })) as Partial<WindowsPipeIdentity> & { protectedCredential?: string }
      if (typeof result.userSid !== 'string' || !sidPattern.test(result.userSid)
        || typeof result.sessionId !== 'number' || !Number.isSafeInteger(result.sessionId) || result.sessionId < 0
        || typeof result.protectedCredential !== 'string'
        || !/^[a-zA-Z0-9+/]{24,4096}={0,2}$/.test(result.protectedCredential)) {
        throw new Error('Invalid pipe identity')
      }
      return new WindowsPipeAccess({
        scheme: 'windows-pipe-v1',
        userSid: result.userSid,
        sessionId: result.sessionId,
      }, result.protectedCredential, secret)
    } catch {
      secret.fill(0)
      throw new Error('Could not protect the Windows bridge with the current account')
    }
  }

  path(instanceId: string, channel: 's' | 'c'): string {
    const { userSid, sessionId } = this.identity
    return `${pipePrefix}ResearchCompanion-v1-${userSid}-${sessionId}-${instanceId}-${channel}`
  }

  authorize(socket: Socket, path: string, onAuthenticated: () => void): void {
    authenticateWindowsPipe(socket, path.slice(pipePrefix.length), this.secret, onAuthenticated)
  }
}

/** Authenticate before delivering any request or status to the shared bridge. */
export function authenticateWindowsPipe(socket: Socket, pipeName: string, secret: Buffer, onAuthenticated: () => void): void {
  const challenge = randomBytes(32).toString('hex')
  let data = Buffer.alloc(0)
  const timer = setTimeout(reject, 2_000)
  timer.unref()

  function removeAuthentication(): void {
    clearTimeout(timer)
    socket.off('data', receive)
    socket.off('close', removeAuthentication)
    socket.off('error', reject)
  }

  function reject(): void {
    removeAuthentication()
    socket.destroy()
  }

  function proof(side: 'client' | 'server', clientNonce: string): Buffer {
    return createHmac('sha256', secret)
      .update(`Research Companion IPC v1\n${side}\n${pipeName}\n${challenge}\n${clientNonce}`, 'utf8').digest()
  }

  function receive(chunk: Buffer): void {
    if (chunk.length + data.length > maxAuthenticationBytes) return reject()
    data = Buffer.concat([data, chunk])
    const newline = data.indexOf(0x0a)
    if (newline < 0) return
    if (newline !== data.length - 1) return reject()
    let message: { clientNonce?: unknown; proof?: unknown } | null
    try { message = JSON.parse(data.subarray(0, newline).toString('utf8')) } catch { return reject() }
    if (!message || typeof message.clientNonce !== 'string' || !noncePattern.test(message.clientNonce)
      || typeof message.proof !== 'string' || !noncePattern.test(message.proof)) return reject()
    if (!timingSafeEqual(proof('client', message.clientNonce), Buffer.from(message.proof, 'hex'))) return reject()
    removeAuthentication()
    socket.write(`${JSON.stringify({ authenticated: true, proof: proof('server', message.clientNonce).toString('hex') })}\n`)
    onAuthenticated()
  }

  socket.on('close', removeAuthentication)
  socket.on('error', reject)
  socket.on('data', receive)
  socket.write(`${JSON.stringify({ challenge })}\n`)
}

export function isWindowsPipePath(path: string): boolean {
  return path.startsWith(pipePrefix)
}
