// MetagenomicsSiblingRootCloneInstaller.swift - Clone an identical database from another channel's root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "MetagenomicsSiblingRootClone")

public enum MetagenomicsSiblingRootCloneError: Error, LocalizedError, Sendable, Equatable {
    case payloadDigestMismatch(expected: String, actual: String)
    case missingRequiredFiles([String])
    case archiveIdentityUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .payloadDigestMismatch(let expected, let actual):
            return "The cloned payload digest \(actual) does not match the sibling's recorded digest \(expected)."
        case .missingRequiredFiles(let files):
            return "The sibling copy is missing required files: \(files.joined(separator: ", "))."
        case .archiveIdentityUnavailable(let id):
            return "The sibling copy of '\(id)' has no recorded archive checksum to verify against the pinned manifest."
        }
    }
}

/// Installs a catalog database by APFS-cloning an identical, verified copy that
/// another channel already installed under a sibling storage root.
///
/// The sibling's registry row must describe the same catalog entry built from
/// the same recipe, be ready, local, and carry a payload digest. The clone is
/// re-digested and must match that digest before it is promoted, and it gets
/// its own canonical provenance receipt naming the sibling as its source.
struct MetagenomicsSiblingRootCloneInstaller: Sendable {
    typealias SiblingDatabaseRootsProvider = @Sendable (_ databasesBaseURL: URL) -> [URL]

    struct Source: Sendable, Equatable {
        let entry: MetagenomicsDatabaseInfo
        let path: URL
        let siblingDatabasesRoot: URL
    }

    private let siblingDatabaseRoots: SiblingDatabaseRootsProvider
    private let provenanceWriter: CanonicalMetagenomicsDatabaseInstallProvenanceWriter
    private let manifest: ManagedToolLock
    private let now: @Sendable () -> Date
    private let uuid: @Sendable () -> UUID

    init(
        siblingDatabaseRoots: @escaping SiblingDatabaseRootsProvider,
        provenanceWriter: CanonicalMetagenomicsDatabaseInstallProvenanceWriter = CanonicalMetagenomicsDatabaseInstallProvenanceWriter(),
        manifest: ManagedToolLock = .bundled,
        now: @escaping @Sendable () -> Date = Date.init,
        uuid: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.siblingDatabaseRoots = siblingDatabaseRoots
        self.provenanceWriter = provenanceWriter
        self.manifest = manifest
        self.now = now
        self.uuid = uuid
    }

