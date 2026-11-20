import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

// Compile with swiftc -parse-as-library; arguments: Transcript directory, output PNG.
// Render only the shipped message view with synthetic text and no DSH connection.
@main @MainActor
struct PublicScreenshot {
    static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task {
            do { try await render(); exit(0) }
            catch { fputs("Transcript screenshot failed: \(error)\n", stderr); exit(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(1) }
        app.run()
    }

    static func render() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 630, height: 560), configuration: configuration)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.ignoresMouseEvents = true
        window.alphaValue = 0.001
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        view.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        while (try? await view.evaluateJavaScript("typeof window.ResearchTranscript")) as? String != "object" {
            try await Task.sleep(for: .milliseconds(50))
        }
        let source = "合成材料 · 摆的周期"
        let answer = #"""
        单摆摆动的幅度很小时，周期主要由摆长和重力加速度决定：

        $$T = 2\pi\sqrt{\frac{L}{g}}$$

        这里 $L$ 是从悬点到摆球质心的距离，$g$ 是当地重力加速度。根号说明，**摆长变为 4 倍，周期才变为 2 倍**。

        ### 用一组数核对
        令 $g = 9.8\,\mathrm{m/s^2}$。摆长从 $0.25\,\mathrm{m}$ 增到 $1.00\,\mathrm{m}$，周期约从 1.00 秒增到 2.01 秒。若摆角很大，就不能直接使用这里的小角度近似。
        """#
        let rows: [[String: Any]] = [
            ["id": "sample-question", "role": "user", "text": "这个式子里的摆长为什么在根号下面？能用两组数字比较一下吗？", "original": ""],
            ["id": "sample-answer", "role": "assistant", "text": answer, "original": "",
             "sourceDisplay": source, "sourceTitle": source, "sourcePage": "PDF 第 2 页", "canOpenSource": true],
        ]
        let measure = """
            window.ResearchTranscript.update({session:'sample', rows, order:rows.map(r=>r.id), jump:1, busy:''});
            await document.fonts.ready;
            await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
            const messages = document.getElementById('messages');
            if (messages.querySelectorAll('article').length !== 2 || !messages.querySelector('.katex')) throw Error("preview incomplete");
            return Math.ceil(messages.getBoundingClientRect().height + 8);
            """
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(measure, arguments: ["rows": rows], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
        let height = value as? Double
        guard let height, height > 100, height <= view.bounds.height else { throw CocoaError(.coderInvalidValue) }
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
        snapshot.snapshotWidth = NSNumber(value: Double(view.bounds.width))
        let image = try await view.takeSnapshot(configuration: snapshot)
        let png = NSMutableData()
        guard let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let writer = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.coderInvalidValue)
        }
        // Re-encode the pixels without screenshot or device metadata.
        CGImageDestinationAddImage(writer, pixels, nil)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        try (png as Data).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
    }
}
