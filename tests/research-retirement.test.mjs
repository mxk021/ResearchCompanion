import test from 'node:test'
import assert from 'node:assert/strict'
import { ResearchRetirement } from '../src/ResearchRetirement.ts'

const identity={workspaceId:'workspace-A',sessionId:'session-A',cwd:'/synthetic-research',createdAt:41}
function fixture() {
  const agent={id:'session-A',status:'idle',inbox:{nextTurn:[],nextStep:[]},cancelled:false,
    cancel(cause,options){ assert.equal(cause.kind,'user');assert.equal(options.keepInbox,false);this.cancelled=true;this.status='idle'},
    async whenIdle(){assert.equal(this.cancelled,true)}}
  const roster=[agent], jobs=[]
  const store={retirementProtocol:'rc5.offline.v1',retirementStatus:()=>undefined,
    async stat(){return {header:{id:'session-A',cwd:identity.cwd,createdAt:41}}}}
  let flushed=0
  const components={sessionPersistence:store,agents:{list:()=>roster},jobs:{list:()=>jobs},sessions:{get:()=>({}),flush:async()=>{flushed++}}}
  const env={workspaceId:identity.workspaceId,cwd:identity.cwd,sessionIds:['session-A'],service:k=>components[k],
    anyBridgeWork:()=>false,hasScheduledWork:async()=>false}
  return {retire:new ResearchRetirement(),env,store,agent,roster,jobs,flushed:()=>flushed}
}
test('inspection binds immutable identity and does not cancel, flush or gate the service',async()=>{
  const {retire,env,agent,flushed}=fixture()
  agent.status='running'
  assert.equal((await retire.plan(identity,env)).retirement.ready,true)
  assert.equal(retire.quiescing,false);assert.equal(agent.cancelled,false);assert.equal(flushed(),0)
  await assert.rejects(()=>retire.plan({...identity,createdAt:42,prepare:true},env))
  await assert.rejects(()=>retire.plan({...identity,workspaceId:'other'},env))
})
test('confirmed preparation stops exactly the active target and materializes a live blank session',async()=>{
  const {retire,env,agent,flushed}=fixture()
  agent.status='running'
  const result=await retire.plan({...identity,prepare:true},env)
  assert.equal(result.retirement.ready,true);assert.equal(agent.cancelled,true);assert.equal(flushed(),1);assert.equal(retire.quiescing,true)
})
test('other work, tools and schedules prevent shutdown, and tagged deleted retries need no second quit',async()=>{
  const {retire,env,agent,roster,jobs,store}=fixture()
  roster.push({...agent,id:'session-B',status:'running'})
  assert.equal((await retire.plan({...identity,prepare:true},env)).retirement.ready,false)
  assert.equal(retire.quiescing,false);assert.equal(agent.cancelled,false)
  roster.pop();jobs.push({status:'stopping'})
  assert.equal((await retire.plan({...identity,prepare:true},env)).retirement.ready,false)
  jobs.pop();env.hasScheduledWork=async()=>true
  assert.equal((await retire.plan({...identity,prepare:true},env)).retirement.ready,false)
  store.retirementStatus=()=>({...identity,phase:'deleted'});env.sessionIds=[]
  assert.deepEqual((await retire.plan(identity,env)).retirement,{...identity,phase:'deleted',ready:true})
})
test('preparation drains admitted requests and releases the maintenance gate on a late external job',async()=>{
  const {retire,env,jobs,flushed}=fixture()
  const before=Promise.withResolvers(), held=Promise.withResolvers()
  const running=retire.trackRequest(async()=>{before.resolve();await held.promise})
  await before.promise
  const preparation=retire.plan({...identity,prepare:true},env)
  while(!retire.quiescing) await new Promise(resolve=>setImmediate(resolve))
  jobs.push({status:'running'});held.resolve();await running
  assert.equal((await preparation).retirement.ready,false);assert.equal(retire.quiescing,false);assert.equal(flushed(),0)
})

test('online plan is read-only; a second host requests offline confirmation before stop',async()=>{
  const {retire,env,store,agent}=fixture()
  let commits=0
  store.planOnlineRetirement=async target=>{assert.deepEqual(target,identity);return {ready:false,reason:'第二个 Host 仍在线'}}
  store.retireOnline=async()=>{++commits;return {phase:'offline-required'}}
  assert.equal(retire.onlineAvailable(env.service),true)
  const planned=await retire.plan({...identity,online:true},env)
  assert.equal(planned.retirement.online,'offline-required')
  assert.equal(commits,0);assert.equal(agent.cancelled,false);assert.equal(retire.quiescing,false)
  await assert.rejects(()=>retire.plan({...identity,online:true,prepare:true,createdAt:undefined},env))
  assert.equal((await retire.plan({...identity,online:true,prepare:true},env)).retirement.online,'offline-required')
  assert.equal(commits,1);assert.equal(agent.cancelled,false);assert.equal(retire.quiescing,false)
})
test('online deletion succeeds only after verifying the exact durable identity',async()=>{
  const {retire,env,store}=fixture()
  store.planOnlineRetirement=async()=>({ready:true})
  store.retireOnline=async()=>({phase:'deleted'})
  await assert.rejects(()=>retire.plan({...identity,online:true,prepare:true},env),/回执/)
  store.retireOnline=async target=>{store.retirementStatus=()=>({...target,phase:'deleted'});return {phase:'deleted'}}
  const result=await retire.plan({...identity,online:true,prepare:true},env)
  assert.equal(result.retirement.phase,'deleted')
  env.sessionIds=[]
  assert.equal((await retire.plan({...identity,online:true,prepare:true},env)).retirement.online,'deleted')
  await assert.rejects(()=>retire.plan({...identity,workspaceId:'other',online:true,prepare:true},env))
})
