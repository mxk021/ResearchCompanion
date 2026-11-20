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

/// One piece of the exact evidence sent. Page numbers are physical (one-based) and
/// bounds use the PDF page's coordinate space, including a nonzero crop-box origin.
struct ResearchPDFSourcePosition: Codable, Equatable, Sendable {
    let page: Int
    let bounds: CGRect
    var column: Int? = nil
    var blockIndex: Int? = nil
    var blockRange: NSRange? = nil
    var sourceRange: NSRange? = nil
    var ocr: Bool = false
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

    func verifiedPDFData(at url: URL) -> Data? {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf",
              let bytes = try? Data(contentsOf: url, options: .uncached),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == fingerprint else { return nil }
        return bytes
    }

    func resolve() -> URL? {
        locate { matches($0) ? $0 : nil }
    }

    func verifiedPDF() -> (URL, Data)? {
        locate { url in verifiedPDFData(at: url).map { (url, $0) } }
    }

    private func locate<Value>(_ verify: (URL) -> Value?) -> Value? {
        let original = URL(fileURLWithPath: originalPath)
        if let match = verify(original) { return match }
        var stale = false
        if let bookmark,
           let moved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale),
           moved.path != originalPath {
            return verify(moved)
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
        var pdfPositions: [ResearchPDFSourcePosition]? = nil
        var backgroundPositions: [ResearchPDFSourcePosition]? = nil
        var positionDigest: String? = nil
    }

    private struct Positions: Codable {
        let primary: [ResearchPDFSourcePosition]?
        let background: [ResearchPDFSourcePosition]?
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
                                       backgroundFile: material.backgroundFile, backgroundPages: material.backgroundPages,
                                       pdfPositions: material.pdfPositions, backgroundPositions: material.backgroundPositions)
        try write(reference, to: url)
    }

    private func write(_ reference: LocalReference, to url: URL) throws {
        var header = reference
        if reference.pdfPositions != nil || reference.backgroundPositions != nil {
            let locations = Positions(primary: reference.pdfPositions, background: reference.backgroundPositions)
            let data = try JSONEncoder().encode(locations)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let sidecar = url.deletingLastPathComponent().appendingPathComponent(digest + ".positions")
            try data.write(to: sidecar, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            header.pdfPositions = nil
            header.backgroundPositions = nil
            header.positionDigest = digest
        }
        // Publish the small, backwards-readable header after its immutable position list.
        try JSONEncoder().encode(header).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read(session: String, reply: ResearchReplyContext, includePositions: Bool = true) -> LocalReference? {
        guard let id = reply.requestId, let material = reply.material,
              let url = try? location(session: session, requestID: id, create: false),
              let meta = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              meta.isRegularFile == true, meta.isSymbolicLink != true, (meta.fileSize ?? Int.max) <= 512 * 1024,
              let data = try? Data(contentsOf: url), var value = try? JSONDecoder().decode(LocalReference.self, from: data),
              value.title == material.title, value.textFingerprint == fingerprint(material.text) else { return nil }
        if includePositions, let digest = value.positionDigest,
           digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
            let sidecar = url.deletingLastPathComponent().appendingPathComponent(digest + ".positions")
            if let info = try? sidecar.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
               info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 16 * 1_048_576,
               let bytes = try? Data(contentsOf: sidecar),
               SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest,
               let positions = try? JSONDecoder().decode(Positions.self, from: bytes) {
                value.pdfPositions = positions.primary
                value.backgroundPositions = positions.background
            }
        }
        return value
    }

    func relink(session: String, reply: ResearchReplyContext, file: URL, background: Bool = false) throws {
        guard let prior = read(session: session, reply: reply, includePositions: false), let previousFile = background ? prior.backgroundFile : prior.file,
              let id = reply.requestId,
              let recordURL = try location(session: session, requestID: id, create: false),
              previousFile.matches(file) else {
            throw ResearchMaterialError.message("所选文件与发送材料时的原始文件内容不同。来源未更改。")
        }
        let replacement = try ResearchFileReference.capture(file)
        guard replacement.fingerprint == previousFile.fingerprint else {
            throw ResearchMaterialError.message("重新定位时文件内容发生了变化。")
        }
        let local = LocalReference(title: prior.title, textFingerprint: prior.textFingerprint,
                                   file: background ? prior.file : replacement, web: prior.web, pdfPages: prior.pdfPages,
                                   backgroundFile: background ? replacement : prior.backgroundFile, backgroundPages: prior.backgroundPages,
                                   pdfPositions: prior.pdfPositions, backgroundPositions: prior.backgroundPositions, positionDigest: prior.positionDigest)
        try write(local, to: recordURL)
    }

    func remove(session: String) throws {
        let parent = directory(for: session)
        if try checkedDirectory(root, create: false), try checkedDirectory(parent, create: false) {
            try FileManager.default.removeItem(at: parent)
        }
    }
}
