const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const path = require('node:path');
const core = require('../core.js');
const root = path.resolve(__dirname, '..');
const TOKEN = 'a'.repeat(64);
function signature(message, token = TOKEN) { return crypto.createHmac('sha256', token).update(message).digest('hex'); }
function proof(timestamp = Date.now(), nonce = crypto.randomBytes(16).toString('hex'), token = TOKEN) {
  const message = timestamp + '.' + nonce;
  return 'Bearer ' + message + '.' + signature(message, token);
}
const headers = () => ({ host: '127.0.0.1:23119', authorization: proof() });

test('context authentication rejects wrong token, browser Origin and non-loopback or rebound Host', async () => {
  const authorize = core.createRequestVerifier(TOKEN, message => signature(message));
  assert.equal(await authorize(headers()), true);
  for (const altered of [
    { authorization: proof(Date.now(), crypto.randomBytes(16).toString('hex'), 'b'.repeat(64)) },
    { authorization: 'Bearer ' + TOKEN + 'x' },
    { authorization: undefined },
    { host: 'example.com:23119' },
    { host: '127.0.0.1.attacker.invalid:23119' },
    { host: '127.0.0.1:80' },
    { host: undefined },
    { origin: 'http://127.0.0.1:23119' },
    { origin: '' },
    { origin: 'null' }
  ]) assert.equal(await authorize({ ...headers(), ...altered }), false, JSON.stringify(altered));
});

test('only explicit bounded current-paper reads are accepted; no keys, paths or duplicate options', () => {
  assert.deepEqual(core.parseQuery(new URLSearchParams('fulltext=1')), { fulltext: true });
  assert.deepEqual(core.parseQuery(new URLSearchParams()), { fulltext: false });
  for (const query of ['fulltext=yes', 'item=ABCD1234', 'path=/etc/passwd', 'fulltext=1&fulltext=0']) {
    assert.throws(() => core.parseQuery(new URLSearchParams(query)), /INVALID_QUERY/);
  }
});

test('current selections are read on demand and cleared immediately, with bounded material previews', () => {
  const view = { _iframeWindow: {document: {activeElement: {}, getSelection: () => null, hasFocus: () => false}},
    _selectionRanges: [], _getPageLabel: () => 'iv' };
  const reader = {_internalReader: {_lastView: view}};
  view._selectionRanges = [{text:'a'.repeat(23999)+'🐇', position:{pageIndex:3}}];
  const selected = core.readerSelection(reader, false).selection;
  assert.equal(selected.text.length,23999);
  assert.equal(selected.truncated,true);
  assert.equal(selected.pageLabel,'iv');
  assert.equal(selected.pageIndex,3);
  assert.deepEqual(core.readerSelection(reader,true),{error:'NO_SELECTION'});
  view._selectionRanges=[];
  assert.deepEqual(core.readerSelection(reader,false),{error:'NO_SELECTION'});
});

