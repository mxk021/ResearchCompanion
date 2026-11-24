import CoreGraphics
import Darwin
import Foundation

/// A positioned Unicode scalar in the original PDF user space.
struct ResearchPDFGlyph: Sendable {
    let scalar: Unicode.Scalar
    let bounds: CGRect
}

struct ResearchPDFGlyphLine: Sendable {
    let text: String
    let bounds: CGRect
    let symbols: Set<String>
}

/// Keeps PDFium's own character stream and positions; these indices never
/// become PDFKit UTF-16 ranges. The page cache includes only extracted data.
final class ResearchPDFGlyphPage: Sendable {
    fileprivate struct Entry: Sendable {
        let scalar: Unicode.Scalar?
        let bounds: CGRect?
    }

    fileprivate let canvas: CGRect
    fileprivate let display: CGAffineTransform
    fileprivate let entries: [Entry]
    private struct Center: Sendable {
        let index: Int
        let point: CGPoint
    }
    private let centersByHeight: [Center]
    fileprivate var cacheCost: Int {
        entries.count * MemoryLayout<Entry>.stride + centersByHeight.count * MemoryLayout<Center>.stride
    }

    fileprivate init(canvas: CGRect, display: CGAffineTransform, entries: [Entry]) {
        self.canvas = canvas
        self.display = display
        self.entries = entries
        self.centersByHeight = entries.indices.compactMap { index -> Center? in
            guard let bounds = entries[index].bounds else { return nil }
            return .init(index: index, point: CGPoint(x: bounds.midX, y: bounds.midY).applying(display))
        }.sorted { $0.point.y < $1.point.y }
    }

    func glyphs(in bounds: CGRect) -> [ResearchPDFGlyph] {
        indices(in: bounds).compactMap { index in
            let entry = entries[index]
            guard let scalar = entry.scalar, let bounds = entry.bounds else { return nil }
            return .init(scalar: scalar, bounds: bounds)
        }
    }

