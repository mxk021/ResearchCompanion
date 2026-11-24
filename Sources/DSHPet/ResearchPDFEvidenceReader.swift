import AppKit
import PDFKit

/// A read-only view of the verified file. Highlight annotations exist only in
/// this private PDFDocument instance and are never written to the source.
@MainActor
final class ResearchPDFEvidenceReader: NSViewController {
    fileprivate struct Stop {
        let page: Int
        var rect: CGRect?
        let column: Int?
        let block: Int?
        var ocr: Bool
    }

    struct Target: Sendable {
        let title: String
        let positions: [ResearchPDFSourcePosition]
    }

    fileprivate struct Mark {
        let page: PDFPage
        let annotation: PDFAnnotation
    }

    fileprivate struct Destination {
        let title: String?
        let stops: [Stop]
        let marks: [Mark]
    }

    private let pdf = PDFView()
    private let location = NSTextField(labelWithString: "")
    private let target = NSPopUpButton()
    private let previous = NSButton()
    private let next = NSButton()
    // A single worker constructs the document and its overlay marks. The UI owns
    // the PDF afterwards and never mutates the submitted source bytes.
    struct Prepared: @unchecked Sendable {
        let filename: String
        let document: PDFDocument
        fileprivate let destinations: [Destination]
        var targetNames: [String] { destinations.compactMap(\.title) }
    }

    private let showsClose: Bool
    private let document: PDFDocument
    private let destinations: [Destination]
    private var displayed: Int?
    private var selected = 0
    private var current = 0

    init(_ prepared: Prepared, showsClose: Bool = true) {
        self.showsClose = showsClose
        self.document = prepared.document
        self.destinations = prepared.destinations
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    static func present(_ prepared: Prepared, in parent: NSWindow) {
        let reader = ResearchPDFEvidenceReader(prepared)
        let sheet = NSWindow(contentViewController: reader)
        sheet.title = prepared.filename
        sheet.styleMask = [.titled, .resizable]
        let available = (parent.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 900, height: 750)
        sheet.setContentSize(NSSize(width: min(760, available.width * 0.85), height: min(790, available.height * 0.78)))
        parent.beginSheet(sheet)
    }

    override func loadView() {
        target.addItems(withTitles: destinations.compactMap(\.title))
        target.isHidden = destinations.count < 2
        target.controlSize = .small
        target.setAccessibilityLabel("原文定位目标")
        target.target = self
        target.action = #selector(selectTarget)
        location.lineBreakMode = .byTruncatingTail
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previous.title = "上一处"
        previous.target = self
        previous.action = #selector(stepBack)
        next.title = "下一处"
        next.target = self
        next.action = #selector(stepForward)
        let close = NSButton(title: "完成", target: self, action: #selector(closeSheet))
        close.isHidden = !showsClose
        if showsClose { close.keyEquivalent = "\u{1b}" }
        let bar = NSStackView(views: [target, location, NSView(), previous, next, close])
        bar.orientation = .horizontal
        bar.spacing = 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 650))
        bar.translatesAutoresizingMaskIntoConstraints = false
        pdf.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        container.addSubview(pdf)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            bar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            pdf.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
            pdf.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdf.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdf.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        pdf.displayMode = .singlePageContinuous
        pdf.autoScales = true
        pdf.document = document
    }

    nonisolated static func prepare(data: Data, filename: String, positions: [ResearchPDFSourcePosition], firstPage: Int,
                                    requireMappedPositions: Bool = false, targets: [Target] = []) throws -> Prepared {
        guard let document = PDFDocument(data: data), (1...max(1, document.pageCount)).contains(firstPage),
              document.page(at: firstPage - 1) != nil else {
            throw ResearchMaterialError.message("无法核对此 PDF 版本和页面。请在「来源」核对当时的摘录。")
        }
        var destinations: [Destination] = []
        var titles = Set<String>()
        for target in requireMappedPositions ? [] : targets {
            guard !titles.contains(target.title) else { continue }
            let destination = try map(target.positions, title: target.title, on: document)
            // A group such as a full caption can only be labelled once all its
            // verified locations map to this exact PDF. Ordinary legacy page
            // navigation remains available if no grouped destination maps.
            if !destination.stops.isEmpty, destination.marks.count == target.positions.count {
                destinations.append(destination)
                titles.insert(target.title)
            }
        }
        if destinations.isEmpty {
            let destination = try map(positions, title: nil, on: document)
            if requireMappedPositions &&
                (destination.marks.isEmpty || destination.marks.count != positions.count) {
                throw ResearchMaterialError.message("部分候选行无法在原页标出。请取消后核对原文件。")
            }
            let page = Stop(page: firstPage, rect: nil, column: nil, block: nil, ocr: false)
            destinations = destination.stops.isEmpty ? [.init(title: nil, stops: [page], marks: [])] : [destination]
        }
        return Prepared(filename: filename, document: document, destinations: destinations)
    }

