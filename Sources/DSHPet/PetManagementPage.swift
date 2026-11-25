import AppKit
import SwiftUI

/// Settings page for importing and maintaining Codex v2 pet packages.
struct PetManagementPage: View {
    @ObservedObject var settings: PetSettings
    @ObservedObject var library: CustomPetLibrary
    let wide: Bool

    @State private var pendingPackage: PendingPackage?
    @State private var petToDelete: ImportedPet?
    @State private var packagePreviewMood = "idle"
    @State private var message: String?
    @State private var messageIsError = false

    private struct PendingPackage {
        let package: ValidatedPetPackage
    }

    var body: some View {
        SettingsColumns(wide: wide) {
            petList
        } detail: {
            previewPanel
        }
        .onAppear {
            ensureCurrentSkinAvailable()
            if let error = library.loadError { setMessage(error, isError: true) }
        }
        .onChange(of: library.pets) { ensureCurrentSkinAvailable() }
        .alert("删除宠物？", isPresented: Binding(
            get: { petToDelete != nil },
            set: { if !$0 { petToDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let pet = petToDelete { delete(pet) }
                petToDelete = nil
            }
            Button("取消", role: .cancel) { petToDelete = nil }
        } message: {
            Text("只会删除 Research Companion 保存的副本，不会修改原始宠物包。")
        }
    }

    private var petList: some View {
        SettingsCard(title: "已导入的宠物") {
            HStack(spacing: 8) {
                Button {
                    choosePackage()
                } label: {
                    Label("导入宠物", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    refreshLibrary()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            Text("选择包含 pet.json 的文件夹。也可以从 ~/.codex/pets 中选择已安装的 Codex 宠物。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsRule()
            if library.pets.isEmpty {
                Text("还没有导入宠物")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(library.pets) { pet in
                        ImportedPetRow(
                            pet: pet,
                            atlas: library.atlas(for: pet.skin),
                            isCurrent: settings.skin == pet.skin,
                            use: { settings.skin = pet.skin },
                            remove: { petToDelete = pet }
                        )
                        if pet.id != library.pets.last?.id { SettingsRule() }
                    }
                }
            }
            if let message {
                Label(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(messageIsError ? Color.orange : Color.secondary)
            }
        }
    }

    private var previewPanel: some View {
        SettingsCard(title: "导入预览") {
            if let pendingPackage {
                SettingsPreviewField {
                    PetPackagePreview(atlas: pendingPackage.package.atlas, mood: packagePreviewMood)
                        .frame(height: 196)
                }
                HStack {
                    Text(pendingPackage.package.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 6)
                    Picker("预览状态", selection: $packagePreviewMood) {
                        Text("空闲").tag("idle")
                        Text("思考中").tag("waiting")
                        Text("完成").tag("done")
                        Text("失败").tag("failed")
                        Text("挥手").tag("wave")
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                if !pendingPackage.package.description.isEmpty {
                    Text(pendingPackage.package.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                SettingsRule()
                HStack(spacing: 8) {
                    Button("导入") { importPendingPackage() }
                        .buttonStyle(.borderedProminent)
                    Button("取消") { self.pendingPackage = nil }
                        .buttonStyle(.bordered)
                }
            } else {
                Text("选择宠物包后可先预览，再确认导入。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择 Codex 宠物包"
        panel.message = "选择包含 pet.json 的文件夹"
        let codexPetsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
        panel.directoryURL = FileManager.default.fileExists(atPath: codexPetsDirectory.path)
            ? codexPetsDirectory
            : FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let accessing = directory.startAccessingSecurityScopedResource()
        defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
        do {
            let package = try library.validatePackage(at: directory)
            pendingPackage = PendingPackage(package: package)
            packagePreviewMood = "idle"
            setMessage("已验证宠物包，可以预览后导入。", isError: false)
        } catch {
            pendingPackage = nil
            setMessage(errorMessage(for: error), isError: true)
        }
    }

    private func importPendingPackage() {
        guard let pendingPackage else { return }
        do {
            let imported = try library.importPet(pendingPackage.package)
            self.pendingPackage = nil
            setMessage("已导入“\(imported.displayName)”；点击“使用”即可切换桌宠。", isError: false)
            ensureCurrentSkinAvailable()
        } catch {
            setMessage(errorMessage(for: error), isError: true)
        }
    }

    private func refreshLibrary() {
        do {
            try library.refresh()
            ensureCurrentSkinAvailable()
            setMessage("宠物列表已刷新。", isError: false)
        } catch {
            setMessage(errorMessage(for: error), isError: true)
        }
    }

    private func delete(_ pet: ImportedPet) {
        do {
            try library.remove(pet)
            ensureCurrentSkinAvailable()
            setMessage("已删除“\(pet.displayName)”的 App 副本。", isError: false)
        } catch {
            setMessage(errorMessage(for: error), isError: true)
        }
    }

    private func ensureCurrentSkinAvailable() {
        guard case .custom = settings.skin else { return }
        if !library.pets.contains(where: { $0.skin == settings.skin }) {
            settings.skin = .defaultSkin
        }
    }

    private func setMessage(_ message: String, isError: Bool) {
        self.message = message
        messageIsError = isError
    }

    private func errorMessage(for error: Error) -> String {
        let description = error.localizedDescription
        return description.isEmpty ? "无法处理这个宠物包，请检查文件夹内容。" : description
    }
}

private struct ImportedPetRow: View {
    let pet: ImportedPet
    let atlas: CodexSpriteAtlas?
    let isCurrent: Bool
    let use: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let atlas {
                PetPackagePreview(atlas: atlas, mood: "idle")
                    .frame(width: 48, height: 58)
            } else {
                Image(systemName: "pawprint")
                    .frame(width: 48, height: 58)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(pet.displayName)
                if !pet.description.isEmpty {
                    Text(pet.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if isCurrent {
                    Text("当前使用中").font(.caption2).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 6)
            if !isCurrent {
                Button("使用", action: use).buttonStyle(.bordered).controlSize(.small)
            }
            Button("删除", action: remove)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .controlSize(.small)
                .accessibilityLabel("删除 \(pet.displayName)")
        }
        .padding(.vertical, 9)
    }
}

private struct PetPackagePreview: View {
    let atlas: CodexSpriteAtlas
    let mood: String
    @State private var startedAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let animation = mood == "wave" ? XiaoyuAnimation.wave : XiaoyuAnimation.animation(for: mood)
        TimelineView(.animation(minimumInterval: animation.minimumFrameInterval, paused: reduceMotion)) { timeline in
            if let frame = atlas.frame(for: animation, elapsed: reduceMotion ? 0 : timeline.date.timeIntervalSince(startedAt)) {
                Image(decorative: frame, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image(systemName: "pawprint.circle")
                    .font(.system(size: 38))
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: mood) { startedAt = Date() }
    }
}
