import AppKit
import ApplicationServices
import Security
import SwiftUI

enum SelectionCaptureError: LocalizedError, Equatable {
    case permission, empty, unsupported, protectedContent, timedOut, sourceChanged, tooLarge, zoteroTooLarge, zoteroBridge, copyExpired, copyUnverified, richTextUnavailable
    var errorDescription: String? {
        switch self {
        case .richTextUnavailable: return "原应用仅提供了无法可靠还原的富文本。可在原应用使用「选取文字（科研助手）」服务。"
        case .copyExpired: return "此选取已超时。请回到原窗口，选中正文后重试。"
        case .copyUnverified: return "无法确认此次拷贝来自当前来源窗口。请保持文档在前台，重新选取。"
        case .permission: return "macOS 未允许当前运行的科研助手读取辅助功能。可在「快捷键」检查本次运行的授权，也可在原应用选择「服务 → 翻译选区」。"
        case .empty: return "当前没有选中文字。请在原应用中选中正文后再翻译。"
        case .unsupported: return "当前控件未提供可读选区。可在原应用选择「服务 → 翻译选区」。"
        case .protectedContent: return "此控件包含受保护内容，无法读取选区。"
        case .timedOut: return "原应用读取选区超时，请返回原窗口再试一次。"
        case .sourceChanged: return "前台应用、窗口或选区已切换。请重新选择并翻译。"
        case .tooLarge: return "选区超过本地 1,048,576 个 UTF‑16 字符的读取上限。请分段选取。"
        case .zoteroTooLarge: return "Zotero 当前选区接口最多传回 24,000 个 UTF‑16 字符。请分段选取。"
        case .zoteroBridge: return "Zotero 当前阅读器未提供实时选区接口。请启用新版科研助手只读扩展，或使用「服务 → 翻译选区」。"
        }
    }
}

struct SelectionAuthorizationView: View {
    @State private var trusted = ResearchSelectionCapture.accessibilityAvailable
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(trusted ? "本进程已获辅助功能授权" : "本进程尚未获辅助功能授权")
                Button(trusted ? "重新检查" : "检查授权…") {
                    trusted = ResearchSelectionCapture.accessibilityAvailable
                    if !trusted { trusted = ResearchSelectionCapture.requestAccessibility() }
                }.controlSize(.small)
                if !trusted {
                    Button("打开辅助功能设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { openURL(url) }
                    }.controlSize(.small)
                }
            }
            Text(ResearchSelectionCapture.identityDescription).textSelection(.enabled)
        }
        .font(.caption).foregroundStyle(.secondary)
        .onAppear { trusted = ResearchSelectionCapture.accessibilityAvailable }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = ResearchSelectionCapture.accessibilityAvailable
        }
    }
}

enum ResearchSelectionCapture {
    struct Target: Sendable {
        let pid: pid_t
        let bundleID: String
        let source: String
        let windowID: CGWindowID?
        let documentIdentity: String?
        var isSafari: Bool { ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(bundleID) }
        func hasSameDocument() -> Bool {
            guard let windowID, windowID == ResearchSelectionCapture.frontWindowID(pid) else { return false }
            guard let documentIdentity else { return true }
            return documentIdentity == ResearchSelectionCapture.windowIdentity(pid)
        }
        var isZotero: Bool { ["org.zotero.zotero", "org.zotero.zotero-beta"].contains(bundleID) }
        func isFrontmost() -> Bool {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
            return hasSameDocument()
        }
    }

    // Existing preview-only Services are registered for these hosts.
    static let appIDs: Set<String> = [
        "com.apple.Preview", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
    ]

    static func sourceName(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier == "com.apple.Preview" ? "预览" : (app.localizedName ?? "原应用")
    }

    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    static var accessibilityAvailable: Bool { AXIsProcessTrusted() }