function fixture() {
  const data = new Map([['/profile/dsh-companion-bridge/pairing.json', JSON.stringify({ token: TOKEN, version: 1 })], ['/cache/current-paper.txt', 'Original paper evidence.']]);
  const permissions = new Map();
  const types = new Map([['/profile/dsh-companion-bridge', 'directory']]);
  const readPaths = [];
  const fileStats = new Map();
  const missingResult = 12345;
  const events = new Map();
  let selectedAttachmentID = 42;
  const view = {_iframeWindow: {document: {activeElement: {}, hasFocus: () =>false, getSelection: () => null}}, _selectionRanges: []};
  let onRead;
  let attachment = {
    id: 42, key: 'PDF00042', libraryID: 1, isAttachment: () => true,
    isFileAttachment: () => true, isPDFAttachment: () => true,
    getField: key => key === 'title' ? 'Local PDF' : '',
    parentItem: { key: 'ITEM0042', libraryID: 1, getCreators: () => [{ firstName: 'A', lastName: 'Researcher' }],
      getField: key => ({ title: 'A real paper', date: '2026-11-15', abstractNote: 'Abstract.' }[key] || '') }
  };
  const Zotero = {
    initializationPromise: Promise.resolve(), uiReadyPromise: Promise.resolve(),
    Profile: { dir: '/profile' }, Libraries: { userLibraryID: 1 },
    File: { pathToFile: p => ({
      isSymlink: () => types.get(p) === 'symlink',
      exists: () => types.has(p) || data.has(p),
      isDirectory: () => types.get(p) === 'directory',
      isFile: () => types.get(p) === 'regular' || (!types.has(p) && data.has(p)),
      get fileSize() { return fileStats.get(p)?.bytes; },
      get lastModifiedTime() { return fileStats.get(p)?.modifiedMs; }
    }) },
    getMainWindow: () => ({ Zotero_Tabs: { selectedType: 'reader', selectedID: 'reader-42' } }),
    Reader: {
      getByTabID: () => ({ itemID: selectedAttachmentID, _internalReader: {_lastView:view} }),
      registerEventListener: (name, fn) => events.set(name, fn),
      unregisterEventListener: (name, fn) => { if (events.get(name) === fn) events.delete(name); }
    },
    Items: { get: id => id === 42 ? attachment : null },
    Fulltext: { getItemCacheFile: () => ({ path: '/cache/current-paper.txt' }) },
    Server: { port: 23119, Endpoints: {} }
  };
  const sandbox = vm.createContext({
    Zotero, URLSearchParams, TextDecoder, TextEncoder, Date, crypto: crypto.webcrypto,
    Components: { results: { NS_ERROR_FILE_NOT_FOUND: missingResult } },

    PathUtils: { join: (...parts) => parts.join('/') },
    IOUtils: {
      makeDirectory: async (p, opts) => { types.set(p, 'directory'); permissions.set(p, opts.permissions); },
      setPermissions: async (p, mode) => permissions.set(p, mode),
      exists: async p => data.has(p),
      readUTF8: async p => { readPaths.push(p); return data.get(p); },
      writeUTF8: async (p, value) => data.set(p, value),
      stat: async p => ({ type: 'regular', size: Buffer.byteLength(data.get(p)) }),
      read: async (p, opts) => { readPaths.push(p); if (onRead) onRead(); return Buffer.from(data.get(p)).subarray(0, opts.maxBytes); }
    },
    Services: { appShell: { hiddenDOMWindow: { crypto: crypto.webcrypto } }, scriptloader: { loadSubScript: (_url, scope) => vm.runInNewContext(fs.readFileSync(path.join(root, 'core.js'), 'utf8'), scope) } }
  });
  vm.runInContext(fs.readFileSync(path.join(root, 'bootstrap.js'), 'utf8'), sandbox);
  return { sandbox, Zotero, view, events, data, types, fileStats, readPaths, permissions, switchPaper: () => { selectedAttachmentID = 43; }, setOnRead: callback => { onRead = callback; } };
}

function body(result) { return JSON.parse(result[2]); }
function request(extra = {}) { return { headers: headers(), searchParams: new URLSearchParams(), ...extra }; }

