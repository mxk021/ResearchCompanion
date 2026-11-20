/* Zotero 10 privileged bootstrap; no outbound network, database writes, or model access. */
if (typeof Zotero === "undefined") { var Zotero; }
const MAX_FULLTEXT_BYTES = 512000;
const BRIDGE_VERSION = "0.1.4";
let bridgeCore;
let installedEndpoint;
let pairingToken;
let verifyRequest;
let running = false;

// IOUtils.stat has no no-follow option. nsIFile.isSymlink performs the actual link check.
function checkedExistingPath(path, expectedType) {
  const file = Zotero.File.pathToFile(path);
  try {
    if (file.isSymlink()) throw new Error("Refusing a symbolic link in bridge-owned storage");
  } catch (error) {
    if (error.result === Components.results.NS_ERROR_FILE_NOT_FOUND) return null;
    throw error;
  }
  if (!file.exists()) return null;
  if (expectedType === "directory" ? !file.isDirectory() : !file.isFile()) {
    throw new Error("Unexpected type in bridge-owned storage");
  }
  return file;
}

async function pairing() {
  const dir = PathUtils.join(Zotero.Profile.dir, "dsh-companion-bridge");
  if (!checkedExistingPath(dir, "directory")) {
    await IOUtils.makeDirectory(dir, { permissions: 0o700, ignoreExisting: false });
  }
  if (!checkedExistingPath(dir, "directory")) throw new Error("Private pairing directory is unavailable");
  await IOUtils.setPermissions(dir, 0o700);
  const path = PathUtils.join(dir, "pairing.json");
  if (checkedExistingPath(path, "regular")) {
    const info = await IOUtils.stat(path);
    if (info.size > 4096) throw new Error("Invalid pairing token file size");
    await IOUtils.setPermissions(path, 0o600);
    const existing = JSON.parse(await IOUtils.readUTF8(path));
    if (!bridgeCore.TOKEN_PATTERN.test(existing.token || "")) throw new Error("Invalid pairing token file");
    return existing.token;
  }
  const randomBytes = crypto.getRandomValues(new Uint8Array(32));
  const token = Array.from(randomBytes, b => b.toString(16).padStart(2, "0")).join("");
  let port = 23119;
  try { port = Zotero.Server.port; } catch (_) { /* Server may still be starting. */ }
  const record = { version: 1, token, endpoint: "http://127.0.0.1:" + port + bridgeCore.ENDPOINT_PATH };
  // The directory is private before creating the file, so the secret is never world-readable.
  await IOUtils.writeUTF8(path, JSON.stringify(record, null, 2), { mode: "create" });
  await IOUtils.setPermissions(path, 0o600);
  return token;
}

async function fulltextFor(attachment) {
  const file = Zotero.Fulltext.getItemCacheFile(attachment);
  if (!file || !checkedExistingPath(file.path, "regular")) return null;
  // Read an existing Zotero cache only. Never trigger extraction, indexing, download or a library write.
  const info = await IOUtils.stat(file.path);
  if (info.type !== "regular") throw new Error("Indexed text is not a regular file");
  const bytes = await IOUtils.read(file.path, { maxBytes: MAX_FULLTEXT_BYTES });
  return {
    text: new TextDecoder("utf-8").decode(bytes),
    truncated: info.size > bytes.length,
    source: "zotero-index"
  };
}

