import Foundation
import os

/// A local, content-free timeline. Only milestones and a random correlation ID
/// are logged. Concurrent spans may overlap and must not be added together.
final class ResearchTurnTiming: @unchecked Sendable {
    enum Point: String {
        case begin, fileChecked, evidenceStarted, objectLookupStarted, objectLookupCompleted, glyphStarted, glyphCompleted
        case cropStarted, cropCompleted, coverageChecked, evidenceReady
        case encodeStarted, encodeCompleted, sessionReady, provenanceReady, bridgeSent, bridgeAccepted
        case firstStream, firstDisplayed, completeDisplayed
    }

    let id = UUID()
    private let start = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var points: [Point: TimeInterval] = [:]
    private var finished = false
    private let indexPreparation: TimeInterval?
    private let reusedIndex: Bool
    private static let logger = Logger(subsystem: "com.local.research-companion", category: "research-timing")

    init(indexPreparation: TimeInterval? = nil, reusedIndex: Bool = false) {
        self.indexPreparation = indexPreparation
        self.reusedIndex = reusedIndex
    }

    func mark(_ point: Point) {
        let value = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        lock.withLock {
            if !finished && points[point] == nil { points[point] = value }
        }
    }

    func measurements() -> [String: Double] {
        lock.withLock { Dictionary(uniqueKeysWithValues: points.map { ($0.key.rawValue, $0.value) }) }
    }

    func finish(_ outcome: String) {
        let line: String? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let timeline = points.sorted { $0.value < $1.value }
                .map { "\($0.key.rawValue)=\(Int($0.value.rounded()))" }.joined(separator: " ")
            let index = indexPreparation.map {
                " indexPreparationMs=\(Int(($0 * 1_000).rounded())) indexReused=\(reusedIndex)"
            } ?? ""
            return "turn=\(id.uuidString) outcome=\(outcome)\(index) \(timeline)"
        }
        if let line { Self.logger.notice("\(line, privacy: .public)") }
    }
}