test('registered endpoint reads real adapter data, exposes no token, leaves API and library untouched, unloads cleanly', async () => {
  const fixtureData = fixture();
  const { sandbox, Zotero, events, permissions } = fixtureData;
  const originalFulltext = fixtureData.data.get('/cache/current-paper.txt');
  await sandbox.startup({ rootURI: 'test://bridge/' });
  const endpoint = new Zotero.Server.Endpoints[core.ENDPOINT_PATH]();
  assert.equal(events.size, 0, "No background reader listener");
  fixtureData.view._selectionRanges = [{text:'Selected evidence', position:{pageIndex:1}}];
  const response = await endpoint.init(request({ searchParams: new URLSearchParams('fulltext=1') }));
  assert.equal(response[0], 200);
  assert.equal(response[1]['Cache-Control'], 'no-store');
  assert.equal(response[3].logFilter(response[2]), '[Research Companion context redacted]');
  assert.equal(body(response).paper.key, 'ITEM0042');
  assert.equal(body(response).paper.sourceUri, 'zotero://select/library/items/ITEM0042');
  assert.equal(body(response).selection.text, 'Selected evidence');
  fixtureData.view._selectionRanges = [];
  assert.equal(body(await endpoint.init(request())).selection, null);
  assert.equal(body(response).fulltext.text, originalFulltext);
  assert.equal(JSON.stringify(body(response)).includes(TOKEN), false);
  assert.equal(permissions.get('/profile/dsh-companion-bridge'), 0o700);
  assert.equal(permissions.get('/profile/dsh-companion-bridge/pairing.json'), 0o600);
  assert.equal(fixtureData.data.get('/cache/current-paper.txt'), originalFulltext);
  sandbox.shutdown();
  assert.equal(events.size, 0);
  assert.equal(Zotero.Server.Endpoints[core.ENDPOINT_PATH], undefined);
});

test('paper switch during indexed-text read is refused instead of mixing a stale source with current context', async () => {
  const f = fixture();
  await f.sandbox.startup({ rootURI: 'test://bridge/' });
  f.setOnRead(f.switchPaper);
  const endpoint = new f.Zotero.Server.Endpoints[core.ENDPOINT_PATH]();
  const response = await endpoint.init(request({ searchParams: new URLSearchParams('fulltext=1') }));
  assert.equal(response[0], 409);
  assert.equal(body(response).error, 'PAPER_CHANGED');
  f.sandbox.shutdown();
});

test('unauthenticated requests never read the current paper or cache', async () => {
  const f = fixture();
  await f.sandbox.startup({ rootURI: 'test://bridge/' });
  f.Zotero.getMainWindow = () => { throw new Error('must not inspect paper before authorization'); };
  const endpoint = new f.Zotero.Server.Endpoints[core.ENDPOINT_PATH]();
  const response = await endpoint.init(request({ headers: { host: '127.0.0.1:23119' } }));
  assert.equal(response[0], 403);
  assert.equal(body(response).error, 'FORBIDDEN');
  f.sandbox.shutdown();
});

test('no active reader reports an explicit blocker with no library enumeration fallback', async () => {
  const f = fixture();
  await f.sandbox.startup({ rootURI: 'test://bridge/' });
  f.Zotero.getMainWindow = () => ({ Zotero_Tabs: { selectedType: 'library' } });
  const endpoint = new f.Zotero.Server.Endpoints[core.ENDPOINT_PATH]();
  const response = await endpoint.init(request());
  assert.equal(response[0], 404);
  assert.equal(body(response).error, 'NO_ACTIVE_PAPER');
  f.sandbox.shutdown();
});


test('short-lived proofs expire and a valid proof is accepted only once even under concurrent requests', async () => {
  let now = 1794700000000;
  const authorize = core.createRequestVerifier(TOKEN, async message => {
    await Promise.resolve();
    return signature(message);
  }, () => now);
  const h = { host: '127.0.0.1:23119', authorization: proof(now) };
  const results = await Promise.all([authorize(h), authorize(h)]);
  assert.deepEqual(results.sort(), [false, true]);
  assert.equal(await authorize(h), false);
  assert.equal(await authorize({ ...h, authorization: proof(now - 60001) }), false);
  assert.equal(await authorize({ ...h, authorization: proof(now + 60001) }), false);
  assert.equal(await authorize({ ...h, authorization: 'Bearer ' + TOKEN }), false);
});

test('nonce replay records survive the complete validity window of future-dated proofs', async () => {
  let now = 1794700000000;
  const authorize = core.createRequestVerifier(TOKEN, message => signature(message), () => now);
  const h = { host: '127.0.0.1:23119', authorization: proof(now + 59000) };
  assert.equal(await authorize(h), true);
  now += 61000;
  assert.equal(await authorize(h), false);
  now += 60000;
  assert.equal(await authorize(h), false);
  assert.equal(await authorize(headersForTime(now)), true);
  function headersForTime(time) { return {host: '127.0.0.1:23119', authorization: proof(time)}; }
});

