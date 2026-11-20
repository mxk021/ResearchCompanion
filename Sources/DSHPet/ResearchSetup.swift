import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// An explicit install or verified Community Beta upgrade. DSH owns profile locking, validation and bundle reconciliation.
struct ResearchSetup {
    static let identifier = "com.deepseek.dsh"
    static let supportedVersion = "0.2.2-rc.5"
    static let bridgeName = "dsh-research-companion"
    static let archiveName = bridgeName + "-0.2.4.tgz"
    static let download = URL(string: "https://www.deepseek.com/harness/")!
    let desktop: URL?
    let home: URL
    let archive: URL?
    var profile: URL { home.appendingPathComponent(".dsh/profiles/desktop") }
    var cli: URL? { desktop?.appendingPathComponent("Contents/Resources/runtime/cli/bin/dsh") }
    var version: String? {
        guard let desktop, let bundle = Bundle(url: desktop), bundle.bundleIdentifier == Self.identifier else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    @MainActor static func current() -> Self {
        let standard = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")
        let app = Bundle(url: standard)?.bundleIdentifier == identifier
            ? standard : NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        return Self(desktop: app, home: FileManager.default.homeDirectoryForCurrentUser,
                    archive: Bundle.main.url(forResource: archiveName, withExtension: nil))
    }

    enum BridgeState: Equatable { case uninitialized, absent, selected, upgradeable, customPrevious, disabled, invalid }
    func bridgeState() -> BridgeState {
        let file = profile.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: file.path) { return .uninitialized }
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dsh = root["dsh"] as? [String: Any], let metadata = dsh["profile"] as? [String: Any],
              let bundles = metadata["bundles"] as? [String] else { return .invalid }
        let dependency = (root["dependencies"] as? [String: String])?[Self.bridgeName]
        if bundles.contains(Self.bridgeName) {
            guard let dependency else { return .invalid }
            let package = profile.appendingPathComponent("node_modules/" + Self.bridgeName)
            guard let manifest = try? Data(contentsOf: package.appendingPathComponent("package.json")),
                  let installed = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any],
                  installed["name"] as? String == Self.bridgeName else { return .invalid }
            if installed["version"] as? String == "0.2.3" {
                return isOriginalCommunityBridge(dependency, installed: package) ? .upgradeable : .customPrevious
            }
            return .selected
        }
        return dependency == nil ? .absent : .disabled
    }

    /// Limit in-place upgrades to the unmodified bridge installed by the previous public release.
    private func isOriginalCommunityBridge(_ dependency: String, installed: URL) -> Bool {
        let previousDigest = "fed8184516967505b5a747ca0c76a0580854dca8f467bc8c6c050d7812900f72"
        guard dependency.hasPrefix("file:") else { return false }
        let pathname = String(dependency.dropFirst("file:".count))
        let resolved = (pathname as NSString).isAbsolutePath ? URL(fileURLWithPath: pathname) : profile.appendingPathComponent(pathname)
        let original = home.appendingPathComponent(".dsh/local-plugins/ResearchCompanion/" + previousDigest)
            .appendingPathComponent(Self.bridgeName + "-0.2.3.tgz")
        guard resolved.standardizedFileURL == original.standardizedFileURL,
              original.resolvingSymlinksInPath().standardizedFileURL == original.standardizedFileURL,
              let bytes = try? Data(contentsOf: original), SHA256.hash(data: bytes).hexString == previousDigest else { return false }
        // A replaced entry point, manifest, UI or cordis patch may belong to a
        // private integration even when the old tarball is still in place.
        var executable = SHA256()
        for path in ["cordis.patch.yml", "lib/client.js", "lib/index.js", "lib/ResearchContext.js", "lib/ResearchSessionIndex.js", "package.json"] {
            guard let data = try? Data(contentsOf: installed.appendingPathComponent(path)) else { return false }
            executable.update(data: data)
            executable.update(data: Data([0]))
        }
        return executable.finalize().hexString == "f984135ea2b42a75ba36750602483e2cc281007aa6ab4e425570ecd8f8ac0555"
    }

    enum Failure: LocalizedError {
        case detail(String)
        var errorDescription: String? {
            switch self { case .detail(let message): return message }
        }
    }

    func install() throws {
        guard let desktop, version == Self.supportedVersion, let cli, let archive,
              FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw Failure.detail("未找到匹配的 DSH 桌面版或随应用分发的科研桥。")
        }
        guard [.absent, .upgradeable].contains(bridgeState()) else { throw Failure.detail("桌面配置已变化。请重新检查科研桥的安装状态。") }
        // Limit executable trust to the official signed desktop distribution validated for this release.
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", "-R",
                            "=anchor apple generic and identifier \"com.deepseek.dsh\" and certificate leaf[subject.OU] = \"NAN929V4UM\"",
                            desktop.path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else { throw Failure.detail("DSH 的签名与已验证发行方不匹配。请检查官方安装包。") }

        // Keep the file: dependency valid after ejecting the DMG or moving the app.
        let bytes = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let directory = home.appendingPathComponent(".dsh/local-plugins/ResearchCompanion/" + digest)
        let destination = directory.appendingPathComponent(Self.archiveName)
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
            throw Failure.detail("本地插件目录重定向到了其他位置，安装已停止。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: destination.path) {
            guard destination.resolvingSymlinksInPath().standardizedFileURL == destination.standardizedFileURL,
                  try Data(contentsOf: destination) == bytes else { throw Failure.detail("已有同名插件包的内容或位置不匹配。") }
        } else {
            try bytes.write(to: destination, options: .withoutOverwriting)
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.identifier).contains(where: { !$0.isTerminated }) else {
            throw Failure.detail("请先保存工作并从应用菜单正常退出 DSH，再更新科研桥。")
        }
        let operation = Process()
        operation.executableURL = cli
        operation.arguments = ["plugin", "--profile", "desktop", "add", "--offline", "--ignore-scripts", "file:" + destination.path]
        operation.environment = ["HOME": home.path, "DSH_HOME": home.appendingPathComponent(".dsh").path,
                                 "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
        operation.currentDirectoryURL = directory
        operation.standardInput = FileHandle.nullDevice
        operation.standardOutput = FileHandle.nullDevice
        operation.standardError = FileHandle.nullDevice
        try operation.run()
        operation.waitUntilExit()
        guard operation.terminationStatus == 0, bridgeState() == .selected,
              FileManager.default.fileExists(atPath: profile.appendingPathComponent("node_modules/" + Self.bridgeName + "/lib/index.js").path) else {
            throw Failure.detail("DSH 未确认科研桥安装成功。请检查桌面 profile 的插件诊断和可用磁盘空间，再点重新检查。")
        }
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

struct ResearchSetupView: View {
    @State private var environment = ResearchSetup.current()
    @State private var bridge: ResearchSetup.BridgeState = .uninitialized
    @State private var isRunning = false
    @State private var installing = false
    @State private var issue: String?
    private var compatible: Bool { environment.version == ResearchSetup.supportedVersion }
    private var guidance: String {
        guard let version = environment.version else { return "问答需要 DeepSeek Harness 桌面版。先从开发者网站取得兼容版本。" }
        guard compatible else { return "当前 DSH 为 " + version + "。已验证版本为 " + ResearchSetup.supportedVersion + "，请先核对版本。" }
        switch bridge {
        case .uninitialized: return "请先打开 DSH，等待桌面初始化，然后从其应用菜单正常退出。"
        case .absent: return isRunning ? "请先保存工作并正常退出 DSH，待其退出后安装本地科研桥。" : "安装科研桥后，重新打开 DSH 即会创建本账号的科研工作区。"
        case .upgradeable: return isRunning ? "请先保存工作并正常退出 DSH，再更新原公开版科研桥。" : "可将旧版科研桥更新到应用随附版本，保留原科研工作区和会话。"
        case .customPrevious: return "现有科研桥由其他方式维护。请按原安装方式更新文档取证接口，保留原插件和本机定制。"
        case .selected: return isRunning ? "科研桥已登记。等待 DSH 就绪；如仍未连接，请在 DSH 插件页检查加载情况。" : "科研桥已登记。请打开 DSH，然后在会话模型菜单选择已授权模型。"
        case .disabled: return "科研桥已安装但未启用。请在 DSH 的桌面插件页启用原有科研桥。"
        case .invalid: return "桌面 profile 无法识别。请先在 DSH 中检查现有配置。"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接科研助手").font(.headline)
            Text(guidance).fixedSize(horizontal: false, vertical: true)
            if let issue { Text(issue).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if environment.version == nil || !compatible {
                    Link("DSH 官方下载", destination: ResearchSetup.download)
                } else if [.absent, .upgradeable].contains(bridge) && !isRunning {
                    Button(installing ? "正在安装…" : bridge == .upgradeable ? "更新科研桥" : "安装科研桥") { install() }.disabled(installing)
                } else if !isRunning, let desktop = environment.desktop {
                    Button("打开 DSH") { NSWorkspace.shared.openApplication(at: desktop, configuration: .init()) { _, _ in } }
                }
                Button("重新检查") { refresh() }.disabled(installing)
            }
            if let guide = Bundle.main.url(forResource: "SETUP", withExtension: "md") {
                Link("查看完整安装说明", destination: guide)
            }
        }
        .font(.callout).padding(14).frame(width: 320, alignment: .leading)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refresh() }
    }

    private func refresh() {
        environment = .current()
        isRunning = NSRunningApplication.runningApplications(withBundleIdentifier: ResearchSetup.identifier).contains { !$0.isTerminated }
        bridge = environment.bridgeState()
    }

    private func install() {
        refresh()
        guard compatible, !isRunning, !installing, [.absent, .upgradeable].contains(bridge) else { return }
        let setup = environment
        installing = true
        issue = nil
        Task {
            do { try await Task.detached(priority: .userInitiated) { try setup.install() }.value }
            catch { issue = error.localizedDescription }
            installing = false
            refresh()
        }
    }
}
