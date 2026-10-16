// SystemTempScratchSweep.swift - LGE scratch in the system temp folder, marked and swept once its creator is gone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import os.log
import LungfishCore

private let logger = Logger(subsystem: LogSubsystem.io, category: "SystemTempScratchSweep")

/// Scratch that LGE makes in the system temp folder, and the sweep that removes what a gone process
/// left there (2.10 P1, 2.11 S3).
///
/// A run with no project, a volume the Nextflow scratch probe rejects and the space-free staging of
/// TaxTriage and nf-core all put scratch in the system temp folder, and a cancelled executor run
/// leaves its scratch for a sweep (P3). ``createMarkedDirectory(prefix:in:toolVersion:keepIntermediates:)`` gives each
/// such folder the ``OwnedWorkDirectoryMarker`` that project scratch gets, bound to the temp folder
/// and naming the creating process by PID, start time and boot session.
///
/// ``sweep(root:recordedPaths:userID:processInspector:)`` lists the folder once, reads one marker
/// for each candidate and removes a child only when every check holds:
/// - its name is an LGE prefix from ``prefixes`` followed by a UUID,
/// - it is a directory, not a symbolic link, and the user owns it,
/// - it holds LGE's marker, bound to this folder and this child, and not kept for debugging,
/// - its creator is gone, since no live process matches its PID, start time and boot session, and
/// - no record names it. No path in `recordedPaths` is the child, sits inside it or holds it, and
///   the child holds no provenance or analysis run record of its own.
public enum SystemTempScratchSweep {

    /// Why the sweep left a child of the system temp folder in place.
    public enum Refusal: String, Sendable, Equatable {
        case otherPrefix
        case symbolicLink
        case notADirectory
        case foreignOwner
        case namedByRecord
        case noMarker
        case keptForDebugging
        case liveCreator
        case creatorUnknown
        case removalFailed
    }

    /// What one sweep removed and what it left.
    public struct Outcome: Sendable, Equatable {
        public var removed: [URL] = []
        public var refused: [String: Refusal] = [:]

        public init() {}
    }

    /// The prefixes of the scratch LGE makes through ``ProjectTempDirectory``. The part of a name
    /// before its UUID must start with one, so `taxtriage-` covers `taxtriage-run-`,
    /// `taxtriage-project-` and `taxtriage-blast-`. A folder with another prefix is never claimed,
    /// whatever marker it holds.
    public static let prefixes: [String] = [
        ".lungfish-temp-", "application-export-import-", "batch-", "bbmerge-", "bbrepair-", "bbtools-",
        "blast-sources-", "classifier-extract-", "discriminating-sites-", "esviritu-", "export-",
        "extract-", "fastq-", "fetch-genome-", "genbank-", "geneious-import-", "genome-",
        "kraken2-extract-", "lungfish-", "mafft-", "managed-assembly-", "mapping-", "nfcore-",
        "primer-trim-", "ref-", "reference-merge-", "sequence-", "sidebar-zip-import-", "sra-batch-",
        "taxtriage-", "variants-", "vcf-import-",
    ]

    /// Record files whose presence in a child means a record names it. The second is the name in
    /// `ProvenanceRecorder.provenanceFilename` (LungfishWorkflow), read from the LungfishCore constant that holds it.
    static let recordFileNames = [AnalysisRunRecord.fileName, BundleAttachmentFilenamePolicy.provenanceSidecarSuffix]

    // MARK: - Marking

