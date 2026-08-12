import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SQLite3

private let mappingViewerSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum MappingViewerBundlePublicationError: Error, LocalizedError {
    case missingCanonicalProvenance(URL)
    case missingViewerBundle(URL)
    case invalidViewerPayloadPath(String)
    case missingViewerPayload(URL)
    case invalidCandidateLocation(URL, URL)
    case unsafePublicationRoot(String)
    case atomicPublicationFailed(URL, URL, String)
    case concurrentSidecarChanges([String])
    case publicationOwnershipConflict(String, String?)
    case rollbackFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .missingCanonicalProvenance(let url):
            return "Canonical mapping provenance is missing at \(url.path)."
        case .missingViewerBundle(let url):
            return "The prepared mapping viewer bundle is missing at \(url.path)."
        case .invalidViewerPayloadPath(let path):
            return "The mapping viewer bundle declares an unsafe payload path: \(path)."
        case .missingViewerPayload(let url):
            return "The mapping viewer bundle payload is missing at \(url.path)."
        case .invalidCandidateLocation(let candidate, let final):
            return "The mapping viewer candidate \(candidate.path) must be adjacent to its final bundle \(final.path)."
        case .unsafePublicationRoot(let path):
            return "The mapping viewer publication root is not a no-follow directory: \(path)."
        case .atomicPublicationFailed(let candidate, let final, let detail):
            return "Could not atomically publish \(candidate.lastPathComponent) as \(final.lastPathComponent): \(detail)"
        case .concurrentSidecarChanges(let paths):
            return "Mapping viewer rollback preserved newer sidecar generations at: \(paths.joined(separator: ", "))."
        case .publicationOwnershipConflict(let path, let preservedPath):
            let suffix = preservedPath.map { " The displaced original was preserved at \($0)." } ?? ""
            return "The published mapping viewer root was replaced by another filesystem generation at \(path).\(suffix)"
        case .rollbackFailed(let url, let detail):
            return "Could not restore \(url.lastPathComponent) after mapping viewer publication failed: \(detail)"
        }
    }
}

struct MappingViewerBundlePublicationPlan {
    let finalBundleURL: URL
    let viewerOutputDescriptors: [ProvenanceFileDescriptor]
    fileprivate let rootIdentity: MappingViewerBundleRootIdentity

    fileprivate func matchesPublishedRoot() -> Bool {
        (try? MappingViewerBundlePublicationService.rootIdentity(at: finalBundleURL)) == rootIdentity
    }
}

private struct MappingViewerBundleRootIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

enum MappingViewerBundlePublicationService {
    private static let mappingResultFilename = "mapping-result.json"

    static func publishCandidate(
        candidateBundleURL: URL,
        finalBundleURL: URL,
        fileManager: FileManager = .default,
        finalize: (URL) throws -> Void
    ) throws {
        try publishCandidate(
            candidateBundleURL: candidateBundleURL,
            finalBundleURL: finalBundleURL,
            fileManager: fileManager
        ) { publishedURL, _ in
            try finalize(publishedURL)
        }
    }

