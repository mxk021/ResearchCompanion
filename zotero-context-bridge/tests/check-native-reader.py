#!/usr/bin/env python3
"""Test the packaged XPI with a synthetic PDF in a separate, offline Zotero 10 profile."""
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

# This test-only plugin opens the supplied synthetic PDF in an empty library.
# It exercises the registered endpoint with the real profile's generated pairing.
CHECK = """
if (typeof Zotero === 'undefined') { var Zotero; }
async function startup() {
    async function run() {
        await Zotero.uiReadyPromise;
        if (Zotero.DataDirectory.dir !== EXPECTED_DATA) throw new Error('Unexpected data directory');
        const win = Zotero.getMainWindow();
        const attachment = await Zotero.Attachments.importFromFile({file: Zotero.File.pathToFile(FIXTURE_PDF)});
        const reader = await Zotero.Reader.open(attachment.id);
        await reader._initPromise;
        let doc, text;
        for (let n = 0; n < 100; n++) {
            doc = reader._internalReader?._lastView?._iframeWindow?.document;
            text = doc && Array.from(doc.querySelectorAll('.textLayer span'))
                .find(span => span.textContent.trim().length > 5)?.firstChild;
            if (text?.nodeType === 3) break;
            await new Promise(resolve => win.setTimeout(resolve, 100));
        }
        if (text?.nodeType !== 3) throw new Error('Synthetic PDF has no text layer');
        const range = doc.createRange();
        range.setStart(text, 0);
        range.setEnd(text, Math.min(text.length, 30));
        const expected = range.toString();
        const selection = doc.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        const pairing = JSON.parse(await IOUtils.readUTF8(PathUtils.join(Zotero.Profile.dir, 'dsh-companion-bridge', 'pairing.json')));
        const encoder = new TextEncoder();
        const key = await crypto.subtle.importKey('raw', encoder.encode(pairing.token), {name:'HMAC', hash:'SHA-256'}, false, ['sign']);
        const endpoint = new Zotero.Server.Endpoints['/dsh-companion/context']();
        async function call(query) {
            const message = Date.now() + '.' + crypto.randomUUID().replaceAll('-', '');
            const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(message));
            const proof = Array.from(new Uint8Array(signature), byte => byte.toString(16).padStart(2, '0')).join('');
            return endpoint.init({headers: {host:'127.0.0.1:' + Zotero.Server.port, authorization:'Bearer ' + message + '.' + proof},
                searchParams: new win.URLSearchParams(query)});
        }
        const query = 'selection=live&requestId=' + crypto.randomUUID();
        const live = await call(query);
        const ordinary = await call('');
        selection.removeAllRanges();
        const empty = await call(query);
        const cleared = await call('');
        return {version: Zotero.ResearchCompanionContextBridgeStatus.version, focused: doc.hasFocus(),
            liveExact: live[0] === 200 && JSON.parse(live[2]).liveSelection?.text === expected,
            previewExact: JSON.parse(ordinary[2]).selection?.text === expected,
            emptyRejected: empty[0] === 422 && JSON.parse(empty[2]).error === 'NO_SELECTION',
            noCache: JSON.parse(cleared[2]).selection === null};
    }
    // Startup must return to allow Zotero's UI readiness promise to resolve.
    run().catch(error => ({failed: error.name})).then(result =>
        IOUtils.writeUTF8(PathUtils.join(Zotero.Profile.dir, 'fixture-result.json'), JSON.stringify(result)));
}
function shutdown() {}
function install() {}
function uninstall() {}
"""

def verify(executable, fixture, root):
    profile = root / 'profile'
    addons = profile / 'extensions'
    addons.mkdir(parents=True)
    database = root / 'data'
    database.mkdir()
    document = root / 'synthetic.pdf'
    shutil.copyfile(fixture, document)
    manifest = json.loads((PROJECT / 'manifest.json').read_text())
    version = manifest['version']
    packaged = PROJECT / f'research-companion-context-{version}.xpi'
    shutil.copyfile(packaged, addons / (manifest['applications']['zotero']['id'] + '.xpi'))
    manifest.update(name='Isolated selection test', version='1.0.0')
    manifest['applications']['zotero']['id'] = TEST_ID
    code = CHECK.replace('EXPECTED_DATA', json.dumps(str(database))).replace('FIXTURE_PDF', json.dumps(str(document)))
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
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=log, env=env, start_new_session=True)
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline and proc.poll() is None and not result_file.exists():
                time.sleep(0.2)
            if not result_file.exists():
                raise SystemExit('The isolated reader did not complete its test.')
            result = json.loads(result_file.read_text())
            print(json.dumps(result))
            expected = dict(version=version, focused=True, liveExact=True, previewExact=True, emptyRejected=True, noCache=True)
            if result != expected:
                raise SystemExit('The native reader result differed from the expected selection.')
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('synthetic_pdf', type=Path, help='A synthetic PDF with a selectable text layer')
    parser.add_argument('--zotero', type=Path, default=Path('/Applications/Zotero.app/Contents/MacOS/zotero'))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='research-companion-reader-') as temporary:
        verify(args.zotero, args.synthetic_pdf, Path(temporary).resolve())
