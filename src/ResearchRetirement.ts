// Desktop 0.2.2-rc.5 uses one shared session store across profiles. Only the
// offline helper runs after a user-confirmed quit. A negotiated native Host
// can instead retire just the target under its exclusive admission lease.
export interface RetirementRequest {
  workspaceId: string
  sessionId: string
  createdAt?: number
  prepare?: boolean
  online?: boolean
}

type Identity = { workspaceId: string; sessionId: string; cwd: string; createdAt: number }
type Receipt = Identity & { phase: 'pending' | 'deleted' }
interface Storage {
  retirementProtocol?: string
  planOnlineRetirement?: (target: Identity) => Promise<{ready: boolean; reason?: string}>
  retireOnline?: (target: Identity) => Promise<{phase: 'deleted' | 'offline-required'; reason?: string}>
  retirementStatus?: (id: string) => Receipt | undefined
  stat(id: string): Promise<{header: {id:string; cwd?:string; createdAt:number}} | undefined>
}
interface LiveAgent {
  id: string
  status: string
  inbox: { nextTurn: readonly unknown[]; nextStep: readonly unknown[] }
  cancel(cause: {kind:'user'}, opts: {keepInbox:false}): void
  whenIdle(): Promise<void>
}
interface SessionServices {
  workspaceId: string
  cwd: string
  sessionIds: readonly string[]
  service(name: string): unknown
  anyBridgeWork(): boolean
  hasScheduledWork(id:string): Promise<boolean>
}
const isWorking=(a:LiveAgent)=>a.status==='running' || a.inbox.nextTurn.length>0 || a.inbox.nextStep.length>0

export class ResearchRetirement {
  private lock?: { id: string; until: number }
  private openRequests = new Set<Promise<void>>()