    static func publishCandidate(
        candidateBundleURL: URL,
        finalBundleURL: URL,
        fileManager: FileManager = .default,
        finalize: (URL, MappingViewerBundlePublicationPlan) throws -> Void
    ) throws {
        let candidate = candidateBundleURL.standardizedFileURL
        let final = finalBundleURL.standardizedFileURL
        guard candidate.deletingLastPathComponent() == final.deletingLastPathComponent(),
              candidate != final else {
            throw MappingViewerBundlePublicationError.invalidCandidateLocation(candidate, final)
        }

        guard try validatePublicationRoot(
            candidate,
            allowMissing: false
        ) else {
            throw MappingViewerBundlePublicationError.missingViewerBundle(candidate)
        }
        let replacingExisting = try validatePublicationRoot(
            final,
            allowMissing: true
        )
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let resolvedFinal = final.resolvingSymlinksInPath()
        guard resolvedCandidate.deletingLastPathComponent()
                == resolvedFinal.deletingLastPathComponent() else {
            throw MappingViewerBundlePublicationError.invalidCandidateLocation(candidate, final)
        }
        let plan = try preparePublicationPlan(
            candidateBundleURL: candidate,
            finalBundleURL: final,
            fileManager: fileManager
        )
        try atomicRename(
            candidate,
            final,
            flags: UInt32(replacingExisting ? RENAME_SWAP : RENAME_EXCL)
        )

        do {
            try finalize(final, plan)
            guard plan.matchesPublishedRoot() else {
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(final.path, nil)
            }
            if replacingExisting {
                // Finalization has committed the result sidecars. A cleanup
                // failure must not swap the old viewer back underneath them;
                // retaining the hidden displaced bundle is consistent and the
                // caller's deferred cleanup gets another safe attempt.
                try? fileManager.removeItem(at: candidate)
            }
        } catch {
            let originalError = error
            guard plan.matchesPublishedRoot() else {
                let preservedOriginal = replacingExisting
                    ? try? preserveDisplacedOriginal(at: candidate)
                    : nil
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(
                    final.path,
                    preservedOriginal?.path
                )
            }
            do {
                if replacingExisting {
                    try atomicRename(candidate, final, flags: UInt32(RENAME_SWAP))
                    // The old viewer is restored atomically. Failure to remove
                    // the now-hidden failed candidate does not invalidate that
                    // rollback and must not replace the original error.
                    try? fileManager.removeItem(at: candidate)
                } else if fileManager.fileExists(atPath: final.path) {
                    try fileManager.removeItem(at: final)
                }
            } catch let rollbackError {
                throw MappingViewerBundlePublicationError.rollbackFailed(
                    final,
                    "\(rollbackError.localizedDescription); original error: \(originalError.localizedDescription)"
                )
            }
            throw originalError
        }
    }

