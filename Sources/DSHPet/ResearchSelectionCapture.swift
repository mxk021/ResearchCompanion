import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog
import Security

enum SelectionCaptureError: String, LocalizedError {
    case pdfCopyUnavailable, pdfServiceUnavailable, permission, empty, unsupported, protectedContent, timedOut, sourceChanged, tooLarge, zoteroTooLarge, zoteroBridge, zoteroUnverified, copyRequired, wpsCopyUnverified, copyUnverified, clipboardReadUnavailable, clipboardNotRestorable, clipboardInterrupted, copyInProgress, richTextUnavailable

    var offersExplicitPaste: Bool {
        switch self {
        case .copyRequired, .wpsCopyUnverified, .permission, .unsupported, .timedOut, .copyUnverified,
             .pdfCopyUnavailable, .pdfServiceUnavailable, .clipboardReadUnavailable, .clipboardNotRestorable,
             .clipboardInterrupted, .copyInProgress, .richTextUnavailable, .zoteroBridge, .zoteroUnverified:
            true
        default:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .pdfCopyUnavailable: return "Safari 未返回本次 PDF 选区。请确认文字仍高亮，或使用「服务 → 选取文字（科研助手）」。"
        case .pdfServiceUnavailable: return "Safari 的文字服务未返回本次 PDF 选区。请确认文字仍高亮，或在 Safari 中手动调用「服务 → 选取文字（科研助手）」。"
        case .richTextUnavailable: return "原应用仅提供了无法可靠还原的富文本。可在原应用使用「选取文字（科研助手）」服务。"
        case .copyRequired: return "此阅读器需要手动复制。请在原窗口按 ⌘C，再点击「粘贴选区」。"
        case .wpsCopyUnverified: return "未取得可核对的 WPS 文字。请在 WPS 中复制选区，再点击「粘贴选区」。"
        case .copyUnverified: return "无法确认此次拷贝来自当前来源窗口。请保持文档在前台，重新选取。"
        case .clipboardReadUnavailable: return "无法读取当前剪贴板以备恢复，尚未复制。可在原窗口使用「服务 → 选取文字（科研助手）」。"
        case .clipboardNotRestorable: return "当前剪贴板格式无法安全保留，尚未复制。可在原窗口使用「服务 → 选取文字（科研助手）」。"
        case .clipboardInterrupted: return "复制期间来源或剪贴板有变化。已保留剪贴板的当前内容。"
        case .copyInProgress: return "上次复制尚未结束。请返回原窗口后再取词。"
        case .permission: return "macOS 未允许当前运行的科研助手读取辅助功能。可在「设置 → 交互与提醒」检查授权，也可在原应用通过「服务 → 选取文字（科研助手）」预览。"
        case .empty: return "没有选区。请在原应用中重新选取文字。"
        case .unsupported: return "当前控件未提供可读选区。可在原应用通过「服务 → 选取文字（科研助手）」预览。"
        case .protectedContent: return "此控件包含受保护内容，无法读取选区。"
        case .timedOut: return "原应用读取选区超时，请返回原窗口再试一次。"
        case .sourceChanged: return "前台应用、窗口或选区已切换。请回到原窗口重新选取。"
        case .tooLarge: return "选区超过本地 1,048,576 个 UTF‑16 字符的读取上限。请分段选取。"
        case .zoteroTooLarge: return "Zotero 当前选区接口最多传回 24,000 个 UTF‑16 字符。请分段选取。"
        case .zoteroBridge: return "Zotero 当前阅读器未提供可核对的实时选区接口。请启用科研助手只读扩展 0.1.5 或更新版本。"
        case .zoteroUnverified: return "无法核对本次 Zotero 选区的原文范围。请在阅读器正文中重新选取，或主动复制后粘贴。"
        }
    }
}

struct ResearchSelectionRead: Sendable {
    enum Clipboard: Sendable {
        case untouched, restored, keptNewer, restoreFailed

        var message: String? {
            switch self {
            case .untouched, .restored: nil
            case .keptNewer: "已保存本次选区。取词期间剪贴板已更新，现有内容保留。"
            case .restoreFailed: "已保存本次选区。无法确认原剪贴板已恢复。"
            }
        }
    }

    let material: ResearchMaterial
    var clipboard: Clipboard = .untouched
}

/// Live debug events contain only timings, process/window IDs, counts and outcome codes.
enum ResearchSelectionTrace {
    private static let log = Logger(subsystem: "com.local.research-companion", category: "selection")
    static func mark(_ request: UUID, _ stage: StaticString, _ number: Int = 0) {
        log.debug("id=\(request.uuidString, privacy: .public) stage=\(String(describing: stage), privacy: .public) n=\(number) uptime=\(ProcessInfo.processInfo.systemUptime)")
    }

    static func failure(_ request: UUID, _ stage: StaticString, _ error: Error) {
        let reason = (error as? SelectionCaptureError)?.rawValue ?? (error is CancellationError ? "cancelled" : "other")
        log.debug("id=\(request.uuidString, privacy: .public) stage=\(String(describing: stage), privacy: .public) failure=\(reason, privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime)")
    }
}

enum ResearchSelectionCapture {
    struct NativeSelection {
        let element: AXUIElement
        let text: String
        let characterRange: NSRange?

        func agrees(with refreshed: Self) -> Bool {
            CFEqual(element, refreshed.element) && characterRange == refreshed.characterRange
                && text.utf8.elementsEqual(refreshed.text.utf8)
        }
    }

