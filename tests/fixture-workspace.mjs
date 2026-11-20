import { mkdtemp, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

/** Async workspace registration is part of the real rc.3 plugin contract. */
export async function fixtureWorkspace(t) {
  const path = await mkdtemp(join(tmpdir(), 'companion-route-test-'))
  const previous = process.env.DSH_RESEARCH_WORKSPACE
  process.env.DSH_RESEARCH_WORKSPACE = path
  const workspace = { id: 'route-test-workspace', title: '科研助手', path, sessionIds: [], status: async () => 'ok' }
  let created
  const ready = new Promise(resolve => { created = resolve })
  t.after(async () => {
    await ready
    if (previous === undefined) delete process.env.DSH_RESEARCH_WORKSPACE
    else process.env.DSH_RESEARCH_WORKSPACE = previous
    await rm(path, { recursive: true, force: true })
  })
  return {
    create: async (actualPath, title) => {
      if (actualPath !== path || title !== '科研助手') throw new Error('Unexpected test workspace creation')
      created()
      return workspace
    },
    list: () => [workspace],
    get: id => id === workspace.id ? workspace : undefined,
  }
}
