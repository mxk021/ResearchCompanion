import AppKit
import SwiftUI

@MainActor
final class ResearchWindowPresentation: ObservableObject {
    @Published private(set) var revision = 0
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
    private static let interactionKey = "research-companion.chatWindowInteraction"
    private static let defaultSize = NSSize(width: 740, height: 760)
    private let chat: ChatWindow
    private let close: () -> Void
    private let presentation = ResearchWindowPresentation()
    private(set) var isPinned: Bool
    private var settingFrame = false
    private var frameSaveTask: Task<Void, Never>?
    private(set) var isKeepingSelectionVisible = false
    var visibilityDidChange: (() -> Void)?

    init(model: DSHPetModel, command: DSHPetCommandClient) {
        let saved = UserDefaults.standard.string(forKey: Self.interactionKey)
        isPinned = saved == "pinned" || saved == "pinnedClickThrough"
        if saved == "pinnedClickThrough" {
            UserDefaults.standard.set("pinned", forKey: Self.interactionKey)
        }
        chat = ChatWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        close = { [weak model] in model?.collapseComposer(reason: .closeButton) }
        super.init()
        chat.title = "科研助手"
        chat.setAccessibilityIdentifier("research-companion.chat")
        chat.isReleasedWhenClosed = false
        chat.isMovableByWindowBackground = false
        updateLevel()
        chat.delegate = self
        chat.requestClose = { [weak model] in model?.collapseComposer(reason: .panelCancel) }
        let hosting = NSHostingView(rootView: ResearchComposerView(model: model, command: command, presentation: presentation))
        // Intrinsic SwiftUI sizes must not replace an AppKit user resize.
        hosting.sizingOptions = []
        chat.contentView = hosting
    }

    var window: NSWindow { chat }

    func togglePinned() {
        isPinned.toggle()
        UserDefaults.standard.set(isPinned ? "pinned" : "normal", forKey: Self.interactionKey)
        updateLevel()
    }

    private func updateLevel() {
        let level: NSWindow.Level = isPinned || isKeepingSelectionVisible ? .floating : .normal
        if chat.level != level { chat.level = level }
    }

    func present() {
        if chat.isMiniaturized {
            chat.deminiaturize(nil)
        } else if !chat.isVisible {
            restoreFrame()
            presentation.didPresent()
        }
        // A user action in the nonactivating pet panel can precede application activation.
        if !NSApp.isActive { chat.orderFrontRegardless() }
        chat.makeKeyAndOrderFront(nil)
        visibilityDidChange?()
    }

    @discardableResult
    func focusAfterSelection(in original: NSWindow) -> Bool {
        guard chat === original, chat.isVisible, !chat.isMiniaturized, chat.attachedSheet == nil,
              NSApp.keyWindow == nil || NSApp.keyWindow === chat else { return false }
        chat.makeKeyAndOrderFront(nil)
        visibilityDidChange?()
        return true
    }

    /// Keep precisely the visible chat above the reader during the short
    /// native selection handoff. Do not introduce a second window or Space.
    func keepSelectionVisible(in original: NSWindow) {
        guard chat === original, chat.isKeyWindow, chat.isVisible, chat.isOnActiveSpace,
              !chat.isMiniaturized, !chat.styleMask.contains(.fullScreen), chat.attachedSheet == nil,
              !isKeepingSelectionVisible else { return }
        isKeepingSelectionVisible = true
        updateLevel()
    }

    @discardableResult
    func endSelectionVisibility() -> Bool {
        guard isKeepingSelectionVisible else { return false }
        isKeepingSelectionVisible = false
        updateLevel()
        return true
    }

    func hide() {
        guard chat.isVisible || chat.isMiniaturized else { return }
        endSelectionVisibility()
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
    func windowWillMiniaturize(_ notification: Notification) {
        endSelectionVisibility()
        persistFrame()
    }
    func windowDidMiniaturize(_ notification: Notification) { visibilityDidChange?() }
    func windowDidDeminiaturize(_ notification: Notification) {
        recoverVisibleFrame()
        visibilityDidChange?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        endSelectionVisibility()
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
