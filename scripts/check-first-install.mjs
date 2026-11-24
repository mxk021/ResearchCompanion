// Exercise the stock signed Desktop Host and the release TGZ, with a fresh HOME and no account.
// Run using the Desktop Electron binary in ELECTRON_RUN_AS_NODE mode; see docs/BUILD.md.
import assert from 'node:assert/strict'
import { execFile, fork } from 'node:child_process'
import { once } from 'node:events'
import { createRequire } from 'node:module'
import { createConnection } from 'node:net'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { promisify } from 'node:util'
import { setTimeout as delay } from 'node:timers/promises'
import { copyFile, mkdir, mkdtemp, readFile, readdir, realpath, rm, stat } from 'node:fs/promises'
import { createHash, randomUUID } from 'node:crypto'

assert.ok(process.versions.electron, 'Run with the DSH Desktop Electron runtime in Node mode.')
assert.ok(process.argv[2], 'Supply a bridge .tgz, optionally followed by the packaged Research Companion executable.')
const tgz = resolve(process.argv[2])
const nativeApp = process.argv[3] && resolve(process.argv[3])
const setupCheck = process.env.RC_TEST_SETUP_CHECK
assert.ok(!setupCheck || nativeApp, 'The optional setup check also needs the packaged native app.')
const resources = resolve(dirname(process.execPath), '../Resources')
const packages = join(resources, 'app.asar/dsh')
const installation = join(packages, 'node_modules/@deepseek-ai')
const require = createRequire(import.meta.url)
const execute = promisify(execFile)
const testDir = await realpath(await mkdtemp(join(tmpdir(), 'rc-install-')))
const home = join(testDir, 'home')
const dsh = join(home, '.dsh')
const profile = join(dsh, 'profiles/desktop')
const instanceDir = join(home, 'Library/Application Support/Research Companion/instances')
const workspace = join(home, 'Library/Application Support/Research Companion/Workspace')
const env = { HOME: home, CFFIXED_USER_HOME: home, TMPDIR: testDir, DSH_HOME: dsh,
  XDG_CONFIG_HOME: join(home, '.config'), XDG_CACHE_HOME: join(home, '.cache'), XDG_DATA_HOME: join(home, '.local/share'),
  PATH: '/usr/bin:/bin:/usr/sbin:/sbin', ELECTRON_RUN_AS_NODE: '1' }
