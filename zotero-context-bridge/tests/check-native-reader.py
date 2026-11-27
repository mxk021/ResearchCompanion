#!/usr/bin/env python3
"""Test the packaged XPI in a separate, offline Zotero 10 profile."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import zipfile

TEST_ID = 'reader-fixture@local.invalid'
PROJECT = Path(__file__).resolve().parent.parent

# This test-only plugin opens the supplied PDF in an empty library.
# It exercises the registered endpoint with the real profile's generated pairing.
CHECK = """
if (typeof Zotero === 'undefined') { var Zotero; }
async function startup() {
    async function run() {
        await Zotero.uiReadyPromise;
        if (Zotero.DataDirectory.dir !== EXPECTED_DATA) throw new Error('Unexpected data directory');
        const win = Zotero.getMainWindow();
        // The private library links to an existing PDF. The reader never writes the source.
        const parent = new Zotero.Item('journalArticle');
        parent.setField('title', 'Synthetic Orchard Reference');
        parent.setCreators([{firstName: 'Ada', lastName: 'Fixture', creatorType: 'author'}]);
        await parent.saveTx();
        const attachment = await Zotero.Attachments.linkFromFile({
            file: Zotero.File.pathToFile(FIXTURE_PDF), parentItemID: parent.id
        });
        const reader = await Zotero.Reader.open(attachment.id, {pageIndex: FIXTURE_PAGE});
        await reader._initPromise;
        let view, doc, text;
        for (let n = 0; n < 100; n++) {
            view = reader._internalReader?._lastView;
            doc = view?._iframeWindow?.document;
            text = doc && Array.from(doc.querySelectorAll('[data-page-number="' + (FIXTURE_PAGE + 1) + '"] .textLayer span'))
                .find(span => span.textContent.trim().length > 5)?.firstChild;
            if (text?.nodeType === 3) break;
            await new Promise(resolve => win.setTimeout(resolve, 100));
        }
        if (text?.nodeType !== 3) throw new Error('Missing text layer');
        await view._ensureBasicPageData(FIXTURE_PAGE);
        const chars = view._pdfPages[FIXTURE_PAGE].chars;
        const expected = FIXTURE_SELECTION || text.textContent.trim().split(/\\s+/)[0];
        const compact = txt => txt.replace(/\\s+/g, '');
        const glyphs = chars.map(item => item.ignorable ? '' : compact(item.c ?? ''));
        let start = null, end = null;
        const source = glyphs.join('');
        const match = source.indexOf(compact(expected));
        if (match < 0) throw new Error('Target absent from reader char stream');
        let offset = 0;
        for (const [index, glyph] of glyphs.entries()) {
            if (glyph && offset === match) start = index;
            offset += glyph.length;
            if (offset === match + compact(expected).length) { end = index; break; }
        }
        if (start === null || end === null || end <= start) throw new Error('Invalid target glyph extent');

        const realm = view._iframeWindow;
        function at(index, ratio) {
            const [x1, y1, x2, y2] = view.getClientRect(chars[index].rect, FIXTURE_PAGE);
            return [x1 + ratio * (x2 - x1), (y1 + y2) / 2];
        }
        function dispatch(type, point) {
            const [clientX, clientY] = point;
            const element = doc.elementFromPoint(clientX, clientY);
            if (!element?.closest('.page')) throw new Error('Glyph position is outside the reader: ' +
                JSON.stringify({type, clientX, clientY, width: realm.innerWidth, height: realm.innerHeight}));
            const x = clientX + realm.mozInnerScreenX - win.mozInnerScreenX;
            const y = clientY + realm.mozInnerScreenY - win.mozInnerScreenY;
            win.windowUtils.sendMouseEvent(type, x, y, 0, 1, 0);
        }
        async function select(first, last) {
            view._setSelectionRanges();
            doc.getSelection().removeAllRanges();
            view._iframe.focus();
            const viewer = doc.getElementById('viewerContainer');
            const [x1, y1] = at(first, 0.25), [x2, y2] = at(last, 0.75);
            viewer.scrollTop += (y1 + y2 - viewer.clientHeight) / 2;
            viewer.scrollLeft += (x1 + x2 - viewer.clientWidth) / 2;
            await new Promise(resolve => win.setTimeout(resolve, 200));
            const begin = at(first, 0.25), finish = at(last, 0.75);
            dispatch('mousedown', begin);
            if (view.action?.type !== 'selectText') throw new Error('Native reader did not start selection: ' +
                JSON.stringify({action:view.action?.type, tool:view._tool.type, scrolling:view._scrolling,
                    active:view._pointerDownTriggered, focused:doc.hasFocus()}));
            dispatch('mousemove', finish);
            await new Promise(resolve => win.setTimeout(resolve, 100));
            dispatch('mouseup', finish);
            await new Promise(resolve => win.setTimeout(resolve, 100));
        }
        await select(start, end);
        const initialNative = view._selectionRanges.map(r => r.text).join('\\n');
        const initialMirror = doc.getSelection().toString();
        if (initialNative !== expected) throw new Error('Native pointer range differs from target: ' +
            JSON.stringify({expectedUnits:expected.length, selectedUnits:initialNative.length,
                firstMatch:initialNative[0] === expected[0], lastMatch:initialNative.at(-1) === expected.at(-1),
                expectedOffsets:[start, end + 1],
                actualOffsets:Array.from(view._selectionRanges, r => [r.anchorOffset, r.headOffset])}));
        const pairing = JSON.parse(await IOUtils.readUTF8(PathUtils.join(Zotero.Profile.dir, 'dsh-companion-bridge', 'pairing.json')));
        const encoder = new TextEncoder();
        const key = await crypto.subtle.importKey('raw', encoder.encode(pairing.token), {name:'HMAC', hash:'SHA-256'}, false, ['sign']);
        const endpoint = new Zotero.Server.Endpoints['/dsh-companion/context']();
        async function call(query, localPDF = false) {
            const message = Date.now() + '.' + crypto.randomUUID().replaceAll('-', '');
            const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
            const proof = Array.from(new Uint8Array(signature), byte => byte.toString(16).padStart(2, '0')).join('');
            return endpoint.init({headers: {host:'127.0.0.1:' + Zotero.Server.port, authorization:'Bearer ' + message + '.' + proof,
                ...(localPDF ? {'X-Research-Companion-Local-PDF':'1'} : {})},
                searchParams: new win.URLSearchParams(query)});
        }
        const liveQuery = () => 'selection=live&requestId=' + crypto.randomUUID();
        const live = await call(liveQuery());
        const ordinary = await call('');
        const auto = await call(liveQuery(), true);
        const captured = JSON.parse(auto[2]).liveSelection;
        const pdfFile = captured?.pdfFile;
        const paper = JSON.parse(ordinary[2]).paper;
        const nativeFile = await IOUtils.stat(FIXTURE_PDF);
        await select(start, start + 1);
        const secondNative = view._selectionRanges.map(r => r.text).join('\\n');
        const second = await call(liveQuery());
        await select(start, end);
        const repeated = await call(liveQuery());
        view._setSelectionRanges();
        const empty = await call(liveQuery());
        const cleared = await call('');
        const location = JSON.parse(live[2]).liveSelection?.location;
        const attachmentAndPage = location?.library === 'library' &&
            location.attachmentKey === attachment.key && location.pageIndex === FIXTURE_PAGE;
        // Use the installed Zotero protocol handler, not a stub or an extension command.
        // Start on a different page, then verify the original reader and visible PDF page.
        const viewer = view._iframeWindow.PDFViewerApplication?.pdfViewer;
        let opensOnPage = null;
        if (attachmentAndPage && viewer?.pagesCount > 1) {
            const visible = FIXTURE_PAGE + 1;
            const other = visible === 1 ? 2 : 1;
            viewer.currentPageNumber = other;
            const uri = Services.io.newURI('zotero://open-pdf/library/items/' + location.attachmentKey + '?page=' + visible);
            const { ZoteroProtocolHandler } = ChromeUtils.importESModule('chrome://zotero/content/ZoteroProtocolHandler.mjs');
            await new ZoteroProtocolHandler().getExtension(uri).doAction(uri);
            for (let n = 0; n < 60 && viewer.currentPageNumber !== visible; n++) {
                await new Promise(resolve => win.setTimeout(resolve, 100));
            }
            opensOnPage = viewer.currentPageNumber === visible && Zotero.Reader.getByTabID(reader.tabID) === reader;
        }
        return {version: Zotero.ResearchCompanionContextBridgeStatus.version, focused: doc.hasFocus(),
            liveExact: live[0] === 200 && JSON.parse(live[2]).liveSelection?.text === expected,
            previewExact: JSON.parse(ordinary[2]).selection?.text === expected,
            switchingExact: second[0] === 200 && secondNative !== expected &&
                JSON.parse(second[2]).liveSelection?.text === secondNative,
            repeatExact: repeated[0] === 200 && JSON.parse(repeated[2]).liveSelection?.text === expected,
            verifiedCapture: JSON.parse(live[2]).liveSelection?.capture?.method === 'pdf-canvas',
            mirrorDiffers: initialMirror !== expected,
            selectionUnits: initialNative.length,
            attachmentAndPage, opensOnPage,
            parentAndChild: ordinary[0] === 200 && attachment.parentItem?.id === parent.id &&
                paper?.key === parent.key && paper?.title === 'Synthetic Orchard Reference' &&
                paper?.authors.join(',') === 'Ada Fixture' && paper?.attachmentID === attachment.id &&
                paper?.attachmentKey === attachment.key && captured?.title === paper.title &&
                captured?.capture.attachmentID === attachment.id && reader.itemID === attachment.id,
            optInLocalPDF: live[0] === 200 && !JSON.parse(live[2]).liveSelection?.pdfFile &&
                auto[0] === 200 && pdfFile?.path === FIXTURE_PDF && pdfFile?.bytes === nativeFile.size &&
                pdfFile?.modifiedMs === nativeFile.lastModified && pdfFile?.attachmentID === attachment.id &&
                pdfFile?.attachmentKey === attachment.key && pdfFile?.library === location.library,
            emptyRejected: empty[0] === 422 && JSON.parse(empty[2]).error === 'NO_SELECTION',
            noCache: JSON.parse(cleared[2]).selection === null};
    }
    // Startup must return to allow Zotero's UI readiness promise to resolve.
    run().catch(error => ({failed: error.message, at: error.stack?.split('\\n')[0]})).then(result =>
        IOUtils.writeUTF8(PathUtils.join(Zotero.Profile.dir, 'fixture-result.json'), JSON.stringify(result)));
}
function shutdown() {}
function install() {}
function uninstall() {}
"""

def verify(executable, fixture, root, package, expected_text, page):
    profile = root / 'profile'
    addons = profile / 'extensions'
    addons.mkdir(parents=True)
    database = root / 'data'
    database.mkdir()
    document = fixture.resolve(strict=True)
    manifest = json.loads((PROJECT / 'manifest.json').read_text())
    version = manifest['version']
    packaged = package or PROJECT / f'research-companion-context-{version}.xpi'
    shutil.copyfile(packaged, addons / (manifest['applications']['zotero']['id'] + '.xpi'))
    manifest.update(name='Isolated selection test', version='1.0.0')
    manifest['applications']['zotero']['id'] = TEST_ID
    code = CHECK.replace('EXPECTED_DATA', json.dumps(str(database))).replace('FIXTURE_PDF', json.dumps(str(document)))
    code = code.replace('FIXTURE_SELECTION', json.dumps(expected_text)).replace('FIXTURE_PAGE', str(page - 1))
    with zipfile.ZipFile(addons / (TEST_ID + '.xpi'), 'w', zipfile.ZIP_DEFLATED) as plugin:
        plugin.writestr('manifest.json', json.dumps(manifest))
        plugin.writestr('bootstrap.js', code)

    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    preferences = {
        'extensions.zotero.httpServer.port': port, 'extensions.zotero.useDataDir': True,
        'extensions.zotero.dataDir': str(database), 'extensions.zotero.sync.autoSync': False,
        'extensions.zotero.automaticScraperUpdates': False, 'extensions.update.enabled': False,
        'app.update.auto': False, 'extensions.autoDisableScopes': 0, 'extensions.enabledScopes': 15,
        'extensions.startupScanScopes': 15, 'browser.shell.checkDefaultBrowser': False,
    }
    (profile / 'user.js').write_text(''.join(f'user_pref({json.dumps(k)}, {json.dumps(v)});\n'
                                             for k, v in preferences.items()))
    args = [executable, '-headless', '-no-remote', '-offline', '-profile', profile, '-datadir', database]
    env = dict(os.environ, MOZ_HEADLESS='1', MOZ_NO_REMOTE='1', MOZ_CRASHREPORTER_DISABLE='1', TMPDIR=str(root))
    result_file = profile / 'fixture-result.json'
    with (root / 'launch.log').open('w') as log:
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env,
                                start_new_session=os.name != 'nt')
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and proc.poll() is None and not result_file.exists():
                time.sleep(0.2)
            if not result_file.exists():
                raise SystemExit('The isolated reader did not complete its test.')
            result = json.loads(result_file.read_text())
            print(json.dumps(result))
            expected = dict(version=version, focused=True, liveExact=True, previewExact=True,
                            switchingExact=True, repeatExact=True, verifiedCapture=True,
                            emptyRejected=True, noCache=True, attachmentAndPage=True, optInLocalPDF=True, parentAndChild=True)
            if (any(result.get(k) != v for k, v in expected.items()) or result.get('opensOnPage') is False
                    or page > 1 and result.get('opensOnPage') is not True):
                raise SystemExit('The native reader result differed from the expected selection.')
        finally:
            if proc.poll() is None:
                if os.name == 'nt':
                    proc.terminate()
                else:
                    os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    if os.name == 'nt':
                        proc.kill()
                    else:
                        os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdf', type=Path, help='A local PDF with a selectable text layer, preferably a synthetic fixture')
    parser.add_argument('--xpi', type=Path, help='Use a staged extension package')
    parser.add_argument('--selection', help='Exact visible text of a selection on the requested page')
    parser.add_argument('--page', type=int, default=1)
    parser.add_argument('--zotero', type=Path, default=Path('/Applications/Zotero.app/Contents/MacOS/zotero'))
    args = parser.parse_args()
    if args.page < 1:
        parser.error('--page uses a physical, one-based PDF page number')
    with tempfile.TemporaryDirectory(prefix='research-companion-reader-') as temporary:
        verify(args.zotero, args.pdf, Path(temporary).resolve(), args.xpi, args.selection, args.page)