    static let identityDescription: String = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        var signing = "签名信息不可用"
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let values = info as? [String: Any] {
            if let team = values[kSecCodeInfoTeamIdentifier as String] as? String { signing = "签名团队 " + team }
            else if let flags = values[kSecCodeInfoFlags as String] as? NSNumber,
                    flags.uint32Value & 0x0002 /* kSecCodeSignatureAdhoc */ != 0 {
                signing = "临时签名 · 更新后 macOS 可能要求重新授权"
            } else { signing = "已签名" }
            if let hash = values[kSecCodeInfoUnique as String] as? Data {
                signing += " · CDHash " + hash.prefix(8).map { String(format: "%02x", $0) }.joined()
            }
        }
        return [Bundle.main.bundleURL.path, Bundle.main.bundleIdentifier ?? "无应用标识",
                "PID " + String(ProcessInfo.processInfo.processIdentifier), signing].joined(separator: " · ")
    }()

    static func frontWindowID(_ pid: pid_t) -> CGWindowID? {
        // Only window owner, layer and number are used. No image or window title is requested.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? CGWindowID
    }

    private static func windowIdentity(_ pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let window = CopyDocument.element(app, kAXFocusedWindowAttribute) else { return nil }
        let document = CopyDocument.value(window, kAXDocumentAttribute)
        let locator = (document as? URL)?.absoluteString ?? (document as? String) ?? ""
        let title = CopyDocument.value(window, kAXTitleAttribute) as? String ?? ""
        return locator.isEmpty && title.isEmpty ? nil : locator + "\n" + title
    }

    static func target(_ app: NSRunningApplication) -> Target? {
        guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let identifier = app.bundleIdentifier else { return nil }
        return Target(pid: app.processIdentifier, bundleID: identifier, source: sourceName(app),
                      windowID: frontWindowID(app.processIdentifier),
                      documentIdentity: (identifier.contains("Safari") || identifier == "com.kingsoft.wpsoffice.mac") && accessibilityAvailable
                        ? windowIdentity(app.processIdentifier) : nil)
    }

    /// A validated native document canvas for a scoped Copy action. Reject
    /// dialogs and editable controls when direct AX selection was unavailable.
    struct CopyDocument {
        let target: Target
        let window: AXUIElement
        let focus: AXUIElement?
        let title: String

        fileprivate static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, 0.15)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        fileprivate static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }
        init?(_ target: Target) {
            guard target.isFrontmost(), accessibilityAvailable,
                  target.bundleID == "com.kingsoft.wpsoffice.mac" || target.isSafari else { return nil }
            let app = AXUIElementCreateApplication(target.pid)
            guard let window = Self.element(app, kAXFocusedWindowAttribute),
                  Self.value(window, kAXSubroleAttribute) as? String == "AXStandardWindow",
                  let name = Self.value(window, kAXTitleAttribute) as? String, !name.isEmpty else { return nil }
            let focus = Self.element(app, kAXFocusedUIElementAttribute)
            if target.isSafari {
                guard (try? ResearchSelectionCapture.safariDocument(in: target)) != nil else { return nil }
            } else {
                guard let focus, let role = Self.value(focus, kAXRoleAttribute) as? String,
                      ["AXSplitGroup","AXScrollArea","AXLayoutArea"].contains(role),
                      Self.value(focus, "AXProtectedContent") as? Bool != true else { return nil }
            }
            self.target = target; self.focus = focus; self.window = window
            self.title = ResearchMaterial.bounded(name, limit: 512)
        }
        func copyCommand() throws -> AXUIElement {
            guard isCurrent() else { throw SelectionCaptureError.sourceChanged }
            let app = AXUIElementCreateApplication(target.pid)
            guard let bar = Self.element(app, kAXMenuBarAttribute),
                  let menus = Self.value(bar, kAXChildrenAttribute) as? [AXUIElement],
                  let edit = menus.first(where: { node in
                      let title = Self.value(node, kAXTitleAttribute) as? String
                      return title == "Edit" || title == "编辑" || title == "編輯"
                  }),
                  let submenu = (Self.value(edit, kAXChildrenAttribute) as? [AXUIElement])?.first,
                  let commands = Self.value(submenu, kAXChildrenAttribute) as? [AXUIElement],
                  let copy = commands.first(where: { node in
                      guard let title = Self.value(node, kAXTitleAttribute) as? String else { return false }
                      return ["Copy", "复制", "拷贝", "複製", "拷貝"].contains(title)
                  }), let enabled = Self.value(copy, kAXEnabledAttribute) as? Bool
            else { throw SelectionCaptureError.unsupported }
            guard enabled else { throw SelectionCaptureError.empty }
            return copy
        }
        func isCurrent() -> Bool {
            guard target.isFrontmost(), let current = Self(target) else { return false }
            return CFEqual(window, current.window) && title == current.title &&
                ((focus == nil && current.focus == nil) || (focus != nil && current.focus != nil && CFEqual(focus!, current.focus!)))
        }
    }

    static func exactSelection(_ text: String, source: String, title: String) throws -> ResearchMaterial {
        guard text.utf16.count <= ResearchMaterial.localSelectionLimit else { throw SelectionCaptureError.tooLarge }
        guard ResearchMaterial.hasReadableText(text) else { throw SelectionCaptureError.empty }
        return try ResearchMaterial.selection(text, source: source, title: title)
    }

    // An AX refusal is only called an authorization problem when macOS also reports this process untrusted.
    static func mapError(_ status: AXError, trusted: Bool) -> SelectionCaptureError? {
        switch status {
        case .success, .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented: return nil
        case .apiDisabled: return trusted ? .unsupported : .permission
        case .cannotComplete: return .timedOut
        case .invalidUIElement: return .sourceChanged
        default: return .unsupported
        }
    }

    static func current(_ target: Target, requestID: UUID) async throws -> ResearchMaterial {
        guard target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
        if target.isZotero { return try await ResearchZoteroSelection.read(requestID: requestID) }
        if !accessibilityAvailable { throw SelectionCaptureError.permission }
        var lastFailure = SelectionCaptureError.unsupported
        // WebKit may publish the active tab's accessibility focus only after Safari
        // has regained its key window. All attempts belong to this captured document.
        for delay in (target.isSafari ? [0, 45, 110, 180] : [0]) {
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            try Task.checkCancellation()
            guard target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
            do { return try read(target) }
            catch let failure as SelectionCaptureError where failure == .unsupported || failure == .empty {
                lastFailure = failure
            }
        }
        if target.isSafari, try safariDocument(in: target) != nil {
            if await ResearchSafariService.available(for: target) {
                do { return try await ResearchSafariService.read(target, requestID: requestID) }
                catch SelectionCaptureError.unsupported { /* Services not offered by this view. */ }
            }
            // An unacknowledged service delivery has no request token. Until it
            // drains, new requests use this window's independent Copy command.
        }
        if let document = CopyDocument(target) {
            return try await ResearchDocumentCopy.read(document, copy: document.copyCommand())
        }
        throw lastFailure
    }

    /// Inspect only document containers in the current Safari window. PDFKit can
    /// expose a document tree while reporting no focused accessibility element.
    /// Never traverse editable controls, other tabs, sheets, or page text runs.
    private static func safariDocument(in target: Target) throws -> AXUIElement? {
        guard target.isSafari, target.isFrontmost() else { return nil }
        let app = AXUIElementCreateApplication(target.pid)
        guard let window = CopyDocument.element(app, kAXFocusedWindowAttribute),
              CopyDocument.value(window, kAXSubroleAttribute) as? String == "AXStandardWindow" else { return nil }
        if let focus = CopyDocument.element(app, kAXFocusedUIElementAttribute) {
            let role = CopyDocument.value(focus, kAXRoleAttribute) as? String ?? ""
            let sub = CopyDocument.value(focus, kAXSubroleAttribute) as? String ?? ""
            if role == "AXSecureTextField" || sub == "AXSecureTextField" || CopyDocument.value(focus, "AXProtectedContent") as? Bool == true {
                throw SelectionCaptureError.protectedContent
            }
            if ["AXTextField","AXTextArea","AXComboBox","AXSearchField","AXToolbar","AXSheet","AXDialog"].contains(role) { return nil }
        }
        var queue = [window]
        let stop = ProcessInfo.processInfo.systemUptime + 0.45
        for _ in 0..<8 {
            var next: [AXUIElement] = []
            for node in queue.prefix(40) {
                guard ProcessInfo.processInfo.systemUptime < stop else { throw SelectionCaptureError.timedOut }
                let role = CopyDocument.value(node, kAXRoleAttribute) as? String ?? ""
                if role == "AXWebArea" || CopyDocument.value(node, kAXSubroleAttribute) as? String == "AXPDFPluginSubrole" { return node }
                guard ["AXWindow","AXGroup","AXSplitGroup","AXTabGroup","AXScrollArea","AXLayoutArea"].contains(role) else { continue }
                next += (CopyDocument.value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(40)
            }
            if next.isEmpty { break }; queue = next
        }
        return nil
    }

    static func read(_ target: Target) throws -> ResearchMaterial {
        let application = AXUIElementCreateApplication(target.pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.8
        func check() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SelectionCaptureError.timedOut }
        }
        var selectionAttributeAvailable = false
        func attribute(_ node: AXUIElement, _ name: String, parameter: CFTypeRef? = nil) throws -> CFTypeRef? {
            try check()
            AXUIElementSetMessagingTimeout(node, 0.18)
            var value: CFTypeRef?
            let result = if let parameter {
                AXUIElementCopyParameterizedAttributeValue(node, name as CFString, parameter, &value)
            } else {
                AXUIElementCopyAttributeValue(node, name as CFString, &value)
            }
            if result == .noValue, [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, "AXSelectedTextMarkerRange"].contains(name) {
                selectionAttributeAvailable = true
            }
            if result != .success, let error = mapError(result, trusted: result == .apiDisabled && accessibilityAvailable) { throw error }
            return result == .success ? value : nil
        }
        func element(_ node: AXUIElement, _ name: String) throws -> AXUIElement? {
            guard let value = try attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        guard target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
        guard let window = try element(application, kAXFocusedWindowAttribute),
              let focused = try element(application, kAXFocusedUIElementAttribute) ?? safariDocument(in: target) else {
            throw SelectionCaptureError.unsupported
        }
        var nodes: [AXUIElement] = []
        var webArea: AXUIElement?
        var pointer: AXUIElement? = focused
        for _ in 0..<12 {
            guard let node = pointer, let role = try attribute(node, kAXRoleAttribute) as? String else { break }
            let subrole = try attribute(node, kAXSubroleAttribute) as? String
            guard role != "AXSecureTextField", subrole != "AXSecureTextField",
                  try attribute(node, "AXProtectedContent") as? Bool != true else { throw SelectionCaptureError.protectedContent }
            guard !["AXApplication", "AXMenu", "AXMenuItem", "AXToolbar"].contains(role) else { break }
            nodes.append(node)
            if role == "AXWebArea" { webArea = node; break }
            // Never climb out of an editor. An empty selection here is authoritative.
            if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWindow"].contains(role) { break }
            pointer = try element(node, kAXParentAttribute)
        }
        func selectedText() throws -> String {
            for node in nodes {
                if let text = try attribute(node, kAXSelectedTextAttribute) as? String {
                    if !text.isEmpty { return text }
                    selectionAttributeAvailable = true
                }
                if let range = try attribute(node, kAXSelectedTextRangeAttribute),
                   CFGetTypeID(range) == AXValueGetTypeID() {
                    var selection = CFRange()
                    if AXValueGetValue((range as! AXValue), .cfRange, &selection) {
                        if selection.length == 0 { selectionAttributeAvailable = true }
                        if selection.length > ResearchMaterial.localSelectionLimit { throw SelectionCaptureError.tooLarge }
                        if selection.length > 0,
                           let text = try attribute(node, kAXStringForRangeParameterizedAttribute, parameter: range) as? String { return text }
                    }
                }
                if let marker = try attribute(node, "AXSelectedTextMarkerRange"),
                   let text = try attribute(node, "AXStringForTextMarkerRange", parameter: marker) as? String { return text }
            }
            if selectionAttributeAvailable { return "" }
            throw SelectionCaptureError.unsupported
        }
        if target.isSafari, webArea == nil,
           !nodes.contains(where: { ["AXTextField","AXTextArea","AXComboBox","AXSearchField"].contains(CopyDocument.value($0, kAXRoleAttribute) as? String ?? "") }),
           let document = try safariDocument(in: target), CopyDocument.value(document, kAXRoleAttribute) as? String == "AXWebArea" {
            webArea = document
            if !nodes.contains(where: { CFEqual($0, document) }) { nodes.append(document) }
        }
        let original = try selectedText()
        let title = (try attribute(window, kAXTitleAttribute) as? String).flatMap {
            $0.isEmpty ? nil : ResearchMaterial.bounded($0, limit: 512)
        } ?? target.source + "选区"
        var material = try exactSelection(original, source: target.source, title: title)
        let webValue = try webArea.flatMap { try attribute($0, kAXURLAttribute) }
        if let url = (webValue as? URL) ?? (webValue as? String).flatMap(URL.init(string:)),
           let link = ResearchSourceLocation.webURL(url) {
            material.localWebURL = link.absoluteString
            var publicURL = URLComponents(url: link, resolvingAgainstBaseURL: false)
            publicURL?.query = nil
            publicURL?.fragment = nil
            if let value = publicURL?.string, value.utf16.count <= 2048 { material.url = value }
        }
        if target.bundleID == "com.apple.Preview",
           let document = try attribute(window, kAXDocumentAttribute) as? String,
           let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "pdf" {
            material.fileReference = try? ResearchFileReference.capture(url)
        }
        guard target.isFrontmost(), let lastWindow = try element(application, kAXFocusedWindowAttribute),
              CFEqual(lastWindow, window), let lastFocus = try element(application, kAXFocusedUIElementAttribute) ?? safariDocument(in: target),
              CFEqual(lastFocus, focused), try selectedText() == original else { throw SelectionCaptureError.sourceChanged }
        return material
    }
}