test('a symlink in the owned pairing directory is rejected before permissions or reads', async () => {
  const f = fixture();
  f.types.set('/profile/dsh-companion-bridge', 'symlink');
  await assert.rejects(f.sandbox.startup({ rootURI: 'test://bridge/' }), /symbolic link/);
  assert.equal(f.permissions.size, 0);
  assert.deepEqual(f.readPaths, []);
  assert.equal(Object.keys(f.Zotero.Server.Endpoints).length, 0);
});

test('a symlink or non-file pairing token is rejected without modifying its target', async () => {
  for (const type of ['symlink', 'directory']) {
    const f = fixture();
    f.types.set('/profile/dsh-companion-bridge/pairing.json', type);
    await assert.rejects(f.sandbox.startup({ rootURI: 'test://bridge/' }), /symbolic link|Unexpected type/);
    assert.equal(f.permissions.has('/profile/dsh-companion-bridge/pairing.json'), false);
    assert.deepEqual(f.readPaths, []);
  }
});

test('fresh pairing creates only its private storage and never exposes the secret in context responses', async () => {
  const f = fixture();
  f.data.delete('/profile/dsh-companion-bridge/pairing.json');
  await f.sandbox.startup({ rootURI: 'test://bridge/' });
  const record = JSON.parse(f.data.get('/profile/dsh-companion-bridge/pairing.json'));
  assert.match(record.token, /^[0-9a-f]{64}$/);
  assert.equal(record.endpoint, 'http://127.0.0.1:23119/dsh-companion/context');
  assert.equal(f.permissions.get('/profile/dsh-companion-bridge/pairing.json'), 0o600);
  const endpoint = new f.Zotero.Server.Endpoints[core.ENDPOINT_PATH]();
  const response = await endpoint.init(request({ headers: {host: '127.0.0.1:23119', authorization: proof(Date.now(), crypto.randomBytes(16).toString('hex'), record.token)} }));
  assert.equal(response[0], 200);
  assert.equal(response[2].includes(record.token), false);
  f.sandbox.shutdown();
});


test('startup completes without waiting for UI readiness and uses only loader-provided globals', async () => {
  const f = fixture();
  f.Zotero.uiReadyPromise = new Promise(() => {});
  f.data.delete('/profile/dsh-companion-bridge/pairing.json');
  assert.equal('Cc' in f.sandbox, false);
  assert.equal('Ci' in f.sandbox, false);
  await f.sandbox.startup({ rootURI: 'test://bridge/' });
  assert.equal(f.Zotero.ResearchCompanionContextBridgeStatus.phase, 'ready');
  assert.equal(Object.keys(f.Zotero.ResearchCompanionContextBridgeStatus).sort().join(','), 'phase,version');
  const tokenRecord = JSON.parse(f.data.get('/profile/dsh-companion-bridge/pairing.json'));
  assert.match(tokenRecord.token, /^[0-9a-f]{64}$/);
  f.sandbox.shutdown();
  assert.equal(f.Zotero.ResearchCompanionContextBridgeStatus.phase, 'disabled');
});

test('startup failure exposes only a bounded non-sensitive phase diagnostic', async () => {
  const f = fixture();
  f.types.set('/profile/dsh-companion-bridge', 'symlink');
  await assert.rejects(f.sandbox.startup({ rootURI: 'test://bridge/' }), /symbolic link/);
  const status = f.Zotero.ResearchCompanionContextBridgeStatus;
  assert.equal(status.phase, 'failed');
  assert.equal(status.failedAt, 'pairing');
  assert.equal(JSON.stringify(status).includes(TOKEN), false);
  assert.equal(JSON.stringify(status).includes('/profile'), false);
  assert.equal(Object.keys(f.Zotero.Server.Endpoints).length, 0);
});


