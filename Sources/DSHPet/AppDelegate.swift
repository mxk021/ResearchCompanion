import AppKit
import SwiftUI
import Combine
import QuartzCore
import os

private let appLog = Logger(subsystem: "com.local.research-companion", category: "app")

/// 透明、无边框的桌宠面板，只有可操作区域接收鼠标事件。
/// 鼠标移入球体范围时恢复响应（可拖拽），移出后再次穿透。
/// 拖拽由 SwiftUI 手势驱动（见 DSHPetView），位置持久化到 UserDefaults。
final class DSHPetPanel: NSPanel {
    /// 供 SwiftUI 拖拽手势引用当前悬浮窗
    static weak var current: DSHPetPanel?

    /// 拖拽进行中，无论指针位置都继续接收拖拽事件。
    var isDragging = false
    var onRightClick: ((NSPoint) -> Void)?

    private enum PositionKeys {
        static let x = "dsh-pet.ballPositionX"
        static let y = "dsh-pet.ballPositionY"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(NSEvent.mouseLocation)
    }

    /// 尝试恢复上次拖拽保存的位置；仅当设置允许且窗口中心仍在某个屏幕可视区内才生效
    @discardableResult
    func restoreSavedPosition() -> Bool {
        guard PetSettings.shared.rememberPosition else { return false }
        let defaults = UserDefaults.standard
        let x = (defaults.object(forKey: PositionKeys.x) as? NSNumber)?.doubleValue
        let y = (defaults.object(forKey: PositionKeys.y) as? NSNumber)?.doubleValue
        guard let x, let y else { return false }
        // 用「窗口中心」判断而非整窗相交：避免显示器变化后只留一截在屏边、球心在屏外
        let center = NSPoint(x: x + self.frame.width / 2, y: y + self.frame.height / 2)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard visibleFrames.contains(where: { $0.contains(center) }) else { return false }
        setFrameOrigin(NSPoint(x: x, y: y))
        return true
    }

    /// 拖拽结束时保存当前位置（受「记住位置」设置控制）
    func persistPosition() {
        guard PetSettings.shared.rememberPosition else { return }
        UserDefaults.standard.set(Double(frame.origin.x), forKey: PositionKeys.x)
        UserDefaults.standard.set(Double(frame.origin.y), forKey: PositionKeys.y)
        appLog.info("persistPosition -> \(Int(self.frame.origin.x)),\(Int(self.frame.origin.y))")
    }
}

private final class PetHostingView: NSHostingView<DSHPetView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Separate control surface below the pet. Keeping it in its own panel means
/// expanding the composer never changes the pet window's drag anchor or size.
final class DSHPetComposerPanel: NSPanel {
    var onExplicitClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onExplicitClose?() }
}

final class DSHPetTaskPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

private final class PetContextPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct PetContextView: View {
    let hidePet: () -> Void

