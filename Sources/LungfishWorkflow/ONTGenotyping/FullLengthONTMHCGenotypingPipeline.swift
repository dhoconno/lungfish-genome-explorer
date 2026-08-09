import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

public struct FullLengthONTMHCGenotypingPipeline: Sendable {
    internal let nativeToolRunner: NativeToolRunner
    internal let condaManager: CondaManager
    internal let postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning
    internal let metadataPublicationObserver: @Sendable (FullLengthONTMHCMetadataPublicationEvent) throws -> Void
    internal let rollbackOperationObserver: @Sendable () throws -> Void
    internal let cleanupJournalObserver:
        @Sendable (GenotypingCleanupJournalEvent) throws -> Void
    internal let exclusivePublicationFailureInjector: @Sendable (FullLengthONTMHCExclusivePublicationTarget) throws -> Int32?
    internal let reviewableRowCatalogPublisher:
        @Sendable (
            GenotypeReviewableRowCatalogInputs,
            URL,
            @escaping @Sendable () throws -> Void
        ) throws -> GenotypeReviewableRowCatalogPublication

    static func reviewableCatalogAuthority(
        expectedReferenceRecords: [MHCReferenceRecord],
        referenceCatalogURL: URL,
        expectedCandidateDocument: ONTMHCCandidateAllelesDocument,
        candidateURL: URL,
        expectedUnnameableDocument: ONTMHCUnnameableClustersDocument? = nil,
        unnameableURL: URL? = nil,
        authorityObserver: () throws -> Void = {}
    ) throws -> FullLengthONTMHCReviewCatalogAuthority {
        let referenceSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            referenceCatalogURL
        )
        let candidateSnapshot = try GenotypeReviewAuthorityFileSnapshot.capture(
            candidateURL
        )
        let unnameableSnapshot = try unnameableURL.map {
            try GenotypeReviewAuthorityFileSnapshot.capture($0)
        }
        let referenceProjection = try JSONDecoder().decode(
            FullLengthONTMHCReferenceCatalogProjection.self,
            from: referenceSnapshot.data
        )
        let candidateDocument = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: candidateSnapshot.data
        )
        guard referenceProjection.records == expectedReferenceRecords else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(referenceCatalogURL.path)
        }
        guard candidateDocument == expectedCandidateDocument else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(candidateURL.path)
        }
        let unnameableDocument = try unnameableSnapshot.map {
            try JSONDecoder().decode(
                ONTMHCUnnameableClustersDocument.self,
                from: $0.data
            )
        }
        guard unnameableDocument == expectedUnnameableDocument else {
            throw GenotypeReviewableRowCatalogPublisherError
                .authorityChanged(unnameableURL?.path ?? candidateURL.path)
        }
        try authorityObserver()
        try referenceSnapshot.requireUnchanged()
        try candidateSnapshot.requireUnchanged()
        try unnameableSnapshot?.requireUnchanged()
        return FullLengthONTMHCReviewCatalogAuthority(
            referenceRecords: referenceProjection.records,
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            snapshots: [referenceSnapshot, candidateSnapshot] + [unnameableSnapshot].compactMap { $0 }
        )
    }

    public init(
        nativeToolRunner: NativeToolRunner = .shared,
        condaManager: CondaManager = .shared,
        postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning = DefaultFullLengthONTMHCWorkDirectoryCleaner()
    ) {
        self.nativeToolRunner = nativeToolRunner
        self.condaManager = condaManager
        self.postPublicationWorkDirectoryCleaner = postPublicationWorkDirectoryCleaner
        self.metadataPublicationObserver = { _ in }
        self.rollbackOperationObserver = {}
        self.cleanupJournalObserver = { _ in }
        self.exclusivePublicationFailureInjector = { _ in nil }
        self.reviewableRowCatalogPublisher = {
            inputs, outputDirectory, authorityCheck in
            try GenotypeReviewableRowCatalogPublisher().publish(
                inputs,
                to: outputDirectory,
                postPublicationAuthorityCheck: authorityCheck
            )
        }
    }

    init(
        nativeToolRunner: NativeToolRunner,
        condaManager: CondaManager,
        postPublicationWorkDirectoryCleaner: any FullLengthONTMHCWorkDirectoryCleaning,
        metadataPublicationObserver: @escaping @Sendable (FullLengthONTMHCMetadataPublicationEvent) throws -> Void,
        rollbackOperationObserver: @escaping @Sendable () throws -> Void = {},
        cleanupJournalObserver:
            @escaping @Sendable (GenotypingCleanupJournalEvent) throws -> Void = { _ in },
        exclusivePublicationFailureInjector: @escaping @Sendable (FullLengthONTMHCExclusivePublicationTarget) throws -> Int32? = { _ in nil },
        reviewableRowCatalogPublisher:
            @escaping @Sendable (
                GenotypeReviewableRowCatalogInputs,
                URL,
                @escaping @Sendable () throws -> Void
            ) throws -> GenotypeReviewableRowCatalogPublication = {
                try GenotypeReviewableRowCatalogPublisher().publish(
                    $0,
                    to: $1,
                    postPublicationAuthorityCheck: $2
                )
            }
    ) {
        self.nativeToolRunner = nativeToolRunner
        self.condaManager = condaManager
        self.postPublicationWorkDirectoryCleaner = postPublicationWorkDirectoryCleaner
        self.metadataPublicationObserver = metadataPublicationObserver
        self.rollbackOperationObserver = rollbackOperationObserver
        self.cleanupJournalObserver = cleanupJournalObserver
        self.exclusivePublicationFailureInjector = exclusivePublicationFailureInjector
        self.reviewableRowCatalogPublisher = reviewableRowCatalogPublisher
    }

    public func run(
        _ request: FullLengthONTMHCGenotypingRunRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> FullLengthONTMHCGenotypingResult {
        let runStartedAt = Date()
        let lifecycleRunID = UUID()
        let lifecycleProcessIdentity = try OwnedProcessIdentity.current()
        let runLock = try DarwinFullLengthONTMHCRunLock.acquire(
            outputDirectoryURL: request.outputDirectory
        )
        defer { runLock.release() }
        let finalOutputURL = request.outputDirectory.standardizedFileURL
        let stagedOutputURL = finalOutputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(finalOutputURL.lastPathComponent).run-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let lifecycleProjectRoot = (request.projectURL
            ?? stagedOutputURL.deletingLastPathComponent()).standardizedFileURL
        var finalExisted = false
        var failureEnvelopeSnapshot: ProvenanceEnvelope?
        var successfulPublicationRecordSnapshot: FullLengthONTMHCResultBundlePublicationRecord?
        var rollbackStepSnapshot: ProvenanceStep?
        var rollbackFailureRecovery: FullLengthONTMHCRollbackFailureRecovery?
        do {
            try metadataPublicationObserver(.runLockAcquired(lockURL: runLock.lockURL))
            try validateInputs(request)
            finalExisted = try FullLengthONTMHCAlignmentSafety().requireOptionalDirectoryEntryNoFollow(
                finalOutputURL,
                role: "final output bundle directory"
            )
            try FileManager.default.createDirectory(
                at: stagedOutputURL,
                withIntermediateDirectories: false
            )
            try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
                stagedOutputURL,
                request: OwnedWorkDirectoryCreationRequest(
                    projectURL: lifecycleProjectRoot,
                    parentDirectoryURL: stagedOutputURL.deletingLastPathComponent(),
                    prefix: ".full-length-ont-mhc-staging-",
                    runID: lifecycleRunID,
                    processIdentity: lifecycleProcessIdentity,
                    state: .active,
                    lockRelativePath: projectRelativePath(
                        runLock.lockURL,
                        projectRoot: lifecycleProjectRoot
                    ),
                    keepIntermediates: request.keepIntermediates,
                    toolName: "lungfish fastq full-length-ont-mhc-genotype",
                    toolVersion: WorkflowRun.currentAppVersion
                )
            )
            if finalExisted, request.reuseCompatibleCheckpoints {
                try importRequestedCheckpointGeneration(
                    request: request,
                    priorFinalOutputURL: finalOutputURL,
                    stagedOutputURL: stagedOutputURL
                )
            }
            let stagedRequest = request.replacingOutput(
                outputDirectory: stagedOutputURL,
                outputName: request.outputName
            )
            let stagedRun = try await runStaged(
                stagedRequest,
                logicalFinalOutputURL: finalOutputURL,
                progressHandler: progressHandler
            )
            let stagedResult = stagedRun.result
            try Task.checkCancellation()
            try finalizeStagedBundleMetadata(
                stagedOutputURL: stagedOutputURL,
                finalOutputURL: finalOutputURL
            )
            try Task.checkCancellation()
            let publicationMappings = try resultBundlePublicationMappings(
                stagedOutputURL: stagedOutputURL,
                finalOutputURL: finalOutputURL
            )
            var publicationRecord = try publishStagedResultBundle(
                stagedOutputURL: stagedOutputURL,
                finalOutputURL: finalOutputURL,
                replacingExisting: finalExisted,
                payloadMappings: publicationMappings
            )
            successfulPublicationRecordSnapshot = publicationRecord
            do {
                try metadataPublicationObserver(.resultBundlePublishedBeforeReceipt(
                    stagedDirectoryURL: stagedOutputURL,
                    finalDirectoryURL: finalOutputURL
                ))
                try appendActualResultBundlePublicationReceipt(
                    publicationRecord,
                    provenanceURL: finalOutputURL.appendingPathComponent(
                        "full-length-ont-mhc-genotyping-provenance.json"
                    )
                )
                let finalProvenanceURL = finalOutputURL.appendingPathComponent(
                    "full-length-ont-mhc-genotyping-provenance.json"
                )
                let finalManifestURL = ONTGenotypeResultBundle.manifestURL(in: finalOutputURL)
                try metadataPublicationObserver(.provenanceFinalizedBeforeManifestPublication(
                    finalManifestURL: finalManifestURL,
                    provenanceURL: finalProvenanceURL
                ))
                publicationRecord = try publishRelocatedSuccessManifest(
                    in: finalOutputURL,
                    publicationRecord: publicationRecord
                )
                successfulPublicationRecordSnapshot = publicationRecord
                try OwnedWorkDirectoryMarkerStore.transition(
                    finalOutputURL,
                    expectedProjectURL: lifecycleProjectRoot,
                    expectedRunID: lifecycleRunID,
                    to: .completed
                )
                try FileManager.default.removeItem(
                    at: finalOutputURL.appendingPathComponent(
                        OwnedWorkDirectoryMarker.fileName
                    )
                )
                try metadataPublicationObserver(.successManifestPublished(
                    finalManifestURL: finalManifestURL,
                    provenanceURL: finalProvenanceURL
                ))
            } catch {
                failureEnvelopeSnapshot = try? ProvenanceEnvelopeReader.load(
                    fromSidecar: finalOutputURL.appendingPathComponent(
                        "full-length-ont-mhc-genotyping-provenance.json"
                    )
                )
                let rollbackStartedAt = Date()
                do {
                    try rollbackPublishedResultBundle(
                        stagedOutputURL: stagedOutputURL,
                        finalOutputURL: finalOutputURL,
                        replacingExisting: finalExisted
                    )
                    rollbackStepSnapshot = rollbackProvenanceStep(
                        for: publicationRecord,
                        startedAt: rollbackStartedAt,
                        completedAt: Date(),
                        exitStatus: 0,
                        errorMessage: nil
                    )
                } catch let rollbackError {
                    let recovery = retainRollbackFailureGenerations(
                        after: publicationRecord
                    )
                    rollbackFailureRecovery = recovery
                    let rollbackErrorText = [
                        rollbackError.localizedDescription,
                        recovery.quarantineError,
                    ].compactMap { $0 }.joined(separator: "; ")
                    rollbackStepSnapshot = rollbackProvenanceStep(
                        for: publicationRecord,
                        startedAt: rollbackStartedAt,
                        completedAt: Date(),
                        exitStatus: 1,
                        errorMessage: rollbackErrorText,
                        recovery: recovery
                    )
                    throw FullLengthONTMHCGenotypingError.reportFailed(
                        "Post-publication metadata failed (\(error.localizedDescription)); rollback also failed (\(rollbackError.localizedDescription))."
                    )
                }
                throw error
            }
            let cleanupPlan = try beginSuccessfulCleanupJournal(
                projectRoot: lifecycleProjectRoot,
                runID: lifecycleRunID,
                stagedRun: stagedRun,
                finalOutputURL: finalOutputURL,
                retiredPublicationURL:
                    finalExisted
                        && FileManager.default.fileExists(
                            atPath: stagedOutputURL.path
                        )
                        ? stagedOutputURL
                        : nil,
                keepIntermediates: request.keepIntermediates
            )
            var publicationCleanup = completeSuccessfulWorkDirectoryLifecycle(
                stagedRun: stagedRun,
                finalOutputURL: finalOutputURL,
                projectRoot: lifecycleProjectRoot,
                runID: lifecycleRunID,
                keepIntermediates: request.keepIntermediates,
                cleanupPlan: cleanupPlan
            )
            if finalExisted, cleanupPlan.entry(for: stagedOutputURL) != nil {
                let disposition = identityBoundRemovalDisposition(
                    plan: cleanupPlan,
                    url: stagedOutputURL,
                    successDisposition: "removed"
                ) {
                    try FileManager.default.removeItem(at: $0)
                }
                publicationCleanup.dispositions.append(disposition)
                if let error = disposition.error {
                    publicationCleanup.warnings.append(.init(
                        kind: .retiredCohortPublicationDirectory,
                        path: stagedOutputURL.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    ))
                }
            }
            try appendSuccessfulCleanupDisposition(
                projectRoot: lifecycleProjectRoot,
                runID: lifecycleRunID,
                outputBundleURL: finalOutputURL,
                dispositions: publicationCleanup.dispositions
            )
            return relocatedResult(
                stagedResult,
                from: stagedOutputURL,
                to: finalOutputURL,
                additionalCleanupWarnings: publicationCleanup.warnings
            )
        } catch let journalError as GenotypingCleanupJournalError {
            throw journalError
        } catch {
            let partialEnvelope = failureEnvelopeSnapshot ?? loadPartialFailureEnvelope(
                stagedOutputURL: stagedOutputURL,
                finalOutputURL: finalOutputURL,
                finalExistedBeforeRun: finalExisted
            )
            let priorFailureEnvelopeData = try? Data(
                contentsOf: request.failureProvenanceURL
            )
            let failedPublicationRecord = (error as? FullLengthONTMHCResultBundlePublicationError)?.record
            var reportedError: Error = error
            var retainedFailureDiagnosticRoots = rollbackFailureRecovery?.retainedRoots ?? []
            let candidateWorkDirectory = candidateArtifactWorkDirectory(for: stagedOutputURL)
            if FileManager.default.fileExists(atPath: candidateWorkDirectory.path) {
                do {
                    if let retainedLogsURL = try retainCandidateFailureLogs(
                        from: candidateWorkDirectory,
                        for: request
                    ) {
                        retainedFailureDiagnosticRoots.append(retainedLogsURL)
                    }
                } catch let candidateLogRetentionError {
                    reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                        "Run failed (\(error.localizedDescription)); candidate failure-log retention also failed (\(candidateLogRetentionError.localizedDescription))."
                    )
                }
            }
            let historyWriter = ProjectOperationHistoryWriter(
                projectURL: lifecycleProjectRoot
            )
            do {
                try writeFailureProvenance(
                    request: request,
                    stagedOutputURL: stagedOutputURL,
                    startedAt: runStartedAt,
                    error: reportedError,
                    partialEnvelope: partialEnvelope,
                    failedPublicationRecord: failedPublicationRecord,
                    successfulPublicationRecord: successfulPublicationRecordSnapshot,
                    rollbackStep: rollbackStepSnapshot,
                    rollbackFailureRecovery: rollbackFailureRecovery,
                    additionalDiagnosticRoots: retainedFailureDiagnosticRoots
                )
                let failureData = try Data(contentsOf: request.failureProvenanceURL)
                var historyPayloads = ["failure-provenance.json": failureData]
                if let priorFailureEnvelopeData {
                    historyPayloads["superseded-prior-failure-provenance.json"] =
                        priorFailureEnvelopeData
                }
                _ = try historyWriter.createOperation(
                    operationID: lifecycleRunID,
                    payloads: historyPayloads
                )
            } catch let preparationError as FullLengthFailureProvenancePreparationError {
                let originalFailure = reportedError
                reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                    "Run failed (\(originalFailure.localizedDescription)); \(preparationError.localizedDescription)."
                )
                do {
                    let receiptData = try failureProvenancePreparationReceiptData(
                        request: request,
                        runID: lifecycleRunID,
                        startedAt: runStartedAt,
                        originalError: originalFailure,
                        preparationError: preparationError,
                        rollbackFailureRecovery: rollbackFailureRecovery
                    )
                    var historyPayloads = [
                        "failure-provenance-preparation-error.json": receiptData,
                    ]
                    if let priorFailureEnvelopeData {
                        historyPayloads["prior-failure-provenance.json"] =
                            priorFailureEnvelopeData
                    }
                    _ = try historyWriter.createOperation(
                        operationID: lifecycleRunID,
                        payloads: historyPayloads
                    )
                    if FileManager.default.fileExists(
                        atPath: request.failureProvenanceURL.path
                    ) {
                        do {
                            try FileManager.default.removeItem(
                                at: request.failureProvenanceURL
                            )
                        } catch {
                            reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                                "Run failed (\(reportedError.localizedDescription)); stale failed-run provenance could not be retired (\(error.localizedDescription))."
                            )
                        }
                    }
                } catch let receiptError {
                    throw FullLengthONTMHCGenotypingError.reportFailed(
                        "Run failed (\(reportedError.localizedDescription)); incomplete failure-provenance preparation receipt also could not be written (\(receiptError.localizedDescription))."
                    )
                }
            } catch let provenanceError {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Run failed (\(reportedError.localizedDescription)); failed-run provenance also could not be written (\(provenanceError.localizedDescription))."
                )
            }
            let retainedRecoveryPaths = Set(
                rollbackFailureRecovery?.retainedRoots.map { $0.standardizedFileURL.path } ?? []
            )
            let dispositions = failCurrentRunWorkDirectories(
                stagedOutputURL: stagedOutputURL,
                projectRoot: lifecycleProjectRoot,
                runID: lifecycleRunID,
                keepIntermediates: request.keepIntermediates,
                retainedRecoveryPaths: retainedRecoveryPaths
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let dispositionData = try encoder.encode(
                    GenotypingWorkDirectoryDispositionEnvelope(
                        schemaVersion: 1,
                        runID: lifecycleRunID,
                        entries: dispositions
                    )
                )
                try historyWriter.append(
                    dispositionData,
                    named: "cleanup-disposition.json",
                    toOperation: lifecycleRunID
                )
            } catch let dispositionError {
                reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                    "Run failed (\(reportedError.localizedDescription)); cleanup disposition could not be appended for current-run roots (\(dispositionError.localizedDescription))."
                )
            }
            let cleanupFailures = dispositions.filter { $0.error != nil }
            if !cleanupFailures.isEmpty {
                let details = cleanupFailures.map {
                    "\($0.path): \($0.error ?? "unknown cleanup error")"
                }.joined(separator: "; ")
                reportedError = FullLengthONTMHCGenotypingError.reportFailed(
                    "Run failed (\(reportedError.localizedDescription)); current-run work cleanup failed: \(details)"
                )
            }
            throw reportedError
        }
    }

    internal func runStaged(
        _ request: FullLengthONTMHCGenotypingRunRequest,
        logicalFinalOutputURL: URL,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> FullLengthONTMHCStagedRunResult {
        let progress = FullLengthONTMHCProgressRelay(progressHandler)
        let startedAt = Date()
        progress.emit(0.01, "Validating full-length ONT MHC genotyping inputs.")
        try validateInputs(request)
        let referenceFASTAURL = try resolveMHCReferenceFASTA(request.referenceSourceURL)
        let executionPlan = FullLengthONTMHCSampleExecutionPlan.automatic(
            totalThreads: request.threads,
            sampleCount: request.inputFASTQURLs.count,
            requestedSampleJobs: request.sampleJobs,
            requestedSavontThreadsPerSample: request.savontThreadsPerSample
        )

        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let workDirectory = request.outputDirectory.appendingPathComponent("workflow", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: request.outputDirectory.appendingPathComponent("samples", isDirectory: true),
            withIntermediateDirectories: true
        )
        try invalidatePublishedRunMetadata(request)

        let referenceCatalogProjectionURL = request.outputDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("reference", isDirectory: true)
            .appendingPathComponent("mhc-reference-catalog.json")
        let referenceCatalog = try materializeMHCReferenceCatalog(
            sourceURL: request.referenceSourceURL,
            fastaURL: referenceFASTAURL,
            cdnaThreshold: request.cdnaThreshold,
            outputURL: referenceCatalogProjectionURL
        )

        try Data().write(to: request.unmatchedClustersFASTAURL, options: .atomic)
        try Data().write(to: request.cdnaClustersFASTAURL, options: .atomic)

        progress.emit(
            0.02,
            "Planning \(request.inputFASTQURLs.count) \(sampleLabel(request.inputFASTQURLs.count)): \(executionPlan.sampleJobs) concurrent sample \(jobLabel(executionPlan.sampleJobs)), Savont \(executionPlan.savontThreadsPerSample) thread/sample."
        )
        let stagedSamples = try stageSamples(
            request: request,
            workDirectory: workDirectory,
            logicalFinalOutputURL: logicalFinalOutputURL,
            progressHandler: { fraction, message in
                progress.emit(fraction, message)
            }
        )
        let orderedSamples = FullLengthONTMHCSampleScheduler.processingOrder(for: stagedSamples)
        let totalReadCount = stagedSamples.reduce(0) { $0 + max(1, $1.readCount) }
        progress.emit(
            FullLengthONTMHCSampleScheduler.processingStartProgress,
            "Processing \(orderedSamples.count) \(sampleLabel(orderedSamples.count)) largest-first across \(executionPlan.sampleJobs) concurrent sample \(jobLabel(executionPlan.sampleJobs))."
        )

        let sampleExecution = FullLengthONTMHCSampleExecutionConfiguration(
            workerThreads: executionPlan.workerThreadsPerSample,
            savontThreads: executionPlan.savontThreadsPerSample
        )
        var sampleResults: [FullLengthONTMHCSampleResult] = []
        var completedReadCount = 0
        var completedSampleCount = 0
        var nextSampleIndex = 0

        try await withThrowingTaskGroup(of: FullLengthONTMHCSampleResult.self) { group in
            func enqueueNextSample() {
                guard nextSampleIndex < orderedSamples.count else { return }
                let scheduled = orderedSamples[nextSampleIndex]
                let processingRank = nextSampleIndex + 1
                nextSampleIndex += 1
                progress.emit(
                    FullLengthONTMHCSampleScheduler.processingProgress(
                        completedReadCount: completedReadCount,
                        totalReadCount: totalReadCount
                    ),
                    "Started \(scheduled.sample) (\(processingRank)/\(orderedSamples.count), \(formattedReadCount(scheduled.readCount)) reads)."
                )
                let sampleProgressFraction = FullLengthONTMHCSampleScheduler.processingProgress(
                    completedReadCount: completedReadCount,
                    totalReadCount: totalReadCount
                )
                group.addTask {
                    try await processSample(
                        scheduled,
                        processingRank: processingRank,
                        request: request,
                        referenceFASTAURL: referenceFASTAURL,
                        execution: sampleExecution,
                        progressFraction: sampleProgressFraction,
                        progressHandler: { fraction, message in
                            progress.emit(fraction, message)
                        }
                    )
                }
            }

            for _ in 0..<min(executionPlan.sampleJobs, orderedSamples.count) {
                enqueueNextSample()
            }
            while let result = try await group.next() {
                sampleResults.append(result)
                completedReadCount += max(1, result.readCount)
                completedSampleCount += 1
                progress.emit(
                    FullLengthONTMHCSampleScheduler.processingProgress(
                        completedReadCount: completedReadCount,
                        totalReadCount: totalReadCount
                    ),
                    "Completed \(completedSampleCount)/\(orderedSamples.count): \(result.sample) (\(formattedReadCount(result.readCount)) reads)."
                )
                enqueueNextSample()
            }
        }

        let orderedResults = sampleResults.sorted { lhs, rhs in
            lhs.originalIndex < rhs.originalIndex
        }
        let minimap2ExecutableURL = try await condaManager.toolPath(
            name: "minimap2",
            environment: "minimap2"
        )
        let samtoolsExecutableURL = try await condaManager.toolPath(
            name: "samtools",
            environment: "samtools"
        )
        let cohortAlignmentBuilder = FullLengthONTMHCCohortAlignmentBuilder(
            minimap2ExecutableURL: minimap2ExecutableURL,
            samtoolsExecutableURL: samtoolsExecutableURL,
            workDirectoryCleaner: postPublicationWorkDirectoryCleaner
        )
        let cohortWorkDirectory = request.outputDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(".\(request.outputDirectory.lastPathComponent).cohort-alignment-work", isDirectory: true)
        try FileManager.default.createDirectory(at: cohortWorkDirectory, withIntermediateDirectories: true)
        try bindSiblingWorkDirectory(
            cohortWorkDirectory,
            stagedOutputURL: request.outputDirectory,
            request: request
        )
        let cohortAlignmentResult = try await cohortAlignmentBuilder.build(.init(
            samples: orderedResults.compactMap { result in
                guard !result.clusterRecords.isEmpty else { return nil }
                return FullLengthONTMHCSampleAlignmentInput(
                    sampleID: result.sample,
                    originalClustersFASTAURL: result.clustersFASTAURL,
                    clusterRecords: result.clusterRecords
                )
            },
            referenceAlleleFASTAURL: referenceFASTAURL,
            threads: request.threads,
            outputDirectoryURL: request.outputDirectory,
            workDirectoryURL: cohortWorkDirectory,
            keepIntermediates: request.keepIntermediates,
            deferTemporaryWorkDirectoryCleanup: true,
            allowEmptyCohort: orderedResults.allSatisfy(\.clusterRecords.isEmpty)
        ))
        let samtoolsVersion = cohortAlignmentResult.toolVersions.first {
            $0.toolName == "samtools"
        }?.version ?? "unknown"
        let bamView = try await cohortAlignmentBuilder.viewHeaderAndAlignments(
            in: cohortAlignmentResult.bamURL,
            temporaryWorkDirectoryURL: cohortAlignmentResult.temporaryWorkDirectoryURL,
            samtoolsVersion: samtoolsVersion
        )
        let candidateReferenceRecords = referenceCatalog.records
        let summariesBySample = try genotypeSummariesFromFinalCohortBAM(
            orderedResults: orderedResults,
            samURL: bamView.samURL,
            cohortAlignmentResult: cohortAlignmentResult,
            referenceFASTAURL: referenceFASTAURL,
            referenceRecords: candidateReferenceRecords,
            request: request
        )
        let hitSummaryDerivationStartedAt = Date()
        let referenceLengths = try FullLengthONTMHCClusterGenotyper
            .readFASTARecords(from: referenceFASTAURL)
            .reduce(into: [String: Int]()) { lengths, record in
                lengths[record.name] = record.sequence.count
            }
        let genotypingHitSummariesByTarget = try FullLengthONTMHCGenotypingHitSummaryAccumulator.summaries(
            samURL: bamView.samURL,
            bamPath: "artifacts/alignments/genotyping-evidence.bam",
            referenceLengths: referenceLengths,
            cdnaThreshold: request.cdnaThreshold,
            referenceRecords: candidateReferenceRecords,
            targetLengths: Dictionary(uniqueKeysWithValues: orderedResults.flatMap { result in
                result.clusterRecords.map { ("\(result.sample)|\($0.name)", $0.sequence.count) }
            })
        )
        let hitSummaryDerivationCompletedAt = Date()
        let authoritativeResults = try orderedResults.map { result in
            guard let summary = summariesBySample[result.sample] else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Final cohort BAM did not yield a summary for sample \(result.sample)."
                )
            }
            return result.applyingAuthoritativeGenotypingSummary(summary)
        }
        var allGenotypeRows = authoritativeResults.flatMap(\.genotypeRows)
        let sampleCounts = Dictionary(uniqueKeysWithValues: orderedResults.map { ($0.sample, $0.readCount) })
        var sampleSummaries = authoritativeResults.map(\.sampleSummary)
        var pipelineSteps = sampleResults
            .flatMap(\.steps)
            .sorted { lhs, rhs in lhs.startedAt < rhs.startedAt }
        pipelineSteps.append(referenceCatalog.step)
        let blastRescueDirectory = request.outputDirectory
            .appendingPathComponent(".full-length-ont-mhc", isDirectory: true)
            .appendingPathComponent("blast-rescue", isDirectory: true)
        let blastReferenceURL = try prepareBlastRescueReference(
            referenceFASTAURL,
            rescueDirectory: blastRescueDirectory
        )
        var rescueBySampleCluster: [String: FullLengthONTMHCBlastRescueMatch] = [:]
        var blastRescueTSVURLs: [URL] = []
        for result in authoritativeResults {
            let closestClusters = Set(result.closestMatches.map(\.cluster))
            let rescueCandidates = result.unmatchedClusters.filter { !closestClusters.contains($0.name) }
            let sampleDirectory = request.outputDirectory
                .appendingPathComponent("samples", isDirectory: true)
                .appendingPathComponent(result.sample, isDirectory: true)
            let rescueMatches = try await rescueUnmatchedMHCMatches(
                sample: result.sample,
                records: rescueCandidates,
                referenceFASTAURL: blastReferenceURL,
                sampleDirectory: sampleDirectory,
                steps: &pipelineSteps
            )
            if !rescueCandidates.isEmpty {
                blastRescueTSVURLs.append(
                    blastRescueTSVURL(
                        sample: result.sample,
                        sampleDirectory: sampleDirectory
                    )
                )
            }
            for match in rescueMatches {
                rescueBySampleCluster[sampleClusterKey(sample: match.sample, cluster: match.cluster)] = match
            }
        }
        let unmatchedClosestMatchRows = authoritativeResults.flatMap { result in
            let closestByCluster = Dictionary(uniqueKeysWithValues: result.closestMatches.map { ($0.cluster, $0) })
            return result.unmatchedClusters.map { record in
                FullLengthONTMHCUnmatchedSequenceNormalizer.workbookRow(
                    sample: result.sample,
                    record: record,
                    closestMatch: closestByCluster[record.name],
                    rescueMatch: rescueBySampleCluster[sampleClusterKey(sample: result.sample, cluster: record.name)]
                )
            }
        }
        for result in authoritativeResults {
            try append(records: result.unmatchedClusters, sample: result.sample, to: request.unmatchedClustersFASTAURL)
            try append(records: result.cdnaMatchedClusters, sample: result.sample, to: request.cdnaClustersFASTAURL)
        }
        let rawDecisionSerializationStartedAt = Date()
        try FileManager.default.createDirectory(
            at: request.rawUnmatchedConsensusesFASTAURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawDecisionDocument = FullLengthONTMHCRawUnmatchedDecisionDocument(
            rows: unmatchedClosestMatchRows
        )
        let rawDecisionEncoder = JSONEncoder()
        rawDecisionEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try rawDecisionEncoder.encode(rawDecisionDocument).write(
            to: request.rawUnmatchedConsensusDecisionsJSONURL,
            options: .atomic
        )
        let rawDecisionSerializationCompletedAt = Date()
        let orderedClusterFASTAURLs = authoritativeResults
            .map(\.clustersFASTAURL)
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        let orderedBlastRescueTSVURLs = blastRescueTSVURLs
            .sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        let rawDecisionInputs = [
            cohortAlignmentResult.bamURL,
            cohortAlignmentResult.baiURL,
            referenceFASTAURL,
            referenceCatalogProjectionURL,
        ] + orderedClusterFASTAURLs + orderedBlastRescueTSVURLs
        var rawDecisionArgv = [
            "lungfish-in-process", "serialize-raw-unmatched-consensus-decisions",
            "--genotyping-bam", cohortAlignmentResult.bamURL.path,
            "--genotyping-bai", cohortAlignmentResult.baiURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--reference-catalog", referenceCatalogProjectionURL.path,
        ]
        for inputURL in orderedClusterFASTAURLs {
            rawDecisionArgv += ["--cluster-fasta", inputURL.path]
        }
        for inputURL in orderedBlastRescueTSVURLs {
            rawDecisionArgv += ["--blast-rescue-tsv", inputURL.path]
        }
        rawDecisionArgv += [
            "--output", request.rawUnmatchedConsensusDecisionsJSONURL.path,
        ]
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish-in-process:serialize-raw-unmatched-consensus-decisions",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: rawDecisionArgv,
            resolvedOptions: [
                "schemaVersion": .integer(FullLengthONTMHCRawUnmatchedDecisionDocument.schemaVersion),
                "rowCount": .integer(rawDecisionDocument.rows.count),
                "rowIdentityFields": .array([
                    .string("sample_id"), .string("source_cluster_id"), .string("cluster_read_count"),
                    .string("raw_sequence"), .string("candidate_sequence"),
                    .string("candidate_was_reverse_complemented"),
                ]),
                "orientationRule": .string("raw cohort strand XOR full-candidate reverse-complement"),
                "trimRule": .string("mapped interval is metadata; complete oriented consensus defines candidate identity"),
                "closestMatchRule": .string("persist selected minimap2 evidence from the cohort BAM or BLAST evidence from checksum-bound per-sample TSVs with every row"),
                "orderingRule": .string("sample, source cluster, candidate sequence, cluster read count"),
                "blastRescueTSVCount": .integer(orderedBlastRescueTSVURLs.count),
                "blastRescueTSVOrderingRule": .string("standardized absolute path, bytewise ascending"),
                "blastRescueMinimumQueryCoveragePercent": .number(
                    FullLengthONTMHCBlastRescueMatch.minimumQueryCoverage
                ),
                "blastRescueMinimumAlignedBases": .integer(
                    FullLengthONTMHCBlastRescueMatch.minimumAlignedBases
                ),
                "blastRescueMinimumPercentIdentity": .number(
                    FullLengthONTMHCBlastRescueMatch.minimumPercentIdentity
                ),
                "blastRescueMaximumEValue": .number(
                    FullLengthONTMHCBlastRescueMatch.maximumEValue
                ),
                "blastRescueSelectionRule": .string(
                    "lowest e-value, highest bit score, query coverage, percent identity, aligned bases, then closest reference"
                ),
            ],
            inputs: rawDecisionInputs,
            outputs: [request.rawUnmatchedConsensusDecisionsJSONURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: rawDecisionSerializationStartedAt,
            completedAt: rawDecisionSerializationCompletedAt
        ))

        let rawUnmatchedMaterializationStartedAt = Date()
        let rawDecisionDecoder = JSONDecoder()
        let persistedRawDecisionDocument = try rawDecisionDecoder.decode(
            FullLengthONTMHCRawUnmatchedDecisionDocument.self,
            from: Data(contentsOf: request.rawUnmatchedConsensusDecisionsJSONURL)
        )
        let rawUnmatchedRecords = FullLengthONTMHCUnmatchedClosestMatchWorkbookBuilder
            .deduplicatedFASTARecords(persistedRawDecisionDocument.rows)
        try writeFASTARecords(
            rawUnmatchedRecords,
            to: request.rawUnmatchedConsensusesFASTAURL
        )
        let rawUnmatchedMaterializationCompletedAt = Date()
        let rawUnmatchedMaterializationArgv = [
            "lungfish-in-process", "materialize-raw-unmatched-consensus-fasta",
            "--decisions", request.rawUnmatchedConsensusDecisionsJSONURL.path,
            "--output", request.rawUnmatchedConsensusesFASTAURL.path,
        ]
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish-in-process:materialize-raw-unmatched-consensus-fasta",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: rawUnmatchedMaterializationArgv,
            resolvedOptions: [
                "recordCount": .integer(rawUnmatchedRecords.count),
                "sequenceIdentityRule": .string("SHA-256 of complete oriented consensus sequence"),
                "supportMetadataRule": .string("aggregate occurrence, sample, and cluster-read support by sequence identity"),
                "outputPath": .string("artifacts/internal/raw-unmatched-consensuses.fasta"),
                "rootPublicationOwner": .string("FullLengthONTMHCCandidateArtifactWriter"),
                "canonicalRootOutputPath": .string("deduplicated_unmatched_clusters.fasta"),
                "decisionPayloadSchemaVersion": .integer(
                    FullLengthONTMHCRawUnmatchedDecisionDocument.schemaVersion
                ),
            ],
            inputs: [request.rawUnmatchedConsensusDecisionsJSONURL],
            outputs: [request.rawUnmatchedConsensusesFASTAURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: rawUnmatchedMaterializationStartedAt,
            completedAt: rawUnmatchedMaterializationCompletedAt
        ))

        let evidenceArtifactPair = try validatedEvidenceArtifactPair(
            cohortAlignmentResult,
            bundleDirectoryURL: request.outputDirectory
        )
        let candidateWriter = FullLengthONTMHCCandidateArtifactWriter(
            minimap2ExecutableURL: minimap2ExecutableURL,
            samtoolsExecutableURL: samtoolsExecutableURL
        )
        let candidateWorkDirectory = candidateArtifactWorkDirectory(
            for: request.outputDirectory
        )
        try FileManager.default.createDirectory(at: candidateWorkDirectory, withIntermediateDirectories: true)
        try bindSiblingWorkDirectory(
            candidateWorkDirectory,
            stagedOutputURL: request.outputDirectory,
            request: request
        )
        let candidateReferenceAnnotationInputURLs = request.referenceSourceURL.pathExtension.lowercased() == "lungfishref"
            ? try mhcReferenceVisualizationInputURLs(
                sourceURL: request.referenceSourceURL,
                fastaURL: referenceFASTAURL
            )
            : try mhcReferenceCatalogInputURLs(
                sourceURL: request.referenceSourceURL,
                fastaURL: referenceFASTAURL
            )
        let candidateArtifactResult = try await candidateWriter.stage(.init(
            observations: try unmatchedClosestMatchRows.map { row in
                let summaries = try genotypingHitSummariesByTarget["\(row.sample)|\(row.cluster)"]
                    .map { summary in
                        try FullLengthONTMHCCandidateObservationNormalizer.canonicalize(
                            summary: summary,
                            candidateWasReverseComplemented: row.candidateWasReverseComplemented
                        )
                    }
                return FullLengthONTMHCCandidateSequenceObservation(
                    sampleID: row.sample,
                    readGroupID: row.sample,
                    sourceClusterID: row.cluster,
                    clusterReadCount: row.clusterReads,
                    sequence: row.candidateSequence,
                    genotypingHitSummaries: summaries.map { [$0] } ?? []
                )
            },
            referenceAlleleFASTAURL: referenceFASTAURL,
            rawUnmatchedConsensusesFASTAURL: request.rawUnmatchedConsensusesFASTAURL,
            referenceBundleURL: request.referenceSourceURL,
            referenceAnnotationInputURLs: candidateReferenceAnnotationInputURLs,
            referenceRecords: candidateReferenceRecords,
            genotypingEvidence: evidenceArtifactPair,
            threads: request.threads,
            outputDirectoryURL: request.outputDirectory,
            finalOutputDirectoryURL: logicalFinalOutputURL,
            workDirectoryURL: candidateWorkDirectory,
            analysisName: request.outputName,
            projectBundleName: request.projectURL?.lastPathComponent
        ))
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish MHC genotyping hit summary accumulator",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "summarize-full-length-ont-mhc-genotyping-hits",
                "--bam-path", "artifacts/alignments/genotyping-evidence.bam",
                "--cdna-threshold", String(request.cdnaThreshold),
                bamView.samURL.path,
                referenceFASTAURL.path,
            ],
            resolvedOptions: [
                "alignmentIdentity": .array([
                    .string("bam_path"), .string("query_name"), .string("reference_name"),
                    .string("read_group_id"), .string("reference_start"), .string("cigar"),
                ]),
                "alignmentCountSemantics": .string("unique-schema-v1-locator-tuples"),
                "queryCountSemantics": .string("unique-locator-count-per-query-and-target"),
                "exactGenomicRule": .string("zero SNP substitutions; exact end-to-end genomic known status additionally requires full reference and consensus spans from target position 1 with no I/D/N/S/H"),
                "partialExtensionDeferralRule": .string("a zero-SNP genomic overlap with no I/D/N but incomplete reference or consensus end coverage is deferred from initial known calls for reciprocal partial-extension classification; an exact end-to-end genomic match still wins"),
                "legacyBroadGenomicRule": .string("zero-SNP genomic relationships containing internal I/D/N events retain prior known-call behavior unless qualifying cDNA extension evidence independently supports an extension"),
                "cdnaCompatibilityRule": .string("zero SNP substitutions; cDNA reference coverage >= 0.95; no individual cDNA-deficit I/S/H event >= 20 bases"),
                "knownCDNAStructuralRule": .string("compatible cDNA; cluster coverage >= 0.95; each terminal cluster flank < 20 bases; no individual cluster-side D/N segment >= 20 bases"),
                "extensionCDNAStructuralRule": .string("compatible cDNA plus any terminal cluster flank or individual cluster-side D/N segment >= 20 bases"),
                "structuralSegmentMinimumBases": .integer(20),
                "minimumCDNAReferenceCoverage": .number(0.95),
                "cohortAlignmentOrientation": .string("reference allele is SAM query; consensus cluster is SAM target; target POS/end flanks and D/N are cluster-only sequence; I/S/H are missing cDNA-query coverage"),
                "reciprocalAlignmentOrientation": .string("consensus cluster is SAM query; reference allele is SAM target; I/S are cluster-only sequence; D/N and uncovered target ends are missing cDNA-reference coverage"),
                "cohortCDNAReferenceCoverageDefinition": .string("comparable query/reference bases / annotated cDNA reference length, clamped to 1; I/S/H deficit bases excluded"),
                "cohortClusterCoverageDefinition": .string("target reference span / complete consensus cluster length, clamped to 1"),
                "reciprocalCDNAReferenceCoverageDefinition": .string("comparable query/reference bases / annotated cDNA reference length, clamped to 1; D/N/uncovered-target deficit bases excluded"),
                "reciprocalClusterCoverageDefinition": .string("query span / complete consensus cluster length, clamped to 1"),
                "cohortInterpretationOrientation": .string("canonical candidate orientation: raw cohort strand XOR full-candidate reverse-complement; leading/trailing cluster flanks swapped when reversed"),
                "secondaryAlignmentCompletenessRule": .string("cohort minimap2 -N equals per-sample consensus target count; reciprocal minimap2 -N equals reference record count; secondary=yes; no fixed cap"),
                "eventThresholdSemantics": .string("20-base threshold is applied to each individual event and each terminal side; event lengths are never summed to cross the threshold"),
                "classificationPrecedence": .array([
                    .string("exact genomic known"), .string("partial extension candidate"),
                    .string("structural cDNA extension candidate"),
                    .string("end-to-end cDNA known"), .string("SNP-defined novel"), .string("un-nameable"),
                ]),
                "perReferenceCollapseRule": .string("retain one best full-coverage interpretation per raw cDNA reference ID by relationship, cDNA coverage, cluster coverage, then score; retain all compatible reference IDs"),
                "strandConflictRule": .string("equally compatible opposite-strand interpretations are ambiguous and un-nameable"),
                "genomicLocusResolutionRule": .string("unambiguous genomic reciprocal evidence resolves locus and closest comparison; naming cDNAs are filtered to that locus while all compatible cDNA interpretations remain in the audit payload"),
                "provisionalNamingAmbiguityRule": .string("one compatible in-locus cDNA name supplies _ext base; otherwise genomic closest supplies base and provisional_naming_ambiguous is true"),
                "candidateSequenceIdentityRule": .string("complete consensus, reverse-complemented as a whole when selected strand is reverse; mapped-interval crop is metadata only and never defines candidate identity, deduplicated FASTA, reciprocal input, or full-length Excel sequence"),
                "candidateDocumentSchemaVersion": .integer(5),
                "referenceMoleculeClassSource": .string("materialized annotated MHC reference catalog; length threshold is fallback only when metadata is absent"),
                "retainedCDNAExtensionInterpretationCount": .integer(
                    genotypingHitSummariesByTarget.values.reduce(0) {
                        $0 + $1.cdnaExtensionInterpretations.count
                    }
                ),
                "structurallyReroutedClusterCount": .integer(Set(
                    summariesBySample.values.flatMap(\.cdnaStructuralInterpretations).filter {
                        $0.relationship == .extension
                    }.map(\.clusterID)
                ).count),
                "closestBiologicalRank": .array([
                    .string("snps-ascending"), .string("non-intron-indel-bases-ascending"),
                    .string("matched-bases-descending"), .string("alignment-score-descending"),
                ]),
                "closestTieSemantics": .string("retain-all-query-names-before-lexical-tie-break"),
                "cdnaThreshold": .integer(request.cdnaThreshold),
            ],
            inputs: [cohortAlignmentResult.bamURL, bamView.samURL, referenceFASTAURL, referenceCatalogProjectionURL],
            outputs: [candidateArtifactResult.candidateJSONURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: hitSummaryDerivationStartedAt,
            completedAt: hitSummaryDerivationCompletedAt
        ))
        try metadataPublicationObserver(.candidateArtifactsStaged(
            outputDirectoryURL: request.outputDirectory
        ))
        try Task.checkCancellation()
        let reciprocalKnownRows = reciprocalKnownGenotypeRows(
            from: candidateArtifactResult
        )
        allGenotypeRows.append(contentsOf: reciprocalKnownRows)
        let cdnaAlleles = Set(candidateReferenceRecords.filter {
            $0.moleculeClass == .cDNA
        }.map(\.alleleName))
        let cdnaReferenceIDs = Set(candidateReferenceRecords.filter {
            $0.moleculeClass == .cDNA
        }.map(\.sequenceID))
        sampleSummaries = sampleSummaries.map { summary in
            let rows = reciprocalKnownRows.filter { $0.sample == summary.sample }
            guard !rows.isEmpty else { return summary }
            let reciprocalCDNAClusters = Set(rows.filter {
                $0.referenceSequenceID.map(cdnaReferenceIDs.contains) ?? cdnaAlleles.contains($0.allele)
            }.map(\.cluster))
            let assignedSourceReads = Dictionary(grouping: rows, by: \.cluster).values.reduce(0) {
                $0 + ($1.map(\.clusterReads).max() ?? 0)
            }
            return FullLengthONTMHCSampleSummary(
                sample: summary.sample,
                totalInputReads: summary.totalInputReads,
                clusterCount: summary.clusterCount,
                clusteredReads: summary.clusteredReads,
                assignedReads: summary.assignedReads + assignedSourceReads,
                unmatchedClusters: max(0, summary.unmatchedClusters - Set(rows.map(\.cluster)).count),
                cdnaClusters: summary.cdnaClusters + reciprocalCDNAClusters.count,
                savontPreset: summary.savontPreset,
                savontStatus: .called,
                savontFallbackReason: summary.savontFallbackReason
            )
        }

        progress.emit(0.86, "Writing full-length ONT MHC genotype reports.")
        let reportRows = FullLengthONTMHCClusterReportBuilder.reportRows(
            genotypeRows: allGenotypeRows,
            sampleReadCounts: sampleCounts
        )
        try writeReportCSV(reportRows, to: request.reportCSVURL)
        try writeSampleSummaryCSV(sampleSummaries, to: request.sampleSummaryCSVURL)
        try writeStatsJSON(
            sampleSummaries: sampleSummaries,
            genotypeRows: allGenotypeRows,
            to: request.statsJSONURL
        )
        let candidateCanonicalizationInputURL = request.outputDirectory.appendingPathComponent(
            "artifacts/internal/mhc-candidate-canonicalization-input.json"
        )
        let candidateSourceMapURL = request.outputDirectory.appendingPathComponent(
            "artifacts/internal/mhc-candidate-source-map.json"
        )
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish final cohort BAM genotype parser",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-in-process", "parse-full-length-ont-mhc-final-bam",
                "--samtools-view", samtoolsExecutableURL.path,
                "--include-header",
                "--cdna-threshold", String(request.cdnaThreshold),
                "--min-unmatched-reads", String(request.minUnmatchedReads),
                "--reciprocal-known-bam", candidateArtifactResult.reciprocalBAMURL.path,
                "--reciprocal-known-bai", candidateArtifactResult.reciprocalBAIURL.path,
                "--candidate-canonicalization-input", candidateCanonicalizationInputURL.path,
                "--candidate-source-map", candidateSourceMapURL.path,
                cohortAlignmentResult.bamURL.path,
            ],
            resolvedOptions: [
                "postCropKnownFoldbackRule": .string(
                    "uniquely-resolved-reference-ready-zero-canonical-substitution-genomic-candidates-fold-back-to-named-allele;ambiguous-reference-ties-remain-candidates;incomplete-zero-canonical-substitution-genomic-candidates-remain-reviewable-partial-extensions"
                ),
            ],
            inputs: [
                cohortAlignmentResult.bamURL,
                URL(fileURLWithPath: bamView.commandRecord.stdoutLogDescriptor.path),
                referenceFASTAURL,
                candidateArtifactResult.reciprocalBAMURL,
                candidateArtifactResult.reciprocalBAIURL,
                candidateCanonicalizationInputURL,
                candidateSourceMapURL,
            ] + authoritativeResults.map(\.clustersFASTAURL),
            outputs: [request.reportCSVURL, request.sampleSummaryCSVURL, request.statsJSONURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: bamView.commandRecord.completedAt,
            completedAt: Date()
        ))
        let candidateDocument = try JSONDecoder().decode(
            ONTMHCCandidateAllelesDocument.self,
            from: Data(contentsOf: candidateArtifactResult.candidateJSONURL)
        )
        let unnameableDocument = try JSONDecoder().decode(
            ONTMHCUnnameableClustersDocument.self,
            from: Data(contentsOf: candidateArtifactResult.unnameableJSONURL)
        )
        let reviewableRowCatalogPublication =
            try publishReviewableRowCatalogIfNeeded(
                request: request,
                referenceRecords: candidateReferenceRecords,
                referenceCatalogProjectionURL: referenceCatalogProjectionURL,
                reportRows: reportRows,
                sampleNames: sampleSummaries.map(\.sample),
                candidateDocument: candidateDocument,
                candidateJSONURL: candidateArtifactResult.candidateJSONURL,
                unnameableDocument: unnameableDocument,
                unnameableJSONURL: candidateArtifactResult.unnameableJSONURL,
                genotypingEvidenceBAMURL: cohortAlignmentResult.bamURL,
                genotypingEvidenceBAIURL: cohortAlignmentResult.baiURL
            )
        if let publication = reviewableRowCatalogPublication,
           let step = publication.provenance.steps.first {
            pipelineSteps.append(FullLengthONTMHCProvenanceStep(
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                resolvedOptions: step.resolvedOptions,
                runtimeIdentity: step.runtimeIdentity ?? ProvenanceRuntimeIdentity(),
                inputs: step.inputs.map { URL(fileURLWithPath: $0.path) },
                outputs: [publication.outputURL],
                exitStatus: Int32(step.exitStatus ?? 0),
                stderr: step.stderr,
                startedAt: step.startedAt ?? publication.provenance.createdAt,
                completedAt: step.completedAt ?? publication.provenance.createdAt
            ))
        }
        let referenceVisualizationPublication = try publishMHCReferenceVisualizations(
            referenceBundleURL: request.referenceSourceURL,
            referenceFASTAURL: referenceFASTAURL,
            referenceRecords: candidateReferenceRecords,
            exactCallRows: allGenotypeRows,
            exactCallInputURL: request.reportCSVURL,
            candidateDocument: candidateDocument,
            candidateJSONURL: candidateArtifactResult.candidateJSONURL,
            unnameableDocument: unnameableDocument,
            unnameableJSONURL: candidateArtifactResult.unnameableJSONURL,
            outputDirectoryURL: request.outputDirectory,
            finalOutputDirectoryURL: logicalFinalOutputURL,
            steps: &pipelineSteps
        )
        let haplotypeAnalysis = try writeHaplotypeAnalysisIfRequested(
            request: request,
            supportDirectory: request.outputDirectory.appendingPathComponent(".full-length-ont-mhc", isDirectory: true),
            generatedAt: Date()
        )
        let orderedAlleles = try FullLengthONTMHCClusterGenotyper
            .readFASTARecords(from: referenceFASTAURL)
            .map(\.name)
        let workbookAssemblyStartedAt = Date()
        let workbookProjection = try FullLengthONTMHCWorkbookProjection(
            candidateDocument: candidateDocument,
            unnameableDocument: unnameableDocument,
            sampleOrder: sampleSummaries.map(\.sample)
        )
        let knownAlleleDisplayNames = Dictionary(
            uniqueKeysWithValues: candidateReferenceRecords.map { ($0.sequenceID, $0.alleleName) }
        )
        let normalizedUnmatchedRows = try workbookProjection.normalizedUnmatchedRows(
            candidateFASTARecords: FullLengthONTMHCClusterGenotyper.readFASTARecords(
                from: candidateArtifactResult.candidateFASTAURL
            ),
            unnameableFASTARecords: FullLengthONTMHCClusterGenotyper.readFASTARecords(
                from: candidateArtifactResult.unnameableFASTAURL
            ),
            candidateGenBankRecords: try GenBankReader(
                url: candidateArtifactResult.candidateGenBankURL
            ).readAllSync(),
            unnameableGenBankRecords: try GenBankReader(
                url: candidateArtifactResult.unnameableGenBankURL
            ).readAllSync(),
            knownAlleleDisplayNames: knownAlleleDisplayNames
        )
        let workbookProjectionInputURL = request.outputDirectory
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("projections", isDirectory: true)
            .appendingPathComponent("mhc-workbook-projection-input.json")
        let projectionInputDocument = FullLengthONTMHCWorkbookProjectionInputDocument(
            sourceSummary: .init(
                reportRowCount: reportRows.count,
                sampleSummaryCount: sampleSummaries.count,
                genotypeRowCount: allGenotypeRows.count,
                unmatchedClusterRowCount: unmatchedClosestMatchRows.count,
                orderedAlleleCount: orderedAlleles.count,
                includesHaplotypeAnalysis: haplotypeAnalysis != nil,
                candidateRecordCount: candidateDocument.candidates.count,
                unnameableRecordCount: unnameableDocument.clusters.count,
                normalizedUnmatchedRowCount: normalizedUnmatchedRows.count,
                referenceRecordCount: candidateReferenceRecords.count
            ),
            sheets: workbookSheets(
                reportRows: reportRows,
                sampleSummaries: sampleSummaries,
                haplotypeAnalysis: haplotypeAnalysis,
                projection: workbookProjection,
                normalizedUnmatchedRows: normalizedUnmatchedRows,
                knownAlleleDisplayNames: knownAlleleDisplayNames
            )
        )
        try FileManager.default.createDirectory(
            at: workbookProjectionInputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let workbookInputEncoder = JSONEncoder()
        workbookInputEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try workbookInputEncoder.encode(projectionInputDocument).write(
            to: workbookProjectionInputURL,
            options: .atomic
        )
        let workbookAssemblyCompletedAt = Date()
        var workbookAssemblyInputs = [
            candidateArtifactResult.candidateJSONURL,
            candidateArtifactResult.candidateFASTAURL,
            candidateArtifactResult.candidateGenBankURL,
            candidateArtifactResult.unnameableJSONURL,
            candidateArtifactResult.unnameableFASTAURL,
            candidateArtifactResult.unnameableGenBankURL,
            cohortAlignmentResult.bamURL,
            cohortAlignmentResult.baiURL,
            candidateArtifactResult.reciprocalBAMURL,
            candidateArtifactResult.reciprocalBAIURL,
            request.reportCSVURL,
            request.sampleSummaryCSVURL,
            request.deduplicatedUnmatchedClustersFASTAURL,
            referenceFASTAURL,
            referenceCatalogProjectionURL,
        ]
        if haplotypeAnalysis != nil,
           FileManager.default.fileExists(atPath: request.haplotypeAnalysisURL.path) {
            workbookAssemblyInputs.append(request.haplotypeAnalysisURL)
        }
        var workbookAssemblyArgv = [
            "lungfish-in-process", "assemble-mhc-workbook-projection-input",
            "--candidate-json", candidateArtifactResult.candidateJSONURL.path,
            "--candidate-fasta", candidateArtifactResult.candidateFASTAURL.path,
            "--candidate-genbank", candidateArtifactResult.candidateGenBankURL.path,
            "--unnameable-json", candidateArtifactResult.unnameableJSONURL.path,
            "--unnameable-fasta", candidateArtifactResult.unnameableFASTAURL.path,
            "--unnameable-genbank", candidateArtifactResult.unnameableGenBankURL.path,
            "--genotyping-bam", cohortAlignmentResult.bamURL.path,
            "--genotyping-bai", cohortAlignmentResult.baiURL.path,
            "--reciprocal-bam", candidateArtifactResult.reciprocalBAMURL.path,
            "--reciprocal-bai", candidateArtifactResult.reciprocalBAIURL.path,
            "--report-csv", request.reportCSVURL.path,
            "--sample-summary-csv", request.sampleSummaryCSVURL.path,
            "--unmatched-fasta", request.deduplicatedUnmatchedClustersFASTAURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--reference-catalog", referenceCatalogProjectionURL.path,
            "--output", workbookProjectionInputURL.path,
        ]
        if let assayID = request.haplotypeAssayID {
            workbookAssemblyArgv += ["--haplotype-assay", assayID]
        }
        if let definitionSetID = request.haplotypeDefinitionSetID {
            workbookAssemblyArgv += ["--haplotype-definition-set", definitionSetID]
        }
        if haplotypeAnalysis != nil {
            workbookAssemblyArgv += ["--haplotype-analysis", request.haplotypeAnalysisURL.path]
        }
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish-in-process:assemble-mhc-workbook-projection-input",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: workbookAssemblyArgv,
            resolvedOptions: [
                "reportRowCount": .integer(reportRows.count),
                "sampleSummaryCount": .integer(sampleSummaries.count),
                "genotypeRowCount": .integer(allGenotypeRows.count),
                "unmatchedClusterRowCount": .integer(unmatchedClosestMatchRows.count),
                "orderedAlleleCount": .integer(orderedAlleles.count),
                "normalizedUnmatchedRowCount": .integer(normalizedUnmatchedRows.count),
                "referenceRecordCount": .integer(candidateReferenceRecords.count),
                "projectionSchemaVersion": .integer(FullLengthONTMHCWorkbookProjectionInputDocument.schemaVersion),
                "includesHaplotypeAnalysis": .boolean(haplotypeAnalysis != nil),
                "inProcessSourceException": .string("typed row arrays are fully materialized in deterministic projection JSON"),
            ],
            inputs: workbookAssemblyInputs,
            outputs: [workbookProjectionInputURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: workbookAssemblyStartedAt,
            completedAt: workbookAssemblyCompletedAt
        ))

        let workbookProjectionStartedAt = Date()
        let durableWorkbookInput = try JSONDecoder().decode(
            FullLengthONTMHCWorkbookProjectionInputDocument.self,
            from: Data(contentsOf: workbookProjectionInputURL)
        )
        try FullLengthONTMHCXLSXPackageWriter.write(
            sheets: durableWorkbookInput.sheets,
            to: request.workbookURL
        )
        let workbookProjectionCompletedAt = Date()
        pipelineSteps.append(FullLengthONTMHCProvenanceStep(
            toolName: "lungfish-internal mhc-candidate-workbook-project",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: [
                "lungfish-internal", "mhc-candidate-workbook-project",
                "--projection-input", workbookProjectionInputURL.path,
                "--workbook", request.workbookURL.path,
                "--shared-novel-tint", FullLengthONTMHCWorkbookTintDefaults.sharedNovel,
                "--singleton-novel-tint", FullLengthONTMHCWorkbookTintDefaults.singletonNovel,
                "--shared-extension-tint", FullLengthONTMHCWorkbookTintDefaults.sharedExtension,
                "--singleton-extension-tint", FullLengthONTMHCWorkbookTintDefaults.singletonExtension,
            ],
            resolvedOptions: [
                "sharedNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedNovel),
                "singletonNovelTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonNovel),
                "sharedExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.sharedExtension),
                "singletonExtensionTint": .string(FullLengthONTMHCWorkbookTintDefaults.singletonExtension),
            ],
            inputs: [workbookProjectionInputURL],
            outputs: [request.workbookURL],
            exitStatus: 0,
            stderr: nil,
            startedAt: workbookProjectionStartedAt,
            completedAt: workbookProjectionCompletedAt
        ))
        let workbookCopy = try createInitialCurrentWorkbookCopy(for: request)
        pipelineSteps.append(workbookCopy.step)
        let referenceRecordStoreSnapshot = try await GenotypeReferenceRecordStoreSnapshot.publish(
            fromReferenceBundle: request.referenceSourceURL,
            toResultBundle: request.outputDirectory
        )
        if let snapshot = referenceRecordStoreSnapshot {
            pipelineSteps.append(FullLengthONTMHCProvenanceStep(
                toolName: "lungfish genotype reference metadata snapshot",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: ["copy", snapshot.sourceURL.path, snapshot.destinationURL.path],
                inputs: [snapshot.sourceURL],
                outputs: [snapshot.destinationURL],
                exitStatus: 0,
                stderr: nil,
                startedAt: snapshot.startedAt,
                completedAt: snapshot.completedAt
            ))
        }
        try rewriteCheckpointPaths(
            in: request.outputDirectory,
            replacing: request.outputDirectory.standardizedFileURL.path,
            with: logicalFinalOutputURL.standardizedFileURL.path
        )
        let manifestCreatedAt = Date()
        var manifestPublicationPlan: FullLengthONTMHCSuccessManifestPublicationPlan?
        do {
            let plan = try stageManifest(
                request: request,
                workbookRevision: workbookCopy.revision,
                evidenceArtifactPair: evidenceArtifactPair,
                candidateArtifacts: candidateArtifactResult.manifest,
                referenceVisualizations: referenceVisualizationPublication?.descriptor,
                referenceRecordStore: referenceRecordStoreSnapshot?.info,
                reviewableRowCatalog: reviewableRowCatalogPublication?.artifact,
                createdAt: manifestCreatedAt
            )
            manifestPublicationPlan = plan
            let provenanceCompletedAt = Date()
            try writeProvenance(
                request: request,
                referenceFASTAURL: referenceFASTAURL,
                executionPlan: executionPlan,
                stagedSamples: stagedSamples,
                processingOrder: orderedSamples,
                steps: pipelineSteps,
                cohortAlignmentResult: cohortAlignmentResult,
                bamViewRecord: bamView.commandRecord,
                candidateArtifactResult: candidateArtifactResult,
                referenceVisualizationPublication: referenceVisualizationPublication,
                manifestPublicationPlan: plan,
                startedAt: startedAt,
                completedAt: provenanceCompletedAt
            )
            try metadataPublicationObserver(.provenanceWrittenBeforeManifestPublication(
                stagedManifestURL: plan.stagedURL,
                finalManifestURL: ONTGenotypeResultBundle.manifestURL(in: logicalFinalOutputURL),
                provenanceURL: request.provenanceURL
            ))
            manifestPublicationPlan = nil
        } catch {
            if let stagedURL = manifestPublicationPlan?.stagedURL,
               FileManager.default.fileExists(atPath: stagedURL.path) {
                do {
                    try FileManager.default.removeItem(at: stagedURL)
                } catch let cleanupError {
                    throw FullLengthONTMHCGenotypingError.reportFailed(
                        "Metadata staging failed (\(error.localizedDescription)); staged manifest cleanup also failed (\(cleanupError.localizedDescription))."
                    )
                }
            }
            throw error
        }
        let cleanupWarnings = cohortAlignmentResult.cleanupDiagnostics.map(cleanupWarning)
        progress.emit(
            0.98,
            "Finalizing full-length ONT MHC result before intermediate cleanup."
        )
        let result = FullLengthONTMHCGenotypingResult(
            outputDirectory: request.outputDirectory,
            reportCSVURL: request.reportCSVURL,
            sampleSummaryCSVURL: request.sampleSummaryCSVURL,
            statsJSONURL: request.statsJSONURL,
            workbookURL: request.currentWorkbookURL,
            primaryWorkbookURL: request.workbookURL,
            haplotypeAnalysisURL: haplotypeAnalysis == nil ? nil : request.haplotypeAnalysisURL,
            unmatchedClustersFASTAURL: request.unmatchedClustersFASTAURL,
            deduplicatedUnmatchedClustersFASTAURL: request.deduplicatedUnmatchedClustersFASTAURL,
            cdnaClustersFASTAURL: request.cdnaClustersFASTAURL,
            provenanceURL: request.provenanceURL,
            referenceFASTAURL: referenceFASTAURL,
            genotypingEvidenceBAMURL: cohortAlignmentResult.bamURL,
            genotypingEvidenceBAIURL: cohortAlignmentResult.baiURL,
            reciprocalEvidenceBAMURL: candidateArtifactResult.reciprocalBAMURL,
            reciprocalEvidenceBAIURL: candidateArtifactResult.reciprocalBAIURL,
            candidateAllelesJSONURL: candidateArtifactResult.candidateJSONURL,
            candidateAllelesFASTAURL: candidateArtifactResult.candidateFASTAURL,
            candidateAllelesGenBankURL: candidateArtifactResult.candidateGenBankURL,
            unnameableClustersJSONURL: candidateArtifactResult.unnameableJSONURL,
            unnameableClustersFASTAURL: candidateArtifactResult.unnameableFASTAURL,
            unnameableClustersGenBankURL: candidateArtifactResult.unnameableGenBankURL,
            cleanupWarnings: cleanupWarnings
        )
        return FullLengthONTMHCStagedRunResult(
            result: result,
            cohortWorkDirectory: cohortWorkDirectory,
            cohortTemporaryWorkDirectory:
                cohortAlignmentResult.temporaryWorkDirectoryURL,
            candidateWorkDirectory: candidateWorkDirectory
        )
    }

    internal func validateInputs(_ request: FullLengthONTMHCGenotypingRunRequest) throws {
        let paths = request.inputFASTQURLs + [
            request.referenceSourceURL,
        ] + [
            request.orientReferenceURL,
            request.forwardPrimerURL,
            request.reversePrimerURL,
        ].compactMap { $0 }
        for url in paths {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FullLengthONTMHCGenotypingError.missingInput(url.path)
            }
        }
        guard !request.inputFASTQURLs.isEmpty else {
            throw FullLengthONTMHCGenotypingError.invalidFASTQ("No FASTQ bundles selected")
        }
    }

    internal func finalizeStagedBundleMetadata(
        stagedOutputURL: URL,
        finalOutputURL: URL
    ) throws {
        let provenanceURL = stagedOutputURL.appendingPathComponent(
            "full-length-ont-mhc-genotyping-provenance.json"
        )
        try rewriteJSONStrings(
            at: provenanceURL,
            replacing: stagedOutputURL.standardizedFileURL.path,
            with: finalOutputURL.standardizedFileURL.path
        )
    }

}

// Widened from `private` and renamed during the F47 file split: this helper is
// now called from sibling extension files. The unqualified name `isDirectory`
// is already used by private free functions elsewhere in LungfishWorkflow, so
// module-scope visibility requires a unique name. Body unchanged.
func fullLengthONTMHCPathIsDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}
