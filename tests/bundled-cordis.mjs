/** Use the installed host's exact framework for isolated tests; never install a peer. */
import { closeSync, openSync, readSync } from 'node:fs'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

export async function loadCordis() {
  try { return { ...(await import('@deepseek-ai/cordis')), cleanup: async () => {} } }
  catch (error) { if (error.code !== 'ERR_MODULE_NOT_FOUND') throw error }
  const archive = process.env.DSH_TEST_APP_ASAR ?? '/Applications/DeepSeek Harness.app/Contents/Resources/app.asar'
  const fd = openSync(archive, 'r')
  const root = await mkdtemp(join(tmpdir(), 'companion-cordis-test-'))
  try {
    const header = Buffer.alloc(16)
    readSync(fd, header, 0, 16, 0)
    const bytes = Buffer.alloc(header.readUInt32LE(12))
    readSync(fd, bytes, 0, bytes.length, 16)
    const tree = JSON.parse(bytes.toString('utf8'))
    const base = 8 + header.readUInt32LE(4)
    for (const name of ['cordis', 'cosmokit']) for (const file of ['package.json', 'lib/index.js']) {
      let entry = tree
      for (const part of `dsh/node_modules/@deepseek-ai/${name}/${file}`.split('/')) entry = entry.files[part]
      if (!entry || !Number.isSafeInteger(entry.size) || entry.size > 2_000_000 || !/^\d+$/.test(entry.offset)) throw new Error('Unexpected bundled test framework file')
      const data = Buffer.alloc(entry.size)
      readSync(fd, data, 0, data.length, base + Number(entry.offset))
      const target = join(root, 'node_modules', '@deepseek-ai', name, file)
      await mkdir(join(target, '..'), { recursive: true })
      await writeFile(target, data)
    }
    const framework = await import(pathToFileURL(join(root, 'node_modules/@deepseek-ai/cordis/lib/index.js')).href)
    return { ...framework, cleanup: () => rm(root, { recursive: true, force: true }) }
  } catch (error) { await rm(root, { recursive: true, force: true }); throw error }
  finally { closeSync(fd) }
}