    struct Target: Sendable {
        let pid: pid_t
        let bundleID: String
        let source: String
        let windowID: CGWindowID?
        let documentIdentity: String?
        var isSafari: Bool { ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(bundleID) }
        var isWPS: Bool { bundleID == "com.kingsoft.wpsoffice.mac" }
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

    // These hosts can change documents without changing the native window ID.
    private static let documentIdentityHosts: Set<String> = [
        "com.apple.Preview", "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
        "com.kingsoft.wpsoffice.mac", "org.zotero.zotero", "org.zotero.zotero-beta",
    ]

    static func sourceName(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier == "com.apple.Preview" ? "预览" : (app.localizedName ?? "原应用")
    }

    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    static var accessibilityAvailable: Bool { AXIsProcessTrusted() }

    static let identity: (description: String, isAdHoc: Bool) = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        var signing = "签名信息不可用"
        var isAdHoc = false
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let values = info as? [String: Any] {
            isAdHoc = (values[kSecCodeInfoFlags as String] as? NSNumber)
                .map { $0.uint32Value & 0x0002 /* kSecCodeSignatureAdhoc */ != 0 } ?? false
            if isAdHoc {
                signing = "临时签名 · 授权按构建绑定"
            } else if let team = values[kSecCodeInfoTeamIdentifier as String] as? String {
                signing = "签名团队 " + team
            } else { signing = "已签名" }
            if let hash = values[kSecCodeInfoUnique as String] as? Data {
                signing += " · CDHash " + hash.prefix(8).map { String(format: "%02x", $0) }.joined()
            }
        }
        let description = [Bundle.main.bundleURL.path, Bundle.main.bundleIdentifier ?? "无应用标识",
                           "PID " + String(ProcessInfo.processInfo.processIdentifier), signing].joined(separator: " · ")
        return (description, isAdHoc)
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
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview",
           let address = ResearchBrowserNavigation.safariAddress(window), let location = safariLocation(address) {
            // One Safari window can hold different PDF tabs with the same title.
            // The native address is stable across title and selection updates.
            return "safari-address\n" + location.string
        }
        let document = CopyDocument.value(window, kAXDocumentAttribute)
        let locator = (document as? URL)?.absoluteString ?? (document as? String) ?? ""
        let title = CopyDocument.value(window, kAXTitleAttribute) as? String ?? ""
        return locator.isEmpty && title.isEmpty ? nil : locator + "\n" + title
    }

    static func safariLocation(_ address: String) -> (components: URLComponents, string: String)? {
        let location = address.contains("://") ? address : "//" + address
        guard let components = URLComponents(string: location), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.scheme.map({ ["https", "http"].contains($0.lowercased()) }) ?? true else { return nil }
        // Safari may omit the scheme from its display; do not guess a source URL.
        return (components, location)
    }

    static func target(_ app: NSRunningApplication) -> Target? {
        guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let identifier = app.bundleIdentifier else { return nil }
        return Target(pid: app.processIdentifier, bundleID: identifier, source: sourceName(app),
                      windowID: frontWindowID(app.processIdentifier),
                      documentIdentity: documentIdentityHosts.contains(identifier) && accessibilityAvailable
                        ? windowIdentity(app.processIdentifier) : nil)
    }

    /// Services provides a private pasteboard without a caller or document ID.
    static func serviceSelectionText(from board: NSPasteboard) throws -> String {
        guard ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(board.name),
              let text = board.string(forType: .string) ?? board.string(forType: .init("NSStringPboardType")) else {
            throw SelectionCaptureError.empty
        }
        return text
    }

    /// A validated native document canvas for a scoped Copy action. Reject
    /// dialogs and editable controls when direct AX selection was unavailable.
    struct CopyDocument {
        let target: Target
        let window: AXUIElement
        let focus: AXUIElement?
        let foregroundOwner: pid_t?
        let title: String
        let webURL: URL?
        let isSafariPDF: Bool
        private let originalAddress: String?

        @MainActor func matchesInterruptedPDF(_ item: NSPasteboardItem) -> Bool {
            guard isSafariPDF, target.hasSameDocument() else { return false }
            if let webURL { return ResearchDocumentCopy.matchesPDFOrigin(item, url: webURL) }
            guard let originalAddress, ResearchBrowserNavigation.safariAddress(window) == originalAddress,
                  let components = ResearchSelectionCapture.safariLocation(originalAddress)?.components,
                  !components.path.isEmpty, components.path != "/" else { return false }
            // Safari can omit the scheme from its display. Compare only against
            // the native origin carried by this copy; never invent a source URL.
            return (components.scheme.map { [$0] } ?? ["https", "http"]).contains { scheme in
                var candidate = components
                candidate.scheme = scheme
                return ResearchDocumentCopy.matchesPDFOrigin(item, url: candidate.url)
            }
        }

        fileprivate static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(element, 0.15)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        fileprivate static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let result = value(parent, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }
        static func isEnabled(_ control: AXUIElement) -> Bool {
            value(control, kAXEnabledAttribute) as? Bool == true
        }
        // A top-level Safari PDF exposes the plug-in itself. An HTML document
        // containing only a PDF can wrap exactly that plug-in in a web area and
        // an application group. Do not choose among sibling embeds or controls.
        private static func isPDFSurface(_ surface: AXUIElement) -> Bool {
            var node = surface
            for _ in 0..<3 {
                let subrole = value(node, kAXSubroleAttribute) as? String
                if subrole == "AXPDFPluginSubrole" { return true }
                var count = CFIndex(0)
                guard subrole == "AXApplicationGroup" || value(node, kAXRoleAttribute) as? String == "AXWebArea",
                      AXUIElementGetAttributeValueCount(node, kAXChildrenAttribute as CFString, &count) == .success, count == 1,
                      let children = value(node, kAXChildrenAttribute) as? [AXUIElement], children.count == 1 else { return false }
                node = children[0]
            }
            return false
        }

