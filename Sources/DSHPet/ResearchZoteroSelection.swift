import CryptoKit
import Foundation

/// Uses the same owner-only local pairing as the existing DSH bridge. No library records are opened.
enum ResearchZoteroSelection {
    private struct Pairing: Decodable { let token: String; let endpoint: String? }
    private struct Reply: Decodable {
        struct Selection: Decodable { let requestId: String; let text: String; let title: String }
        let ok: Bool
        let error: String?
        let liveSelection: Selection?
    }
    // Redirects must never carry a local pairing proof to a different origin.
    private final class LocalOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private static func pairing() throws -> Pairing {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Zotero")
        let ini = try String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8)
        let sections = ini.components(separatedBy: "[").filter { $0.hasPrefix("Profile") }.map { section in
            section.split(whereSeparator: \.isNewline).reduce(into: [String: String]()) { fields, line in
                let pair = line.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
        }
        guard let profile = sections.first(where: { $0["Default"] == "1" }) ?? sections.first,
              let path = profile["Path"] else { throw SelectionCaptureError.zoteroBridge }
        let directory = profile["IsRelative"] == "0" ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        let url = directory.appendingPathComponent("dsh-companion-bridge/pairing.json")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SelectionCaptureError.zoteroBridge }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 4096,
              let data = try file.read(upToCount: 4097), data.count <= 4096 else { throw SelectionCaptureError.zoteroBridge }
        let record = try JSONDecoder().decode(Pairing.self, from: data)
        guard record.token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw SelectionCaptureError.zoteroBridge }
        return record
    }

    static func decode(_ data: Data, status: Int, requestID: UUID) throws -> ResearchMaterial {
        guard data.count <= 200_000, let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw SelectionCaptureError.zoteroBridge
        }
        guard status == 200, reply.ok, let selection = reply.liveSelection else {
            switch reply.error {
            case "NO_SELECTION": throw SelectionCaptureError.empty
            case "NO_ACTIVE_PAPER", "SOURCE_CHANGED", "PAPER_CHANGED": throw SelectionCaptureError.sourceChanged
            case "SELECTION_TOO_LARGE": throw SelectionCaptureError.zoteroTooLarge
            case "UNSUPPORTED": throw SelectionCaptureError.unsupported
            case "PROTECTED_CONTENT": throw SelectionCaptureError.protectedContent
            default: throw SelectionCaptureError.zoteroBridge
            }
        }
        guard UUID(uuidString: selection.requestId) == requestID else { throw SelectionCaptureError.sourceChanged }
        let title = ResearchMaterial.bounded(selection.title, limit: 512)
        return try ResearchSelectionCapture.exactSelection(selection.text, source: "Zotero", title: title.isEmpty ? "Zotero 选区" : title)
    }

    static func read(requestID: UUID) async throws -> ResearchMaterial {
        let record: Pairing
        do { record = try pairing() } catch { throw SelectionCaptureError.zoteroBridge }
        var port = 23119
        if let value = record.endpoint {
            guard let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1",
                  url.path == "/dsh-companion/context", url.user == nil, url.password == nil,
                  let localPort = url.port, (1...65535).contains(localPort) else { throw SelectionCaptureError.zoteroBridge }
            port = localPort
        }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let proof = "\(Int64(Date().timeIntervalSince1970 * 1000)).\(nonce)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(proof.utf8), using: SymmetricKey(data: Data(record.token.utf8)))
            .map { String(format: "%02x", $0) }.joined()
        let url = URL(string: "http://127.0.0.1:\(port)/dsh-companion/context?selection=live&requestId=\(requestID.uuidString.lowercased())")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.setValue("Bearer " + proof + "." + signature, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config, delegate: LocalOnly(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.expectedContentLength <= 200_000 else {
                throw SelectionCaptureError.zoteroBridge
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 200_000 else { throw SelectionCaptureError.zoteroBridge }
                data.append(byte)
            }
            return try decode(data, status: http.statusCode, requestID: requestID)
        } catch let error as URLError {
            if error.code == .timedOut { throw SelectionCaptureError.timedOut }
            if error.code == .cancelled { throw CancellationError() }
            throw SelectionCaptureError.zoteroBridge
        }
    }
}