    /// Corroborates the printed symbol, without assigning mathematical roles
    /// or flattening the equation into a transcription.
    func containsSymbol(_ symbol: String, within bounds: CGRect) -> Bool {
        let values = Array(symbol.unicodeScalars)
        guard (1...12).contains(values.count),
              values.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return false }
        let indices = indices(in: bounds)
        return indices.indices.contains { offset in
            let end = offset + values.count
            guard end <= indices.count else { return false }
            let startIndex = indices[offset]
            let endIndex = indices[end - 1]
            guard endIndex - startIndex == values.count - 1,
                  entries[startIndex...endIndex].map(\.scalar).elementsEqual(values.map(Optional.some))
            else { return false }
            return symbolBoundary(at: startIndex - 1, beside: startIndex)
                && symbolBoundary(at: endIndex + 1, beside: endIndex)
        }
    }

    private func symbolBoundary(at neighbor: Int, beside index: Int) -> Bool {
        guard entries.indices.contains(neighbor) else { return true }
        if let scalar = entries[neighbor].scalar,
           !CharacterSet.alphanumerics.contains(scalar), !CharacterSet.nonBaseCharacters.contains(scalar),
           scalar.properties.generalCategory != .connectorPunctuation { return true }
        // A superscript can be as tall as a neighboring lowercase letter.
        // A shift of both glyph edges separates it from an ordinary ascender.
        guard let other = entries[neighbor].bounds, let glyph = entries[index].bounds else { return false }
        let lower = glyph.minY - other.minY
        let upper = glyph.maxY - other.maxY
        let shifted = lower * upper > 0 && min(abs(lower), abs(upper)) > min(glyph.height, other.height) * 0.55
        return shifted && abs(glyph.midX - other.midX) > min(glyph.width, other.width) * 0.30
    }

    /// A narrow, single-line recovery. Keep the independent original only
    /// when deleting exactly one explicitly requested, positioned symbol
    /// recovers the entire PDFKit line. Otherwise leave the evidence partial.
    func recovering(line: String, within bounds: CGRect, requiredSymbols: Set<String>) -> ResearchPDFGlyphLine? {
        guard !requiredSymbols.isEmpty, !line.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { return nil }
        let indices = indices(in: bounds)
        let native = line.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        guard native.count >= 5, indices.count == native.count + 1,
              let first = indices.first, let last = indices.last else { return nil }
        let selected = indices.compactMap { entries[$0].scalar }
        guard selected.count == indices.count else { return nil }
        let difference = zip(native, selected).prefix { $0 == $1 }.count
        let missing = selected[difference]
        guard requiredSymbols.contains(String(missing)),
              native.dropFirst(difference).elementsEqual(selected.dropFirst(difference + 1)),
              difference == 0 || selected[difference - 1] != missing,
              difference + 1 == selected.count || selected[difference + 1] != missing else { return nil }
        let missingIndex = indices[difference]
        let original = entries[first...last]
        let scalars = original.compactMap(\.scalar)
        guard scalars.count == original.count, !scalars.contains(where: CharacterSet.newlines.contains),
              scalars.filter({ !CharacterSet.whitespaces.contains($0) }) == selected else { return nil }
        let removed = scalars.enumerated().filter { $0.offset + first != missingIndex }.map(\.element)
        func words(_ value: String) -> [Substring] { value.split(whereSeparator: \.isWhitespace) }
        let recovered = String(String.UnicodeScalarView(scalars))
        guard words(String(String.UnicodeScalarView(removed))) == words(line),
              words(recovered).contains(Substring(String(missing))) else { return nil }
        let ink = indices.compactMap { entries[$0].bounds }.reduce(CGRect.null) { $0.union($1) }
        return .init(text: recovered, bounds: ink, symbols: [String(missing)])
    }

    private func indices(in bounds: CGRect) -> [Int] {
        guard bounds.isFiniteArea else { return [] }
        let region = bounds.applying(display).intersection(canvas)
        guard region.isFiniteArea else { return [] }
        var low = 0
        var high = centersByHeight.count
        while low < high {
            let mid = (low + high) / 2
            if centersByHeight[mid].point.y < region.minY { low = mid + 1 }
            else { high = mid }
        }
        return centersByHeight[low...].prefix { $0.point.y <= region.maxY }
            .filter { region.contains($0.point) }.map(\.index).sorted()
    }
}

private extension CGRect {
    var isFiniteArea: Bool { !isNull && !isEmpty && [minX, minY, maxX, maxY].allSatisfy(\.isFinite) }
}

/// The page coordinate map still comes from the index. Only the rasterizer
/// changes for resource combinations that the system renderer cannot replay
/// faithfully.
enum ResearchPDFCropRenderer {
    static func requiresAlternate(_ page: CGPDFPage) -> Bool {
        guard let dictionary = page.dictionary else { return false }
        let scanner = CompositeResources()
        scanner.visit(dictionary, depth: 0)
        return scanner.found
    }

    static func alternateImage(bytes: Data, pageIndex: Int, canvas: CGRect, display: CGAffineTransform,
                               crop: CGRect, scale: CGFloat) throws -> CGImage {
        try Task.checkCancellation()
        guard let library = library,
              let image = library.crop(bytes: bytes, pageIndex: pageIndex, canvas: canvas, display: display,
                                       crop: crop, scale: scale) else {
            // Substituting the native raster here can silently drop dots or
            // change masked regions even when their page coordinates agree.
            throw ResearchMaterialError.message("此页的图案和透明叠层无法可靠绘制，已保留原页位置。请打开原文核对。")
        }
        try Task.checkCancellation()
        return image
    }

