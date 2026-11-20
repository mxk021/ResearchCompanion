import Combine
import Darwin
import Foundation

enum ResearchNoteStorageError: LocalizedError {
    case directoryUnavailable
    case directoryDenied
    case filenameInUse
    case invalidFilename
    case diskFull
    case fileSystem(Int32)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable: "笔记目录已移动、删除或离线。请选择可用的目录。"
        case .directoryDenied: "没有权限写入笔记目录。请检查目录权限或选择其他目录。"
        case .filenameInUse: "已有同名文件。请输入不同的文件名。"
        case .invalidFilename: "请输入有效的 Markdown 文件名。"
        case .diskFull: "存储空间不足，笔记未保存。"
        case .fileSystem(let code): "无法写入笔记。\(POSIXErrorCode(rawValue: code).map { POSIXError($0).localizedDescription } ?? "系统错误 \(code)")"
        }
    }

    static func atWrite(_ code: Int32) -> Self {
        switch code {
        case EACCES, EPERM, EROFS: .directoryDenied
        case ENOENT, ENOTDIR, ELOOP, ESTALE: .directoryUnavailable
        case ENOSPC, EDQUOT: .diskFull
        default: .fileSystem(code)
        }
    }
}

struct ResearchNoteDirectory: Codable, Sendable, Equatable {
    let path: String
    private let bookmark: Data

    init(_ folder: URL) throws {
        let directory = folder.resolvingSymlinksInPath()
        try Self.check(directory)
        path = directory.path
        // The installed app is unsandboxed. A native bookmark tracks the folder
        // selected in NSOpenPanel without a path-only fallback after a failure.
        bookmark = try directory.bookmarkData(options: .minimalBookmark)
    }

    func resolve() throws -> URL {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else {
            throw ResearchNoteStorageError.directoryUnavailable
        }
        try Self.check(url)
        return url
    }

    private static func check(_ url: URL) throws {
        guard url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw ResearchNoteStorageError.directoryUnavailable
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw ResearchNoteStorageError.directoryDenied
        }
    }
}

@MainActor
final class ResearchNoteSettings: ObservableObject {
    static let shared = ResearchNoteSettings()
    private static let key = "research.notes.defaultDirectory"

    @Published private(set) var directory: ResearchNoteDirectory?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        directory = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ResearchNoteDirectory.self, from: $0) }
    }

    func setDirectory(_ directory: ResearchNoteDirectory) throws {
        defaults.set(try JSONEncoder().encode(directory), forKey: Self.key)
        self.directory = directory
    }

    func clearDirectory() {
        defaults.removeObject(forKey: Self.key)
        directory = nil
    }
}

enum ResearchNoteRevealError: LocalizedError, Equatable {
    case missing
    case replaced
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .missing: "原保存位置找不到这份笔记。笔记可能已移动或删除。"
        case .replaced: "原保存位置已是另一份文件，无法定位刚保存的笔记。"
        case .permissionDenied: "无法访问笔记目录。请检查目录权限。"
        case .unavailable: "笔记所在位置暂时无法访问。"
        }
    }

    static func atLookup(_ code: Int32) -> Self {
        switch code {
        case ENOENT, ENOTDIR: .missing
        case EACCES, EPERM: .permissionDenied
        default: .unavailable
        }
    }
}

enum ResearchNoteStorage {
    fileprivate struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let createdAt: Int
        let createdNanoseconds: Int

        init(_ metadata: stat) {
            device = metadata.st_dev
            inode = metadata.st_ino
            createdAt = metadata.st_birthtimespec.tv_sec
            createdNanoseconds = metadata.st_birthtimespec.tv_nsec
        }
    }

    struct Saved: Sendable {
        let url: URL
        let renamedForCollision: Bool
        fileprivate let identity: FileIdentity

        /// Check the saved object again on explicit reveal. The path is the
        /// destination from the exclusive rename, never from WebKit or the
        /// current output directory setting.
        func revealTarget() throws -> URL {
            let folder = url.deletingLastPathComponent()
            guard access(folder.path, R_OK | X_OK) == 0 else {
                throw ResearchNoteRevealError.atLookup(errno)
            }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                throw ResearchNoteRevealError.atLookup(errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFREG, FileIdentity(metadata) == identity else {
                throw ResearchNoteRevealError.replaced
            }
            return url
        }

        var status: String {
            let name = url.lastPathComponent
            return renamedForCollision ? "已保存 \(name)，保留了已有的同名笔记" : "已保存 \(name)"
        }
    }

    static func suggestedName(title: String?, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let blocked = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let label = (title ?? "") as NSString
        let materialExtensions = ["pdf", "txt", "text", "md", "markdown"]
        let stem = materialExtensions.contains(label.pathExtension.lowercased())
            ? label.deletingPathExtension : label as String
        let name = stem.precomposedStringWithCanonicalMapping.unicodeScalars
            .map { blocked.contains($0) ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        var compact = ""
        for character in name {
            guard compact.utf8.count + character.utf8.count <= 90 else { break }
            compact.append(character)
        }
        let subject = compact.trimmingCharacters(in: .whitespaces)
        return "\(formatter.string(from: date)) - \(subject.isEmpty ? "科研笔记" : subject)"
    }

    static func save(_ markdown: String, in directory: URL, suggestedName: String) throws -> Saved {
        try write(markdown, in: directory, filename: suggestedName + ".md", chooseUniqueName: true)
    }

    static func saveAs(_ markdown: String, to destination: URL) throws -> Saved {
        try write(markdown, in: destination.deletingLastPathComponent(),
                  filename: destination.lastPathComponent, chooseUniqueName: false)
    }

    private static func write(_ markdown: String, in directory: URL, filename: String,
                              chooseUniqueName: Bool) throws -> Saved {
        guard directory.isFileURL, filename.lowercased().hasSuffix(".md"), filename.count > 3,
              !filename.contains("/"), !filename.contains(":"), !filename.unicodeScalars.contains(where: { $0.value == 0 }),
              filename.utf8.count <= Int(NAME_MAX) else { throw ResearchNoteStorageError.invalidFilename }

        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw ResearchNoteStorageError.atWrite(errno) }
        defer { close(folder) }
        let stage = ".research-note-\(UUID().uuidString).tmp"
        let handle = openat(folder, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard handle >= 0 else { throw ResearchNoteStorageError.atWrite(errno) }
        defer { unlinkat(folder, stage, 0) }
        let output = FileHandle(fileDescriptor: handle, closeOnDealloc: true)
        try output.write(contentsOf: Data(markdown.utf8))
        try output.synchronize()
        var metadata = stat()
        guard fstat(handle, &metadata) == 0 else { throw ResearchNoteStorageError.atWrite(errno) }
        let identity = FileIdentity(metadata)
        try output.close()

        let stem = String(filename.dropLast(3))
        for attempt in 1...(chooseUniqueName ? 1000 : 1) {
            let candidate = attempt == 1 ? filename : "\(stem) - \(attempt).md"
            // Exclusive rename publishes a complete note without replacing an
            // existing file, even when two windows save at the same instant.
            if renameatx_np(folder, stage, folder, candidate, UInt32(RENAME_EXCL)) == 0 {
                return Saved(url: directory.appendingPathComponent(candidate),
                             renamedForCollision: attempt > 1, identity: identity)
            }
            let error = errno
            guard error == EEXIST else { throw ResearchNoteStorageError.atWrite(error) }
        }
        throw ResearchNoteStorageError.filenameInUse
    }
}
