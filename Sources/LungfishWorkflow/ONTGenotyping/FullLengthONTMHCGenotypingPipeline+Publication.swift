import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func publishStagedResultBundle(
        stagedOutputURL: URL,
        finalOutputURL: URL,
        replacingExisting: Bool,
        payloadMappings: [(staged: ProvenanceFileDescriptor, final: ProvenanceFileDescriptor)]
    ) throws -> FullLengthONTMHCResultBundlePublicationRecord {
        try FullLengthONTMHCAlignmentSafety().requireDirectoryNoFollow(
            stagedOutputURL,
            role: "staged full-length MHC result bundle"
        )
        let startedAt = Date()
        let flags = UInt32(replacingExisting ? RENAME_SWAP : RENAME_EXCL)
        let initialErrorNumber: Int32?
        if !replacingExisting,
           let injectedError = try exclusivePublicationFailureInjector(.resultBundle) {
            initialErrorNumber = injectedError
        } else {
            let status = stagedOutputURL.path.withCString { stagedPath in
                finalOutputURL.path.withCString { finalPath in
                    Darwin.renameatx_np(
                        AT_FDCWD,
                        stagedPath,
                        AT_FDCWD,
                        finalPath,
                        flags
                    )
                }
            }
            initialErrorNumber = status == 0 ? nil : errno
        }
        guard let initialErrorNumber else {
            return FullLengthONTMHCResultBundlePublicationRecord(
                stagedDirectoryURL: stagedOutputURL,
                finalDirectoryURL: finalOutputURL,
                payloadMappings: payloadMappings,
                replacingExisting: replacingExisting,
                publicationMechanism: "renameatx_np",
                successManifestMechanism: "renameatx_np",
                fallbackReason: nil,
                startedAt: startedAt,
                completedAt: Date(),
                exitStatus: 0,
                errorMessage: nil
            )
        }
        let initialCode = POSIXErrorCode(rawValue: initialErrorNumber) ?? .EIO
        guard !replacingExisting, isUnsupportedExclusiveRename(initialErrorNumber) else {
            let record = FullLengthONTMHCResultBundlePublicationRecord(
                stagedDirectoryURL: stagedOutputURL,
                finalDirectoryURL: finalOutputURL,
                payloadMappings: payloadMappings,
                replacingExisting: replacingExisting,
                publicationMechanism: "renameatx_np",
                successManifestMechanism: "renameatx_np",
                fallbackReason: nil,
                startedAt: startedAt,
                completedAt: Date(),
                exitStatus: -1,
                errorMessage: POSIXError(initialCode).localizedDescription
            )
            throw FullLengthONTMHCResultBundlePublicationError(record: record)
        }
        let fallbackReason = "renameatx_np(RENAME_EXCL) unavailable: \(POSIXError(initialCode).localizedDescription)"
        let fallbackError: Error?
        do {
            try publishNewDirectoryUsingExclusiveReservation(
                stagedURL: stagedOutputURL,
                finalURL: finalOutputURL
            )
            fallbackError = nil
        } catch {
            fallbackError = error
        }
        let record = FullLengthONTMHCResultBundlePublicationRecord(
            stagedDirectoryURL: stagedOutputURL,
            finalDirectoryURL: finalOutputURL,
            payloadMappings: payloadMappings,
            replacingExisting: replacingExisting,
            publicationMechanism: "exclusive-directory-reservation-then-rename",
            successManifestMechanism: "exclusive-file-reservation-then-rename",
            fallbackReason: fallbackReason,
            startedAt: startedAt,
            completedAt: Date(),
            exitStatus: fallbackError == nil ? 0 : -1,
            errorMessage: fallbackError?.localizedDescription
        )
        if fallbackError != nil {
            throw FullLengthONTMHCResultBundlePublicationError(record: record)
        }
        return record
    }

    internal func isUnsupportedExclusiveRename(_ errorNumber: Int32) -> Bool {
        errorNumber == ENOTSUP || errorNumber == EOPNOTSUPP
    }

    internal func publishNewDirectoryUsingExclusiveReservation(
        stagedURL: URL,
        finalURL: URL
    ) throws {
        let reservationStatus = finalURL.path.withCString { path in
            Darwin.mkdir(path, S_IRWXU)
        }
        guard reservationStatus == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var publicationSucceeded = false
        defer {
            if !publicationSucceeded {
                _ = finalURL.path.withCString { Darwin.rmdir($0) }
            }
        }
        let status = stagedURL.path.withCString { stagedPath in
            finalURL.path.withCString { finalPath in
                Darwin.rename(stagedPath, finalPath)
            }
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        publicationSucceeded = true
    }

    internal func resultBundlePublicationMappings(
        stagedOutputURL: URL,
        finalOutputURL: URL
    ) throws -> [(staged: ProvenanceFileDescriptor, final: ProvenanceFileDescriptor)] {
        guard let enumerator = FileManager.default.enumerator(
            at: stagedOutputURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw FullLengthONTMHCGenotypingError.reportFailed("Could not enumerate staged result payload.")
        }
        let rootComponents = stagedOutputURL.standardizedFileURL.pathComponents
        var mappings: [(staged: ProvenanceFileDescriptor, final: ProvenanceFileDescriptor)] = []
        for case let source as URL in enumerator {
            try Task.checkCancellation()
            let relativeComponents = source.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
            if relativeComponents.first == "workflow" {
                enumerator.skipDescendants()
                continue
            }
            var information = stat()
            guard Darwin.lstat(source.path, &information) == 0 else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Could not inspect staged result payload entry: \(source.path)"
                )
            }
            switch information.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG:
                break
            default:
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Staged result payload contains an unsupported filesystem entry: \(source.path)"
                )
            }
            if source.lastPathComponent == "full-length-ont-mhc-genotyping-provenance.json" { continue }
            if source.lastPathComponent == OwnedWorkDirectoryMarker.fileName { continue }
            if source.lastPathComponent.hasPrefix(".\(ONTGenotypeResultBundleManifest.filename).staging-") { continue }
            let destination = relativeComponents.reduce(finalOutputURL) {
                $0.appendingPathComponent($1)
            }
            let checksum = try ProvenanceFileHasher.sha256(of: source) {
                try Task.checkCancellation()
            }
            let size = try ProvenanceFileHasher.fileSize(of: source)
            let staged = ProvenanceFileDescriptor(
                path: source.path,
                checksumSHA256: checksum,
                fileSize: size,
                role: .input
            )
            let final = ProvenanceFileDescriptor(
                path: destination.path,
                checksumSHA256: checksum,
                fileSize: size,
                role: .output,
                originPath: source.path
            )
            mappings.append((staged, final))
        }
        return mappings.sorted { $0.staged.path < $1.staged.path }
    }

    internal func appendActualResultBundlePublicationReceipt(
        _ record: FullLengthONTMHCResultBundlePublicationRecord,
        provenanceURL: URL
    ) throws {
        try writeExecutedPublicationReceipt(
            record,
            provenanceURL: provenanceURL,
            replacingPriorReceipt: false
        )
    }

    internal func writeExecutedPublicationReceipt(
        _ record: FullLengthONTMHCResultBundlePublicationRecord,
        provenanceURL: URL,
        replacingPriorReceipt: Bool
    ) throws {
        let publicationStep = record.provenanceStep
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Published result bundle is missing its staged provenance receipt."
            )
        }
        guard let receiptCompletedAt = publicationStep.completedAt else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Executed publication receipt is missing its completion time."
            )
        }
        var resolvedDefaults = envelope.options.resolvedDefaults
        resolvedDefaults["mhcResultBundleAtomicPublication"] = .string(
            record.publicationMechanism == "renameatx_np"
                ? "adjacent-directory-renameatx_np"
                : record.publicationMechanism
        )
        resolvedDefaults["mhcSuccessManifestAtomicPublication"] = .string(record.successManifestMechanism)
        let options = ProvenanceOptions(
            explicit: envelope.options.explicit,
            defaults: envelope.options.defaults,
            resolvedDefaults: resolvedDefaults
        )
        var steps = envelope.steps
        if replacingPriorReceipt,
           let index = steps.lastIndex(where: {
               $0.toolName == "lungfish-internal publish-result-bundle"
           }) {
            steps[index] = publicationStep
        } else {
            steps.append(publicationStep)
        }
        let updated = ProvenanceEnvelope(
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
            options: options,
            runtimeIdentity: envelope.runtimeIdentity,
            files: envelope.files,
            output: envelope.output,
            outputs: envelope.outputs,
            steps: steps,
            wallTimeSeconds: receiptCompletedAt.timeIntervalSince(envelope.createdAt),
            exitStatus: 0,
            stderr: envelope.stderr,
            signatures: envelope.signatures,
            legacyWorkflowRun: envelope.legacyRun
        )
        try ProvenanceWriter(signingProvider: nil).write(updated, toSidecar: provenanceURL)
    }

    internal func publishRelocatedSuccessManifest(
        in finalOutputURL: URL,
        publicationRecord: FullLengthONTMHCResultBundlePublicationRecord
    ) throws -> FullLengthONTMHCResultBundlePublicationRecord {
        let entries = try FileManager.default.contentsOfDirectory(
            at: finalOutputURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".\(ONTGenotypeResultBundleManifest.filename).staging-")
        }
        guard entries.count == 1, let stagedURL = entries.first else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Expected exactly one staged success manifest after result publication."
            )
        }
        let finalURL = ONTGenotypeResultBundle.manifestURL(in: finalOutputURL)
        let checksum = try ProvenanceFileHasher.sha256(of: stagedURL) {
            try Task.checkCancellation()
        }
        let size = try ProvenanceFileHasher.fileSize(of: stagedURL)
        let plan = FullLengthONTMHCSuccessManifestPublicationPlan(
            stagedURL: stagedURL,
            finalURL: finalURL,
            stagedDescriptor: .init(
                path: stagedURL.path,
                checksumSHA256: checksum,
                fileSize: size,
                role: .input
            ),
            finalDescriptor: .init(
                path: finalURL.path,
                checksumSHA256: checksum,
                fileSize: size,
                role: .output,
                originPath: stagedURL.path
            )
        )
        if publicationRecord.successManifestMechanism == "exclusive-file-reservation-then-rename" {
            try publishSuccessManifestUsingExclusiveReservation(plan)
            return publicationRecord
        }
        do {
            try publishSuccessManifestUsingRenameExclusive(plan)
            return publicationRecord
        } catch let error as FullLengthONTMHCExclusiveRenameUnsupportedError {
            let updatedRecord = publicationRecord.recordingSuccessManifestFallback(
                reason: error.localizedDescription
            )
            let provenanceURL = finalOutputURL.appendingPathComponent(
                "full-length-ont-mhc-genotyping-provenance.json"
            )
            try writeExecutedPublicationReceipt(
                updatedRecord,
                provenanceURL: provenanceURL,
                replacingPriorReceipt: true
            )
            try metadataPublicationObserver(.provenanceFinalizedBeforeManifestPublication(
                finalManifestURL: finalURL,
                provenanceURL: provenanceURL
            ))
            try publishSuccessManifestUsingExclusiveReservation(plan)
            return updatedRecord
        }
    }

    internal func rollbackPublishedResultBundle(
        stagedOutputURL: URL,
        finalOutputURL: URL,
        replacingExisting: Bool
    ) throws {
        try rollbackOperationObserver()
        if replacingExisting {
            let status = stagedOutputURL.path.withCString { stagedPath in
                finalOutputURL.path.withCString { finalPath in
                    Darwin.renameatx_np(
                        AT_FDCWD,
                        stagedPath,
                        AT_FDCWD,
                        finalPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
            guard status == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try FileManager.default.removeItem(at: finalOutputURL)
        }
    }

    internal func rollbackProvenanceStep(
        for publicationRecord: FullLengthONTMHCResultBundlePublicationRecord,
        startedAt: Date,
        completedAt: Date,
        exitStatus: Int,
        errorMessage: String?,
        recovery: FullLengthONTMHCRollbackFailureRecovery? = nil
    ) -> ProvenanceStep {
        let action = publicationRecord.replacingExisting
            ? "swap-prior-generation-back"
            : "remove-published-generation"
        var argv = [
            "lungfish-internal", "rollback-result-bundle",
            "--action", action,
            "--atomic-mechanism", publicationRecord.replacingExisting ? "renameatx_np" : "removeItem",
            publicationRecord.finalDirectoryURL.path,
            publicationRecord.stagedDirectoryURL.path,
        ]
        if let path = recovery?.retainedPriorGenerationURL?.path {
            argv += ["--retained-prior-generation", path]
        }
        if let path = recovery?.retainedFailedPublishedGenerationURL?.path {
            argv += ["--retained-failed-published-generation", path]
        }
        return ProvenanceStep(
            toolName: "lungfish-internal rollback-result-bundle",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
            resolvedOptions: [
                "rollbackAction": .string(action),
                "publicationMode": .string(publicationRecord.replacingExisting ? "replace" : "create"),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: publicationRecord.provenanceStep.outputs.map { $0.withRole(.input) },
            outputs: [],
            exitStatus: exitStatus,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: errorMessage,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    internal func retainRollbackFailureGenerations(
        after publicationRecord: FullLengthONTMHCResultBundlePublicationRecord
    ) -> FullLengthONTMHCRollbackFailureRecovery {
        let fileManager = FileManager.default
        let stagedURL = publicationRecord.stagedDirectoryURL.standardizedFileURL
        let finalURL = publicationRecord.finalDirectoryURL.standardizedFileURL
        let retainedPriorURL: URL? = publicationRecord.replacingExisting
            && fileManager.fileExists(atPath: stagedURL.path)
            ? stagedURL
            : nil
        guard fileManager.fileExists(atPath: finalURL.path) else {
            return FullLengthONTMHCRollbackFailureRecovery(
                retainedPriorGenerationURL: retainedPriorURL,
                retainedFailedPublishedGenerationURL: nil,
                quarantineError: nil
            )
        }
        let quarantineURL = publicationRecord.replacingExisting
            ? URL(fileURLWithPath: stagedURL.path + ".published-recovery", isDirectory: true)
            : stagedURL
        let status = finalURL.path.withCString { finalPath in
            quarantineURL.path.withCString { quarantinePath in
                PortableExclusiveRename.renameatxNP(
                    AT_FDCWD,
                    finalPath,
                    AT_FDCWD,
                    quarantinePath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if status == 0 {
            return FullLengthONTMHCRollbackFailureRecovery(
                retainedPriorGenerationURL: retainedPriorURL,
                retainedFailedPublishedGenerationURL: quarantineURL,
                quarantineError: nil
            )
        }
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        return FullLengthONTMHCRollbackFailureRecovery(
            retainedPriorGenerationURL: retainedPriorURL,
            retainedFailedPublishedGenerationURL: finalURL,
            quarantineError: "Could not quarantine failed published generation at \(quarantineURL.path): \(error.localizedDescription)"
        )
    }

    internal func relocatedResult(
        _ result: FullLengthONTMHCGenotypingResult,
        from stagedOutputURL: URL,
        to finalOutputURL: URL,
        additionalCleanupWarnings: [FullLengthONTMHCGenotypingCleanupWarning] = []
    ) -> FullLengthONTMHCGenotypingResult {
        func relocated(_ url: URL?) -> URL? {
            guard let url else { return nil }
            let stagedComponents = stagedOutputURL.standardizedFileURL.pathComponents
            let components = url.standardizedFileURL.pathComponents
            guard components.count >= stagedComponents.count,
                  Array(components.prefix(stagedComponents.count)) == stagedComponents else {
                return url
            }
            return components.dropFirst(stagedComponents.count).reduce(finalOutputURL) {
                $0.appendingPathComponent($1)
            }
        }
        return FullLengthONTMHCGenotypingResult(
            outputDirectory: finalOutputURL,
            reportCSVURL: relocated(result.reportCSVURL)!,
            sampleSummaryCSVURL: relocated(result.sampleSummaryCSVURL)!,
            statsJSONURL: relocated(result.statsJSONURL)!,
            workbookURL: relocated(result.workbookURL)!,
            primaryWorkbookURL: relocated(result.primaryWorkbookURL)!,
            haplotypeAnalysisURL: relocated(result.haplotypeAnalysisURL),
            unmatchedClustersFASTAURL: relocated(result.unmatchedClustersFASTAURL)!,
            deduplicatedUnmatchedClustersFASTAURL: relocated(result.deduplicatedUnmatchedClustersFASTAURL)!,
            cdnaClustersFASTAURL: relocated(result.cdnaClustersFASTAURL)!,
            provenanceURL: relocated(result.provenanceURL)!,
            referenceFASTAURL: result.referenceFASTAURL,
            genotypingEvidenceBAMURL: relocated(result.genotypingEvidenceBAMURL),
            genotypingEvidenceBAIURL: relocated(result.genotypingEvidenceBAIURL),
            reciprocalEvidenceBAMURL: relocated(result.reciprocalEvidenceBAMURL),
            reciprocalEvidenceBAIURL: relocated(result.reciprocalEvidenceBAIURL),
            candidateAllelesJSONURL: relocated(result.candidateAllelesJSONURL),
            candidateAllelesFASTAURL: relocated(result.candidateAllelesFASTAURL),
            candidateAllelesGenBankURL: relocated(result.candidateAllelesGenBankURL),
            unnameableClustersJSONURL: relocated(result.unnameableClustersJSONURL),
            unnameableClustersFASTAURL: relocated(result.unnameableClustersFASTAURL),
            unnameableClustersGenBankURL: relocated(result.unnameableClustersGenBankURL),
            cleanupWarnings: result.cleanupWarnings.map { warning in
                guard warning.path.hasPrefix(stagedOutputURL.path) else { return warning }
                return FullLengthONTMHCGenotypingCleanupWarning(
                    kind: warning.kind,
                    path: warning.path.replacingOccurrences(
                        of: stagedOutputURL.path,
                        with: finalOutputURL.path
                    ),
                    error: warning.error,
                    publishedArtifactsRemainValid: warning.publishedArtifactsRemainValid
                )
            } + additionalCleanupWarnings
        )
    }

    internal func stageManifest(
        request: FullLengthONTMHCGenotypingRunRequest,
        workbookRevision: ONTGenotypeWorkbookRevision,
        evidenceArtifactPair: ONTMHCBAMArtifactPair,
        candidateArtifacts: ONTMHCCandidateArtifactManifest,
        referenceVisualizations: ONTMHCReferenceVisualizationArtifacts?,
        referenceRecordStore: ONTGenotypeReferenceRecordStoreInfo?,
        reviewableRowCatalog: ONTMHCArtifactReference?,
        createdAt: Date
    ) throws -> FullLengthONTMHCSuccessManifestPublicationPlan {
        let resolvedHaplotypeDefinitionSet = try resolveHaplotypeDefinitionSet(for: request)
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            workflowKind: .fullLengthONTMHCGenotype,
            workflowMode: request.haplotypeDefinitionSetID == nil ? .genotypeOnly : .haplotyped,
            outputName: request.outputName,
            analysisName: request.outputName,
            primaryWorkbookPath: relativePath(from: request.outputDirectory, to: request.workbookURL),
            currentWorkbookPath: relativePath(from: request.outputDirectory, to: request.currentWorkbookURL),
            workbookRevisions: [workbookRevision],
            longSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.reportCSVURL),
            sampleSummaryCSVPath: relativePath(from: request.outputDirectory, to: request.sampleSummaryCSVURL),
            statsJSONPath: relativePath(from: request.outputDirectory, to: request.statsJSONURL),
            provenancePath: relativePath(from: request.outputDirectory, to: request.provenanceURL),
            deduplicatedUnmatchedClustersFASTAPath: relativePath(
                from: request.outputDirectory,
                to: request.deduplicatedUnmatchedClustersFASTAURL
            ),
            haplotypeAnalysisPath: request.haplotypeDefinitionSetID == nil
                ? nil
                : relativePath(from: request.outputDirectory, to: request.haplotypeAnalysisURL),
            haplotypeDefinitionSetID: request.haplotypeDefinitionSetID,
            haplotypeAssayID: resolvedHaplotypeDefinitionSet?.assayID,
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            mhcCandidateArtifacts: candidateArtifacts,
            mhcReferenceVisualizations: referenceVisualizations,
            referenceRecordStore: referenceRecordStore,
            reviewableRowCatalog: reviewableRowCatalog
        )
        let stagedURL = request.outputDirectory.appendingPathComponent(
            ".\(ONTGenotypeResultBundleManifest.filename).staging-\(UUID().uuidString)"
        ).standardizedFileURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stagedURL, options: .atomic)
        let checksum = try ProvenanceFileHasher.sha256(of: stagedURL) {
            try Task.checkCancellation()
        }
        let fileSize = try ProvenanceFileHasher.fileSize(of: stagedURL)
        let finalURL = request.manifestURL.standardizedFileURL
        let stagedDescriptor = ProvenanceFileDescriptor(
            path: stagedURL.path,
            checksumSHA256: checksum,
            fileSize: fileSize,
            format: .json,
            role: .input
        )
        let finalDescriptor = ProvenanceFileDescriptor(
            path: finalURL.path,
            checksumSHA256: checksum,
            fileSize: fileSize,
            format: .json,
            role: .output,
            originPath: stagedURL.path
        )
        return FullLengthONTMHCSuccessManifestPublicationPlan(
            stagedURL: stagedURL,
            finalURL: finalURL,
            stagedDescriptor: stagedDescriptor,
            finalDescriptor: finalDescriptor
        )
    }

    internal func validateSuccessManifestPublicationPlan(
        _ plan: FullLengthONTMHCSuccessManifestPublicationPlan
    ) throws {
        guard !FileManager.default.fileExists(atPath: plan.finalURL.path) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Success manifest destination unexpectedly exists before last-step publication: \(plan.finalURL.path)"
            )
        }
        guard try ProvenanceFileHasher.sha256(of: plan.stagedURL, cancellationCheck: {
            try Task.checkCancellation()
        }) == plan.stagedDescriptor.checksumSHA256,
              try ProvenanceFileHasher.fileSize(of: plan.stagedURL) == plan.stagedDescriptor.fileSize else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Staged success manifest no longer matches its provenance descriptor."
            )
        }
    }

    internal func publishSuccessManifestUsingRenameExclusive(
        _ plan: FullLengthONTMHCSuccessManifestPublicationPlan
    ) throws {
        try validateSuccessManifestPublicationPlan(plan)
        let errorNumber: Int32?
        if let injectedError = try exclusivePublicationFailureInjector(.successManifest) {
            errorNumber = injectedError
        } else {
            let status = plan.stagedURL.path.withCString { stagedPath in
                plan.finalURL.path.withCString { finalPath in
                    Darwin.renameatx_np(
                        AT_FDCWD,
                        stagedPath,
                        AT_FDCWD,
                        finalPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            errorNumber = status == 0 ? nil : errno
        }
        guard let errorNumber else { return }
        let code = POSIXErrorCode(rawValue: errorNumber) ?? .EIO
        if isUnsupportedExclusiveRename(errorNumber) {
            throw FullLengthONTMHCExclusiveRenameUnsupportedError(
                targetDescription: "success manifest",
                code: code
            )
        } else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not atomically publish success manifest last: \(POSIXError(code).localizedDescription)"
            )
        }
    }

    internal func publishSuccessManifestUsingExclusiveReservation(
        _ plan: FullLengthONTMHCSuccessManifestPublicationPlan
    ) throws {
        try validateSuccessManifestPublicationPlan(plan)
        let descriptor = plan.finalURL.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not exclusively reserve success manifest destination: \(POSIXError(code).localizedDescription)"
            )
        }
        guard Darwin.close(descriptor) == 0 else {
            let closeCode = POSIXErrorCode(rawValue: errno) ?? .EIO
            _ = plan.finalURL.path.withCString { Darwin.unlink($0) }
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not close success manifest reservation: \(POSIXError(closeCode).localizedDescription)"
            )
        }
        var publicationSucceeded = false
        defer {
            if !publicationSucceeded {
                _ = plan.finalURL.path.withCString { Darwin.unlink($0) }
            }
        }
        let status = plan.stagedURL.path.withCString { stagedPath in
            plan.finalURL.path.withCString { finalPath in
                Darwin.rename(stagedPath, finalPath)
            }
        }
        guard status == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not publish success manifest using exclusive reservation: \(POSIXError(code).localizedDescription)"
            )
        }
        publicationSucceeded = true
    }

    internal func validatedEvidenceArtifactPair(
        _ result: FullLengthONTMHCCohortAlignmentResult,
        bundleDirectoryURL: URL
    ) throws -> ONTMHCBAMArtifactPair {
        guard let bamDescriptor = result.finalArtifactDescriptors.first(where: { $0.role == .evidenceBAM }),
              let baiDescriptor = result.finalArtifactDescriptors.first(where: { $0.role == .evidenceBAI }),
              bamDescriptor.phase == .final,
              baiDescriptor.phase == .final,
              bamDescriptor.path == result.bamURL.standardizedFileURL.path,
              baiDescriptor.path == result.baiURL.standardizedFileURL.path else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Cohort alignment builder did not return final BAM/BAI descriptors."
            )
        }
        let observedBAM = try FullLengthONTMHCArtifactDescriptor(
            url: result.bamURL,
            role: .evidenceBAM,
            phase: .final
        )
        let observedBAI = try FullLengthONTMHCArtifactDescriptor(
            url: result.baiURL,
            role: .evidenceBAI,
            phase: .final
        )
        guard observedBAM == bamDescriptor, observedBAI == baiDescriptor,
              bamDescriptor.byteSize <= UInt64(Int64.max),
              baiDescriptor.byteSize <= UInt64(Int64.max) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Published cohort BAM/BAI does not match its immutable builder descriptors."
            )
        }
        return ONTMHCBAMArtifactPair(
            bam: ONTMHCArtifactReference(
                path: relativePath(from: bundleDirectoryURL, to: result.bamURL),
                sha256: bamDescriptor.sha256,
                sizeBytes: Int64(bamDescriptor.byteSize)
            ),
            bai: ONTMHCArtifactReference(
                path: relativePath(from: bundleDirectoryURL, to: result.baiURL),
                sha256: baiDescriptor.sha256,
                sizeBytes: Int64(baiDescriptor.byteSize)
            )
        )
    }

    internal func invalidatePublishedRunMetadata(_ request: FullLengthONTMHCGenotypingRunRequest) throws {
        if FileManager.default.fileExists(atPath: request.manifestURL.path) {
            try FileManager.default.removeItem(at: request.manifestURL)
        }
    }
}