    /// `verifiedBytes` must return the exact content for the supplied digest.
    /// Taking it lazily reuses positions without reopening the file on a hit.
    static func glyphPage(fingerprint: String, pageIndex: Int, canvas: CGRect, display: CGAffineTransform,
                          verifiedBytes: () throws -> Data?) throws -> ResearchPDFGlyphPage? {
        try Task.checkCancellation()
        guard let library, !fingerprint.isEmpty, let pageIndex = Int32(exactly: pageIndex), pageIndex >= 0 else { return nil }
        let page = try library.glyphPage(fingerprint: fingerprint, pageIndex: pageIndex, canvas: canvas,
                                         display: display, verifiedBytes: verifiedBytes)
        try Task.checkCancellation()
        return page
    }

    private static let library = Bundle.main.privateFrameworksURL
        .map { $0.appendingPathComponent("libpdfium.dylib") }
        .flatMap(PDFium.init(url:))

    private final class CompositeResources {
        private var pattern = false
        private var transparency = false
        private var visited = Set<CGPDFDictionaryRef>()
        private var budget = 400
        var found: Bool { pattern && transparency }

        func visit(_ dictionary: CGPDFDictionaryRef, depth: Int) {
            guard !found, depth < 8, budget > 0, visited.insert(dictionary).inserted else { return }
            budget -= 1
            var group: CGPDFDictionaryRef?
            var subtype: UnsafePointer<CChar>?
            if CGPDFDictionaryGetDictionary(dictionary, "Group", &group), let group,
               CGPDFDictionaryGetName(group, "S", &subtype), let subtype, String(cString: subtype) == "Transparency" {
                transparency = true
            }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources {
                inspectResources(resources, depth: depth)
            } else {
                var parent: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent), let parent {
                    visit(parent, depth: depth + 1)
                }
            }
        }

