import AppKit
import CryptoKit
import Darwin
import PDFKit

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

/// A verified attachment identity from Zotero's authenticated local reader.
/// Its destination stays in the existing local evidence snapshot.
struct ResearchZoteroLocation: Codable, Equatable, Sendable {
    let library: String
    let attachmentKey: String
    let pageIndex: Int?
    let pageLabel: String?

    var physicalPage: Int? { pageIndex.flatMap { (0..<1_000_000).contains($0) ? $0 + 1 : nil } }

    var url: URL? {
        let group = library.split(separator: "/", omittingEmptySubsequences: false)
        guard library == "library" || (group.count == 2 && group[0] == "groups" &&
                  Int(group[1]).map { $0 > 0 && String($0) == group[1] } == true),
              attachmentKey.range(of: #"^[A-Z0-9]{8}$"#, options: .regularExpression) != nil else { return nil }
        let page = physicalPage.map { "?page=\($0)" } ?? ""
        return URL(string: "zotero://open-pdf/\(library)/items/\(attachmentKey)\(page)")
    }
}

/// Coverage of what was asked for. Source coordinates and content coverage
/// are separate, even when present in the same immutable material.
struct ResearchPDFEvidenceCheck: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case target, content, caption, definition, continuousRange, visual, location, relationship
    }

    enum Status: String, Codable, Sendable {
        case verified, missing, ambiguous
    }

    let kind: Kind
    let target: String
    let status: Status
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
    // Independent PDF glyphs use their own indices. Only their region is shared.
    var verifiedGlyphEngine: String? = nil
}

/// A named destination in the existing verified position arrays. Indices are
/// local to one immutable source snapshot and never enter provider requests.
struct ResearchPDFSourceGroup: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case object, caption, context }

    let role: Role
    let title: String
    let range: Range<Int>

    func positions(in primary: [ResearchPDFSourcePosition],
                   background: [ResearchPDFSourcePosition]) -> [ResearchPDFSourcePosition]? {
        let entries = role == .context ? background : primary
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= entries.count else { return nil }
        return Array(entries[range])
    }
}

struct ResearchFileReference: Codable, Equatable, Sendable {
    let originalPath: String
    let bookmark: Data?
    let fingerprint: String