    /// Creates `<root>/<prefix><UUID>/` with an ``OwnedWorkDirectoryMarker`` bound to `root` that
    /// names the current process, the user's alone (`0700`), as project scratch is made.
    ///
    /// The marker binds the physical folder, so `/var/...` and `/private/var/...` name one root. The
    /// returned URL keeps the caller's spelling of `root`. With `keepIntermediates` the marker says
    /// the folder is kept for debugging, and the sweep never removes it.
    static func createMarkedDirectory(prefix: String, in root: URL, toolVersion: String, keepIntermediates: Bool = false) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let created = try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: physicalRoot,
                parentDirectoryURL: physicalRoot,
                prefix: prefix,
                runID: UUID(),
                processIdentity: try OwnedProcessIdentity.current(),
                state: .active,
                lockRelativePath: nil,
                keepIntermediates: keepIntermediates,
                toolName: "ProjectTempDirectory",
                toolVersion: toolVersion
            )
        )
        let directory = root.appendingPathComponent(created.lastPathComponent, isDirectory: true)
        logger.debug("Created marked system temp directory: \(directory.path, privacy: .public)")
        return directory
    }

    /// Creates `directory`, whose name its caller laid out before it touched the disk (Bracken's staging), the
    /// user's alone (`0700`), and binds the same marker to it and its parent folder. The sweep claims it only
    /// while its name is an LGE prefix from ``prefixes`` followed by a UUID.
    public static func createMarkedDirectory(at directory: URL, prefix: String, toolName: String, toolVersion: String) throws {
        let root = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let physical = physicalRoot.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(
            at: physical, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            physical,
            request: OwnedWorkDirectoryCreationRequest(
                projectURL: physicalRoot,
                parentDirectoryURL: physicalRoot,
                prefix: prefix,
                runID: UUID(),
                processIdentity: try OwnedProcessIdentity.current(),
                state: .active,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: toolName,
                toolVersion: toolVersion
            )
        )
        logger.debug("Created marked system temp directory: \(directory.path, privacy: .public)")
    }

    // MARK: - Sweeping

    /// Removes the children of `root` that LGE made and whose creator is gone. Runs no faster than
    /// one directory listing, one `lstat` and one marker read per candidate, and never on the main
    /// actor (the app starts it detached at utility priority).
    ///
    /// - Parameters:
    ///   - root: The system temp folder. Tests pass a folder of their own.
    ///   - recordedPaths: Paths that records name. A child that is one, holds one or sits inside one
    ///     stays.
    ///   - userID: The owner a child must have.
    ///   - processInspector: Reads a live process's identity, nil when the PID is gone.
    @discardableResult
    public static func sweep(
        root: URL,
        recordedPaths: [URL] = [],
        userID: uid_t = getuid(),
        processInspector: AnalysisRunScratch.ProcessInspector = {
            try OwnedProcessIdentity.inspect(processIdentifier: $0)
        }
    ) -> Outcome {
        let physicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var outcome = Outcome()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: physicalRoot.path) else {
            return outcome
        }
        let recorded = recordedPaths.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        for name in names.sorted() {
            let child = physicalRoot.appendingPathComponent(name, isDirectory: true)
            if let refusal = refusal(
                of: child,
                in: physicalRoot,
                recorded: recorded,
                userID: userID,
                processInspector: processInspector
            ) {
                outcome.refused[name] = refusal
                continue
            }
            do {
                try removeLeavingMarkerLast(child)
                outcome.removed.append(child)
            } catch {
                outcome.refused[name] = .removalFailed
                logger.warning(
                    "Could not remove abandoned scratch \(child.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if !outcome.removed.isEmpty {
            logger.info("Removed \(outcome.removed.count) abandoned scratch folders from \(physicalRoot.path, privacy: .public)")
        }
        return outcome
    }

    /// Whether `name` is an LGE prefix followed by a UUID.
    static func hasLGEPrefix(_ name: String) -> Bool {
        let uuidLength = 36
        guard name.count > uuidLength,
              UUID(uuidString: String(name.suffix(uuidLength))) != nil else { return false }
        let stem = name.dropLast(uuidLength)
        return prefixes.contains { stem.hasPrefix($0) }
    }

    /// The first check `child` fails, or nil when the sweep may remove it.
    private static func refusal(
        of child: URL,
        in root: URL,
        recorded: [String],
        userID: uid_t,
        processInspector: AnalysisRunScratch.ProcessInspector
    ) -> Refusal? {
        guard hasLGEPrefix(child.lastPathComponent) else { return .otherPrefix }
        var info = stat()
        guard lstat(child.path, &info) == 0 else { return .notADirectory }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .symbolicLink
        case S_IFDIR: break
        default: return .notADirectory
        }
        guard info.st_uid == userID else { return .foreignOwner }
        let path = child.path
        if recorded.contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }) {
            return .namedByRecord
        }
        guard let marker = try? OwnedWorkDirectoryMarkerStore.load(from: child, expectedProjectURL: root) else {
            return .noMarker
        }
        guard !marker.keepIntermediates else { return .keptForDebugging }
        if recordFileNames.contains(where: { holdsEntry(named: $0, in: child) }) {
            return .namedByRecord
        }
        let live: OwnedProcessIdentity?
        do {
            live = try processInspector(marker.processIdentifier)
        } catch {
            return .creatorUnknown // Cannot prove the creator is gone, so fail closed.
        }
        if let live, marker.matchesProcessIdentity(live) { return .liveCreator }
        return nil
    }

    private static func holdsEntry(named name: String, in directory: URL) -> Bool {
        var info = stat()
        return lstat(directory.appendingPathComponent(name).path, &info) == 0
    }

    /// Removes the contents first and the marker with the folder last, so a sweep cut short leaves a
    /// folder the next launch still claims. A quit, a crash or one locked file part way through would
    /// otherwise leave an unmarked remainder that no launch claims again.
    private static func removeLeavingMarkerLast(_ child: URL) throws {
        let fileManager = FileManager.default
        var firstFailure: Error?
        for entry in try fileManager.contentsOfDirectory(atPath: child.path) where entry != OwnedWorkDirectoryMarker.fileName {
            do {
                try fileManager.removeItem(at: child.appendingPathComponent(entry))
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
        try fileManager.removeItem(at: child)
    }
}