        init?(_ target: Target, whileForegroundOwner ownerPID: pid_t? = nil) {
            guard target.isSafari || target.isWPS, isBound(target, whileForegroundOwner: ownerPID),
                  target.documentIdentity != nil, accessibilityAvailable else { return nil }
            let app = AXUIElementCreateApplication(target.pid)
            guard let window = Self.element(app, kAXFocusedWindowAttribute),
                  let name = Self.value(window, kAXTitleAttribute) as? String, !name.isEmpty else { return nil }
            let focus = Self.element(app, kAXFocusedUIElementAttribute)
            if target.isWPS {
                let locator = Self.value(window, kAXDocumentAttribute)
                let url = (locator as? URL) ?? (locator as? String).flatMap(URL.init(string:))
                let isPDF = url?.pathExtension.lowercased() == "pdf" ||
                    name.lowercased().range(of: #"\.pdf(?:$|\s)"#, options: .regularExpression) != nil
                guard isPDF else { return nil }
                guard let focus, let role = Self.value(focus, kAXRoleAttribute) as? String,
                      ["AXSplitGroup", "AXScrollArea", "AXLayoutArea", "AXPDFArea"].contains(role),
                      Self.value(focus, kAXSubroleAttribute) as? String != "AXSecureTextField",
                      Self.value(focus, "AXProtectedContent") as? Bool != true else { return nil }
                isSafariPDF = false
                webURL = nil
                originalAddress = nil
            } else {
                guard Self.value(window, kAXSubroleAttribute) as? String == "AXStandardWindow",
                      let surface = try? ResearchSelectionCapture.safariDocument(in: target, whileForegroundOwner: ownerPID) else { return nil }
                isSafariPDF = Self.isPDFSurface(surface)
                let url = ResearchSelectionCapture.selectionURL(Self.value(surface, kAXURLAttribute)
                    ?? Self.value(window, kAXDocumentAttribute))
                webURL = url
                originalAddress = isSafariPDF && url == nil ? ResearchBrowserNavigation.safariAddress(window) : nil
            }
            self.target = target
            self.focus = focus
            self.foregroundOwner = ownerPID
            self.window = window
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
                  })
            else { throw SelectionCaptureError.unsupported }
            return copy
        }

