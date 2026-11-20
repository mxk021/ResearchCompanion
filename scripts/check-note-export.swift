import Foundation

/// Compile with Sources/DSHPet/ResearchNoteStorage.swift. All note files use a
/// temporary directory and the settings check uses a unique preferences suite.
@main
private struct ResearchNoteCheck {
    private struct Failure: Error {
        let message: String
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    @MainActor static func main() async throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("ResearchNoteCheck-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("笔记")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let directory = try ResearchNoteDirectory(folder)

        let suite = "ResearchNoteCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ResearchNoteSettings(defaults: defaults)
        try settings.setDirectory(directory)
        let reloaded = ResearchNoteSettings(defaults: UserDefaults(suiteName: suite)!)
        try check(try reloaded.directory?.resolve().standardizedFileURL.path == folder.standardizedFileURL.path,
                  "Saved bookmark does not resolve from restored preferences")

        let name = ResearchNoteStorage.suggestedName(title: "../含公式: 论文/第一章", at: Date(timeIntervalSince1970: 5))
        try check(name.contains("含公式 论文 第一章") && !name.contains("/") && !name.contains(":"),
                  "Suggested filename is not readable and path-safe")
        let fileTitle = ResearchNoteStorage.suggestedName(title: "Calibration.MD", at: Date(timeIntervalSince1970: 5))
        try check(fileTitle.hasSuffix(" - Calibration"), "An imported filename duplicated the note extension")
        let note = """
        # 科研笔记

        ## AI 解释

        $\u{005c}frac{1}{x}$

        ## 材料来源与原文摘录

        > 原文不能被改动。
        """
        let prior = folder.appendingPathComponent(name + ".md")
        try "已有笔记".write(to: prior, atomically: true, encoding: .utf8)
        let first = try ResearchNoteStorage.save(note, in: folder, suggestedName: name)
        try check(first.renamedForCollision && first.url != prior, "Quick save did not report the existing filename")
        try check(try first.revealTarget() == first.url, "Quick save did not reveal the newly chosen name")
        let hiddenDirectory: [FileAttributeKey: Any] = [.posixPermissions: 0o300]
        try fm.setAttributes(hiddenDirectory, ofItemAtPath: folder.path)
        do {
            _ = try first.revealTarget()
            throw Failure(message: "Reveal accepted a directory that Finder cannot list")
        } catch ResearchNoteRevealError.permissionDenied {}
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try check(try String(contentsOf: first.url, encoding: .utf8) == note, "Markdown and LaTeX bytes changed on save")
        try check(try String(contentsOf: prior, encoding: .utf8) == "已有笔记", "Quick save replaced an existing note")
        do {
            _ = try ResearchNoteStorage.saveAs(note, to: prior)
            throw Failure(message: "Save As replaced an existing note")
        } catch ResearchNoteStorageError.filenameInUse {}
        let alternate = scratch.appendingPathComponent("另存为.md")
        let other = try ResearchNoteStorage.saveAs(note, to: alternate)
        try check(try other.revealTarget() == alternate, "Save As did not reveal the actual destination")
        let moved = scratch.appendingPathComponent("Moved.md")
        try fm.moveItem(at: alternate, to: moved)
        do {
            _ = try other.revealTarget()
            throw Failure(message: "Reveal selected an old path after the note was moved")
        } catch ResearchNoteRevealError.missing {}
        try "替换文件".write(to: alternate, atomically: true, encoding: .utf8)
        do {
            _ = try other.revealTarget()
            throw Failure(message: "Reveal selected the unrelated file at the old path")
        } catch ResearchNoteRevealError.replaced {}
        try fm.removeItem(at: alternate)
        try fm.createSymbolicLink(at: alternate, withDestinationURL: moved)
        do {
            _ = try other.revealTarget()
            throw Failure(message: "Reveal selected a symlink at the old path")
        } catch ResearchNoteRevealError.replaced {}

        // A conflicting symlink can be treated as an existing name, but must
        // never be traversed as a destination or be replaced by the rename.
        let link = folder.appendingPathComponent("alias.md")
        try fm.createSymbolicLink(at: link, withDestinationURL: prior)
        let aliased = try ResearchNoteStorage.save(note, in: folder, suggestedName: "alias")
        try check(aliased.renamedForCollision && (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil,
                  "Quick save modified a preexisting symlink")
        try check(try String(contentsOf: prior, encoding: .utf8) == "已有笔记", "Quick save followed a destination symlink")

        let allNames = try await withThrowingTaskGroup(of: String.self) { tasks in
            for index in 0..<8 {
                tasks.addTask {
                    try ResearchNoteStorage.save(note + "\n\(index)", in: folder, suggestedName: name).url.lastPathComponent
                }
            }
            var names = Set<String>()
            for try await result in tasks { names.insert(result) }
            return names
        }
        try check(allNames.count == 8, "Concurrent saves reused a name")
        try check(try fm.contentsOfDirectory(atPath: folder.path).allSatisfy { $0.hasSuffix(".md") },
                  "A prepared note was left behind after save or conflict")

        let substituted = scratch.appendingPathComponent("directory-link")
        try fm.createSymbolicLink(at: substituted, withDestinationURL: folder)
        do {
            _ = try ResearchNoteStorage.save(note, in: substituted, suggestedName: "Symlink check")
            throw Failure(message: "The writer followed a replacement directory symlink")
        } catch ResearchNoteStorageError.directoryUnavailable {}

        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o500]
        try fm.setAttributes(attributes, ofItemAtPath: folder.path)
        do {
            _ = try ResearchNoteStorage.save(note, in: folder, suggestedName: "Permission check")
            throw Failure(message: "Write to readonly directory unexpectedly succeeded")
        } catch ResearchNoteStorageError.directoryDenied {}
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try fm.removeItem(at: folder)
        do {
            _ = try first.revealTarget()
            throw Failure(message: "Reveal succeeded after the note and its directory were removed")
        } catch ResearchNoteRevealError.missing {}
        do {
            _ = try directory.resolve()
            throw Failure(message: "Deleted directory was still offered as valid")
        } catch ResearchNoteStorageError.directoryUnavailable {}
        reloaded.clearDirectory()
        try check(ResearchNoteSettings(defaults: defaults).directory == nil, "Clearing the default directory did not persist")

        print("Note export: persisted bookmark, exact Markdown, Save As, collision and symlink protection, eight parallel saves, permissions, missing folder, and exact Finder targets after move, replacement, or permission change.")
    }
}