test('manifest satisfies Zotero 10 required identity, maximum version and loopback-only update URL', () => {
  // The installed modules/Extension.sys.mjs explicitly rejects absent applications.zotero.update_url.
  const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));
  const properties = manifest.applications.zotero;
  assert.equal(manifest.manifest_version, 2);
  assert.equal(properties.id, 'research-companion-context@local.invalid');
  assert.equal(properties.strict_min_version, '10.0');
  assert.equal(properties.strict_max_version, '10.*');
  const updateURL = new URL(properties.update_url);
  assert.equal(updateURL.protocol, 'https:');
  assert.equal(updateURL.hostname, '127.0.0.1');
  assert.equal(updateURL.port, '23119');
  assert.equal(updateURL.pathname, '/dsh-companion/updates.json');
});


test('only the authenticated context endpoint is registered; no update service is exposed', async () => {
  const f = fixture();
  await f.sandbox.startup({ rootURI: 'test://bridge/' });
  assert.deepEqual(Object.keys(f.Zotero.Server.Endpoints), [core.ENDPOINT_PATH]);
  f.sandbox.shutdown();
  assert.deepEqual(Object.keys(f.Zotero.Server.Endpoints), []);
});

test('explicit translation reads only the active reader selection including multi-page canvas text', () => {
  const f = fixture();
  const requestId = '00000000-0000-4000-8000-000000000002';
  assert.deepEqual(core.parseQuery(new URLSearchParams({ selection:'live', requestId })), {live:true, requestId});
  assert.throws(() => core.parseQuery(new URLSearchParams({ selection:'live', requestId, fulltext:'1' })));
  const win = {Zotero_Tabs:{selectedID:'test', selectedType:'reader'}, document:{hasFocus:()=>true}};
  const doc = { hasFocus:()=>true, getSelection:()=>null, activeElement:{} };
  const view = {_iframeWindow:{document:doc}, _selectionRanges:[2,0,1].map(n=>({text:'Page '+n,position:{pageIndex:n}}))};
  f.Zotero.getMainWindow=()=>win;
  const reader = {itemID:42,_internalReader:{_lastView:view}};
  f.Zotero.Reader.getByTabID=()=>reader;
  const run=()=>core.liveSelection(f.Zotero,win,requestId);
  assert.equal(JSON.parse(run()[2]).liveSelection.text,'Page 0\nPage 1\nPage 2');
  assert.equal(core.liveSelection(f.Zotero,{},requestId)[0],409);
  doc.hasFocus=()=>false; assert.equal(run()[0],422);
  doc.hasFocus=()=>true; view._selectionRanges=[];
  doc.getSelection=()=>({rangeCount:1,isCollapsed:false,toString:()=>'old DOM mirror'});
  assert.equal(run()[0],422);
  view._selectionRanges=[{text:'A'.repeat(24001),position:{pageIndex:1}}];
  assert.equal(run()[0],413);
  doc.activeElement={isContentEditable:true};assert.equal(run()[0],422);
});

test('desktop Zotero PDF uses its exact canvas text despite a nonempty, shifted DOM mirror', () => {
  const expected = 'A careful test of x² and ∂L/∂x, with data  —\nincluding the last glyph −𝛼.';
  let native = [{text:expected,position:{pageIndex:5}}];
  const doc = {
    activeElement:{}, hasFocus:()=>true,
    getSelection:()=>({rangeCount:1,isCollapsed:false,toString:()=>'ulation. '+expected.slice(0,-7)})
  };
  const view = {_iframeWindow:{document:doc}, _selectionRanges:native};
  const reader = {_internalReader:{_lastView:view}};
  const read=()=>core.readerSelection(reader,true);
  for (const value of [expected, 'Second selection / α₂', expected]) {
    view._selectionRanges=[{text:value,position:{pageIndex:5}}];
    assert.equal(read().selection.text,value);
    assert.equal(read().method,'pdf-canvas');
  }
  for (const invalid of [[native[0], native[0]], [native[0],{text:'Skip',position:{pageIndex:7}}], [native[0], {position:{pageIndex:6}}]]) {
    view._selectionRanges=invalid;
    assert.deepEqual(read(),{error:'SELECTION_UNVERIFIED'});
  }
  view._selectionRanges=[];
  assert.deepEqual(read(),{error:'NO_SELECTION'});
});