        func pdfSelectionForFindEnabled(near copy: AXUIElement) -> Bool? {
            // WebKit's Use Selection for Find validates the selection without
            // requiring permission to copy. Only inspect the native command.
            guard let edit = Self.element(copy, kAXParentAttribute),
                  let commands = Self.value(edit, kAXChildrenAttribute) as? [AXUIElement],
                  let find = commands.first(where: {
                      guard let title = Self.value($0, kAXTitleAttribute) as? String else { return false }
                      return ["Find", "查找", "尋找", "搜索", "搜尋"].contains(title)
                  }),
                  let menu = (Self.value(find, kAXChildrenAttribute) as? [AXUIElement])?.first,
                  let items = Self.value(menu, kAXChildrenAttribute) as? [AXUIElement],
                  let useSelection = items.first(where: {
                      (Self.value($0, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == "E" &&
                          (Self.value($0, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0
                  }) else { return nil }
            return Self.value(useSelection, kAXEnabledAttribute) as? Bool
        }

        func safariServiceCommand(copy: AXUIElement) -> AXUIElement? {
            // The PDF viewer's native Copy validation is the permission gate.
            // Do not use a service to read a PDF whose Copy action is unavailable.
            guard isSafariPDF, isCurrent(), Self.value(copy, kAXEnabledAttribute) as? Bool == true,
                  let bar = Self.element(AXUIElementCreateApplication(target.pid), kAXMenuBarAttribute),
                  let top = Self.value(bar, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            func children(_ item: AXUIElement) -> [AXUIElement] {
                Self.value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
            }
            for menu in top.prefix(3) {
                let title = Self.value(menu, kAXTitleAttribute) as? String ?? ""
                guard title == target.source || title.hasPrefix("Safari") else { continue }
                for group in children(menu).flatMap(children) {
                    let title = Self.value(group, kAXTitleAttribute) as? String ?? ""
                    guard ["Services", "服务", "服務"].contains(title),
                          Self.value(group, kAXEnabledAttribute) as? Bool == true else { continue }
                    return children(group).flatMap(children).first { item in
                        Self.value(item, kAXRoleAttribute) as? String == kAXMenuItemRole &&
                            Self.value(item, kAXTitleAttribute) as? String == "选取文字（科研助手）" &&
                            Self.value(item, kAXEnabledAttribute) as? Bool == true
                    }
                }
            }
            return nil
        }
        func isCurrent() -> Bool {
            guard isBound(target, whileForegroundOwner: foregroundOwner) else { return false }
            let app = AXUIElementCreateApplication(target.pid)
            guard let current = Self.element(app, kAXFocusedWindowAttribute), CFEqual(window, current) else { return false }
            switch (focus, Self.element(app, kAXFocusedUIElementAttribute)) {
            case (nil, nil): return true
            case let (original?, now?): return CFEqual(original, now)
            default: return false
            }
        }
        @MainActor func material(with selected: String, from item: NSPasteboardItem) throws -> ResearchMaterial {
            var sourceURL = webURL
            if sourceURL == nil, let originalAddress, ResearchBrowserNavigation.safariAddress(window) == originalAddress,
               let candidate = ResearchSelectionCapture.safariLocation(originalAddress)?.components.url,
               ResearchDocumentCopy.matchesPDFOrigin(item, url: candidate) {
                sourceURL = candidate
            }
            return try ResearchSelectionCapture.exactSelection(selected, source: target.source, title: title, webURL: sourceURL)
        }

        @MainActor func serviceMaterial(_ selected: String) throws -> ResearchMaterial {
            guard target.hasSameDocument(), originalAddress.map({ ResearchBrowserNavigation.safariAddress(window) == $0 }) ?? true else {
                throw SelectionCaptureError.sourceChanged
            }
            // A Services pasteboard only carries text. Bind a URL when Safari
            // independently supplied one, retaining no inferred scheme.
            let address = originalAddress.flatMap { ResearchSelectionCapture.safariLocation($0)?.components }
            let verifiedURL = webURL ?? address.flatMap { $0.scheme == nil ? nil : $0.url }
            return try ResearchSelectionCapture.exactSelection(selected, source: target.source, title: title, webURL: verifiedURL)
        }
    }

    private static func selectionURL(_ value: CFTypeRef?) -> URL? {
        guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return nil }
        return ResearchSourceLocation.webURL(url)
    }

    static func exactSelection(_ text: String, source: String, title: String, webURL: URL? = nil) throws -> ResearchMaterial {
        guard text.utf16.count <= ResearchMaterial.localSelectionLimit else { throw SelectionCaptureError.tooLarge }
        guard ResearchMaterial.hasReadableText(text) else { throw SelectionCaptureError.empty }
        var link = webURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        link?.query = nil
        link?.fragment = nil
        var result = try ResearchMaterial.selection(text, source: source, title: title, url: link?.string.flatMap {
            $0.utf16.count <= 2048 ? $0 : nil
        })
        result.localWebURL = webURL?.absoluteString
        return result
    }

    static func clipboardSelection(_ text: String, source: String, title: String) throws -> ResearchMaterial {
        var material = try exactSelection(text, source: source, title: title + " · 出处未核验")
        material.verifiedExcerpts = nil
        material.scope = "当前选区 · 出处未独立核验"
        return material
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

    static func current(_ target: Target, requestID: UUID,
                        safariService: @MainActor (CopyDocument, AXUIElement) async throws -> ResearchSelectionRead?) async throws -> ResearchSelectionRead {
        guard target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
        if target.isZotero {
            let material = try await ResearchZoteroSelection.read(requestID: requestID)
            try Task.checkCancellation()
            guard target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
            return .init(material: material)
        }
        if !accessibilityAvailable { throw SelectionCaptureError.permission }
        ResearchSelectionTrace.mark(requestID, "foreground-ax-start")
        do {
            let material = try await read(target, whileForegroundOwner: nil)
            ResearchSelectionTrace.mark(requestID, "foreground-ax-read")
            return .init(material: material)
        }
        catch let failure as SelectionCaptureError where [.unsupported, .empty, .timedOut].contains(failure) {
            ResearchSelectionTrace.failure(requestID, "foreground-ax-unavailable", failure)
            if target.isWPS {
                guard let document = CopyDocument(target) else { throw SelectionCaptureError.copyRequired }
                let copy = try document.copyCommand()
                return try await ResearchDocumentCopy.read(document, copy: copy, requestID: requestID)
            }
            guard target.isSafari else { throw failure }
            guard let document = CopyDocument(target) else {
                if failure == .unsupported { throw SelectionCaptureError.copyRequired }
                throw failure
            }
            do {
                let copy = try document.copyCommand()
                if document.isSafariPDF, let result = try await safariService(document, copy) { return result }
                return try await ResearchDocumentCopy.read(document, copy: copy, requestID: requestID)
            } catch let error as SelectionCaptureError where [.unsupported, .timedOut, .copyUnverified, .richTextUnavailable].contains(error) {
                throw SelectionCaptureError.copyRequired
            }
        }
    }

    /// A direct read never opens a menu, copies text, or activates the source.
    /// Zotero's local reader intentionally requires its selected tab to have focus.
    static func readWithoutActivation(_ target: Target, ownerPID: pid_t) async throws -> ResearchMaterial {
        guard !target.isZotero else { throw SelectionCaptureError.unsupported }
        guard accessibilityAvailable else { throw SelectionCaptureError.permission }
        return try await read(target, whileForegroundOwner: ownerPID)
    }

    /// WPS can dispatch its native menu action to its bound window without
    /// becoming frontmost. Use the foreground fallback only before dispatch.
    static func copyWPSWithoutActivation(_ target: Target, ownerPID: pid_t, requestID: UUID) async throws -> ResearchSelectionRead? {
        guard target.isWPS else { return nil }
        try Task.checkCancellation()
        guard let document = CopyDocument(target, whileForegroundOwner: ownerPID),
              let copy = try? document.copyCommand(), CopyDocument.isEnabled(copy) else { return nil }
        ResearchSelectionTrace.mark(requestID, "wps-background-copy")
        return try await ResearchDocumentCopy.read(document, copy: copy, requestID: requestID)
    }

    private static func isBound(_ target: Target, whileForegroundOwner ownerPID: pid_t?) -> Bool {
        guard let ownerPID else { return target.isFrontmost() }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID && target.hasSameDocument()
    }

    /// Inspect only document containers in the current Safari window. PDFKit can
    /// expose a document tree while reporting no focused accessibility element.
    /// Never traverse editable controls, other tabs, sheets, or page text runs.
    private static func safariDocument(in target: Target, whileForegroundOwner ownerPID: pid_t? = nil) throws -> AXUIElement? {
        guard target.isSafari, isBound(target, whileForegroundOwner: ownerPID) else { return nil }
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

    private static func read(_ target: Target, whileForegroundOwner ownerPID: pid_t?) async throws -> ResearchMaterial {
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

        guard isBound(target, whileForegroundOwner: ownerPID) else { throw SelectionCaptureError.sourceChanged }
        guard let window = try element(application, kAXFocusedWindowAttribute),
              let focused = try element(application, kAXFocusedUIElementAttribute) ?? safariDocument(in: target, whileForegroundOwner: ownerPID) else {
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
        func characterRange(_ value: CFTypeRef?) -> NSRange? {
            guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range),
                  range.location >= 0, range.length >= 0 else { return nil }
            return NSRange(location: range.location, length: range.length)
        }
        func selection() throws -> NativeSelection {
            for node in nodes {
                if let text = try attribute(node, kAXSelectedTextAttribute) as? String {
                    if !text.isEmpty {
                        let range = characterRange(CopyDocument.value(node, kAXSelectedTextRangeAttribute))
                        return .init(element: node, text: text, characterRange: range)
                    }
                    selectionAttributeAvailable = true
                }
                if let value = try attribute(node, kAXSelectedTextRangeAttribute), let range = characterRange(value) {
                    if range.length == 0 { selectionAttributeAvailable = true }
                    if range.length > ResearchMaterial.localSelectionLimit { throw SelectionCaptureError.tooLarge }
                    if range.length > 0,
                       let text = try attribute(node, kAXStringForRangeParameterizedAttribute, parameter: value) as? String, !text.isEmpty {
                        return .init(element: node, text: text, characterRange: range)
                    }
                }
                if let marker = try attribute(node, "AXSelectedTextMarkerRange"),
                   let text = try attribute(node, "AXStringForTextMarkerRange", parameter: marker) as? String {
                    if !text.isEmpty { return .init(element: node, text: text, characterRange: nil) }
                    selectionAttributeAvailable = true
                }
            }
            throw selectionAttributeAvailable ? SelectionCaptureError.empty : .unsupported
        }
        if target.isSafari, webArea == nil,
           !nodes.contains(where: { ["AXTextField","AXTextArea","AXComboBox","AXSearchField"].contains(CopyDocument.value($0, kAXRoleAttribute) as? String ?? "") }),
           let document = try safariDocument(in: target, whileForegroundOwner: ownerPID), CopyDocument.value(document, kAXRoleAttribute) as? String == "AXWebArea" {
            webArea = document
            if !nodes.contains(where: { CFEqual($0, document) }) { nodes.append(document) }
        }
        func localPDFURL() -> URL? {
            let document = CopyDocument.value(window, kAXDocumentAttribute)
            guard let url = (document as? URL) ?? (document as? String).flatMap(URL.init(string:)),
                  url.isFileURL, url.path.hasPrefix("/"), url.pathExtension.lowercased() == "pdf",
                  url.query == nil, url.fragment == nil else { return nil }
            return url
        }
        let documentURL = localPDFURL()
        let original = try selection()
        let title = (try attribute(window, kAXTitleAttribute) as? String).flatMap {
            $0.isEmpty ? nil : ResearchMaterial.bounded($0, limit: 512)
        } ?? target.source + "选区"
        func webURL() throws -> URL? {
            let url = try selectionURL(webArea.flatMap { try attribute($0, kAXURLAttribute) })
            if url == nil, target.isSafari { return try selectionURL(attribute(window, kAXDocumentAttribute)) }
            return url
        }
        let originalURL = try webURL()
        let material = try exactSelection(original.text, source: target.source, title: title, webURL: originalURL)
        guard isBound(target, whileForegroundOwner: ownerPID), let lastWindow = try element(application, kAXFocusedWindowAttribute),
              CFEqual(lastWindow, window), let lastFocus = try element(application, kAXFocusedUIElementAttribute) ?? safariDocument(in: target, whileForegroundOwner: ownerPID),
              CFEqual(lastFocus, focused) else { throw SelectionCaptureError.sourceChanged }
        let refreshed: NativeSelection
        do { refreshed = try selection() }
        catch let failure as SelectionCaptureError where failure == .empty || failure == .unsupported {
            throw SelectionCaptureError.sourceChanged
        }
        guard original.agrees(with: refreshed), try webURL() == originalURL,
              localPDFURL() == documentURL else { throw SelectionCaptureError.sourceChanged }
        guard let documentURL, originalURL == nil else { return material }
        let located = try await ResearchSourceLocation.locatePDFSelection(material, at: documentURL)
        try Task.checkCancellation()
        guard isBound(target, whileForegroundOwner: ownerPID), localPDFURL() == documentURL else {
            throw SelectionCaptureError.sourceChanged
        }
        return located
    }
}

/// Copy acts once on the verified native document. Direct accessibility reads
/// are attempted first, before consulting the shared clipboard at all.
@MainActor
enum ResearchDocumentCopy {
    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
    private static let legacyText = NSPasteboard.PasteboardType("NSStringPboardType")
    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"), .fileURL,
    ]
    private static var clipboardOwner: UUID?
    private static var clipboardQuietUntil: ContinuousClock.Instant?

    // Safari's PDF plug-in can retain a highlighted selection while its Edit
    // menu still reports Copy disabled after reactivation. Dispatch its real
    // keyboard equivalent to this process only. Nonstandard menu shortcuts and
    // other applications continue to use the enabled accessibility command.
    private static func pdfCopyKey(for command: AXUIElement) -> CGKeyCode? {
        guard ResearchSelectionCapture.CopyDocument.value(command, kAXMenuItemCmdCharAttribute) as? String == "C",
              (ResearchSelectionCapture.CopyDocument.value(command, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0 else { return nil }
        if let code = ResearchSelectionCapture.CopyDocument.value(command, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber,
           let key = CGKeyCode(exactly: code.intValue) { return key }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()) else { return nil }
        defer { withExtendedLifetime(source) {} }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboard = UInt32(LMGetKbdType())
        for key in UInt16(0)..<128 {
            var state: UInt32 = 0, length = 0
            var letters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), UInt32(cmdKey >> 8), keyboard,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &state, letters.count, &length, &letters)
            if status == noErr, length == 1, letters[0] == 99 || letters[0] == 67 { return key }
        }
        return nil
    }

    // WebKit's native PDF copy includes a version-1 PasteboardCustomData
    // record with the security origin and empty custom-type collections.
    // It identifies an origin, never a tab or writer. An unfamiliar format,
    // opaque/local origin, or missing rich representation provides no proof.
    static func matchesPDFOrigin(_ item: NSPasteboardItem, url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased(), !host.isEmpty,
              [.string, .rtf, .html].allSatisfy(item.types.contains),
              let data = item.data(forType: .init("com.apple.WebKit.custom-pasteboard-data")) else { return false }
        let port = url.port.flatMap { $0 == (scheme == "https" ? 443 : 80) ? nil : ":" + String($0) } ?? ""
        let origin = Array((scheme + "://" + host + port).utf8)
        guard origin.count <= 512, origin.allSatisfy({ $0 < 128 }), data.count == origin.count + 25 else { return false }
        var expected: [UInt8] = [1, 0, 0, 0]
        withUnsafeBytes(of: UInt32(origin.count).littleEndian) { expected.append(contentsOf: $0) }
        expected.append(1) // WebKit's 8-bit string encoding.
        expected.append(contentsOf: origin)
        expected.append(contentsOf: repeatElement(0, count: 16))
        return data.elementsEqual(expected)
    }

    /// Listen for our one marked command at the target process; do not request
    /// any additional permissions or record any other event's content.
    private final class CopyReceipt {
        let token: Int64
        var received = false
        var tap: CFMachPort?
        init(pid: pid_t, token: Int64) {
            self.token = token
            guard CGPreflightListenEventAccess() else { return }
            tap = CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: { _, _, event, ptr in
                    if let ptr {
                        let receipt = Unmanaged<CopyReceipt>.fromOpaque(ptr).takeUnretainedValue()
                        if event.getIntegerValueField(.eventSourceUserData) == receipt.token,
                           event.getIntegerValueField(.eventSourceUnixProcessID) == getpid() { receipt.received = true }
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap {
                let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        deinit { if let tap { CFMachPortInvalidate(tap) } }
    }

    private static func isFinderFocusClick(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let command = event.cgEvent else { return false }
        let point = command.location
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        // The event PID may be unavailable during activation. Confirm the
        // foremost window at that point and exclude menus, sheets and toolbars.
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.contains(point) else { continue }
            guard layer == 0, point.y > frame.minY + 48,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.finder" else { return false }
            let target = command.getIntegerValueField(.eventTargetUnixProcessID)
            return target == 0 || target == Int64(owner)
        }
        return false
    }

    private static func pressCopy(_ copy: AXUIElement, requestID: UUID) throws -> AXError {
        let action = AXUIElementPerformAction(copy, kAXPressAction as CFString)
        ResearchSelectionTrace.mark(requestID, "menu-copy-result", Int(action.rawValue))
        guard action == .success || action == .cannotComplete else { throw SelectionCaptureError.unsupported }
        return action
    }

    private struct WPSCopySample: Equatable {
        let revision: Int
        let types: [[NSPasteboard.PasteboardType]]
        let text: Data?
        let source: String?

        @MainActor init?(_ board: NSPasteboard, after initial: Int) {
            let revision = board.changeCount
            guard revision != initial else { return nil }
            let items = board.pasteboardItems ?? []
            types = items.map(\.types)
            let item = items.count == 1 && privateTypes.isDisjoint(with: types[0]) ? items.first : nil
            let plain = item?.string(forType: .string) ?? item?.string(forType: legacyText)
            text = plain.flatMap { ResearchMaterial.hasReadableText($0) ? Data($0.utf8) : nil }
            source = item?.string(forType: sourceType)
            guard board.changeCount == revision else { return nil }
            self.revision = revision
        }
    }

    private static func readWPS(_ document: ResearchSelectionCapture.CopyDocument, copy: AXUIElement,
                                board: NSPasteboard, requestID: UUID) async throws -> ResearchSelectionRead {
        guard ResearchSelectionCapture.CopyDocument.isEnabled(copy) else { throw SelectionCaptureError.wpsCopyUnverified }
        var interrupted = false
        let events: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: events,
            handler: { _ in interrupted = true }
        ) else { throw SelectionCaptureError.wpsCopyUnverified }
        defer { NSEvent.removeMonitor(monitor) }
        let localMonitor: Any?
        if document.foregroundOwner != nil {
            // The chat remains key. The global monitor cannot see Copy or any
            // other input dispatched to our own application during this read.
            guard let monitor = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
                interrupted = true
                return event
            }) else { throw SelectionCaptureError.wpsCopyUnverified }
            localMonitor = monitor
        } else { localMonitor = nil }
        defer { if let localMonitor { NSEvent.removeMonitor(localMonitor) } }
        let initial = board.changeCount
        try Task.checkCancellation()
        guard document.isCurrent(), board.changeCount == initial, !interrupted else { throw SelectionCaptureError.sourceChanged }
        _ = try pressCopy(copy, requestID: requestID)
        let deadline = ContinuousClock.now + .milliseconds(1200)
        var settled = false
        defer {
            // A native Copy already sent can still arrive after cancellation.
            if !settled { clipboardQuietUntil = deadline }
        }
        var previous: WPSCopySample?
        var firstChange: ContinuousClock.Instant?
        var lastChange = ContinuousClock.now
        repeat {
            try Task.checkCancellation()
            guard document.isCurrent(), !interrupted else { throw SelectionCaptureError.sourceChanged }
            let sample = WPSCopySample(board, after: initial)
            let now = ContinuousClock.now
            if let sample {
                if firstChange == nil { firstChange = now }
                if sample != previous {
                    if let firstChange, firstChange.duration(to: now) > .milliseconds(400) {
                        throw SelectionCaptureError.wpsCopyUnverified
                    }
                    lastChange = now
                } else if lastChange.duration(to: now) >= .milliseconds(120), let text = sample.text {
                    // Require both observed WPS PDF representations. The formats alone do not identify the writer.
                    let wpsTypes: Set<NSPasteboard.PasteboardType> = [
                        .init("com.trolltech.anymime.text--plain"), .init("com.trolltech.anymime.text--html")
                    ]
                    guard let types = sample.types.first, wpsTypes.isSubset(of: types),
                          sample.source.map({ $0 == document.target.bundleID }) ?? true else {
                        throw SelectionCaptureError.wpsCopyUnverified
                    }
                    let selected = String(decoding: text, as: UTF8.self)
                    let material = try ResearchSelectionCapture.clipboardSelection(selected, source: document.target.source,
                        title: document.title)
                    guard !interrupted, document.isCurrent(), WPSCopySample(board, after: initial) == sample else {
                        throw SelectionCaptureError.clipboardInterrupted
                    }
                    settled = true
                    ResearchSelectionTrace.mark(requestID, "wps-copy-captured", sample.revision - initial)
                    return .init(material: material)
                }
            }
            previous = sample
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw SelectionCaptureError.wpsCopyUnverified
    }

    static func read(_ document: ResearchSelectionCapture.CopyDocument, copy: AXUIElement, requestID: UUID) async throws -> ResearchSelectionRead {
        try Task.checkCancellation()
        // Copy alone can be disabled temporarily or by the PDF's permissions.
        // Require both commands to agree before declaring the selection empty.
        if document.isSafariPDF, ResearchSelectionCapture.CopyDocument.value(copy, kAXEnabledAttribute) as? Bool == false,
           document.pdfSelectionForFindEnabled(near: copy) == false {
            try Task.checkCancellation()
            guard document.isCurrent() else { throw SelectionCaptureError.sourceChanged }
            ResearchSelectionTrace.mark(requestID, "safari-pdf-selection-empty")
            throw SelectionCaptureError.empty
        }

        // A cancelled caller stops publishing results immediately. Its posted
        // Copy still owns cleanup until the bounded observation has finished.
        let waitUntil = ContinuousClock.now + .seconds(2)
        while clipboardOwner != nil || (clipboardQuietUntil.map { ContinuousClock.now < $0 } ?? false) {
            guard ContinuousClock.now < waitUntil else { throw SelectionCaptureError.copyInProgress }
            try await Task.sleep(for: .milliseconds(15))
        }
        try Task.checkCancellation()
        clipboardOwner = requestID
        defer { clipboardOwner = nil }
        let board = NSPasteboard.general
        if document.target.isWPS {
            do {
                return try await readWPS(document, copy: copy, board: board, requestID: requestID)
            } catch let failure as SelectionCaptureError where failure.offersExplicitPaste {
                // Establish the manual-paste baseline after the outstanding WPS write window.
                if let quietUntil = clipboardQuietUntil, ContinuousClock.now < quietUntil {
                    try await Task.sleep(until: quietUntil, clock: .continuous)
                }
                throw failure
            }
        }
        let enabled = ResearchSelectionCapture.CopyDocument.value(copy, kAXEnabledAttribute) as? Bool
        let key = document.isSafariPDF ? pdfCopyKey(for: copy) : nil
        ResearchSelectionTrace.mark(requestID, "copy-menu-enabled", enabled == true ? 1 : 0)
        guard key != nil || enabled == true else {
            throw enabled == false ? SelectionCaptureError.empty : .unsupported
        }
        let eventID = Int64.random(in: 1...Int64.max)
        var otherInput = false
        var possibleUserCopy = false
        guard document.isCurrent(), let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown],
                        handler: { event in
                            if event.type == .keyDown, let key, event.keyCode == key,
                               event.cgEvent?.getIntegerValueField(.eventSourceUserData) == eventID { return }
                            otherInput = true
                            // A plain switch via Command-Tab or a click on Finder is
                            // distinct from a second Copy. Unknown input always wins.
                            if event.type == .keyDown, event.keyCode == kVK_Tab,
                               event.modifierFlags.intersection([.command, .control, .option]) == .command { return }
                            if Self.isFinderFocusClick(event) { return }
                            possibleUserCopy = true
                        }) else { throw SelectionCaptureError.copyUnverified }
        defer { NSEvent.removeMonitor(monitor) }
        ResearchSelectionTrace.mark(requestID, "clipboard-preflight-start")
        let worker = Task.detached(priority: .userInitiated) {
            try ResearchClipboardSnapshot.capture(.general, requestID: requestID)
        }
        let backup = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        let initial = backup.revision
        ResearchSelectionTrace.mark(requestID, "clipboard-snapshot-ready")
        let restoration = try backup.prepareRestoration()
        ResearchSelectionTrace.mark(requestID, "clipboard-restoration-staged")
        try Task.checkCancellation()
        guard !otherInput, document.isCurrent(), board.changeCount == initial else { throw SelectionCaptureError.sourceChanged }
        let receipt = key != nil ? CopyReceipt(pid: document.target.pid, token: eventID) : nil
        let menuReceipt: AXError?
        if let key {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { throw SelectionCaptureError.unsupported }
            for event in [down, up] {
                event.flags = .maskCommand
                event.setIntegerValueField(.eventSourceUserData, value: eventID)
                event.postToPid(document.target.pid)
            }
            ResearchSelectionTrace.mark(requestID, "pdf-copy-posted", Int(document.target.pid))
            menuReceipt = nil // Posting is not a receipt. Require the bound new write below.
        } else {
            menuReceipt = try pressCopy(copy, requestID: requestID)
        }

        // Copy may publish asynchronously. After issuing it, finish the bounded
        // ownership check even when capture has been cancelled. Cancellation
        // still prevents accepting text or bringing a window back.
        let revision = await Task { @MainActor in
            let limit = ContinuousClock.now + .seconds(1)
            while true {
                let observed = board.changeCount
                if observed != initial {
                    if observed != initial + 1 || board.pasteboardItems?.isEmpty == false {
                        return observed
                    }
                }
                if ContinuousClock.now >= limit { return initial }
                try? await Task.sleep(for: .milliseconds(15))
            }
        }.value
        ResearchSelectionTrace.mark(requestID, "board-revision-delta", revision - initial)
        if let receipt {
            ResearchSelectionTrace.mark(requestID, "pdf-copy-receipt", receipt.received ? 1 : (receipt.tap == nil ? -1 : 0))
        }
        if revision == initial {
            if Task.isCancelled || otherInput || !document.isCurrent() { throw SelectionCaptureError.sourceChanged }
            throw key != nil ? SelectionCaptureError.pdfCopyUnavailable : .timedOut
        }
        guard revision == initial + 1, board.changeCount == revision,
              let items = board.pasteboardItems, items.count == 1,
              let types = board.types, privateTypes.isDisjoint(with: types) else { throw SelectionCaptureError.clipboardInterrupted }
        let item = items[0]
        let declared = item.string(forType: sourceType)
        let stillBound = document.isCurrent()
        let uninterrupted = !otherInput && stillBound
        // Only undo an interrupted PDF copy when the command reached this
        // specific process, the original window/document still exists, and the
        // one new item has that PDF web origin. A user Copy or newer revision
        // wins even if it comes from the same application or the same origin.
        let interruptedPDF = !uninterrupted && !possibleUserCopy && receipt?.received == true &&
            document.matchesInterruptedPDF(item)
        if let declared, declared != document.target.bundleID { throw SelectionCaptureError.copyUnverified }
        guard uninterrupted || interruptedPDF || (declared != nil && !otherInput) else {
            throw stillBound && !otherInput ? SelectionCaptureError.copyUnverified : SelectionCaptureError.sourceChanged
        }
        if interruptedPDF { ResearchSelectionTrace.mark(requestID, "interrupted-pdf-copy-identified") }
        let selection = Result {
            try Task.checkCancellation()
            guard uninterrupted else { throw SelectionCaptureError.sourceChanged }
            if let menuReceipt, menuReceipt != .success { throw SelectionCaptureError.timedOut }
            guard let selected = try text(from: item) else { throw SelectionCaptureError.copyUnverified }
            let material = try document.material(with: selected, from: item)
            // Seal this independent snapshot only while the verified revision
            // is still installed. A later board change cannot invalidate it.
            guard !Task.isCancelled, document.isCurrent(), board.changeCount == revision else {
                throw SelectionCaptureError.clipboardInterrupted
            }
            ResearchSelectionTrace.mark(requestID, "selection-verified", selected.utf16.count)
            return material
        }
        // Restore a verified Copy without overwriting an intervening write. A
        // source change may prevent returning text while recovery is still safe.
        return try finish(selection, restoring: restoration.apply(to: board, replacing: revision), requestID: requestID)
    }

    /// Board ownership and material ownership are separate. A failed or
    /// skipped restoration never publishes unverified text, and a verified
    /// selection remains available when there is an independent failure.
    static func finish(_ selection: Result<ResearchMaterial, Error>, restoring outcome: ResearchClipboardSnapshot.Restoration.Outcome,
                       requestID: UUID) throws -> ResearchSelectionRead {
        let clipboard: ResearchSelectionRead.Clipboard
        switch outcome {
        case .restored:
            ResearchSelectionTrace.mark(requestID, "clipboard-restored")
            clipboard = .restored
        case .newerWrite:
            ResearchSelectionTrace.mark(requestID, "clipboard-kept-newer")
            clipboard = .keptNewer
        case .failed:
            ResearchSelectionTrace.mark(requestID, "clipboard-restore-failed")
            clipboard = .restoreFailed
        }
        return .init(material: try selection.get(), clipboard: clipboard)
    }

    static func readExplicitPaste(_ board: NSPasteboard) throws -> String {
        let revision = board.changeCount
        guard let items = board.pasteboardItems, items.count == 1,
              privateTypes.isDisjoint(with: board.types ?? []),
              let value = try text(from: items[0]), board.changeCount == revision else {
            throw SelectionCaptureError.copyUnverified
        }
        return value
    }

    static func text(from item: NSPasteboardItem) throws -> String? {
        if let plain = item.string(forType: .string) ?? item.string(forType: legacyText), !plain.isEmpty { return plain }
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