        private func inspectResources(_ resources: CGPDFDictionaryRef, depth: Int) {
            var patterns: CGPDFDictionaryRef?
            if !pattern, CGPDFDictionaryGetDictionary(resources, "Pattern", &patterns), let patterns {
                CGPDFDictionaryApplyBlock(patterns, { _, object, _ in
                    guard self.budget > 0 else { return false }
                    self.budget -= 1
                    var stream: CGPDFStreamRef?
                    var type = CGPDFInteger(0)
                    if CGPDFObjectGetValue(object, .stream, &stream), let stream,
                       let entry = CGPDFStreamGetDictionary(stream),
                       CGPDFDictionaryGetInteger(entry, "PatternType", &type), type == 1 {
                        self.pattern = true
                    }
                    return !self.pattern
                }, nil)
            }
            var states: CGPDFDictionaryRef?
            if !transparency, CGPDFDictionaryGetDictionary(resources, "ExtGState", &states), let states {
                CGPDFDictionaryApplyBlock(states, { _, object, _ in
                    guard self.budget > 0 else { return false }
                    self.budget -= 1
                    var entry: CGPDFDictionaryRef?
                    var mask: CGPDFDictionaryRef?
                    if CGPDFObjectGetValue(object, .dictionary, &entry), let entry,
                       CGPDFDictionaryGetDictionary(entry, "SMask", &mask), mask != nil {
                        self.transparency = true
                    }
                    return !self.transparency
                }, nil)
            }
            var objects: CGPDFDictionaryRef?
            if !found, CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects {
                CGPDFDictionaryApplyBlock(objects, { _, object, _ in
                    guard self.budget > 0 else { return false }
                    self.budget -= 1
                    var stream: CGPDFStreamRef?
                    var subtype: UnsafePointer<CChar>?
                    if CGPDFObjectGetValue(object, .stream, &stream), let stream,
                       let entry = CGPDFStreamGetDictionary(stream),
                       CGPDFDictionaryGetName(entry, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" {
                        self.visit(entry, depth: depth + 1)
                    }
                    return !self.found
                }, nil)
            }
        }
    }

    // Only these public C entry points from the pinned PDFium build are used.
    // Keep loading optional in the source-only test harness while requiring an
    // explicit failure for composite evidence when the verified App asset is absent.
    private final class PDFium: @unchecked Sendable {
        private typealias Pointer = OpaquePointer
        private typealias LoadDocument = @convention(c) (UnsafeRawPointer?, Int, UnsafePointer<CChar>?) -> Pointer?
        private typealias LoadPage = @convention(c) (Pointer, Int32) -> Pointer?
        private typealias Close = @convention(c) (Pointer) -> Void
        private typealias Dimension = @convention(c) (Pointer) -> Float
        private typealias CreateBitmap = @convention(c) (Int32, Int32, Int32, UnsafeMutableRawPointer?, Int32) -> Pointer?
        private typealias Render = @convention(c) (Pointer, Pointer, Int32, Int32, Int32, Int32, Int32, Int32) -> Void
        private typealias PageToDevice = @convention(c) (Pointer, Int32, Int32, Int32, Int32, Int32, Double, Double,
                                                        UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32

        private struct TextAPI {
            typealias Count = @convention(c) (Pointer) -> Int32
            typealias UnicodeValue = @convention(c) (Pointer, Int32) -> UInt32
            typealias CharacterFlag = @convention(c) (Pointer, Int32) -> Int32
            typealias Box = @convention(c) (Pointer, Int32, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>,
                                           UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>) -> Int32

            let load: @convention(c) (Pointer) -> Pointer?
            let close: Close
            let count: Count
            let unicode: UnicodeValue
            let generated: CharacterFlag
            let mappingError: CharacterFlag
            let box: Box

            init?(handle: UnsafeMutableRawPointer) {
                func symbol<T>(_ name: String, as _: T.Type) -> T? {
                    dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
                }
                guard let load = symbol("FPDFText_LoadPage", as: (@convention(c) (Pointer) -> Pointer?).self),
                      let close = symbol("FPDFText_ClosePage", as: Close.self),
                      let count = symbol("FPDFText_CountChars", as: Count.self),
                      let unicode = symbol("FPDFText_GetUnicode", as: UnicodeValue.self),
                      let generated = symbol("FPDFText_IsGenerated", as: CharacterFlag.self),
                      let mappingError = symbol("FPDFText_HasUnicodeMapError", as: CharacterFlag.self),
                      let box = symbol("FPDFText_GetCharBox", as: Box.self) else { return nil }
                self.load = load
                self.close = close
                self.count = count
                self.unicode = unicode
                self.generated = generated
                self.mappingError = mappingError
                self.box = box
            }
        }

        private let loadDocument: LoadDocument
        private let closeDocument: Close
        private let loadPage: LoadPage
        private let closePage: Close
        private let pageWidth: Dimension
        private let pageHeight: Dimension
        private let createBitmap: CreateBitmap
        private let destroyBitmap: Close
        private let render: Render
        private let pageToDevice: PageToDevice
        private let text: TextAPI?
        private let lock = NSLock()
        private let glyphPages: NSCache<NSString, ResearchPDFGlyphPage> = {
            let cache = NSCache<NSString, ResearchPDFGlyphPage>()
            cache.countLimit = 12
            cache.totalCostLimit = 8 * 1024 * 1024
            return cache
        }()

        init?(url: URL) {
            guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
            func symbol<T>(_ name: String, as _: T.Type) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let initialize = symbol("FPDF_InitLibrary", as: (@convention(c) () -> Void).self),
                  let loadDocument = symbol("FPDF_LoadMemDocument64", as: LoadDocument.self),
                  let closeDocument = symbol("FPDF_CloseDocument", as: Close.self),
                  let loadPage = symbol("FPDF_LoadPage", as: LoadPage.self),
                  let closePage = symbol("FPDF_ClosePage", as: Close.self),
                  let pageWidth = symbol("FPDF_GetPageWidthF", as: Dimension.self),
                  let pageHeight = symbol("FPDF_GetPageHeightF", as: Dimension.self),
                  let createBitmap = symbol("FPDFBitmap_CreateEx", as: CreateBitmap.self),
                  let destroyBitmap = symbol("FPDFBitmap_Destroy", as: Close.self),
                  let render = symbol("FPDF_RenderPageBitmap", as: Render.self),
                  let pageToDevice = symbol("FPDF_PageToDevice", as: PageToDevice.self) else {
                dlclose(handle)
                return nil
            }
            self.loadDocument = loadDocument
            self.closeDocument = closeDocument
            self.loadPage = loadPage
            self.closePage = closePage
            self.pageWidth = pageWidth
            self.pageHeight = pageHeight
            self.createBitmap = createBitmap
            self.destroyBitmap = destroyBitmap
            self.render = render
            self.pageToDevice = pageToDevice
            self.text = TextAPI(handle: handle)
            // PDFium initializes once and remains mapped for the life of the
            // process. Calls are serialized because its API is not thread safe.
            initialize()
        }

        func crop(bytes: Data, pageIndex: Int, canvas: CGRect, display: CGAffineTransform,
                  crop: CGRect, scale: CGFloat) -> CGImage? {
            let dimension = [canvas.width, canvas.height, crop.width, crop.height].map { ceil($0 * scale) }
            guard canvas.contains(crop), scale > 0,
                  let pageIndex = Int32(exactly: pageIndex), pageIndex >= 0, !bytes.isEmpty,
                  dimension.allSatisfy({ $0.isFinite && $0 >= 8 }),
                  max(dimension[0], dimension[1]) <= 24_000,
                  dimension[2] <= 1_480, dimension[3] <= 1_150 else { return nil }
            let width = Int32(dimension[2]), height = Int32(dimension[3])
            let fullWidth = Int32(dimension[0]), fullHeight = Int32(dimension[1])
            let offsetX = -Int32((crop.minX * scale).rounded())
            let offsetY = -Int32(((canvas.height - crop.maxY) * scale).rounded())
            let stride = 4 * width
            var pixels = Data(repeating: 255, count: Int(stride * height))
            let completed = lock.withLock {
                withPage(bytes: bytes, pageIndex: pageIndex) { page -> Bool? in
                    guard abs(CGFloat(pageWidth(page)) - canvas.width) < 0.05,
                          abs(CGFloat(pageHeight(page)) - canvas.height) < 0.05,
                          agrees(page, canvas: canvas, display: display, width: fullWidth, height: fullHeight) else { return nil }
                    return pixels.withUnsafeMutableBytes { output in
                        guard let bitmap = createBitmap(width, height, 3, output.baseAddress, stride) else { return false }
                        defer { destroyBitmap(bitmap) }
                        render(bitmap, page, offsetX, offsetY, fullWidth, fullHeight, 0, 0)
                        return true
                    }
                }
            }
            guard completed == true, let provider = CGDataProvider(data: pixels as CFData),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let format = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
            return CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: Int(stride), space: colorSpace,
                           bitmapInfo: format, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }

        /// Call under lock so the page and its memory outlive a PDFium operation.
        private func withPage<Value>(bytes: Data, pageIndex: Int32, _ body: (Pointer) -> Value?) -> Value? {
            bytes.withUnsafeBytes { input in
                guard !Task.isCancelled, let document = loadDocument(input.baseAddress, input.count, nil)
                else { return nil }
                defer { closeDocument(document) }
                guard let page = loadPage(document, pageIndex) else { return nil }
                defer { closePage(page) }
                return body(page)
            }
        }

        func glyphPage(fingerprint: String, pageIndex: Int32, canvas: CGRect, display: CGAffineTransform,
                       verifiedBytes: () throws -> Data?) throws -> ResearchPDFGlyphPage? {
            guard let text, canvas.isFiniteArea, canvas.width <= 12_000, canvas.height <= 12_000 else { return nil }
            let key = "1:\(fingerprint):\(pageIndex)" as NSString
            func cached() -> ResearchPDFGlyphPage? {
                guard let existing = glyphPages.object(forKey: key), existing.canvas == canvas, existing.display == display
                else { return nil }
                return existing
            }
            if let page = cached() { return page }
            guard let bytes = try verifiedBytes(), !bytes.isEmpty else { return nil }
            return lock.withLock {
                if let page = cached() { return page }
                let extracted = withPage(bytes: bytes, pageIndex: pageIndex) { page -> ResearchPDFGlyphPage? in
                    guard abs(CGFloat(pageWidth(page)) - canvas.width) < 0.05,
                          abs(CGFloat(pageHeight(page)) - canvas.height) < 0.05,
                          agrees(page, canvas: canvas, display: display,
                                 width: Int32((canvas.width * 2).rounded(.up)),
                                 height: Int32((canvas.height * 2).rounded(.up))),
                          let textPage = text.load(page)
                    else { return nil }
                    defer { text.close(textPage) }
                    let count = text.count(textPage)
                    guard (1...50_000).contains(count) else { return nil }
                    var entries: [ResearchPDFGlyphPage.Entry] = []
                    entries.reserveCapacity(Int(count))
                    for index in 0..<count {
                        if index % 256 == 0, Task.isCancelled { return nil }
                        entries.append(readGlyph(textPage, at: index, with: text, canvas: canvas, display: display))
                    }
                    return ResearchPDFGlyphPage(canvas: canvas, display: display, entries: entries)
                }
                if let extracted {
                    glyphPages.setObject(extracted, forKey: key, cost: extracted.cacheCost)
                }
                return extracted
            }
        }

        private func readGlyph(_ page: Pointer, at index: Int32, with text: TextAPI,
                               canvas: CGRect, display: CGAffineTransform) -> ResearchPDFGlyphPage.Entry {
            let decoded = Unicode.Scalar(text.unicode(page, index))
            if let decoded, CharacterSet.whitespacesAndNewlines.contains(decoded) { return .init(scalar: decoded, bounds: nil) }
            guard text.generated(page, index) == 0 else { return .init(scalar: nil, bounds: nil) }
            // Keep the ink geometry of an unmapped character separately.
            // It must block a supposed exact line, even when it is invisible
            // to the Unicode text returned by the parser.
            let scalar = text.mappingError(page, index) == 0 ? decoded.flatMap {
                CharacterSet.controlCharacters.contains($0) ? nil : $0
            } : nil
            var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0
            guard text.box(page, index, &left, &right, &bottom, &top) != 0, left < right, bottom < top
            else { return .init(scalar: scalar, bounds: nil) }
            let bounds = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
            let printed = bounds.applying(display)
            guard bounds.isFiniteArea, printed.isFiniteArea,
                  canvas.contains(printed) else { return .init(scalar: scalar, bounds: nil) }
            return .init(scalar: scalar, bounds: bounds)
        }

        private func agrees(_ page: Pointer, canvas: CGRect, display: CGAffineTransform,
                            width: Int32, height: Int32) -> Bool {
            // Compare three corners via the renderer's own mapping before a
            // crop can be published as referring to this original region.
            let inverse = display.inverted()
            let corners: [(CGPoint, Int32, Int32)] = [
                (CGPoint(x: 0, y: canvas.height), 0, 0),
                (CGPoint(x: canvas.width, y: canvas.height), width, 0),
                (.zero, 0, height),
            ]
            return corners.allSatisfy { corner, expectedX, expectedY in
                let raw = corner.applying(inverse)
                var x: Int32 = 0, y: Int32 = 0
                return pageToDevice(page, 0, 0, width, height, 0, raw.x, raw.y, &x, &y) != 0 &&
                    abs(Int(x) - Int(expectedX)) <= 1 && abs(Int(y) - Int(expectedY)) <= 1
            }
        }
    }
}