    private nonisolated static func map(_ positions: [ResearchPDFSourcePosition], title: String?,
                                        on document: PDFDocument) throws -> Destination {
        var stops: [Stop] = []
        var marks: [Mark] = []
        var pageStops: [Int: Int] = [:]
        let border = PDFBorder()
        border.lineWidth = 0
        let tint = NSColor(srgbRed: 1, green: 0.82, blue: 0.1, alpha: 0.32)
        for entry in positions {
            try Task.checkCancellation()
            guard (1...max(1, document.pageCount)).contains(entry.page),
                  let page = document.page(at: entry.page - 1) else { continue }
            let rect = Self.targetRect(for: entry, on: page)
            guard let rect else { continue }
            let mark = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            mark.color = .clear
            mark.border = border
            mark.interiorColor = tint
            mark.shouldPrint = false
            marks.append(Mark(page: page, annotation: mark))
            if title != nil {
                // One destination can span a whole caption, multiple columns
                // or several supporting pages. Keep all actual ranges visible.
                if let index = pageStops[entry.page] {
                    stops[index].rect = stops[index].rect?.union(rect)
                    stops[index].ocr = stops[index].ocr || entry.ocr
                    continue
                }
                pageStops[entry.page] = stops.count
            }
            let sameBlock = entry.blockIndex != nil && stops.last?.page == entry.page &&
                stops.last?.block == entry.blockIndex && stops.last?.column == entry.column
            if !sameBlock {
                stops.append(Stop(page: entry.page, rect: rect, column: entry.column, block: entry.blockIndex, ocr: entry.ocr))
            }
        }
        return Destination(title: title, stops: stops, marks: marks)
    }

    nonisolated static func targetRect(for entry: ResearchPDFSourcePosition, on page: PDFPage) -> CGRect? {
        let box = page.bounds(for: .cropBox)
        let rect = entry.bounds.intersection(box)
        guard !rect.isNull, !rect.isEmpty, !rect.isInfinite else { return nil }
        if !entry.ocr, let range = entry.sourceRange, range.location >= 0, range.length > 0,
           range.location <= page.numberOfCharacters, range.length <= page.numberOfCharacters - range.location,
           let selection = page.selection(for: range) {
            let textRect = selection.bounds(for: page)
            // Some PDF text layers report a selection across columns or across a line break.
            if !textRect.isEmpty, rect.insetBy(dx: -2, dy: -2).contains(textRect) {
                return textRect.intersection(box)
            }
        }
        return rect
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reveal()
    }

    @objc private func selectTarget() {
        let index = target.indexOfSelectedItem
        guard destinations.indices.contains(index), selected != index else { return }
        selected = index
        current = 0
        reveal()
    }

    @objc private func stepBack() {
        if current > 0 { current -= 1; reveal() }
    }

    @objc private func stepForward() {
        if current + 1 < destinations[selected].stops.count { current += 1; reveal() }
    }

    private func reveal() {
        let destination = destinations[selected]
        let stops = destination.stops
        guard stops.indices.contains(current) else { return }
        let stop = stops[current]
        guard let page = document.page(at: stop.page - 1) else { return }
        if displayed != selected {
            var changed = Set(destination.marks.map(\.page))
            if let displayed {
                for mark in destinations[displayed].marks {
                    mark.page.removeAnnotation(mark.annotation)
                    changed.insert(mark.page)
                }
            }
            for mark in destination.marks { mark.page.addAnnotation(mark.annotation) }
            for page in changed { pdf.annotationsChanged(on: page) }
            displayed = selected
        }
        location.stringValue = [target.isHidden ? destination.title : nil,
                                "PDF 文件第 \(stop.page) 页", stop.ocr ? "本机 OCR" : nil,
                                stops.count > 1 ? "来源 \(current + 1)/\(stops.count)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        previous.isEnabled = current > 0
        next.isEnabled = current + 1 < stops.count
        previous.isHidden = stops.count < 2
        next.isHidden = stops.count < 2
        if let rect = stop.rect { pdf.go(to: rect.insetBy(dx: -4, dy: -6), on: page) }
        else { pdf.go(to: page) }
    }

    @objc private func closeSheet() {
        if let window = view.window { window.sheetParent?.endSheet(window) }
    }
}