    /// The production provider: every other existing upstream channel root on
    /// the same volume, mapped to its `databases/` directory.
    static func channelSiblingDatabaseRoots(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> SiblingDatabaseRootsProvider {
        { databasesBaseURL in
            ManagedStorageChannelRoots.siblingRoots(of: databasesBaseURL.deletingLastPathComponent(), homeDirectory: homeDirectory)
                .map { $0.appendingPathComponent("databases", isDirectory: true) }
        }
    }

    /// Finds a sibling installation of `database` that can be cloned.
    func findSource(for database: MetagenomicsDatabaseInfo, databasesBaseURL: URL) -> Source? {
        guard let catalogID = database.catalogID, let recipe = database.installationRecipe else { return nil }
        let fileManager = FileManager.default
        for siblingRoot in siblingDatabaseRoots(databasesBaseURL.standardizedFileURL) {
            let manifestURL = siblingRoot.appendingPathComponent("metagenomics-db-registry.json")
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let manifest = try? decoder.decode(DatabaseManifest.self, from: data) else { continue }
            for entry in manifest.databases {
                guard entry.catalogID == catalogID, entry.status == .ready, !entry.isExternal,
                      entry.installationRecipe == recipe, entry.payloadDigest?.isEmpty == false,
                      let path = entry.path?.standardizedFileURL else { continue }
                if case .kraken2Special = recipe, entry.version != database.version { continue }
                var isDirectory = ObjCBool(false)
                guard fileManager.fileExists(atPath: path.path, isDirectory: &isDirectory), isDirectory.boolValue,
                      path.path.hasPrefix(siblingRoot.standardizedFileURL.path + "/"),
                      (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      APFSCloneSupport.onSameVolume(path, databasesBaseURL) else { continue }
                return Source(entry: entry, path: path, siblingDatabasesRoot: siblingRoot)
            }
        }
        return nil
    }

    /// Clones a sibling installation into place, or returns `nil` when no
    /// sibling has one. Throws when a candidate was found but could not be
    /// verified, so the caller falls back to a download.
    func prepareClone(
        database: MetagenomicsDatabaseInfo,
        databasesBaseURL: URL,
        progress: @Sendable @escaping (Double, String) -> Void
    ) throws -> PreparedMetagenomicsDatabaseInstallation? {
        guard let source = findSource(for: database, databasesBaseURL: databasesBaseURL) else { return nil }
        let started = now()
        let fileManager = FileManager.default
        let finalURL = MetagenomicsDatabaseInstaller.installationURL(for: database, databasesBaseURL: databasesBaseURL)
        let parent = finalURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".install-\(uuid().uuidString)", isDirectory: true)
        let siblingLabel = source.siblingDatabasesRoot.deletingLastPathComponent().lastPathComponent

        progress(0.05, "Cloning \(database.name) from \(siblingLabel)…")
        try APFSCloneSupport.cloneItem(at: source.path, to: staging)
        var backupURL: URL?
        var didPromote = false
        do {
            try Task.checkCancellation()
            // The sibling's receipt describes the sibling. This copy gets its own.
            let inheritedSidecar = staging.appendingPathComponent(ProvenanceWriter.provenanceFilename)
            if fileManager.fileExists(atPath: inheritedSidecar.path) {
                try fileManager.removeItem(at: inheritedSidecar)
            }
            let missing = MetagenomicsDatabaseRegistry.missingRequiredFiles(in: staging, tool: database.tool)
            guard missing.isEmpty else { throw MetagenomicsSiblingRootCloneError.missingRequiredFiles(missing) }

            progress(0.4, "Verifying \(database.name)…")
            let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: staging)
            guard let expected = source.entry.payloadDigest, snapshot.aggregateSHA256 == expected else {
                throw MetagenomicsSiblingRootCloneError.payloadDigestMismatch(
                    expected: source.entry.payloadDigest ?? "", actual: snapshot.aggregateSHA256
                )
            }
            try Task.checkCancellation()

            let inputs = try archiveIdentityInputs(database: database, source: source)
            let resolved: [String: ParameterValue] = [
                "databaseRoot": .file(staging),
                "installSource": .string("sibling-root-clone"),
                "clonedFrom": .string(source.path.path),
                "clonedFromRoot": .string(source.siblingDatabasesRoot.deletingLastPathComponent().path),
                "clonedFromVersion": .string(source.entry.version ?? "unknown"),
                "clonedFromPayloadDigest": .string(expected),
                "invocationKind": .string("swift-api"),
            ]
            let completed = now()
            let step = MetagenomicsDatabaseInstallStepEvidence(
                toolName: "Lungfish sibling-root clone", toolVersion: WorkflowRun.currentAppVersion,
                argv: ["clonefile", source.path.path, finalURL.path], durableReplayArgv: [],
                resolvedOptions: resolved, runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: inputs, outputs: snapshot.files, exitStatus: 0,
                startedAt: started, completedAt: completed, stderr: ""
            )
            let recipeSource = database.installationRecipe.map { recipe -> String in
                switch recipe {
                case .archive(let url): return url.absoluteString
                case .kraken2Special(let type): return type.rawValue
                }
            } ?? "unknown"
            let attempt = MetagenomicsDatabaseInstallAttempt(
                database: database, finalURL: finalURL, recipeSource: recipeSource,
                explicitOptions: ["catalogID": .string(database.catalogID ?? "unknown")],
                defaultOptions: [:], resolvedOptions: resolved, steps: [step],
                startedAt: started, completedAt: completed
            )

            progress(0.9, "Installing \(database.name)…")
            if fileManager.fileExists(atPath: finalURL.path) {
                let backup = parent.appendingPathComponent(".backup-\(uuid().uuidString)", isDirectory: true)
                try fileManager.moveItem(at: finalURL, to: backup)
                backupURL = backup
            }
            try fileManager.moveItem(at: staging, to: finalURL)
            didPromote = true
            let finalSnapshot = MetagenomicsDatabasePayloadSnapshot(
                rootURL: staging, files: snapshot.files,
                aggregateSHA256: snapshot.aggregateSHA256, totalSizeBytes: snapshot.totalSizeBytes
            )
            try provenanceWriter.writeSuccess(attempt, snapshot: finalSnapshot)
            let version: String
            if case .kraken2Special = database.installationRecipe {
                version = database.version ?? source.entry.version ?? "cloned"
            } else {
                version = source.entry.version ?? "cloned-\(snapshot.aggregateSHA256.prefix(12))"
            }
            logger.info("Cloned '\(database.name, privacy: .public)' from \(source.path.path, privacy: .public)")
            progress(1, "Verifying…")
            return PreparedMetagenomicsDatabaseInstallation(
                result: .init(
                    finalURL: finalURL, version: version, payloadDigest: snapshot.aggregateSHA256,
                    sizeOnDisk: Int64(clamping: snapshot.totalSizeBytes)
                ),
                stagingURL: staging, backupURL: backupURL
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            if didPromote { try? fileManager.removeItem(at: finalURL) }
            if let backupURL, fileManager.fileExists(atPath: backupURL.path), !fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.moveItem(at: backupURL, to: finalURL)
            }
            throw error
        }
    }

    /// For a pinned archive, the receipt must carry the received archive
    /// identity. The sibling's canonical receipt recorded it when it verified
    /// the download, so the clone inherits that evidence.
    private func archiveIdentityInputs(database: MetagenomicsDatabaseInfo, source: Source) throws -> [ProvenanceFileDescriptor] {
        guard case .archive(let archiveURL)? = database.installationRecipe else { return [] }
        let sidecar = source.path.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let envelope = try? ProvenanceEnvelopeReader.loadCanonical(fromSidecar: sidecar)
        let recordedSHA256 = envelope?.options.resolvedDefaults["receivedArchiveSHA256"]?.stringValue
        let recordedSize = envelope?.options.resolvedDefaults["receivedArchiveSizeBytes"]?.integerValue
        guard let recordedSHA256, !recordedSHA256.isEmpty, let recordedSize else {
            if let catalogID = database.catalogID, let spec = manifest.database(id: catalogID),
               spec.url == archiveURL.absoluteString, spec.sha256 != nil || spec.md5 != nil {
                throw MetagenomicsSiblingRootCloneError.archiveIdentityUnavailable(catalogID)
            }
            return []
        }
        return [ProvenanceFileDescriptor(
            path: archiveURL.absoluteString, checksumSHA256: recordedSHA256,
            fileSize: UInt64(clamping: max(0, recordedSize)), role: .input
        )]
    }
}
