import { pathToFileURL } from 'node:url'
import { writeFileSync, readFileSync } from 'node:fs'
const { build } = await import(process.env.ESBUILD_MODULE ? pathToFileURL(process.env.ESBUILD_MODULE).href : 'esbuild')
await build({entryPoints:['src/index.ts'],outfile:'lib/index.js',bundle:true,format:'esm',platform:'node',target:'node24',external:['@deepseek-ai/*'],logLevel:'info'})
await build({entryPoints:['src/ResearchContext.ts'],outfile:'lib/ResearchContext.js',bundle:true,format:'esm',platform:'node',target:'node24'})
await build({entryPoints:['src/ResearchSessionIndex.ts'],outfile:'lib/ResearchSessionIndex.js',bundle:true,format:'esm',platform:'node',target:'node24'})
await build({entryPoints:['src/CommandBridge.ts'],outfile:'lib/CommandBridge.js',bundle:true,format:'esm',platform:'node',target:'node24',external:['@deepseek-ai/*']})
const body=readFileSync('src/client.js','utf8')
writeFileSync('lib/client.js',`window.__ModuleLoader__.load({id:"dsh-research-companion",factory:(require)=>{var module={exports:{}};var exports=module.exports;\n${body}\nreturn module.exports;}});\n`)
