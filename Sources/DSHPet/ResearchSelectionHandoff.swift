import Darwin

/// Restricts each step to its expected foreground owner. A third app aborts the
/// handoff even if it switches back before the asynchronous read completes.
enum ResearchSelectionHandoff {
    case readingInChat
    case activatingSource
    case readingSource
    case readingSafariService

    func permits(_ front: pid_t?, owner: pid_t, source: pid_t) -> Bool {
        switch self {
        case .readingInChat: front == owner
        case .activatingSource, .readingSafariService: front == owner || front == source
        case .readingSource: front == source
        }
    }

    func shouldReturn(from front: pid_t?, source: pid_t, sourceStillBound: Bool) -> Bool {
        self != .readingInChat && front == source && sourceStillBound
    }
}
