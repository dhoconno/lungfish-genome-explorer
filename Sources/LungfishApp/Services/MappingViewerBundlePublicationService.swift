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
    case atomicPublicationFailed(URL, URL, String)
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
        case .atomicPublicationFailed(let candidate, let final, let detail):
            return "Could not atomically publish \(candidate.lastPathComponent) as \(final.lastPathComponent): \(detail)"
        case .rollbackFailed(let url, let detail):
            return "Could not restore \(url.lastPathComponent) after mapping viewer publication failed: \(detail)"
        }
    }
}

enum MappingViewerBundlePublicationService {
    private static let mappingResultFilename = "mapping-result.json"

    static func publishCandidate(
        candidateBundleURL: URL,
        finalBundleURL: URL,
        fileManager: FileManager = .default,
        finalize: (URL) throws -> Void
    ) throws {
        let candidate = candidateBundleURL.standardizedFileURL
        let final = finalBundleURL.standardizedFileURL
        guard candidate.deletingLastPathComponent() == final.deletingLastPathComponent(),
              candidate != final else {
            throw MappingViewerBundlePublicationError.invalidCandidateLocation(candidate, final)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MappingViewerBundlePublicationError.missingViewerBundle(candidate)
        }

        let replacingExisting = fileManager.fileExists(atPath: final.path)
        try atomicRename(
            candidate,
            final,
            flags: UInt32(replacingExisting ? RENAME_SWAP : RENAME_EXCL)
        )

        do {
            try rehydrateImportedBAMProvenance(
                in: final,
                replacingRoot: candidate,
                with: final,
                fileManager: fileManager
            )
            try finalize(final)
            if replacingExisting {
                // Finalization has committed the result sidecars. A cleanup
                // failure must not swap the old viewer back underneath them;
                // retaining the hidden displaced bundle is consistent and the
                // caller's deferred cleanup gets another safe attempt.
                try? fileManager.removeItem(at: candidate)
            }
        } catch {
            let originalError = error
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
        fileManager: FileManager = .default
    ) throws {
        let resultDirectory = resultDirectoryURL.standardizedFileURL
        let sourceBundle = sourceReferenceBundleURL.standardizedFileURL
        let viewerBundle = viewerBundleURL.standardizedFileURL
        let mappingResultURL = resultDirectory.appendingPathComponent(mappingResultFilename)
        let mappingProvenanceURL = resultDirectory.appendingPathComponent(MappingProvenance.filename)
        let canonicalProvenanceURL = resultDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let snapshots = try [mappingResultURL, mappingProvenanceURL, canonicalProvenanceURL].map {
            SidecarSnapshot(url: $0, data: fileManager.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil)
        }

        do {
            try result.save(to: resultDirectory)
            if let provenance = MappingProvenance.load(from: resultDirectory) {
                try provenance
                    .withViewerBundleURL(viewerBundle)
                    .withSourceReferenceBundleURL(sourceBundle)
                    .save(to: resultDirectory)
            }
            try rewriteCanonicalProvenance(
                result: result,
                resultDirectoryURL: resultDirectory,
                sourceReferenceBundleURL: sourceBundle,
                viewerBundleURL: viewerBundle,
                fileManager: fileManager
            )
        } catch {
            do {
                try restore(snapshots, fileManager: fileManager)
            } catch let rollbackError {
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
        fileManager: FileManager
    ) throws {
        let publicationStartedAt = Date()
        let canonicalURL = resultDirectoryURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        guard let envelope = try ProvenanceEnvelopeReader.load(from: resultDirectoryURL) else {
            throw MappingViewerBundlePublicationError.missingCanonicalProvenance(canonicalURL)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: viewerBundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MappingViewerBundlePublicationError.missingViewerBundle(viewerBundleURL)
        }

        let mappingResultURL = resultDirectoryURL.appendingPathComponent(mappingResultFilename)
        let mappingResultDescriptor = try ProvenanceFileDescriptor.file(
            url: mappingResultURL,
            format: .json,
            role: .output
        )
        let viewerDescriptors = try viewerOutputDescriptors(
            viewerBundleURL: viewerBundleURL,
            fileManager: fileManager
        )
        let publicationOutputs = deduplicated([mappingResultDescriptor] + viewerDescriptors)
        let refreshedFiles = try envelope.files.map {
            try refreshedMappingResultDescriptor($0, mappingResultURL: mappingResultURL)
        }
        let refreshedOutputs = try envelope.outputs.map {
            try refreshedMappingResultDescriptor($0, mappingResultURL: mappingResultURL)
        }
        let refreshedPrimaryOutput = try envelope.output.map {
            try refreshedMappingResultDescriptor($0, mappingResultURL: mappingResultURL)
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
                outputs: try step.outputs.map {
                    try refreshedMappingResultDescriptor($0, mappingResultURL: mappingResultURL)
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

        try ProvenanceWriter(signingProvider: nil).write(updatedEnvelope, to: resultDirectoryURL)
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
            try rehydrateAlignmentMetadataDatabase(
                at: databaseURL,
                replacingRoot: candidateBundleURL,
                with: finalBundleURL
            )
        }

        for sidecar in alignmentArtifacts
            where sidecar.lastPathComponent.hasSuffix(".import.lungfish-provenance.json") {
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
            let remappedURL = URL(fileURLWithPath: remappedPath)
            guard fileManager.fileExists(atPath: remappedURL.path) else {
                throw MappingViewerBundlePublicationError.missingViewerPayload(remappedURL)
            }
            return try ProvenanceFileDescriptor.file(
                url: remappedURL,
                format: descriptor.format,
                role: descriptor.role,
                originPath: descriptor.originPath.map(remapString),
                sourceProvenancePath: descriptor.sourceProvenancePath.map(remapString)
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
                try ProvenanceFileDescriptor.file(url: $0, format: .json, role: .output)
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
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.pathComponents.count > resolvedRoot.pathComponents.count,
              resolvedCandidate.pathComponents.starts(with: resolvedRoot.pathComponents) else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        return try ProvenanceFileDescriptor.file(url: candidate, format: format, role: role)
    }

    private static func refreshedMappingResultDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        mappingResultURL: URL
    ) throws -> ProvenanceFileDescriptor {
        guard URL(fileURLWithPath: descriptor.path).standardizedFileURL == mappingResultURL.standardizedFileURL else {
            return descriptor
        }
        return try ProvenanceFileDescriptor.file(
            url: mappingResultURL,
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

    private static func restore(
        _ snapshots: [SidecarSnapshot],
        fileManager: FileManager
    ) throws {
        var firstError: Error?
        for snapshot in snapshots {
            do {
                if let data = snapshot.data {
                    try data.write(to: snapshot.url, options: .atomic)
                } else if fileManager.fileExists(atPath: snapshot.url.path) {
                    try fileManager.removeItem(at: snapshot.url)
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private struct SidecarSnapshot {
        let url: URL
        let data: Data?
    }
}
