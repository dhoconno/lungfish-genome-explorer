import XCTest
import AppKit
import SwiftUI
import CryptoKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

// Configure, deferred mutation, and workbook publication lock behavior
@MainActor
final class GenotypeResultViewportWorkbookPublicationTests: GenotypeResultViewportTestCase {
    func testWorkbookPublicationLockDefersStyleReviewAndCommentInSubmissionOrder() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixAnnotationLockRetry")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let retryScheduler = MatrixWorkbookUpdateSchedulerSpy()
        let workbookScheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixAnnotationRetryScheduler = retryScheduler
        controller.matrixWorkbookUpdateScheduler = workbookScheduler
        var surfacedErrors: [Error] = []
        controller.onMatrixAnnotationCommandError = { surfacedErrors.append($0) }
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(for: bundleURL)

        controller.applyMatrixStyle(.init(targets: [target], field: .isItalic(true)))
        controller.applyMatrixReview(.init(targets: [target], intent: .set(.falsePositive)))
        controller.editMatrixComment(.init(targets: [target], intent: .upsert(body: "queued")))

        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 3)
        XCTAssertEqual(retryScheduler.scheduledCount, 1)
        XCTAssertEqual(workbookScheduler.scheduledCount, 0)
        XCTAssertEqual(
            controller.testingCurrentWorkbookUpdateStatus,
            "Saving annotation after the workbook update finishes."
        )
        XCTAssertTrue(surfacedErrors.isEmpty)
        var persisted = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
            forBundleAt: bundleURL
        )
        XCTAssertTrue(persisted.matrixStyles.isEmpty)
        XCTAssertTrue(persisted.matrixReviews.isEmpty)
        XCTAssertTrue(persisted.matrixComments.isEmpty)

        retryScheduler.fireScheduledActions()

        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 3)
        XCTAssertEqual(retryScheduler.scheduledCount, 1)
        XCTAssertEqual(
            controller.testingCurrentWorkbookUpdateStatus,
            "Saving annotation after the workbook update finishes."
        )
        XCTAssertTrue(surfacedErrors.isEmpty)
        publicationLock.release()
        retryScheduler.fireScheduledActions()

        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 0)
        XCTAssertEqual(workbookScheduler.scheduledCount, 0)
        XCTAssertNil(controller.testingCurrentWorkbookUpdateStatus)
        XCTAssertTrue(surfacedErrors.isEmpty)
        persisted = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
            forBundleAt: bundleURL
        )
        XCTAssertEqual(persisted.matrixStyles.map(\.target), [target])
        XCTAssertEqual(persisted.matrixReviews.map(\.target), [target])
        XCTAssertEqual(persisted.resolvedMatrixComments[target]?.body, "queued")
        XCTAssertEqual(
            persisted.auditLog
                .filter {
                    $0.action == "setMatrixStyle"
                        || $0.action == "setMatrixReview"
                        || $0.action == "upsertMatrixComment"
                }
                .map(\.action),
            ["setMatrixStyle", "setMatrixReview", "upsertMatrixComment"]
        )
    }


    func testExcelCaptureWaitsForPendingNativeAnnotationPersistenceBeforeOpeningPanel() throws {
        let root = try TestTempDirectory.make(prefix: "ExcelPendingNative")
        defer { TestTempDirectory.cleanup(root) }
        let controller = GenotypeResultViewController()
        let scheduler = MatrixWorkbookUpdateSchedulerSpy()
        controller.matrixAnnotationRetryScheduler = scheduler
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: root, samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SUPPORTED", reads: 9)
        ]))
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-A", genotype: "01_Mafa_A1_SUPPORTED", sample: "AnimalA")
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(for: root)
        defer { publicationLock.release() }
        controller.editMatrixComment(.init(targets: [target], intent: .upsert(body: "pending native note")))
        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 1)
        var panels = 0
        var failures = 0
        controller.excelSavePanelPresenter = { _, _, completion in panels += 1; completion(nil) }
        controller.onExcelExportEvent = { if case .failed = $0 { failures += 1 } }
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        XCTAssertEqual(panels, 0)
        XCTAssertEqual(failures, 1)
        publicationLock.release()
        scheduler.fireScheduledActions()
        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        XCTAssertEqual(panels, 1)
        let capture = try JSONDecoder().decode(GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(controller.captureExcelExportSnapshot().excelSnapshotData))
        XCTAssertEqual(capture.allMatrix.rows[0].cells[0].comment, "pending native note")
    }

    func testConfigureWaitsForDeferredMutationAndThenAppliesNewBundleContext() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixDeferredConfigure")
        defer { TestTempDirectory.cleanup(root) }
        let firstBundle = root.appendingPathComponent("first.lungfishgenotype", isDirectory: true)
        let secondBundle = root.appendingPathComponent("second.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: firstBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondBundle, withIntermediateDirectories: true)
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let retryScheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixAnnotationRetryScheduler = retryScheduler
        var drainedCount = 0
        controller.onDeferredMatrixAnnotationMutationsDrained = { drainedCount += 1 }
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: firstBundle,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "FIRST", reads: 9)]
        ))
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(for: firstBundle)
        controller.editMatrixComment(.init(
            targets: [target],
            intent: .upsert(body: "belongs to first")
        ))

        controller.configure(result: makeResult(
            bundleURL: secondBundle,
            samples: [],
            calls: [makeCall(sample: "AnimalB", genotype: "SECOND", reads: 8)]
        ))

        XCTAssertEqual(controller.testingResultBundleURL, firstBundle.standardizedFileURL)
        XCTAssertEqual(controller.testingPendingConfigurationBundleURL, secondBundle.standardizedFileURL)
        publicationLock.release()
        retryScheduler.fireScheduledActions()

        XCTAssertEqual(drainedCount, 1)
        XCTAssertEqual(controller.testingResultBundleURL, secondBundle.standardizedFileURL)
        XCTAssertNil(controller.testingPendingConfigurationBundleURL)
        XCTAssertEqual(
            try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: firstBundle)
                .resolvedMatrixComments[target]?.body,
            "belongs to first"
        )
        XCTAssertTrue(
            try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: secondBundle)
                .matrixComments.isEmpty
        )
    }


    func testDeferredConfigurationCancelPreservesDraftOpenedBeforeAnnotationRetryDrains()
        async throws
    {
        let root = try TestTempDirectory.make(prefix: "MatrixDeferredConfigureDraft")
        defer { TestTempDirectory.cleanup(root) }
        let firstBundle = root.appendingPathComponent(
            "first.lungfishgenotype",
            isDirectory: true
        )
        let secondBundle = root.appendingPathComponent(
            "second.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstBundle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondBundle,
            withIntermediateDirectories: true
        )
        let firstCall = makeCall(
            sample: "AnimalA",
            genotype: "FIRST",
            reads: 9
        )
        let retryScheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixAnnotationRetryScheduler = retryScheduler
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: firstBundle,
            samples: [],
            calls: [firstCall]
        ))
        let publicationLock =
            try ONTGenotypeBundlePublicationLock.acquire(for: firstBundle)
        controller.editMatrixComment(.init(
            targets: [.column(sample: "AnimalA")],
            intent: .upsert(body: "belongs to first")
        ))
        controller.configure(result: makeResult(
            bundleURL: secondBundle,
            samples: [],
            calls: [],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingUpdateManualHaplotypeLabel("Unsaved")
        var promptCount = 0
        controller.testingSetManualHaplotypeDraftDecisionProvider {
            transition in
            XCTAssertEqual(transition, .eligibilityChange)
            promptCount += 1
            return .cancel
        }

        publicationLock.release()
        retryScheduler.fireScheduledActions()
        for _ in 0..<100 where promptCount == 0 {
            await Task.yield()
        }
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(
            controller.testingResultBundleURL,
            firstBundle.standardizedFileURL
        )
        XCTAssertNil(controller.testingPendingConfigurationBundleURL)
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorSample,
            "AnimalA"
        )
        guard case .eligible = controller.manualHaplotypeEligibility else {
            return XCTFail(
                "Cancel must preserve the current genotype-only eligibility."
            )
        }
    }


    func testDeferredFailureOverlayRestoresUnderlyingWorkbookStatus() throws {
        struct WorkbookFailure: Error {}

        let root = try TestTempDirectory.make(prefix: "MatrixDeferredStatusOverlay")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let retryScheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixAnnotationRetryScheduler = retryScheduler
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: []))
        controller.applyCurrentWorkbookUpdateFailed(WorkbookFailure())
        let underlyingStatus = try XCTUnwrap(controller.testingCurrentWorkbookUpdateStatus)
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(for: bundleURL)

        controller.editMatrixComment(.init(
            targets: [target],
            intent: .upsert(body: "will hit unsafe lock")
        ))

        XCTAssertEqual(
            controller.testingCurrentWorkbookUpdateStatus,
            "Saving annotation after the workbook update finishes."
        )
        publicationLock.release()
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: bundleURL)
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        )
        var surfacedError: Error?
        controller.onMatrixAnnotationCommandError = { surfacedError = $0 }
        retryScheduler.fireScheduledActions()

        guard case .unsafeLock = surfacedError as? ONTGenotypeWorkbookUpdateRecoveryError else {
            return XCTFail("Expected unsafe lock error, got \(String(describing: surfacedError))")
        }
        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 0)
        XCTAssertEqual(controller.testingCurrentWorkbookUpdateStatus, underlyingStatus)
    }


    func testWorkbookPublicationLockClassificationTraversesOnlyLegitimatePrimaryWrappers() {
        let controller = GenotypeResultViewController()
        let lock = ONTGenotypeWorkbookUpdateRecoveryError.lockHeld("/tmp/publication.lock")
        let nested = NSError(
            domain: "test.wrapper",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: lock]
        )
        let transaction = GenotypeAnnotationPublicationTransactionError(
            primaryError: nested,
            rollbackError: nil
        )

        XCTAssertTrue(controller.testingIsWorkbookPublicationLockHeld(lock))
        XCTAssertTrue(controller.testingIsWorkbookPublicationLockHeld(transaction))
        XCTAssertFalse(controller.testingIsWorkbookPublicationLockHeld(
            ONTGenotypeWorkbookUpdateRecoveryError.unsafeLock("/tmp/publication.lock")
        ))
        XCTAssertFalse(controller.testingIsWorkbookPublicationLockHeld(
            GenotypeAnnotationPublicationTransactionError(
                primaryError: CocoaError(.fileWriteNoPermission),
                rollbackError: lock
            )
        ))
        XCTAssertFalse(controller.testingIsWorkbookPublicationLockHeld(
            NSError(
                domain: "test.lookalike",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Workbook publication lock is already held: /tmp/publication.lock",
                ]
            )
        ))
    }


    func testUnsafeWorkbookPublicationLockSurfacesWithoutDeferredRetry() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixAnnotationUnsafeLock")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let retryScheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixAnnotationRetryScheduler = retryScheduler
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: bundleURL)
        try? FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        )
        var surfacedError: Error?
        controller.onMatrixAnnotationCommandError = { surfacedError = $0 }

        controller.applyMatrixReview(.init(targets: [target], intent: .set(.falsePositive)))

        guard case .unsafeLock = surfacedError as? ONTGenotypeWorkbookUpdateRecoveryError else {
            return XCTFail("Expected unsafe lock error, got \(String(describing: surfacedError))")
        }
        XCTAssertEqual(controller.testingDeferredMatrixAnnotationMutationCount, 0)
        XCTAssertEqual(retryScheduler.scheduledCount, 0)
    }


    func testFailedSidecarPublicationSchedulesNoWorkbookUpdate() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixWorkbookPublicationFailure")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let scheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixWorkbookUpdateScheduler = scheduler
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: []))
        let concurrent = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "other")
        try concurrent.addMatrixComment(target: target, body: "concurrent")
        var surfacedError: Error?
        controller.onMatrixAnnotationCommandError = { surfacedError = $0 }

        controller.editMatrixComment(.init(targets: [target], intent: .upsert(body: "stale")))

        XCTAssertNotNil(surfacedError)
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }


    func testStalePublicationReloadsAndPublishesExactConcurrentAnnotationUnionOnly() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixStaleExactUnion")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_FIRST"
        let second = "02_Mafa_A1_SECOND"
        let attempted = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: first, sample: "AnimalA"
        )
        let styled = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: first, sample: "AnimalB"
        )
        let reviewed = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: second, sample: "AnimalA"
        )
        let commented = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: second, sample: "AnimalB"
        )
        let calls = [
            makeCall(sample: "AnimalA", genotype: first, reads: 12),
            makeCall(sample: "AnimalB", genotype: first, reads: 8),
            makeCall(sample: "AnimalA", genotype: second, reads: 10),
            makeCall(sample: "AnimalB", genotype: second, reads: 9),
        ]
        let scheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixWorkbookUpdateScheduler = scheduler
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls
        ))

        let concurrent = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "other")
        try concurrent.setMatrixStyle(
            target: styled,
            style: .init(fillColor: "#FFEEDD")
        )
        try concurrent.setMatrixReviewSynchronously(
            .falsePositive,
            targets: [reviewed],
            evidence: GenotypeMatrixEvidenceIndex([reviewed: 10]),
            author: "other"
        )
        try concurrent.upsertMatrixCommentSynchronously(
            body: "concurrent",
            targets: [commented],
            author: "other"
        )
        var surfacedError: Error?
        var rehydratedSidecar: GenotypeAnnotationSidecar?
        controller.onMatrixAnnotationCommandError = { surfacedError = $0 }
        controller.onAnnotationSidecarChanged = { rehydratedSidecar = $0 }
        controller.testingResetMatrixReloadCounters()

        controller.editMatrixComment(.init(
            targets: [attempted],
            intent: .upsert(body: "stale")
        ))

        XCTAssertTrue(
            surfacedError?.localizedDescription.contains("changed in another process") == true
        )
        XCTAssertEqual(
            Set(controller.testingLastMatrixReloadTargets),
            Set([styled, reviewed, commented])
        )
        XCTAssertEqual(controller.testingMatrixPartialReloadCount, 2)
        XCTAssertEqual(controller.testingMatrixPartialReloadedCellCount, 3)
        XCTAssertEqual(rehydratedSidecar?.matrixStyles.map(\.target), [styled])
        XCTAssertEqual(rehydratedSidecar?.matrixReviews.map(\.target), [reviewed])
        XCTAssertEqual(rehydratedSidecar?.resolvedMatrixComments[commented]?.body, "concurrent")
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }


    func testStalePublicationReappliesActiveSearchAfterReloadingConcurrentComment() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixStaleSearchComment")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_INTERNAL"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let matchingTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: call.locusGroup,
            genotype: genotype
        )
        let staleAttemptTarget = GenotypeAnnotationSidecar.MatrixTarget.column(
            sample: "AnimalA"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call]
        ))
        controller.testingResetSearchPerformanceCounters()
        controller.testingSetQuickFilterSearchText("concurrent-search-note")
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 1)
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)

        let concurrent = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "other")
        try concurrent.upsertMatrixCommentSynchronously(
            body: "concurrent-search-note",
            targets: [matchingTarget],
            author: "other"
        )
        var surfacedError: Error?
        controller.onMatrixAnnotationCommandError = { surfacedError = $0 }

        controller.editMatrixComment(.init(
            targets: [staleAttemptTarget],
            intent: .upsert(body: "stale attempt")
        ))

        XCTAssertTrue(
            surfacedError?.localizedDescription.contains("changed in another process") == true
        )
        XCTAssertEqual(controller.testingQuickSearchText, "concurrent-search-note")
        XCTAssertEqual(controller.testingSearchIndexBuildCount, 2)
        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])
    }


    func testStaleAnnotationFailureReconcilesCandidateDisplayOnlySidecarChangeIntoMatrix() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixStaleCandidateDisplay")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [
                makeCandidate(
                    id: "candidate",
                    name: "Candidate_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "candidate",
                    sample: "AnimalA",
                    reads: 5
                ),
            ]
        ))
        XCTAssertEqual(Set(controller.testingVisibleMatrixGenotypes), ["Known", "Candidate_nov"])

        let concurrent = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "other")
        var latestSettings = concurrent.sidecar.settings.mhcCandidateDisplay
        latestSettings.showKnown = false
        try concurrent.updateMHCCandidateDisplaySettings(latestSettings)
        var surfacedError: Error?
        controller.onMatrixAnnotationCommandError = { surfacedError = $0 }
        controller.testingResetMatrixReloadCounters()

        controller.editMatrixComment(.init(
            targets: [.column(sample: "AnimalA")],
            intent: .upsert(body: "stale")
        ))

        XCTAssertTrue(
            surfacedError?.localizedDescription.contains("changed in another process") == true
        )
        XCTAssertFalse(
            try XCTUnwrap(controller.testingDisplayState.mhcCandidateDisplaySettings).showKnown
        )
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, ["Candidate_nov"])
        XCTAssertEqual(controller.testingLastMatrixReloadTargets, [])
    }


    func testSemanticPublicationReloadsMultipleIsolatedCellsWithoutCartesianExpansion() throws {
        let root = try TestTempDirectory.make(prefix: "MatrixExactPartialReload")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_FIRST"
        let second = "02_Mafa_A1_SECOND"
        let firstA = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondB = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        let firstTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: first, sample: "AnimalA"
        )
        let secondTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A", genotype: second, sample: "AnimalB"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [firstA, secondB]
        ))
        controller.testingResetMatrixReloadCounters()

        controller.editMatrixComment(.init(
            targets: [firstTarget, secondTarget],
            intent: .replace(body: "exact")
        ))

        XCTAssertEqual(
            Set(controller.testingLastMatrixReloadTargets),
            Set([firstTarget, secondTarget])
        )
        XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
        XCTAssertEqual(controller.testingMatrixPartialReloadCount, 2)
        XCTAssertEqual(controller.testingMatrixPartialReloadedCellCount, 2)
    }


    func testMatrixEditsCaptureCurrentAuthorProviderAfterSingleConfigure() throws {
        let root = try TestTempDirectory.make(prefix: "GenotypeEditAuthorProvider")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var author = "First analyst"
        let controller = GenotypeResultViewController()
        controller.annotationAuthorProvider = { author }
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 8)]
        ))
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "AnimalA"
        )

        controller.applyMatrixStyle(.init(targets: [target], field: .isBold(true)))
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let styleProvenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(styleProvenance.options.resolvedDefaults["author"], .string("First analyst"))
        author = "Second analyst"
        controller.addMatrixComment(.init(targets: [target], body: "Reviewed after handoff"))

        let persisted = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        let commentProvenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(persisted.matrixStyles.first?.author, "First analyst")
        XCTAssertEqual(persisted.matrixComments.first?.author, "Second analyst")
        XCTAssertEqual(commentProvenance.options.resolvedDefaults["author"], .string("Second analyst"))
        XCTAssertEqual(
            persisted.auditLog.filter { $0.action == "setMatrixStyle" || $0.action == "upsertMatrixComment" }.map(\.author),
            ["First analyst", "Second analyst"]
        )
    }

}
