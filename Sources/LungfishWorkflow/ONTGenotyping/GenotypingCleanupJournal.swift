import Foundation
import LungfishIO

enum GenotypingCleanupJournalEvent: Sendable {
    case beforeInitialCreation
    case beforeTerminalAppend
}

enum GenotypingCleanupJournalPhase: String, Sendable {
    case initialCreation = "initial creation"
    case terminalAppend = "terminal append"
}

struct GenotypingCleanupJournalError: Error, LocalizedError, Sendable {
    let phase: GenotypingCleanupJournalPhase
    let underlyingDescription: String

    var errorDescription: String? {
        "Cleanup journal \(phase.rawValue) failed: \(underlyingDescription)"
    }
}

struct GenotypingCleanupPlanEntry: Codable, Sendable {
    let path: String
    let intendedAction: String
    let identity: FileSystemObjectIdentity
}

struct GenotypingCleanupPlanEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let state: String
    let terminalPayloadName: String
    let recoveryRule: String
    let entries: [GenotypingCleanupPlanEntry]
}

enum GenotypingCleanupJournal {
    static let planPayloadName = "cleanup-plan.json"
    static let terminalPayloadName = "cleanup-disposition.json"

    static func planEntries(
        _ candidates: [(url: URL, intendedAction: String)]
    ) throws -> [GenotypingCleanupPlanEntry] {
        var seen = Set<String>()
        return try candidates.compactMap { candidate in
            let url = candidate.url.standardizedFileURL
            guard seen.insert(url.path).inserted,
                  FileManager.default.fileExists(atPath: url.path) else {
                return nil
            }
            return GenotypingCleanupPlanEntry(
                path: url.path,
                intendedAction: candidate.intendedAction,
                identity: try FileSystemObjectIdentity.noFollow(url)
            )
        }
    }

    static func planData(
        runID: UUID,
        entries: [GenotypingCleanupPlanEntry]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            GenotypingCleanupPlanEnvelope(
                schemaVersion: 1,
                runID: runID,
                state: "planned-terminal-disposition-pending",
                terminalPayloadName: terminalPayloadName,
                recoveryRule:
                    "If the terminal payload is absent, compare each path's "
                    + "no-follow device/inode with its planned identity: "
                    + "absence means removed; the same identity means retained; "
                    + "a different identity means the path was replaced and "
                    + "must not be deleted automatically.",
                entries: entries
            )
        )
    }
}
