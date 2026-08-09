import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func completeSuccessfulWorkDirectoryLifecycle(
        stagedRun: FullLengthONTMHCStagedRunResult,
        finalOutputURL: URL,
        projectRoot: URL,
        runID: UUID,
        keepIntermediates: Bool,
        cleanupPlan: GenotypingCleanupPlan
    ) -> FullLengthWorkDirectoryCleanupResult {
        if keepIntermediates {
            var warnings: [FullLengthONTMHCGenotypingCleanupWarning] = []
            var dispositions: [GenotypingWorkDirectoryDisposition] = []
            for (url, kind) in [
                (
                    stagedRun.cohortWorkDirectory,
                    FullLengthONTMHCGenotypingCleanupWarningKind
                        .cohortAlignmentWorkDirectory
                ),
                (
                    stagedRun.candidateWorkDirectory,
                    FullLengthONTMHCGenotypingCleanupWarningKind
                        .candidateArtifactWorkDirectory
                ),
            ] {
                let disposition = identityBoundRetainedDisposition(
                    plan: cleanupPlan,
                    url: url
                ) { detachedURL in
                    try OwnedWorkDirectoryMarkerStore.transition(
                        detachedURL,
                        expectedProjectURL: projectRoot,
                        expectedRunID: runID,
                        to: .completed
                    )
                }
                dispositions.append(disposition)
                if let error = disposition.error {
                    warnings.append(
                        .init(
                            kind: kind,
                            path: url.standardizedFileURL.path,
                            error: error,
                            publishedArtifactsRemainValid: true
                        )
                    )
                }
            }
            let workflowDirectory = finalOutputURL.appendingPathComponent(
                "workflow",
                isDirectory: true
            )
            if cleanupPlan.entry(for: workflowDirectory) != nil {
                let disposition = identityBoundRetainedDisposition(
                    plan: cleanupPlan,
                    url: workflowDirectory,
                    mutation: { _ in }
                )
                dispositions.append(disposition)
                if let error = disposition.error {
                    warnings.append(.init(
                        kind: .workflowIntermediates,
                        path: workflowDirectory.standardizedFileURL.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    ))
                }
            }
            return .init(warnings: warnings, dispositions: dispositions)
        }

        var warnings: [FullLengthONTMHCGenotypingCleanupWarning] = []
        var dispositions: [GenotypingWorkDirectoryDisposition] = []
        var cohortTemporaryCleanupFailed = false
        if cleanupPlan.entry(
            for: stagedRun.cohortTemporaryWorkDirectory
        ) != nil {
            let disposition = identityBoundRemovalDisposition(
                plan: cleanupPlan,
                url: stagedRun.cohortTemporaryWorkDirectory,
                successDisposition: "removed"
            ) {
                try postPublicationWorkDirectoryCleaner.removeWorkDirectory(
                    at: $0
                )
            }
            dispositions.append(disposition)
            if let error = disposition.error {
                cohortTemporaryCleanupFailed = true
                warnings.append(
                    .init(
                        kind: .cohortAlignmentTemporaryWorkDirectory,
                        path:
                            stagedRun.cohortTemporaryWorkDirectory
                                .standardizedFileURL.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    )
                )
            }
        }
        for (url, kind) in [
            (
                stagedRun.cohortWorkDirectory,
                FullLengthONTMHCGenotypingCleanupWarningKind
                    .cohortAlignmentWorkDirectory
            ),
            (
                stagedRun.candidateWorkDirectory,
                FullLengthONTMHCGenotypingCleanupWarningKind
                    .candidateArtifactWorkDirectory
            ),
        ] {
            if kind == .cohortAlignmentWorkDirectory,
               cohortTemporaryCleanupFailed {
                dispositions.append(.init(
                    path: url.standardizedFileURL.path,
                    disposition: "retained-cleanup-failed",
                    error:
                        "Retained because cleanup of the nested cohort "
                        + "alignment temporary work directory failed."
                ))
                continue
            }
            let disposition = identityBoundRemovalDisposition(
                plan: cleanupPlan,
                url: url,
                successDisposition: "removed"
            ) { detachedURL in
                try OwnedWorkDirectoryMarkerStore.transition(
                    detachedURL,
                    expectedProjectURL: projectRoot,
                    expectedRunID: runID,
                    to: .completed
                )
                try postPublicationWorkDirectoryCleaner.removeWorkDirectory(
                    at: detachedURL
                )
            }
            dispositions.append(disposition)
            if let error = disposition.error {
                warnings.append(
                    .init(
                        kind: kind,
                        path: url.standardizedFileURL.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    )
                )
            }
        }
        let relocatedWorkflowDirectory = finalOutputURL
            .appendingPathComponent("workflow", isDirectory: true)
        if cleanupPlan.entry(for: relocatedWorkflowDirectory) != nil {
            let workflowPath = relocatedWorkflowDirectory
                .standardizedFileURL.path
            let workflowEntries = cleanupPlan.entries.filter {
                $0.path == workflowPath
                    || $0.path.hasPrefix(workflowPath + "/")
            }.sorted {
                $0.path.split(separator: "/").count
                    > $1.path.split(separator: "/").count
            }
            var protectedDescendants: [String] = []
            for entry in workflowEntries {
                let url = URL(fileURLWithPath: entry.path)
                if protectedDescendants.contains(where: {
                    $0.hasPrefix(entry.path + "/")
                }) {
                    let disposition = GenotypingWorkDirectoryDisposition(
                        path: entry.path,
                        disposition: "retained-cleanup-failed",
                        error:
                            "Retained because an identity-mismatched or "
                            + "unremovable descendant must survive."
                    )
                    dispositions.append(disposition)
                    protectedDescendants.append(entry.path)
                    warnings.append(.init(
                        kind: .workflowIntermediates,
                        path: entry.path,
                        error: disposition.error ?? "Cleanup was retained.",
                        publishedArtifactsRemainValid: true
                    ))
                    continue
                }
                let disposition = identityBoundRemovalDisposition(
                    plan: cleanupPlan,
                    url: url,
                    successDisposition:
                        entry.path == workflowPath
                            ? "intermediates-removed"
                            : "removed"
                ) {
                    try postPublicationWorkDirectoryCleaner
                        .removeWorkDirectory(at: $0)
                }
                dispositions.append(disposition)
                if let error = disposition.error {
                    protectedDescendants.append(entry.path)
                    warnings.append(.init(
                        kind: .workflowIntermediates,
                        path: entry.path,
                        error: error,
                        publishedArtifactsRemainValid: true
                    ))
                }
            }
        }
        return .init(warnings: warnings, dispositions: dispositions)
    }

    internal func identityBoundRemovalDisposition(
        plan: GenotypingCleanupPlan,
        url: URL,
        successDisposition: String,
        remover: (URL) throws -> Void
    ) -> GenotypingWorkDirectoryDisposition {
        let path = url.standardizedFileURL.path
        guard let entry = plan.entry(for: url) else {
            return .init(
                path: path,
                disposition: "retained-identity-mismatch",
                error: "No immutable cleanup-plan identity exists for \(path)."
            )
        }
        switch GenotypingIdentityBoundCleanup.remove(entry, remover: remover) {
        case .removed:
            return .init(
                path: path,
                disposition: successDisposition,
                error: nil
            )
        case .identityMismatch(let detail):
            return .init(
                path: path,
                disposition: "retained-identity-mismatch",
                error: detail
            )
        case .failed(let detail):
            return .init(
                path: path,
                disposition: "retained-cleanup-failed",
                error: detail
            )
        case .retained(let quarantinePath):
            return .init(
                path: path,
                disposition: "retained-cleanup-failed",
                error: quarantinePath.map {
                    "Unexpectedly retained at \($0)."
                } ?? "Unexpectedly retained."
            )
        }
    }

    internal func identityBoundRetainedDisposition(
        plan: GenotypingCleanupPlan,
        url: URL,
        mutation: (URL) throws -> Void
    ) -> GenotypingWorkDirectoryDisposition {
        let path = url.standardizedFileURL.path
        guard let entry = plan.entry(for: url) else {
            return .init(
                path: path,
                disposition: "retained-identity-mismatch",
                error: "No immutable cleanup-plan identity exists for \(path)."
            )
        }
        switch GenotypingIdentityBoundCleanup.mutateAndRetain(
            entry,
            mutation: mutation
        ) {
        case .retained:
            return .init(
                path: path,
                disposition: "retained-by-request",
                error: nil
            )
        case .identityMismatch(let detail):
            return .init(
                path: path,
                disposition: "retained-identity-mismatch",
                error: detail
            )
        case .failed(let detail):
            return .init(
                path: path,
                disposition: "retained-cleanup-failed",
                error: detail
            )
        case .removed(let quarantinePath):
            return .init(
                path: path,
                disposition: "retained-cleanup-failed",
                error: "Unexpectedly removed via \(quarantinePath)."
            )
        }
    }

    internal func beginSuccessfulCleanupJournal(
        projectRoot: URL,
        runID: UUID,
        stagedRun: FullLengthONTMHCStagedRunResult,
        finalOutputURL: URL,
        retiredPublicationURL: URL?,
        keepIntermediates: Bool
    ) throws -> GenotypingCleanupPlan {
        let operationURL = ProjectOperationHistoryWriter(
            projectURL: projectRoot
        ).operationDirectoryURL(for: runID)
        let cleanupPlanURL = operationURL.appendingPathComponent(
            GenotypingCleanupJournal.planPayloadName
        )
        do {
            var candidates: [
                (
                    url: URL,
                    intendedAction: GenotypingCleanupIntendedAction
                )
            ] = [
                (
                    stagedRun.cohortWorkDirectory,
                    keepIntermediates
                        ? .retainByRequestAfterMarkerCompletion
                        : .removeOwnedWorkDirectory
                ),
                (
                    stagedRun.candidateWorkDirectory,
                    keepIntermediates
                        ? .retainByRequestAfterMarkerCompletion
                        : .removeOwnedWorkDirectory
                ),
            ]
            let workflowDirectory = finalOutputURL.appendingPathComponent(
                "workflow",
                isDirectory: true
            )
            if keepIntermediates {
                candidates.append(
                    (workflowDirectory, .retainByRequest)
                )
            } else {
                let descendantPaths =
                    try FileManager.default.subpathsOfDirectory(
                        atPath: workflowDirectory.path
                    )
                candidates.append(contentsOf: descendantPaths.map {
                    (
                        workflowDirectory.appendingPathComponent($0),
                        .removeRegenerableWorkflowIntermediates
                    )
                })
                candidates.append(
                    (
                        workflowDirectory,
                        .removeRegenerableWorkflowIntermediates
                    )
                )
            }
            if !keepIntermediates {
                candidates.insert(
                    (
                        stagedRun.cohortTemporaryWorkDirectory,
                        .removeOwnedTemporaryWorkDirectory
                    ),
                    at: 0
                )
            }
            if let retiredPublicationURL {
                candidates.append(
                    (
                        retiredPublicationURL,
                        .removeRetiredPublicationDirectory
                    )
                )
            }
            let entries = try GenotypingCleanupJournal.planEntries(candidates)
            try cleanupJournalObserver(.beforeInitialCreation)
            _ = try ProjectOperationHistoryWriter(
                projectURL: projectRoot
            ).createOperation(
                operationID: runID,
                payloads: [
                    GenotypingCleanupJournal.planPayloadName:
                        try GenotypingCleanupJournal.planData(
                            runID: runID,
                            entries: entries
                        ),
                ]
            )
            let plan = GenotypingCleanupPlan(
                runID: runID,
                operationURL: operationURL,
                outputBundleURL: finalOutputURL,
                entriesByPath: Dictionary(
                    uniqueKeysWithValues: entries.map { ($0.path, $0) }
                )
            )
            try cleanupJournalObserver(
                .afterInitialCreationBeforeMutation
            )
            return plan
        } catch {
            throw GenotypingCleanupJournalError(
                runID: runID,
                operationPath: operationURL.path,
                cleanupPlanPath: cleanupPlanURL.path,
                outputBundlePath: finalOutputURL.path,
                phase: .initialCreation,
                publishedArtifactsValid: true,
                retainedRootPaths:
                    [
                        stagedRun.cohortWorkDirectory,
                        stagedRun.candidateWorkDirectory,
                        finalOutputURL.appendingPathComponent("workflow"),
                        retiredPublicationURL,
                    ].compactMap { $0?.standardizedFileURL.path },
                underlyingDescription: error.localizedDescription
            )
        }
    }

    internal func appendSuccessfulCleanupDisposition(
        projectRoot: URL,
        runID: UUID,
        outputBundleURL: URL,
        dispositions: [GenotypingWorkDirectoryDisposition]
    ) throws {
        let operationURL = ProjectOperationHistoryWriter(
            projectURL: projectRoot
        ).operationDirectoryURL(for: runID)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(
                GenotypingWorkDirectoryDispositionEnvelope(
                    schemaVersion: 1,
                    runID: runID,
                    entries: dispositions
                )
            )
            try cleanupJournalObserver(.beforeTerminalAppend)
            try ProjectOperationHistoryWriter(
                projectURL: projectRoot
            ).append(
                data,
                named: GenotypingCleanupJournal.terminalPayloadName,
                toOperation: runID
            )
        } catch {
            throw GenotypingCleanupJournalError(
                runID: runID,
                operationPath: operationURL.path,
                cleanupPlanPath: operationURL.appendingPathComponent(
                    GenotypingCleanupJournal.planPayloadName
                ).path,
                outputBundlePath: outputBundleURL.standardizedFileURL.path,
                phase: .terminalAppend,
                publishedArtifactsValid: true,
                retainedRootPaths: dispositions.filter {
                    $0.disposition != "removed"
                        && $0.disposition != "intermediates-removed"
                }.map(\.path),
                underlyingDescription: error.localizedDescription
            )
        }
    }

    internal func failCurrentRunWorkDirectories(
        stagedOutputURL: URL,
        projectRoot: URL,
        runID: UUID,
        keepIntermediates: Bool,
        retainedRecoveryPaths: Set<String>
    ) -> [GenotypingWorkDirectoryDisposition] {
        let siblingParent = stagedOutputURL.deletingLastPathComponent()
        let ordinaryCurrentRunRoots = [
            siblingParent.appendingPathComponent(
                ".\(stagedOutputURL.lastPathComponent).cohort-alignment-work",
                isDirectory: true
            ),
            candidateArtifactWorkDirectory(for: stagedOutputURL),
            stagedOutputURL,
        ]
        let recoveryRoots = retainedRecoveryPaths
            .sorted()
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        var seenPaths = Set<String>()
        let currentRunRoots = (ordinaryCurrentRunRoots + recoveryRoots).filter {
            seenPaths.insert($0.standardizedFileURL.path).inserted
        }
        var dispositions: [GenotypingWorkDirectoryDisposition] = []
        for url in currentRunRoots {
            let path = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                continue
            }
            if retainedRecoveryPaths.contains(path) {
                do {
                    let markerURL = url.appendingPathComponent(
                        OwnedWorkDirectoryMarker.fileName
                    )
                    if FileManager.default.fileExists(atPath: markerURL.path) {
                        let marker = try OwnedWorkDirectoryMarkerStore.load(
                            from: url,
                            expectedProjectURL: projectRoot
                        )
                        if marker.state == .active {
                            try OwnedWorkDirectoryMarkerStore.transition(
                                url,
                                expectedProjectURL: projectRoot,
                                expectedRunID: runID,
                                to: .failed
                            )
                        }
                    }
                    dispositions.append(.init(
                        path: path,
                        disposition: "retained-rollback-recovery",
                        error: nil
                    ))
                } catch {
                    dispositions.append(.init(
                        path: path,
                        disposition: "retained-cleanup-failed",
                        error: cleanupErrorDescription(error)
                    ))
                }
                continue
            }
            do {
                try OwnedWorkDirectoryMarkerStore.transition(
                    url,
                    expectedProjectURL: projectRoot,
                    expectedRunID: runID,
                    to: .failed
                )
                if keepIntermediates {
                    dispositions.append(
                        .init(
                            path: path,
                            disposition: "retained-by-request",
                            error: nil
                        )
                    )
                } else {
                    try postPublicationWorkDirectoryCleaner
                        .removeWorkDirectory(at: url)
                    dispositions.append(
                        .init(
                            path: path,
                            disposition: "removed",
                            error: nil
                        )
                    )
                }
            } catch {
                dispositions.append(
                    .init(
                        path: path,
                        disposition: "retained-cleanup-failed",
                        error: cleanupErrorDescription(error)
                    )
                )
            }
        }
        return dispositions
    }

    internal func projectRelativePath(_ url: URL, projectRoot: URL) -> String? {
        let rootPath = projectRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    internal func bindSiblingWorkDirectory(
        _ directoryURL: URL,
        stagedOutputURL: URL,
        request: FullLengthONTMHCGenotypingRunRequest
    ) throws {
        let projectRoot = (request.projectURL
            ?? stagedOutputURL.deletingLastPathComponent()).standardizedFileURL
        let rootMarker = try OwnedWorkDirectoryMarkerStore.load(
            from: stagedOutputURL,
            expectedProjectURL: projectRoot
        )
        try OwnedWorkDirectoryMarkerStore.bindExistingDirectory(
            directoryURL,
            request: OwnedWorkDirectoryCreationRequest(
                projectURL: projectRoot,
                parentDirectoryURL: directoryURL.deletingLastPathComponent(),
                prefix: ".full-length-ont-mhc-work-",
                runID: rootMarker.runID,
                processIdentity: OwnedProcessIdentity(
                    processIdentifier: rootMarker.processIdentifier,
                    processStartTime: rootMarker.processStartTime,
                    bootSessionID: rootMarker.bootSessionID
                ),
                state: .active,
                lockRelativePath: rootMarker.lockRelativePath,
                keepIntermediates: rootMarker.keepIntermediates,
                toolName: rootMarker.toolName,
                toolVersion: rootMarker.toolVersion
            )
        )
    }

    internal func candidateArtifactWorkDirectory(for outputDirectoryURL: URL) -> URL {
        outputDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputDirectoryURL.lastPathComponent).candidate-artifact-work",
                isDirectory: true
            )
    }

    internal func retainCandidateFailureLogs(
        from candidateWorkDirectory: URL,
        for request: FullLengthONTMHCGenotypingRunRequest
    ) throws -> URL? {
        let safety = FullLengthONTMHCAlignmentSafety()
        try safety.requireSafeDirectoryTree(
            candidateWorkDirectory,
            role: "failed candidate artifact work directory"
        )
        guard let enumerator = FileManager.default.enumerator(
            at: candidateWorkDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return nil
        }
        let maximumRetainedLogCount = 32
        let maximumRetainedLogBytes: Int64 = 2 * 1_024 * 1_024
        var logURLs: [URL] = []
        for case let url as URL in enumerator {
            if logURLs.count == maximumRetainedLogCount {
                break
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            guard url.pathComponents.contains("logs")
                    || url.pathExtension.lowercased() == "log" else {
                continue
            }
            try safety.requireRegularFileNoFollow(
                url,
                role: "failed candidate artifact log"
            )
            guard try ProvenanceFileHasher.fileSize(of: url)
                <= maximumRetainedLogBytes else {
                continue
            }
            logURLs.append(url)
        }
        guard !logURLs.isEmpty else { return nil }
        let diagnosticsRoot = URL(
            fileURLWithPath: request.failureProvenanceURL.path + ".diagnostics",
            isDirectory: true
        )
        let retainedLogsRoot = diagnosticsRoot.appendingPathComponent(
            "candidate-artifact-logs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: retainedLogsRoot,
            withIntermediateDirectories: true
        )
        let sourcePrefix = candidateWorkDirectory.standardizedFileURL.path + "/"
        for sourceURL in logURLs.sorted(by: { $0.path < $1.path }) {
            let relativePath = sourceURL.standardizedFileURL.path
                .replacingOccurrences(of: sourcePrefix, with: "")
            let destinationURL = retainedLogsRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }
        return diagnosticsRoot
    }
}
