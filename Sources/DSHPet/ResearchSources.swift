import AppKit
import CryptoKit

struct ResearchReplyContext: Decodable, Equatable {
    let question: String
    let questionId: String
    let requestId: String?
    let time: Double?
    let material: ResearchSourceMaterial?
}

struct ResearchSourceMaterial: Decodable, Equatable {
    let key: String
    let title: String
    let text: String
    let source: String?
    let scope: String?
    let url: String?
    let pageLabel: String?
    let pageIndex: Int?
}

struct ResearchFileReference: Codable, Equatable, Sendable {
    let originalPath: String
    let bookmark: Data?
    let fingerprint: String

    struct FileStamp: Equatable, Sendable {
        let inode: UInt64
        let size: Int64
        let modified: Date?
    }

    static func fileStamp(_ url: URL) throws -> FileStamp {
        let meta = try FileManager.default.attributesOfItem(atPath: url.path)
        guard meta[.type] as? FileAttributeType == .typeRegular, let node = meta[.systemFileNumber] as? NSNumber,
              let size = meta[.size] as? NSNumber else { throw ResearchMaterialError.message("无法读取普通本机文件。") }
        return FileStamp(inode: node.uint64Value, size: size.int64Value, modified: meta[.modificationDate] as? Date)
    }

    static func capture(_ url: URL) throws -> Self {
        guard supportedType(of: url) != nil else {
            throw ResearchMaterialError.message("来源只支持 PDF、纯文本或 Markdown 文件。")
        }
        return .init(originalPath: url.path, bookmark: try? url.bookmarkData(options: .minimalBookmark),
                     fingerprint: try digest(url))
    }

    private static func supportedType(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": "pdf"
        case "txt", "text": "text"
        case "md", "markdown": "markdown"
        default: nil
        }
    }

    private static func digest(_ url: URL) throws -> String {
        let stamp = try fileStamp(url)
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" || stamp.size <= 64 * 1_048_576 else {
            throw ResearchMaterialError.message("请选择普通本机文件。")
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var read: Int64 = 0
        while let bytes = try input.read(upToCount: 512 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            read += Int64(bytes.count)
            guard read <= stamp.size else {
                throw ResearchMaterialError.message("读取时文件大小发生变化。")
            }
            hash.update(data: bytes)
        }
        guard read == stamp.size, try fileStamp(url) == stamp else {
            throw ResearchMaterialError.message("读取时文件已发生变化。")
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ url: URL) -> Bool {
        guard let type = Self.supportedType(of: URL(fileURLWithPath: originalPath)),
              type == Self.supportedType(of: url) else { return false }
        return (try? Self.digest(url)) == fingerprint
    }

    func resolve() -> URL? {
        let original = URL(fileURLWithPath: originalPath)
        if matches(original) { return original }
        var stale = false
        if let bookmark,
           let moved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale),
           moved.path != originalPath, matches(moved) {
            return moved
        }
        return nil
    }
}

/// Only the locator and the explicit OCR choice survive relaunch. Text and indexes
/// are read from the current file and never shared across DSH targets or sessions.
struct ResearchFileAttachment: Codable {
    let file: ResearchFileReference
    let recognizeScans: Bool

