import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Local-only preparation for files and clipboard image representations.
enum ResearchDraftImageInput {
    static let contentTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .webP, .gif, .bmp]
    static let directPasteboardTypes = contentTypes.map { NSPasteboard.PasteboardType($0.identifier) }
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL] + directPasteboardTypes
    private static let maxInputBytes = 48 * 1_024 * 1_024
    private static let maxInputPixels = 80_000_000

    enum Source: Sendable {
        case file(URL)
        case clipboard(Data)

        var name: String {
            switch self {
            case .file(let url): return url.deletingPathExtension().lastPathComponent
            case .clipboard: return "粘贴图片"
            }
        }
    }

    struct Prepared: Sendable {
        let data: Data
        let mediaType: String
        let name: String
    }

    private enum InputError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let detail) = self { return detail }
            return nil
        }
    }

    @MainActor
    static func hasImage(on board: NSPasteboard) -> Bool {
        (board.pasteboardItems ?? []).contains { item in
            if item.types.contains(.fileURL) { return fileURL(in: item) != nil }
            return directPasteboardTypes.contains { item.types.contains($0) }
        }
    }

    @MainActor
    static func sources(from board: NSPasteboard, capacity: Int) throws -> [Source] {
        let revision = board.changeCount
        var sources: [Source] = []
        var rawBytes = 0
        for item in board.pasteboardItems ?? [] {
            let source: Source
            if item.types.contains(.fileURL) {
                // Finder also supplies previews of some non-image files. The
                // preview of a PDF, package or directory is never an attachment.
                guard let url = fileURL(in: item) else { continue }
                source = .file(url)
            } else {
                guard let type = directPasteboardTypes.first(where: { item.types.contains($0) }) else { continue }
                guard let data = item.data(forType: type), !data.isEmpty else {
                    throw InputError.message("未能读取剪贴板或拖入的图片。")
                }
                guard data.count <= maxInputBytes - rawBytes else {
                    throw InputError.message("剪贴板或拖入的图片原始数据过大，请选择图片文件。")
                }
                rawBytes += data.count
                source = .clipboard(data)
            }
            guard sources.count < capacity else {
                throw InputError.message("超出本次可附加的图片数量，请减少图片后重试。")
            }
            sources.append(source)
        }
        guard revision == board.changeCount else {
            throw InputError.message("读取时剪贴板已变化，请重新粘贴。")
        }
        return sources
    }

    @MainActor
    private static func fileURL(in item: NSPasteboardItem) -> URL? {
        guard let text = item.string(forType: .fileURL),
              let url = URL(string: text), url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension),
              contentTypes.contains(where: { type.conforms(to: $0) }) else { return nil }
        return url
    }

    static func prepare(_ source: Source, limits: DSHPetImageLimits) throws -> Prepared {
        let original: Data
        switch source {
        case .clipboard(let data):
            original = data
        case .file(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard url.isFileURL, values.isRegularFile == true, let size = values.fileSize,
                  (1...maxInputBytes).contains(size) else {
                throw InputError.message("请选择不超过 48 MiB 的本机图片文件。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            original = try handle.read(upToCount: maxInputBytes + 1) ?? Data()
        }

        guard (1...maxInputBytes).contains(original.count),
              let input = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(input) as String?, let originalType = UTType(identifier),
              contentTypes.contains(where: { originalType.conforms(to: $0) }),
              CGImageSourceGetCount(input) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxInputPixels / height else {
            throw InputError.message("无法读取此单帧图片，或原始像素数过大。")
        }

        let dimensionLimit = min(limits.maxImageDimension ?? 4_096, 4_096)
        let pixelLimit = min(limits.maxImagePixels ?? 16_777_216, 16_777_216)
        guard dimensionLimit > 0, pixelLimit > 0 else { throw InputError.message("科研桥未提供有效的图片尺寸上限。") }
        let scale = min(1, sqrt(Double(pixelLimit) / (Double(width) * Double(height))))
        let longest = max(1, min(dimensionLimit, Int((Double(max(width, height)) * scale).rounded(.down))))
        guard let image = image(input, maximum: longest),
              image.width <= dimensionLimit, image.height <= dimensionLimit,
              image.width <= pixelLimit / image.height else {
            throw InputError.message("无法在科研桥的像素上限内准备此图片。")
        }

        let order: [UTType] = originalType.conforms(to: .jpeg) ? [.jpeg, .png] : [.png, .jpeg]
        for type in order {
            guard let mime = type.preferredMIMEType, limits.mediaTypes.contains(mime),
                  let ext = type.preferredFilenameExtension,
                  let data = encode(image, as: type), data.count <= limits.maxImageBytes else { continue }
            let basename = source.name.components(separatedBy: .controlCharacters).joined()
            let name = basename.isEmpty ? "图片" : String(basename.prefix(120))
            return Prepared(data: data, mediaType: mime, name: name + "." + ext)
        }
        throw InputError.message("图片无法转换为科研桥接受的格式或超过单张大小上限。")
    }

    static func preview(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return image(source, maximum: 180)
    }

    private static func image(_ source: CGImageSource, maximum: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, type.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = type == .jpeg ? [
            kCGImageDestinationLossyCompressionQuality: 0.93,
            kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1),
        ] : [:]
        // Re-encode only the oriented bitmap, without the input's GPS or EXIF.
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? result as Data : nil
    }
}
