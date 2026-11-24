import CoreGraphics

/// Inspect painted images and stroked Form objects in original PDF coordinates.
/// The rendered page supplies all crops, including axes, overlaid labels, and clipping.
enum ResearchPDFImageGeometry {
    struct Placements {
        var images: [CGRect] = []
        var linePlots: [CGRect] = []
    }

    static func placements(on page: CGPDFPage) -> [CGRect] { paintedObjects(on: page).images }

    static func paintedObjects(on page: CGPDFPage) -> Placements {
        guard let scanner = Scanner() else { return Placements() }
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        scanner.scan(content)
        return scanner.placements
    }

    private final class Scanner {
        private let operators: CGPDFOperatorTableRef
        private var transform: CGAffineTransform = .identity
        private var stack: [CGAffineTransform] = []
        private var depth = 0
        private var resourceCount = 0
        private(set) var placements = Placements()
        private var strokes = 0

        init?() {
            guard let table = CGPDFOperatorTableCreate() else { return nil }
            operators = table
            CGPDFOperatorTableSetCallback(table, "q") { scanner, raw in
                guard let raw else { return }
                let state = Unmanaged<Scanner>.fromOpaque(raw).takeUnretainedValue()
                guard state.stack.count < 64, !Task.isCancelled else {
                    CGPDFScannerStop(scanner)
                    return
                }
                state.stack.append(state.transform)
            }
            CGPDFOperatorTableSetCallback(table, "Q") { _, raw in
                guard let raw else { return }
                let state = Unmanaged<Scanner>.fromOpaque(raw).takeUnretainedValue()
                if let previous = state.stack.popLast() { state.transform = previous }
            }
            CGPDFOperatorTableSetCallback(table, "cm") { scanner, raw in
                guard let raw else { return }
                let state = Unmanaged<Scanner>.fromOpaque(raw).takeUnretainedValue()
                var values = [CGFloat](repeating: 0, count: 6)
                for index in values.indices.reversed() where !CGPDFScannerPopNumber(scanner, &values[index]) { return }
                if values.allSatisfy(\.isFinite) { state.concatenate(values) }
            }
            for name in ["S", "s", "B", "B*"] {
                CGPDFOperatorTableSetCallback(table, name) { _, raw in
                    guard let raw else { return }
                    Unmanaged<Scanner>.fromOpaque(raw).takeUnretainedValue().strokes += 1
                }
            }
            CGPDFOperatorTableSetCallback(table, "Do") { scanner, raw in
                guard let raw else { return }
                Unmanaged<Scanner>.fromOpaque(raw).takeUnretainedValue().resource(scanner)
            }
        }

        deinit { CGPDFOperatorTableRelease(operators) }

        func scan(_ content: CGPDFContentStreamRef) {
            let scanner = CGPDFScannerCreate(content, operators, Unmanaged.passUnretained(self).toOpaque())
            defer { CGPDFScannerRelease(scanner) }
            _ = CGPDFScannerScan(scanner)
        }

        private func concatenate(_ values: [CGFloat]) {
            let local = CGAffineTransform(a: values[0], b: values[1], c: values[2],
                                          d: values[3], tx: values[4], ty: values[5])
            transform = local.concatenating(transform)
        }

        private func resource(_ scanner: CGPDFScannerRef) {
            guard resourceCount < 160, depth < 7, !Task.isCancelled else {
                CGPDFScannerStop(scanner)
                return
            }
            resourceCount += 1
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let parent = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var rawType: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &rawType), let rawType else { return }
            switch String(cString: rawType) {
            case "Image":
                let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform)
                if !rect.isInfinite, rect.minX.isFinite, rect.minY.isFinite, rect.width > 2, rect.height > 2 {
                    placements.images.append(rect)
                }
            case "Form":
                var resources: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return }
                let child = CGPDFContentStreamCreateWithStream(stream, resources, parent)
                let originalTransform = transform
                let originalStack = stack
                defer {
                    depth -= 1
                    stack = originalStack
                    transform = originalTransform
                    CGPDFContentStreamRelease(child)
                }
                depth += 1
                stack = []
                var matrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var values = [CGFloat](repeating: 0, count: 6)
                    if values.indices.allSatisfy({ CGPDFArrayGetNumber(matrix, $0, &values[$0]) }),
                       values.allSatisfy(\.isFinite) { concatenate(values) }
                }
                let placementTransform = transform
                let preceding = strokes
                scan(child)
                // A plotted Form supplies its own clip box and actually paints
                // independent strokes. Its geometry can corroborate ownership
                // of chart labels before the requested figure is rasterized.
                var bounds: CGPDFArrayRef?
                var values = [CGFloat](repeating: 0, count: 4)
                if strokes - preceding >= 6, CGPDFDictionaryGetArray(dictionary, "BBox", &bounds),
                   let bounds, values.indices.allSatisfy({ CGPDFArrayGetNumber(bounds, $0, &values[$0]) }),
                   values.allSatisfy(\.isFinite) {
                    let box = CGRect(x: values[0], y: values[1], width: values[2] - values[0],
                                     height: values[3] - values[1]).applying(placementTransform)
                    if box.width > 2, box.height > 2 { placements.linePlots.append(box) }
                }
            default:
                return
            }
        }
    }
}