/// Safari's built-in PDF view can own a visible selection without AX text.
/// Its system Services responder sends that exact selection on a private board.
@MainActor
enum ResearchSafariService {
    private final class Flight {
        let id: UUID
        let target: ResearchSelectionCapture.Target
        var delivered: Result<ResearchMaterial, Error>?
        var dispatched = false
        var abandoned = false
        init(_ id: UUID, _ target: ResearchSelectionCapture.Target) { self.id = id; self.target = target }
    }
    private static var flight: Flight?
    private static var accepted: (id: UUID, pid: pid_t, until: TimeInterval)?
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func available(for target: ResearchSelectionCapture.Target) -> Bool {
        if let old = flight, old.abandoned,
           NSRunningApplication(processIdentifier: old.target.pid)?.isTerminated != false {
            flight = nil
        }
        return flight == nil
    }
    static func allowsActivation(from pid: pid_t) -> Bool {
        (flight?.target.pid == pid && flight?.dispatched == true && flight?.abandoned == false)
            || (accepted?.pid == pid && (accepted?.until ?? 0) >= now)
    }
    static func returned(_ id: UUID, target: ResearchSelectionCapture.Target) -> Bool {
        accepted?.id == id && allowsActivation(from: target.pid) && target.hasSameDocument()
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
    }
    static func consume(_ board: NSPasteboard) -> Bool {
        guard let current = flight else { return false }
        guard !current.abandoned else { flight = nil; return true }
        let target = current.target
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        current.delivered = Result {
            guard current.dispatched, board.name != .general, (front == target.pid || front == getpid()),
                  target.hasSameDocument() else { throw SelectionCaptureError.sourceChanged }
            guard let text = board.string(forType: .string) ?? board.string(forType: .init("NSStringPboardType")) else {
                throw SelectionCaptureError.empty
            }
            let app = AXUIElementCreateApplication(target.pid)
            guard let window = ResearchSelectionCapture.CopyDocument.element(app, kAXFocusedWindowAttribute) else {
                throw SelectionCaptureError.sourceChanged
            }
            let title = ResearchSelectionCapture.CopyDocument.value(window, kAXTitleAttribute) as? String ?? target.source
            let locator = ResearchSelectionCapture.CopyDocument.value(window, kAXDocumentAttribute)
            var material = try ResearchSelectionCapture.exactSelection(text, source: target.source, title: title)
            // Safari's AXDocument is its URL, even when the window title is a PDF URL.
            if let raw = (locator as? URL) ?? (locator as? String).flatMap(URL.init(string:)),
               let url = ResearchSourceLocation.webURL(raw) {
                material.localWebURL = url.absoluteString
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.query = nil; components?.fragment = nil
                if let locator = components?.string, locator.utf16.count <= 2048 { material.url = locator }
            }
            return material
        }
        accepted = (current.id, target.pid, now + 1.5)
        return true
    }

