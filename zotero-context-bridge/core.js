/* Read-only protocol helpers. This module performs no I/O. */
(function (root) {
  "use strict";
  const VERSION = 1;
  const ENDPOINT_PATH = "/dsh-companion/context";
  const MAX_SELECTION_CHARS = 24000;
  const TOKEN_PATTERN = /^[0-9a-f]{64}$/;

  function constantTimeEqual(a, b) {
    if (typeof a !== "string" || typeof b !== "string") return false;
    let difference = a.length ^ b.length;
    const length = Math.max(a.length, b.length);
    for (let i = 0; i < length; i++) difference |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
    return difference === 0;
  }

  function trustedLocalHeaders(headers, port) {
    const normalized = {};
    for (const [key, value] of Object.entries(headers || {})) normalized[key.toLowerCase()] = value;
    if (!["127.0.0.1:" + port, "localhost:" + port, "[::1]:" + port].includes(normalized.host)) return null;
    if (Object.hasOwn(normalized, "origin")) return null;
    return normalized;
  }

  // A proof, rather than the long-lived pairing secret, crosses Zotero's debug-logged headers.
  // sign(message) must be HMAC-SHA256, with the token's UTF-8 characters as its key.
  function createRequestVerifier(token, sign, now = Date.now) {
    if (!TOKEN_PATTERN.test(token || "") || typeof sign !== "function") throw new Error("Invalid verifier setup");
    const seen = new Map();
    const maxSkewMs = 60000;
    return async function authorize(headers, port = 23119) {
      const normalized = trustedLocalHeaders(headers, port);
      if (!normalized || typeof normalized.authorization !== "string") return false;
      const proof = /^Bearer ([0-9]{13})\.([0-9a-f]{32})\.([0-9a-f]{64})$/.exec(normalized.authorization);
      if (!proof) return false;
      const timestamp = Number(proof[1]);
      const nonce = proof[2];
      const time = now();
      if (!Number.isSafeInteger(timestamp) || Math.abs(time - timestamp) > maxSkewMs) return false;
      for (const [key, expiresAt] of seen) if (expiresAt < time) seen.delete(key);
      if (seen.has(nonce) || seen.size >= 4096) return false;
      let expected;
      try { expected = await sign(proof[1] + "." + nonce); } catch (_) { return false; }
      if (!constantTimeEqual(expected, proof[3])) return false;
      // Recheck after asynchronous crypto so concurrent copies cannot both be admitted.
      if (seen.has(nonce) || seen.size >= 4096 || Math.abs(now() - timestamp) > maxSkewMs) return false;
      seen.set(nonce, timestamp + maxSkewMs);
      return true;
    };
  }

  function parseQuery(params) {
    const entries = [...params.entries()];
    if (params.has("selection")) {
      const requestId = params.get("requestId");
      if (entries.length !== 2 || params.get("selection") !== "live" ||
          !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(requestId || "")) {
        throw new Error("INVALID_QUERY");
      }
      return { live: true, requestId };
    }
    if (entries.some(([key]) => key !== "fulltext")) throw new Error("INVALID_QUERY");
    if (params.getAll("fulltext").length > 1) throw new Error("INVALID_QUERY");
    const value = params.get("fulltext");
    if (value !== null && value !== "0" && value !== "1") throw new Error("INVALID_QUERY");
    return { fulltext: value === "1" };
  }

  // Zotero 10 PDFView represents canvas selections as per-page ranges.
  // Inspect only the current pane of the selected reader, during a paired request.
  function readerSelection(reader, requireFocus) {
    const view = reader?._internalReader?._lastView;
    const doc = view?._iframeWindow?.document;
    if (!doc) return { error: "UNSUPPORTED" };
    const element = doc.activeElement;
    if ((requireFocus && !doc.hasFocus()) || element?.isContentEditable ||
        element?.closest?.("input,textarea,[contenteditable=true]")) return { error: "NO_SELECTION" };
    let text, pageIndex;
    const dom = doc.getSelection();
    if (dom?.rangeCount && !dom.isCollapsed) {
      text = dom.toString();
      const start = dom.getRangeAt?.(0)?.startContainer;
      const page = (start?.parentElement ?? start)?.closest?.(".page[data-page-number]");
      const number = Number(page?.getAttribute("data-page-number"));
      if (Number.isSafeInteger(number) && number > 0) pageIndex = number - 1;
    }
    if (!text?.trim() && Array.isArray(view._selectionRanges)) {
      const ranges = Array.from(view._selectionRanges);
      if (ranges.length && !ranges[0].collapsed && ranges.every(r => typeof r.text === "string" && Number.isInteger(r.position?.pageIndex))) {
        ranges.sort((a, b) => a.position.pageIndex - b.position.pageIndex);
        text = ranges.map(range => range.text).join("\n");
        pageIndex = ranges[0].position.pageIndex;
      }
    }
    if (!text?.trim()) return { error: "NO_SELECTION" };
    const truncated = text.length > MAX_SELECTION_CHARS;
    if (truncated && requireFocus) return { error: "SELECTION_TOO_LARGE" };
    if (truncated) {
      const unit = text.charCodeAt(MAX_SELECTION_CHARS - 1);
      text = text.slice(0, unit >= 0xd800 && unit <= 0xdbff ? MAX_SELECTION_CHARS - 1 : MAX_SELECTION_CHARS);
    }
    let pageLabel;
    if (Number.isInteger(pageIndex) && pageIndex >= 0) {
      try { pageLabel = view._getPageLabel?.(pageIndex, true); } catch (_) {}
    }
    return { selection: { text, truncated, pageIndex, pageLabel: typeof pageLabel === "string" ? pageLabel : undefined } };
  }

  function liveSelection(zotero, activeWindow, requestId) {
    const fail = (code, error) => jsonResponse(code, { ok: false, error });
    const win = zotero.getMainWindow();
    if (!win || activeWindow !== win || !win.document.hasFocus()) return fail(409, "SOURCE_CHANGED");
    const tabs = win.Zotero_Tabs;
    if (tabs?.selectedType !== "reader") return fail(400, "UNSUPPORTED");
    const reader = zotero.Reader.getByTabID(tabs.selectedID);
    const { error, selection } = readerSelection(reader, true);
    if (error) return fail(error === "UNSUPPORTED" ? 400 : error === "SELECTION_TOO_LARGE" ? 413 : 422, error);
    const attachment = zotero.Items.get(reader.itemID);
    if (!attachment?.isAttachment()) return fail(409, "SOURCE_CHANGED");
    const title = (attachment.parentItem || attachment).getField("title") || "Zotero 选区";
    return jsonResponse(200, { ok: true, liveSelection: { text: selection.text, title, requestId } });
  }

  function zoteroItemURI(Zotero, item) {
    if (item.libraryID === Zotero.Libraries?.userLibraryID) return "zotero://select/library/items/" + item.key;
    const groupID = Zotero.Groups?.getGroupIDFromLibraryID?.(item.libraryID);
    return groupID ? "zotero://select/groups/" + groupID + "/items/" + item.key : null;
  }

  async function currentPaper(Zotero) {
    const win = Zotero.getMainWindow();
    const tabs = win?.Zotero_Tabs;
    if (!tabs || tabs.selectedType !== "reader") return null;
    const reader = Zotero.Reader.getByTabID(tabs.selectedID);
    if (!reader?.itemID) return null;
    const attachment = Zotero.Items.get(reader.itemID);
    if (!attachment?.isAttachment?.()) return null;
    const item = attachment.parentItem || attachment;
    const creators = item.getCreators?.() || [];
    const date = item.getField("date") || "";
    const yearMatch = date.match(/\b\d{4}\b/);
    return {
      attachment, reader,
      paper: {
        title: String(item.getField("title") || attachment.getField("title") || "Untitled paper"),
        key: item.key, libraryID: item.libraryID,
        attachmentKey: attachment.key, attachmentID: attachment.id,
        sourceUri: zoteroItemURI(Zotero, item),
        authors: creators.slice(0, 30).map(c => [c.firstName, c.lastName || c.name].filter(Boolean).join(" ")),
        year: yearMatch ? yearMatch[0] : "",
        abstract: String(item.getField("abstractNote") || "").slice(0, 24000)
      }
    };
  }

  function jsonResponse(code, body) {
    return [code, {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"}, JSON.stringify(body), {logFilter: () => "[Research Companion context redacted]"}];
  }

  const api = { VERSION, ENDPOINT_PATH, MAX_SELECTION_CHARS, TOKEN_PATTERN,
    constantTimeEqual, createRequestVerifier, parseQuery, readerSelection, currentPaper, liveSelection, jsonResponse };
  root.DSHContextBridge = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
