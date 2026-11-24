import CoreGraphics
import CryptoKit
import Foundation

/// Local-only inspection for a predeclared paper/query pair. Build with the same
/// app sources as check-pdf-query.swift. Write all evidence outside the repository.
@main
struct ResearchPaperSampleCheck {
    private struct Material: Codable, Equatable {
        let body: String
        let primary: [ResearchPDFSourcePosition]
        let context: [ResearchPDFSourcePosition]
        let images: [String]
    }

    private struct Result: Codable {
        let pages: Int
        let readablePages: Int
        let fileVerified: Bool
        let indexMilliseconds: Double
        let cachedIndexMilliseconds: Double
        let fileVerificationMilliseconds: Double
        var evidenceMilliseconds: Double?
        var cachedEvidenceMilliseconds: [Double] = []
        var material: Material?
        var reviewMaterial: Material?
        var sourceMappingVerified: Bool?
        var appObjectMaterialSHA256: String?
        var relationshipMilliseconds: Double?
        var appPreparationMilliseconds: Double?
        var stages: [String: Double]?
        var evidenceChecks: [ResearchPDFEvidenceCheck]?
        var error: String?
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func main() throws {
        let args = CommandLine.arguments.dropFirst()
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        guard args.count == 3 else {
            throw ResearchMaterialError.message("Usage: check-paper-sample <PDF> <question> <temporary output directory>")
        }
        let study = URL(fileURLWithPath: args[args.startIndex])
        let question = args[args.startIndex + 1]
        let output = URL(fileURLWithPath: args[args.startIndex + 2]).resolvingSymlinksInPath()
        guard output.path.hasPrefix("/private/tmp/") || output.path.hasPrefix(temp + "/"),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw ResearchMaterialError.message("Evidence output must be a new system temporary directory.")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let started = ContinuousClock.now
        var relationshipTime = Duration.zero
        let index = try ResearchPDFIndex.read(study, title: study.lastPathComponent,
            measureRelationships: { relationshipTime += $0 }) { _ in }
        let indexedIn = milliseconds(since: started)
        let readAgain = ContinuousClock.now
        let cachedIndex = try ResearchPDFIndex.read(study, title: study.lastPathComponent) { _ in }
        let rereadIn = milliseconds(since: readAgain)
        guard cachedIndex === index else { throw ResearchMaterialError.message("The unchanged PDF index was rebuilt.") }
        let verifying = ContinuousClock.now
        let fileVerified = index.reference.resolve()?.resolvingSymlinksInPath().path ==
            study.resolvingSymlinksInPath().path
        var sample = Result(pages: index.pages.count, readablePages: index.pages.filter { !$0.blocks.isEmpty }.count,
                            fileVerified: fileVerified, indexMilliseconds: indexedIn, cachedIndexMilliseconds: rereadIn,
                            fileVerificationMilliseconds: milliseconds(since: verifying))
        // Match the application: figure citations inside a bounded quotation
        // describe its prose and are not stand-alone object requests.
        var initialChecks: [ResearchPDFEvidenceCheck]?
        let request = ResearchPDFRequest(question)
        let objects = index.addressedObjects(for: request)
        let seconds = relationshipTime.components
        sample.relationshipMilliseconds = Double(seconds.seconds) * 1000 + Double(seconds.attoseconds) / 1e15

        func merge(_ pieces: [ResearchMaterial]) -> Material {
            Material(body: pieces.map(\.text).joined(separator: "\n"),
                     primary: pieces.flatMap { $0.pdfPositions ?? [] },
                     context: pieces.flatMap { $0.backgroundPositions ?? [] }, images: [])
        }

        func getEvidence(timing: ResearchTurnTiming? = nil) throws -> (Material, [Data]) {
            if !objects.isEmpty {
                let prepared = try index.objectEvidence(objects, includeImages: true, question: question, timing: timing, parsed: request)
                if timing != nil { initialChecks = prepared.material.evidenceChecks }
                return (Material(body: prepared.material.text, primary: prepared.material.pdfPositions ?? [],
                                 context: prepared.material.backgroundPositions ?? [],
                                 images: prepared.images.map(digest)), prepared.images)
            }
            let pieces = try index.prepare(request)
            if timing != nil { initialChecks = pieces.flatMap { $0.evidenceChecks ?? [] } }
            return (merge(pieces), [])
        }

        func mapped(_ material: Material) -> Bool {
            guard let (_, original) = index.reference.verifiedPDF(),
                  let firstPage = material.primary.first?.page else { return false }
            let positions = material.primary + material.context
            return (try? ResearchPDFEvidenceReader.prepare(data: original, filename: study.lastPathComponent,
                positions: positions, firstPage: firstPage, requireMappedPositions: true)) != nil
        }

        let fetching = ContinuousClock.now
        do {
            let timing = ResearchTurnTiming()
            let (first, crops) = try getEvidence(timing: timing)
            sample.stages = timing.measurements()
            sample.evidenceChecks = initialChecks
            sample.evidenceMilliseconds = milliseconds(since: fetching)
            sample.material = first
            for (number, crop) in crops.enumerated() {
                let format = crop.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? "png" : "jpg"
                try crop.write(to: output.appendingPathComponent("original-\(number + 1).\(format)"))
            }
            for _ in 0..<3 {
                let cached = ContinuousClock.now
                let next = try getEvidence().0
                sample.cachedEvidenceMilliseconds.append(milliseconds(since: cached))
                guard first == next else {
                    throw ResearchMaterialError.message("Cached evidence differed from initial evidence.")
                }
            }
            sample.sourceMappingVerified = mapped(first)
            // Compare the final local request material with the raw benchmark
            // artifact without changing the historical scoring or timing.
            if !objects.isEmpty {
                let start = ContinuousClock.now
                let packet = try DSHPetCommandClient.readPDFObjects(index, ids: objects, question: question,
                    allowImages: true, selection: nil, parsed: request)
                sample.appPreparationMilliseconds = milliseconds(since: start)
                guard packet.text.hasPrefix(first.body),
                      (packet.pdfPositions ?? []) == first.primary,
                      (packet.backgroundPositions ?? []) == first.context,
                      packet.documentImages.map(digest) == first.images,
                      packet.evidenceChecks == initialChecks,
                      (packet.verifiedExcerpts ?? []).allSatisfy({ $0.text(in: packet.text) != nil }) else {
                    throw ResearchMaterialError.message("原页证据与科研窗口准备的材料不一致。")
                }
                sample.appObjectMaterialSHA256 = digest(Data(packet.text.utf8))
            }
        } catch let review as ResearchPDFReviewRequired {
            sample.evidenceMilliseconds = milliseconds(since: fetching)
            sample.error = review.localizedDescription
            sample.reviewMaterial = merge(review.materials)
            sample.sourceMappingVerified = sample.reviewMaterial.map(mapped)
        } catch {
            sample.error = error.localizedDescription
            if sample.evidenceMilliseconds == nil {
                sample.evidenceMilliseconds = milliseconds(since: fetching)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sample).write(to: output.appendingPathComponent("evidence.json"))
    }
}
