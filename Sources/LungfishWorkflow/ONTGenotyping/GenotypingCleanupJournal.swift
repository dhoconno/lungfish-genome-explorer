import Darwin
import Foundation
import LungfishIO

enum GenotypingCleanupJournalEvent: Sendable {
    case beforeInitialCreation
    case afterInitialCreationBeforeMutation
    case beforeTerminalAppend
}

enum GenotypingCleanupJournalPhase: String, Sendable {
    case initialCreation = "initial creation"
    case terminalAppend = "terminal append"
}

struct GenotypingCleanupJournalError: Error, LocalizedError, Sendable {
    let runID: UUID
    let operationPath: String
    let cleanupPlanPath: String
    let outputBundlePath: String
    let phase: GenotypingCleanupJournalPhase
    let publishedArtifactsValid: Bool
    let retainedRootPaths: [String]
    let underlyingDescription: String

    var errorDescription: String? {
        "Cleanup journal \(phase.rawValue) failed for run "
            + "\(runID.uuidString.lowercased()) at \(operationPath) "
            + "(plan: \(cleanupPlanPath), output: \(outputBundlePath), "
            + "published artifacts valid: \(publishedArtifactsValid), "
            + "retained roots: \(retainedRootPaths.joined(separator: ", "))): "
            + underlyingDescription
    }
}

enum GenotypingCleanupIntendedAction: String, Codable, Sendable {
    case removeOwnedWorkDirectory = "remove-owned-work-directory"
    case removeOwnedTemporaryWorkDirectory =
        "remove-owned-temporary-work-directory"
    case removeRegenerableWorkflowIntermediates =
        "remove-regenerable-workflow-intermediates"
    case removeRetiredPublicationDirectory =
        "remove-retired-publication-directory"
    case removeRegenerableAlignmentIntermediate =
        "remove-regenerable-alignment-intermediate"
    case removeOwnedSupportDirectoryAfterMarkerCompletion =
        "remove-owned-support-directory-after-marker-completion"
    case retainByRequest = "retain-by-request"
    case retainByRequestAfterMarkerCompletion =
        "retain-by-request-after-marker-completion"
}

struct GenotypingCleanupPlanEntry: Codable, Sendable {
    let path: String
    let intendedAction: GenotypingCleanupIntendedAction
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

struct GenotypingCleanupPlan: Sendable {
    let runID: UUID
    let operationURL: URL
    let outputBundleURL: URL
    let entriesByPath: [String: GenotypingCleanupPlanEntry]

    var entries: [GenotypingCleanupPlanEntry] {
        entriesByPath.values.sorted { $0.path < $1.path }
    }

    func entry(for url: URL) -> GenotypingCleanupPlanEntry? {
        entriesByPath[url.standardizedFileURL.path]
    }
}

enum GenotypingIdentityBoundCleanupOutcome: Sendable {
    case removed(quarantinePath: String)
    case retained(quarantinePath: String?)
    case identityMismatch(detail: String)
    case failed(detail: String)
}

enum GenotypingCleanupJournal {
    static let planPayloadName = "cleanup-plan.json"
    static let terminalPayloadName = "cleanup-disposition.json"

    static func planEntries(
        _ candidates: [
            (
                url: URL,
                intendedAction: GenotypingCleanupIntendedAction
            )
        ]
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

enum GenotypingIdentityBoundCleanup {
    static func remove(
        _ entry: GenotypingCleanupPlanEntry,
        remover: (URL) throws -> Void
    ) -> GenotypingIdentityBoundCleanupOutcome {
        withDetachedEntry(entry) { quarantineURL in
            try remover(quarantineURL)
            return .removed(quarantinePath: quarantineURL.path)
        }
    }

    static func mutateAndRetain(
        _ entry: GenotypingCleanupPlanEntry,
        mutation: (URL) throws -> Void
    ) -> GenotypingIdentityBoundCleanupOutcome {
        withDetachedEntry(entry) { quarantineURL in
            try mutation(quarantineURL)
            let originalURL = URL(fileURLWithPath: entry.path)
            let status = quarantineURL.path.withCString { source in
                originalURL.path.withCString { destination in
                    PortableExclusiveRename.renameatxNP(
                        AT_FDCWD,
                        source,
                        AT_FDCWD,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard status == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not exclusively restore retained cleanup "
                            + "target from \(quarantineURL.path) to "
                            + "\(originalURL.path).",
                    ]
                )
            }
            return .retained(quarantinePath: nil)
        }
    }

    private static func withDetachedEntry(
        _ entry: GenotypingCleanupPlanEntry,
        operation:
            (URL) throws -> GenotypingIdentityBoundCleanupOutcome
    ) -> GenotypingIdentityBoundCleanupOutcome {
        let originalURL = URL(fileURLWithPath: entry.path).standardizedFileURL
        let quarantineURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(originalURL.lastPathComponent).cleanup-quarantine-"
                    + UUID().uuidString.lowercased()
            )
        let detachStatus = originalURL.path.withCString { source in
            quarantineURL.path.withCString { quarantine in
                PortableExclusiveRename.renameatxNP(
                    AT_FDCWD,
                    source,
                    AT_FDCWD,
                    quarantine,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard detachStatus == 0 else {
            return .identityMismatch(
                detail:
                    "Could not exclusively detach planned cleanup target "
                    + "\(entry.path) (errno \(errno)); it was retained."
            )
        }

        let detachedIdentity: FileSystemObjectIdentity
        do {
            detachedIdentity = try FileSystemObjectIdentity.noFollow(
                quarantineURL
            )
        } catch {
            return .failed(
                detail:
                    "Detached cleanup quarantine \(quarantineURL.path) could "
                    + "not be inspected and was retained: "
                    + error.localizedDescription
            )
        }
        guard detachedIdentity == entry.identity else {
            let restoreStatus = quarantineURL.path.withCString { source in
                originalURL.path.withCString { destination in
                    PortableExclusiveRename.renameatxNP(
                        AT_FDCWD,
                        source,
                        AT_FDCWD,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            let retainedPath =
                restoreStatus == 0 ? originalURL.path : quarantineURL.path
            return .identityMismatch(
                detail:
                    "Planned identity \(entry.identity.device):"
                    + "\(entry.identity.inode) did not match detached identity "
                    + "\(detachedIdentity.device):\(detachedIdentity.inode); "
                    + "the replacement was retained at \(retainedPath)."
            )
        }

        do {
            return try operation(quarantineURL)
        } catch {
            let restoreStatus = quarantineURL.path.withCString { source in
                originalURL.path.withCString { destination in
                    PortableExclusiveRename.renameatxNP(
                        AT_FDCWD,
                        source,
                        AT_FDCWD,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            let retainedPath =
                restoreStatus == 0 ? originalURL.path : quarantineURL.path
            return .failed(
                detail:
                    "Identity-matched cleanup target was retained at "
                    + "\(retainedPath): \(error.localizedDescription)"
            )
        }
    }
}
