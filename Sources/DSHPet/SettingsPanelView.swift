import AppKit
import SwiftUI

/// Native macOS settings window for Research Companion.
struct SettingsPanelView: View {
    static let initialSize = CGSize(width: 1040, height: 644)
    static let minimumSize = CGSize(width: 740, height: 500)

    @ObservedObject var model: DSHPetModel
    @ObservedObject private var settings: PetSettings
    @ObservedObject private var connections: HarnessConnectionManager
    @ObservedObject private var petLibrary: CustomPetLibrary
    @Environment(\.colorScheme) private var colorScheme
    @State private var page: SettingsPage = .appearance

    init(model: DSHPetModel) {
        self.model = model
        _settings = ObservedObject(wrappedValue: PetSettings.shared)
        _connections = ObservedObject(wrappedValue: model.harnessConnections)
        _petLibrary = ObservedObject(wrappedValue: CustomPetLibrary.shared)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(page: $page, connected: model.connected)
            SettingsRule(vertical: true)
            GeometryReader { geometry in
                let inset: CGFloat = geometry.size.width >= 740 ? 36 : 24
                let wide = geometry.size.width - inset * 2 >= 740
                VStack(alignment: .leading, spacing: 0) {
                    SettingsPageHeader(page: page)
                        .padding(.horizontal, inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsRule()
                    ScrollView {
                        pageView(wide: wide)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(.horizontal, inset)
                            .padding(.vertical, 24)
                    }
                    .id(page)
                }
            }
        }
        .frame(minWidth: Self.minimumSize.width, idealWidth: Self.initialSize.width,
               minHeight: Self.minimumSize.height, idealHeight: Self.initialSize.height)
        .background(ResearchPalette(colorScheme).paper)
        .foregroundStyle(ResearchPalette(colorScheme).ink)
        .tint(ResearchPalette(colorScheme).accent)
        .accessibilityIdentifier("research-settings")
    }

    @ViewBuilder
    private func pageView(wide: Bool) -> some View {
        switch page {
        case .appearance: AppearanceSettingsPage(settings: settings, library: petLibrary, wide: wide)
        case .interaction: InteractionSettingsPage(settings: settings, wide: wide)
        case .researchNotes: ResearchNotesSettingsPage(settings: .shared)
        case .petManagement: PetManagementPage(settings: settings, library: petLibrary, wide: wide)
        case .connection: HarnessConnectionSettingsPage(model: model, connections: connections,
                                                        commandClient: model.commandClient, wide: wide)
        case .about: AboutSettingsPage(wide: wide)
        }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance = "桌宠外观"
    case interaction = "交互与提醒"
    case researchNotes = "科研笔记"
    case petManagement = "宠物管理"
    case connection = "DSH 连接"
    case about = "关于与更新"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .interaction: return "slider.horizontal.3"
        case .researchNotes: return "text.alignleft"
        case .petManagement: return "pawprint"
        case .connection: return "link"
        case .about: return "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .appearance: return "设定桌宠形象、尺寸和状态颜色。"
        case .interaction: return "管理桌宠位置、状态提醒和选区访问。"
        case .researchNotes: return "选择「保存为笔记」使用的默认目录。"
        case .petManagement: return "导入和管理兼容的 Codex 宠物包。"
        case .connection: return "选择连接来源并检查消息与状态通道。"
        case .about: return "查看版本、更新和使用帮助。"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var page: SettingsPage
    let connected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ResearchBrandMark(size: 38)
                Text("科研助手")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.25)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 22)

            VStack(spacing: 4) {
                ForEach(SettingsPage.allCases) { item in
                    if item == .connection {
                        SettingsRule().padding(.horizontal, 9).padding(.vertical, 7)
                    }
                    Button { page = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 17)
                            Text(item.rawValue).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SettingsSidebarButtonStyle(selected: page == item))
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                    .accessibilityIdentifier("research-settings.section.\(item.rawValue)")
                }
            }
            .padding(.horizontal, 12)

            Spacer()
            HStack(spacing: 8) {
                ConnectionStatusDot(connected: connected)
                    .accessibilityHidden(true)
                Text(connected ? "DSH 已连接" : "DSH 未连接")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ResearchPalette(colorScheme).secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 19)
        }
        .frame(width: 176)
        .background(ResearchPalette(colorScheme).rail)
    }
}