    static func read(_ target: ResearchSelectionCapture.Target, requestID: UUID) async throws -> ResearchMaterial {
        guard flight == nil else { throw SelectionCaptureError.timedOut }
        let job = Flight(requestID, target)
        flight = job
        defer {
            // A Services callback carries no caller-defined token. Never bind a late
            // payload to a newer capture. Drain a dispatched, cancelled delivery first.
            if job.dispatched && job.delivered == nil { job.abandoned = true }
            else if flight === job { flight = nil }
        }
        typealias AX = ResearchSelectionCapture.CopyDocument
        func children(_ node: AXUIElement) -> [AXUIElement] { AX.value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
        func title(_ node: AXUIElement) -> String { AX.value(node, kAXTitleAttribute) as? String ?? "" }
        func press(_ node: AXUIElement) throws {
            try Task.checkCancellation()
            guard target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
            AXUIElementSetMessagingTimeout(node, 0.18)
            guard AXUIElementPerformAction(node, kAXPressAction as CFString) == .success else { throw SelectionCaptureError.unsupported }
        }
        let app = AXUIElementCreateApplication(target.pid)
        guard target.isFrontmost(), let bar = AX.element(app, kAXMenuBarAttribute) else { throw SelectionCaptureError.sourceChanged }
        guard let appMenu = children(bar).first(where: { title($0).hasPrefix("Safari") }),
              let appItems = children(appMenu).first,
              let service = children(appItems).first(where: { ["服务","服務","Services"].contains(title($0)) })
        else { throw SelectionCaptureError.unsupported }
        try press(appMenu)
        defer {
            if !job.dispatched && target.isFrontmost() {
                _ = AXUIElementPerformAction(service, kAXCancelAction as CFString)
                _ = AXUIElementPerformAction(appItems, kAXCancelAction as CFString)
            }
        }
        try press(service)
        let ready = now + 0.55
        var matches: [AXUIElement] = []
        while now < ready {
            if let menu = children(service).first {
                matches = children(menu).filter { title($0) == "选取文字（科研助手）" }
                if !matches.isEmpty { break }
            }
            try await Task.sleep(for: .milliseconds(25))
            guard target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
        }
        guard matches.count == 1 else { throw SelectionCaptureError.unsupported }
        guard AX.value(matches[0], kAXEnabledAttribute) as? Bool == true else { throw SelectionCaptureError.empty }
        job.dispatched = true
        do { try press(matches[0]) } catch { job.dispatched = false; throw error }
        let deadline = now + 2.0
        while now < deadline {
            try Task.checkCancellation()
            if let result = job.delivered { return try result.get() }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard (front == target.pid || front == getpid()), target.hasSameDocument() else { throw SelectionCaptureError.sourceChanged }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw SelectionCaptureError.timedOut
    }
}

/// A nonempty, unrelated pasteboard is never overwritten programmatically. In
/// that case ask for the user's own Copy once. A fresh copy made during this
/// request can be replaced by this document's next native Copy.
@MainActor
enum ResearchDocumentCopy {
    private static var previous: (pid: pid_t, revision: Int)?
    static func read(_ document: ResearchSelectionCapture.CopyDocument, copy: AXUIElement) async throws -> ResearchMaterial {
        let board = NSPasteboard.general
        let initial = board.changeCount
        var copyAt: TimeInterval?
        var ambiguous = false
        let modifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let automatic = (board.types ?? []).isEmpty || (previous?.pid == document.target.pid && previous?.revision == initial)
        guard document.isCurrent(), let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown,.leftMouseDown,.rightMouseDown], handler: { event in
            if event.type != .keyDown { ambiguous = true; return }
            if event.keyCode == 53 { ambiguous = true; return }
            guard event.keyCode == 8, !event.isARepeat,
                  event.modifierFlags.intersection(modifiers) == .command else { return }
            if !automatic, copyAt == nil, document.target.isFrontmost() { copyAt = event.timestamp }
            else { ambiguous = true }
        }) else { throw SelectionCaptureError.copyUnverified }
        defer { NSEvent.removeMonitor(monitor) }
        var panel: NSPanel?
        if automatic {
            guard document.isCurrent(), board.changeCount == initial else { throw SelectionCaptureError.sourceChanged }
            copyAt = ProcessInfo.processInfo.systemUptime
            guard AXUIElementPerformAction(copy, kAXPressAction as CFString) == .success else { throw SelectionCaptureError.unsupported }
        } else {
            let prompt = NSPanel(contentRect: .init(x: 0,y: 0,width: 410,height: 65), styleMask: [.nonactivatingPanel,.titled,.fullSizeContentView],
                                 backing: .buffered, defer: false)
            prompt.titleVisibility = .hidden; prompt.titlebarAppearsTransparent = true; prompt.level = .floating
            prompt.isReleasedWhenClosed = false; prompt.ignoresMouseEvents = true; prompt.hidesOnDeactivate = false
            let label = NSTextField(wrappingLabelWithString: "请在\(document.target.source)按一次 ⌘C，或按 Esc 取消。\n这次复制会保留在剪贴板中。")
            label.frame = .init(x: 15,y: 8,width: 385,height: 45); prompt.contentView?.addSubview(label)
            if let area = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame {
                prompt.setFrameTopLeftPoint(.init(x: max(area.minX,area.maxX-430),y: area.maxY-16))
            }
            prompt.orderFrontRegardless(); panel = prompt
        }
        defer { panel?.orderOut(nil) }
        let limit = ProcessInfo.processInfo.systemUptime + 8
        var firstChange: TimeInterval?
        var revision = initial
        var lastChange: TimeInterval = 0
        while true {
            try Task.checkCancellation()
            guard !ambiguous, document.target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
            let now = ProcessInfo.processInfo.systemUptime
            guard now < limit else { throw SelectionCaptureError.copyExpired }
            let observed = board.changeCount
            if observed != revision {
                if let firstChange, now - firstChange > 0.40 { throw SelectionCaptureError.copyUnverified }
                firstChange = firstChange ?? now; lastChange = now; revision = observed
            }
            if let firstChange, let copyAt {
                guard firstChange >= copyAt - 0.045, firstChange - copyAt < 1.2 else { throw SelectionCaptureError.copyUnverified }
                if now - lastChange >= 0.12 {
                    guard document.isCurrent(), let items = board.pasteboardItems, items.count == 1 else { throw SelectionCaptureError.copyUnverified }
                    let item = items[0], types = Set(item.types.map(\.rawValue))
                    guard types.isDisjoint(with: ["org.nspasteboard.ConcealedType","org.nspasteboard.TransientType",
                        "org.nspasteboard.AutoGeneratedType",NSPasteboard.PasteboardType.fileURL.rawValue]) else { throw SelectionCaptureError.protectedContent }
                    if let declared = item.string(forType: .init("org.nspasteboard.source")), declared != document.target.bundleID {
                        throw SelectionCaptureError.copyUnverified
                    }
                    guard let text = try text(from: item), board.changeCount == revision, document.isCurrent() else {
                        throw SelectionCaptureError.copyUnverified
                    }
                    let material = try ResearchSelectionCapture.exactSelection(text, source: document.target.source, title: document.title)
                    previous = (document.target.pid,revision)
                    return material
                }
            } else if let firstChange, now - firstChange > 0.16 { throw SelectionCaptureError.copyUnverified }
            else if let copyAt, now - copyAt > 1.2 { throw SelectionCaptureError.empty }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func text(from item: NSPasteboardItem) throws -> String? {
        if let plain = item.string(forType: .string) ?? item.string(forType: .init("NSStringPboardType")), !plain.isEmpty { return plain }
        if let rtf = item.data(forType: .rtf) {
            guard rtf.count <= ResearchMaterial.localSelectionLimit * 4 else { throw SelectionCaptureError.tooLarge }
            if let decoded = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string, !decoded.isEmpty { return decoded }
        }
        if let html = item.data(forType: .html) {
            guard html.count <= ResearchMaterial.localSelectionLimit * 4 else { throw SelectionCaptureError.tooLarge }
            guard let result = HTMLSelectionText.decode(html) else { throw SelectionCaptureError.richTextUnavailable }
            return result
        }
        return nil
    }
}


/// Office also publishes HTML fragments. Decode only structurally readable text.
/// SAX never instantiates WebKit, loads images, evaluates scripts or fetches DTDs.
/// Unsupported HTML-only selections fail explicitly instead of losing characters.
private final class HTMLSelectionText: NSObject, XMLParserDelegate {
    private static let hidden: Set<String> = ["head", "script", "style", "template", "noscript"]
    private static let blocks: Set<String> = ["p", "div", "br", "li", "tr", "blockquote", "section", "pre",
                                              "h1", "h2", "h3", "h4", "h5", "h6"]
    private var skipDepth = 0
    private var depth = 0
    private var count = 0
    private var pendingBreak = false
    private var output = ""

    static func decode(_ data: Data) -> String? {
        guard let markup = String(data: data, encoding: .utf8),
              markup.range(of: #"<!\s*(?:DOCTYPE|ENTITY)"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        // Recognize the common HTML-only spacing entity without introducing a DTD.
        let input = markup.replacingOccurrences(of: "&nbsp;", with: "&#160;")
        for document in [input, "<selectionRoot>" + input + "</selectionRoot>"] {
            let decoder = HTMLSelectionText()
            let parser = XMLParser(data: Data(document.utf8))
            parser.shouldResolveExternalEntities = false
            parser.externalEntityResolvingPolicy = .never
            parser.delegate = decoder
            if parser.parse(), parser.parserError == nil, !decoder.output.isEmpty { return decoder.output }
        }
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        guard depth <= 80 else { parser.abortParsing(); return }
        let tag = elementName.split(separator: ":").last?.lowercased() ?? ""
        if skipDepth > 0 || Self.hidden.contains(tag) { skipDepth += 1; return }
        if Self.blocks.contains(tag) { pendingBreak = true }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        if skipDepth > 0 { skipDepth -= 1; return }
        if Self.blocks.contains(elementName.split(separator: ":").last?.lowercased() ?? "") { pendingBreak = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0, !string.isEmpty else { return }
        count += string.utf16.count + (pendingBreak ? 1 : 0)
        guard count <= ResearchMaterial.localSelectionLimit else { parser.abortParsing(); return }
        if pendingBreak && !output.isEmpty && output.last != "\n" && string.first != "\n" { output.append("\n") }
        pendingBreak = false
        output.append(string)
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let value = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: value) }
        else { parser.abortParsing() }
    }
}
