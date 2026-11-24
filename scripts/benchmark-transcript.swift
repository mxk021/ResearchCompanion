import AppKit
import WebKit

@MainActor
private final class BenchmarkReady: NSObject, WKScriptMessageHandler {
    var resolve: CheckedContinuation<Void, Never>?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if (message.body as? [String: Bool])?["ready"] == true {
            resolve?.resume()
            resolve = nil
        }
    }
}

/// Synthetic WebKit rendering benchmark. Compile with swiftc -parse-as-library.
/// The browser timing includes synchronous rendering and forced layout. The
/// byte count is JSON payload size, which excludes WebKit IPC overhead.
@main private struct TranscriptBenchmark {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 || (arguments.count == 3 && ["--legacy", "--append"].contains(arguments[2])) else {
            fputs("Usage: benchmark-transcript path/to/Transcript [--legacy|--append]\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fputs("Benchmark timeout\n", stderr); exit(1) }
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("\(error)\n", stderr); exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let resource = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let handler = BenchmarkReady()
        config.userContentController.add(handler, name: "researchTranscript")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 480), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.alphaValue = 0.001
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await withCheckedContinuation { continuation in
            handler.resolve = continuation
            web.loadFileURL(resource.appendingPathComponent("index.html"), allowingReadAccessTo: resource)
        }
        func evaluate(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any {
            try await withCheckedThrowingContinuation { continuation in
                web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { continuation.resume(with: $0) }
            }
        }
        let history = (0..<90).map { i in
            [
                "id": "past-\(i)", "role": i % 2 == 0 ? "user" : "assistant",
                "text": "第 \(i) 条合成消息，" + String(repeating: "合成科研记录温度与实验参数。", count: 12) + #" 公式 $f(x)=x^2$。"#
            ]
        }
        let reply = (0..<45).map { i -> String in
            let paragraph = #"合成结果 $x_i^2+\alpha$，固定输出区间与取样误差，复核条件及相关附注。"#
            let math = #"\begin{aligned} y &= \sum_{i=1}^k\frac{\alpha}{1+x_i^2} \\ x&=\sqrt{u^2+v^2}+"#
            return ["### 第 \(i) 组", paragraph, "$$\n" + math + String(i) + #" \end{aligned}"# + "\n$$", ""].joined(separator: "\n\n")
        }.joined(separator: "\n")
        let updates = 72
        let nativeStart = ProcessInfo.processInfo.systemUptime
        let setup = try await evaluate(#"""
        const mode = Boolean(delta);
        window.bench = {history, reply, times: [], jsBytes: 0, mode, previousText: ''};
        const b = window.bench;
        b.update = (text, streaming, first) => {
          const row = {id: 'tail', role: 'assistant', text, original: '', streaming};
          if (appendText && !first && streaming && b.previousText && text.startsWith(b.previousText)) {
            row.text = text.slice(b.previousText.length);
            row.appendAfterUTF16 = b.previousText.length;
          }
          const payload = mode
            ? {session:'bench', jump: 1, order: first ? history.map(r => r.id) : (b.times.length === 0 ? history.map(r => r.id).concat(row.id) : undefined),
               rows: first ? history : [row]}
            : {session: 'bench', jump:1, rows: first ? history : history.concat(row)};
          const bytes = new TextEncoder().encode(JSON.stringify(payload)).length;
          b.jsBytes += first ? 0 : bytes;
          const start = performance.now();
          window.ResearchTranscript.update(payload);
          const height = document.documentElement.scrollHeight;
          b.previousText = streaming ? text : '';
          return {milliseconds: performance.now() - start, height};
        };
        return b.update('', false, true);
        """#, ["history": history.map { row in row.merging(["original": ""]) { first, _ in first } },
               "reply": reply, "delta": !CommandLine.arguments.contains("--legacy"),
               "appendText": CommandLine.arguments.contains("--append")])
        let first = ProcessInfo.processInfo.systemUptime - nativeStart
        let result = try await evaluate(#"""
        const b = window.bench;
        for (let index=1; index<=updates; index++) {
          const end = Math.floor(b.reply.length * index / updates);
          const measurements = b.update(b.reply.slice(0,end), index<updates, false);
          b.times.push(measurements.milliseconds);
          if (index % 7 === 0) await new Promise(resolve => setTimeout(resolve, 0));
        }
        const sorted = b.times.slice().sort((a,b) => a-b);
        return {calls: updates, rows: document.querySelectorAll('#messages article').length, formulas: document.querySelectorAll('#messages article:last-child .katex').length, sourceUTF16: b.reply.length, bytes: b.jsBytes,
          totalMs: b.times.reduce((a,b)=>a+b,0), medianMs: sorted[Math.floor(sorted.length/2)], p95Ms: sorted[Math.floor(sorted.length*.95)], maxMs: sorted.at(-1)};
        """#, ["updates": updates])
        // Force layout before reading each scroll position. This measures
        // WebKit's synchronous work, independent of refresh rate and animation.
        let scrolling = try await evaluate(#"""
        const height = document.documentElement.scrollHeight - window.innerHeight;
        const offsets = [0.1, 0.7, 0.25, 0.9, 0.45, 0.8, 0.15, 0.65];
        const times = [];
        let moved = 0;
        for (let cycle = 0; cycle < 4; cycle++) for (const offset of offsets) {
          const start = performance.now();
          window.scrollTo(0, height * offset);
          const error = Math.abs(window.scrollY - height * offset);
          times.push(performance.now() - start);
          if (error < 2) moved++;
          await new Promise(resolve => setTimeout(resolve, 0));
        }
        times.sort((a,b) => a-b);
        if (height < window.innerHeight || moved !== times.length) throw new Error('History did not scroll to every test offset');
        return {positions: moved, scrollableHeight: height, medianMs: times[Math.floor(times.length * 0.5)],
          p95Ms: times[Math.floor(times.length * 0.95)]};
        """#)
        let data = try JSONSerialization.data(withJSONObject: [
            "initialNativeMs": first * 1000, "initialWeb": setup, "stream": result, "scroll": scrolling,
        ], options: [.prettyPrinted,.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