  get quiescing() {
    if (this.lock && this.lock.until <= Date.now()) this.lock=undefined
    return this.lock!==undefined
  }
  async trackRequest(next:()=>Promise<unknown>) {
    let done!:()=>void
    const pending=new Promise<void>(resolve=>{done=resolve})
    this.openRequests.add(pending)
    try { return await next() } finally { this.openRequests.delete(pending);done() }
  }
  available(service:(name:string)=>unknown) {
    return (service('sessionPersistence') as Storage|undefined)?.retirementProtocol==='rc5.offline.v1'
  }
  onlineAvailable(service: (name:string)=>unknown) {
    const store = service('sessionPersistence') as Storage | undefined
    return this.available(service) && typeof store?.planOnlineRetirement === 'function' && typeof store.retireOnline === 'function'
  }
  async plan(req:RetirementRequest, env:SessionServices) {
    if(env.workspaceId!==req.workspaceId || !/^[\w-]{1,128}$/u.test(req.sessionId)) throw new Error('此助手只能管理专属科研工作区。')
    const store=env.service('sessionPersistence') as Storage|undefined
    if(!store || !this.available(env.service) || !store.retirementStatus)throw new Error('科研会话删除适配器尚未准备好。')
    const remembered=store.retirementStatus(req.sessionId)
    let identity:Identity
    if(remembered){
      if(remembered.workspaceId!==req.workspaceId || remembered.cwd!==env.cwd || remembered.createdAt!==req.createdAt)throw new Error('恢复票据与原会话的确认身份不符。')
      identity=remembered
    } else {
      if(!env.sessionIds.includes(req.sessionId))throw new Error('目标会话已不属于科研工作区。')
      const header=(await store.stat(req.sessionId))?.header
      if(header?.id!==req.sessionId || header.cwd!==env.cwd || !Number.isSafeInteger(header.createdAt))throw new Error('无法核实会话的原始日志与工作区身份。')
      if(req.createdAt!==undefined && req.createdAt!==header.createdAt)throw new Error('选择会话后其身份已变化，请重新选择。')
      identity={workspaceId:req.workspaceId,sessionId:req.sessionId,cwd:env.cwd,createdAt:header.createdAt}
    }
    const phase=remembered?.phase??'present'
    const result=(ready:boolean,reason?:string)=>({retirement:{...identity,phase,ready,...reason?{reason}:{}}})
    if(req.online) {
      if(!this.onlineAvailable(env.service)) throw new Error('当前 Host 尚未启用在线删除。')
      const online = (status: string, reason?: string) => ({
        retirement: {...identity, phase:status==='deleted'?'deleted':phase, ready:true, online:status, reason},
      })
      if (phase==='deleted') return online('deleted')
      if (req.prepare && req.createdAt!==identity.createdAt) throw new Error('在线删除需要已确认的原会话身份。')
      if (this.quiescing) throw new Error('DSH 正在准备离线维护，请稍候。')
      if (!req.prepare) {
        const check = await store.planOnlineRetirement!(identity)
        return online(check.ready ? 'available' : 'offline-required', check.reason)
      }
      const receipt = await store.retireOnline!(identity)
      if (receipt.phase==='offline-required') return online('offline-required', receipt.reason)
      const persisted = store.retirementStatus(req.sessionId)
      if (receipt.phase!=='deleted' || persisted?.phase!=='deleted' || persisted.workspaceId!==identity.workspaceId
          || persisted.cwd!==identity.cwd || persisted.createdAt!==identity.createdAt || persisted.sessionId!==identity.sessionId)
        throw new Error('未取得匹配目标的持久删除回执，请重试核对。')
      return online('deleted')
    }
    if(phase==='deleted')return result(true)
    if(req.prepare && req.createdAt!==identity.createdAt)throw new Error('确认对象不完整，无法开始退出。')
    const agents=env.service('agents') as {list():LiveAgent[]}|undefined
    const jobs=env.service('jobs') as {list(id?:string):{status:string}[]}|undefined
    if(!agents || !jobs) return result(false,'无法检查 DSH 全部 Agent 与后台任务，请稍后重试。')
    const inspect=async()=>{
      const roster=agents.list()
      if(roster.some(a=>a.id!==req.sessionId && isWorking(a)) || env.anyBridgeWork())return '其他会话仍在运行或有排队操作，请待任务完成后重试。'
      if([undefined,...roster.map(a=>a.id)].some(id=>jobs.list(id).some(j=>j.status==='running'||j.status==='stopping')))return 'DSH 仍有后台工具或作业，请待任务结束后重试。'
      for(const agent of roster)if(await env.hasScheduledWork(agent.id))return 'DSH 有已启用的定时任务，暂缓退出以免打断任务。'
    }
    const issue=await inspect()
    if(issue)return result(false,issue)
    if(!req.prepare)return result(true)
    if(this.quiescing && this.lock?.id!==req.sessionId)return result(false,'另一项已确认的离线维护正在进行。')
    const guard={id:req.sessionId,until:Date.now()+35_000}
    this.lock=guard
    try{
      let timer:ReturnType<typeof setTimeout>|undefined
      try{
        await Promise.race([Promise.all([...this.openRequests]),new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(new Error('其他 DSH 请求尚未结束，已暂缓退出。')),4000)})])
      }finally{clearTimeout(timer)}
      const blocked=await inspect()
      if(blocked)throw new Error(blocked)
      const target=agents.list().find(a=>a.id===req.sessionId)
      if(target && isWorking(target)){
        if(typeof target.whenIdle!=='function')throw new Error('无法等待目标任务停写，请先正常停止。')
        target.cancel({kind:'user'},{keepInbox:false})
        try{
          await Promise.race([target.whenIdle(),new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(new Error('目标任务仍在收尾，请稍后重试。')),8000)})])
        }finally{clearTimeout(timer)}
      }
      if (phase==='present') {
        const sessions=env.service('sessions') as {get(id:string):unknown;flush(session:unknown):Promise<void>}|undefined
        if (!sessions) throw new Error('无法确认空白会话已写入存储。')
        const live=sessions.get(req.sessionId)
        if(live) await sessions.flush(live)
      }
      const late=await inspect()
      if(late || (target && isWorking(target)))throw new Error(late??'目标会话仍在运行。')
      if(!this.quiescing || this.lock!==guard)throw new Error('维护申请已过期，请重试。')
      return result(true)
    }catch(error){
      if(this.lock===guard)this.lock=undefined
      return result(false,error instanceof Error ? error.message : '无法确认 DSH 已空闲。')
    }
  }
}