    struct FileStamp: Equatable, Sendable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        let device: Int32
    }

    enum VerificationError: LocalizedError {
        case changed, unavailable, unstable

        var errorDescription: String? {
            switch self {
            case .changed: "原文件内容已更新，本次未发送。请在读取新版本后重试。"
            case .unavailable: "原文件目前无法读取，本次未发送。恢复文件位置或访问权限后，可用原草稿重试。"
            case .unstable: "核验期间原文件仍在变化，本次未发送。请在文件稳定后重试。"
            }
        }
    }

    static func fileStamp(_ url: URL) throws -> FileStamp {
        var attributes = stat()
        guard url.isFileURL, lstat(url.path, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG else {
            throw ResearchMaterialError.message("无法读取普通本机文件。")
        }
        return stamp(attributes)
    }

    private static func stamp(_ attributes: stat) -> FileStamp {
        return FileStamp(inode: attributes.st_ino, size: attributes.st_size,
                         modifiedSeconds: attributes.st_mtimespec.tv_sec, modifiedNanos: attributes.st_mtimespec.tv_nsec,
                         changedSeconds: attributes.st_ctimespec.tv_sec, changedNanos: attributes.st_ctimespec.tv_nsec,
                         device: attributes.st_dev)
    }

    static func capture(_ url: URL) throws -> Self {
        guard supportedType(of: url) != nil else {
            throw ResearchMaterialError.message("来源只支持 PDF、纯文本或 Markdown 文件。")
        }
        return .init(originalPath: url.path, bookmark: try? url.bookmarkData(options: .minimalBookmark),
                     fingerprint: try digest(url))
    }

    /// Bind the PDF position search to the same bytes as its file reference.
    /// Larger files still receive a document reference without an eager PDF parse.
    fileprivate static func snapshotSelectionPDF(_ url: URL) throws -> (Self, Data?) {
        let original = try fileStamp(url)
        guard original.size <= 16 * 1_048_576 else { return (try capture(url), nil) }
        let bytes = try withStableFile(url, matching: original) { file in
            guard let bytes = try file.read(upToCount: Int(original.size) + 1), bytes.count == original.size else {
                throw VerificationError.unstable
            }
            return bytes
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let reference = Self(originalPath: url.path, bookmark: try? url.bookmarkData(options: .minimalBookmark), fingerprint: hash)
        return (reference, bytes)
    }

    private static func supportedType(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf": "pdf"
        case "txt", "text": "text"
        case "md", "markdown": "markdown"
        default: nil
        }
    }

    /// Metadata changes only invalidate the fast path. The saved byte digest
    /// still determines whether the index describes the current material.
    func verifiedStamp(at url: URL, previous: FileStamp) throws -> FileStamp {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let current = try? Self.fileStamp(url) else { throw VerificationError.unavailable }
        if current == previous {
            // Metadata alone can still be visible after read access is revoked.
            try Self.withStableFile(url, matching: current) { _ in }
            return current
        }
        guard try Self.digest(url, expected: current) == fingerprint else { throw VerificationError.changed }
        return current
    }

    private static func digest(_ url: URL, expected: FileStamp? = nil) throws -> String {
        try Task.checkCancellation()
        let original = try expected ?? fileStamp(url)
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" || original.size <= 64 * 1_048_576 else {
            throw VerificationError.unavailable
        }
        return try withStableFile(url, matching: original) { input in
            var hash = SHA256()
            var read: Int64 = 0
            while true {
                try Task.checkCancellation()
                let bytes: Data?
                do { bytes = try input.read(upToCount: 512 * 1024) }
                catch { throw VerificationError.unavailable }
                guard let bytes, !bytes.isEmpty else { break }
                read += Int64(bytes.count)
                guard read <= original.size else { throw VerificationError.unstable }
                hash.update(data: bytes)
            }
            guard read == original.size else { throw VerificationError.unstable }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func withStableFile<T>(_ url: URL, matching original: FileStamp,
                                           read: (FileHandle) throws -> T) throws -> T {
        try Task.checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw VerificationError.unavailable }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw VerificationError.unavailable }
        guard attributes.st_mode & S_IFMT == S_IFREG, stamp(attributes) == original else {
            throw VerificationError.unstable
        }
        let result = try read(input)
        try Task.checkCancellation()
        guard fstat(descriptor, &attributes) == 0, let pathStamp = try? fileStamp(url) else {
            throw VerificationError.unavailable
        }
        guard stamp(attributes) == original, pathStamp == original else { throw VerificationError.unstable }
        return result
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
    var zotero: ResearchZoteroPDF.Identity? = nil

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

    /// Enrich an already authenticated selection with a local PDF position.
    /// The caller supplies the active document URL from the reader, never a title match.
    static func locatePDFSelection(_ material: ResearchMaterial, at url: URL) async throws -> ResearchMaterial {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf", material.selectionIsComplete else { return material }
        let worker = Task.detached(priority: .userInitiated) { () throws -> ResearchMaterial in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            var result = material
            guard let (file, bytes) = try? ResearchFileReference.snapshotSelectionPDF(url) else {
                try Task.checkCancellation()
                return result
            }
            result.fileReference = file
            let selection = material.text.utf16.count
            guard (3...4_096).contains(selection), let bytes, let pdf = PDFDocument(data: bytes),
                  !pdf.isLocked, (1...96).contains(pdf.pageCount) else { return result }
            try Task.checkCancellation()
            let exact = pdf.findString(material.text, withOptions: [.literal]).filter {
                $0.string?.utf8.elementsEqual(material.text.utf8) == true
            }
            try Task.checkCancellation()
            guard exact.count == 1 else { return result }
            let lines = exact[0].selectionsByLine()
            guard (1...64).contains(lines.count) else { return result }
            let positions: [ResearchPDFSourcePosition] = lines.compactMap { line in
                guard line.pages.count == 1, let page = line.pages.first else { return nil }
                let index = pdf.index(for: page)
                let bounds = line.bounds(for: page).intersection(page.bounds(for: .cropBox))
                guard index != NSNotFound, index < pdf.pageCount, !bounds.isEmpty, !bounds.isInfinite else { return nil }
                return .init(page: index + 1, bounds: bounds)
            }
            guard positions.count == lines.count else { return result }
            let pages = positions.map(\.page)
            result.pdfPositions = positions
            result.pdfPages = ResearchPDFIndex.pageList(pages)
            if Set(pages).count == 1, let page = pages.first {
                result.verifiedExcerpts = result.verifiedExcerpts?.map { excerpt in
                    var located = excerpt
                    located.page = page
                    return located
                }
            }
            return result
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
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
        return ResearchZoteroLocation(library: scope, attachmentKey: String(key[2]),
                                      pageIndex: material.pageIndex, pageLabel: material.pageLabel).url
    }
}

/// Only captures information that is unavailable in the saved bridge prompt.
/// File paths and exact web URLs stay local, bound by session, request, and excerpt.
struct ResearchProvenanceStore {
    private struct PendingSelection: Codable {
        let id: UUID
        let source: String
        let title: String
        let text: String?
        // Leave the legacy text field absent for an unverified copy. Older
        // clients require that field and would promote its contents to a quote.
        let unverifiedText: String?
        let unverifiedScope: String?
        let url: String?
        let page: String?
        let file: ResearchFileReference?
        let web: String?
        let zotero: ResearchZoteroLocation?
        let pdfPages: String?
        let pdfPositions: [ResearchPDFSourcePosition]?

        init(_ material: ResearchMaterial) {
            id = material.id
            source = material.source
            title = material.title
            let verified = material.verifiedExcerpts?.isEmpty == false
            text = verified ? material.text : nil
            unverifiedText = verified ? nil : material.text
            unverifiedScope = verified ? nil : material.scope
            url = material.url
            page = material.page
            file = material.fileReference
            web = material.localWebURL
            zotero = material.zoteroLocation
            pdfPages = material.pdfPages
            pdfPositions = material.pdfPositions
        }

        func material() throws -> ResearchMaterial {
            guard let body = text ?? unverifiedText, (text == nil) != (unverifiedText == nil) else {
                throw ResearchMaterialError.message("本地选区记录无法读取。")
            }
            var value = try ResearchMaterial.selection(body, source: source, title: title, url: url)
            value.id = id
            value.page = page
            value.fileReference = file
            value.localWebURL = web
            value.zoteroLocation = zotero
            value.pdfPages = pdfPages
            value.pdfPositions = pdfPositions
            if unverifiedText != nil {
                value.verifiedExcerpts = nil
                value.scope = unverifiedScope ?? "选区 · 出处未独立核验"
            } else if let pdfPages, let page = Int(pdfPages), page > 0, let range = value.verifiedExcerpts?.first?.range {
                value.verifiedExcerpts = [.init(kind: .selection, range: range, title: title, page: page,
                                                doi: ResearchVerifiedExcerpt.doi(from: url.flatMap(URL.init(string:))))]
            }
            return value
        }
    }

    struct LocalReference: Codable {
        let title: String
        let textFingerprint: String
        var file: ResearchFileReference?
        let web: String?
        var zotero: ResearchZoteroLocation? = nil
        var pdfPages: String? = nil
        var backgroundFile: ResearchFileReference? = nil
        var backgroundPages: String? = nil
        var pdfPositions: [ResearchPDFSourcePosition]? = nil
        var backgroundPositions: [ResearchPDFSourcePosition]? = nil
        var positionDigest: String? = nil
        var objectLabels: [String]? = nil
        var imageFingerprints: [String]? = nil
        var sourceGroups: [ResearchPDFSourceGroup]? = nil
        var verifiedExcerpts: [ResearchVerifiedExcerpt]? = nil
        var questionFingerprint: String? = nil
        var hasPartialCaption: Bool? = nil
        var evidenceChecks: [ResearchPDFEvidenceCheck]? = nil
    }

    private struct Positions: Codable {
        let primary: [ResearchPDFSourcePosition]?
        let background: [ResearchPDFSourcePosition]?
        let groups: [ResearchPDFSourceGroup]?
        let verifiedExcerpts: [ResearchVerifiedExcerpt]?
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

    // Reuse the same DSH/workspace/session identity as the file association.
    // A capture remains local, separate from the immutable sources of sent turns.
    private func pendingSelectionLocation(_ key: String, create: Bool) throws -> URL? {
        guard try checkedDirectory(root, create: create) else { return nil }
        return root.appendingPathComponent(fingerprint(key) + ".selection.json")
    }

    func pendingSelection(_ key: String) -> ResearchMaterial? {
        guard let url = try? pendingSelectionLocation(key, create: false),
              let meta = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              meta.isRegularFile == true, meta.isSymbolicLink != true,
              (meta.fileSize ?? Int.max) <= 8 * ResearchMaterial.localSelectionLimit,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PendingSelection.self, from: data) else { return nil }
        return try? snapshot.material()
    }

    func savePendingSelection(_ material: ResearchMaterial, for key: String) throws {
        guard let url = try pendingSelectionLocation(key, create: true) else { return }
        try JSONEncoder().encode(PendingSelection(material)).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func removePendingSelection(_ key: String) throws {
        guard let url = try pendingSelectionLocation(key, create: false),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func record(session: String, requestID: String, material: ResearchMaterial, question: String? = nil) throws {
        let web = material.localWebURL == material.url ? nil : material.localWebURL
        let excerpts = material.verifiedExcerpts?.filter { $0.text(in: material.text) != nil }
        guard material.fileReference != nil || web != nil || material.zoteroLocation?.url != nil || material.backgroundFile != nil ||
              excerpts?.isEmpty == false else { return }
        guard let url = try location(session: session, requestID: requestID, create: true) else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else { return } // Retry keeps its original capture.
        let imageFingerprints = material.documentImages.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        let partialCaption = excerpts?.contains { $0.kind == .caption && $0.partial == true } == true
        let reference = LocalReference(title: material.title, textFingerprint: fingerprint(material.text),
                                       file: material.fileReference, web: web, zotero: material.zoteroLocation, pdfPages: material.pdfPages,
                                       backgroundFile: material.backgroundFile, backgroundPages: material.backgroundPages,
                                       pdfPositions: material.pdfPositions, backgroundPositions: material.backgroundPositions,
                                       objectLabels: material.objectLabels, imageFingerprints: imageFingerprints.isEmpty ? nil : imageFingerprints,
                                       sourceGroups: material.sourceGroups, verifiedExcerpts: excerpts,
                                       questionFingerprint: question.map { fingerprint($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
                                       hasPartialCaption: partialCaption ? true : nil,
                                       evidenceChecks: material.evidenceChecks)
        try write(reference, to: url)
    }

    private func write(_ reference: LocalReference, to url: URL) throws {
        var header = reference
        if reference.pdfPositions != nil || reference.backgroundPositions != nil || reference.verifiedExcerpts?.isEmpty == false {
            let locations = Positions(primary: reference.pdfPositions, background: reference.backgroundPositions,
                                      groups: reference.sourceGroups, verifiedExcerpts: reference.verifiedExcerpts)
            let data = try JSONEncoder().encode(locations)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let sidecar = url.deletingLastPathComponent().appendingPathComponent(digest + ".positions")
            try data.write(to: sidecar, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            header.pdfPositions = nil
            header.backgroundPositions = nil
            header.sourceGroups = nil
            header.verifiedExcerpts = nil
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
                value.sourceGroups = positions.groups
                value.verifiedExcerpts = positions.verifiedExcerpts
            }
        }
        return value
    }

    func originalQuestion(in reply: ResearchReplyContext, reference: LocalReference?) -> String? {
        guard let digest = reference?.questionFingerprint else { return reply.question }
        if fingerprint(reply.question) == digest { return reply.question }
        // Existing bridges can prepend one instruction line for translate/explain.
        // Remove an envelope prefix only if the remaining bytes match this turn.
        guard let divider = reply.question.firstIndex(of: "\n") else { return nil }
        let question = String(reply.question[reply.question.index(after: divider)...])
        return fingerprint(question) == digest ? question : nil
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
        var local = prior
        if background { local.backgroundFile = replacement }
        else { local.file = replacement }
        try write(local, to: recordURL)
    }

    func remove(session: String) throws {
        let parent = directory(for: session)
        if try checkedDirectory(root, create: false), try checkedDirectory(parent, create: false) {
            try FileManager.default.removeItem(at: parent)
        }
    }
}