async function contextRequest(request) {
  let port = 23119;
  try { port = Zotero.Server.port; } catch (_) { /* Fail against the default host. */ }
  if (!verifyRequest || !(await verifyRequest(request.headers, port))) {
    return bridgeCore.jsonResponse(403, { ok: false, error: "FORBIDDEN" });
  }
  let query;
  try { query = bridgeCore.parseQuery(request.searchParams); }
  catch (_) { return bridgeCore.jsonResponse(400, { ok: false, error: "INVALID_QUERY" }); }
  if (query.live) return bridgeCore.liveSelection(Zotero, Services.focus.activeWindow, query.requestId);
  const current = await bridgeCore.currentPaper(Zotero);
  if (!current) return bridgeCore.jsonResponse(404, { ok: false, error: "NO_ACTIVE_PAPER" });
  let fulltext = null;
  const warnings = [];
  if (query.fulltext) {
    try { fulltext = await fulltextFor(current.attachment); }
    catch (_) { warnings.push("The current paper's indexed text could not be read."); }
  }
  // A paper switch while asynchronous I/O is in flight must never mix old full text with a new title.
  const stillCurrent = await bridgeCore.currentPaper(Zotero);
  if (!running || stillCurrent?.paper.attachmentID !== current.paper.attachmentID) {
    return bridgeCore.jsonResponse(409, { ok: false, error: "PAPER_CHANGED" });
  }
  return bridgeCore.jsonResponse(200, {
    ok: true, version: bridgeCore.VERSION, capturedAt: new Date().toISOString(),
    paper: current.paper, selection: bridgeCore.readerSelection(stillCurrent.reader, false).selection ?? null,
    fulltext, fulltextStatus: !query.fulltext ? "not-requested" : fulltext ? "available" : "not-indexed",
    warnings
  });
}

async function startup({ rootURI }) {
  let phase = "starting";
  const report = next => {
    phase = next;
    // Non-sensitive, in-memory diagnostics: no token, item metadata, text, or filesystem paths.
    Zotero.ResearchCompanionContextBridgeStatus = { version: BRIDGE_VERSION, phase };
  };
  report(phase);
  try {
    await Zotero.initializationPromise;
    // No UI readiness wait: plugin startup may participate in opening the first UI.
    // Current reader state is resolved lazily only when an authenticated request arrives.
    report("loading-core");
    // Zotero's actual bootstrap loader supplies this global sandbox. Loading a subscript
    // into an arbitrary object can give globalThis a different owner in Gecko.
    Services.scriptloader.loadSubScript(rootURI + "core.js", globalThis);
    bridgeCore = globalThis.DSHContextBridge;
    if (!bridgeCore) throw new Error("Context bridge core failed to load");
    if (Zotero.Server.Endpoints[bridgeCore.ENDPOINT_PATH]) throw new Error("Context bridge endpoint already registered");
    report("pairing");
    pairingToken = await pairing();
    report("crypto");
    // Zotero.Plugins._loadScope explicitly requests the privileged global crypto API.
    const webCrypto = crypto;
    const encoder = new TextEncoder();
    const key = await webCrypto.subtle.importKey("raw", encoder.encode(pairingToken),
      { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    verifyRequest = bridgeCore.createRequestVerifier(pairingToken, async message => {
      const signature = await webCrypto.subtle.sign("HMAC", key, encoder.encode(message));
      return Array.from(new Uint8Array(signature), b => b.toString(16).padStart(2, "0")).join("");
    });
    installedEndpoint = function () {};
    installedEndpoint.prototype = {
      supportedMethods: ["GET"],
      supportedDataTypes: ["application/json"],
      allowRequestsFromUnsafeWebContent: false,
      init: async function (request) {
        try { return await contextRequest(request); }
        catch (_) { return bridgeCore.jsonResponse(500, { ok: false, error: "CONTEXT_UNAVAILABLE" }); }
      }
    };
    running = true;
    Zotero.Server.Endpoints[bridgeCore.ENDPOINT_PATH] = installedEndpoint;
    report("ready");
  } catch (error) {
    Zotero.ResearchCompanionContextBridgeStatus = {
      version: BRIDGE_VERSION, phase: "failed", failedAt: phase,
      error: typeof error?.name === "string" ? error.name : "Error"
    };
    pairingToken = null;
    verifyRequest = null;
    running = false;
    throw error;
  }
}

function shutdown() {
  Zotero.ResearchCompanionContextBridgeStatus = { version: BRIDGE_VERSION, phase: "disabled" };
  running = false;
  if (bridgeCore && Zotero.Server.Endpoints[bridgeCore.ENDPOINT_PATH] === installedEndpoint) {
    delete Zotero.Server.Endpoints[bridgeCore.ENDPOINT_PATH];
  }
  pairingToken = null;
  verifyRequest = null;
  installedEndpoint = null;
}
function install() {}
function uninstall() {}