const cli = join(resources, 'runtime/cli/bin/dsh')
let host
async function assertSetup(expected) {
  if (setupCheck) await execute(resolve(setupCheck), [home, resolve(dirname(nativeApp), '../..'), basename(tgz), expected], {env})
}
async function start(workspaceOverride) {
  const child = fork(join(installation, 'dsh-desktop-host/lib/index.js'),
    [packages, profile, join(resources, 'runtime/primary-runtime')],
    { execArgv: ['--expose-internals'], cwd: profile,
      env: workspaceOverride ? { ...env, DSH_RESEARCH_WORKSPACE: workspaceOverride } : env, stdio: ['ignore', 'ignore', 'ignore', 'ipc'] })
  host = child
  for (let i = 0; i < 160; i++) {
    if (child.exitCode !== null || child.signalCode) throw new Error('Stock desktop Host exited before the bridge was ready.')
    for (const file of await readdir(instanceDir).catch(() => [])) {
      if (file.endsWith('.json')) {
        const path = join(instanceDir, file)
        const manifest = JSON.parse(await readFile(path, 'utf8'))
        if (manifest.pid === child.pid) return { manifest, path }
      }
    }
    await delay(125)
  }
  throw new Error('Stock desktop Host did not publish its instance descriptor within 20 seconds.')
}
async function request(manifest, action, fields = {}) {
  const id = randomUUID()
  const socket = createConnection(manifest.commandSocketPath)
  socket.setTimeout(15000, () => socket.destroy(new Error('Bridge call timed out: ' + action)))
  try {
    const reader = createInterface({ input: socket })
    const [line] = await Promise.race([
      (async () => {
        const pending = once(reader, 'line')
        socket.write(JSON.stringify({ id, action, ...fields }) + '\n')
        return pending
      })(),
      once(socket, 'error').then(([error]) => Promise.reject(error)),
    ])
    const reply = JSON.parse(line)
    assert.equal(reply.id, id)
    assert.equal(reply.ok, true, action)
    return reply
  } finally { socket.destroy() }
}
async function stop() {
  if (!host || host.exitCode !== null || host.signalCode) return
  const current = host
  const exited = once(current, 'exit')
  const timeout = setTimeout(() => current.kill('SIGTERM'), 8000)
  try {
    current.send({ type: 'shutdown' })
    const [code] = await exited
    assert.equal(code, 0, 'The stock Host did not shut down normally')
  } finally { clearTimeout(timeout); host = undefined }
}
try {
  await mkdir(home, { recursive: true, mode: 0o700 })
  await assertSetup('uninitialized')
  await assert.rejects(execute(cli, ['plugin', '--profile', 'desktop', 'add', '--offline', '--ignore-scripts', 'file:' + tgz], { env }),
    error => /initialize its profile/.test(error.stderr))
  // Use the installation's actual profile initializer and default Desktop bundle list.
  require(join(installation, 'dsh-app-boot/lib/index.js')).initProfile(profile,
    require(join(installation, 'dsh-official-bundles/lib/index.js')).PROFILE_TEMPLATES.web.bundles)
  await assertSetup('absent')
  const store = join(dsh, 'local-plugins/ResearchCompanion')
  await mkdir(store, { recursive: true, mode: 0o700 })
  async function installPackage(source) {
    const digest = createHash('sha256').update(await readFile(source)).digest('hex')
    const directory = join(store,digest)
    await mkdir(directory,{recursive:true,mode:0o700})
    const localPackage = join(directory,basename(source))
    await copyFile(source,localPackage)
    await execute(cli, ['plugin','--profile','desktop','add','--offline','--ignore-scripts','file:' + localPackage], {env})
  }
  const previous = process.env.RC_TEST_UPGRADE_FROM
  await installPackage(previous ?? tgz)
  await assertSetup(previous ? 'upgradeable' : 'selected')
  const metadata = JSON.parse(await readFile(join(profile, 'package.json')))
  assert.ok(metadata.dsh.profile.bundles.includes('dsh-research-companion'))
  assert.deepEqual(Object.keys(metadata.dependencies), ['dsh-research-companion'])
  const { manifest, path } = await start()
  const [capabilities, state] = await Promise.all([request(manifest, 'capabilities'), request(manifest, 'workspaces')])
  assert.ok(capabilities.supports.includes('researchHistory'))
  if (!previous) assert.ok(capabilities.supports.includes('researchDocumentPlan'))
  assert.ok(!capabilities.supports.some(feature => feature.startsWith('research.retirement.') || feature === 'researchSafeDelete'))
  assert.equal(state.workspaces.length, 1)
  assert.equal(state.workspaces[0].path, workspace)
  assert.equal(state.workspaces[0].sessionIds.length, 0)
  assert.ok((await stat(workspace)).isDirectory())
  if (nativeApp) {
    const result = await execute(nativeApp, ['--check-bridge', path], { env, timeout: 16000 })
    assert.equal(JSON.parse(result.stdout).ok, true)
  }
  const { catalog } = await request(manifest, 'modelCatalog')
  assert.deepEqual(catalog.groups.map(group => group.id).sort(), ['chatgpt', 'deepseek-account'])
  const subscription = catalog.groups.find(group => group.id === 'chatgpt')
  assert.deepEqual(subscription.models, [])
  assert.ok(subscription.error)
  const sessionId = randomUUID(), workspaceId = state.workspaces[0].id
  assert.equal((await request(manifest, 'createSession', { workspaceId, sessionId, title: 'Synthetic optics' })).sessionId, sessionId)
  await stop()
  if (previous) await installPackage(tgz)
  await assertSetup('selected')
  const reopened = await start()
  assert.ok((await request(reopened.manifest,'capabilities')).supports.includes('researchDocumentPlan'))
  const persisted = (await request(reopened.manifest, 'workspaces')).workspaces
  assert.equal(persisted[0].id, workspaceId)
  assert.deepEqual(persisted[0].sessionIds, [sessionId])
  if (nativeApp) {
    const result = await execute(nativeApp, ['--check-bridge', reopened.path], { env, timeout: 16000 })
    assert.equal(JSON.parse(result.stdout).ok, true)
  }
  await stop()
  const legacy = join(home, 'Documents/Codex/ResearchCompanionWorkspace')
  const older = await start(legacy)
  const previousWorkspace = (await request(older.manifest, 'workspaces')).workspaces[0]
  assert.equal(previousWorkspace.path, legacy)
  await stop()
  const upgraded = await start()
  const preserved = (await request(upgraded.manifest, 'workspaces')).workspaces[0]
  assert.equal(preserved.id, previousWorkspace.id)
  assert.equal(preserved.path, legacy)
  await stop()
  if (previous) console.log('The stock offline CLI upgraded the previous public bridge in place and kept the original synthetic session.')
  console.log('The unconfigured ChatGPT provider offered no model. A pre-existing synthetic legacy workspace retained its registered identity after an upgrade.')
  console.log('Fresh HOME: stock CLI installed the release bridge offline; stock Host created one workspace, persisted a named synthetic session across restart, and withheld unsupported deletion.')
  if (nativeApp) console.log('The packaged native command client connected over the owner-local socket.')
  if (setupCheck) console.log('The native setup view can find the packaged archive and recognized the isolated profile states.')
} finally {
  try { await stop() } finally { await rm(testDir, { recursive: true, force: true }) }
}