    static func key(host: String, workspace: String, session: String?) -> String {
        // A distinct null slot represents an as-yet-unsent composition.
        let identity = [Optional(host), Optional(workspace), session].map { item in
            item.map { String($0.utf8.count) + ":" + $0 } ?? "-"
        }.joined()
        return "research.attachedFile.v1." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ResearchSourceLocation {
    static func webURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, url.absoluteString.utf16.count <= 4096 else { return nil }
        return url
    }

    static func zoteroURL(_ material: ResearchSourceMaterial) -> URL? {
        let key = material.key.split(separator: ":", omittingEmptySubsequences: false)
        guard key.count == 4, key[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              key[1].range(of: "^[A-Z0-9]{8}$", options: .regularExpression) != nil,
              key[2].range(of: "^[A-Z0-9]{8}$", options: .regularExpression) != nil,
              key[3].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let source = material.source.flatMap(URL.init(string:)), source.scheme == "zotero", source.host == "select",
              source.user == nil, source.password == nil, source.query == nil, source.fragment == nil else { return nil }
        let path = source.path.split(separator: "/")
        let scope: String
        if path.count == 3, path[0] == "library", path[1] == "items", path[2] == key[1] {
            scope = "library"
        } else if path.count == 4, path[0] == "groups", path[2] == "items", path[3] == key[1],
                  let group = Int(path[1]), group > 0 {
            scope = "groups/\(group)"
        } else { return nil }
        let page = material.pageIndex.flatMap { (0..<1_000_000).contains($0) ? "?page=\($0 + 1)" : nil } ?? ""
        return URL(string: "zotero://open-pdf/\(scope)/items/\(key[2])\(page)")
    }
}

/// Only captures information that is unavailable in the saved bridge prompt.
/// File paths and exact web URLs stay local, bound by session, request, and excerpt.
struct ResearchProvenanceStore {
    struct LocalReference: Codable {
        let title: String
        let textFingerprint: String
        let file: ResearchFileReference?
        let web: String?
        var pdfPages: String? = nil
        var backgroundFile: ResearchFileReference? = nil
        var backgroundPages: String? = nil
    }

    init(root: URL) { self.root = root }

    static var live: Self {
        Self(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Research Companion/PrivateProvenance", isDirectory: true))
    }

    private let root: URL

    private func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func directory(for session: String) -> URL {
        root.appendingPathComponent(fingerprint(session), isDirectory: true)
    }

    private func checkedDirectory(_ url: URL, create: Bool) throws -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard create else { return false }
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let meta = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard meta.isDirectory == true, meta.isSymbolicLink != true else {
            throw ResearchMaterialError.message("本地来源目录不可安全访问。")
        }
        return true
    }

    private func location(session: String, requestID: String, create: Bool) throws -> URL? {
        let parent = directory(for: session)
        guard try checkedDirectory(root, create: create), try checkedDirectory(parent, create: create) else { return nil }
        return parent.appendingPathComponent(fingerprint(requestID) + ".json", isDirectory: false)
    }

    func record(session: String, requestID: String, material: ResearchMaterial) throws {
        let web = material.localWebURL == material.url ? nil : material.localWebURL
        guard material.fileReference != nil || web != nil || material.backgroundFile != nil else { return }
        guard let url = try location(session: session, requestID: requestID, create: true) else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else { return } // Retry keeps its original capture.
        let reference = LocalReference(title: material.title, textFingerprint: fingerprint(material.text),
                                       file: material.fileReference, web: web, pdfPages: material.pdfPages,
                                       backgroundFile: material.backgroundFile, backgroundPages: material.backgroundPages)
        try write(reference, to: url)
    }

    private func write(_ reference: LocalReference, to url: URL) throws {
        try JSONEncoder().encode(reference).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read(session: String, reply: ResearchReplyContext) -> LocalReference? {
        guard let id = reply.requestId, let material = reply.material,
              let url = try? location(session: session, requestID: id, create: false),
              let meta = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              meta.isRegularFile == true, meta.isSymbolicLink != true, (meta.fileSize ?? Int.max) <= 65536,
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(LocalReference.self, from: data),
              value.title == material.title, value.textFingerprint == fingerprint(material.text) else { return nil }
        return value
    }

    func relink(session: String, reply: ResearchReplyContext, file: URL) throws {
        guard let prior = read(session: session, reply: reply), let previousFile = prior.file, let id = reply.requestId,
              let recordURL = try location(session: session, requestID: id, create: false),
              previousFile.matches(file) else {
            throw ResearchMaterialError.message("所选文件与发送材料时的原始文件内容不同。来源未更改。")
        }
        let local = LocalReference(title: prior.title, textFingerprint: prior.textFingerprint,
                                   file: try .capture(file), web: prior.web, pdfPages: prior.pdfPages,
                                   backgroundFile: prior.backgroundFile, backgroundPages: prior.backgroundPages)
        try write(local, to: recordURL)
    }

    func remove(session: String) throws {
        let parent = directory(for: session)
        if try checkedDirectory(root, create: false), try checkedDirectory(parent, create: false) {
            try FileManager.default.removeItem(at: parent)
        }
    }
}
