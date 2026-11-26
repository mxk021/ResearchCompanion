import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { promisify } from 'node:util'

const execute = promisify(execFile)
const noncePattern = /^[a-f0-9]{64}$/
const unprotectScript = Buffer.from([
  "$ErrorActionPreference = 'Stop'",
  "$ProgressPreference = 'SilentlyContinue'",
  'Add-Type -AssemblyName System.Security',
  '$sealed = [Convert]::FromBase64String([Console]::ReadLine())',
  '$plain = [Security.Cryptography.ProtectedData]::Unprotect($sealed, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)',
  'try { [Console]::Write([Convert]::ToBase64String($plain)) } finally { [Array]::Clear($plain, 0, $plain.Length) }',
].join('\n'), 'utf16le').toString('base64')

/** Connect isolated fixtures to the production Windows transport without changing the macOS probe. */
export async function authenticateTestPipe(socket, manifest) {
  if (process.platform !== 'win32') return
  const prefix = '\\\\.\\pipe\\'
  assert.equal(manifest.transport.scheme, 'windows-pipe-v1')
  assert.ok(manifest.commandSocketPath.startsWith(prefix))
  assert.match(manifest.protectedCredential, /^[A-Za-z0-9+/]+={0,2}$/)
  const shell = join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
  const lines = createInterface({ input: socket, crlfDelay: Infinity })
  const iterator = lines[Symbol.asyncIterator]()
  const timeout = setTimeout(() => socket.destroy(new Error('Fixture pipe handshake timed out')), 5000)
  let secret
  try {
    const hello = JSON.parse((await iterator.next()).value)
    assert.match(hello.challenge, noncePattern)
    const child = execute(shell, ['-NoProfile', '-NonInteractive', '-EncodedCommand', unprotectScript], {
      windowsHide: true, timeout: 4000,
    })
    child.child.stdin.end(manifest.protectedCredential + '\n')
    secret = Buffer.from((await child).stdout, 'base64')
    assert.equal(secret.length, 32)
    const clientNonce = randomBytes(32).toString('hex')
    const pipeName = manifest.commandSocketPath.slice(prefix.length)
    const proof = side => createHmac('sha256', secret)
      .update(['Research Companion IPC v1', side, pipeName, hello.challenge, clientNonce].join('\n')).digest()
    socket.write(JSON.stringify({ clientNonce, proof: proof('client').toString('hex') }) + '\n')
    const auth = JSON.parse((await iterator.next()).value)
    assert.equal(auth.authenticated, true)
    assert.match(auth.proof, noncePattern)
    assert.ok(timingSafeEqual(Buffer.from(auth.proof, 'hex'), proof('server')))
  } finally {
    secret?.fill(0)
    clearTimeout(timeout)
    lines.close()
    socket.resume()
  }
}