    var body: some View {
        Button(action: hidePet) {
            Text("隐藏宠物")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 88, height: 32)
                .background(Color(nsColor: NSColor(calibratedWhite: 0.42, alpha: 0.76)),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(0.35), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("隐藏宠物")
        .frame(width: 104, height: 48)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let model = DSHPetModel.shared
    private var panel: DSHPetPanel?
    private var composerPanel: DSHPetComposerPanel?
    private var researchWindow: ResearchWindowController?
    private var taskPanel: DSHPetTaskPanel?
    private var petContextPanel: PetContextPanel?
    private var petContextMonitors: [Any] = []
    private var settingsPanel: NSPanel?
    private var hoverMonitors: [Any] = []
    private var visibilitySink: AnyCancellable?
    private var settingsSink: AnyCancellable?
    private var bubbleSink: AnyCancellable?
    private var composerSink: AnyCancellable?
    private var researchVisibilitySink: AnyCancellable?
    private var taskPanelSink: AnyCancellable?
    private var connectionSink: AnyCancellable?
    private var statusItem: NSStatusItem?
    private var statusSink: AnyCancellable?
    private var statusHeaderItem: NSMenuItem?
    private var togglePetMenuItem: NSMenuItem?
    private var lastIconColor: Color?
    private var taskPanelEventMonitors: [Any] = []
    private var isTaskPanelClosing = false
    private var lastExternalApplication: NSRunningApplication?
    private var panelSelectionOrigin: (app: NSRunningApplication, target: ResearchSelectionCapture.Target)?
    private var selectionActivationTask: Task<Void, Never>?
    private var selectionCapture: SelectionCapture?
    private var selectionWindowReturn: SelectionWindowReturn?
    private var safariSelectionService: SafariSelectionService?

    private struct SelectionCapture {
        let request: DSHPetCommandClient.SelectionRequest
        let source: ResearchSelectionCapture.Target
        let chatWindow: NSWindow
        var phase: ResearchSelectionHandoff
    }

    private struct SelectionWindowReturn {
        let id: UUID
        let sourcePID: pid_t
        let chatWindow: NSWindow
    }

    // System Services carries the text on a private board, but supplies no
    // caller or request token. Only one issued Safari action may await a reply.
    private final class SafariSelectionService {
        let requestID: UUID
        let document: ResearchSelectionCapture.CopyDocument
        var reply: Result<ResearchMaterial, Error>?
        var interrupted = false

        init(requestID: UUID, document: ResearchSelectionCapture.CopyDocument) {
            self.requestID = requestID
            self.document = document
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ResearchLaunchLog.write("delegate-launched")
        // Launch Services normally directs another open to the running app.
        // Forward a forced second launch before creating panels or connections.
        if let existing = Self.existingInstance() {
            ResearchLaunchLog.write("duplicate-instance-exit")
            if let url = existing.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)

        // 菜单栏品牌符号与标准主菜单
        setupStatusItem()
        setupMainMenu()
        recordSelectionForeground(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(selectionForegroundChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        ResearchLaunchLog.write(ResearchSelectionCapture.accessibilityAvailable
            ? "selection-accessibility-allowed" : "selection-accessibility-denied")

        setupPanel()
        setupPetContextPanel()
        setupComposerPanel()
        setupTaskPanel()
        model.start()
        startHoverMonitor()
        observeVisibility()
        observeSettings()
        observeBubble()
        observeComposer()
        ResearchLaunchLog.write("panels-created")
        showComposer()
        // 显示器增删/分辨率变化时，把球收回可视区（避免被 macOS 甩到屏幕外）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // 设置面板「重置位置」请求
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(resetPositionRequested),
            name: .dshPetResetPosition,
            object: nil
        )
        appLog.info("didFinishLaunching done")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ResearchLaunchLog.write("app-terminating")
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        cancelSelectionCapture()
        researchWindow?.persistFrame()
        model.commandClient.flushDraftPersistence()
        model.stop()
        for monitor in hoverMonitors {
            NSEvent.removeMonitor(monitor)
        }
        hoverMonitors = []
        bubbleSink?.cancel()
        bubbleSink = nil
        statusSink?.cancel()
        statusSink = nil
        composerSink?.cancel()
        composerSink = nil
        researchVisibilitySink?.cancel()
        researchVisibilitySink = nil
        taskPanelSink?.cancel()
        taskPanelSink = nil
        connectionSink?.cancel()
        connectionSink = nil
        removeTaskPanelEventMonitors()
        dismissPetContext()
        model.closeTaskPanel()
    }

    func applicationWillHide(_ notification: Notification) {
        ResearchLaunchLog.write("app-hidden")
        cancelSelectionCapture()
        researchWindow?.persistFrame()
        model.closeTaskPanel()
        model.commandClient.setResearchWindowForeground(false)
    }

    func applicationDidUnhide(_ notification: Notification) {
        updateResearchForeground()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        finishSelectionWindowReturn()
        updateResearchForeground()
    }

    func applicationDidResignActive(_ notification: Notification) {
        updateResearchForeground()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if selectionWindowReturn != nil {
            finishSelectionWindowReturn()
        } else {
            showComposer()
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - 悬浮窗

    private func setupPanel() {
        let bubble = showStatusBubble ? model.bubblePresentation : nil
        let width = DSHPetView.panelWidth(
            for: PetSettings.shared.skin,
            size: PetSettings.shared.ballSize,
            glowEnabled: PetSettings.shared.glowEnabled,
            bubble: bubble
        )
        let height = DSHPetView.panelHeight(
            for: PetSettings.shared.skin,
            size: PetSettings.shared.ballSize,
            glowEnabled: PetSettings.shared.glowEnabled,
            bubble: bubble
        )
        let panel = DSHPetPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.title = "科研助手 · 角色"
        panel.setAccessibilityLabel("科研助手角色")
        panel.setAccessibilityIdentifier("research-companion.character")
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating                       // 置顶
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true               // 由 updateHover 根据角色的可见区域更新
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.onRightClick = { [weak self] point in
            self?.showPetContext(at: point)
        }

        let hosting = PetHostingView(rootView: DSHPetView(
            model: model,
            settings: PetSettings.shared,
            onActivateChat: { [weak self] in self?.activateResearchComposerFromPet() },
            onOpenHarness: { [weak self] in self?.model.openHarness() }
        ))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting

        // 优先恢复上次拖拽位置，否则放屏幕右下角
        if !panel.restoreSavedPosition() {
            positionAtBottomRight(panel)
        }
        DSHPetPanel.current = panel
        if PetSettings.shared.isPetVisible {
            panel.orderFrontRegardless()
        }
        self.panel = panel
    }

    private func setupPetContextPanel() {
        let context = PetContextPanel(
            contentRect: NSRect(x: 0, y: 0, width: 104, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        context.isOpaque = false
        context.backgroundColor = .clear
        context.hasShadow = false
        context.level = .floating
        context.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        context.isReleasedWhenClosed = false
        context.hidesOnDeactivate = false
        context.isExcludedFromWindowsMenu = true
        context.contentView = NSHostingView(rootView: PetContextView { [weak self] in
            self?.dismissPetContext()
            PetSettings.shared.isPetVisible = false
        })
        petContextPanel = context
    }

    private func showPetContext(at point: NSPoint) {
        guard let context = petContextPanel else { return }
        let visible = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = context.frame.size
        let origin = NSPoint(
            x: min(max(point.x + 8, visible.minX), visible.maxX - size.width),
            y: min(max(point.y - size.height - 8, visible.minY), visible.maxY - size.height)
        )
        context.setFrameOrigin(origin)
        context.orderFrontRegardless()
        installPetContextMonitors()
    }

    private func dismissPetContext() {
        petContextPanel?.orderOut(nil)
        for monitor in petContextMonitors { NSEvent.removeMonitor(monitor) }
        petContextMonitors.removeAll()
    }

    private func installPetContextMonitors() {
        guard petContextMonitors.isEmpty else { return }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismissPetContext()
                return nil
            }
            if event.type != .keyDown, event.window !== self.petContextPanel {
                self.dismissPetContext()
            }
            return event
        }) {
            petContextMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissPetContext() }
        }) {
            petContextMonitors.append(global)
        }
    }

    private func setupComposerPanel() {
        let p = DSHPetComposerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 72, height: 18),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.title = "科研助手 · 操作栏"
        p.setAccessibilityIdentifier("research-companion.pet-toolbar")
        p.onExplicitClose = { [weak self] in self?.model.collapseComposer(reason: .panelCancel) }
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isExcludedFromWindowsMenu = true
        let hosting = NSHostingView(rootView: DSHPetComposerView(model: model, command: model.commandClient))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        p.contentView = hosting
        self.composerPanel = p
        updateComposerPanel()
    }

    private func setupTaskPanel() {
        let p = DSHPetTaskPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = false
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none
        p.isExcludedFromWindowsMenu = true
        let hosting = NSHostingView(rootView: DSHPetTaskPanelView(model: model, command: model.commandClient))
        hosting.wantsLayer = true
        p.contentView = hosting
        p.onCancel = { [weak self] in self?.model.closeTaskPanel() }
        self.taskPanel = p
    }

    private func positionAtBottomRight(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let inset: CGFloat = 16
        let origin = NSPoint(
            x: screen.visibleFrame.maxX - panel.frame.width - inset,
            y: screen.visibleFrame.minY + inset
        )
        panel.setFrameOrigin(origin)
        appLog.info("positionAtBottomRight -> \(Int(origin.x)),\(Int(origin.y)) on visibleFrame \(Int(screen.visibleFrame.minX)),\(Int(screen.visibleFrame.minY)) \(Int(screen.visibleFrame.width))x\(Int(screen.visibleFrame.height))")
    }

    @objc private func screenParametersChanged() {
        researchWindow?.recoverVisibleFrame()
        guard let panel, panel.isVisible else { return }
        // 显示器增删/分辨率变化后，若窗口中心不在任何屏幕的可视区内
        // （可能只留一截在屏边、球心已甩到无屏幕区域，导致拖不到），
        // 就把球收回鼠标所在屏的右下角。
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let centerOnScreen = visibleFrames.contains { $0.contains(center) }
        if !centerOnScreen {
            positionAtBottomRight(panel)
            appLog.info("screen changed: ball center off-screen, repositioned to bottom-right")
        }
        updateComposerPanel()
        updateTaskPanel()
    }

    @objc private func resetPositionRequested() {
        guard let panel else { return }
        positionAtBottomRight(panel)
    }

    // MARK: - 设置联动

    private func observeSettings() {
        // 皮肤、尺寸或光晕变化时更新窗口；底部锚点保持不动。
        settingsSink = Publishers.CombineLatest3(
            PetSettings.shared.$ballSize,
            PetSettings.shared.$skin,
            PetSettings.shared.$glowEnabled
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] newSize, skin, glowEnabled in
                guard let self, let panel = self.panel else { return }
                let bubble = self.showStatusBubble ? self.model.bubblePresentation : nil
                panel.setFrame(self.panelFrame(
                    ballSize: newSize, skin: skin, glowEnabled: glowEnabled, bubble: bubble
                ), display: true)
                self.updateComposerPanel()
                self.updateHover()
            }
    }

    // MARK: - 状态气泡（面板增高联动）

    /// 当前是否显示状态气泡（有可显示的卡组页且设置开关打开）
    private var showStatusBubble: Bool {
        model.bubblePresentation != nil && PetSettings.shared.showStatusBubble
    }

    /// 按可见内容计算面板大小，保留宠物的水平中心和底部位置。
    private func panelFrame(
        ballSize d: CGFloat, skin: FloatingPetSkin, glowEnabled: Bool, bubble: DSHPetBubblePresentation?
    ) -> NSRect {
        let w = DSHPetView.panelWidth(for: skin, size: d, glowEnabled: glowEnabled, bubble: bubble)
        let h = DSHPetView.panelHeight(for: skin, size: d, glowEnabled: glowEnabled, bubble: bubble)
        let old = panel?.frame ?? NSRect(x: 0, y: 0, width: w, height: h)
        let ballCenterX = old.midX
        return NSRect(x: ballCenterX - w / 2, y: old.minY, width: w, height: h)
    }

    private func observeBubble() {
        // 气泡内容/页数/设置变化 → 增高/缩回面板顶部
        let bubbleChanges: AnyPublisher<Void, Never> = model.$bubblePresentation
            .map { _ in () as Void }
            .eraseToAnyPublisher()
        let bubbleSetting: AnyPublisher<Void, Never> = PetSettings.shared.$showStatusBubble
            .map { _ in () as Void }
            .eraseToAnyPublisher()
        bubbleSink = Publishers.MergeMany(bubbleChanges, bubbleSetting)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel else { return }
                let bubble = self.showStatusBubble ? self.model.bubblePresentation : nil
                let frame = self.panelFrame(
                    ballSize: PetSettings.shared.ballSize,
                    skin: PetSettings.shared.skin,
                    glowEnabled: PetSettings.shared.glowEnabled,
                    bubble: bubble
                )
                if !frame.equalTo(panel.frame) {
                    panel.setFrame(frame, display: true)
                    appLog.info("panel frame -> \(Int(frame.width))x\(Int(frame.height)) bubble=\(bubble != nil)")
                    self.updateHover()
                }
            }
    }