private struct SettingsSidebarButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let accent = ResearchPalette(colorScheme).accent
        configuration.label
            .font(.system(size: 13, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? accent : ResearchPalette(colorScheme).secondary)
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(
                accent.opacity(configuration.isPressed ? 0.19 : (selected ? 0.12 : 0)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(accent)
                        .frame(width: 2, height: 14)
                        .padding(.leading, 2)
                }
            }
    }
}

private struct SettingsPageHeader: View {
    let page: SettingsPage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(page.rawValue)
                .font(.system(size: 29, weight: .semibold))
                .tracking(-0.65)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("research-settings.section-title")
            Text(page.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(ResearchPalette(colorScheme).secondary)
        }
        .padding(.top, 22)
        .padding(.bottom, 19)
    }
}

struct SettingsRule: View {
    var vertical = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle().fill(ResearchPalette(colorScheme).rule)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

struct SettingsColumns<Main: View, Detail: View>: View {
    let wide: Bool
    @ViewBuilder let main: () -> Main
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout {
            main().frame(maxWidth: .infinity, alignment: .topLeading)
            detail().frame(width: wide ? 280 : nil)
                .frame(maxWidth: wide ? 280 : .infinity, alignment: .topLeading)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let title {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ResearchPalette(colorScheme).raised, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(ResearchPalette(colorScheme).rule, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct SettingRow<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.caption)
                        .foregroundStyle(ResearchPalette(colorScheme).secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            content
        }
    }
}

private struct ToggleSettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 11)
    }
}

private struct PetSelectionButton: View {
    let skin: FloatingPetSkin
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(skin: FloatingPetSkin, title: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.skin = skin
        self.title = title ?? skin.label
        self.selected = selected
        self.action = action
    }

    var body: some View {
        let accent = ResearchPalette(colorScheme).accent
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(selected ? accent.opacity(0.10) : ResearchPalette(colorScheme).paper,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? accent.opacity(0.52) : ResearchPalette(colorScheme).rule, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }
}

private struct ResearchNotesSettingsPage: View {
    @ObservedObject var settings: ResearchNoteSettings
    @State private var directoryProblem: String?

