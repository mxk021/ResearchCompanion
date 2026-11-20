import AppKit
import UniformTypeIdentifiers

@MainActor
enum ResearchNoteActions {
    enum Mode: String { case quick, supplement, saveAs }

    /// The caller captures the exact answer and selection before opening any sheet.
    /// Cancellation returns nil and never publishes a file or a success receipt.
    static func save(_ source: ResearchAnswerSource, selected: String?, mode: Mode,
                     in window: NSWindow) async throws -> ResearchNoteStorage.Saved? {
        let supplement: String
        if mode == .supplement {
            guard let entered = await askForSupplement(in: window) else { return nil }
            supplement = entered
        } else {
            supplement = ""
        }

        let now = Date()
        let markdown = source.markdown(interpretation: selected ?? source.answer.text, supplement: supplement, savedAt: now)
        let name = ResearchNoteStorage.suggestedName(title: source.material?.title, at: now)
        if mode == .saveAs {
            guard let destination = await chooseDestination(name: name, in: window) else { return nil }
            return try await Task.detached { try ResearchNoteStorage.saveAs(markdown, to: destination) }.value
        }

        let directory: ResearchNoteDirectory
        if let configured = ResearchNoteSettings.shared.directory {
            directory = configured
        } else {
            guard let chosen = try await pickDefaultDirectory(in: window) else { return nil }
            directory = chosen
        }
        return try await Task.detached {
            try ResearchNoteStorage.save(markdown, in: directory.resolve(), suggestedName: name)
        }.value
    }

    static func chooseDefaultDirectory(in window: NSWindow,
                                       completion: @escaping (Result<ResearchNoteDirectory, Error>) -> Void) {
        Task {
            do {
                if let chosen = try await pickDefaultDirectory(in: window) { completion(.success(chosen)) }
            } catch { completion(.failure(error)) }
        }
    }

    private static func pickDefaultDirectory(in window: NSWindow) async throws -> ResearchNoteDirectory? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目录"
        panel.message = "选择保存 Markdown 笔记的默认目录。"
        guard await panel.beginSheetModal(for: window) == .OK, let folder = panel.url else { return nil }
        let directory = try await Task.detached { try ResearchNoteDirectory(folder) }.value
        try ResearchNoteSettings.shared.setDirectory(directory)
        return directory
    }

    private static func askForSupplement(in window: NSWindow) async -> String? {
        let alert = NSAlert()
        alert.messageText = "添加笔记补充"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        field.placeholderString = "我的补充"
        field.setAccessibilityLabel("我的补充")
        alert.accessoryView = field
        alert.addButton(withTitle: "保存笔记")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private static func chooseDestination(name: String, in window: NSWindow) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = name + ".md"
        let validator = NewNoteNameValidator()
        panel.delegate = validator
        defer { withExtendedLifetime(validator) {} } // The panel holds its delegate weakly.
        guard await panel.beginSheetModal(for: window) == .OK else { return nil }
        return panel.url
    }
}

@MainActor
private final class NewNoteNameValidator: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            throw ResearchNoteStorageError.filenameInUse
        }
    }
}