    static func publish(
        result: MappingResult,
        resultDirectoryURL: URL,
        sourceReferenceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager = .default,
        beforeRollback: (() throws -> Void)? = nil,
        afterCanonicalRewrite: (() throws -> Void)? = nil,
        viewerPublicationPlan: MappingViewerBundlePublicationPlan? = nil,
        beforePublishedRootRecheck: (() throws -> Void)? = nil
    ) throws {
        let resultDirectory = resultDirectoryURL.standardizedFileURL
        let sourceBundle = sourceReferenceBundleURL.standardizedFileURL
        let viewerBundle = viewerBundleURL.standardizedFileURL
        if let viewerPublicationPlan {
            guard viewerPublicationPlan.finalBundleURL.standardizedFileURL == viewerBundle,
                  viewerPublicationPlan.matchesPublishedRoot() else {
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(viewerBundle.path, nil)
            }
        }
        let mappingResultURL = resultDirectory.appendingPathComponent(mappingResultFilename)
        let mappingProvenanceURL = resultDirectory.appendingPathComponent(MappingProvenance.filename)
        let snapshot = try ProvenancePublicationSnapshot(
            urls: deduplicatedURLs(
                [mappingResultURL, mappingProvenanceURL]
                    + ProvenancePublicationArtifacts.bundleRootArtifacts(for: resultDirectory)
            ),
            backupNamePrefix: "lungfish-mapping-viewer-publication",
            fileManager: fileManager
        )
        defer { snapshot.discard() }
        let tracker = try MappingViewerRollbackWitnessTracker(snapshot: snapshot)
        let stagingDirectory = resultDirectory.appendingPathComponent(
            ".mapping-viewer-publication-\(UUID().uuidString)",
            isDirectory: true
        )
        var displacedURLs: [URL] = []
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            for displacedURL in displacedURLs {
                try? fileManager.removeItem(at: displacedURL)
            }
        }

        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            try result.save(to: stagingDirectory)
            let mappingResultPublication = try snapshot.publishReplacement(
                from: stagingDirectory.appendingPathComponent(mappingResultFilename),
                to: mappingResultURL,
                replacingExisting: fileManager.fileExists(atPath: mappingResultURL.path),
                witness: tracker.currentWitness
            )
            tracker.replaceWitness(mappingResultPublication.witness)
            if let displacedURL = mappingResultPublication.displacedURL {
                displacedURLs.append(displacedURL)
            }
            if let provenance = MappingProvenance.load(from: resultDirectory) {
                try provenance
                    .withViewerBundleURL(viewerBundle)
                    .withSourceReferenceBundleURL(sourceBundle)
                    .save(to: stagingDirectory)
                let mappingProvenancePublication = try snapshot.publishReplacement(
                    from: stagingDirectory.appendingPathComponent(MappingProvenance.filename),
                    to: mappingProvenanceURL,
                    replacingExisting: true,
                    witness: tracker.currentWitness
                )
                tracker.replaceWitness(mappingProvenancePublication.witness)
                if let displacedURL = mappingProvenancePublication.displacedURL {
                    displacedURLs.append(displacedURL)
                }
            }
            try rewriteCanonicalProvenance(
                result: result,
                resultDirectoryURL: resultDirectory,
                sourceReferenceBundleURL: sourceBundle,
                viewerBundleURL: viewerBundle,
                fileManager: fileManager,
                viewerPublicationPlan: viewerPublicationPlan,
                writer: ProvenanceWriter(
                    publicationMutationDidOccur: tracker.observe,
                    signingProvider: nil
                )
            )
            try afterCanonicalRewrite?()
            try beforePublishedRootRecheck?()
            if let viewerPublicationPlan,
               !viewerPublicationPlan.matchesPublishedRoot() {
                throw MappingViewerBundlePublicationError.publicationOwnershipConflict(viewerBundle.path, nil)
            }
        } catch {
            do {
                try beforeRollback?()
                let preserved = try snapshot.restore(ifCurrentMatches: tracker.currentWitness)
                guard preserved.isEmpty else {
                    throw MappingViewerBundlePublicationError.concurrentSidecarChanges(
                        preserved.map(\.path)
                    )
                }
            } catch let rollbackError {
                if let concurrencyError = rollbackError as? MappingViewerBundlePublicationError,
                   case .concurrentSidecarChanges = concurrencyError {
                    throw concurrencyError
                }
                throw MappingViewerBundlePublicationError.rollbackFailed(
                    resultDirectory,
                    rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    private static func rewriteCanonicalProvenance(
        result: MappingResult,
        resultDirectoryURL: URL,
        sourceReferenceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager,
        viewerPublicationPlan: MappingViewerBundlePublicationPlan?,
        writer: ProvenanceWriter
    ) throws {
        let publicationStartedAt = Date()
        let canonicalURL = resultDirectoryURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        guard let envelope = try ProvenanceEnvelopeReader.load(from: resultDirectoryURL) else {
            throw MappingViewerBundlePublicationError.missingCanonicalProvenance(canonicalURL)
        }
        if viewerPublicationPlan == nil {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: viewerBundleURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MappingViewerBundlePublicationError.missingViewerBundle(viewerBundleURL)
            }
        }

        let mappingResultURL = resultDirectoryURL.appendingPathComponent(mappingResultFilename)
        let mappingResultDescriptor = try ProvenanceFileDescriptor.file(
            url: mappingResultURL,
            format: .json,
            role: .output
        )
        let mappingProvenanceURL = resultDirectoryURL.appendingPathComponent(MappingProvenance.filename)
        let mappingProvenanceDescriptor = fileManager.fileExists(atPath: mappingProvenanceURL.path)
            ? try ProvenanceFileDescriptor.file(
                url: mappingProvenanceURL,
                format: .json,
                role: .output
            )
            : nil
        let viewerDescriptors = try viewerPublicationPlan?.viewerOutputDescriptors
            ?? viewerOutputDescriptors(
                viewerBundleURL: viewerBundleURL,
                fileManager: fileManager
            )
        let publicationOutputs = deduplicated(
            [mappingResultDescriptor] + [mappingProvenanceDescriptor].compactMap { $0 } + viewerDescriptors
        )
        let refreshedFiles = try envelope.files
            .filter { $0.path != canonicalURL.path }
            .map {
                try refreshedPublicationSidecarDescriptor(
                    $0,
                    mappingResultURL: mappingResultURL,
                    mappingProvenanceURL: mappingProvenanceURL
                )
            }
        let refreshedOutputs = try envelope.outputs
            .filter { $0.path != canonicalURL.path }
            .map {
                try refreshedPublicationSidecarDescriptor(
                    $0,
                    mappingResultURL: mappingResultURL,
                    mappingProvenanceURL: mappingProvenanceURL
                )
            }
        let refreshedPrimaryOutput: ProvenanceFileDescriptor? = try envelope.output.flatMap { descriptor in
            guard descriptor.path != canonicalURL.path else { return nil }
            return try refreshedPublicationSidecarDescriptor(
                descriptor,
                mappingResultURL: mappingResultURL,
                mappingProvenanceURL: mappingProvenanceURL
            )
        }
        let refreshedSteps = try envelope.steps.map { step in
            ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                argv: step.argv,
                durableReplayArgv: step.durableReplayArgv,
                reproducibleCommand: step.reproducibleCommand,
                resolvedOptions: step.resolvedOptions,
                runtimeIdentity: step.runtimeIdentity,
                inputs: step.inputs,
                outputs: try step.outputs
                    .filter { $0.path != canonicalURL.path }
                    .map {
                        try refreshedPublicationSidecarDescriptor(
                            $0,
                            mappingResultURL: mappingResultURL,
                            mappingProvenanceURL: mappingProvenanceURL
                        )
                },
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }

        let argv = [
            "Lungfish.app",
            "prepare-mapping-viewer-bundle",
            "--mapping-result", resultDirectoryURL.path,
            "--source-reference-bundle", sourceReferenceBundleURL.path,
            "--viewer-bundle", viewerBundleURL.path,
        ]
        let inputs = try sourceInputDescriptors(
            sourceBundleURL: sourceReferenceBundleURL,
            fileManager: fileManager
        ) + [
            try ProvenanceFileDescriptor.file(url: result.bamURL, format: .bam, role: .input),
            try ProvenanceFileDescriptor.file(url: result.baiURL, format: .unknown, role: .index),
        ]
        let publicationCompletedAt = Date()
        let publicationStep = ProvenanceStep(
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            resolvedOptions: [
                "mappingResult": .file(resultDirectoryURL),
                "sourceReferenceBundle": .file(sourceReferenceBundleURL),
                "viewerBundle": .file(viewerBundleURL),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: inputs,
            outputs: publicationOutputs,
            exitStatus: 0,
            wallTimeSeconds: publicationCompletedAt.timeIntervalSince(publicationStartedAt),
            dependsOn: refreshedSteps.last.map { [$0.id] } ?? [],
            startedAt: publicationStartedAt,
            completedAt: publicationCompletedAt
        )
        let updatedOptions = ProvenanceOptions(
            explicit: envelope.options.explicit,
            defaults: envelope.options.defaults,
            resolvedDefaults: envelope.options.resolvedDefaults.merging([
                "sourceReferenceBundle": .file(sourceReferenceBundleURL),
                "viewerBundle": .file(viewerBundleURL),
            ]) { _, finalValue in finalValue }
        )
        let updatedEnvelope = ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: updatedOptions,
            runtimeIdentity: envelope.runtimeIdentity,
            files: deduplicated(refreshedFiles + inputs + publicationOutputs),
            output: refreshedPrimaryOutput,
            outputs: deduplicated(refreshedOutputs + publicationOutputs),
            steps: refreshedSteps + [publicationStep],
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )

        try writer.write(updatedEnvelope, to: resultDirectoryURL)
    }

    private static func validatePublicationRoot(
        _ url: URL,
        allowMissing: Bool
    ) throws -> Bool {
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        if status != 0 {
            if errno == ENOENT, allowMissing {
                return false
            }
            if errno == ENOENT {
                return false
            }
            throw MappingViewerBundlePublicationError.atomicPublicationFailed(
                url,
                url,
                POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription
            )
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            throw MappingViewerBundlePublicationError.unsafePublicationRoot(url.path)
        }
        let resolvedRoot = url.resolvingSymlinksInPath()
        let expectedRoot = url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent, isDirectory: true)
        guard resolvedRoot == expectedRoot else {
            throw MappingViewerBundlePublicationError.unsafePublicationRoot(url.path)
        }
        return true
    }

    fileprivate static func rootIdentity(at url: URL) throws -> MappingViewerBundleRootIdentity {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw MappingViewerBundlePublicationError.unsafePublicationRoot(url.path)
        }
        return MappingViewerBundleRootIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private static func preparePublicationPlan(
        candidateBundleURL: URL,
        finalBundleURL: URL,
        fileManager: FileManager
    ) throws -> MappingViewerBundlePublicationPlan {
        let identity = try rootIdentity(at: candidateBundleURL)
        try rehydrateImportedBAMProvenance(
            in: candidateBundleURL,
            replacingRoot: candidateBundleURL,
            with: finalBundleURL,
            fileManager: fileManager
        )
        let manifestURL = candidateBundleURL.appendingPathComponent(BundleManifest.filename)
        let candidateDescriptors = fileManager.fileExists(atPath: manifestURL.path)
            ? try viewerOutputDescriptors(
                viewerBundleURL: candidateBundleURL,
                fileManager: fileManager
            )
            : []
        let finalDescriptors = try candidateDescriptors.map {
            try remappedPublishedDescriptor(
                $0,
                from: candidateBundleURL,
                to: finalBundleURL
            )
        }
        return MappingViewerBundlePublicationPlan(
            finalBundleURL: finalBundleURL,
            viewerOutputDescriptors: finalDescriptors,
            rootIdentity: identity
        )
    }

    private static func remappedPublishedDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        from candidateRoot: URL,
        to finalRoot: URL
    ) throws -> ProvenanceFileDescriptor {
        let candidatePath = candidateRoot.standardizedFileURL.path
        let descriptorPath = URL(fileURLWithPath: descriptor.path).standardizedFileURL.path
        let finalPath: String
        if descriptorPath == candidatePath {
            finalPath = finalRoot.standardizedFileURL.path
        } else {
            let prefix = candidatePath + "/"
            guard descriptorPath.hasPrefix(prefix) else {
                throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(descriptor.path)
            }
            finalPath = finalRoot.standardizedFileURL.path + "/" + descriptorPath.dropFirst(prefix.count)
        }
        return ProvenanceFileDescriptor(
            path: finalPath,
            checksumSHA256: descriptor.checksumSHA256,
            fileSize: descriptor.fileSize,
            format: descriptor.format,
            role: descriptor.role,
            originPath: descriptor.originPath,
            sourceProvenancePath: descriptor.sourceProvenancePath
        )
    }

    private static func preserveDisplacedOriginal(at candidateURL: URL) throws -> URL {
        let preservedURL = candidateURL.deletingLastPathComponent().appendingPathComponent(
            ".\(candidateURL.lastPathComponent).ownership-conflict-\(UUID().uuidString)",
            isDirectory: true
        )
        try atomicRename(candidateURL, preservedURL, flags: UInt32(RENAME_EXCL))
        return preservedURL
    }

    private static func atomicRename(
        _ source: URL,
        _ destination: URL,
        flags: UInt32
    ) throws {
        let status = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    flags
                )
            }
        }
        guard status == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw MappingViewerBundlePublicationError.atomicPublicationFailed(
                source,
                destination,
                POSIXError(code).localizedDescription
            )
        }
    }

    private static func rehydrateImportedBAMProvenance(
        in publishedBundleURL: URL,
        replacingRoot candidateBundleURL: URL,
        with finalBundleURL: URL,
        fileManager: FileManager
    ) throws {
        let alignmentsURL = publishedBundleURL.appendingPathComponent("alignments", isDirectory: true)
        guard fileManager.fileExists(atPath: alignmentsURL.path) else { return }
        let alignmentArtifacts = try fileManager.contentsOfDirectory(
            at: alignmentsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for databaseURL in alignmentArtifacts where databaseURL.lastPathComponent.hasSuffix(".stats.db") {
            try validateRegularPayloadNoFollow(databaseURL)
            try rehydrateAlignmentMetadataDatabase(
                at: databaseURL,
                replacingRoot: candidateBundleURL,
                with: finalBundleURL
            )
        }

        for sidecar in alignmentArtifacts
            where sidecar.lastPathComponent.hasSuffix(".import.lungfish-provenance.json") {
            try validateRegularPayloadNoFollow(sidecar)
            let envelope = try ProvenanceJSON.decoder.decode(
                ProvenanceEnvelope.self,
                from: Data(contentsOf: sidecar)
            )
            let rehydrated = try remappedEnvelope(
                envelope,
                replacingRoot: candidateBundleURL,
                with: finalBundleURL,
                fileManager: fileManager
            )
            try ProvenanceWriter(signingProvider: nil).write(rehydrated, toSidecar: sidecar)
        }
    }

    private static func rehydrateAlignmentMetadataDatabase(
        at databaseURL: URL,
        replacingRoot candidateBundleURL: URL,
        with finalBundleURL: URL
    ) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            sqlite3_close(database)
            throw MappingViewerBundlePublicationError.atomicPublicationFailed(
                candidateBundleURL,
                finalBundleURL,
                "Could not open imported BAM metadata for path rehydration: \(detail)"
            )
        }
        defer { sqlite3_close_v2(database) }

        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw sqliteRehydrationError(
                database: database,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
        }
        do {
            try executePathReplacement(
                """
                UPDATE file_info
                SET value = replace(value, ?1, ?2)
                WHERE instr(value, ?1) > 0
                """,
                database: database,
                candidatePath: candidateBundleURL.standardizedFileURL.path,
                finalPath: finalBundleURL.standardizedFileURL.path,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
            try executePathReplacement(
                """
                UPDATE provenance
                SET command = replace(command, ?1, ?2),
                    input_file = replace(input_file, ?1, ?2),
                    output_file = replace(output_file, ?1, ?2)
                WHERE instr(command, ?1) > 0
                   OR instr(COALESCE(input_file, ''), ?1) > 0
                   OR instr(COALESCE(output_file, ''), ?1) > 0
                """,
                database: database,
                candidatePath: candidateBundleURL.standardizedFileURL.path,
                finalPath: finalBundleURL.standardizedFileURL.path,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw sqliteRehydrationError(
                    database: database,
                    candidateBundleURL: candidateBundleURL,
                    finalBundleURL: finalBundleURL
                )
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func executePathReplacement(
        _ sql: String,
        database: OpaquePointer,
        candidatePath: String,
        finalPath: String,
        candidateBundleURL: URL,
        finalBundleURL: URL
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteRehydrationError(
                database: database,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, candidatePath, -1, mappingViewerSQLiteTransient)
        sqlite3_bind_text(statement, 2, finalPath, -1, mappingViewerSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteRehydrationError(
                database: database,
                candidateBundleURL: candidateBundleURL,
                finalBundleURL: finalBundleURL
            )
        }
    }

    private static func sqliteRehydrationError(
        database: OpaquePointer,
        candidateBundleURL: URL,
        finalBundleURL: URL
    ) -> MappingViewerBundlePublicationError {
        .atomicPublicationFailed(
            candidateBundleURL,
            finalBundleURL,
            "Could not rehydrate imported BAM metadata paths: \(String(cString: sqlite3_errmsg(database)))"
        )
    }

    private static func remappedEnvelope(
        _ envelope: ProvenanceEnvelope,
        replacingRoot candidateBundleURL: URL,
        with finalBundleURL: URL,
        fileManager: FileManager
    ) throws -> ProvenanceEnvelope {
        let remapString: (String) -> String = { value in
            value.replacingOccurrences(
                of: candidateBundleURL.standardizedFileURL.path,
                with: finalBundleURL.standardizedFileURL.path
            )
        }
        let remapDescriptor: (ProvenanceFileDescriptor) throws -> ProvenanceFileDescriptor = { descriptor in
            let remappedPath = remapString(descriptor.path)
            guard remappedPath != descriptor.path else { return descriptor }
            let candidateURL = URL(fileURLWithPath: descriptor.path)
            guard fileManager.fileExists(atPath: candidateURL.path) else {
                throw MappingViewerBundlePublicationError.missingViewerPayload(candidateURL)
            }
            try validateRegularPayloadNoFollow(candidateURL)
            let captured = try ProvenanceFileDescriptor.file(
                url: candidateURL,
                format: descriptor.format,
                role: descriptor.role,
                originPath: descriptor.originPath.map(remapString),
                sourceProvenancePath: descriptor.sourceProvenancePath.map(remapString)
            )
            return ProvenanceFileDescriptor(
                path: remappedPath,
                checksumSHA256: captured.checksumSHA256,
                fileSize: captured.fileSize,
                format: captured.format,
                role: captured.role,
                originPath: captured.originPath,
                sourceProvenancePath: captured.sourceProvenancePath
            )
        }
        let remapValue: (ParameterValue) -> ParameterValue = { value in
            remappedParameterValue(value, remapString: remapString)
        }
        let remapOptions: ([String: ParameterValue]) -> [String: ParameterValue] = { options in
            options.mapValues(remapValue)
        }
        let argv = envelope.argv.map(remapString)
        let steps = try envelope.steps.map { step in
            let stepArgv = step.argv.map(remapString)
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                argv: stepArgv,
                durableReplayArgv: step.durableReplayArgv?.map(remapString),
                reproducibleCommand: stepArgv.map(shellQuote).joined(separator: " "),
                resolvedOptions: remapOptions(step.resolvedOptions),
                runtimeIdentity: step.runtimeIdentity,
                inputs: try step.inputs.map(remapDescriptor),
                outputs: try step.outputs.map(remapDescriptor),
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
        return ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: argv,
            durableReplayArgv: envelope.durableReplayArgv?.map(remapString),
            reproducibleCommand: argv.map(shellQuote).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: remapOptions(envelope.options.explicit),
                defaults: remapOptions(envelope.options.defaults),
                resolvedDefaults: remapOptions(envelope.options.resolvedDefaults)
            ),
            runtimeIdentity: envelope.runtimeIdentity,
            files: try envelope.files.map(remapDescriptor),
            output: try envelope.output.map(remapDescriptor),
            outputs: try envelope.outputs.map(remapDescriptor),
            steps: steps,
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )
    }

    private static func remappedParameterValue(
        _ value: ParameterValue,
        remapString: (String) -> String
    ) -> ParameterValue {
        switch value {
        case .string(let string):
            return .string(remapString(string))
        case .file(let url):
            let remappedPath = remapString(url.path)
            guard remappedPath != url.path else { return value }
            return .file(URL(fileURLWithPath: remappedPath))
        case .array(let values):
            return .array(values.map { remappedParameterValue($0, remapString: remapString) })
        case .dictionary(let values):
            return .dictionary(values.mapValues { remappedParameterValue($0, remapString: remapString) })
        case .integer, .number, .boolean, .null:
            return value
        }
    }

    private static func shellQuote(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@%+=:,./-"))
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func sourceInputDescriptors(
        sourceBundleURL: URL,
        fileManager: FileManager
    ) throws -> [ProvenanceFileDescriptor] {
        let manifestURL = sourceBundleURL.appendingPathComponent(BundleManifest.filename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(manifestURL)
        }
        try validateRegularPayloadNoFollow(manifestURL)
        let manifest = try BundleManifest.load(from: sourceBundleURL)
        var descriptors = [
            ProvenanceFileDescriptor(path: sourceBundleURL.path, role: .reference),
            try ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .reference),
        ]
        if let genome = manifest.genome {
            descriptors.append(try descriptor(
                relativePath: genome.path,
                format: .fasta,
                role: .reference,
                bundleURL: sourceBundleURL,
                fileManager: fileManager
            ))
            if !genome.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: genome.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: sourceBundleURL,
                    fileManager: fileManager
                ))
            }
            if let gzipIndexPath = genome.gzipIndexPath, !gzipIndexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: gzipIndexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: sourceBundleURL,
                    fileManager: fileManager
                ))
            }
        }
        descriptors.append(contentsOf: try nonAlignmentPayloadDescriptors(
            manifest: manifest,
            bundleURL: sourceBundleURL,
            payloadRole: .reference,
            fileManager: fileManager
        ))
        return deduplicated(descriptors)
    }

    private static func viewerOutputDescriptors(
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws -> [ProvenanceFileDescriptor] {
        let manifestURL = viewerBundleURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(manifestURL)
        }
        try validateRegularPayloadNoFollow(manifestURL)
        let manifest = try BundleManifest.load(from: viewerBundleURL)
        var descriptors = [
            ProvenanceFileDescriptor(path: viewerBundleURL.path, role: .output),
            try ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output),
        ]
        if let genome = manifest.genome {
            descriptors.append(try descriptor(
                relativePath: genome.path,
                format: .fasta,
                role: .output,
                bundleURL: viewerBundleURL,
                fileManager: fileManager
            ))
            if !genome.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: genome.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
            if let gzipIndexPath = genome.gzipIndexPath, !gzipIndexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: gzipIndexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
        }
        descriptors.append(contentsOf: try nonAlignmentPayloadDescriptors(
            manifest: manifest,
            bundleURL: viewerBundleURL,
            payloadRole: .output,
            fileManager: fileManager
        ))
        for track in manifest.alignments {
            descriptors.append(try descriptor(
                relativePath: track.sourcePath,
                format: track.format == .cram ? .cram : .bam,
                role: .output,
                bundleURL: viewerBundleURL,
                fileManager: fileManager
            ))
            if !track.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: track.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
            if let metadataPath = track.metadataDBPath {
                descriptors.append(try descriptor(
                    relativePath: metadataPath,
                    format: .sqlite,
                    role: .output,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
        }
        let alignmentsURL = viewerBundleURL.appendingPathComponent("alignments", isDirectory: true)
        if fileManager.fileExists(atPath: alignmentsURL.path) {
            let importProvenanceSidecars = try fileManager.contentsOfDirectory(
                at: alignmentsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasSuffix(".import.lungfish-provenance.json") }
            descriptors.append(contentsOf: try importProvenanceSidecars.map {
                try validateRegularPayloadNoFollow($0)
                return try ProvenanceFileDescriptor.file(url: $0, format: .json, role: .output)
            })
        }
        return deduplicated(descriptors)
    }

    private static func nonAlignmentPayloadDescriptors(
        manifest: BundleManifest,
        bundleURL: URL,
        payloadRole: FileRole,
        fileManager: FileManager
    ) throws -> [ProvenanceFileDescriptor] {
        var descriptors: [ProvenanceFileDescriptor] = []
        for annotation in manifest.annotations {
            descriptors.append(try descriptor(
                relativePath: annotation.path,
                format: .bigBed,
                role: payloadRole,
                bundleURL: bundleURL,
                fileManager: fileManager
            ))
            if let databasePath = annotation.databasePath, !databasePath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: databasePath,
                    format: .sqlite,
                    role: payloadRole,
                    bundleURL: bundleURL,
                    fileManager: fileManager
                ))
            }
        }
        for variant in manifest.variants {
            descriptors.append(try descriptor(
                relativePath: variant.path,
                format: variantFormat(for: variant.path),
                role: payloadRole,
                bundleURL: bundleURL,
                fileManager: fileManager
            ))
            if !variant.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: variant.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: bundleURL,
                    fileManager: fileManager
                ))
            }
            if let databasePath = variant.databasePath, !databasePath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: databasePath,
                    format: .sqlite,
                    role: payloadRole,
                    bundleURL: bundleURL,
                    fileManager: fileManager
                ))
            }
        }
        for track in manifest.tracks {
            descriptors.append(try descriptor(
                relativePath: track.path,
                format: .bigWig,
                role: payloadRole,
                bundleURL: bundleURL,
                fileManager: fileManager
            ))
        }
        return descriptors
    }

    private static func variantFormat(for path: String) -> FileFormat {
        path.lowercased().hasSuffix(".bcf") ? .bcf : .vcf
    }

    private static func descriptor(
        relativePath: String,
        format: FileFormat,
        role: FileRole,
        bundleURL: URL,
        fileManager: FileManager
    ) throws -> ProvenanceFileDescriptor {
        let root = bundleURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.pathComponents.count > root.pathComponents.count,
              candidate.pathComponents.starts(with: root.pathComponents) else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(candidate)
        }
        try validateRegularPayloadNoFollow(candidate)
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.pathComponents.count > resolvedRoot.pathComponents.count,
              resolvedCandidate.pathComponents.starts(with: resolvedRoot.pathComponents) else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        return try ProvenanceFileDescriptor.file(url: candidate, format: format, role: role)
    }

    private static func validateRegularPayloadNoFollow(_ url: URL) throws {
        var information = stat()
        guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(url)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(url.path)
        }
    }

    private static func refreshedPublicationSidecarDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        mappingResultURL: URL,
        mappingProvenanceURL: URL
    ) throws -> ProvenanceFileDescriptor {
        let descriptorURL = URL(fileURLWithPath: descriptor.path).standardizedFileURL
        let refreshedURL: URL
        if descriptorURL == mappingResultURL.standardizedFileURL {
            refreshedURL = mappingResultURL
        } else if descriptorURL == mappingProvenanceURL.standardizedFileURL {
            refreshedURL = mappingProvenanceURL
        } else {
            return descriptor
        }
        return try ProvenanceFileDescriptor.file(
            url: refreshedURL,
            format: descriptor.format ?? .json,
            role: descriptor.role,
            originPath: descriptor.originPath,
            sourceProvenancePath: descriptor.sourceProvenancePath
        )
    }

    private static func deduplicated(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen: Set<String> = []
        return descriptors.filter { seen.insert($0.path).inserted }
    }

    private static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

}

private final class MappingViewerRollbackWitnessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ProvenancePublicationSnapshot
    private var witness: ProvenancePublicationRollbackWitness

    init(snapshot: ProvenancePublicationSnapshot) throws {
        self.snapshot = snapshot
        self.witness = try snapshot.captureRollbackWitness()
    }

    var currentWitness: ProvenancePublicationRollbackWitness {
        lock.withLock { witness }
    }

    func replaceWitness(_ witness: ProvenancePublicationRollbackWitness) {
        lock.withLock { self.witness = witness }
    }

    func observe(_ mutation: ProvenanceWriterMutation) throws {
        try lock.withLock {
            witness = try snapshot.refreshingRollbackWitness(witness, after: mutation)
        }
    }
}
