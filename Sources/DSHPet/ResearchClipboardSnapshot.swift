import AppKit
import UniformTypeIdentifiers

/// A short-lived copy of installed pasteboard representations. File items are
/// copied as references and Finder metadata. Their destination is never opened.
struct ResearchClipboardSnapshot: Sendable {
    private struct Representation: Sendable {
        let type: String
        let data: Data
    }

    private static let textTypes: Set<String> = [
        "public.utf8-plain-text", "public.utf16-external-plain-text", "NSStringPboardType",
        "CorePasteboardFlavorType 0x75743136", // UTF-16 plain text
        "org.nspasteboard.source",
    ]

    // AppKit publishes these legacy aliases when a public URL or URL name
    // is declared. The native item still owns the original URL bytes.
    private static let urlTypes: Set<String> = [
        "public.url", "public.url-name", "Apple URL pasteboard type", "WebURLsWithTitlesPBoardType",
        "CorePasteboardFlavorType 0x75726C20", "CorePasteboardFlavorType 0x75726C6E",
        "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
    ]

    private static let ordinaryTypes = textTypes.union(urlTypes).union([
        "public.rtf", "NSRTFPboardType", "NeXT Rich Text Format v1.0 pasteboard type",
        "public.html", "Apple HTML pasteboard type", "com.apple.WebKit.custom-pasteboard-data",
        "com.apple.flat-rtfd", "NSRTFDPboardType", "NeXT RTFD pasteboard type",
        "com.apple.webarchive", "Apple Web Archive pasteboard type",
        "public.png", "Apple PNG pasteboard type", "public.tiff", "NeXT TIFF v4.0 pasteboard type",
        "public.jpeg", "Apple JPEG pasteboard type", "public.heic", "com.compuserve.gif", "com.adobe.pdf", "Apple PDF pasteboard type",
    ])

    private static let finderNode = "com.apple.finder.noderef"
    private static let finderTypes = textTypes.union([
        "public.file-url", "Apple URL pasteboard type", "NSFilenamesPboardType",
        finderNode, "com.apple.icns", "fndf", "public.tiff", "NeXT TIFF v4.0 pasteboard type",
        "CorePasteboardFlavorType 0x6675726C", // Finder's legacy file URL
        "CorePasteboardFlavorType 0x69636E73", // Finder's file icon
        "dyn.ah62d4rv4gu8y6y4grf0gn5xbrzw1gydcr7u1e3cytf2gn",
        "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu",
    ])

    let revision: Int
    private let items: [[Representation]]

    private enum Refusal: Int { case aggregate = 1, item, representation, aggregateMetadata }

    static func capture(_ board: NSPasteboard, requestID: UUID? = nil) throws -> Self {
        func refuse(_ reason: Refusal) -> SelectionCaptureError {
            if let requestID { ResearchSelectionTrace.mark(requestID, "clipboard-snapshot-refused", reason.rawValue) }
            return .clipboardNotRestorable
        }
        func ordinary(_ type: String) -> Bool {
            // Only standard public image identifiers and explicit byte-backed
            // formats. Private, transient and promised types are not fetched.
            ordinaryTypes.contains(type) || (type.hasPrefix("public.") && UTType(type)?.conforms(to: .image) == true)
        }
        let revision = board.changeCount
        if #available(macOS 15.4, *), board.name == .general {
            let behavior = board.accessBehavior
            if let requestID { ResearchSelectionTrace.mark(requestID, "clipboard-access-behavior", behavior.rawValue) }
            guard behavior != .alwaysDeny else { throw SelectionCaptureError.clipboardReadUnavailable }
        }
        // AppKit returns empty arrays for an empty board and nil on read
        // errors. Only an explicitly empty board is safe to restore as empty.
        guard let items = board.pasteboardItems, let declaredTypes = board.types else {
            throw SelectionCaptureError.clipboardReadUnavailable
        }
        let firstFile = items.firstIndex { $0.types.contains(.fileURL) }
        let aggregate = Set(declaredTypes.map(\.rawValue))
        if let requestID {
            // These flags describe the shape, never the contents or the source app.
            let hasRichText = !aggregate.isDisjoint(with: ["public.rtf", "public.html", "com.apple.flat-rtfd", "com.apple.webarchive"])
            let hasImage = aggregate.contains { $0.hasPrefix("public.") && UTType($0)?.conforms(to: .image) == true }
            let flags = (firstFile == nil ? 0 : 1) | (hasRichText ? 2 : 0) | (hasImage ? 4 : 0)
            ResearchSelectionTrace.mark(requestID, "clipboard-format-flags", flags)
            ResearchSelectionTrace.mark(requestID, "clipboard-item-count", items.count)
            ResearchSelectionTrace.mark(requestID, "clipboard-type-count", aggregate.count)
        }
        guard items.count <= 128,
              aggregate.allSatisfy({ ordinary($0) || firstFile != nil && finderTypes.contains($0) }),
              !items.isEmpty || aggregate.isEmpty else {
            throw refuse(.aggregate)
        }
        var remaining = 64 * 1024 * 1024
        var representations = try items.map { item in
            try Task.checkCancellation()
            let types = item.types
            let itemHasFileURL = types.contains(.fileURL)
            guard !types.isEmpty, types.allSatisfy({ ordinary($0.rawValue) || itemHasFileURL && finderTypes.contains($0.rawValue) }),
                  !itemHasFileURL || item.string(forType: .fileURL).flatMap(URL.init(string:))?.isFileURL == true else {
                throw refuse(.item)
            }
            return try types.map { type in
                guard board.changeCount == revision else { throw SelectionCaptureError.sourceChanged }
                guard let data = item.data(forType: type), data.count <= remaining else {
                    throw refuse(.representation)
                }
                remaining -= data.count
                return Representation(type: type.rawValue, data: data)
            }
        }
        // Finder also publishes an aggregate node-reference marker. AppKit
        // omits it from pasteboardItems, and Finder can otherwise paste only
        // the first URL even when all the clipboard items survived.
        if let firstFile, aggregate.contains(finderNode),
           !representations[firstFile].contains(where: { $0.type == finderNode }) {
            guard let data = board.data(forType: .init(finderNode)), data.count <= remaining else {
                throw refuse(.aggregateMetadata)
            }
            representations[firstFile].append(Representation(type: finderNode, data: data))
        }
        guard board.changeCount == revision else { throw SelectionCaptureError.sourceChanged }
        return Self(revision: revision, items: representations)
    }

    /// Stage all AppKit items before issuing Copy, while the existing board is
    /// still intact. In particular AppKit can reject invalid legacy type names.
    func prepareRestoration() throws -> Restoration {
        var replacement: [NSPasteboardItem] = []
        replacement.reserveCapacity(items.count)
        for representations in items {
            let item = NSPasteboardItem()
            for value in representations {
                guard item.setData(value.data, forType: .init(value.type)) else {
                    throw SelectionCaptureError.clipboardNotRestorable
                }
            }
            replacement.append(item)
        }
        return Restoration(items: replacement)
    }

    struct Restoration {
        enum Outcome { case restored, newerWrite, failed }
        fileprivate let items: [NSPasteboardItem]

        func apply(to board: NSPasteboard, replacing ownedRevision: Int) -> Outcome {
            guard board.changeCount == ownedRevision else { return .newerWrite }
            let revision = board.clearContents()
            guard board.changeCount == revision else { return .newerWrite }
            return items.isEmpty || board.writeObjects(items) ? .restored : .failed
        }
    }
}