    // MARK: - 桌宠可操作区域

    private func startHoverMonitor() {
        // 事件驱动：鼠标移动/拖拽时才检测，鼠标不动时零唤醒（取代固定频率轮询定时器）。
        // 本地监视器：本 app 活跃时（拖拽中、设置面板开着）触发；
        // 全局监视器也观察其他窗口前台时的指针位置。
        // 全局监视器回调在后台线程，统一跳回主线程再更新。
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let local = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.updateHover()
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateHover()
            }
        }
        hoverMonitors = [local, global].compactMap { $0 }
    }

    private func updateHover() {
        let settings = PetSettings.shared
        guard panel?.isVisible == true else { return }
        let mouse = NSEvent.mouseLocation
        let d = settings.ballSize
        let petFrame: NSRect?
        if let panel, panel.isVisible {
            if settings.skin.isSprite {
                // Codex 宠物保留完整单格的交互宽度，小雨沿用原来的贴合区域。
                let petWidth = d * (settings.skin == .xiaoyu ? 0.75 : 192.0 / 208.0)
                petFrame = NSRect(
                    x: panel.frame.midX - petWidth / 2,
                    y: panel.frame.minY,
                    width: petWidth,
                    height: d * 1.10
                )
            } else {
                petFrame = NSRect(x: panel.frame.midX - d, y: panel.frame.minY + d / 2, width: d * 2, height: d)
            }
        } else {
            petFrame = nil
        }
        let insidePet: Bool
        if settings.skin.isSprite {
            insidePet = petFrame?.insetBy(dx: -8, dy: -4).contains(mouse) == true
        } else if let panel, panel.isVisible {
            let ballCenter = NSPoint(x: panel.frame.midX, y: panel.frame.minY + d)
            insidePet = hypot(mouse.x - ballCenter.x, mouse.y - ballCenter.y) <= d
        } else {
            insidePet = false
        }

        var insideBubble = false
        if let panel,
           settings.showStatusBubble,
           let bubble = model.bubblePresentation {
            let bubbleCanReceiveInput = bubble.interactive || bubble.taskID != nil
            if bubbleCanReceiveInput {
                let bubbleHeight = DSHPetView.bubbleSpaceHeight(for: bubble)
                    + (settings.skin.isSprite ? DSHPetView.tailGap : 0)
                let bubbleWidth = bubble.isMulti ? DSHPetView.multiBubblePanelWidth : panel.frame.width
                let rect = NSRect(
                    x: panel.frame.midX - bubbleWidth / 2,
                    y: panel.frame.maxY - bubbleHeight,
                    width: bubbleWidth,
                    height: bubbleHeight
                )
                insideBubble = rect.insetBy(dx: 2, dy: 2).contains(mouse)
            }
        }

        if model.barPhase != .composer {
            let controlFrame = composerPanel?.frame.insetBy(dx: -14, dy: -18)
            let insideTaskPanel = taskPanel?.isVisible == true && taskPanel?.frame.contains(mouse) == true
            model.setComposerHovering(
                insidePet
                    || insideBubble
                    || controlFrame?.contains(mouse) == true
                    || insideTaskPanel
            )
        }
        updateComposerPanel()

        guard let panel, panel.isVisible else { return }
        let outsideControls = !panel.isDragging && !insidePet && !insideBubble
        if panel.ignoresMouseEvents != outsideControls {
            panel.ignoresMouseEvents = outsideControls
        }
    }

    // MARK: - 输入控件面板

    private func observeComposer() {
        composerSink = model.$barPhase.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateComposerPanel() }
        researchVisibilitySink = model.$isResearchPanelOpen.removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] open in
                guard let self, open == self.model.isResearchPanelOpen else { return }
                if !open {
                    self.cancelSelectionCapture()
                    self.model.commandClient.flushDraftPersistence()
                    self.researchWindow?.hide()
                    self.updateResearchForeground()
                } else if self.researchWindow?.window.isVisible != true,
                          self.researchWindow?.window.isMiniaturized != true {
                    self.focusResearchPanel()
                }
                self.updateComposerPanel()
            }
        taskPanelSink = model.$taskPanelMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateComposerPanel()
                self?.updateTaskPanel()
                self?.updateHover()
            }
        connectionSink = model.commandClient.$connection.removeDuplicates()
            .sink { connection in
                switch connection {
                case .connected: ResearchLaunchLog.write("bridge-connected")
                case .connecting: ResearchLaunchLog.write("bridge-connecting")
                case .disconnected: ResearchLaunchLog.write("bridge-disconnected")
                }
            }
    }

    private func updateComposerPanel() {
        guard let composerPanel else { return }
        let settings = PetSettings.shared
        guard settings.isPetVisible, !model.isResearchPanelOpen else {
            if composerPanel.isVisible { composerPanel.orderOut(nil) }
            return
        }
        let phase = model.barPhase
        let size = Self.composerPanelSize(
            for: phase,
            expandedComposerSize: expandedComposerSize
        )
        let frame = composerFrame(size: size)
        if !frame.equalTo(composerPanel.frame) { composerPanel.setFrame(frame, display: true) }
        composerPanel.ignoresMouseEvents = phase != .composer && phase != .hovering
        if !composerPanel.isVisible { composerPanel.orderFrontRegardless() }
    }

    private func focusResearchPanel() {
        guard model.isResearchPanelOpen else { return }
        let firstPresentation = researchWindow == nil
        if firstPresentation {
            let controller = ResearchWindowController(model: model, command: model.commandClient)
            controller.visibilityDidChange = { [weak self] in self?.updateResearchForeground() }
            researchWindow = controller
        }
        cancelSelectionCapture()
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
           app.activationPolicy == .regular {
            lastExternalApplication = app
            panelSelectionOrigin = ResearchSelectionCapture.target(app).map { (app, $0) }
        }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if !NSApp.isActive { NSApp.activate() }
        researchWindow?.present()
        if firstPresentation { ResearchLaunchLog.write("first-panel-presented") }
    }

    private func updateResearchForeground() {
        let window = researchWindow?.window
        let visible = model.isResearchPanelOpen && !NSApp.isHidden
            && window?.isVisible == true && window?.isMiniaturized == false
        // An owned PDF handoff leaves the conversation onscreen. Avoid a
        // draft flush and immediate bridge refresh for this activation pulse.
        if visible, researchWindow?.isKeepingSelectionVisible == true { return }
        model.commandClient.setResearchWindowForeground(visible && NSApp.isActive)
    }

    private var expandedComposerSize: NSSize {
        NSSize(
            width: min(520, (NSScreen.main?.visibleFrame.width ?? 540) - 24),
            height: min(700, (NSScreen.main?.visibleFrame.height ?? 724) - 24)
        )
    }

    static func composerPanelSize(
        for phase: DSHPetBarPhase,
        expandedComposerSize: NSSize
    ) -> NSSize {
        if phase == .composer { return expandedComposerSize }
        if phase == .hovering {
            return NSSize(
                width: DSHPetComposerView.expandedBarPanelWidth,
                height: DSHPetComposerView.expandedBarPanelHeight
            )
        }
        return NSSize(
            width: DSHPetComposerView.restingPanelWidth,
            height: DSHPetComposerView.restingPanelHeight
        )
    }

    private func updateTaskPanel() {
        guard let taskPanel else { return }
        let shouldShow = PetSettings.shared.isPetVisible
            && model.taskPanelMode != .closed
        guard shouldShow else {
            removeTaskPanelEventMonitors()
            taskPanel.ignoresMouseEvents = true
            guard taskPanel.isVisible else {
                taskPanel.alphaValue = 1
                isTaskPanelClosing = false
                return
            }
            guard !isTaskPanelClosing,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                if !isTaskPanelClosing {
                    taskPanel.orderOut(nil)
                    taskPanel.alphaValue = 1
                }
                return
            }
            isTaskPanelClosing = true
            if let layer = taskPanel.contentView?.layer {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 1.0
                scale.toValue = 0.96
                scale.duration = 0.15
                scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                layer.add(scale, forKey: "dsh-pet.taskPanel.closeScale")
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                taskPanel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak taskPanel] in
                Task { @MainActor in
                    guard let self, let taskPanel else { return }
                    self.isTaskPanelClosing = false
                    if self.model.taskPanelMode == .closed || !PetSettings.shared.isPetVisible {
                        taskPanel.orderOut(nil)
                    }
                    taskPanel.alphaValue = 1
                }
            }
            return
        }

        isTaskPanelClosing = false
        let wasVisible = taskPanel.isVisible
        let shouldAnimateOpening = !wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let size = NSSize(width: 340, height: 340)
        taskPanel.setFrame(taskPanelFrame(size: size), display: true)
        taskPanel.ignoresMouseEvents = false
        taskPanel.alphaValue = shouldAnimateOpening ? 0 : 1
        taskPanel.orderFrontRegardless()
        installTaskPanelEventMonitors()

        guard shouldAnimateOpening else { return }
        if let layer = taskPanel.contentView?.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.96
            scale.toValue = 1.0
            scale.duration = 0.2
            scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            layer.add(scale, forKey: "dsh-pet.taskPanel.scale")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            taskPanel.animator().alphaValue = 1
        }
    }

    private func taskPanelFrame(size: NSSize) -> NSRect {
        guard let anchor = composerPanel?.frame else { return NSRect(origin: .zero, size: size) }
        let anchorCenter = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(anchorCenter) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 6
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        let belowY = anchor.minY - size.height - gap
        let aboveY = anchor.maxY + gap
        let y = belowY >= visible.minY + 4
            ? belowY
            : min(aboveY, visible.maxY - size.height - 4)
        return NSRect(x: x, y: max(visible.minY + 4, y), width: size.width, height: size.height)
    }

    private func installTaskPanelEventMonitors() {
        guard taskPanelEventMonitors.isEmpty else { return }
        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseEvents.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                Task { @MainActor in self.model.closeTaskPanel() }
                return nil
            }
            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                Task { @MainActor in self.closeTaskPanelIfClickIsOutside() }
            }
            return event
        }) {
            taskPanelEventMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.closeTaskPanelIfClickIsOutside() }
        }) {
            taskPanelEventMonitors.append(global)
        }
    }

    private func removeTaskPanelEventMonitors() {
        for monitor in taskPanelEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        taskPanelEventMonitors.removeAll()
    }

    private func closeTaskPanelIfClickIsOutside() {
        guard model.taskPanelMode != .closed else { return }
        let point = NSEvent.mouseLocation
        let visibleFrames = [panel, composerPanel, taskPanel]
            .compactMap { candidate -> NSRect? in
                guard let candidate, candidate.isVisible else { return nil }
                return candidate.frame
            }
        if !visibleFrames.contains(where: { $0.contains(point) }) {
            model.closeTaskPanel()
        }
    }

    private func composerFrame(size: NSSize) -> NSRect {
        guard let panel else { return NSRect(origin: .zero, size: size) }
        let centerX = panel.frame.midX
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: centerX, y: panel.frame.midY)) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The idle capsule visually belongs to the pet's feet. Expanded
        // surfaces retain a small breathing gap, while idle sits flush below.
        let petControlGap: CGFloat = !model.isResearchPanelOpen && model.barPhase == .resting ? 0 : 4
        let x = min(max(centerX - size.width / 2, visible.minX + petControlGap), visible.maxX - size.width - petControlGap)
        let belowY = panel.frame.minY - size.height - petControlGap
        let y: CGFloat
        if belowY >= visible.minY + petControlGap {
            y = belowY
        } else {
            // When there is no room below, sit above the visible pet (whose
            // sprite is bottom-anchored), not above the transparent hit area.
            y = min(
                panel.frame.minY + PetSettings.shared.ballSize + petControlGap,
                visible.maxY - size.height - petControlGap
            )
        }
        return clampedComposerFrame(NSRect(x: x, y: y, width: size.width, height: size.height))
    }

    private func clampedComposerFrame(_ frame: NSRect) -> NSRect {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return frame }
        let inset: CGFloat = 4
        let x = min(max(frame.minX, visible.minX + inset), max(visible.minX + inset, visible.maxX - frame.width - inset))
        let y = min(max(frame.minY, visible.minY + inset), max(visible.minY + inset, visible.maxY - frame.height - inset))
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    // MARK: - 宠物显示状态

    private func observeVisibility() {
        visibilitySink = PetSettings.shared.$isPetVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                guard let self else { return }
                if !visible { self.model.closeTaskPanel() }
                if visible {
                    if let panel = self.panel, !panel.isVisible {
                        panel.orderFrontRegardless()
                    }
                } else {
                    self.dismissPetContext()
                    self.panel?.orderOut(nil)
                }
                self.updateComposerPanel()
                self.updateTaskPanel()
                self.updateHover()
                appLog.info("display surfaces: visible=\(visible, privacy: .public)")
            }
    }

    // MARK: - 菜单栏图标

    /// 创建菜单栏常驻图标。
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.image = ResearchBrandMark.statusImage()
        item.button?.imagePosition = .imageOnly

        // 菜单内容：状态行 + 显示/隐藏 + 设置… + 退出
        let menu = NSMenu()

        statusHeaderItem = NSMenuItem(title: model.statusText, action: nil, keyEquivalent: "")
        statusHeaderItem?.isEnabled = false
        menu.addItem(statusHeaderItem!)

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: "打开科研对话",
            selector: #selector(showComposer)
        ))
        menu.addItem(makeMenuItem(title: "固定窗口", selector: #selector(toggleResearchWindowPin)))

        togglePetMenuItem = makeMenuItem(
            title: PetSettings.shared.isPetVisible ? "隐藏宠物" : "显示宠物",
            selector: #selector(togglePetVisibility)
        )
        menu.addItem(togglePetMenuItem!)

        menu.addItem(makeMenuItem(
            title: "设置…",
            selector: #selector(toggleSettingsPanel)
        ))

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu

        // mood 颜色 / 球显隐 / 状态文案变化 → 刷新图标与菜单
        statusSink = Publishers.Merge(model.objectWillChange, PetSettings.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange 在属性写入前发出，推迟到下一轮再读，保证拿到新值
                Task { @MainActor [weak self] in
                    self?.refreshStatusItem()
                }
            }
        refreshStatusItem() // 初始绘制
    }

    /// 用最新状态刷新菜单栏图标与菜单文案。
    private func refreshStatusItem() {
        guard let item = statusItem else { return }
        let color = model.color

        // The template glyph stays fixed; only the menu's state dot changes color.
        if lastIconColor != color {
            lastIconColor = color
            statusHeaderItem?.image = Self.makeColoredDot(color: color, size: 10)
        }

        item.button?.toolTip = model.statusText
        item.button?.setAccessibilityLabel(model.statusText)
        statusHeaderItem?.title = model.statusText
        togglePetMenuItem?.title = PetSettings.shared.isPetVisible ? "隐藏宠物" : "显示宠物"
    }

    private func makeMenuItem(title: String, selector: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleResearchWindowPin) else { return true }
        menuItem.state = researchWindow?.isPinned == true ? .on : .off
        return researchWindow != nil
    }

    @objc private func toggleResearchWindowPin() {
        researchWindow?.togglePinned()
    }

    @objc private func togglePetVisibility() {
        PetSettings.shared.isPetVisible.toggle()
    }

    private func cancelSelectionCapture(interrupted: Bool = false) {
        selectionActivationTask?.cancel()
        if let selectionCapture {
            self.selectionCapture = nil
            if interrupted {
                model.commandClient.finishResearchSelectionCapture(selectionCapture.request, result: .failure(SelectionCaptureError.sourceChanged))
            } else {
                model.commandClient.cancelResearchSelectionCapture()
            }
        }
        selectionActivationTask = nil
        selectionWindowReturn = nil
        finishSelectionWindowVisibility()
    }

    @objc func cancelResearchTextFromPanel(_ sender: Any?) {
        cancelSelectionCapture()
        model.commandClient.rejectResearchSelection("本次取词已取消。")
    }

    @objc private func showComposer() {
        cancelSelectionCapture()
        activateResearchComposer()
    }

    @objc func selectResearchTextFromPanel(_ sender: Any?) {
        guard model.isResearchPanelOpen, let chat = researchWindow?.window,
              chat.isVisible, !chat.isMiniaturized else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else {
            captureFrontSelection(in: chat)
            return
        }
        // Keep only the previously active app and window identity. Read the
        // selection itself for this action, never when the chat was raised.
        let source = panelSelectionOrigin ?? lastExternalApplication.flatMap { app in
            ResearchSelectionCapture.target(app).map { (app: app, target: $0) }
        }
        guard let origin = source, !origin.app.isTerminated, origin.target.hasSameDocument() else {
            cancelSelectionCapture()
            model.commandClient.rejectResearchSelection("无法确认之前的来源窗口。请在原窗口重新选中文字，再通过「服务 → 选取文字（科研助手）」预览。")
            _ = focusSelectionEditor(in: chat)
            return
        }
        captureSelection(in: origin.app, target: origin.target, chatWindow: chat, beginsInChat: true)
    }

    private func captureFrontSelection(in chat: NSWindow) {
        guard let app = NSWorkspace.shared.frontmostApplication, let target = ResearchSelectionCapture.target(app),
              target.isFrontmost() else {
            cancelSelectionCapture()
            model.commandClient.rejectResearchSelection(SelectionCaptureError.unsupported.localizedDescription)
            _ = focusSelectionEditor(in: chat)
            return
        }
        captureSelection(in: app, target: target, chatWindow: chat, beginsInChat: false)
    }

    private func captureSelection(in app: NSRunningApplication, target: ResearchSelectionCapture.Target,
                                  chatWindow: NSWindow, beginsInChat: Bool) {
        cancelSelectionCapture()
        let command = model.commandClient
        guard let request = command.beginResearchSelectionCapture() else {
            _ = focusSelectionEditor(in: chatWindow)
            return
        }
        ResearchSelectionTrace.mark(request.id, "capture-source-pid", Int(target.pid))
        ResearchSelectionTrace.mark(request.id, "capture-window", Int(target.windowID ?? 0))
        selectionCapture = SelectionCapture(request: request, source: target, chatWindow: chatWindow,
                                            phase: beginsInChat ? .readingInChat : .readingSource)
        selectionActivationTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            let result: Result<ResearchSelectionRead, Error>
            do {
                let background = beginsInChat ? try await self.readSelectionWithoutActivation(target, requestID: request.id) : nil
                if let background {
                    result = .success(background)
                } else {
                    if beginsInChat { try await self.activateSelectionSource(app, target: target, requestID: request.id) }
                    result = .success(try await self.readForegroundSelection(target, requestID: request.id))
                }
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self.completeSelectionCapture(request.id, result: result)
        }
    }

    private func readSelectionWithoutActivation(_ target: ResearchSelectionCapture.Target, requestID: UUID) async throws -> ResearchSelectionRead? {
        // The existing paired Zotero endpoint authorizes only its focused reader.
        guard !target.isZotero else { return nil }
        ResearchSelectionTrace.mark(requestID, "background-ax-start")
        let worker = Task.detached(priority: .userInitiated) { () throws -> ResearchSelectionRead? in
            do {
                let material = try await ResearchSelectionCapture.readWithoutActivation(target, ownerPID: getpid())
                ResearchSelectionTrace.mark(requestID, "background-ax-read")
                return .init(material: material)
            } catch let failure as SelectionCaptureError where [.unsupported, .empty, .timedOut].contains(failure) {
                // Protected or changed sources must never reach native Copy.
                ResearchSelectionTrace.failure(requestID, "background-ax-unavailable", failure)
                return try await ResearchSelectionCapture.copyWPSWithoutActivation(target, ownerPID: getpid(), requestID: requestID)
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func activateSelectionSource(_ app: NSRunningApplication, target: ResearchSelectionCapture.Target,
                                         requestID: UUID) async throws {
        try Task.checkCancellation()
        guard let capture = selectionCapture, capture.request.id == requestID,
              model.commandClient.isCurrentSelectionRequest(capture.request), NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), target.hasSameDocument() else {
            throw SelectionCaptureError.sourceChanged
        }
        selectionCapture?.phase = .activatingSource
        if target.isSafari || target.isWPS { researchWindow?.keepSelectionVisible(in: capture.chatWindow) }
        ResearchSelectionTrace.mark(requestID, "source-activation-requested")
        NSApp.yieldActivation(to: app)
        _ = app.activate(options: [])
        let deadline = ContinuousClock.now + .seconds(1)
        while !target.isFrontmost(), ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard front == getpid() || front == target.pid else { throw SelectionCaptureError.sourceChanged }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard selectionCapture?.request.id == requestID, model.commandClient.isCurrentSelectionRequest(capture.request),
              target.isFrontmost() else {
            throw SelectionCaptureError.sourceChanged
        }
        selectionCapture?.phase = .readingSource
        ResearchSelectionTrace.mark(requestID, "source-foreground")
    }

    private func readForegroundSelection(_ target: ResearchSelectionCapture.Target, requestID: UUID) async throws -> ResearchSelectionRead {
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()
            guard target.isFrontmost() else { throw SelectionCaptureError.sourceChanged }
            return try await ResearchSelectionCapture.current(target, requestID: requestID) { document, copy in
                try await self?.readSafariSelectionService(document, copy: copy, requestID: requestID)
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func readSafariSelectionService(_ document: ResearchSelectionCapture.CopyDocument,
                                             copy: AXUIElement, requestID: UUID) async throws -> ResearchSelectionRead? {
        guard safariSelectionService == nil,
              let item = document.safariServiceCommand(copy: copy) else {
            ResearchSelectionTrace.mark(requestID, "safari-private-service-unavailable")
            return nil
        }
        try Task.checkCancellation()
        guard let active = selectionCapture, active.request.id == requestID,
              model.commandClient.isCurrentSelectionRequest(active.request) else { throw SelectionCaptureError.sourceChanged }
        let service = SafariSelectionService(requestID: requestID, document: document)
        guard let input = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown], handler: { _ in
            service.interrupted = true
        }) else { return nil }
        defer { NSEvent.removeMonitor(input) }
        safariSelectionService = service
        selectionCapture?.phase = .readingSafariService
        // AXPress can wait for our Services provider. Keep it off the main
        // actor so the incoming private board can be handled immediately.
        let action = Task.detached(priority: .userInitiated) { () -> AXError? in
            guard !Task.isCancelled, document.isCurrent(),
                  ResearchSelectionCapture.CopyDocument.isEnabled(copy) else { return nil }
            AXUIElementSetMessagingTimeout(item, 1.0)
            ResearchSelectionTrace.mark(requestID, "safari-private-service-issued")
            return AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
        let status = await withTaskCancellationHandler { await action.value } onCancel: { action.cancel() }
        if let status { ResearchSelectionTrace.mark(requestID, "safari-private-service-action", Int(status.rawValue)) }
        let unissued = status == nil || status == .actionUnsupported || status == .notImplemented
        defer {
            if (unissued || service.reply != nil),
               safariSelectionService === service { safariSelectionService = nil }
            // A dispatcher timeout may still deliver later. Keep that one
            // reply reserved for its expired request, never for a new one.
        }
        try Task.checkCancellation()
        if unissued {
            guard selectionCapture?.request.id == requestID, document.isCurrent() else { throw SelectionCaptureError.sourceChanged }
            selectionCapture?.phase = .readingSource
            return nil
        }
        guard status == .success || status == .cannotComplete else { throw SelectionCaptureError.pdfServiceUnavailable }
        let deadline = ContinuousClock.now + .seconds(1)
        while service.reply == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        guard !service.interrupted else { throw SelectionCaptureError.sourceChanged }
        guard let reply = service.reply else { throw SelectionCaptureError.pdfServiceUnavailable }
        return .init(material: try reply.get())
    }

    private func completeSelectionCapture(_ id: UUID, result: Result<ResearchSelectionRead, Error>) {
        guard let capture = selectionCapture, capture.request.id == id else { return }
        selectionCapture = nil
        selectionActivationTask = nil
        defer { if selectionWindowReturn == nil { finishSelectionWindowVisibility() } }
        guard model.commandClient.isCurrentSelectionRequest(capture.request) else { return }
        let chat = capture.chatWindow
        if !model.isResearchPanelOpen || researchWindow?.window !== chat || !chat.isVisible || chat.isMiniaturized {
            model.commandClient.cancelResearchSelectionCapture()
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let allowed = capture.phase.permits(front, owner: getpid(), source: capture.source.pid)
        let sourceStillBound = capture.source.hasSameDocument()
        let checked = allowed && sourceStillBound ? result : .failure(SelectionCaptureError.sourceChanged)
        switch checked {
        case .success(let read):
            model.commandClient.finishResearchSelectionCapture(capture.request, result: .success(read.material), clipboard: read.clipboard)
            ResearchSelectionTrace.mark(id, model.commandClient.appMaterial?.id == read.material.id ? "material-saved" : "material-not-saved")
        case .failure(let error):
            model.commandClient.finishResearchSelectionCapture(capture.request, result: .failure(error))
            ResearchSelectionTrace.failure(id, "capture-failed", error)
        }
        if front == getpid() {
            _ = focusSelectionEditor(in: chat)
        } else if capture.phase.shouldReturn(from: front, source: capture.source.pid, sourceStillBound: sourceStillBound) {
            returnToSelectionWindow(chat, from: capture.source.pid, requestID: id)
        }
    }

    private func focusSelectionEditor(in chat: NSWindow) -> Bool {
        guard model.isResearchPanelOpen, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
              researchWindow?.focusAfterSelection(in: chat) == true else { return false }
        model.focusComposerEditor()
        return true
    }

    private func returnToSelectionWindow(_ chat: NSWindow, from sourcePID: pid_t, requestID: UUID) {
        guard selectionWindowReturn == nil, model.isResearchPanelOpen, researchWindow?.window === chat,
              chat.isVisible, !chat.isMiniaturized, chat.attachedSheet == nil,
              let source = NSWorkspace.shared.frontmostApplication, source.processIdentifier == sourcePID else { return }
        selectionWindowReturn = SelectionWindowReturn(id: requestID, sourcePID: sourcePID, chatWindow: chat)
        // Transfer activation from this particular reader. An asynchronous
        // LaunchServices reopen can arrive after the user has switched to Finder.
        guard NSRunningApplication.current.activate(from: source, options: []) else {
            selectionWindowReturn = nil
            return
        }
        finishSelectionWindowReturn()
        guard selectionWindowReturn?.id == requestID, researchWindow?.isKeepingSelectionVisible == true else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.selectionWindowReturn?.id == requestID else { return }
            self.finishSelectionWindowReturn()
            if self.selectionWindowReturn?.id == requestID {
                self.selectionWindowReturn = nil
                self.finishSelectionWindowVisibility()
            }
        }
    }

    private func finishSelectionWindowReturn() {
        guard let pending = selectionWindowReturn,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
        selectionWindowReturn = nil
        if focusSelectionEditor(in: pending.chatWindow) {
            ResearchSelectionTrace.mark(pending.id, "composer-focused")
        }
        finishSelectionWindowVisibility()
    }

    private func finishSelectionWindowVisibility() {
        guard researchWindow?.endSelectionVisibility() == true else { return }
        updateResearchForeground()
    }

    private func activateResearchComposer() {
        model.openComposer(focus: true)
        focusResearchPanel()
    }

    private func activateResearchComposerFromPet() {
        ResearchLaunchLog.write("pet-chat-clicked")
        activateResearchComposer()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),
              Bundle.main.bundleURL.pathExtension == "app" else { return }

        // A click in a nonactivating panel may restore the window without activating
        // its app. Ask Launch Services to reopen the same running bundle, like its Dock icon.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    @objc private func selectionForegroundChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        recordSelectionForeground(app)
        let front = app?.processIdentifier
        if let pending = selectionWindowReturn, front != getpid(), front != pending.sourcePID {
            selectionWindowReturn = nil
            finishSelectionWindowVisibility()
        } else if front == getpid() {
            finishSelectionWindowReturn()
        }
        if let capture = selectionCapture {
            if !capture.phase.permits(front, owner: getpid(), source: capture.source.pid) {
                cancelSelectionCapture(interrupted: true)
            }
        }
    }

    private func recordSelectionForeground(_ application: NSRunningApplication?) {
        if application?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // Preserve a window identity already captured before the user-triggered raise.
            if panelSelectionOrigin?.app.processIdentifier != lastExternalApplication?.processIdentifier {
                panelSelectionOrigin = lastExternalApplication.flatMap { app in
                    ResearchSelectionCapture.target(app).map { (app, $0) }
                }
            }
        } else {
            lastExternalApplication = application?.activationPolicy == .regular ? application : nil
            panelSelectionOrigin = nil
        }
    }

    /// macOS hands the user's exact selection to this service on a private
    /// board. No source document identifier accompanies that payload.
    @objc func previewResearchSelection(
        _ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        if let service = safariSelectionService {
            guard service.reply == nil else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard let active = selectionCapture, active.request.id == service.requestID,
                  model.commandClient.isCurrentSelectionRequest(active.request),
                  active.phase.permits(front, owner: getpid(), source: active.source.pid),
                  !service.interrupted else {
                // We cannot tell which invocation supplied an unbound board.
                // Clearing the reservation here could expose an even later
                // automatic reply to the normal, manually invoked handler.
                ResearchSelectionTrace.mark(service.requestID, "safari-private-service-reply-expired")
                error.pointee = "上一次 Safari 文字服务尚未确认结束。请重开科研助手后再使用系统文字服务。" as NSString
                return
            }
            service.reply = Result {
                let text = try ResearchSelectionCapture.serviceSelectionText(from: pasteboard)
                let material = try service.document.serviceMaterial(text)
                ResearchSelectionTrace.mark(service.requestID, "safari-private-service-selection-verified", text.utf16.count)
                return material
            }
            return
        }
        cancelSelectionCapture()
        let command = model.commandClient
        guard let request = command.beginResearchSelectionCapture() else { activateResearchComposer(); return }
        do {
            let text = try ResearchSelectionCapture.serviceSelectionText(from: pasteboard)
            let selected = try ResearchSelectionCapture.exactSelection(text, source: ResearchMaterial.selectionServiceSource,
                                                                        title: "正文已取得 · 出处未确认")
            command.finishResearchSelectionCapture(request, result: .success(selected))
        } catch let issue {
            command.finishResearchSelectionCapture(request, result: .failure(issue))
            error.pointee = issue.localizedDescription as NSString
        }
        activateResearchComposer()
    }

    /// 菜单头部的状态色点：纯色实心圆，颜色跟随 mood。
    private static func makeColoredDot(color: Color, size: CGFloat = 10) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.12, dy: size * 0.12)).fill()
            return true
        }
    }

    // MARK: - 主菜单（手动补齐，替代 SwiftUI 自动生成的菜单）

    /// 无 SwiftUI App 场景后手动建立标准主菜单：
    /// 保证「设置…（⌘,）」与文本输入框的剪切/复制/粘贴等快捷键可用。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于科研助手", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(makeMenuItem(
            title: "输入消息",
            selector: #selector(showComposer)
        ))
        appMenu.addItem(makeMenuItem(
            title: "新建会话",
            selector: #selector(newSessionFromMenu)
        ))
        appMenu.addItem(makeMenuItem(
            title: "选择工作区",
            selector: #selector(selectWorkspaceFromMenu)
        ))
        appMenu.addItem(makeMenuItem(
            title: "打开 DSH",
            selector: #selector(openHarnessFromMenu)
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(makeMenuItem(title: "设置…", selector: #selector(toggleSettingsPanel), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏科研助手", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出科研助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(makeMenuItem(title: "固定窗口", selector: #selector(toggleResearchWindowPin)))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Harness 输入入口

    @objc private func newSessionFromMenu() {
        model.startNewSession()
        focusResearchPanel()
    }

    @objc private func selectWorkspaceFromMenu() {
        model.openComposer()
        focusResearchPanel()
    }

    @objc private func openHarnessFromMenu() {
        model.openHarness()
    }

    // MARK: - 设置面板

    /// 打开/关闭设置面板（菜单栏「设置…」）
    @objc func toggleSettingsPanel() {
        if let settingsPanel, settingsPanel.isVisible {
            settingsPanel.orderOut(nil)
            return
        }
        openSettingsPanel()
    }

    private func openSettingsPanel() {
        let panel: NSPanel
        if let existing = settingsPanel {
            panel = existing
        } else {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: SettingsPanelView.initialSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            p.title = "科研助手设置"
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentMinSize = SettingsPanelView.minimumSize
            p.setFrameAutosaveName("DSHPetSettingsSidebar")
            let hosting = NSHostingView(rootView: SettingsPanelView(model: model))
            hosting.sizingOptions = []
            p.contentView = hosting
            p.center()
            settingsPanel = p
            panel = p
        }
        // 设置面板需要能输入（TextField 等），临时激活本 app
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        appLog.info("settings panel opened")
    }

    private static func existingInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != ownPID && !$0.isTerminated }
    }
}