test('native DOM reads do not borrow the PDF canvas selection or leave the current text layer', () => {
  const doc={activeElement:{},hasFocus:()=>true};
  const a={nodeType:1,ownerDocument:doc,closest:selector=>selector==='.textLayer' ? {} : null};
  const b={nodeType:3,parentElement:a};
  const selected={rangeCount:1,isCollapsed:false,getRangeAt:()=>({startContainer:a,endContainer:b}),
    toString:()=>'Native α  \n exact'};
  doc.getSelection=()=>selected;
  const view={_iframeWindow:{document:doc},_nativeTextSelection:{enabled:true},_selectionRanges:[{text:'False mirror'}]};
  const reader={_internalReader:{_lastView:view}};
  assert.equal(core.readerSelection(reader,true).selection.text,selected.toString());
  a.closest=()=>null;
  assert.deepEqual(core.readerSelection(reader,true),{error:'SELECTION_UNVERIFIED'});
  delete view._selectionRanges;
  assert.equal(core.readerSelection(reader,true).method,'document-dom');
  a.ownerDocument={};
  assert.deepEqual(core.readerSelection(reader,true),{error:'SELECTION_UNVERIFIED'});
});

test('live replies are tagged with the active attachment and reject a changed tab during capture', () => {
  const f=fixture();
  const win={Zotero_Tabs:{selectedID:'Reader-1',selectedType:'reader'},document:{hasFocus:()=>true}};
  const view={_iframeWindow:{document:{hasFocus:()=>true,activeElement:{}}},_selectionRanges:[
    {text:'α₁ exact',position:{pageIndex:4}}],_getPageLabel:()=> 'iv'};
  const reader={itemID:42,_internalReader:{_lastView:view}};
  f.Zotero.getMainWindow=()=>win;
  f.Zotero.Reader.getByTabID=()=>reader;
  const req='00000000-0000-4000-8000-000000000003';
  const send=()=>core.liveSelection(f.Zotero,win,req);
  const result=JSON.parse(send()[2]).liveSelection;
  assert.deepEqual(result.capture,{method:'pdf-canvas',tabID:'Reader-1',attachmentID:42,attachmentKey:'PDF00042'});
  assert.deepEqual(result.location,{library:'library',attachmentKey:'PDF00042',pageIndex:4,pageLabel:'iv'});
  assert.equal(result.text,'α₁ exact');
  assert.equal(result.requestId,req);
  const attachment=f.Zotero.Items.get(42);
  attachment.libraryID=7;
  assert.equal(JSON.parse(send()[2]).liveSelection.location,undefined);
  f.Zotero.Groups={getGroupIDFromLibraryID: id=>id===7 ? 123 : null};
  assert.deepEqual(JSON.parse(send()[2]).liveSelection.location,{library:'groups/123',attachmentKey:'PDF00042',pageIndex:4,pageLabel:'iv'});
  attachment.isPDFAttachment=()=>false;
  assert.deepEqual(JSON.parse(send()[2]).liveSelection.location,{library:'groups/123',attachmentKey:'PDF00042'});
  attachment.isFileAttachment=()=>false;
  assert.equal(JSON.parse(send()[2]).liveSelection.location,undefined);
  view._getPageLabel=()=>{win.Zotero_Tabs.selectedID='Reader-2'; return '5';};
  const changed=send();
  assert.equal(changed[0],409);
  assert.equal(JSON.parse(changed[2]).error,'SOURCE_CHANGED');
});

