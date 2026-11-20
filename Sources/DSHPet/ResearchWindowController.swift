import AppKit
import SwiftUI

enum ResearchReadingAction: String, CaseIterable {
    case saveSelection, openSource

    var title: String {
        switch self {
        case .saveSelection: "将选区或当前回答保存为笔记"
        case .openSource: "打开当前回答的原文"
        }
    }

    var shortcut: GlobalHotKeyConfiguration {
        .init(isEnabled: true, keyCode: self == .saveSelection ? 1 : 31,
              modifiers: [.command, .option]) // ⌥⌘S / ⌥⌘O
    }
}

@MainActor
final class ResearchWindowPresentation: ObservableObject {
    @Published private(set) var revision = 0
    var performReadingAction: ((ResearchReadingAction) -> Void)?
    func didPresent() { revision &+= 1 }
}

/// The conversation uses its own native window. The pet and its small
/// controls remain anchored independently, even as this window resizes.
@MainActor
final class ResearchWindowController: NSObject, NSWindowDelegate {
    private final class ChatWindow: NSWindow {
        var requestClose: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { requestClose?() }
    }

    private static let frameKey = "research-companion.chatWindowFrame"
    private static let defaultSize = NSSize(width: 620, height: 710)
    private let chat: ChatWindow
    private let close: () -> Void
    private let presentation = ResearchWindowPresentation()
    private var settingFrame = false
    private var frameSaveTask: Task<Void, Never>?
    var visibilityDidChange: (() -> Void)?

    init(model: DSHPetModel, command: DSHPetCommandClient) {
        chat = ChatWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        close = { [weak model] in model?.collapseComposer(reason: .closeButton) }
        super.init()
        chat.title = "科研伙伴"
        chat.setAccessibilityIdentifier("research-companion.chat")
        chat.isReleasedWhenClosed = false
        chat.isMovableByWindowBackground = false
        chat.level = .normal
        chat.delegate = self
        chat.requestClose = { [weak model] in model?.collapseComposer(reason: .panelCancel) }
        let hosting = NSHostingView(rootView: ResearchComposerView(model: model, command: command, presentation: presentation))
        // Intrinsic SwiftUI sizes must not replace an AppKit user resize.
        hosting.sizingOptions = []
        chat.contentView = hosting
    }

    var window: NSWindow { chat }

    var readingMenuAvailable: Bool {
        NSApp.isActive && chat.isKeyWindow && chat.isVisible && chat.attachedSheet == nil
    }

    func performReadingAction(_ action: ResearchReadingAction) {
        guard readingMenuAvailable else { return }
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        presentation.performReadingAction?(action)
    }

    func present() {
        if chat.isMiniaturized {
            chat.deminiaturize(nil)
        } else if !chat.isVisible {
            restoreFrame()
            presentation.didPresent()
        }
        chat.makeKeyAndOrderFront(nil)
        visibilityDidChange?()
    }

    func hide() {
        guard chat.isVisible || chat.isMiniaturized else { return }
        persistFrame()
        chat.orderOut(nil)
        visibilityDidChange?()
    }

    func recoverVisibleFrame() {
        guard chat.isVisible, !chat.isMiniaturized else { return }
        fit(chat.frame)
        persistFrame()
    }

    func persistFrame() {
        frameSaveTask?.cancel()
        frameSaveTask = nil
        guard chat.isVisible, !chat.isMiniaturized, !settingFrame else { return }
        let frame = NSStringFromRect(chat.frame)
        if UserDefaults.standard.string(forKey: Self.frameKey) != frame {
            UserDefaults.standard.set(frame, forKey: Self.frameKey)
        }
    }

    private func scheduleFrameSave() {
        guard chat.isVisible, !settingFrame, !chat.inLiveResize, frameSaveTask == nil else { return }
        frameSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.persistFrame()
        }
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    func windowDidEndLiveResize(_ notification: Notification) { persistFrame() }
    func windowWillMiniaturize(_ notification: Notification) { persistFrame() }
    func windowDidMiniaturize(_ notification: Notification) { visibilityDidChange?() }
    func windowDidDeminiaturize(_ notification: Notification) {
        recoverVisibleFrame()
        visibilityDidChange?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        persistFrame()
        close()
        visibilityDidChange?()
        return true
    }

    private func restoreFrame() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let saved = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString)
        let fallback = NSRect(x: bounds.midX - Self.defaultSize.width / 2,
                              y: bounds.midY - Self.defaultSize.height / 2,
                              width: Self.defaultSize.width, height: Self.defaultSize.height)
        let proposed = saved.flatMap { Self.isUsable($0) ? $0 : nil } ?? fallback
        fit(proposed, fallback: bounds)
    }

    private func fit(_ requested: NSRect, fallback: NSRect? = nil) {
        let bounds = fallback ?? NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        guard let bounds else { return }
        let screenBounds = NSScreen.screens.map(\.visibleFrame)
        let result = ResearchWindowGeometry.visibleFrame(for: requested, screens: screenBounds, fallback: bounds)
        settingFrame = true
        chat.minSize = NSSize(width: min(ResearchWindowGeometry.minimumSize.width, result.width),
                              height: min(ResearchWindowGeometry.minimumSize.height, result.height))
        if !NSEqualRects(result, chat.frame) { chat.setFrame(result, display: true) }
        settingFrame = false
    }

    private static func isUsable(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }

}
