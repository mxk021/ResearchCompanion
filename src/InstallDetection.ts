import { execFile } from 'node:child_process'
import { constants } from 'node:fs'
import { access } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

/** Check only the two supported installation locations, without launching the app. */
export async function detectHostApp(): Promise<'installed' | 'not-found' | 'unknown'> {
  if (process.platform !== 'darwin') return 'unknown'
  let inaccessible = false
  for (const base of ['/Applications', join(homedir(), 'Applications')]) {
    const contents = join(base, 'Research Companion.app', 'Contents')
    const plist = join(contents, 'Info.plist')
    try {
      await access(plist, constants.R_OK)
      const { stdout } = await execFileAsync('/usr/libexec/PlistBuddy', [
        '-c', 'Print CFBundleIdentifier', '-c', 'Print CFBundleExecutable', plist,
      ], { timeout: 2_000, maxBuffer: 1_024 })
      const [identifier, executable] = stdout.trim().split('\n')
      if (identifier !== 'com.local.research-companion' || executable !== 'ResearchCompanion') continue
      await access(join(contents, 'MacOS', executable), constants.X_OK)
      return 'installed'
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') inaccessible = true
    }
  }
  return inaccessible ? 'unknown' : 'not-found'
}
