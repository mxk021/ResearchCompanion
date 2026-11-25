import assert from 'node:assert/strict'
import {createHmac} from 'node:crypto'
import {EventEmitter} from 'node:events'
import {test} from 'node:test'
import {authenticateWindowsPipe, isWindowsPipePath} from '../src/WindowsPipeAccess.ts'

class TestSocket extends EventEmitter {
  sent = []
  destroyed = false
  write(line) { this.sent.push(JSON.parse(line)) }
  destroy() {
    this.destroyed = true
    this.emit('close')
  }
}

const pipeName = 'ResearchCompanion-v1-S-1-5-21-1-2-3-4-1-123456789012345678901234-c'
const credential = Buffer.from('ab'.repeat(32), 'hex')
const clientNonce = '12'.repeat(32)
const buildProof = (side, name, challenge) => createHmac('sha256', credential)
  .update(`Research Companion IPC v1\n${side}\n${name}\n${challenge}\n${clientNonce}`).digest('hex')

test('Windows named-pipe authentication binds both directions before accepting bridge data', () => {
  assert.ok(isWindowsPipePath('\\\\.\\pipe\\' + pipeName))
  assert.equal(isWindowsPipePath('\\\\elsewhere\\pipe\\' + pipeName), false)
  assert.equal(isWindowsPipePath('/tmp/' + pipeName), false)
  const socket = new TestSocket()
  let accepted = 0
  authenticateWindowsPipe(socket, pipeName, credential, () => accepted++)
  const {challenge} = socket.sent[0]
  const response = JSON.stringify({clientNonce, proof: buildProof('client', pipeName, challenge)}) + '\n'
  assert.match(challenge, /^[0-9a-f]{64}$/)
  assert.equal(accepted, 0)
  socket.emit('data', Buffer.from(response.slice(0, 12)))
  assert.equal(accepted, 0)
  socket.emit('data', Buffer.from(response.slice(12)))
  assert.equal(accepted, 1)
  assert.equal(socket.destroyed, false)
  assert.deepEqual(socket.sent[1], {authenticated: true, proof: buildProof('server', pipeName, challenge)})
})

test('wrong credential, wrong channel, prior challenge and a pipelined command never enter the bridge', () => {
  const replaySource = new TestSocket()
  authenticateWindowsPipe(replaySource, pipeName, credential, () => assert.fail('unexpected replay source auth'))
  const previous = replaySource.sent[0].challenge
  replaySource.destroy()
  for (const mode of ['wrong-proof', 'wrong-channel', 'replay', 'pipelined']) {
    const socket = new TestSocket()
    authenticateWindowsPipe(socket, pipeName, credential, () => assert.fail(`unauthorized: ${mode}`))
    const {challenge} = socket.sent[0]
    const proof = mode === 'wrong-proof' ? 'ff'.repeat(32) : buildProof('client',
      mode === 'wrong-channel' ? pipeName.replace(/-c$/, '-s') : pipeName, mode === 'replay' ? previous : challenge)
    const line = JSON.stringify({clientNonce, proof}) + '\n'
    socket.emit('data', Buffer.from(mode === 'pipelined' ? line + '{"action":"workspaces"}\n' : line))
    assert.equal(socket.destroyed, true)
    assert.equal(socket.sent.length, 1)
  }
})
