import Foundation

@MainActor
public final class ProjectSessionRegistry {
    private var sessionsByID: [UUID: ProjectSession] = [:]
    private var projectURLsBySessionID: [UUID: URL] = [:]
    private var insertionOrderBySessionID: [UUID: Int] = [:]
    private var nextInsertionOrder: Int = 0
    private var frontmostSessionID: UUID?

    public init() {}

    public func register(_ session: ProjectSession, projectURL: URL?) {
        sessionsByID[session.id] = session
        if insertionOrderBySessionID[session.id] == nil {
            insertionOrderBySessionID[session.id] = nextInsertionOrder
            nextInsertionOrder += 1
        }
        if let projectURL {
            projectURLsBySessionID[session.id] = Self.canonicalProjectURL(projectURL)
        } else {
            projectURLsBySessionID.removeValue(forKey: session.id)
        }
    }

    public func unregister(_ session: ProjectSession) {
        sessionsByID.removeValue(forKey: session.id)
        projectURLsBySessionID.removeValue(forKey: session.id)
        insertionOrderBySessionID.removeValue(forKey: session.id)
        if frontmostSessionID == session.id {
            frontmostSessionID = nil
        }
    }

    public func markFrontmost(_ session: ProjectSession) {
        sessionsByID[session.id] = session
        if insertionOrderBySessionID[session.id] == nil {
            insertionOrderBySessionID[session.id] = nextInsertionOrder
            nextInsertionOrder += 1
        }
        frontmostSessionID = session.id
    }

    public var frontmostSession: ProjectSession? {
        frontmostSessionID.flatMap { sessionsByID[$0] }
    }

    public func sessions(forProjectURL projectURL: URL) -> [ProjectSession] {
        let canonical = Self.canonicalProjectURL(projectURL)
        return sessionsByID.values
            .filter { projectURLsBySessionID[$0.id] == canonical }
            .sorted { lhs, rhs in
                (insertionOrderBySessionID[lhs.id] ?? Int.max) < (insertionOrderBySessionID[rhs.id] ?? Int.max)
            }
    }

    public func windowNumber(for session: ProjectSession) -> Int {
        guard let projectURL = projectURLsBySessionID[session.id] else { return 1 }
        let peers = sessionsByID.values
            .filter { projectURLsBySessionID[$0.id] == projectURL }
            .sorted { lhs, rhs in
                (insertionOrderBySessionID[lhs.id] ?? Int.max) < (insertionOrderBySessionID[rhs.id] ?? Int.max)
            }
        guard let index = peers.firstIndex(where: { $0.id == session.id }) else { return 1 }
        return index + 1
    }

    public static func canonicalProjectURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
