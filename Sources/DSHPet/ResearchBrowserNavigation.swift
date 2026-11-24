import AppKit
import ApplicationServices
import OSLog

/// Uses native Safari accessibility when an open destination can be proven by URL.
/// A title, a shortened displayed address, or a PDF with a different fragment do not match.
enum ResearchBrowserNavigation {
    private static let safari = "com.apple.Safari"
    private static let preview = "com.apple.SafariTechnologyPreview"
    private static let log = Logger(subsystem: "com.local.research-companion", category: "source-navigation")

    private struct Match: @unchecked Sendable {
        enum Location {
            case window
            case document
            case tab(AXUIElement)
        }

        let window: AXUIElement
        let location: Location
    }

    @MainActor
    static func revealOpenPage(_ url: URL, source: String?, ifCurrent: @escaping () -> Bool) async -> Bool {
        guard AXIsProcessTrusted(), let bundleID = safariBundle(for: url, source: source),
              let browser = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !browser.isTerminated else { return false }
        let start = ProcessInfo.processInfo.systemUptime
        let pid = browser.processIdentifier
        let worker = Task.detached(priority: .userInitiated) { find(url, in: pid) }
        let match = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled, ifCurrent(), let match, !browser.isTerminated else { return false }
        // Revalidate after the background lookup. The tab may have navigated while we waited.
        let recheck = Lookup(timeout: 0.04, deadline: ProcessInfo.processInfo.systemUptime + 0.08)
        switch match.location {
        case .tab(let tab):
            guard recheck.matches(tab, url: url, attributes: [kAXURLAttribute]) else { return false }
        case .window:
            guard recheck.matchesWindow(match.window, url: url) else { return false }
        case .document:
            let root = AXUIElementCreateApplication(pid)
            guard let focused = recheck.element(root, kAXFocusedWindowAttribute), CFEqual(focused, match.window),
                  recheck.matchesCurrentDocument(focused, url: url) else { return false }
        }
        NSApp.yieldActivation(to: browser)
        guard browser.isActive || browser.activate(options: []) else { return false }
        if recheck.value(match.window, kAXMinimizedAttribute) as? Bool == true {
            _ = AXUIElementSetAttributeValue(match.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        guard AXUIElementPerformAction(match.window, kAXRaiseAction as CFString) == .success else { return false }
        if case .tab(let tab) = match.location, AXUIElementPerformAction(tab, kAXPressAction as CFString) != .success { return false }
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
        log.debug("route=reuse-safari dispatch-ms=\(milliseconds)")
        return true
    }

    @MainActor
    private static func safariBundle(for url: URL, source: String?) -> String? {
        if source?.hasPrefix("Safari Technology Preview") == true { return preview }
        if source?.hasPrefix("Safari") == true { return safari }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              let identifier = Bundle(url: app)?.bundleIdentifier,
              [safari, preview].contains(identifier) else { return nil }
        return identifier
    }

    static func isExactPage(_ candidate: String, _ expected: URL) -> Bool {
        URL(string: candidate).flatMap(ResearchSourceLocation.webURL)?.absoluteString == expected.absoluteString
    }

    static func safariAddress(_ window: AXUIElement) -> String? {
        Lookup(timeout: 0.15, deadline: .infinity).safariAddress(window)
    }

    private static func find(_ url: URL, in pid: pid_t) -> Match? {
        let lookup = Lookup(timeout: 0.04, deadline: ProcessInfo.processInfo.systemUptime + 0.25)
        let root = AXUIElementCreateApplication(pid)
        let focused = lookup.element(root, kAXFocusedWindowAttribute)
        if let focused {
            if lookup.matchesWindow(focused, url: url) { return .init(window: focused, location: .window) }
            if lookup.matchesCurrentDocument(focused, url: url) { return .init(window: focused, location: .document) }
        }
        let windows = (focused.map { [$0] } ?? []) +
            (lookup.value(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(12).filter {
                guard let focused else { return true }
                return !CFEqual(focused, $0)
            }
        for window in windows {
            guard lookup.isAvailable else { return nil }
            if focused.map({ !CFEqual($0, window) }) ?? true, lookup.matchesWindow(window, url: url) {
                return .init(window: window, location: .window)
            }
            if let tab = lookup.matchingTab(in: window, url: url) { return .init(window: window, location: .tab(tab)) }
        }
        return nil
    }

    private struct Lookup {
        let timeout: Float
        let deadline: TimeInterval

        var isAvailable: Bool { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }

        func value(_ item: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard isAvailable else { return nil }
            AXUIElementSetMessagingTimeout(item, timeout)
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(item, attribute as CFString, &result) == .success ? result : nil
        }

        func element(_ item: AXUIElement, _ attribute: String) -> AXUIElement? {
            guard let result = value(item, attribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
            return (result as! AXUIElement)
        }

        private func children(_ item: AXUIElement) -> [AXUIElement] {
            value(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }

        private func role(_ item: AXUIElement) -> String? { value(item, kAXRoleAttribute) as? String }

        func matches(_ item: AXUIElement, url: URL, attributes: [String]) -> Bool {
            attributes.contains { attribute in
                let candidate = value(item, attribute)
                if let locator = (candidate as? URL)?.absoluteString ?? candidate as? String {
                    return ResearchBrowserNavigation.isExactPage(locator, url)
                }
                return false
            }
        }

        func matchesWindow(_ window: AXUIElement, url: URL) -> Bool {
            guard value(window, kAXSubroleAttribute) as? String == "AXStandardWindow" else { return false }
            if matches(window, url: url, attributes: [kAXDocumentAttribute, kAXURLAttribute]) { return true }
            return safariAddress(window).map { ResearchBrowserNavigation.isExactPage($0, url) } == true
        }

        func matchesCurrentDocument(_ window: AXUIElement, url: URL) -> Bool {
            guard value(window, kAXSubroleAttribute) as? String == "AXStandardWindow",
                  let contents = documentChildren(window, limit: 64) else { return false }
            // Safari's smart address bar can omit the path. The primary web area
            // returns the full URL. Stay in the browser's document container and
            // decline reuse when there is more than one top-level web area.
            var roots: [AXUIElement] = []
            for item in contents {
                guard let kind = role(item) else { return false }
                if kind == kAXSplitGroupRole { roots.append(item) }
            }
            guard roots.count == 1 else { return false }
            var level = roots
            var document: AXUIElement?
            var remainingNodes = 64
            for _ in 0..<8 {
                var next: [AXUIElement] = []
                for item in level {
                    guard remainingNodes > 0, let kind = role(item) else { return false }
                    remainingNodes -= 1
                    if kind == "AXWebArea" {
                        guard document == nil else { return false }
                        document = item
                    } else if [kAXGroupRole, kAXSplitGroupRole, kAXTabGroupRole, kAXScrollAreaRole, "AXLayoutArea"].contains(kind) {
                        guard let children = documentChildren(item, limit: remainingNodes - next.count) else { return false }
                        next += children
                    }
                }
                if next.isEmpty { return document.map { matches($0, url: url, attributes: [kAXURLAttribute]) } == true }
                level = next
            }
            return false
        }

        private func documentChildren(_ item: AXUIElement, limit: Int) -> [AXUIElement]? {
            guard isAvailable, limit >= 0 else { return nil }
            AXUIElementSetMessagingTimeout(item, timeout)
            var result: CFTypeRef?
            switch AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &result) {
            case .noValue, .attributeUnsupported: return []
            case .success:
                guard let children = result as? [AXUIElement], children.count <= limit else { return nil }
                return children
            default: return nil
            }
        }

        func safariAddress(_ window: AXUIElement) -> String? {
            guard let toolbar = children(window).first(where: { role($0) == kAXToolbarRole }) else { return nil }
            var level = [toolbar]
            for _ in 0..<4 {
                guard isAvailable else { return nil }
                var next: [AXUIElement] = []
                for item in level.prefix(48) {
                    let kind = role(item)
                    if kind == kAXTextFieldRole,
                       (value(item, kAXIdentifierAttribute) as? String)?.hasSuffix("WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD") == true,
                       value(item, kAXFocusedAttribute) as? Bool != true,
                       let address = value(item, kAXValueAttribute) as? String, address.utf8.count <= 4096 { return address }
                    if kind == kAXToolbarRole || kind == kAXGroupRole { next += children(item).prefix(48) }
                }
                level = next
            }
            return nil
        }

        func matchingTab(in window: AXUIElement, url: URL) -> AXUIElement? {
            guard value(window, kAXSubroleAttribute) as? String == "AXStandardWindow",
                  let group = children(window).first(where: { role($0) == kAXTabGroupRole }) else { return nil }
            let tabs = value(group, kAXTabsAttribute) as? [AXUIElement] ?? children(group)
            return tabs.prefix(32).first { tab in
                ["AXRadioButton", "AXTab"].contains(role(tab) ?? "") && matches(tab, url: url, attributes: [kAXURLAttribute])
            }
        }
    }
}