test('active PDF path and file version are returned only to a paired, opt-in live request', async () => {
  const f = fixture();
  const win = {Zotero_Tabs:{selectedID:'Reader-1',selectedType:'reader'},document:{hasFocus:()=>true}};
  f.sandbox.Services.focus = {activeWindow: win};
  const view = {_iframeWindow:{document:{hasFocus:()=>true,activeElement:{}}},
    _selectionRanges:[{text:'Exact local PDF selection.',position:{pageIndex:0}}]};
  const attachment = f.Zotero.Items.get(42);
  attachment.isStoredFileAttachment = () => true;
  attachment.attachmentPath = 'storage:fixture.pdf';
  const stored = '/storage/PDF00042/fixture.pdf';
  f.Zotero.Attachments = {
    getStorageDirectory: a => { assert.equal(a, attachment); return {path:'/storage/PDF00042'}; },
    LINK_MODE_LINKED_FILE: 2, BASE_PATH_PLACEHOLDER:'attachments:',
    resolveRelativePath: raw => { assert.equal(raw, 'attachments:linked.pdf'); return '/linked/linked.pdf'; }
  };
  f.types.set(stored, 'regular');
  f.fileStats.set(stored, {bytes:65536, modifiedMs:1794700000000});
  const reader = {itemID:42,_item:attachment,_internalReader:{_lastView:view}};
  f.Zotero.getMainWindow = () => win;
  f.Zotero.Reader.getByTabID = () => reader;
  await f.sandbox.startup({rootURI:'test://bridge/'});
  const endpoint = new f.Zotero.Server.Endpoints[core.ENDPOINT_PATH]();
  const requestId = '00000000-0000-4000-8000-000000000004';
  const live = () => new URLSearchParams({selection:'live', requestId});
  const optedHeaders = () => ({...headers(), 'X-Research-Companion-Local-PDF':'1'});
  const read = () => endpoint.init(request({headers:optedHeaders(), searchParams:live()}));
  assert.equal(body(await endpoint.init(request({searchParams:live()}))).liveSelection.pdfFile, undefined);
  assert.equal(body(await endpoint.init(request({headers:optedHeaders()}))).pdfFile, undefined);
  assert.equal((await endpoint.init(request({headers:{host:'127.0.0.1:23119','X-Research-Companion-Local-PDF':'1'},
    searchParams:live()})))[0], 403);
  const selected = body(await read()).liveSelection;
  assert.deepEqual(selected.pdfFile, {path:stored, bytes:65536, modifiedMs:1794700000000, attachmentID:42,
    attachmentKey:'PDF00042', library:'library'});
  assert.equal(selected.text, 'Exact local PDF selection.');
  f.types.set(stored, 'symlink');
  assert.equal(body(await read()).liveSelection.pdfFile, undefined);
  const linked = '/linked/linked.pdf';
  f.types.set(linked, 'regular');
  f.fileStats.set(linked, {bytes:12, modifiedMs:1794700000001});
  attachment.isStoredFileAttachment = () => false;
  attachment.attachmentLinkMode = 2;
  attachment.attachmentPath = 'attachments:linked.pdf';
  assert.equal(body(await read()).liveSelection.pdfFile.path, linked);
  attachment.attachmentPath = 'AAAAlegacyAliasMustNotBeMigrated';
  assert.equal(body(await read()).liveSelection.pdfFile, undefined);
  attachment.attachmentPath = '/linked/linked.pdf';
  reader._item = {...attachment, key:'DIFF0001'};
  assert.equal(body(await read()).liveSelection.pdfFile, undefined);
  reader._item = attachment;
  f.fileStats.set(linked, {get bytes() { win.Zotero_Tabs.selectedID = 'Reader-2'; return 12; }, modifiedMs:1794700000001});
  assert.equal((await read())[0], 409);
  f.sandbox.shutdown();
});