    var body: some View {
        SettingsCard(title: "默认 Markdown 笔记目录") {
            Label {
                Text(settings.directory?.path ?? "尚未选择目录")
                    .font(.system(size: 12, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "folder")
            }
            .foregroundStyle(.secondary)
            if let directoryProblem {
                Label(directoryProblem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("选择目录…") {
                    guard let window = NSApp.keyWindow else { return }
                    ResearchNoteActions.chooseDefaultDirectory(in: window) { result in
                        if case .failure(let error) = result { directoryProblem = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                if settings.directory != nil {
                    Button("取消默认目录") { settings.clearDirectory() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .task(id: settings.directory) {
            directoryProblem = nil
            guard let directory = settings.directory else { return }
            do {
                _ = try await Task.detached { try directory.resolve() }.value
            } catch {
                if !Task.isCancelled { directoryProblem = error.localizedDescription }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsPage: View {
    @ObservedObject var settings: PetSettings
    @ObservedObject var library: CustomPetLibrary
    let wide: Bool
    @State private var previewMood = "idle"
    @State private var showingColors = false
    @State private var showingDSHPetDetails = false
    @State private var showingStatePreview = false

    var body: some View {
        SettingsColumns(wide: wide) {
            appearanceControls
        } detail: {
            appearancePreview
        }
        .sheet(isPresented: $showingColors) {
            StatusColorsSheet(settings: settings)
        }
        .sheet(isPresented: $showingDSHPetDetails) {
            DSHPetDetailsSheet(settings: settings)
        }
        .sheet(isPresented: $showingStatePreview) {
            StatePreviewSheet(settings: settings, skin: settings.skin, mood: previewMood)
        }
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "选择桌宠") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(FloatingPetSkin.allCases) { skin in
                        PetSelectionButton(skin: skin, selected: settings.skin == skin) {
                            settings.skin = skin
                        }
                    }
                    ForEach(library.pets) { pet in
                        PetSelectionButton(skin: pet.skin, title: pet.displayName, selected: settings.skin == pet.skin) {
                            settings.skin = pet.skin
                        }
                    }
                }
            }

            SettingsCard(title: "显示与状态") {
                VStack(alignment: .leading, spacing: 0) {
                    SettingRow("桌宠大小") {
                        HStack(spacing: 8) {
                            Slider(value: Binding(
                                get: { settings.ballSize },
                                set: { settings.ballSize = ($0 / 4).rounded() * 4 }
                            ), in: 60...200)
                            .accessibilityLabel("桌宠大小")
                            TextField("桌宠大小", text: Binding(
                                get: { String(Int(settings.ballSize)) },
                                set: { if let value = Double($0) { settings.ballSize = min(max(CGFloat(value), 60), 200) } }
                            ))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 48)
                            Text("px").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 232)
                    }
                    .padding(.bottom, 11)
                    SettingsRule()
                    ToggleSettingRow(title: "显示状态气泡", detail: "在思考、等待操作和完成时显示提醒。", isOn: $settings.showStatusBubble)
                    SettingsRule()
                    ToggleSettingRow(title: "桌宠发光", detail: "随状态变化显示光晕。", isOn: $settings.glowEnabled)
                    SettingsRule()
                    Button {
                        showingColors = true
                    } label: {
                        SettingRow("状态配色") {
                            HStack(spacing: 8) {
                                ForEach(moodColorConfigs.prefix(5), id: \.mood) { config in
                                    Circle()
                                        .fill(settings.moodColors[config.mood] ?? Color(hex: config.defaultHex))
                                        .frame(width: 12, height: 12)
                                }
                                SettingsChevron()
                            }
                            .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 8)
                    if settings.skin == .classic {
                        SettingsRule()
                        Button {
                            showingDSHPetDetails = true
                        } label: {
                            SettingRow("心情球专属设置", detail: "眼睛、颜色与呼吸速度") {
                                SettingsChevron()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 11)
                    }
                }
            }
        }
    }

    private var appearancePreview: some View {
        SettingsCard(title: "效果预览") {
            SettingsPreviewField {
                PetPreview(settings: settings, library: library, mood: previewMood)
                    .frame(height: 196)
            }
            HStack {
                Picker("预览状态", selection: $previewMood) {
                    ForEach(moodColorConfigs, id: \.mood) { config in Text(config.label).tag(config.mood) }
                    Text("未连接").tag("disconnected")
                }
                .labelsHidden()
                .frame(maxWidth: 116)
                Spacer(minLength: 5)
                Button("放大 / 导出…") { showingStatePreview = true }
                    .buttonStyle(.link)
            }
            SettingsRule()
            Button("重置桌宠位置") {
                NotificationCenter.default.post(name: .dshPetResetPosition, object: nil)
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

struct SettingsPreviewField<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            let accent = ResearchPalette(colorScheme).accent
            let rim = ResearchPalette(colorScheme).rule
            RadialGradient(colors: [accent.opacity(0.11), ResearchPalette(colorScheme).paper], center: .center,
                           startRadius: 0, endRadius: 145)
            Canvas { context, size in
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.40
                for scale in [CGFloat(0.45), 0.73, 1.0] {
                    let r = radius * scale
                    context.stroke(Path(ellipseIn: CGRect(x: middle.x - r, y: middle.y - r, width: r * 2, height: r * 2)),
                                   with: .color(rim.opacity(0.8)), lineWidth: 1)
                }
                var axes = Path()
                axes.move(to: CGPoint(x: middle.x - radius - 8, y: middle.y))
                axes.addLine(to: CGPoint(x: middle.x + radius + 8, y: middle.y))
                axes.move(to: CGPoint(x: middle.x, y: middle.y - radius - 8))
                axes.addLine(to: CGPoint(x: middle.x, y: middle.y + radius + 8))
                context.stroke(axes, with: .color(rim.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
            }
            .accessibilityHidden(true)
            content().frame(maxWidth: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ResearchPalette(colorScheme).rule, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct PetPreview: View {
    @ObservedObject var settings: PetSettings
    @ObservedObject var library: CustomPetLibrary
    let mood: String
    @State private var phase = false
    private var previewColor: Color { settings.moodColors[mood] ?? settings.disconnectedColor }

    init(settings: PetSettings, mood: String) {
        self.init(settings: settings, library: .shared, mood: mood)
    }

    init(settings: PetSettings, library: CustomPetLibrary, mood: String) {
        _settings = ObservedObject(wrappedValue: settings)
        _library = ObservedObject(wrappedValue: library)
        self.mood = mood
    }

    var body: some View {
        GeometryReader { geometry in
            let bubbleHeight: CGFloat = settings.showStatusBubble && mood != "idle" ? 34 : 0
            let heightFactor: CGFloat = settings.skin.isSprite ? (settings.glowEnabled ? 1.55 : 1.10) : 1
            let widthFactor: CGFloat = settings.skin.isSprite && settings.glowEnabled ? 1.55 : 1
            let previewSize = min(settings.ballSize, min(
                max(1, geometry.size.height - bubbleHeight) / (heightFactor * 1.02),
                max(1, geometry.size.width - 20) / (widthFactor * 1.02)
            ))
            let customAvailable: Bool = {
                if case .custom = settings.skin {
                    return library.atlas(for: settings.skin) != nil
                }
                return true
            }()

            VStack(spacing: 4) {
                if settings.showStatusBubble {
                    let label = mood == "disconnected" ? "未连接" : moodColorConfigs.first(where: { $0.mood == mood })?.label
                    if let label, mood != "idle" {
                        Text(label).font(.caption.weight(.medium)).foregroundStyle(.primary)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(.thinMaterial, in: Capsule())
                            .frame(height: 30)
                    }
                }
                Group {
                    if settings.skin.isSprite && customAvailable {
                        XiaoyuSpriteView(skin: settings.skin, mood: mood, color: previewColor, size: previewSize, glowEnabled: settings.glowEnabled, interactionTriggeredAt: nil, dragDirection: nil)
                    } else {
                        DSHPetPreview(settings: settings, mood: mood, color: previewColor, diameter: previewSize)
                    }
                }
                // Center the pet itself; its glow canvas is taller and bottom-aligned.
                .frame(width: previewSize, height: previewSize, alignment: .bottom)
                .scaleEffect(phase ? 1.02 : 0.98)
                .animation(.easeInOut(duration: settings.breathingSpeed).repeatForever(autoreverses: true), value: phase)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { phase = true }
    }
}

private struct DSHPetPreview: View {
    @ObservedObject var settings: PetSettings
    let mood: String
    let color: Color
    let diameter: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [color, color.opacity(0.7)], center: .topLeading, startRadius: 0, endRadius: diameter))
                .frame(width: diameter, height: diameter)
                .shadow(color: settings.glowEnabled ? color.opacity(0.8) : .clear, radius: diameter * 0.16)
            if settings.showEyes {
                let eyeFill = StatusBallAppearance.eyeColor(for: mood, configured: settings.eyeColor.color)
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
                    let eyeScale = DSHPetView.blinkScale(at: timeline.date.timeIntervalSinceReferenceDate)
                    HStack(spacing: diameter * 0.13) {
                        Capsule().fill(eyeFill).frame(width: diameter * 0.1, height: diameter * 0.18)
                        Capsule().fill(eyeFill).frame(width: diameter * 0.1, height: diameter * 0.18)
                    }
                    .scaleEffect(y: eyeScale, anchor: .center)
                }
            }
            Circle().fill(RadialGradient(colors: [.white.opacity(0.6), .clear], center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: diameter * 0.6))
                .frame(width: diameter * 0.82, height: diameter * 0.82).blendMode(.screen)
            if StatusBallAppearance.showsStoppedRing(for: mood) {
                Circle()
                    .strokeBorder(Color.white.opacity(0.30), lineWidth: 2)
                    .frame(width: diameter + 6, height: diameter + 6)
            }
        }
    }
}

// MARK: - Interaction and colours

private struct InteractionSettingsPage: View {
    @ObservedObject var settings: PetSettings
    let wide: Bool

    var body: some View {
        SettingsColumns(wide: wide) {
            SettingsCard(title: "桌宠显示与位置") {
                VStack(alignment: .leading, spacing: 0) {
                    ToggleSettingRow(title: "显示桌宠", detail: "同时显示桌宠及其操作栏。", isOn: $settings.isPetVisible)
                    SettingsRule()
                    ToggleSettingRow(title: "记住拖拽位置", detail: "启动时恢复上次停留的位置。", isOn: $settings.rememberPosition)
                    SettingsRule()
                    ToggleSettingRow(title: "锁定位置", detail: "停用桌宠拖拽。", isOn: $settings.lockPosition)
                    SettingsRule()
                    SettingRow("恢复默认位置", detail: "将桌宠移回屏幕右下角。") {
                        Button("重置位置") {
                            NotificationCenter.default.post(name: .dshPetResetPosition, object: nil)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 11)
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "选取文字") {
                    Text("读取其他应用的选区需要辅助功能授权。也可从原应用的「服务」菜单选择「选取文字（科研助手）」。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SelectionAuthorizationView()
                }
                SettingsCard(title: "状态提醒") {
                    Text("桌宠气泡和任务卡片显示 DSH 的进度与授权请求。气泡开关与颜色可在「桌宠外观」中调整。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ColorSettingRow: View {
    let config: MoodColorConfig
    @ObservedObject var settings: PetSettings
    var body: some View {
        HStack {
            Text(config.label); Spacer()
            ColorPicker(config.label, selection: Binding(get: { settings.moodColors[config.mood] ?? Color(hex: config.defaultHex) }, set: { settings.setMoodColor(config.mood, $0) }), supportsOpacity: false).labelsHidden()
            Text(String(format: "#%06X", colorToHex(settings.moodColors[config.mood] ?? Color(hex: config.defaultHex)))).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 68, alignment: .trailing)
        }.padding(.vertical, 7)
    }
}

private struct StatusColorsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: PetSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("状态配色").font(.title2.weight(.semibold))
                    Text("自定义气泡与光晕在不同状态下的颜色。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(moodColorConfigs, id: \.mood) { config in
                        ColorSettingRow(config: config, settings: settings)
                        if config.mood != moodColorConfigs.last?.mood { Divider().opacity(0.4) }
                    }
                    Divider().padding(.vertical, 5)
                    HStack {
                        Text("未连接")
                        Spacer()
                        ColorPicker("未连接颜色", selection: $settings.disconnectedColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                    .padding(.vertical, 9)
                    Button("恢复默认颜色") { settings.resetMoodColors() }
                        .controlSize(.small).padding(.top, 12)
                }
                .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(width: 390, height: 480)
    }
}

private struct DSHPetDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: PetSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("心情球专属设置").font(.title2.weight(.semibold))
                    Text("仅影响心情球桌宠。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(.bottom, 18)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                SettingRow("呼吸速度", detail: "周期越短，呼吸越快") {
                    HStack(spacing: 10) {
                        Slider(value: $settings.breathingSpeed, in: 0.5...5, step: 0.1)
                        Text(String(format: "%.1fs", settings.breathingSpeed))
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                    }
                    .frame(width: 230)
                }
                ToggleSettingRow(title: "显示眼睛", detail: "在心情球上显示呼吸与眨眼。", isOn: $settings.showEyes)
                SettingRow("眼睛颜色") {
                    Picker("眼睛颜色", selection: $settings.eyeColor) {
                        ForEach(EyeColor.allCases) { color in Text(color.label).tag(color) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                }
            }
            .padding(.top, 18)
            Spacer()
        }
        .padding(24)
        .frame(width: 480, height: 270)
    }
}

// MARK: - Harness connection

private struct HarnessConnectionSettingsPage: View {
    @ObservedObject var model: DSHPetModel
    @ObservedObject var connections: HarnessConnectionManager
    @ObservedObject var commandClient: DSHPetCommandClient
    let wide: Bool

    private var targetBinding: Binding<String> { Binding(get: { connections.selectionID }, set: { model.selectHarnessTarget($0) }) }

    var body: some View {
        SettingsColumns(wide: wide) {
            SettingsCard(title: "当前连接") {
                HStack(alignment: .center, spacing: 11) {
                    Image(systemName: connectionIcon)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 34)
                        .accessibilityHidden(true)
                    Text(connectionDetail)
                        .font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    ConnectionStatusDot(connected: model.connected).accessibilityHidden(true)
                    Text(model.connected ? "已连接" : "未连接")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                SettingsRule()
                SettingRow("连接目标", detail: "若检测到多个实例，可在此指定目标。") {
                    Picker("连接目标", selection: targetBinding) {
                        Text("自动识别").tag("auto")
                        ForEach(connections.instances) { instance in
                            Text(instance.displayName).tag(instance.id)
                        }
                        if connections.selectionID != "auto",
                           !connections.instances.contains(where: { $0.id == connections.selectionID }) {
                            Text("选定目标（未运行）").tag(connections.selectionID)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                VStack(alignment: .leading, spacing: 0) {
                    SettingsRule()
                    ConnectionFactRow(label: "状态通道", value: model.connected ? "可用" : "不可用")
                    SettingsRule()
                    ConnectionFactRow(label: "消息通道", value: commandConnectionLabel)
                    SettingsRule()
                    ConnectionFactRow(label: "连接方式", value: model.transportKind.rawValue)
                    SettingsRule()
                }
                HStack(spacing: 8) {
                    Button { model.openHarness() } label: {
                        Label(openButtonTitle, systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent).disabled(connections.isDiscovering)
                    Button { model.refreshHarnessConnections() } label: {
                        Label(connections.isDiscovering ? "扫描中…" : "重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).disabled(connections.isDiscovering)
                    Spacer(minLength: 0)
                }
                if let message = connections.message {
                    Label(message, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = connections.openingError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "功能检查") {
                    VStack(alignment: .leading, spacing: 0) {
                        CapabilityStatusRow(icon: "list.bullet.rectangle", title: "任务状态", detail: "接收任务进度", available: model.connected)
                        SettingsRule()
                        CapabilityStatusRow(icon: "paperplane", title: "发送消息", detail: "发送到选定会话", available: commandClient.capabilitiesAvailable)
                    }
                }
                SettingsCard(title: "安装与连接") {
                    VStack(alignment: .leading, spacing: 10) {
                        ConnectionHelpStep(number: "1", text: "打开 DSH 桌面版的「插件」页。")
                        ConnectionHelpStep(number: "2", text: "安装并启用 dsh-research-companion。")
                        ConnectionHelpStep(number: "3", text: "如需重启，请等待正在运行的任务结束。")
                        ConnectionHelpStep(number: "4", text: "回到此处，选择连接目标并重新检测。")
                        Text("如果消息通道不可用，请确认 DSH 正在运行。")
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                    }
                }
            }
        }
    }

    private var connectionIcon: String {
        switch connections.effectiveInstance?.kind.rawValue {
        case "desktop": return "desktopcomputer"
        case "web": return "globe"
        default: return model.connected ? "point.3.connected.trianglepath.dotted" : "questionmark.circle"
        }
    }

    private var connectionDetail: String {
        connections.effectiveInstance?.displayName ?? "等待发现 DSH 实例"
    }
    private var commandConnectionLabel: String {
        switch commandClient.connection { case .connected: return "已连接"; case .connecting: return "连接中"; case .disconnected: return "未连接" }
    }
    private var openButtonTitle: String {
        switch connections.effectiveInstance?.kind.rawValue { case "desktop": return "打开 DSH 桌面版"; case "web": return "打开 DSH 网页版"; default: return "打开 DSH" }
    }
}

private struct ConnectionStatusDot: View {
    let connected: Bool
    var body: some View { Circle().fill(connected ? Color.green : Color.secondary.opacity(0.55)).frame(width: 7, height: 7) }
}

private struct ConnectionFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospaced()
        }
        .font(.system(size: 12))
        .padding(.vertical, 8)
    }
}

private struct CapabilityStatusRow: View {
    let icon: String
    let title: String
    let detail: String
    let available: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label(available ? "可用" : "待验证", systemImage: available ? "checkmark.circle" : "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.vertical, 9)
    }
}

private struct ConnectionHelpStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(number + ".")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - About and updates

private struct AboutSettingsPage: View {
    let wide: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var detailInk: Color {
        colorScheme == .dark ? ResearchPalette(colorScheme).secondary : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard {
                HStack(spacing: 16) {
                    ResearchBrandMark(size: 68)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("科研助手")
                            .font(.system(size: 23, weight: .semibold))
                            .tracking(-0.4)
                        Text("连接 DSH，读取文献、核对出处并保存 Markdown 笔记。")
                            .font(.system(size: 13))
                            .foregroundStyle(detailInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
            SettingsColumns(wide: wide) {
                SettingsCard(title: "版本与更新") {
                    SettingRow("当前版本") {
                        Text(UpdateChecker.currentVersion)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(detailInk)
                    }
                    SettingsRule()
                    Text("科研助手采用手动更新。版本信息请查看发行说明。")
                        .font(.caption)
                        .foregroundStyle(detailInk)
                }
            } detail: {
                SettingsCard(title: "使用帮助") {
                    if let guide = Bundle.main.url(forResource: "SETUP", withExtension: "md") {
                        Button {
                            NSWorkspace.shared.open(guide)
                        } label: {
                            Label("打开安装与使用说明", systemImage: "doc.text")
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Text("安装与使用说明见发行包内的指南。")
                            .font(.caption)
                            .foregroundStyle(detailInk)
                    }
                }
            }
        }
    }
}

private struct SelectionAuthorizationView: View {
    @State private var trusted = ResearchSelectionCapture.accessibilityAvailable
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsRule()
            Label(trusted ? "本进程已获辅助功能授权" : "本进程尚未获辅助功能授权",
                  systemImage: trusted ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading, spacing: 6) { actions }
            }
            if !trusted, ResearchSelectionCapture.identity.isAdHoc {
                Text("若旧授权仍在系统设置里，请展开代码签名详情核对路径，再移除旧条目并添加当前应用。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("代码签名详情") {
                Text(ResearchSelectionCapture.identity.description)
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 6)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .onAppear { trusted = ResearchSelectionCapture.accessibilityAvailable }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = ResearchSelectionCapture.accessibilityAvailable
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(trusted ? "重新检查" : "检查授权…") {
            trusted = ResearchSelectionCapture.accessibilityAvailable
            if !trusted { trusted = ResearchSelectionCapture.requestAccessibility() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        if !trusted {
            Button("打开辅助功能设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    openURL(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
