/** Account-only model selection for the research workspace. DSH owns routing and storage. */
export interface ResearchSelection {
  provider: string
  model: string
  reasoningEffort?: string
}

interface Reasoning {
  efforts: readonly { id: string; name: string; description?: string }[]
  defaultEffort?: string
}

export interface ResearchModelRuntime {
  listProviders(): readonly { id: string; name: string }[]
  listConfigurableProviders(): readonly { provider: string; settingsNs: string }[]
  listModels(provider: string): Promise<readonly { id: string; name: string }[]>
  resolveModelInfo(provider: string, model: string): Promise<{ reasoning?: Reasoning }>
  resolveCallConfig(selection: ResearchSelection, signal: AbortSignal): Promise<ResearchSelection>
}

const subscriptionRoutes = new Set(['chatgpt', 'chatgpt-sub'])

function registeredSubscriptions(llm?: ResearchModelRuntime): string[] {
  return [...new Set(llm?.listConfigurableProviders().filter(entry =>
    entry.settingsNs === 'chatgpt' && subscriptionRoutes.has(entry.provider),
  ).map(entry => entry.provider) ?? [])]
}

export type ResearchProviderState = {
  id: string
  name: string
  models: readonly { id: string; name: string; reasoning?: Reasoning }[]
  error?: string
}

export function accountProviderAllowed(provider: unknown, llm?: ResearchModelRuntime): boolean {
  if (provider === 'deepseek-account') return true
  // Both the installed route and the owner namespace from the existing
  // subscription plugin must match; a generic API-key route is never accepted.
  return typeof provider === 'string' && subscriptionRoutes.has(provider) && registeredSubscriptions(llm).includes(provider)
}

export function decodeResearchSelection(value: unknown): ResearchSelection | undefined {
  if (!value || typeof value !== 'object') return
  const row = value as Record<string, unknown>
  if (typeof row.provider !== 'string' || !row.provider || typeof row.model !== 'string' || !row.model) return
  if (row.reasoningEffort !== undefined && (typeof row.reasoningEffort !== 'string' || !row.reasoningEffort)) return
  return { provider: row.provider, model: row.model,
    ...(typeof row.reasoningEffort === 'string' ? { reasoningEffort: row.reasoningEffort } : {}) }
}

export function sameResearchSelection(left: ResearchSelection | undefined, right: ResearchSelection | undefined): boolean {
  return left?.provider === right?.provider && left?.model === right?.model && left?.reasoningEffort === right?.reasoningEffort
}

function publicFailure(error: unknown): string {
  const code = error && typeof error === 'object' && 'code' in error ? String(error.code) : ''
  if (/sign.in|unauthori[sz]ed|not.authenticated|invalid.grant|login/i.test(code)) {
    return '账号授权不可用，请在 DSH 的模型设置检查。'
  }
  if (code === 'RESEARCH_MODEL_TIMEOUT') return '读取模型目录超时，请检查网络后刷新。'
  // Never return exception bodies that might include a credential-bearing URL.
  return /^[a-z0-9_-]{1,75}$/i.test(code) ? `模型目录读取失败（${code}）` : '模型目录读取失败，请在 DSH 检查网络与授权。'
}

async function withinDirectoryDeadline<T>(query: () => Promise<T>): Promise<T> {
  let deadline: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      query(),
      new Promise<T>((_, reject) => {
        deadline = setTimeout(() => reject(Object.assign(new Error('Model directory timed out'), {
          code: 'RESEARCH_MODEL_TIMEOUT',
        })), 10_000)
      }),
    ])
  } finally {
    if (deadline) clearTimeout(deadline)
  }
}

export async function researchModelCatalog(llm: ResearchModelRuntime | undefined): Promise<{ groups: ResearchProviderState[] }> {
  const installed = llm?.listProviders() ?? []
  const subscription = registeredSubscriptions(llm)
  const providers = [
    { id: 'deepseek-account', name: 'DeepSeek 账号' },
    ...(subscription.length ? subscription : ['chatgpt']).map(id => ({ id, name: 'ChatGPT 订阅' })),
  ]
  const groups = await Promise.all(providers.map(async ({ id, name }): Promise<ResearchProviderState> => {
    if (!llm || !installed.some(provider => provider.id === id) || !accountProviderAllowed(id, llm)) {
      return { id, name, models: [], error: '当前 DSH 未接入此提供方。' }
    }
    try {
      const models = await withinDirectoryDeadline(async () => {
        const list = await llm.listModels(id)
        return Promise.all(list.map(async model => {
          const info = await llm.resolveModelInfo(id, model.id)
          return { id: model.id, name: model.name, ...(info.reasoning ? { reasoning: info.reasoning } : {}) }
        }))
      })
      return { id, name, models, ...(models.length === 0 ? { error: '当前账号没有可用模型，请在 DSH 检查授权。' } : {}) }
    } catch (error) {
      return { id, name, models: [], error: publicFailure(error) }
    }
  }))
  return { groups }
}

export async function verifyResearchSelection(llm: ResearchModelRuntime | undefined, selection: ResearchSelection): Promise<ResearchSelection> {
  if (!accountProviderAllowed(selection.provider, llm)) {
    throw new Error('科研助手仅允许现有 DSH 账号及 ChatGPT 订阅模型，已阻止 API Key 路由。')
  }
  if (!llm || !llm.listProviders().some(provider => provider.id === selection.provider)) {
    throw new Error('当前 DSH 未接入所选模型提供方。')
  }
  const resolved = await withinDirectoryDeadline(async () => {
    const available = await llm.listModels(selection.provider)
    if (!available.some(model => model.id === selection.model)) {
      throw Object.assign(new Error('current account does not offer this model'), { code: 'RESEARCH_MODEL_UNAVAILABLE' })
    }
    return llm.resolveCallConfig(selection, AbortSignal.timeout(8_000))
  }).catch(error => {
    if (error?.code === 'RESEARCH_MODEL_UNAVAILABLE') throw new Error('当前账号目录中没有所选模型，请核对 DSH 授权或重新选择。')
    if (error?.code === 'UNSUPPORTED_REASONING_EFFORT') throw new Error('所选模型不支持该推理强度，请刷新模型列表。')
    throw new Error(publicFailure(error))
  })
  if (resolved.provider !== selection.provider || resolved.model !== selection.model
      || (selection.reasoningEffort !== undefined && resolved.reasoningEffort !== selection.reasoningEffort)) {
    throw new Error('提供方返回的模型参数与所选项不一致。')
  }
  return { provider: resolved.provider, model: resolved.model,
    ...(resolved.reasoningEffort === undefined ? {} : { reasoningEffort: resolved.reasoningEffort }) }
}
