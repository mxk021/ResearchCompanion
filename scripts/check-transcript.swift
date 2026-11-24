import AppKit
import WebKit

private enum CheckError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

private func check(_ condition: @autoclosure () -> Bool, _ detail: String) throws {
    guard condition() else { throw CheckError.failed(detail) }
}

@MainActor
private final class Ready: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var resume: CheckedContinuation<Void, Never>?
    var copied: (id: String, session: String)?
    var sourceID: String?
    var directSource: [String: String]?
    var noteReveals: [[String: String]] = []
    var notes: [(id: String, session: String, selection: String, mode: String?)] = []
    var notePreviewRequested = false

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if (message.body as? [String: Bool])?["ready"] == true {
            resume?.resume()
            resume = nil
        }
        if let body = message.body as? [String: String], let id = body["copyID"], let session = body["session"] {
            copied = (id, session)
        }
        if let body = message.body as? [String: String] {
            if let id = body["sourceID"] { sourceID = id }
            if body["directSourceID"] != nil { directSource = body }
            if body["noteRevealID"] != nil { noteReveals.append(body) }
            if let id = body["noteID"], let session = body["session"], let selection = body["selection"] {
                notes.append((id, session, selection, body["noteMode"]))
            }
        }
        if (message.body as? [String: Any])?["notePreviewID"] != nil { notePreviewRequested = true }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fputs("Failed loading offline transcript: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

/// Compile this check with Sources/DSHPet/ResearchWindowGeometry.swift. The
/// only argument is the path to the resource directory or its copy in the App.
/// Uses synthetic rows in offscreen WebKit. No DSH session or network request.
@main
private struct TranscriptCheck {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "-AppleShowScrollBars") else {
            fputs("Usage: check-transcript path/to/Transcript [-AppleShowScrollBars Always|WhenScrolling]\n", stderr)
            exit(2)
        }
        let native = NSApplication.shared
        native.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) {
            fputs("WebKit check did not finish\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        }
        native.run()
    }

    @MainActor private static func run() async throws {
        let main = NSRect(x: 0, y: 24, width: 1200, height: 760)
        let external = NSRect(x: -1800, y: 35, width: 1800, height: 1000)
        let saved = NSRect(x: -1550, y: 80, width: 842, height: 825)
        try check(ResearchWindowGeometry.visibleFrame(for: saved, screens: [main, external], fallback: main) == saved,
                  "Saved frame moved despite display being present")
        let remaining = ResearchWindowGeometry.visibleFrame(for: saved, screens: [main], fallback: main)
        try check(main.insetBy(dx: 8, dy: 8).contains(remaining) && remaining.width == saved.width && remaining.height < saved.height,
                  "Frame failed to fit the remaining display")
        print("Window frame: preserves saved position, fits after display removal")

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let page = root.appendingPathComponent("index.html")
        let bridge = Ready()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(bridge, name: "researchTranscript")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 365, height: 270), configuration: config)
        web.navigationDelegate = bridge
        let surface = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        surface.contentView = web
        surface.alphaValue = 0.001
        surface.ignoresMouseEvents = true
        surface.orderBack(nil)
        defer { surface.orderOut(nil) }
        await withCheckedContinuation { continuation in
            bridge.resume = continuation
            web.loadFileURL(page, allowingReadAccessTo: root)
        }
        print("WebKit: loaded pinned page and scripts")

        let rows = (0..<28).map { index in
            ["id": "item-\(index)", "role": "assistant", "text": "第 \(index) 条历史记录。", "original": ""]
        }
        let layout = "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));"
        func evaluate(_ script: String, arguments: [String: Any] = [:]) async throws -> Any {
            try await withCheckedThrowingContinuation { continuation in
                web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                    continuation.resume(with: result)
                }
            }
        }
        let initial = try await evaluate("""
            window.ResearchTranscript.update({ session: 'fixture', jump: 1, rows, order: rows.map(row => row.id), busy: '' });
            \(layout)
            return document.documentElement.scrollHeight - (scrollY + innerHeight);
            """, arguments: ["rows": rows])
        try check((initial as? Double ?? .infinity) <= 2, "Initial history did not open at the bottom")

        let reading = try await evaluate("""
            window.scrollTo(0, 40);
            \(layout)
            const range = document.createRange();
            range.selectNodeContents(document.querySelector('.message-body p'));
            window.getSelection().addRange(range);
            return scrollY;
            """)
        let stream = ["id": "tail", "role": "assistant", "text": #"$$\begin{aligned}"#, "original": ""]
        _ = try await evaluate("""
            const tail = { ...stream, streaming: true };
            window.ResearchTranscript.update({ session: 'fixture', jump: 1, order: [...ids, tail.id], rows: [tail], busy: '流式测试' });
            if (!document.querySelector('article:last-child .message-body').textContent.includes(stream.text)) {
              throw new Error('Incomplete formula was removed');
            }
            """, arguments: ["stream": stream, "ids": rows.compactMap { $0["id"] }])
        let long = String(repeating: #"x_i+\frac{\alpha}{1+t}+"#, count: 22) + "y"
        let complete = stream.merging(["text": "$$\n" + long + "\n$$"]) { _, newer in newer }
        let state = try await evaluate("""
            window.ResearchTranscript.update({ session: 'fixture', jump: 1, rows: [{ ...complete, streaming: true }], busy: '' });
            const fonts = await document.fonts.load('16px KaTeX_Main');
            \(layout)
            const formula = document.querySelector('.math-display');
            return { y: scrollY, following: document.getElementById('latest').hidden,
                     selection: window.getSelection().toString(), localFont: fonts.some(font => font.status === 'loaded'),
                     overflow: formula.scrollWidth > formula.clientWidth };
            """, arguments: ["complete": complete]) as? [String: Any]
        try check(state?["y"] as? Double == reading as? Double, "Reader position moved during stream")
        try check(state?["following"] as? Bool == false, "User scroll failed to suspend follow")
        try check(state?["selection"] as? String == "第 0 条历史记录。", "Selection did not survive asynchronous update")
        try check(state?["localFont"] as? Bool == true && state?["overflow"] as? Bool == true,
                  "Local KaTeX font or horizontal scrolling failed")

        let bottom = try await evaluate("""
            document.getElementById('latest').click();
            \(layout)
            return document.documentElement.scrollHeight - (scrollY + innerHeight);
            """)
        try check((bottom as? Double ?? .infinity) <= 2, "Return to latest did not land at the bottom")
        print("WebKit: local KaTeX font, narrow formula, long history, streaming, selection and return to latest passed")

        let extended =
            (complete["text"] ?? "") + "\n\n稳定段落。\n\n" +
            #"[引用][paper]，金额 $5 与 `$x$`，以及 $\alpha^2$。"# +
            "\n\n[paper]: https://example.net/\n\n- 条目 A\n\n- 条目 B\n"
        let incremental = try await evaluate("""
            const view = window.ResearchTranscript;
            const transcript = document.querySelector('#messages');
            const first = transcript.firstElementChild;
            const live = transcript.lastElementChild;
            const formula = live.querySelector('.katex');
            window.getSelection().removeAllRanges();
            const range = document.createRange();
            range.selectNodeContents(formula);
            window.getSelection().addRange(range);
            const selected = range.toString();
            const { startContainer, endContainer, startOffset, endOffset } = range;
            const selectionRetained = () => {
              const selection = window.getSelection();
              if (selection.rangeCount === 0) return false;
              const current = selection.getRangeAt(0);
              return current.startContainer === startContainer && current.endContainer === endContainer
                && current.startOffset === startOffset && current.endOffset === endOffset && current.toString() === selected;
            };
            view.update({ session: 'fixture', jump: 1, rows: [{ ...complete, text: extended, streaming: true }], busy: '' });
            const stableHistory = transcript.firstElementChild === first;
            const stableFormula = live.querySelector('.katex') === formula;
            const stableSelection = selectionRetained();
            const receivedAppendedText = live.textContent.includes('稳定段落');
            const expected = document.createElement('template');
            expected.innerHTML = window.createResearchMarkdown(window.markdownit, window.katex).render(extended);
            const canonical = expected.innerHTML === live.querySelector('.message-body').innerHTML;
            const corrected = extended.replace('x_i+', 'x_j+');
            view.update({ session: 'fixture', jump: 1, order: [...ids, 'saved'],
                          rows: [{ ...complete, id: 'saved', text: corrected }], busy: '' });
            const final = transcript.lastElementChild;
            final.querySelector('.copy-original').click();
            const selection = selected.length > 0 && selectionRetained();
            window.getSelection().removeAllRanges();
            \(layout)
            const finalFormula = final.querySelector('.math-display')?.dataset.latex;
            return { stableHistory, stableFormula, stableSelection, receivedAppendedText, canonical,
                     reused: final === live && transcript.children.length === ids.length + 1,
                     selection, corrected: finalFormula?.trimStart().startsWith('x_j+') === true };
            """, arguments: ["ids": rows.compactMap { $0["id"] }, "extended": extended, "complete": complete]) as? [String: Bool]
        for condition in ["stableHistory", "stableFormula", "stableSelection", "receivedAppendedText"] {
            try check(incremental?[condition] == true, "Stream check failed: \(condition)")
        }
        try check(incremental?["canonical"] == true, "Incremental Markdown differs from the canonical render")
        try check(incremental?["reused"] == true && incremental?["selection"] == true,
                  "Persisting the live reply duplicated the row or lost the selection")
        try check(incremental?["corrected"] == true, "A deferred final correction was lost after selection cleared")
        _ = try await evaluate("return true;")
        try check(bridge.copied?.id == "saved" && bridge.copied?.session == "fixture", "Copy did not resolve the persisted row ID")
        print("WebKit: delta rendering keeps stable elements and selection, matches Markdown, and remaps copy at finalization")

        let appended = try await evaluate(#"""
            const transcript = window.ResearchTranscript;
            const base = '😀 **原文的论点：';
            const row = { id: 'local', role: 'assistant', streaming: true, original: '', text: base };
            const patch = { session: 'compact-strong', jump: 1 };
            transcript.update({ ...patch, rows: [row], order: [row.id] });
            const article = document.querySelector('#messages > article');
            const body = article.querySelector('.message-body');
            const partial = body.textContent.includes('**原文的论点：') && !body.querySelector('strong');
            const suffix = '**梯度下降，$x_i^2$。';
            transcript.update({ ...patch, rows: [{ ...row, text: suffix, appendAfterUTF16: base.length }] });
            const bold = body.querySelector('strong')?.textContent === '原文的论点：';
            const math = body.querySelector('[data-latex]')?.dataset.latex === 'x_i^2';
            const header = article.querySelector('.message-header');
            const observer = new MutationObserver(() => {});
            observer.observe(header, { subtree: true, attributes: true, childList: true });
            const oldText = body.textContent;
            let rejected = false;
            try {
              transcript.update({ ...patch, rows: [{ ...row, text: '丢失的基准', appendAfterUTF16: base.length }] });
            } catch (_) {
              rejected = body.textContent === oldText;
            }
            const final = base + suffix + ' 再核验。';
            transcript.update({ ...patch, rows: [{ ...row, text: final }] });
            const headerUntouched = observer.takeRecords().length === 0;
            observer.disconnect();
            transcript.update({ ...patch, rows: [{ ...row, id: 'settled', streaming: false, text: final }], order: ['settled'] });
            const settled = document.querySelector('#messages > article');
            transcript.update({ ...patch, session: 'elsewhere', rows: [], order: [] });
            transcript.update({ ...patch, rows: [{ ...row, id: 'settled', streaming: false, text: final }], order: ['settled'] });
            const reopened = document.querySelector('#messages > article');
            return partial && bold && math && rejected && headerUntouched && settled === article &&
                reopened.querySelector('strong')?.textContent === '原文的论点：' &&
                reopened.querySelector('[data-latex]')?.dataset.latex === 'x_i^2';
            """#)
        try check(appended as? Bool == true,
                  "WebKit lost the UTF-16 stream base, Markdown correction, retained header, or reopened history")
        print("WebKit: compact bold updates, UTF-16 append and rejected-base recovery survive settling and reopening")

        let noteFeedback = try await evaluate("""
            window.ResearchTranscript.update({ session: 'notes', jump: 2, order: ['quoted'],
              rows: [{ id: 'quoted', role: 'assistant', text: sample, original: '' }], busy: '' });
            const row = document.querySelector('#messages article');
            const text = row.querySelector('.message-body p').firstChild;
            const math = row.querySelector('.math');
            const range = document.createRange();
            range.setStart(text, 0);
            range.setEnd(math.querySelector('annotation').firstChild, 1);
            window.getSelection().removeAllRanges();
            window.getSelection().addRange(range);
            row.querySelector('.answer-note').click();
            row.querySelector('.answer-note-options summary').click();
            row.querySelector('.note-supplement').click();
            row.querySelector('.answer-note-options summary').click();
            row.querySelector('.note-save-as').click();
            row.querySelector('.answer-note').dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 2 }));
            window.getSelection().removeAllRanges();
            row.querySelector('.answer-note').click();
            math.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
            document.querySelector('#save-formula').click();
            math.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }));
            document.querySelector('#save-formula-options').click();
            row.querySelector('.answer-source').click();
            const view = window.ResearchTranscript;
            view.noteSaved('已保存旧笔记.md', 'notes', 'old-receipt');
            view.noteSaved('已保存 A <诗句>.md', 'notes', 'current-receipt');
            view.noteSaved('已保存其他会话.md', 'other', 'other-receipt');
            const feedback = document.querySelector('#note-feedback');
            const status = document.querySelector('#note-feedback-text');
            const reveal = document.querySelector('#reveal-note');
            const visible = !feedback.hidden && !reveal.hidden &&
              status.textContent === '已保存 A <诗句>.md' && status.children.length === 0;
            reveal.click();
            view.noteSaved('原保存位置找不到这份笔记。', 'notes', '');
            const failed = reveal.hidden && status.textContent === '原保存位置找不到这份笔记。';
            reveal.click();
            document.querySelector('#dismiss-note-feedback').click();
            await new Promise(resolve => requestAnimationFrame(resolve));
            return visible && failed && feedback.hidden;
            """, arguments: ["sample": #"选中 $\frac{1}{x}$，保留公式。"#])
        try check(bridge.sourceID == "quoted" && bridge.notes.count == 6 &&
                  bridge.notes.allSatisfy { $0.id == "quoted" && $0.session == "notes" },
                  "Source/note controls did not preserve the displayed answer ID")
        try check(bridge.notes[0].selection == #"选中 $\frac{1}{x}$"# &&
                  bridge.notes[1].selection == bridge.notes[0].selection &&
                  bridge.notes[2].selection == bridge.notes[0].selection && bridge.notes[2].mode == "saveAs" &&
                  bridge.notes[3].selection.isEmpty &&
                  bridge.notes[4].selection == #"$\frac{1}{x}$"# &&
                  bridge.notes[5].selection == bridge.notes[4].selection,
                  "Selected note lost the full LaTeX expression or duplicated KaTeX text")
        try check(bridge.notes.enumerated().filter { $0.element.mode == "supplement" }.map(\.offset) == [1, 5],
                  "Save options went through the quick-save control or lost the selected source")
        try check(noteFeedback as? Bool == true, "Save feedback styles, failure state or safe text were incorrect")
        try check(bridge.noteReveals == [["noteRevealID": "current-receipt", "session": "notes"]],
                  "Finder reveal used an older receipt or transmitted an arbitrary path")
        print("WebKit: note actions preserve selection, LaTeX and explicit save mode with current Finder receipt and readable status")

        let unobtrusiveNotes = try await evaluate("""
            window.getSelection().removeAllRanges();
            const split = document.querySelector('.note-split');
            const save = split.querySelector('.answer-note');
            const notice = document.querySelector('#reading-feedback');
            const before = [notice.hidden, notice.textContent];
            split.dispatchEvent(new Event('pointerenter'));
            split.dispatchEvent(new Event('focusin', { bubbles: true }));
            await new Promise(resolve => requestAnimationFrame(resolve));
            return !save.hasAttribute('title') && save.hasAttribute('aria-description') &&
              notice.hidden === before[0] && notice.textContent === before[1];
            """)
        try check(unobtrusiveNotes as? Bool == true && !bridge.notePreviewRequested && bridge.notes.count == 6,
                  "Hover and keyboard focus must not show instructions or perform note work")

        let direct = try await evaluate("""
            const view = window.ResearchTranscript;
            const openButton = row => row.querySelector('.answer-direct-source');
            const matches = document.querySelector('#messages');
            const existing = matches.querySelector('article');
            const hiddenWithoutCapture = openButton(existing).hidden;
            window.ResearchTranscript.update({ session: 'notes', jump: 3, order: ['quoted', 'shortcut', 'live-source', 'source-without-link'],
              rows: [{ id: 'shortcut', role: 'assistant', text: '[模型网址](https://example.invalid/model)', original: '',
                       sourceObjects: '式 (5) · Fig. 1', sourceTitle: '实际合成科研材料的完整而且很长的校准标题'.repeat(5), sourcePage: 'PDF 文件第 8 页', sourceDisplay: '式 (5) · Fig. 1 · 材料甲 · PDF 文件第 8 页', sourceDetails: '材料甲 · PDF 文件第 8 页 · 阅读器页标签 iv',
                       sourceWarning: '图注边界未能核实，已取得的摘录可能不完整。请打开原页核对。', canOpenSource: true },
                     { id: 'live-source', role: 'assistant', text: '未完成', original: '', streaming: true,
                       sourceDisplay: '未完成材料', canOpenSource: true },
                     { id: 'source-without-link', role: 'assistant', text: '旧网页仅有摘录', original: '',
                       sourceDisplay: '网页乙 <记录>', sourceDetails: '网页乙 <记录>', canOpenSource: false }],
              busy: '' });
            const ready = matches.children[1];
            const directVisible = !openButton(ready).hidden && !ready.querySelector('.answer-source').hidden;
            const partialCaptionVisible = ready.querySelector('.answer-source').textContent === '图注待核对' &&
              ready.querySelector('.answer-source').title.includes('可能不完整');
            const hiddenDuringStream = openButton(matches.children[2]).hidden;
            const showsLabels = openButton(ready).getAttribute('aria-label').includes('PDF 文件第 8 页') &&
              openButton(ready).querySelector('.source-objects').textContent.includes('式 (5) · Fig. 1') &&
              openButton(ready).querySelector('.source-objects').getClientRects().length > 0 &&
              openButton(ready).title.endsWith('阅读器页标签 iv');
            const old = matches.children[3];
            const noFabricatedLink = openButton(old).hidden &&
              old.querySelector('.source-objects').hidden &&
              old.querySelector('.answer-source').textContent.includes('网页乙 <记录>');
            openButton(ready).click();
            await new Promise(resolve => requestAnimationFrame(resolve));
            return { hiddenWithoutCapture, directVisible, partialCaptionVisible, hiddenDuringStream, showsLabels, noFabricatedLink };
            """) as? [String: Bool]
        try check(direct?["hiddenWithoutCapture"] == true && direct?["directVisible"] == true && direct?["partialCaptionVisible"] == true &&
                  direct?["hiddenDuringStream"] == true && direct?["showsLabels"] == true &&
                  direct?["noFabricatedLink"] == true && bridge.directSource == ["directSourceID": "shortcut", "session": "notes"],
                  "Direct jump must send just the completed answer IDs, leave the source sheet, and hide without provenance")
        print("WebKit: direct source targets the settled answer by ID without passing an arbitrary URL")

        let compactLayout = try await evaluate("""
            const second = document.querySelector('#messages').children[1];
            const primary = second.querySelector('.answer-direct-source');
            const more = second.querySelector('.answer-more');
            const save = second.querySelector('.answer-note');
            const arrow = second.querySelector('.answer-note-options summary');
            more.querySelector('summary').click();
            await new Promise(resolve => requestAnimationFrame(resolve));
            const visible = node => node.getClientRects().length > 0;
            const compact = visible(primary) && visible(arrow) && visible(more) &&
              second.querySelectorAll('.copy-original').length === 1 &&
              more.querySelectorAll('button').length === 1 && visible(more.querySelector('.copy-original')) &&
              Math.abs(arrow.getBoundingClientRect().left - save.getBoundingClientRect().right) <= 2 &&
              second.querySelector('.answer-material-label').scrollWidth > second.querySelector('.answer-material-label').clientWidth &&
              visible(second.querySelector('.source-page')) && visible(second.querySelector('.source-objects'));
            more.querySelector('.copy-original').click();
            \(layout)
            return compact && !more.open && document.body.scrollWidth <= innerWidth;
            """)
        try check(compactLayout as? Bool == true && bridge.copied?.id == "shortcut",
                  "Compact menu must preserve the selected answer's copy and close after choosing")
        surface.setContentSize(NSSize(width: 625, height: 270))
        let wideLayout = try await evaluate("""
            \(layout)
            const actions = document.querySelector('#messages').children[1].querySelector('.message-actions');
            return actions.querySelector(':scope > .copy-original').getClientRects().length > 0 &&
                   actions.querySelector('.note-split .answer-note-options').getClientRects().length > 0 &&
                   actions.querySelector('.answer-more').getClientRects().length === 0;
            """)
        try check(wideLayout as? Bool == true, "Wide layout must restore direct actions without a duplicate menu")
        print("WebKit: actual available widths switch answer actions without losing the target or duplicating controls")

        let reset = try await evaluate("""
            const range = document.createRange();
            range.selectNodeContents(document.querySelector('.message-body p'));
            window.getSelection().addRange(range);
            window.ResearchTranscript.update({ session: 'next', jump: 1, order: ['one'],
              rows: [{ id: 'one', role: 'assistant', text: '另一个会话', original: '',
                       sourceObjects: '式 (2)', sourceDisplay: '式 (2) · 材料丙', canOpenSource: true }], busy: '' });
            const list = document.querySelector('#messages');
            const onlyCurrentSource = list.querySelector('.source-objects').textContent.includes('式 (2)') &&
                !list.textContent.includes('Fig. 1') && !list.textContent.includes('图注待核对');
            return list.children.length === 1 && list.textContent.includes('另一个会话') &&
              window.getSelection().isCollapsed && onlyCurrentSource &&
              window.ResearchTranscript.readingCommand === undefined;
            """)
        try check(reset as? Bool == true, "Switching conversations retained prior content or selection")

        let mathSource = #"其中 $x_t$ 是参数，$\hat{g}_t$ 是估计，$H_t^{-1}$ 是逆矩阵。"# +
            "\n\n" + #"$$\begin{pmatrix}1&0\\0&1\end{pmatrix}\frac{1}{x_t^2}$$"# +
            "\n\n$$\n" + long + "\n$$"
        let mathRow = ["id": "math", "role": "assistant", "text": mathSource, "original": mathSource]
        _ = try await evaluate("""
            window.ResearchTranscript.update({ session: 'math-layout', jump: 1, order: ['math'],
              rows: [{ ...mathRow, streaming: true }], busy: '' });
            """, arguments: ["mathRow": mathRow])
        for (appearance, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            surface.appearance = NSAppearance(named: appearance)
            let matched = try await evaluate("""
                const query = matchMedia('(prefers-color-scheme: dark)');
                if (query.matches !== dark) {
                  await Promise.race([
                    new Promise(resolve => query.addEventListener('change', resolve, { once: true })),
                    new Promise(resolve => setTimeout(resolve, 1500))
                  ]);
                }
                return query.matches === dark && getComputedStyle(document.documentElement).backgroundColor ===
                   (dark ? 'rgb(35, 36, 39)' : 'rgb(252, 252, 253)');
                """, arguments: ["dark": dark])
            try check(matched as? Bool == true, "WebKit did not apply the \(appearance.rawValue) palette")
            for width in [365, 625] {
                surface.setContentSize(NSSize(width: CGFloat(width), height: 270))
                let result = try await evaluate("""
                    await document.fonts.ready;
                    \(layout)
                    const formulas = [...document.querySelectorAll('.math-inline')];
                    const displays = [...document.querySelectorAll('.math-display')];
                    const layout = formulas.map(formula => {
                      const probe = () => {
                        const node = document.createElement('span');
                        node.style.cssText = 'display:inline-block;width:0;height:0';
                        return node;
                      };
                      const outside = probe();
                      const inside = probe();
                      formula.before(outside);
                      formula.prepend(inside);
                      const style = getComputedStyle(formula);
                      const measured = { display: style.display, overflow: style.overflowX,
                        baselineDelta: Math.abs(inside.getBoundingClientRect().top - outside.getBoundingClientRect().top) };
                      inside.remove();
                      outside.remove();
                      return measured;
                    });
                    const wide = displays.at(-1);
                    wide.scrollLeft = wide.scrollWidth;
                    const endReachable = wide.scrollLeft > 0 && wide.scrollLeft + wide.clientWidth >= wide.scrollWidth - 2;
                    wide.scrollLeft = 0;
                    return { layout, endReachable, operatorsPreserved: formulas.length === 3 && displays.length === 2 &&
                        formulas.every(formula => formula.querySelector('.katex-html') &&
                          formula.querySelector('annotation')?.textContent === formula.dataset.latex) &&
                        displays[0].querySelector('.katex-html') && displays[0].dataset.latex.includes('pmatrix') };
                    """) as? [String: Any]
                try check(result?["operatorsPreserved"] as? Bool == true, "Native math layout lost superscripts or matrix markup")
                try check(result?["endReachable"] as? Bool == true, "Wide displayed formula cannot scroll to the end")
                let inline = result?["layout"] as? [[String: Any]] ?? []
                try check(inline.count == 3 && inline.allSatisfy { item in
                    item["display"] as? String == "inline" && item["overflow"] as? String == "visible" &&
                        (item["baselineDelta"] as? Double ?? .infinity) <= 1
                }, "Inline math left the text baseline at width \(width) in \(appearance.rawValue): \(inline)")
            }
            if !dark {
                _ = try await evaluate("""
                    window.ResearchTranscript.update({ session: 'math-layout', jump: 1, order: ['math'], rows: [mathRow], busy: '' });
                    window.ResearchTranscript.update({ session: 'math-history', jump: 1, order: ['math'], rows: [mathRow], busy: '' });
                    """, arguments: ["mathRow": mathRow])
            }
        }
        print("WebKit: light and dark AppKit appearances applied readable palettes")
        let scrollbars = NSScroller.preferredScrollerStyle == .legacy ? "always visible" : "overlay"
        print("WebKit: inline math stays on the text baseline, wide display math remains scrollable (\(scrollbars) scrollbars)")
    }
}
