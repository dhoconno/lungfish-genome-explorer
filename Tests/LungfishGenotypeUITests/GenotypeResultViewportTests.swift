import XCTest
import AppKit
import CryptoKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

@MainActor
private final class MatrixWorkbookUpdateSchedulerSpy: GenotypeMatrixWorkbookUpdateScheduling {
    private final class Token: GenotypeMatrixWorkbookUpdateCancellation {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private var entries: [(token: Token, action: @MainActor () -> Void)] = []

    var scheduledCount: Int {
        entries.count
    }

    func schedule(_ action: @escaping @MainActor () -> Void) -> GenotypeMatrixWorkbookUpdateCancellation {
        let token = Token()
        entries.append((token, action))
        return token
    }

    func fireScheduledActions() {
        let pending = entries
        entries.removeAll()
        for entry in pending where !entry.token.isCancelled {
            entry.action()
        }
    }
}

@MainActor
final class GenotypeResultViewportTests: XCTestCase {
    func testMatrixReviewCapabilityUsesRawEvidenceIndependentOfFiltersAndDisplayThresholds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixRawEvidenceFilters-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        controller.testingShowMatrixTargetSelection([target])
        let unfiltered = controller.testingMatrixReviewCapability
        let evidenceBuildCount = controller.testingMatrixEvidenceIndexBuildCount

        var state = controller.testingDisplayState
        state.hideLowSupport = true
        state.minimumSupportPercent = 100
        state.matrixMinimumReads = 100
        state.matrixMinimumPercent = 100
        state.matrixRowFilterText = "does-not-match"
        state.matrixSampleFilterText = "hidden-sample"
        controller.testingApplyDisplayState(state)

        XCTAssertEqual(unfiltered.falsePositive, .enabled)
        XCTAssertEqual(controller.testingMatrixReviewCapability.falsePositive, .enabled)
        XCTAssertEqual(controller.testingMatrixEvidenceIndexBuildCount, evidenceBuildCount)
    }

    func testMatrixReviewCapabilityTreatsAbsentExactRecordAsFalseNegativeEligible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixAbsentEvidence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_EXPECTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalB"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))

        controller.testingShowMatrixTargetSelection([target])

        XCTAssertEqual(controller.testingMatrixReviewCapability.falseNegative, .enabled)
        XCTAssertEqual(controller.testingMatrixReviewCapability.support.unsupportedCount, 1)
    }

    func testMatrixReviewCapabilityUsesFullStableCandidateIdentityAndRejectsMixedSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixCandidateEvidenceIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let supported = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Collision_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-supported"
        )
        let absent = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Collision_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-absent"
        )
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-supported", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
                makeCandidate(id: "cluster-absent", name: "Collision_nov", classification: .novel, support: .singleton, samples: []),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-supported", sample: "AnimalA", reads: 5),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingShowMatrixTargetSelection([supported])
        XCTAssertEqual(controller.testingMatrixReviewCapability.falsePositive, .enabled)
        controller.testingShowMatrixTargetSelection([absent])
        XCTAssertEqual(controller.testingMatrixReviewCapability.falseNegative, .enabled)
        controller.testingShowMatrixTargetSelection([supported, absent])

        XCTAssertFalse(controller.testingMatrixReviewCapability.falsePositive.isEnabled)
        XCTAssertFalse(controller.testingMatrixReviewCapability.falseNegative.isEnabled)
        XCTAssertEqual(controller.testingMatrixReviewCapability.support.supportedCount, 1)
        XCTAssertEqual(controller.testingMatrixReviewCapability.support.unsupportedCount, 1)
    }

    func testInspectorAndMatrixConsumeSameCapabilitySnapshotWithoutRebuildingIndexesOnSelection() {
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let controller = GenotypeResultViewController()
        controller.onMatrixReviewCapabilityChanged = { viewModel.updateMatrixReviewCapability($0) }
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        let evidenceBuildCount = controller.testingMatrixEvidenceIndexBuildCount
        let annotationBuildCount = controller.testingMatrixAnnotationIndexBuildCount

        controller.testingShowMatrixTargetSelection([target])

        XCTAssertEqual(viewModel.matrixReviewCapability, controller.testingMatrixReviewCapability)
        XCTAssertEqual(
            controller.testingComparisonMatrixReviewCapability,
            controller.testingMatrixReviewCapability
        )
        XCTAssertEqual(controller.testingMatrixEvidenceIndexBuildCount, evidenceBuildCount)
        XCTAssertEqual(controller.testingMatrixAnnotationIndexBuildCount, annotationBuildCount)
    }

    func testReviewRequestIsRevalidatedAgainstCurrentRawEvidenceBeforeStorePublication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixReviewRevalidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let request = GenotypeMatrixReviewRequest(
            targets: [target],
            intent: .set(.falsePositive)
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))
        controller.testingShowMatrixTargetSelection([target])
        XCTAssertEqual(controller.testingMatrixReviewCapability.falsePositive, .enabled)

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: []
        ))
        let annotationBuildCount = controller.testingMatrixAnnotationIndexBuildCount
        var surfacedError: Error?
        controller.onMatrixAnnotationCommandError = { surfacedError = $0 }
        controller.applyMatrixReview(request)

        XCTAssertEqual(
            surfacedError as? GenotypeMatrixReviewMutationError,
            .ineligibleEvidence
        )
        XCTAssertTrue(
            try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
                .matrixReviews.isEmpty
        )
        XCTAssertEqual(controller.testingMatrixAnnotationIndexBuildCount, annotationBuildCount)
    }

    func testSemanticCommentRequestsUpsertReplaceAndRemoveExactTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixCommentIntents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let second = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalB")
        let visibleCall = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_VISIBLE",
            reads: 5
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 5,
                passedUniqueReads: 5,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [visibleCall]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [visibleCall]))
        controller.testingResetMatrixReloadCounters()

        controller.editMatrixComment(.init(targets: [first], intent: .upsert(body: "first")))
        controller.editMatrixComment(.init(targets: [first], intent: .upsert(body: "edited")))
        controller.editMatrixComment(.init(
            targets: [first, second],
            intent: .replace(body: "bulk replacement")
        ))
        var sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        XCTAssertEqual(sidecar.matrixComments.count, 2)
        XCTAssertEqual(Set(sidecar.matrixComments.map(\.body)), ["bulk replacement"])

        controller.editMatrixComment(.init(targets: [first], intent: .remove))
        sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        XCTAssertEqual(sidecar.matrixComments.map(\.target), [second])
        XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
        XCTAssertGreaterThan(controller.testingMatrixPartialReloadCount, 0)
    }

    func testSuccessfulMatrixAnnotationBurstCoalescesOneDelayedWorkbookUpdate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixWorkbookCoalesce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SUPPORTED"
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: genotype,
            sample: "AnimalA"
        )
        let scheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixWorkbookUpdateScheduler = scheduler
        var workbookUpdateCount = 0
        controller.onCurrentWorkbookUpdateRequested = { _, _, _ in workbookUpdateCount += 1 }
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 9)]
        ))

        controller.applyMatrixReview(.init(targets: [target], intent: .set(.falsePositive)))
        controller.editMatrixComment(.init(targets: [target], intent: .upsert(body: "reviewed")))

        XCTAssertEqual(scheduler.scheduledCount, 2)
        XCTAssertEqual(workbookUpdateCount, 0)
        scheduler.fireScheduledActions()
        XCTAssertEqual(workbookUpdateCount, 1)
    }

    func testFailedSidecarPublicationSchedulesNoWorkbookUpdate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixWorkbookPublicationFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixStaleExactUnion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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

    func testSemanticPublicationReloadsMultipleIsolatedCellsWithoutCartesianExpansion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixExactPartialReload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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

    func testWorkbookUpdateFailurePreservesPublishedSidecarAndExposesRetryWarning() throws {
        struct WorkbookFailure: Error {}

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixWorkbookRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let scheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixWorkbookUpdateScheduler = scheduler
        controller.onCurrentWorkbookUpdateRequested = { _, _, _ in }
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: []))
        controller.editMatrixComment(.init(targets: [target], intent: .upsert(body: "durable")))
        scheduler.fireScheduledActions()
        let published = try Data(contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        controller.applyCurrentWorkbookUpdateFailed(WorkbookFailure())

        XCTAssertEqual(
            try Data(contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)),
            published
        )
        XCTAssertTrue(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertTrue(controller.testingCurrentWorkbookUpdateStatus?.contains("retry") == true)
    }

    func testWorkbookFailureAfterRemovingFinalAnnotationLeavesEnabledRetryThatInvokesUpdate() throws {
        struct WorkbookFailure: Error {}

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatrixWorkbookFinalRemovalRetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        let scheduler = MatrixWorkbookUpdateSchedulerSpy()
        let controller = GenotypeResultViewController()
        controller.matrixWorkbookUpdateScheduler = scheduler
        var workbookUpdateCount = 0
        controller.onCurrentWorkbookUpdateRequested = { _, _, _ in workbookUpdateCount += 1 }
        _ = controller.view
        let result = makeResult(bundleURL: bundleURL, samples: [], calls: [])
        controller.configure(result: result)

        controller.editMatrixComment(.init(
            targets: [target],
            intent: .upsert(body: "temporary")
        ))
        scheduler.fireScheduledActions()
        XCTAssertEqual(workbookUpdateCount, 1)
        controller.applyCurrentWorkbookUpdateCompleted(result: result)

        controller.editMatrixComment(.init(targets: [target], intent: .remove))
        scheduler.fireScheduledActions()
        XCTAssertEqual(workbookUpdateCount, 2)
        controller.applyCurrentWorkbookUpdateFailed(WorkbookFailure())

        XCTAssertTrue(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertTrue(controller.testingCurrentWorkbookUpdateButtonEnabled)
        controller.testingRequestCurrentWorkbookUpdate()
        XCTAssertEqual(workbookUpdateCount, 3)
    }

    func testMatrixEditsCaptureCurrentAuthorProviderAfterSingleConfigure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeEditAuthorProvider-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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

    func testFullLengthMHCSequenceDetailIsEmptyUntilAlleleRowSelection() throws {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")

        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")

        controller.testingSelectMatrixCell(genotype: "known-a", sample: "AnimalA")
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
    }

    func testFullLengthMHCKnownRowShowsExactRecordAndFormatToggles() {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))

        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)

        XCTAssertEqual(controller.testingAlleleSequenceFormat, .genBank)
        XCTAssertEqual(controller.testingAlleleSequenceText, known.genBankText)
        controller.testingSelectAlleleSequenceFormat(.fasta)
        XCTAssertEqual(controller.testingAlleleSequenceText, known.fastaText)
        controller.testingSelectAlleleSequenceFormat(.embl)
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("AC   known-a;"))
    }

    func testFullLengthMHCSupportedCellHelperClearsSelectedRowSequenceForCellsAndNoMatches() {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))
        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)
        XCTAssertFalse(controller.testingAlleleSequenceText.isEmpty)

        XCTAssertEqual(controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 1).count, 1)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")

        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)
        XCTAssertFalse(controller.testingAlleleSequenceText.isEmpty)
        XCTAssertTrue(controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 100).isEmpty)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
    }

    func testFullLengthMHCCellAndColumnSelectionsNeverBuildLegacyDetailHierarchy() {
        let call = makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [.init(
                sample: "AnimalA",
                passedAlignments: 10,
                passedUniqueReads: 10,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            )],
            calls: [call],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(
                    rawReferenceID: "known-a",
                    alleleName: "Mafa-A1*001:01"
                )]
            )
        ))

        for _ in 0..<50 {
            controller.testingSelectMatrixCell(genotype: "known-a", sample: "AnimalA")
            controller.testingSelectMatrixColumn(sample: "AnimalA")
        }

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingLegacyNonRowDetailBuildCount, 0)
        XCTAssertEqual(controller.testingKnownAlleleDetailMountCount, 0)
        XCTAssertEqual(controller.testingCandidateAlleleDetailMountCount, 0)
        XCTAssertFalse(controller.testingCurrentSelectionMatrixTargets.isEmpty)
    }

    func testFullLengthMHCKnownSequenceRecordsAreFormattedOnlyDuringConfigure() {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))
        XCTAssertEqual(controller.testingKnownAlleleSequenceRecordBuildCount, 1)
        XCTAssertEqual(controller.testingKnownAlleleSequenceCacheCount, 1)

        for _ in 0..<50 {
            controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)
        }

        XCTAssertEqual(controller.testingKnownAlleleSequenceRecordBuildCount, 1)
        XCTAssertEqual(controller.testingKnownAlleleSequenceCacheCount, 1)
        XCTAssertEqual(controller.testingAlleleSequenceText, known.genBankText)
    }

    func testFullLengthMHCCandidateRowUsesExactCandidateArtifactNotClosestReference() throws {
        let fixture = try makeSequenceDetailCandidateResult()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)

        controller.testingSelectCandidateRow(stableClusterID: "candidate-stable")

        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, ["candidate-stable"])
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("ACCESSION   candidate-accession"))
        XCTAssertFalse(controller.testingAlleleSequenceText.contains("closest-reference"))
        controller.testingSelectAlleleSequenceFormat(.fasta)
        XCTAssertEqual(
            controller.testingAlleleSequenceText,
            ">candidate-accession Mafa-A1*001:01_1nt_nov\nACGTACGT\n"
        )
        controller.testingSelectAlleleSequenceFormat(.embl)
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("AC   candidate-accession;"))
    }

    func testFullLengthMHCCandidateCatalogKeepsValidRecordWhenAnotherChecksumIsInvalid() throws {
        let fixture = try makeSequenceDetailCandidateResult(includeInvalidCandidate: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)

        controller.testingSelectCandidateRow(stableClusterID: "candidate-stable")

        XCTAssertTrue(controller.testingAlleleSequenceText.contains(
            "ACCESSION   candidate-accession"
        ))
        XCTAssertFalse(controller.testingAlleleSequenceText.contains(
            "Validated allele record unavailable"
        ))

        controller.testingSelectCandidateRow(stableClusterID: "candidate-invalid")

        XCTAssertEqual(
            controller.testingAlleleSequenceRecordIdentities,
            ["candidate-invalid"]
        )
        XCTAssertTrue(controller.testingAlleleSequenceText.contains(
            "Validated allele record unavailable"
        ))
    }

    func testFullLengthMHCUnresolvedSelectionReplacesPriorRecordWithUnavailableRecord() {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "known-a", reads: 10),
                makeCall(sample: "AnimalA", genotype: "missing", reads: 9),
            ],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))
        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)

        controller.testingSelectMatrixRows(genotypes: ["missing"], sample: nil)

        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, ["missing"])
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("Validated allele record unavailable"))
        XCTAssertFalse(controller.testingAlleleSequenceText.contains("known-a"))
    }

    func testReconfigureToCandidateOnlyFullLengthResultClearsPriorSequenceDetail() throws {
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*001:01"
        )
        let candidateFixture = try makeSequenceDetailCandidateResult()
        defer { try? FileManager.default.removeItem(at: candidateFixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-a", reads: 10)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(schemaVersion: 1, records: [known])
        ))
        controller.testingSelectMatrixRows(genotypes: ["known-a"], sample: nil)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)

        controller.configure(result: candidateFixture.result)

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
        XCTAssertTrue(controller.testingAlleleSequenceRecordIdentities.isEmpty)
    }

    func testMatrixOrdersArbitraryRowTargetsByVisibleRowsAndKeepsDuplicateCandidateLabels() {
        let candidates = [
            makeCandidate(id: "cluster-b", name: "Same_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "cluster-a", name: "Same_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 10)],
            candidates: candidates,
            observations: candidates.map {
                makeCandidateObservation(cluster: $0.stableClusterID, sample: "AnimalA", reads: 5)
            }
        ))
        let input: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .row(locus: "MHC-A1", genotype: "Same_nov", stableClusterID: "cluster-b"),
            .column(sample: "AnimalA"),
            .row(locus: "MHC-KNOWN", genotype: "Known"),
            .cell(locus: "MHC-A1", genotype: "Same_nov", sample: "AnimalA", stableClusterID: "cluster-a"),
            .row(locus: "MHC-A1", genotype: "Same_nov", stableClusterID: "cluster-a"),
        ]

        XCTAssertEqual(
            matrix.orderedVisibleRowTargets(from: input),
            matrix.testingVisibleRows.map {
                .row(
                    locus: $0.locus,
                    genotype: $0.genotype,
                    stableClusterID: $0.stableClusterID
                )
            }
        )
    }

    func testFullLengthMHCMixedRowsUseViewportOrderPersistFormatAndKeepOneSequenceHierarchy() throws {
        let fixture = try makeSequenceDetailCandidateResult(includeKnown: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: fixture.result)
        try FileManager.default.removeItem(
            at: fixture.result.mhcCandidateGenBankArtifactURLs.candidateAlleles!
        )
        let unordered: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .row(
                locus: "MHC-A1",
                genotype: "Mafa-A1*001:01_1nt_nov",
                stableClusterID: "candidate-stable"
            ),
            .row(
                locus: try XCTUnwrap(
                    fixture.result.locusSummaries
                        .flatMap(\.sharedCalls)
                        .first { $0.genotype == "known-a" }?
                        .locus
                ),
                genotype: "known-a"
            ),
        ]

        controller.testingShowMatrixTargetSelection(unordered)

        XCTAssertEqual(
            controller.testingAlleleSequenceRecordIdentities,
            ["known-a", "candidate-stable"]
        )
        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)
        let knownRange = try XCTUnwrap(controller.testingAlleleSequenceText.range(of: "known-a"))
        let candidateRange = try XCTUnwrap(
            controller.testingAlleleSequenceText.range(of: "candidate-accession")
        )
        XCTAssertLessThan(knownRange.lowerBound, candidateRange.lowerBound)
        controller.testingSelectAlleleSequenceFormat(.fasta)
        let baselineSubviewCount = descendants(of: controller.view).count
        for _ in 0..<50 {
            controller.testingShowMatrixTargetSelection(Array(unordered.reversed()))
            XCTAssertEqual(controller.testingAlleleSequenceFormat, .fasta)
        }
        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)
        XCTAssertEqual(descendants(of: controller.view).count, baselineSubviewCount)
        XCTAssertTrue(knownAlleleDetails(in: controller.view).isEmpty)
        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)

        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "known-b", reads: 4)],
            kind: "full-length-ont-mhc-genotype",
            mhcReferenceVisualizations: .init(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(
                    rawReferenceID: "known-b",
                    alleleName: "Mafa-B*001:01"
                )]
            )
        ))

        XCTAssertEqual(controller.testingAlleleSequenceFormat, .genBank)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
    }

    func testFullLengthMHCRowsUseSpeciesAgnosticBiologicalAlleleOrder() throws {
        let alleleFieldKey = "feature.allele"
        let knownAlleles = [
            "raw-k": "Mamu-K*001:01",
            "raw-a2": "Mamu-A2*001:01",
            "raw-ag": "Mamu-AG*001:01",
            "raw-b": "Mamu-B*001:01",
            "raw-f": "Mamu-F*001:01",
        ]
        let candidateNames = [
            "cluster-other": "Mamu-E*001:01_nov",
            "cluster-g-z": "Mamu-G*009:01_nov",
            "cluster-b16": "Mamu-B16*001:01_nov",
            "cluster-a1": "Mamu-A1*001:01_nov",
            "cluster-i": "Mamu-I*001:01_nov",
            "cluster-g-a": "Mamu-G*009:01_nov",
            "cluster-j": "Mamu-J*001:01_nov",
            "cluster-b02ps": "Mamu-B02ps*001:01_nov",
        ]
        let calls = ["raw-k", "raw-a2", "raw-ag", "raw-b", "raw-f"].map {
            makeCall(sample: "AnimalA", genotype: $0, reads: 10)
        }
        let candidates = [
            "cluster-other", "cluster-g-z", "cluster-b16", "cluster-a1",
            "cluster-i", "cluster-g-a", "cluster-j", "cluster-b02ps",
        ].map { id in
            makeCandidate(
                id: id,
                name: candidateNames[id]!,
                classification: .novel,
                support: .singleton,
                samples: ["AnimalA"]
            )
        }
        let observations = candidates.map {
            makeCandidateObservation(cluster: $0.stableClusterID, sample: "AnimalA", reads: 5)
        }
        let metadata = ONTGenotypeReferenceMetadata(
            fields: [GenBankRecordDatabase.FieldDefinition(
                key: alleleFieldKey,
                displayTitle: "Allele",
                valueType: "text",
                sourceCategory: "feature",
                preferredOrder: 0
            )],
            recordsBySequenceName: knownAlleles.mapValues { [alleleFieldKey: $0] },
            alleleFieldKey: alleleFieldKey
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeCandidateResult(
            calls: calls,
            candidates: candidates,
            observations: observations,
            referenceMetadata: metadata
        ))
        let expected = [
            candidateNames["cluster-a1"]!,
            "raw-a2",
            "raw-b",
            candidateNames["cluster-b02ps"]!,
            candidateNames["cluster-b16"]!,
            candidateNames["cluster-i"]!,
            "raw-f",
            candidateNames["cluster-g-a"]!,
            candidateNames["cluster-g-z"]!,
            "raw-ag",
            candidateNames["cluster-j"]!,
            "raw-k",
            candidateNames["cluster-other"]!,
        ]
        let expectedIdentities = [
            "\(candidateNames["cluster-a1"]!)|cluster-a1",
            "raw-a2|known",
            "raw-b|known",
            "\(candidateNames["cluster-b02ps"]!)|cluster-b02ps",
            "\(candidateNames["cluster-b16"]!)|cluster-b16",
            "\(candidateNames["cluster-i"]!)|cluster-i",
            "raw-f|known",
            "\(candidateNames["cluster-g-a"]!)|cluster-g-a",
            "\(candidateNames["cluster-g-z"]!)|cluster-g-z",
            "raw-ag|known",
            "\(candidateNames["cluster-j"]!)|cluster-j",
            "raw-k|known",
            "\(candidateNames["cluster-other"]!)|cluster-other",
        ]
        let visibleIdentities = {
            matrix.testingVisibleRows.map {
                "\($0.alleleName)|\($0.stableClusterID ?? "known")"
            }
        }

        XCTAssertEqual(matrix.testingVisibleGenotypes, expected)
        XCTAssertEqual(visibleIdentities(), expectedIdentities)
        let alleleSortKey = try XCTUnwrap(matrix.testingActiveSortDescriptorKey)
        XCTAssertEqual(alleleSortKey, "reference.\(alleleFieldKey)")

        matrix.testingSetSortDescriptor(key: alleleSortKey, ascending: true)
        XCTAssertEqual(matrix.testingVisibleGenotypes, expected)
        XCTAssertEqual(visibleIdentities(), expectedIdentities)

        matrix.testingSetSortDescriptor(key: alleleSortKey, ascending: false)
        XCTAssertEqual(matrix.testingVisibleGenotypes, expected.reversed())
        XCTAssertEqual(visibleIdentities(), expectedIdentities.reversed())
    }

    func testFullLengthMHCFASTAProjectionUsesBiologicalAlleleOrderAndStableCandidateTies() throws {
        let candidates = [
            makeCandidate(id: "cluster-other", name: "Mamu-E*001:01_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "cluster-g-z", name: "Mamu-G*009:01_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "cluster-a1", name: "Mamu-A1*001:01_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "cluster-g-a", name: "Mamu-G*009:01_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
        ]
        let result = makeCandidateResult(
            calls: [
                makeCall(sample: "AnimalA", genotype: "Mamu-K*001:01", reads: 10),
                makeCall(sample: "AnimalA", genotype: "Mamu-B*001:01", reads: 10),
                makeCall(sample: "AnimalA", genotype: "Mamu-A2*001:01", reads: 10),
            ],
            candidates: candidates,
            observations: candidates.map {
                makeCandidateObservation(cluster: $0.stableClusterID, sample: "AnimalA", reads: 5)
            }
        )
        let expectedIdentities = [
            "Mamu-A1*001:01_nov|cluster-a1",
            "Mamu-A2*001:01|known",
            "Mamu-B*001:01|known",
            "Mamu-G*009:01_nov|cluster-g-a",
            "Mamu-G*009:01_nov|cluster-g-z",
            "Mamu-K*001:01|known",
            "Mamu-E*001:01_nov|cluster-other",
        ]
        let projectedRows = GenotypeCandidateMatrixProjection.rows(
            knownRows: result.locusSummaries.flatMap(\.sharedCalls),
            candidateDocument: try XCTUnwrap(result.mhcCandidates),
            settings: .default,
            usesBiologicalAlleleOrder: true
        )

        XCTAssertEqual(projectedRows.map {
            "\($0.alleleName)|\($0.stableClusterID ?? "known")"
        }, expectedIdentities)

        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)
        XCTAssertEqual(matrix.testingActiveSortDescriptorKey, "genotype")
        XCTAssertEqual(matrix.testingVisibleRows.map {
            "\($0.alleleName)|\($0.stableClusterID ?? "known")"
        }, expectedIdentities)
    }

    func testNonFullLengthGenotypeAndAlleleSortsKeepLocalizedStandardOrder() throws {
        let expectedGenotypes = ["Mamu-E*001:01", "Mamu-K*001:01"]
        let fastaMatrix = GenotypeComparisonMatrixView()
        fastaMatrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: expectedGenotypes[1], reads: 10),
                makeCall(sample: "AnimalA", genotype: expectedGenotypes[0], reads: 10),
            ]
        ))

        XCTAssertEqual(fastaMatrix.testingVisibleGenotypes, expectedGenotypes)
        let genotypeSortKey = try XCTUnwrap(fastaMatrix.testingActiveSortDescriptorKey)
        XCTAssertEqual(genotypeSortKey, "genotype")
        fastaMatrix.testingSetSortDescriptor(key: genotypeSortKey, ascending: true)
        XCTAssertEqual(fastaMatrix.testingVisibleGenotypes, expectedGenotypes)

        let alleleFieldKey = "feature.allele"
        let genBankMatrix = GenotypeComparisonMatrixView()
        genBankMatrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "raw-k", reads: 10),
                makeCall(sample: "AnimalA", genotype: "raw-e", reads: 10),
            ],
            referenceMetadata: ONTGenotypeReferenceMetadata(
                fields: [GenBankRecordDatabase.FieldDefinition(
                    key: alleleFieldKey,
                    displayTitle: "Allele",
                    valueType: "text",
                    sourceCategory: "feature",
                    preferredOrder: 0
                )],
                recordsBySequenceName: [
                    "raw-k": [alleleFieldKey: expectedGenotypes[1]],
                    "raw-e": [alleleFieldKey: expectedGenotypes[0]],
                ],
                alleleFieldKey: alleleFieldKey
            )
        ))

        XCTAssertEqual(genBankMatrix.testingVisibleGenotypes, ["raw-e", "raw-k"])
        let alleleSortKey = try XCTUnwrap(genBankMatrix.testingActiveSortDescriptorKey)
        XCTAssertEqual(alleleSortKey, "reference.\(alleleFieldKey)")
        genBankMatrix.testingSetSortDescriptor(key: alleleSortKey, ascending: true)
        XCTAssertEqual(genBankMatrix.testingVisibleGenotypes, ["raw-e", "raw-k"])
    }

    func testFullLengthCandidateControlsExposeExactLabelsDefaultsAndIndependentTintReset() throws {
        let viewModel = GenotypeResultDisplaySectionViewModel()
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 3)],
            candidates: [
                makeCandidate(id: "shared", name: "Shared_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "single", name: "Single_ext", classification: .extension, support: .singleton, samples: ["AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "shared", sample: "AnimalA", reads: 2),
                makeCandidateObservation(cluster: "shared", sample: "AnimalB", reads: 4),
                makeCandidateObservation(cluster: "single", sample: "AnimalB", reads: 6),
            ]
        )

        viewModel.updateMHCCandidatePresentation(from: result)

        XCTAssertTrue(viewModel.mhcCandidateControlsAvailable)
        XCTAssertEqual(GenotypeCandidateEvidenceSection.visibilityLabels, [
            "Known",
            "Shared candidates (2+ samples)",
            "Singleton candidates (1 sample)",
        ])
        XCTAssertEqual(GenotypeCandidateEvidenceSection.tintLabels, [
            "Shared novel",
            "Singleton novel",
            "Shared extension",
            "Singleton extension",
        ])
        XCTAssertEqual(viewModel.mhcCandidateDisplaySettings, .default)

        let replacement = AnnotationColor(red: 0.12, green: 0.34, blue: 0.56, alpha: 0.78)
        viewModel.setMHCCandidateTint(replacement, category: .sharedNovel)
        XCTAssertEqual(viewModel.mhcCandidateDisplaySettings.tints[.sharedNovel], replacement)
        XCTAssertEqual(
            viewModel.mhcCandidateDisplaySettings.tints[.singletonNovel],
            ONTMHCCandidateDisplaySettings.defaultTints[.singletonNovel]
        )

        viewModel.resetMHCCandidateTint(.sharedNovel)
        XCTAssertEqual(viewModel.mhcCandidateDisplaySettings.tints, ONTMHCCandidateDisplaySettings.defaultTints)
    }

    func testCompactSchemaTwoCandidateDocumentEnablesRowsAndUnavailableSequenceDetail() throws {
        let stableClusterID = "compact-candidate"
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 3)],
            candidates: [
                makeCandidate(
                    id: stableClusterID,
                    name: "Mafa-A1*001:01_1nt_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                ONTMHCCandidateObservation(
                    stableClusterID: stableClusterID,
                    sampleID: "AnimalA",
                    readGroupID: "AnimalA",
                    sourceClusterIDs: ["source-compact"],
                    sourceClusterReadCounts: ["source-compact": 7],
                    aggregatedSampleReadCount: 7,
                    genotypingHitSummaries: [try ONTMHCGenotypingTargetHitSummary(
                        bamPath: "artifacts/alignments/genotyping-evidence.bam",
                        targetName: "AnimalA|source-compact",
                        alignmentCount: 7,
                        queryAlignmentCounts: ["compact-reference": 7],
                        exactMatchQueryNames: [],
                        closestMatchQueryNames: ["compact-reference"]
                    )]
                ),
            ],
            candidateSequences: [stableClusterID: String(repeating: "A", count: 24)],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeCandidateReferenceVisualizationRecord(
                    rawReferenceID: "compact-reference",
                    alleleName: "Mafa-A1*001:01",
                    stableClusterID: stableClusterID
                )]
            ),
            candidateDocumentSchemaVersion: 2
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: result)
        XCTAssertTrue(viewModel.mhcCandidateControlsAvailable)

        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.stableClusterID == stableClusterID })

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateRow(stableClusterID: stableClusterID)
        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, [stableClusterID])
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("Validated allele record unavailable"))
        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.first {
                $0.0 == "Genotyping Evidence"
            }?.1,
            "7 alignments in indexed BAM"
        )
    }

    func testSchemaFourCanonicalCandidateRendersOnceWithAllObservationSupport() throws {
        let stableClusterID = "canonical-candidate"
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: stableClusterID,
                    name: "Mafa-A1*001:01_1nt_nov",
                    classification: .novel,
                    support: .shared,
                    samples: ["AnimalA", "AnimalB"]
                ),
            ],
            observations: [
                makeCandidateObservation(cluster: stableClusterID, sample: "AnimalA", reads: 7),
                makeCandidateObservation(cluster: stableClusterID, sample: "AnimalB", reads: 11),
            ],
            candidateDocumentSchemaVersion: 4,
            candidateArtifactManifestSchemaVersion: 2
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: result)
        XCTAssertTrue(viewModel.mhcCandidateControlsAvailable)

        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)
        let candidateRows = matrix.testingVisibleRows.filter {
            $0.stableClusterID == stableClusterID
        }
        XCTAssertEqual(candidateRows.count, 1)
        XCTAssertEqual(candidateRows[0].support(for: "AnimalA")?.passedUniqueReads, 7)
        XCTAssertEqual(candidateRows[0].support(for: "AnimalB")?.passedUniqueReads, 11)
    }

    func testLegacyAndInvalidCandidateBundlesDoNotExposeControlsAndInvalidWarningIsNonfatal() {
        let candidate = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let legacyBase = makeResult(samples: candidate.samples, calls: candidate.calls)
        let legacy = ONTGenotypeResultBundleData(
            bundleURL: legacyBase.bundleURL,
            manifest: legacyBase.manifest,
            artifacts: legacyBase.artifacts,
            stats: legacyBase.stats,
            calls: candidate.calls,
            samples: candidate.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            integrityWarnings: [],
            referenceMetadata: nil
        )
        let invalid = ONTGenotypeResultBundleData(
            bundleURL: candidate.bundleURL,
            manifest: candidate.manifest,
            artifacts: candidate.artifacts,
            stats: candidate.stats,
            calls: candidate.calls,
            samples: candidate.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            integrityWarnings: [.init(
                code: .candidateArtifactChecksumMismatch,
                detail: "candidate JSON checksum did not match",
                path: "artifacts/candidates/candidates.json"
            )],
            referenceMetadata: nil
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: legacy)
        XCTAssertFalse(viewModel.mhcCandidateControlsAvailable)
        XCTAssertTrue(viewModel.mhcCandidateIntegrityWarnings.isEmpty)

        viewModel.updateMHCCandidatePresentation(from: invalid)
        XCTAssertFalse(viewModel.mhcCandidateControlsAvailable)
        XCTAssertEqual(viewModel.mhcCandidateIntegrityWarnings.count, 1)
        XCTAssertTrue(viewModel.mhcCandidateIntegrityWarnings[0].contains("checksum"))

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: invalid)
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, ["Known"])
        XCTAssertTrue(controller.testingCandidateIntegrityWarningText.contains("checksum"))
    }

    func testNonFullLengthBundleDoesNotExposeCandidateWarningsOrEvidenceSection() {
        let candidate = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let nonFullLengthBase = makeResult(samples: candidate.samples, calls: candidate.calls)
        let nonFullLength = ONTGenotypeResultBundleData(
            bundleURL: nonFullLengthBase.bundleURL,
            manifest: nonFullLengthBase.manifest,
            artifacts: nonFullLengthBase.artifacts,
            stats: nonFullLengthBase.stats,
            calls: candidate.calls,
            samples: candidate.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: candidate.mhcCandidates,
            mhcUnnameableClusters: nil,
            integrityWarnings: [.init(
                code: .candidateArtifactChecksumMismatch,
                detail: "candidate JSON checksum did not match",
                path: "artifacts/candidates/candidates.json"
            )],
            referenceMetadata: nil
        )
        let viewModel = GenotypeResultDisplaySectionViewModel()

        viewModel.updateMHCCandidatePresentation(from: nonFullLength)

        XCTAssertFalse(viewModel.mhcCandidateControlsAvailable)
        XCTAssertTrue(viewModel.mhcCandidateIntegrityWarnings.isEmpty)
        XCTAssertNil(viewModel.mhcCandidatePersistenceWarning)

        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: nonFullLength)
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, ["Known"])
        XCTAssertEqual(controller.testingCandidateIntegrityWarningText, "")
    }

    func testCandidateRowsUseDistinctSamplePopulationFractionForGlobalThresholds() {
        let result = makeCandidateResult(
            calls: [
                makeCall(sample: "AnimalD", genotype: "01_Mafa_A1_KnownHigh", reads: 9),
                makeCall(sample: "AnimalD", genotype: "01_Mafa_A1_KnownLow", reads: 1),
            ],
            candidates: [
                makeCandidate(id: "shared", name: "Collision_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "singleton", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalC"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "shared", sample: "AnimalA", reads: 3),
                makeCandidateObservation(cluster: "shared", sample: "AnimalB", reads: 3),
                makeCandidateObservation(cluster: "singleton", sample: "AnimalC", reads: 3),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        XCTAssertEqual(matrix.testingSupportFraction(rowID: .candidate(stableClusterID: "shared"), sample: "AnimalA"), 0.5)
        XCTAssertEqual(matrix.testingSupportFraction(rowID: .candidate(stableClusterID: "singleton"), sample: "AnimalC"), 0.25)

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 25))
        XCTAssertEqual(Set(matrix.testingVisibleRows.map(\.id)), Set([
            .known(locus: "MHC-A", genotype: "01_Mafa_A1_KnownHigh"),
            .candidate(stableClusterID: "shared"),
            .candidate(stableClusterID: "singleton"),
        ]), "The singleton is exactly 1/4 of the eligible sample union and remains visible at threshold")

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 25.1))
        XCTAssertEqual(Set(matrix.testingVisibleRows.map(\.id)), Set([
            .known(locus: "MHC-A", genotype: "01_Mafa_A1_KnownHigh"),
            .candidate(stableClusterID: "shared"),
        ]), "Stable cluster IDs must keep same-named candidates from sharing threshold state")

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 50))
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.id == .candidate(stableClusterID: "shared") })

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 50.1))
        XCTAssertFalse(matrix.testingVisibleRows.contains { $0.population != .known })
        XCTAssertEqual(matrix.testingVisibleRows.map(\.genotype), ["01_Mafa_A1_KnownHigh"], "Candidate-only samples must not alter known read-share semantics")
    }

    func testCandidateRowsUsePopulationFractionForMatrixThresholdAndVisibilityDoesNotChangeDenominator() {
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalD", genotype: "01_Mafa_A1_Known", reads: 10)],
            candidates: [
                makeCandidate(id: "shared", name: "Shared_ext", classification: .extension, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "singleton", name: "Singleton_ext", classification: .extension, support: .singleton, samples: ["AnimalC"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "shared", sample: "AnimalA", reads: 3),
                makeCandidateObservation(cluster: "shared", sample: "AnimalB", reads: 3),
                makeCandidateObservation(cluster: "singleton", sample: "AnimalC", reads: 3),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        matrix.applyDisplayState(.init(matrixMinimumPercent: 25))
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.id == .candidate(stableClusterID: "singleton") })

        var settings = ONTMHCCandidateDisplaySettings.default
        settings.showSingletonCandidates = false
        matrix.applyDisplayState(.init(matrixMinimumPercent: 50, mhcCandidateDisplaySettings: settings))
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.id == .candidate(stableClusterID: "shared") })

        matrix.applyDisplayState(.init(matrixMinimumPercent: 50.1, mhcCandidateDisplaySettings: settings))
        XCTAssertFalse(matrix.testingVisibleRows.contains { $0.population != .known }, "Hidden singleton samples remain in the eligible matrix sample union")
        XCTAssertTrue(matrix.testingVisibleRows.contains { $0.id == .known(locus: "MHC-A", genotype: "01_Mafa_A1_Known") })
    }

    func testCandidatePopulationThresholdHandlesEmptyEligibleSampleUnion() {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "orphan", name: "Orphan_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: []
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        matrix.applyDisplayState(.init(hideLowSupport: true, minimumSupportPercent: 1))

        XCTAssertTrue(matrix.testingVisibleRows.isEmpty)
        XCTAssertNil(matrix.testingSupportFraction(rowID: .candidate(stableClusterID: "orphan"), sample: "AnimalA"))
    }

    func testCandidateSelectionUsesExclusiveCallbackAndCompleteStableEvidenceDetail() throws {
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [
                makeCandidate(id: "cluster-a", name: "Collision_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "cluster-b", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 11),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingSelectCandidateCell(stableClusterID: "cluster-b", sample: "AnimalA")

        XCTAssertEqual(controller.testingSelectedCandidateStableClusterID, "cluster-b")
        let details = Dictionary(uniqueKeysWithValues: controller.testingCurrentSelectionDetailRows)
        XCTAssertEqual(details["Stable Cluster ID"], "cluster-b")
        XCTAssertEqual(details["Provisional Name"], "Collision_nov")
        XCTAssertEqual(details["Classification"], "Novel")
        XCTAssertEqual(details["Support Class"], "Singleton (1 sample)")
        XCTAssertEqual(details["Independent Samples"], "1")
        XCTAssertEqual(details["Occurrence Count"], "1")
        XCTAssertEqual(details["Total Cluster Reads"], "5")
        XCTAssertEqual(details["Selected Sample"], "AnimalA")
        XCTAssertEqual(details["Selected Sample Reads"], "11")
        XCTAssertEqual(details["Closest Reference"], "Mafa-A1*018:01:01:01")
        XCTAssertEqual(details["SNP Substitutions"], "5")
        XCTAssertEqual(details["FASTA Record ID"], "cluster-b")
        XCTAssertEqual(details["Candidate FASTA Path"], "artifacts/candidates/candidates.fasta")
        XCTAssertEqual(details["Genotyping BAM Path"], "artifacts/alignments/genotyping-evidence.bam")
        XCTAssertEqual(details["Genotyping BAI Path"], "artifacts/alignments/genotyping-evidence.bam.bai")
        XCTAssertEqual(details["Reciprocal BAM Path"], "artifacts/alignments/unmatched-to-reference.bam")
        XCTAssertEqual(details["Reciprocal BAI Path"], "artifacts/alignments/unmatched-to-reference.bam.bai")
        XCTAssertEqual(details["Selected Alignment Query"], "cluster-b")
        XCTAssertEqual(details["Selected Alignment CIGAR"], "2000M")
        XCTAssertEqual(details["Genotyping Evidence"], "1 alignment in indexed BAM")
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains {
            $0.0.hasPrefix("Genotyping Alignment")
        })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0.localizedCaseInsensitiveContains("sequence bases") })
        XCTAssertEqual(controller.testingCandidateSelectionCallbackCounts, .init(known: 0, candidate: 1))
    }

    func testCandidateSelectionSummarizesLargeBAMEvidenceWithoutBuildingOneViewPerAlignment() {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(
                    id: "cluster-heavy",
                    name: "Mafa-A1*018:01:01:01_5nt_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalA"]
                ),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "cluster-heavy",
                    sample: "AnimalA",
                    reads: 1_573,
                    evidenceCount: 1_573
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingSelectCandidateCell(stableClusterID: "cluster-heavy", sample: "AnimalA")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertEqual(
            rows.first(where: { $0.0 == "Genotyping Evidence" })?.1,
            "1,573 alignments in indexed BAM"
        )
        XCTAssertFalse(rows.contains { $0.0.hasPrefix("Genotyping Alignment") })
        XCTAssertLessThan(rows.count, 60, "Detail metadata must stay bounded as BAM evidence grows.")
    }

    func testCandidateCellKeepsInspectorEvidenceWhileRowMountsSequenceDetail() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CandidateGraphicalSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let provisionalName = "Collision_nov"
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-a", name: provisionalName, classification: .novel, support: .singleton, samples: ["AnimalA"]),
                makeCandidate(id: "cluster-b", name: provisionalName, classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 11),
            ],
            candidateSequences: [
                "cluster-a": "AAAA",
                "cluster-b": "CCCCCCCCCCCCCCCCC",
            ],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-a",
                        alleleName: "Mafa-A1*001:01",
                        stableClusterID: "cluster-a"
                    ),
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-b",
                        alleleName: "Mafa-A1*002:01",
                        stableClusterID: "cluster-b"
                    ),
                ]
            ),
            integrityWarnings: [.init(
                code: .candidateArtifactMalformedFASTA,
                detail: "Legacy candidate warning"
            )]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-21T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A1", genotype: provisionalName, stableClusterID: "cluster-b"),
                body: "Cluster B row comment.",
                author: "qa",
                timestamp: "2026-07-21T00:00:00Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A1",
                    genotype: provisionalName,
                    sample: "AnimalA",
                    stableClusterID: "cluster-b"
                ),
                body: "Cluster B cell comment.",
                author: "qa",
                timestamp: "2026-07-21T00:00:01Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        let controller = GenotypeResultViewController()
        _ = controller.view
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.configure(result: result)

        controller.testingSelectCandidateCell(stableClusterID: "cluster-b", sample: "AnimalA")

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
        XCTAssertEqual(selection?.highlightTarget?.stableClusterID, "cluster-b")
        XCTAssertEqual(selection?.matrixTargets, [
            .cell(
                locus: "MHC-A1",
                genotype: provisionalName,
                sample: "AnimalA",
                stableClusterID: "cluster-b"
            ),
        ])
        XCTAssertTrue(selection?.detailRows.contains { $0 == ("Selected Sample Reads", "11") } == true)

        controller.testingSelectCandidateRow(stableClusterID: "cluster-b")

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)
        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, ["cluster-b"])
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("Validated allele record unavailable"))
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Selected Sample" })

        let highlightColor = AnnotationColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1)
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: .init(
                genotype: provisionalName,
                locus: "MHC-A1",
                stableClusterID: "cluster-b"
            ),
            scope: .selectedRow,
            color: highlightColor
        ))

        XCTAssertEqual(controller.testingAlleleSequenceRecordIdentities, ["cluster-b"])
        XCTAssertEqual(controller.testingCurrentSelectionStyle.fillColor, highlightColor)
    }

    func testFullSizeCandidateSequenceDetailOccupiesVisiblePane() throws {
        let stableClusterID = "cluster-visible"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_680, height: 1_475),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = try XCTUnwrap(window.contentView).bounds
        window.contentViewController = controller
        controller.configure(result: makeCandidateResult(
            calls: [makeCall(sample: "CR1178", genotype: "Mafa-A1*018:01:01:01", reads: 8)],
            candidates: [
                makeCandidate(
                    id: stableClusterID,
                    name: "Mafa-AG1*05:08:01:01_16nt_nov",
                    classification: .novel,
                    support: .shared,
                    samples: ["CR1178", "CR1178b"]
                ),
            ],
            observations: [
                makeCandidateObservation(cluster: stableClusterID, sample: "CR1178", reads: 106),
                makeCandidateObservation(cluster: stableClusterID, sample: "CR1178b", reads: 134),
            ],
            candidateSequences: [stableClusterID: String(repeating: "A", count: 2_000)],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "NHP11358",
                        alleleName: "Mafa-AG1*05:08:01:01",
                        stableClusterID: stableClusterID
                    ),
                ]
            )
        ))

        controller.testingSelectCandidateRow(stableClusterID: stableClusterID)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let detail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
        let detailScrollView = try XCTUnwrap(
            firstAncestor(of: detail, ofType: NSScrollView.self)
        )
        XCTAssertGreaterThan(controller.testingDetailPaneWidth, 1_000)
        XCTAssertEqual(
            detail.bounds.width,
            controller.testingDetailPaneWidth - 20,
            accuracy: 2,
            "The sequence detail must fill the available detail pane."
        )
        XCTAssertEqual(
            detail.bounds.height,
            detailScrollView.contentSize.height - 16,
            accuracy: 2,
            "The sequence detail must grow to fill the visible pane height."
        )
        XCTAssertNotNil(descendants(of: detail).first {
            $0.accessibilityIdentifier() == "mhc-sequence-format"
        })
        XCTAssertNotNil(descendants(of: detail).first {
            $0.accessibilityIdentifier() == "mhc-sequence-text"
        })

        let splitView = try XCTUnwrap(
            controller.view.firstDescendant(ofType: NSSplitView.self)
        )
        splitView.setPosition(splitView.bounds.height - 320, ofDividerAt: 0)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let compactDetailHeight = detail.bounds.height
        XCTAssertEqual(
            compactDetailHeight,
            detailScrollView.contentSize.height - 16,
            accuracy: 2
        )

        splitView.setPosition(splitView.bounds.height - 700, ofDividerAt: 0)
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(detail.bounds.height, compactDetailHeight)
        XCTAssertEqual(
            detail.bounds.height,
            detailScrollView.contentSize.height - 16,
            accuracy: 2,
            "Dragging the divider must resize the sequence detail with the pane."
        )
    }

    func testRepeatedCandidateRowSelectionsReuseOneSequenceDetail() throws {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-heavy", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
                makeCandidate(id: "cluster-light", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(
                    cluster: "cluster-heavy",
                    sample: "AnimalA",
                    reads: 18_000,
                    evidenceCount: 18_000
                ),
                makeCandidateObservation(cluster: "cluster-light", sample: "AnimalA", reads: 7),
            ],
            candidateSequences: [
                "cluster-heavy": String(repeating: "A", count: 32),
                "cluster-light": String(repeating: "C", count: 28),
            ],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-heavy",
                        alleleName: "Mafa-A1*001:01",
                        stableClusterID: "cluster-heavy"
                    ),
                    makeCandidateReferenceVisualizationRecord(
                        rawReferenceID: "reference-light",
                        alleleName: "Mafa-A1*002:01",
                        stableClusterID: "cluster-light"
                    ),
                ]
            )
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateRow(stableClusterID: "cluster-heavy")
        let detail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
        let baselineDescendantCount = descendants(of: detail).count
        let baselineConstraintIDs = Set(activeConstraints(in: detail).map(ObjectIdentifier.init))
        XCTAssertLessThan(baselineDescendantCount, 300)

        for _ in 0..<20 {
            controller.testingSelectCandidateRow(stableClusterID: "cluster-light")
            controller.testingSelectCandidateRow(stableClusterID: "cluster-heavy")
            let current = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
            XCTAssertTrue(detail === current)
            XCTAssertEqual(descendants(of: current).count, baselineDescendantCount)
            XCTAssertEqual(
                Set(activeConstraints(in: current).map(ObjectIdentifier.init)),
                baselineConstraintIDs
            )
        }

        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
        XCTAssertLessThan(controller.testingCurrentSelectionDetailRows.count, 60)
        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.first { $0.0 == "Genotyping Evidence" }?.1,
            "18,000 alignments in indexed BAM"
        )
    }

    func testMissingCandidateRecordUsesUnavailableSequenceWithoutReloading() async throws {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "legacy-candidate", name: "Legacy_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "legacy-candidate", sample: "AnimalA", reads: 9),
            ]
        )
        let loaderSpy = KnownSelectionResultLoaderSpy(result: result)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.genotypeResultLoader = { url in
            await loaderSpy.load(url)
        }
        controller.configure(result: result)

        controller.testingSelectCandidateRow(stableClusterID: "legacy-candidate")

        let detail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("Validated allele record unavailable"))
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
        XCTAssertLessThan(descendants(of: detail).count, 300)
        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)
        let loaderInvocationCount = await loaderSpy.currentInvocationCount()
        XCTAssertEqual(loaderInvocationCount, 0)
    }

    func testKnownAndCandidateRowsReuseOneSequenceDetailAndCellsClearIt() throws {
        let knownID = "01_Mafa_A1_Known"
        let knownRecord = makeMHCReferenceVisualizationRecord(
            rawReferenceID: knownID,
            alleleName: "Mafa-A1*001:01"
        )
        let candidateReference = makeCandidateReferenceVisualizationRecord(
            rawReferenceID: "candidate-reference",
            alleleName: "Mafa-A1*002:01",
            stableClusterID: "candidate-a"
        )
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: knownID, reads: 12)],
            candidates: [
                makeCandidate(id: "candidate-a", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "candidate-a", sample: "AnimalA", reads: 8),
            ],
            candidateSequences: ["candidate-a": String(repeating: "A", count: 24)],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [knownRecord, candidateReference]
            )
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateRow(stableClusterID: "candidate-a")
        let sequenceDetail = try XCTUnwrap(onlyAlleleSequenceDetail(in: controller.view))

        controller.testingSelectMatrixRows(genotypes: [knownID], sample: nil)

        XCTAssertTrue(sequenceDetail === onlyAlleleSequenceDetail(in: controller.view))

        controller.testingSelectCandidateCell(stableClusterID: "candidate-a", sample: "AnimalA")

        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertTrue(knownAlleleDetails(in: controller.view).isEmpty)

        controller.testingSelectMatrixRows(genotypes: [knownID], sample: nil)

        XCTAssertTrue(sequenceDetail === onlyAlleleSequenceDetail(in: controller.view))
        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
    }

    func testUnsupportedKnownCellRefreshDoesNotResurrectPreviousCandidateDetail() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnsupportedKnownCellRefresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let knownID = "01_Mafa_A1_Known"
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: knownID, reads: 12)],
            candidates: [
                makeCandidate(id: "candidate-a", name: "Candidate_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "candidate-a", sample: "AnimalA", reads: 8),
                makeCandidateObservation(cluster: "candidate-a", sample: "AnimalB", reads: 6),
            ],
            candidateSequences: ["candidate-a": String(repeating: "A", count: 24)],
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeCandidateReferenceVisualizationRecord(
                    rawReferenceID: "candidate-reference",
                    alleleName: "Mafa-A1*002:01",
                    stableClusterID: "candidate-a"
                )]
            )
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateRow(stableClusterID: "candidate-a")
        XCTAssertNotNil(onlyAlleleSequenceDetail(in: controller.view))

        controller.testingSelectMatrixCell(genotype: knownID, sample: "AnimalB")
        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Selection Type", "Cell")
        })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Sample", "AnimalB")
        })

        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Unsupported cell note"
        ))

        XCTAssertTrue(candidateAlleleDetails(in: controller.view).isEmpty)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 0)
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Selection Type", "Cell")
        })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Cell Comment", "Unsupported cell note")
        })
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: knownID, sample: "AnimalB"),
        ])
    }

    func testSampleAlleleDetailsPreserveCandidateClusterIdentity() {
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-a", name: "Collision_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "cluster-b", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 11),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        let details = matrix.visibleSampleAlleleDetails(sample: "AnimalA")

        XCTAssertEqual(Set(details.map(\.rowID)), [
            .candidate(stableClusterID: "cluster-a"),
            .candidate(stableClusterID: "cluster-b"),
        ])
        XCTAssertEqual(Set(details.compactMap(\.stableClusterID)), ["cluster-a", "cluster-b"])
        XCTAssertEqual(Set(details.map { $0.support.passedUniqueReads }), [5, 11])
    }

    func testCandidateVisibilityPersistsBeforeRedrawWithoutMutatingCurrentWorkbook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CandidateDisplayPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("current.xlsx")
        let workbookBytes = Data("workbook-must-not-change".utf8)
        try workbookBytes.write(to: workbookURL)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        _ = controller.testingVisibleMatrixGenotypes
        var state = controller.testingDisplayState
        var candidateSettings = try XCTUnwrap(state.mhcCandidateDisplaySettings)
        candidateSettings.showSingletonCandidates = false
        state.mhcCandidateDisplaySettings = candidateSettings

        controller.applyDisplayState(state)

        XCTAssertTrue(controller.testingVisibleMatrixGenotypes.contains("Candidate_nov"), "Redraw must wait for durable sidecar publication")
        await controller.testingWaitForCandidateSettingsPersistence()
        XCTAssertFalse(controller.testingVisibleMatrixGenotypes.contains("Candidate_nov"))
        XCTAssertEqual(try Data(contentsOf: workbookURL), workbookBytes)
        XCTAssertFalse(
            try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
                .settings.mhcCandidateDisplay.showSingletonCandidates
        )
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        let provenance = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: ProvenanceRecorder.fileSidecarURL(for: annotationURL))
        )
        XCTAssertEqual(provenance.options.explicit["action"], .string("updateMHCCandidateDisplaySettings"))
        XCTAssertEqual(provenance.options.explicit["showSingletonCandidates"], .boolean(false))
        XCTAssertEqual(provenance.output?.path, annotationURL.path)
        XCTAssertNil(controller.testingCandidatePersistenceWarning)
    }

    func testCandidateTintRequiresExplicitWorkbookRefreshButVisibilityDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CandidateTintWorkbookRefresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("current.xlsx")
        let workbookBytes = Data("workbook-must-not-change-until-explicit-update".utf8)
        try workbookBytes.write(to: workbookURL)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        var tintState = controller.testingDisplayState
        var tintSettings = try XCTUnwrap(tintState.mhcCandidateDisplaySettings)
        tintSettings.tints[.singletonNovel] = AnnotationColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5)
        tintState.mhcCandidateDisplaySettings = tintSettings
        controller.applyDisplayState(tintState)
        await controller.testingWaitForCandidateSettingsPersistence()

        XCTAssertTrue(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertTrue(controller.testingCurrentWorkbookUpdateStatus?.contains("candidate tint") == true)
        XCTAssertEqual(try Data(contentsOf: workbookURL), workbookBytes)

        controller.applyCurrentWorkbookUpdateCompleted(result: result)
        XCTAssertFalse(controller.testingCurrentWorkbookNeedsRefresh)

        var visibilityState = controller.testingDisplayState
        var visibilitySettings = try XCTUnwrap(visibilityState.mhcCandidateDisplaySettings)
        visibilitySettings.showSingletonCandidates = false
        visibilityState.mhcCandidateDisplaySettings = visibilitySettings
        controller.applyDisplayState(visibilityState)
        await controller.testingWaitForCandidateSettingsPersistence()

        XCTAssertFalse(controller.testingCurrentWorkbookNeedsRefresh)
        XCTAssertEqual(try Data(contentsOf: workbookURL), workbookBytes)
    }

    func testCandidateSettingsConflictRestoresLatestSidecarAndShowsNonfatalWarning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CandidateDisplayConflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        let concurrent = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "other")
        var concurrentSettings = concurrent.sidecar.settings.mhcCandidateDisplay
        concurrentSettings.showKnown = false
        try concurrent.updateMHCCandidateDisplaySettings(concurrentSettings)
        var state = controller.testingDisplayState
        var staleSettings = try XCTUnwrap(state.mhcCandidateDisplaySettings)
        staleSettings.showSingletonCandidates = false
        state.mhcCandidateDisplaySettings = staleSettings

        controller.applyDisplayState(state)
        await controller.testingWaitForCandidateSettingsPersistence()

        XCTAssertFalse(try XCTUnwrap(controller.testingDisplayState.mhcCandidateDisplaySettings).showKnown)
        XCTAssertTrue(try XCTUnwrap(controller.testingDisplayState.mhcCandidateDisplaySettings).showSingletonCandidates)
        XCTAssertTrue(controller.testingCandidatePersistenceWarning?.localizedCaseInsensitiveContains("changed") == true)
        XCTAssertEqual(controller.testingVisibleMatrixGenotypes, ["Candidate_nov"])
    }

    func testRapidCandidateControlEditsCoalesceWithoutLosingTheLatestSettings() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CandidateDisplayCoalescing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        var firstState = controller.testingDisplayState
        var firstSettings = try XCTUnwrap(firstState.mhcCandidateDisplaySettings)
        firstSettings.showKnown = false
        firstState.mhcCandidateDisplaySettings = firstSettings
        var latestState = firstState
        var latestSettings = firstSettings
        latestSettings.showSingletonCandidates = false
        latestState.mhcCandidateDisplaySettings = latestSettings

        controller.applyDisplayState(firstState)
        controller.applyDisplayState(latestState)
        await controller.testingWaitForCandidateSettingsPersistence()

        let saved = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
            .settings.mhcCandidateDisplay
        XCTAssertFalse(saved.showKnown)
        XCTAssertFalse(saved.showSingletonCandidates)
        XCTAssertTrue(controller.testingVisibleMatrixGenotypes.isEmpty)
    }

    func testCandidateSelectionPersistsByStableIDAcrossTintReloadAndClearsWhenHidden() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CandidateSelectionReload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [],
            candidates: [makeCandidate(id: "stable-a", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "stable-a", sample: "AnimalA", reads: 5)]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCandidateCell(stableClusterID: "stable-a", sample: "AnimalA")
        var tintState = controller.testingDisplayState
        var tintSettings = try XCTUnwrap(tintState.mhcCandidateDisplaySettings)
        tintSettings.tints[.singletonNovel] = AnnotationColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 0.5)
        tintState.mhcCandidateDisplaySettings = tintSettings

        controller.applyDisplayState(tintState)
        await controller.testingWaitForCandidateSettingsPersistence()
        XCTAssertEqual(controller.testingSelectedCandidateStableClusterID, "stable-a")

        var hiddenState = controller.testingDisplayState
        var hiddenSettings = try XCTUnwrap(hiddenState.mhcCandidateDisplaySettings)
        hiddenSettings.showSingletonCandidates = false
        hiddenState.mhcCandidateDisplaySettings = hiddenSettings
        controller.applyDisplayState(hiddenState)
        await controller.testingWaitForCandidateSettingsPersistence()
        XCTAssertNil(controller.testingSelectedCandidateStableClusterID)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.isEmpty)
    }

    func testCandidateRowsRemainExcludedFromKnownCallQCAndHaplotypeOutputs() {
        let result = makeCandidateResult(
            calls: [],
            candidates: [makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"])],
            observations: [
                makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 500),
                makeCandidateObservation(cluster: "candidate", sample: "AnimalB", reads: 700),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        XCTAssertEqual(result.callCount, 0)
        XCTAssertTrue(result.locusSummaries.isEmpty)
        XCTAssertTrue(controller.testingCurrentWorkbookHaplotypeCalls().isEmpty)
        XCTAssertFalse(controller.testingHaplotypeMatrixText.contains("Candidate_nov"))
    }
    func testMHCCandidateMatrixKeepsCollidingLabelsAsStableRowsAndShowsAllPopulationsByDefault() throws {
        let knownCall = makeCall(sample: "AnimalA", genotype: "Mafa-A1*001:01", reads: 13)
        let result = makeCandidateResult(
            calls: [knownCall],
            candidates: [
                makeCandidate(
                    id: "cluster-b",
                    name: "Mafa-A1*018:01:01:01_5nt_nov",
                    classification: .novel,
                    support: .singleton,
                    samples: ["AnimalB"]
                ),
                makeCandidate(
                    id: "cluster-a",
                    name: "Mafa-A1*018:01:01:01_5nt_nov",
                    classification: .novel,
                    support: .shared,
                    samples: ["AnimalA", "AnimalB"]
                ),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 11),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()

        matrix.configure(result: result, sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z"))

        XCTAssertEqual(matrix.testingVisibleRows.map(\.population), [.known, .sharedCandidate, .singletonCandidate])
        let collisions = matrix.testingVisibleRows.filter {
            $0.alleleName == "Mafa-A1*018:01:01:01_5nt_nov"
        }
        XCTAssertEqual(collisions.count, 2)
        XCTAssertEqual(collisions.map(\.id), [
            .candidate(stableClusterID: "cluster-a"),
            .candidate(stableClusterID: "cluster-b"),
        ])
        XCTAssertEqual(collisions[0].support(for: "AnimalA")?.passedUniqueReads, 5)
        XCTAssertEqual(collisions[0].evidenceBySample["AnimalA"]?.first?.queryName, "cluster-a|AnimalA")
        XCTAssertTrue(matrix.testingLocusFilterTitles.contains("MHC-A1"))
        matrix.testingSelectCandidateCell(rowID: collisions[0].id, sample: "AnimalB")
        XCTAssertTrue(matrix.testingDrawsSelectionFocus(rowID: collisions[0].id, sample: "AnimalB"))
        XCTAssertFalse(matrix.testingDrawsSelectionFocus(rowID: collisions[1].id, sample: "AnimalB"))
    }

    func testMHCCandidateMatrixShowsStableClusterIDColumnWithFilterSortCopyAndAccessibility() throws {
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 13)],
            candidates: [
                makeCandidate(id: "cluster-b", name: "Collision_nov", classification: .novel, support: .singleton, samples: ["AnimalB"]),
                makeCandidate(id: "cluster-a", name: "Collision_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 11),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result)

        XCTAssertEqual(matrix.testingPinnedColumnTitles, ["", "Genotype", "Cluster ID", "Locus", "Samples", "Unique"])
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Known and candidate genotype calls, stable cluster identifiers, loci, and summary statistics"
        )
        XCTAssertEqual(
            matrix.testingPinnedCellValue(
                rowID: .known(locus: "MHC-KNOWN", genotype: "Known"),
                column: .stableClusterID
            ),
            ""
        )
        XCTAssertEqual(
            matrix.testingPinnedCellValue(rowID: .candidate(stableClusterID: "cluster-a"), column: .stableClusterID),
            "cluster-a"
        )
        XCTAssertEqual(
            matrix.testingPinnedCellValue(rowID: .candidate(stableClusterID: "cluster-b"), column: .stableClusterID),
            "cluster-b"
        )
        XCTAssertEqual(
            matrix.testingPinnedCellToolTip(rowID: .candidate(stableClusterID: "cluster-a"), column: .stableClusterID),
            "Stable cluster ID: cluster-a"
        )
        XCTAssertEqual(
            matrix.testingPinnedCellAccessibilityLabel(rowID: .candidate(stableClusterID: "cluster-a"), column: .stableClusterID),
            "Stable cluster ID: cluster-a"
        )
        XCTAssertTrue(matrix.testingPinnedCellIsSelectable(
            rowID: .candidate(stableClusterID: "cluster-a"),
            column: .stableClusterID
        ))

        matrix.testingSetFilter("cluster-b")
        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), [.candidate(stableClusterID: "cluster-b")])

        matrix.testingSetFilter("Collision_nov")
        matrix.testingSetSortDescriptor(key: matrix.testingStableClusterIDSortKey, ascending: true)
        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), [
            .candidate(stableClusterID: "cluster-a"),
            .candidate(stableClusterID: "cluster-b"),
        ])
    }

    func testCollidingCandidatesKeepStableIdentityThroughSelectionSupportStylesHighlightsAndComments() throws {
        let genotype = "Mafa-A1*018:01:01:01_5nt_nov"
        let result = makeCandidateResult(
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-a", name: genotype, classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "cluster-b", name: genotype, classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalB", reads: 7),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 11),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalB", reads: 13),
            ]
        )
        let rowA = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: genotype,
            stableClusterID: "cluster-a"
        )
        let rowB = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: genotype,
            stableClusterID: "cluster-b"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: rowA,
                style: .init(fillColor: "#123456"),
                author: "test",
                timestamp: "2026-07-20T00:00:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(target: rowA, body: "Only cluster A", author: "test", timestamp: "2026-07-20T00:00:00Z"),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)

        let idA = GenotypeCandidateMatrixRowID.candidate(stableClusterID: "cluster-a")
        let idB = GenotypeCandidateMatrixRowID.candidate(stableClusterID: "cluster-b")
        let styledA = try XCTUnwrap(matrix.testingBackgroundColor(rowID: idA, column: .alleleName))
        XCTAssertEqual(Double(styledA.redComponent), 0x12 / 255.0, accuracy: 0.000_001)
        XCTAssertNotEqual(
            matrix.testingBackgroundColor(rowID: idB, column: .alleleName)?.usingColorSpace(.deviceRGB)?.redComponent,
            0x12 / 255.0
        )
        XCTAssertTrue(matrix.testingPinnedCellToolTip(rowID: idA, column: .alleleName)?.contains("Only cluster A") == true)
        XCTAssertFalse(matrix.testingPinnedCellToolTip(rowID: idB, column: .alleleName)?.contains("Only cluster A") == true)

        matrix.testingClickCandidateRowChiclet(rowID: idA)
        matrix.testingClickCandidateRowChiclet(rowID: idB, modifiers: .command)
        XCTAssertEqual(Set(matrix.testingSelectedMatrixTargets), Set([rowA, rowB]))

        matrix.testingClickCandidateRowChiclet(rowID: idA)
        matrix.testingClickCandidateRowChiclet(rowID: idB, modifiers: .shift)
        XCTAssertEqual(Set(matrix.testingSelectedMatrixTargets), Set([rowA, rowB]))

        matrix.testingSelectCandidateCell(rowID: idA, sample: "AnimalA")
        XCTAssertEqual(matrix.testingSelectSupportedCellsInSelectedRow(minimumReads: 1), [
            .cell(locus: "MHC-A1", genotype: genotype, sample: "AnimalA", stableClusterID: "cluster-a"),
            .cell(locus: "MHC-A1", genotype: genotype, sample: "AnimalB", stableClusterID: "cluster-a"),
        ])

        matrix.applyHighlight(.init(
            target: .init(genotype: genotype, locus: "MHC-A1", stableClusterID: "cluster-a"),
            scope: .selectedRow,
            color: AnnotationColor(red: 0.1, green: 0.8, blue: 0.2)
        ))
        let highlightedA = try XCTUnwrap(matrix.testingBackgroundColor(rowID: idA, column: .alleleName))
        XCTAssertEqual(Double(highlightedA.greenComponent), 0.8, accuracy: 0.000_001)
        XCTAssertNotEqual(matrix.testingBackgroundColor(rowID: idB, column: .alleleName)?.usingColorSpace(.deviceRGB)?.greenComponent, 0.8)
    }

    func testCandidateTintContrastUsesCompositedNameCellBackgroundAndManualTextWins() throws {
        let candidates = [
            makeCandidate(id: "dark", name: "Dark_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
            makeCandidate(id: "light", name: "Light_nov", classification: .novel, support: .singleton, samples: ["AnimalA"]),
            makeCandidate(id: "semi", name: "Semi_ext", classification: .extension, support: .shared, samples: ["AnimalA", "AnimalB"]),
            makeCandidate(id: "manual", name: "Manual_ext", classification: .extension, support: .singleton, samples: ["AnimalA"]),
        ]
        let observations = candidates.flatMap { candidate in
            candidate.supportingSampleIDs.map {
                makeCandidateObservation(cluster: candidate.stableClusterID, sample: $0, reads: 5)
            }
        }
        let result = makeCandidateResult(calls: [], candidates: candidates, observations: observations)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(tints: [
            .sharedNovel: AnnotationColor(red: 0.01, green: 0.02, blue: 0.03, alpha: 1),
            .singletonNovel: AnnotationColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1),
            .sharedExtension: AnnotationColor(red: 0.01, green: 0.02, blue: 0.03, alpha: 0.2),
            .singletonExtension: AnnotationColor(red: 0.01, green: 0.02, blue: 0.03, alpha: 1),
        ])
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A1", genotype: "Manual_ext", stableClusterID: "manual"),
                style: .init(textColor: "#CC1933"),
                author: "test",
                timestamp: "2026-07-20T00:00:00Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)

        XCTAssertEqual(try XCTUnwrap(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "dark"), column: .alleleName)).hexString, "#FFFFFF")
        XCTAssertEqual(try XCTUnwrap(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "light"), column: .alleleName)).hexString, "#000000")
        XCTAssertEqual(try XCTUnwrap(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "semi"), column: .alleleName)).hexString, "#000000")
        XCTAssertEqual(try XCTUnwrap(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "manual"), column: .alleleName)).hexString, "#CC1933")
        XCTAssertNil(matrix.testingBackgroundColor(rowID: .candidate(stableClusterID: "dark"), column: .locus))
        XCTAssertNil(matrix.testingBackgroundColor(rowID: .candidate(stableClusterID: "dark"), column: .sample("AnimalA")))
        XCTAssertNil(matrix.testingRenderedTextColor(rowID: .candidate(stableClusterID: "dark"), column: .locus))
    }

    func testCandidateCellDetailsIncludeLegacyAndExactRowCommentsWithoutCollisionLeakage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CandidateInheritedComments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "Mafa-A1*018:01:01:01_5nt_nov"
        let result = makeCandidateResult(
            bundleURL: bundleURL,
            calls: [],
            candidates: [
                makeCandidate(id: "cluster-a", name: genotype, classification: .novel, support: .singleton, samples: ["AnimalA"]),
                makeCandidate(id: "cluster-b", name: genotype, classification: .novel, support: .singleton, samples: ["AnimalA"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "cluster-a", sample: "AnimalA", reads: 5),
                makeCandidateObservation(cluster: "cluster-b", sample: "AnimalA", reads: 7),
            ]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: .row(locus: "MHC-A1", genotype: genotype),
                body: "Inherited legacy row.",
                author: "qa",
                timestamp: "2026-07-20T00:00:00Z"
            ),
            .init(
                target: .row(locus: "MHC-A1", genotype: genotype, stableClusterID: "cluster-a"),
                body: "Cluster A row.",
                author: "qa",
                timestamp: "2026-07-20T00:00:01Z"
            ),
            .init(
                target: .row(locus: "MHC-A1", genotype: genotype, stableClusterID: "cluster-b"),
                body: "Cluster B row.",
                author: "qa",
                timestamp: "2026-07-20T00:00:02Z"
            ),
            .init(
                target: .cell(
                    locus: "MHC-A1",
                    genotype: genotype,
                    sample: "AnimalA",
                    stableClusterID: "cluster-a"
                ),
                body: "Cluster A cell.",
                author: "qa",
                timestamp: "2026-07-20T00:00:03Z"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)

        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")

        XCTAssertEqual(
            controller.testingCurrentSelectionMatrixTargets,
            [.cell(
                locus: "MHC-A1",
                genotype: genotype,
                sample: "AnimalA",
                stableClusterID: "cluster-a"
            )]
        )
        let commentBodies = controller.testingCurrentSelectionDetailRows
            .filter { $0.0.hasSuffix("Comment") }
            .map(\.1)
        XCTAssertEqual(commentBodies.filter { $0 == "Inherited legacy row." }.count, 1)
        XCTAssertEqual(commentBodies.filter { $0 == "Cluster A row." }.count, 1)
        XCTAssertEqual(commentBodies.filter { $0 == "Cluster A cell." }.count, 1)
        XCTAssertFalse(commentBodies.contains("Cluster B row."))
    }

    func testNonFullLengthBundleCannotProjectCandidateRowsSamplesSettingsOrColumns() {
        let knownCall = makeCall(sample: "AnimalA", genotype: "Known", reads: 13)
        let fullLengthResult = makeCandidateResult(
            calls: [knownCall],
            candidates: [
                makeCandidate(id: "candidate", name: "Candidate_nov", classification: .novel, support: .singleton, samples: ["CandidateOnlySample"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "candidate", sample: "CandidateOnlySample", reads: 7),
            ]
        )
        let nonFullLengthManifest = makeResult(
            samples: [],
            calls: [],
            mhcCandidateArtifacts: fullLengthResult.manifest.mhcCandidateArtifacts
        ).manifest
        let nonFullLengthResult = ONTGenotypeResultBundleData(
            bundleURL: fullLengthResult.bundleURL,
            manifest: nonFullLengthManifest,
            artifacts: fullLengthResult.artifacts,
            stats: fullLengthResult.stats,
            calls: [knownCall],
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 13,
                passedUniqueReads: 13,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [knownCall]
            )],
            haplotypeAnalysis: nil,
            mhcCandidates: fullLengthResult.mhcCandidates,
            mhcUnnameableClusters: nil,
            integrityWarnings: [],
            referenceMetadata: nil
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(showKnown: false)
        let matrix = GenotypeComparisonMatrixView()

        matrix.configure(result: nonFullLengthResult, sidecar: sidecar)

        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), [.known(locus: "MHC-KNOWN", genotype: "Known")])
        XCTAssertEqual(matrix.testingVisibleSampleNames, ["AnimalA"])
        XCTAssertEqual(matrix.testingPinnedColumnTitles, ["", "Genotype", "Locus", "Samples", "Unique"])
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Shared genotype calls, loci, and summary statistics"
        )
    }

    func testMHCCandidateMatrixVisibilitySettingsFilterEachPopulationIndependently() {
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 3)],
            candidates: [
                makeCandidate(id: "shared", name: "Shared_nov", classification: .novel, support: .shared, samples: ["AnimalA", "AnimalB"]),
                makeCandidate(id: "single", name: "Single_ext", classification: .extension, support: .singleton, samples: ["AnimalB"]),
            ],
            observations: [
                makeCandidateObservation(cluster: "shared", sample: "AnimalA", reads: 2),
                makeCandidateObservation(cluster: "shared", sample: "AnimalB", reads: 4),
                makeCandidateObservation(cluster: "single", sample: "AnimalB", reads: 6),
            ]
        )
        let matrix = GenotypeComparisonMatrixView()

        for (settings, expected) in [
            (ONTMHCCandidateDisplaySettings(showKnown: false), ["Shared_nov", "Single_ext"]),
            (ONTMHCCandidateDisplaySettings(showSharedCandidates: false), ["Known", "Single_ext"]),
            (ONTMHCCandidateDisplaySettings(showSingletonCandidates: false), ["Known", "Shared_nov"]),
            (ONTMHCCandidateDisplaySettings(showKnown: false, showSharedCandidates: false), ["Single_ext"]),
            (ONTMHCCandidateDisplaySettings(showKnown: false, showSingletonCandidates: false), ["Shared_nov"]),
            (ONTMHCCandidateDisplaySettings(showSharedCandidates: false, showSingletonCandidates: false), ["Known"]),
        ] {
            var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
            sidecar.settings.mhcCandidateDisplay = settings
            matrix.configure(result: result, sidecar: sidecar)
            XCTAssertEqual(matrix.testingVisibleGenotypes, expected)
        }
    }

    func testMHCCandidateTintsAreExactAndOnlyColorAlleleNameCells() throws {
        let categories: [(ONTMHCCandidateTintCategory, ONTMHCCandidateClassification, ONTMHCCandidateSupportClass, String)] = [
            (.sharedNovel, .novel, .shared, "shared-nov"),
            (.singletonNovel, .novel, .singleton, "singleton-nov"),
            (.sharedExtension, .extension, .shared, "shared-ext"),
            (.singletonExtension, .extension, .singleton, "singleton-ext"),
        ]
        let customTints = Dictionary(uniqueKeysWithValues: categories.enumerated().map { index, value in
            (value.0, AnnotationColor(
                red: Double(index + 1) / 10,
                green: Double(index + 2) / 10,
                blue: Double(index + 3) / 10,
                alpha: Double(index + 4) / 10
            ))
        })
        let candidates = categories.map { category, classification, support, id in
            makeCandidate(
                id: id,
                name: id,
                classification: classification,
                support: support,
                samples: support == .shared ? ["AnimalA", "AnimalB"] : ["AnimalA"]
            )
        }
        let observations = candidates.flatMap { candidate in
            candidate.supportingSampleIDs.map {
                makeCandidateObservation(cluster: candidate.stableClusterID, sample: $0, reads: 5)
            }
        }
        let result = makeCandidateResult(calls: [], candidates: candidates, observations: observations)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(tints: customTints)
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)

        for (category, _, _, id) in categories {
            let rowID = GenotypeCandidateMatrixRowID.candidate(stableClusterID: id)
            let color = try XCTUnwrap(matrix.testingBackgroundColor(rowID: rowID, column: .alleleName))
            let expected = try XCTUnwrap(customTints[category])
            XCTAssertEqual(color.redComponent, expected.red, accuracy: 0.000_000_1)
            XCTAssertEqual(color.greenComponent, expected.green, accuracy: 0.000_000_1)
            XCTAssertEqual(color.blueComponent, expected.blue, accuracy: 0.000_000_1)
            XCTAssertEqual(color.alphaComponent, expected.alpha, accuracy: 0.000_000_1)
            XCTAssertNil(matrix.testingBackgroundColor(rowID: rowID, column: .locus))
            XCTAssertNil(matrix.testingBackgroundColor(rowID: rowID, column: .sample("AnimalA")))
        }
    }

    func testMHCCandidateTintIsBelowKnownAnnotationAndSelectionFocus() throws {
        let candidate = makeCandidate(
            id: "candidate",
            name: "Candidate_nov",
            classification: .novel,
            support: .singleton,
            samples: ["AnimalA"]
        )
        let result = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [candidate],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A1", genotype: "Candidate_nov"),
                style: .init(fillColor: "#123456"),
                author: "test",
                timestamp: "2026-07-20T00:00:00Z"
            ),
            .init(
                target: .row(locus: "MHC-KNOWN", genotype: "Known"),
                style: .init(fillColor: "#654321"),
                author: "test",
                timestamp: "2026-07-20T00:00:00Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: result, sidecar: sidecar)

        let candidateID = GenotypeCandidateMatrixRowID.candidate(stableClusterID: "candidate")
        let annotatedCandidateColor = try XCTUnwrap(matrix.testingBackgroundColor(rowID: candidateID, column: .alleleName))
        XCTAssertEqual(annotatedCandidateColor.redComponent, 0x12 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(annotatedCandidateColor.greenComponent, 0x34 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(annotatedCandidateColor.blueComponent, 0x56 / 255.0, accuracy: 0.000_000_1)
        let annotatedKnownColor = try XCTUnwrap(matrix.testingBackgroundColor(
            rowID: .known(locus: "MHC-KNOWN", genotype: "Known"),
            column: .alleleName
        ))
        XCTAssertEqual(annotatedKnownColor.redComponent, 0x65 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(annotatedKnownColor.greenComponent, 0x43 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(annotatedKnownColor.blueComponent, 0x21 / 255.0, accuracy: 0.000_000_1)
        matrix.testingSelectCandidateCell(rowID: candidateID, sample: "AnimalA")
        XCTAssertTrue(matrix.testingDrawsSelectionFocus(rowID: candidateID, sample: "AnimalA"))
        XCTAssertEqual(matrix.testingSelectedRowID, candidateID)
    }

    func testMHCCandidateProjectionFailsSoftAndClearsAcrossBundleReload() {
        let matrix = GenotypeComparisonMatrixView()
        let candidateResult = makeCandidateResult(
            calls: [makeCall(sample: "AnimalA", genotype: "Known", reads: 8)],
            candidates: [makeCandidate(id: "candidate", name: "Candidate", classification: .novel, support: .singleton, samples: ["AnimalA"])],
            observations: [makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5)]
        )
        matrix.configure(result: candidateResult, sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z"))
        XCTAssertEqual(matrix.testingVisibleRows.count, 2)
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Known and candidate genotype calls, stable cluster identifiers, loci, and summary statistics"
        )

        let legacyManifest = makeResult(samples: candidateResult.samples, calls: candidateResult.calls).manifest
        let legacyResult = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/legacy.lungfishgenotype"),
            manifest: legacyManifest,
            artifacts: candidateResult.artifacts,
            stats: candidateResult.stats,
            calls: candidateResult.calls,
            samples: candidateResult.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: candidateResult.mhcCandidates,
            mhcUnnameableClusters: nil,
            integrityWarnings: [],
            referenceMetadata: nil
        )
        matrix.configure(result: legacyResult, sidecar: GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z"))
        XCTAssertEqual(matrix.testingVisibleRows.map(\.population), [.known])
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Shared genotype calls, loci, and summary statistics"
        )

        let invalidCandidateResult = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/reloaded.lungfishgenotype"),
            manifest: candidateResult.manifest,
            artifacts: candidateResult.artifacts,
            stats: candidateResult.stats,
            calls: candidateResult.calls,
            samples: candidateResult.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            integrityWarnings: [.init(code: .candidateArtifactMalformedJSON, detail: "invalid")],
            referenceMetadata: nil
        )
        var invalidSidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-20T00:00:00Z")
        invalidSidecar.settings.mhcCandidateDisplay = ONTMHCCandidateDisplaySettings(showKnown: false)
        matrix.configure(result: invalidCandidateResult, sidecar: invalidSidecar)

        XCTAssertEqual(matrix.testingVisibleRows.map(\.id), [
            .known(locus: "MHC-KNOWN", genotype: "Known"),
        ])
        XCTAssertEqual(matrix.testingPinnedColumnTitles, ["", "Genotype", "Locus", "Samples", "Unique"])
        XCTAssertEqual(
            matrix.testingPinnedTableAccessibilityLabel,
            "Shared genotype calls, loci, and summary statistics"
        )
    }

    func testGenotypeOnlyResultForcesSummaryMatrixListOverDetailViewport() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            summaryViewMode: .outline,
            layout: .listTrailing,
            showsAncillaryLoci: true
        ))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)
        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 0)
    }

    func testFullSizeContentKeepsFullLengthCandidateSearchBelowSafeAreaTop() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_500, height: 900),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = try XCTUnwrap(window.contentView).bounds
        window.contentViewController = controller
        controller.configure(result: makeCandidateResult(
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
                makeCandidateObservation(cluster: "candidate", sample: "AnimalA", reads: 5),
            ]
        ))

        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let quickFilterBar = try XCTUnwrap(
            controller.view.firstDescendant(ofType: GenotypeQuickFilterBarView.self)
        )
        let searchField = try XCTUnwrap(quickFilterBar.firstDescendant(ofType: NSSearchField.self))
        let searchFrame = searchField.convert(searchField.bounds, to: controller.view)
        let safeAreaTop = controller.view.safeAreaLayoutGuide.frame.maxY

        XCTAssertGreaterThan(controller.view.safeAreaInsets.top, 0)
        XCTAssertLessThanOrEqual(searchFrame.maxY, safeAreaTop)
    }

    func testGenotypeOnlyResultDirectLensSelectionCannotEscapeSummary() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))
        controller.testingSetUnappliedDisplayState(GenotypeResultDisplayState(
            viewportLens: .audit,
            summaryViewMode: .outline,
            layout: .listTrailing
        ))

        controller.testingSelectLens(.audit)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)
        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)

        controller.testingSetUnappliedDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            summaryViewMode: .outline,
            layout: .listLeading
        ))
        controller.testingSelectLens(.review)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingPanelLayout, .listTop)
        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
    }

    func testGenotypeOnlySummaryShowsScrollableEmptySelectionDetail() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertEqual(
            controller.testingDetailText,
            "Select a sample column or allele row to view details."
        )
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("low coverage"))
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("below threshold"))
    }

    func testClearingGenotypeOnlyMatrixSelectionRestoresEmptyDetailPrompt() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))

        controller.testingClickMatrixColumnChiclet(sample: "AnimalA")
        XCTAssertNotEqual(
            controller.testingDetailText,
            "Select a sample column or allele row to view details."
        )

        controller.testingClickMatrixColumnChiclet(sample: "AnimalA", modifiers: .command)

        XCTAssertEqual(
            controller.testingDetailText,
            "Select a sample column or allele row to view details."
        )
        XCTAssertFalse(controller.testingDetailScrollViewIsHidden)
        XCTAssertTrue(controller.testingCohortSummaryIsHidden)
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("low coverage"))
        XCTAssertFalse(controller.testingDetailText.localizedCaseInsensitiveContains("below threshold"))
    }

    func testHaplotypedResultKeepsLensHeaderAndSideBySideLayout() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)],
            haplotypeAnalysis: analysis
        ))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            layout: .listTrailing
        ))

        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertEqual(controller.testingPanelLayout, .listTrailing)
        XCTAssertTrue(controller.testingSplitIsVertical)
        XCTAssertFalse(controller.testingFirstPaneIsMatrix)
    }

    func testEmptyResultDoesNotUseGenotypeOnlyViewport() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingSelectLens(.audit)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "audit")
        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
    }

    func testReconfigureFromGenotypeOnlyToHaplotypedRestoresLensHeader() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
        ]))
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )

        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42)],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectLens(.review)

        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
    }

    func testViewportPublishesSharedGenotypeSelectionForInspector() {
        let controller = GenotypeResultViewController()
        _ = controller.view

        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02",
                passedAlignments: 42,
                passedUniqueReads: 39,
                sampleTotalReads: 100,
                sampleUniqueRetainedReads: 39,
                sampleUniqueRetainedPercent: 39,
                overallInputReads: 1000,
                overallUniqueRetainedReads: 60,
                overallUniqueRetainedPercent: 6
            )
        ]
        let result = ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
            calls: calls,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 42,
                    passedUniqueReads: 39,
                    sampleTotalReads: 100,
                    sampleUniqueRetainedPercent: 39,
                    calls: calls
                )
            ]
        )

        var selectedState: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { state in
            selectedState = state
        }

        controller.configure(result: result)
        controller.testingSelectFirstSharedCall()

        XCTAssertEqual(selectedState?.title, "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02")
        XCTAssertTrue(selectedState?.detailRows.contains(where: { $0.0 == "Locus" && $0.1 == "MHC-DQB1" }) ?? false)
        XCTAssertTrue(selectedState?.detailRows.contains(where: { $0.0 == "Allele" }) ?? false)
        XCTAssertFalse(selectedState?.subtitle?.localizedCaseInsensitiveContains("samples") ?? true)
        XCTAssertFalse(selectedState?.detailRows.contains(where: {
            ["Samples", "Unique Reads", "Alignments", "Support", "Support Metric", "Top Sample"].contains($0.0)
        }) ?? true)
    }

    func testViewportDoesNotGrowToFitLongGenotypeLabels() {
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 820, height: 640)

        let longGenotype = "13_Mafa_DQB1_06g1|DQB1_06_01_01,_DQB1_06_01_02,_DQB1_06_02,_DQB1_06_34"
        let calls = [
            ONTGenotypeCall(
                sample: "LF2874",
                genotype: longGenotype,
                passedAlignments: 2_945,
                passedUniqueReads: 2_945,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 19_769,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: 11_197_546,
                overallUniqueRetainedReads: 260_534,
                overallUniqueRetainedPercent: 2.326706
            )
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test-definitions",
            definitionSetName: "Test definitions",
            speciesName: "Test species",
            samples: []
        )
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "LF2874",
                passedAlignments: 19_852,
                passedUniqueReads: 19_769,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls
            )
        ], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            layout: .listLeading
        ))

        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
        XCTAssertLessThanOrEqual(controller.view.fittingSize.width, 900)
        XCTAssertGreaterThanOrEqual(controller.testingSamplePaneWidth, 300)
        XCTAssertLessThanOrEqual(controller.testingDetailPaneWidth, 520)
    }

    func testLensSwitcherShowsConsumerAndArtifactsContent() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingSelectLens(.summary)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")

        controller.testingSelectLens(.audit)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "audit")
    }

    func testArtifactsLensListsValidatedCandidateFASTAAndGenBankArtifactsWhenDeclared() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeCandidateGenBankLens-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let candidateFASTAURL = bundleURL.appendingPathComponent("artifacts/candidates/candidate_alleles.fasta")
        let unnameableFASTAURL = bundleURL.appendingPathComponent("artifacts/candidates/unnameable_unmatched_clusters.fasta")
        let candidateURL = bundleURL.appendingPathComponent("artifacts/candidates/candidate_alleles.gb")
        let unnameableURL = bundleURL.appendingPathComponent("artifacts/candidates/unnameable_unmatched_clusters.gb")
        let candidateGenBankArtifactURLs = ONTMHCCandidateGenBankArtifactURLs(
            candidateAlleles: candidateURL,
            unnameableClusters: unnameableURL,
            candidateFASTA: candidateFASTAURL,
            unnameableFASTA: unnameableFASTAURL
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            mhcCandidateGenBankArtifactURLs: candidateGenBankArtifactURLs
        ))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        XCTAssertTrue(lensText.contains("Candidate Alleles FASTA"))
        XCTAssertTrue(lensText.contains("Un-nameable Clusters FASTA"))
        XCTAssertTrue(lensText.contains("Candidate Alleles GenBank"))
        XCTAssertTrue(lensText.contains("Un-nameable Clusters GenBank"))
    }

    func testArtifactsLensOmitsCandidateGenBankArtifactsWhenAbsent() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        XCTAssertFalse(lensText.contains("Candidate Alleles FASTA"))
        XCTAssertFalse(lensText.contains("Un-nameable Clusters FASTA"))
        XCTAssertFalse(lensText.contains("Candidate Alleles GenBank"))
        XCTAssertFalse(lensText.contains("Un-nameable Clusters GenBank"))
        XCTAssertFalse(lensText.contains("Genotyping Evidence BAM"))
        XCTAssertFalse(lensText.contains("Genotyping Evidence BAI"))
        XCTAssertFalse(lensText.contains("Reciprocal Evidence BAM"))
        XCTAssertFalse(lensText.contains("Reciprocal Evidence BAI"))
    }

    func testArtifactsLensListsValidatedMHCAlignmentArtifactsWhenDeclared() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMHCAlignmentArtifactLens-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let genotypingBAMURL = bundleURL.appendingPathComponent("artifacts/alignments/genotyping.bam")
        let genotypingBAIURL = bundleURL.appendingPathComponent("artifacts/alignments/genotyping.bam.bai")
        let reciprocalBAMURL = bundleURL.appendingPathComponent("artifacts/alignments/reciprocal.bam")
        let reciprocalBAIURL = bundleURL.appendingPathComponent("artifacts/alignments/reciprocal.bam.bai")
        let alignmentArtifactURLs = ONTMHCAlignmentArtifactURLs(
            genotypingBAM: genotypingBAMURL,
            genotypingBAI: genotypingBAIURL,
            reciprocalBAM: reciprocalBAMURL,
            reciprocalBAI: reciprocalBAIURL
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            kind: "full-length-ont-mhc-genotype",
            mhcAlignmentArtifactURLs: alignmentArtifactURLs
        ))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        XCTAssertTrue(lensText.contains("Genotyping Evidence BAM"))
        XCTAssertTrue(lensText.contains(genotypingBAMURL.standardizedFileURL.path))
        XCTAssertTrue(lensText.contains("Genotyping Evidence BAI"))
        XCTAssertTrue(lensText.contains(genotypingBAIURL.standardizedFileURL.path))
        XCTAssertTrue(lensText.contains("Reciprocal Evidence BAM"))
        XCTAssertTrue(lensText.contains(reciprocalBAMURL.standardizedFileURL.path))
        XCTAssertTrue(lensText.contains("Reciprocal Evidence BAI"))
        XCTAssertTrue(lensText.contains(reciprocalBAIURL.standardizedFileURL.path))
    }

    func testArtifactsLensOmitsInjectedMHCAlignmentArtifactsForNonFullLengthResult() {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeNonMHCAlignmentArtifactLens-\(UUID().uuidString)", isDirectory: true)
        let alignmentArtifactURLs = ONTMHCAlignmentArtifactURLs(
            genotypingBAM: bundleURL.appendingPathComponent("genotyping.bam"),
            genotypingBAI: bundleURL.appendingPathComponent("genotyping.bam.bai"),
            reciprocalBAM: bundleURL.appendingPathComponent("reciprocal.bam"),
            reciprocalBAI: bundleURL.appendingPathComponent("reciprocal.bam.bai")
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            kind: "ont-barcode-genotype",
            mhcAlignmentArtifactURLs: alignmentArtifactURLs
        ))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        for label in [
            "Genotyping Evidence BAM",
            "Genotyping Evidence BAI",
            "Reciprocal Evidence BAM",
            "Reciprocal Evidence BAI",
        ] {
            XCTAssertFalse(lensText.contains(label))
        }
    }

    func testArtifactsLensMHCAlignmentLabelsFitWithoutClipping() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMHCAlignmentArtifactLabelLayout-\(UUID().uuidString)", isDirectory: true)
        let alignmentArtifactURLs = ONTMHCAlignmentArtifactURLs(
            genotypingBAM: bundleURL.appendingPathComponent("genotyping.bam"),
            genotypingBAI: bundleURL.appendingPathComponent("genotyping.bam.bai"),
            reciprocalBAM: bundleURL.appendingPathComponent("reciprocal.bam"),
            reciprocalBAI: bundleURL.appendingPathComponent("reciprocal.bam.bai")
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            kind: "full-length-ont-mhc-genotype",
            mhcAlignmentArtifactURLs: alignmentArtifactURLs
        ))
        controller.testingSelectLens(.audit)
        controller.view.layoutSubtreeIfNeeded()

        for label in [
            "Genotyping Evidence BAM",
            "Genotyping Evidence BAI",
            "Reciprocal Evidence BAM",
            "Reciprocal Evidence BAI",
        ] {
            let layout = try XCTUnwrap(controller.testingArtifactLabelLayout(label: label))
            XCTAssertGreaterThanOrEqual(
                layout.renderedWidth,
                layout.intrinsicWidth,
                "\(label) is clipped"
            )
        }
    }

    func testResultViewportOmitsSummaryStatisticsStripForEveryLens() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        for lens in GenotypeResultViewController.Lens.allCases {
            controller.testingSelectLens(lens)
            XCTAssertFalse(controller.testingHasSummaryStatisticsStrip)
        }
    }

    func testAnchorLensShowsDerivedAnchorSummaryAndCaveat() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_M1_A_01",
                passedAlignments: 40,
                passedUniqueReads: 40,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "02_M1_B_01",
                passedAlignments: 30,
                passedUniqueReads: 30,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingSelectLens(.summary)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertTrue(controller.testingAnchorLensText.contains("M1"))
        XCTAssertTrue(controller.testingAnchorLensText.contains("MHC-A, MHC-B"))
        XCTAssertTrue(controller.testingAnchorLensText.localizedCaseInsensitiveContains("not phased"))
    }

    func testHaplotypeLensShowsExplicitDefinitionAndReviewStatuses() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_Mafa_A1_063g"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "ERR: TMH (M1B, M2B, M3B)",
                            haplotype2: "ERR: TMH (M1B, M2B, M3B)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: ["B1", "B2", "B3", "B4"]
                        ),
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Mauritian cynomolgus macaques"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW472"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("M1A/-"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("ERR: TMH"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review in Analyst"))
    }

    func testHaplotypeLensTreatsWholeMHCHomozygoteAsSimpleDespiteMultipleDiagnosticFamilies() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: [
                                "11_M1_E_02g3",
                                "02_M1_G_02_07_2mis_156bp",
                                "04_M1_AG_05_3mis_156bp",
                                "01_M1_F_01_w_06",
                            ]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "12_M3_B_075_01",
                                "12_M3_B_079_05",
                                "12_M3_B_165_01",
                            ]
                        ),
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW474"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Simple"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("None"))
        XCTAssertFalse(controller.testingHaplotypeLensText.contains("MHC-A: called"))
        XCTAssertFalse(controller.testingHaplotypeLensText.contains("MHC-B: called"))
    }

    func testHaplotypeLensKeepsMixedFamilyHomozygoteInReview() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW-mixed",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "01_M1_F_01_w_06",
                                "02_M1_G_02_07_2mis_156bp",
                                "02_M2_G_02_06_156bp",
                            ]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW-mixed"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("MHC-A: called"))
    }

    func testOutlineRendersSingleHaplotypeHomozygoteInBothSlots() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW474").first { $0.locus == "MHC-A" })
        XCTAssertEqual(slot.h1.testingLabel, "M1A")
        XCTAssertEqual(slot.h2.testingLabel, "M1A")
    }

    func testSelectingReviewCellMarksOutlineSampleAndLocus() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M2A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M4B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["B1", "B2"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-B")

        XCTAssertEqual(controller.testingOutlineSelectedSample, "DW472")
        XCTAssertEqual(controller.testingOutlineSelectedLocus, "MHC-B")
    }

    func testRedrawOnlyDisplayChangePreservesOutlineSelectionState() throws {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test.definition",
            definitionSetName: "Test definition",
            speciesName: "Test species",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M4B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["B1", "B2"]
                        ),
                    ]
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [], haplotypeAnalysis: analysis
        ))
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-B")
        let initial = try XCTUnwrap(selection)
        XCTAssertEqual(initial.animalId, "DW472")
        XCTAssertTrue(initial.matrixTargets.isEmpty)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            layout: .listTrailing
        ))
        controller.notifySelectionStateIfAvailable()

        let retained = try XCTUnwrap(selection)
        XCTAssertEqual(retained.animalId, initial.animalId)
        XCTAssertEqual(retained.title, initial.title)
        XCTAssertEqual(retained.matrixTargets, initial.matrixTargets)
    }

    func testDisplayStateCanSwitchViewportToHaplotypes() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M3A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(viewportLens: .review))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW472"))
    }

    func testHaplotypeLensCanFocusSampleInAnalystMatrix() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M3A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )
        let call = ONTGenotypeCall(
            sample: "DW472",
            genotype: "01_Mafa_A1_063g",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [call], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        controller.testingReviewHaplotypeSample("DW472")

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_063g"])
    }

    func testConfirmingReviewCallMarksLocusResolvedAndAdvancesQueue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewConfirm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                reviewSample("DW001"),
                reviewSample("DW002"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "DW001", genotype: "12_M1_B_001_01", reads: 100),
                makeCall(sample: "DW002", genotype: "12_M1_B_001_01", reads: 100),
            ],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectCellEvidence(animalId: "DW001", locus: "MHC-B")

        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW001")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "DW001")

        controller.testingConfirmCurrentCallEvidence()

        XCTAssertEqual(controller.testingOutlineIssueCount(sample: "DW001"), 0)
        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW002")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "DW002")
        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
    }

    func testConfirmingReviewCallAdvancesWithinSameSampleBeforeNextSample() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewConfirmMultiLocus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                reviewSample("DW001", loci: ["MHC-B", "MHC-DRB"]),
                reviewSample("DW002", loci: ["MHC-B"]),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "DW001", genotype: "12_M1_B_001_01", reads: 100),
                makeCall(sample: "DW001", genotype: "13_M1_DRB_W5_01", reads: 100),
                makeCall(sample: "DW002", genotype: "12_M1_B_001_01", reads: 100),
            ],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectCellEvidence(animalId: "DW001", locus: "MHC-B")

        controller.testingConfirmCurrentCallEvidence()
        controller.testingConfirmCurrentCallEvidence()

        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-DRB" && $0.value == .confirmed
        })
        XCTAssertFalse(sidecar.callStatusFlags.contains {
            $0.sample == "DW002" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW002")
        XCTAssertEqual(controller.testingOutlineIssueCount(sample: "DW001"), 0)
    }

    private func reviewSample(
        _ sample: String,
        loci: [String] = ["MHC-B"]
    ) -> GenotypeHaplotypeSampleAnalysis {
        GenotypeHaplotypeSampleAnalysis(
            sample: sample,
            calls: loci.map { locus in
                GenotypeHaplotypeLocusCall(
                    locus: locus,
                    sourceLocus: locus == "MHC-DRB" ? "Mafa-DRB" : "Mafa-B",
                    haplotype1: locus == "MHC-DRB" ? "ERR: TMH (M1DR, M2DR, M3DR)" : "ERR: TMH (M1B, M2B, M3B)",
                    haplotype2: locus == "MHC-DRB" ? "ERR: TMH (M1DR, M2DR, M3DR)" : "ERR: TMH (M1B, M2B, M3B)",
                    status: .tooManyHaplotypes,
                    matchedHaplotypes: [],
                    observedGenotypeCount: 4,
                    observedGenotypes: locus == "MHC-DRB" ? ["DRB1", "DRB2", "DRB3", "DRB4"] : ["B1", "B2", "B3", "B4"]
                )
            }
        )
    }

    func testReviewLensUsesNeedsReviewCohortIncludingLowSupportSamples() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewNeedsReview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let lowCalls = [
            makeCall(sample: "LowSupport", genotype: "12_M3_B_075_01", reads: 2),
            makeCall(sample: "LowSupport", genotype: "12_M3_B_165_01", reads: 2),
        ]
        let okCalls = [
            makeCall(sample: "OKSample", genotype: "12_M3_B_075_01", reads: 100),
            makeCall(sample: "OKSample", genotype: "12_M3_B_165_01", reads: 80),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                calledReviewSample("LowSupport"),
                calledReviewSample("OKSample"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LowSupport",
                    passedAlignments: 10,
                    passedUniqueReads: 4,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: lowCalls
                ),
                ONTGenotypeSampleResult(
                    sample: "OKSample",
                    passedAlignments: 1_200,
                    passedUniqueReads: 1_200,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: okCalls
                ),
            ],
            calls: lowCalls + okCalls,
            haplotypeAnalysis: analysis
        ))

        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LowSupport"])
        XCTAssertEqual(controller.testingSavedCohortChipTitle, "Saved: Needs review")
    }

    func testOutlineCellSelectionShowsEvidenceWithoutActivatingNeedsReviewCohort() throws {
        let lowCalls = [
            makeCall(sample: "LowSupport", genotype: "12_M3_B_075_01", reads: 2),
            makeCall(sample: "LowSupport", genotype: "12_M3_B_165_01", reads: 2),
        ]
        let okCalls = [
            makeCall(sample: "OKSample", genotype: "12_M3_B_075_01", reads: 100),
            makeCall(sample: "OKSample", genotype: "12_M3_B_165_01", reads: 80),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                calledReviewSample("LowSupport"),
                calledReviewSample("OKSample"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LowSupport",
                    passedAlignments: 10,
                    passedUniqueReads: 4,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: lowCalls
                ),
                ONTGenotypeSampleResult(
                    sample: "OKSample",
                    passedAlignments: 1_200,
                    passedUniqueReads: 1_200,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: okCalls
                ),
            ],
            calls: lowCalls + okCalls,
            haplotypeAnalysis: analysis
        ))

        controller.testingSelectCellEvidence(animalId: "OKSample", locus: "MHC-B")

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "OKSample")
        XCTAssertNil(controller.testingSavedCohortChipTitle)
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LowSupport", "OKSample"])
    }

    func testReviewLensDoesNotAutoSelectBottomEvidence() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 120),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M1_A1_063"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "LF2823",
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: 10_000,
                sampleUniqueRetainedPercent: 1.2,
                calls: calls
            )
        ], calls: calls, haplotypeAnalysis: analysis))

        controller.testingSelectLens(.review)

        XCTAssertNil(controller.testingCurrentSelectedSample)
        XCTAssertNil(controller.testingCurrentCallEvidenceSample)
        XCTAssertTrue(controller.testingCallEvidencePaneHidden)
    }

    func testQuickSearchFiltersOutlineBySampleAndHaplotype() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 120),
            makeCall(sample: "LF2830", genotype: "05_M2_A1_031", reads: 140),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M1_A1_063"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M5A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M2_A1_031"]
                        )
                    ]
                ),
            ]
        )
        let samples = ["LF2823", "LF2830"].map { sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls.filter { $0.sample == sample }
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: calls, haplotypeAnalysis: analysis))

        controller.testingSetQuickFilterSearchText("2823")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("M2")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2830"])

        controller.testingSetQuickFilterSearchText("M1A")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])
    }

    func testReviewLensQuickSearchFiltersOutlineBySampleHaplotypeAndAllele() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M4_A1_031", reads: 120),
            makeCall(sample: "LF2830", genotype: "12_M4_B_075_01", reads: 140),
            makeCall(sample: "LF2838", genotype: "12_M3_B_075_01", reads: 160),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M4A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M4_A1_031"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M4B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M4_B_075_01"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2838",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M3_B_075_01"]
                        )
                    ]
                ),
            ]
        )
        let samples = ["LF2823", "LF2830", "LF2838"].map { sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls.filter { $0.sample == sample }
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: calls, haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        controller.testingSetQuickFilterSearchText("2823")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("M4")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823", "LF2830"])

        controller.testingSetQuickFilterSearchText("M4A")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("05_M4_A1_031")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])
    }

    func testCallEvidenceHeaderCarriesSampleReadCounts() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 60),
            makeCall(sample: "LF2823", genotype: "05_M4_A1_031", reads: 40),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["05_M1_A1_063", "05_M4_A1_031"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LF2823",
                    passedAlignments: 150,
                    passedUniqueReads: 100,
                    sampleTotalReads: 884_000,
                    sampleUniqueRetainedPercent: 0.011,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeAnalysis: analysis,
            stats: ONTGenotypeRunStats(totalInputReads: 884_000, retainedUniqueReads: 150, assignedUniqueRetainedReads: 100)
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "LF2823", locus: "MHC-A"))
        XCTAssertEqual(evidence.sampleTotalReads, 884_000)
        XCTAssertEqual(evidence.sampleFullLengthReads, 100)
        XCTAssertEqual(evidence.sampleAssignedGenotypeReads, 100)
    }

    private func calledReviewSample(_ sample: String) -> GenotypeHaplotypeSampleAnalysis {
        GenotypeHaplotypeSampleAnalysis(
            sample: sample,
            calls: [
                GenotypeHaplotypeLocusCall(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotype1: "M3B",
                    haplotype2: "-",
                    status: .called,
                    matchedHaplotypes: [],
                    observedGenotypeCount: 1,
                    observedGenotypes: ["12_M3_B_075_01"]
                )
            ]
        )
    }

    func testLocusFilterKeepsAGSeparateFromClassicalA() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "DW472",
                genotype: "01_Mafa_A1_063g|A1_063_01,_A1_063_02",
                passedAlignments: 148,
                passedUniqueReads: 148,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "DW472",
                genotype: "18_Mafa_AG_05_AG_06g|AG_05_02_01,_AG_06_04",
                passedAlignments: 204,
                passedUniqueReads: 204,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))

        XCTAssertEqual(controller.testingLocusFilterTitles, ["All Loci", "MHC-A", "MHC-AG"])
    }

    func testMatrixDefaultsToAlleleNameSort() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "02_Mafa_A2_001_01",
                passedAlignments: 300,
                passedUniqueReads: 300,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 20,
                passedUniqueReads: 20,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))

        XCTAssertEqual(controller.testingVisibleGenotypes, [
            "01_Mafa_A1_001_01",
            "02_Mafa_A2_001_01",
        ])
    }

    func testSelectingRowDoesNotBecomeLocusFilter() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 20,
                passedUniqueReads: 20,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "04_Mafa_B_001_01",
                passedAlignments: 30,
                passedUniqueReads: 30,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingSelectFirstSampleCell(sample: "AnimalA")
        controller.testingSetComparisonFilter("")

        XCTAssertEqual(controller.testingVisibleGenotypes, [
            "01_Mafa_A1_001_01",
            "04_Mafa_B_001_01",
        ])
    }

    func testComparisonMatrixExportSnapshotUsesCohortSampleColumns() {
        let matrix = GenotypeComparisonMatrixView()
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW474", genotype: "12_M3_B_075_01", reads: 119),
        ]
        matrix.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "DW472",
                passedAlignments: 148,
                passedUniqueReads: 148,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[0]]
            ),
            ONTGenotypeSampleResult(
                sample: "DW474",
                passedAlignments: 119,
                passedUniqueReads: 119,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[1]]
            ),
        ], calls: calls))

        matrix.applyCohortFilter(["DW472"])
        let snapshot = matrix.exportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            analysisName: "Example",
            lens: "summary.matrix"
        )

        XCTAssertEqual(snapshot.sampleNames, ["DW472"])
        XCTAssertEqual(snapshot.rows.first?.sampleReads, ["DW472": 148])
    }

    // MARK: - Sample column windowing

    func testGenBankMatrixDefaultsToAlleleAndOffersEveryReferenceField() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        XCTAssertFalse(matrix.testingPinnedColumnTitles.contains("Genotype"))
        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Allele"))
        XCTAssertEqual(matrix.testingReferenceValue(genotype: "NHP01222", fieldKey: "feature.allele"), "Mafa-A1*001:01")
        XCTAssertEqual(
            matrix.testingAvailableReferenceColumnTitles,
            ["Allele", "Organism", "Product", "Definition"]
        )
    }

    func testGenBankMatrixCanToggleAnyReferenceFieldAndFiltersHiddenFields() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73),
                makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41),
            ],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        matrix.testingSetReferenceColumnVisible(fieldKey: "feature.product", visible: true)
        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Product"))

        matrix.testingSetFilter("class I A1 antigen")
        XCTAssertEqual(matrix.testingVisibleGenotypes, ["NHP01222"])
    }

    func testGenBankMatrixSortsMissingReferenceValuesDeterministically() {
        let metadata = makeGenBankReferenceMetadata()
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "NHP-Z", reads: 10),
                makeCall(sample: "AnimalA", genotype: "NHP-A", reads: 10),
            ],
            referenceMetadata: ONTGenotypeReferenceMetadata(
                fields: metadata.fields,
                recordsBySequenceName: ["NHP-Z": [:], "NHP-A": [:]],
                alleleFieldKey: metadata.alleleFieldKey
            )
        ))

        XCTAssertEqual(matrix.testingVisibleGenotypes, ["NHP-A", "NHP-Z"])
    }

    func testFASTAMatrixKeepsGenotypeColumnVisible() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "FASTA_001", reads: 20)]
        ))

        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Genotype"))
        XCTAssertTrue(matrix.testingAvailableReferenceColumnTitles.isEmpty)
    }

    func testKnownRowUsesGraphicalAlleleDetailWithoutAggregateEvidence() throws {
        let rawReferenceID = "NHP01222"
        let record = makeMHCReferenceVisualizationRecord(
            rawReferenceID: rawReferenceID,
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: rawReferenceID, reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: [record])
        ))

        controller.testingSelectMatrixRows(genotypes: [rawReferenceID], sample: nil)

        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertEqual(detail.currentMode, .overview)
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: detail), "Mafa-A1*001:01")
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: detail), rawReferenceID)
        XCTAssertTrue(descendants(of: detail).compactMap { $0 as? NSTableView }.isEmpty)
        assertNoKnownAggregateEvidence(in: visibleText(in: detail))
        let state = try XCTUnwrap(selection)
        XCTAssertEqual(state.detailRows.first?.0, "Selection Type")
        XCTAssertTrue(state.detailRows.contains { $0 == ("Allele", "Mafa-A1*001:01") })
        XCTAssertTrue(state.detailRows.contains { $0 == ("Reference Sequence", rawReferenceID) })
        assertNoKnownAggregateEvidence(in: state.detailRows.map { "\($0.0) \($0.1)" }.joined(separator: "\n"))
    }

    func testReciprocalKnownRowUsingDisplayAlleleNameResolvesGraphicalRecordByAlias() throws {
        let rawReferenceID = "NHP01222"
        let displayAlleleName = "Mafa-A1*001:01"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: displayAlleleName, reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(
                    rawReferenceID: rawReferenceID,
                    alleleName: displayAlleleName
                )]
            )
        ))

        controller.testingSelectMatrixRows(genotypes: [displayAlleleName], sample: nil)

        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: detail), displayAlleleName)
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: detail), rawReferenceID)
    }

    func testSupportedKnownCellReusesGraphicalDetailAndRowClearsObservedSample() throws {
        let rawReferenceID = "NHP01222"
        let call = makeCall(sample: "AnimalA", genotype: rawReferenceID, reads: 73)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]
            )],
            calls: [call],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(rawReferenceID: rawReferenceID, alleleName: "Mafa-A1*001:01")]
            )
        ))
        controller.testingSelectMatrixRows(genotypes: [rawReferenceID], sample: nil)
        let rowDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))

        controller.testingSelectMatrixCell(genotype: rawReferenceID, sample: "AnimalA")

        let cellDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(rowDetail === cellDetail)
        XCTAssertEqual(text("knownAlleleObservedSample", in: cellDetail), "Observed in sample AnimalA")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Sample", "AnimalA") })
        assertNoKnownAggregateEvidence(in: visibleText(in: cellDetail))
        assertNoKnownAggregateEvidence(in: controller.testingCurrentSelectionDetailRows.map { $0.0 }.joined(separator: "\n"))

        controller.testingSelectMatrixRows(genotypes: [rawReferenceID], sample: nil)

        let returnedRowDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(rowDetail === returnedRowDetail)
        XCTAssertFalse(visibleText(in: returnedRowDetail).contains("Observed in sample"))
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Sample" })
    }

    func testRepeatedKnownRowAndCellSelectionsStayBoundedForLargeCohort() throws {
        let firstID = "NHP01222"
        let secondID = "NHP99999"
        let sampleNames = (0..<240).map { String(format: "Animal%03d", $0) }
        let calls = sampleNames.flatMap { sample in
            [
                makeCall(sample: sample, genotype: firstID, reads: 10),
                makeCall(sample: sample, genotype: secondID, reads: 9),
            ]
        }
        let samples = sampleNames.map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample, passedAlignments: 19, passedUniqueReads: 19,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: sampleCalls
            )
        }
        let records = [
            makeMHCReferenceVisualizationRecord(rawReferenceID: firstID, alleleName: "Mafa-A1*001:01"),
            makeMHCReferenceVisualizationRecord(rawReferenceID: secondID, alleleName: "Mafa-B*002:01"),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: samples,
            calls: calls,
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: records)
        ))
        controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)
        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        let baselineDescendantCount = descendants(of: detail).count
        let baselineContentConstraintIdentifiers = detail.testingActiveContentConstraintIdentifiers
        let baselineOverviewConfigurationCount = detail.testingOverviewConfigurationCount
        var maximumDescendantCount = baselineDescendantCount

        let start = CFAbsoluteTimeGetCurrent()
        for iteration in 0..<12 {
            controller.testingSelectMatrixCell(genotype: firstID, sample: sampleNames[0])
            controller.testingSelectMatrixRows(genotypes: [secondID], sample: nil)
            controller.testingSelectMatrixCell(genotype: secondID, sample: sampleNames[239])
            controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)
            let current = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
            XCTAssertTrue(detail === current)
            XCTAssertEqual(
                current.testingActiveContentConstraintIdentifiers,
                baselineContentConstraintIdentifiers,
                "Reconfiguring an already-visible overview must not replace its layout constraints."
            )
            XCTAssertEqual(
                current.testingOverviewConfigurationCount,
                baselineOverviewConfigurationCount + ((iteration + 1) * 2),
                "Only a changed reference allele should rebuild graphical feature lanes."
            )
            maximumDescendantCount = max(maximumDescendantCount, descendants(of: current).count)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(maximumDescendantCount, baselineDescendantCount)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
        XCTAssertLessThan(elapsed, 5, "Repeated known selections took \(elapsed) seconds")
        assertNoKnownAggregateEvidence(in: visibleText(in: detail))
    }

    func testKnownDetailIsMountedOnlyOnceAcrossKnownRowChanges() throws {
        let firstID = "NHP01222"
        let secondID = "NHP99999"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: firstID, reads: 10),
                makeCall(sample: "AnimalA", genotype: secondID, reads: 9),
            ],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeMHCReferenceVisualizationRecord(
                        rawReferenceID: firstID,
                        alleleName: "Mafa-A1*001:01"
                    ),
                    makeMHCReferenceVisualizationRecord(
                        rawReferenceID: secondID,
                        alleleName: "Mafa-B*002:01"
                    ),
                ]
            )
        ))
        controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)
        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertEqual(controller.testingKnownAlleleDetailMountCount, 1)

        controller.testingSelectMatrixRows(genotypes: [secondID], sample: nil)

        XCTAssertTrue(detail === onlyKnownAlleleDetail(in: controller.view))
        XCTAssertEqual(
            controller.testingKnownAlleleDetailMountCount,
            1,
            "Changing known rows must update the persistent detail view without remounting it."
        )
    }

    func testKnownSelectionUsesIndexedCellSupportWithoutEvidenceWorkOrReloading() async throws {
        let rawReferenceID = "NHP01222"
        let sampleNames = (0..<600).map { String(format: "Animal%03d", $0) }
        let calls = sampleNames.map {
            makeCall(sample: $0, genotype: rawReferenceID, reads: 10)
        }
        let result = makeResult(
            samples: [],
            calls: calls,
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(
                    rawReferenceID: rawReferenceID,
                    alleleName: "Mafa-A1*001:01"
                )]
            )
        )
        let loaderSpy = KnownSelectionResultLoaderSpy(result: result)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.genotypeResultLoader = { url in
            await loaderSpy.load(url)
        }
        controller.configure(result: result)
        let baseline = controller.testingKnownSelectionDiagnostics

        for _ in 0..<10 {
            controller.testingSelectMatrixCell(
                genotype: rawReferenceID,
                sample: sampleNames.last!
            )
            controller.testingSelectMatrixRows(genotypes: [rawReferenceID], sample: nil)
        }

        let diagnostics = controller.testingKnownSelectionDiagnostics
        XCTAssertEqual(
            diagnostics.indexedCellSupportLookupCount,
            baseline.indexedCellSupportLookupCount + 10
        )
        XCTAssertEqual(
            diagnostics.aggregateEvidenceHelperEntryCount,
            baseline.aggregateEvidenceHelperEntryCount
        )
        let loaderInvocationCount = await loaderSpy.currentInvocationCount()
        XCTAssertEqual(loaderInvocationCount, 0)

        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        let storedCallbacks = Mirror(reflecting: detail).children.compactMap { child -> String? in
            let typeName = String(reflecting: type(of: child.value))
            return typeName.contains("->") ? child.label ?? typeName : nil
        }
        XCTAssertTrue(
            storedCallbacks.isEmpty,
            "Known detail configuration must remain value-only, without disk/BAM/SQLite/FASTA callbacks: \(storedCallbacks)"
        )
        assertNoKnownAggregateEvidence(in: visibleText(in: detail))
        let forbiddenStateLabels: Set<String> = [
            "Support", "Samples", "Top Sample", "Unique Reads", "Alignments",
            "Support Metric", "Aggregate Samples", "Aggregate Unique Reads", "Aggregate Alignments",
        ]
        XCTAssertTrue(forbiddenStateLabels.isDisjoint(
            with: Set(controller.testingCurrentSelectionDetailRows.map(\.0))
        ))
    }

    func testLegacyKnownRowUsesFallbackMetadataAndFreshAnalysisNote() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)

        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        let detailText = visibleText(in: detail)
        XCTAssertEqual(detail.currentMode, .overview)
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: detail), "Mafa-A1*001:01")
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: detail), "NHP01222")
        XCTAssertEqual(
            text("knownAlleleFallbackNote", in: detail),
            "A fresh analysis is required to generate graphical reference records."
        )
        for value in [
            "Macaca fascicularis",
            "MHC class I A1 antigen",
            "Mafa-A1 complete coding sequence",
        ] {
            XCTAssertTrue(detailText.contains(value), "Missing GenBank value: \(value)")
        }
        assertNoKnownAggregateEvidence(in: detailText)
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Reference Sequence", "NHP01222") })
        XCTAssertTrue(rows.contains { $0 == ("Allele", "Mafa-A1*001:01") })
        XCTAssertTrue(rows.contains { $0 == ("Organism", "Macaca fascicularis") })
        XCTAssertTrue(rows.contains { $0 == ("Product", "MHC class I A1 antigen") })
        XCTAssertTrue(rows.contains { $0 == ("Definition", "Mafa-A1 complete coding sequence") })
        assertNoKnownAggregateEvidence(in: rows.map { $0.0 }.joined(separator: "\n"))

        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")

        let cellDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(detail === cellDetail)
        XCTAssertEqual(text("knownAlleleObservedSample", in: cellDetail), "Observed in sample AnimalA")
        assertNoKnownAggregateEvidence(in: visibleText(in: cellDetail))
    }

    func testSelectedFASTARowFallsBackToGenotypeWithoutGenBankSection() {
        let genotype = "01_Mafa_A1_001_01_FULL_FASTA_LABEL"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 20)]
        ))

        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)

        let detail = onlyKnownAlleleDetail(in: controller.view)
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: detail), genotype)
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: detail), genotype)
        XCTAssertEqual(
            text("knownAlleleFallbackNote", in: detail),
            "A fresh analysis is required to generate graphical reference records."
        )
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Reference Sequence" })
    }

    func testSelectedColumnShowsSampleMetricsAndOnlyVisibleSupportedAlleles() {
        let retained = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP01222", passedAlignments: 45, passedUniqueReads: 30,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 40, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        let filtered = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP99999", passedAlignments: 12, passedUniqueReads: 10,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 40, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 57, passedUniqueReads: 40,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [retained, filtered]
            )],
            calls: [retained, filtered],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSetComparisonFilter("Mafa-A1")

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Sample"))
        XCTAssertTrue(text.contains("AnimalA"))
        XCTAssertTrue(text.contains("Mafa-A1*001:01"))
        XCTAssertFalse(text.contains("Mafa-B*002:01"))
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Retained Unique Reads", "40") })
        XCTAssertTrue(rows.contains { $0 == ("Alignments", "57") })
        XCTAssertTrue(rows.contains { $0 == ("QC", "Low Support") })
        XCTAssertTrue(rows.contains { $0.0 == "Support" && $0.1 == "100.0%" })
    }

    func testSelectedColumnDetailsRefreshWhenRowFilterChanges() {
        let first = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let second = makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [first, second], referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertTrue(controller.testingDetailText.contains("Mafa-B*002:01"))

        controller.testingSetComparisonFilter("Mafa-A1")

        XCTAssertTrue(controller.testingDetailText.contains("Mafa-A1*001:01"))
        XCTAssertFalse(controller.testingDetailText.contains("Mafa-B*002:01"))
    }

    func testMultiRowSelectionPrunesHiddenNonAnchorAndAnchorRows() {
        let first = "01_Mafa_A1_KEEP_A"
        let second = "02_Mafa_A1_KEEP_B"
        let third = "03_Mafa_A1_DROP"
        let calls = [first, second, third].map { makeCall(sample: "AnimalA", genotype: $0, reads: 10) }

        let nonAnchorController = GenotypeResultViewController()
        _ = nonAnchorController.view
        nonAnchorController.configure(result: makeResult(samples: [], calls: calls))
        nonAnchorController.testingSelectMatrixRows(genotypes: [first, third, second], sample: nil)
        nonAnchorController.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(nonAnchorController.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first), .row(locus: "MHC-A", genotype: second),
        ]))
        XCTAssertFalse(nonAnchorController.testingDetailText.contains(third))

        let anchorController = GenotypeResultViewController()
        _ = anchorController.view
        anchorController.configure(result: makeResult(samples: [], calls: calls))
        anchorController.testingSelectMatrixRows(genotypes: [first, second, third], sample: nil)
        anchorController.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(anchorController.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first), .row(locus: "MHC-A", genotype: second),
        ]))
        XCTAssertTrue(anchorController.testingDetailText.contains(first))
        XCTAssertTrue(anchorController.testingDetailText.contains(second))
    }

    func testMultiCellSelectionPrunesRowsAndSamplesWhileKeepingVisibleEmptyCells() {
        let first = "01_Mafa_A1_KEEP"
        let second = "02_Mafa_A1_DROP"
        let callA = makeCall(sample: "AnimalA", genotype: first, reads: 10)
        let callB = makeCall(sample: "AnimalB", genotype: second, reads: 20)
        let samples = [
            ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 10, passedUniqueReads: 10, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [callA]),
            ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 20, passedUniqueReads: 20, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [callB]),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: [callA, callB]))
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        controller.testingClickMatrixCell(genotype: second, sample: "AnimalB", modifiers: .command)
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalB", modifiers: .command)

        controller.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalB"),
        ]))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Evidence", "No supporting reads") })

        controller.testingSetComparisonFilter("")
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        controller.testingClickMatrixCell(genotype: second, sample: "AnimalB", modifiers: .command)
        controller.testingApplyDisplayState(GenotypeResultDisplayState(matrixSampleFilterText: "AnimalB"))
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalB"),
        ])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Unique Reads", "20") })
    }

    func testMixedSelectionPrunesEveryTargetKindAcrossSequentialFilters() {
        let keep = "01_Mafa_A1_KEEP"
        let drop = "02_Mafa_A1_DROP"
        let calls = [
            makeCall(sample: "AnimalA", genotype: keep, reads: 10),
            makeCall(sample: "AnimalB", genotype: keep, reads: 20),
            makeCall(sample: "AnimalA", genotype: drop, reads: 30),
            makeCall(sample: "AnimalB", genotype: drop, reads: 40),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingClickMatrixSelectAllChiclet()
        controller.testingClickMatrixCell(genotype: keep, sample: "AnimalA", modifiers: .command)
        controller.testingClickMatrixCell(genotype: keep, sample: "AnimalB", modifiers: .command)

        controller.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: keep),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalB"),
            .column(sample: "AnimalA"),
            .column(sample: "AnimalB"),
        ]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(matrixSampleFilterText: "AnimalB"))
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: keep),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalB"),
            .column(sample: "AnimalB"),
        ]))
    }

    func testSelectedColumnSupportRefreshesWhenDenominatorChanges() {
        let selected = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SELECTED", reads: 25)
        let other = makeCall(sample: "AnimalA", genotype: "02_Mafa_A1_OTHER", reads: 75)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 200, passedUniqueReads: 200,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [selected, other]
            )],
            calls: [selected, other]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Support", "25.0%") })
        var selectionPublicationCount = 0
        controller.onSelectionStateChanged = { _ in selectionPublicationCount += 1 }

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            supportDenominator: .sampleRetained
        ))

        XCTAssertEqual(selectionPublicationCount, 1)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Support", "12.5%") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Support", "25.0%") })
    }

    func testSelectedLargeColumnPublishesEveryAlleleWithBoundedDetailSubviews() {
        let alleleCount = 1_001
        let calls = (0..<alleleCount).map { index in
            makeCall(
                sample: "AnimalA",
                genotype: String(format: "%04d_Mafa_A1_%04d", index, index),
                reads: 1
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.filter { $0.0.hasPrefix("Allele ") }.count,
            alleleCount
        )
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 12)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))
    }

    func testSelectedLargeMultiRowAndCellDetailsStayBounded() {
        let count = 1_001
        let calls = (0..<count).map { index in
            makeCall(sample: "AnimalA", genotype: String(format: "%04d_Mafa_A1_%04d", index, index), reads: index + 1)
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        let rowTargets = calls.reversed().map {
            GenotypeAnnotationSidecar.MatrixTarget.row(locus: "MHC-A", genotype: $0.genotype)
        }
        controller.testingShowMatrixTargetSelection(rowTargets)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0.hasPrefix("Allele ") }.count, count)
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 6)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))

        let cellTargets = calls.reversed().map {
            GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-A", genotype: $0.genotype, sample: "AnimalA")
        }
        controller.testingShowMatrixTargetSelection(cellTargets)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets.count, count)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0.hasPrefix("Cell ") }.count, count)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0 == "Unique Reads" }.count, count)
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 6)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))
    }

    func testSelectedColumnOmitsUnavailableSummaryMetricsWhenSampleSummaryMissing() {
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_ONLY", reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Sample", "AnimalA") })
        XCTAssertTrue(rows.contains { $0 == ("Unique Reads", "42") })
        XCTAssertFalse(rows.contains { ["Retained Unique Reads", "QC"].contains($0.0) })
        XCTAssertFalse(rows.contains { $0.0 == "Alignments" && $0.1 == "Unavailable" })
    }

    func testDuplicateCellEvidenceRowsKeepFirstRecordWithoutCrashing() {
        let genotype = "01_Mafa_A1_DUPLICATE"
        let first = makeCall(sample: "AnimalA", genotype: genotype, reads: 17)
        let duplicate = makeCall(sample: "AnimalA", genotype: genotype, reads: 91)
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(samples: [], calls: [first, duplicate]))
        _ = controller.testingVisibleGenotypes
        controller.testingShowMatrixTargetSelection([
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Locus", "MHC-A") })
        XCTAssertTrue(rows.contains { $0 == ("Unique Reads", "17") })
        XCTAssertTrue(rows.contains { $0 == ("Alignments", "17") })
        XCTAssertTrue(rows.contains { $0 == ("Support", "15.7%") })
        XCTAssertFalse(rows.contains { $0 == ("Unique Reads", "91") })
    }

    func testSelectedAlleleTieUsesRawSequenceOrdinalOrder() {
        let first = "01_Mafa_A1_Z"
        let second = "02_Mafa_A1_A"
        let fields = [
            GenBankRecordDatabase.FieldDefinition(
                key: "feature.allele", displayTitle: "Allele", valueType: "text",
                sourceCategory: "feature", preferredOrder: 0
            ),
        ]
        let metadata = ONTGenotypeReferenceMetadata(
            fields: fields,
            recordsBySequenceName: [
                first: ["feature.allele": "Mafa-A1*same"],
                second: ["feature.allele": "Mafa-A1*same"],
            ],
            alleleFieldKey: "feature.allele"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: first, reads: 10), makeCall(sample: "AnimalA", genotype: second, reads: 10)],
            referenceMetadata: metadata
        ))

        controller.testingShowMatrixTargetSelection([
            .row(locus: "MHC-A", genotype: second),
            .row(locus: "MHC-A", genotype: first),
        ])

        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.filter { $0.0 == "Reference Sequence" }.map(\.1),
            [first, second]
        )
    }

    func testSelectedMultipleRowsShowEveryAlleleAggregateAndGenBankValue() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73),
            makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41),
        ]
        controller.configure(result: makeResult(
            samples: [], calls: calls, referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222", "NHP99999"], sample: nil)

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Alleles: 2"))
        XCTAssertTrue(text.contains("Mafa-A1*001:01"))
        XCTAssertTrue(text.contains("Mafa-B*002:01"))
        XCTAssertTrue(text.contains("73"))
        XCTAssertTrue(text.contains("41"))
        XCTAssertTrue(text.contains("MHC class I A1 antigen"))
        XCTAssertTrue(text.contains("MHC class I B antigen"))
    }

    func testSelectedSupportedCellPublishesAlleleContextWithoutEvidenceMetrics() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP01222", passedAlignments: 91, passedUniqueReads: 73,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 100, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 91, passedUniqueReads: 73,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]
            )],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Sample", "AnimalA") })
        XCTAssertTrue(rows.contains { $0 == ("Allele", "Mafa-A1*001:01") })
        XCTAssertTrue(rows.contains { $0 == ("Reference Sequence", "NHP01222") })
        XCTAssertTrue(rows.contains { $0 == ("Product", "MHC class I A1 antigen") })
        XCTAssertFalse(rows.contains { ["Unique Reads", "Alignments", "Support", "Support Metric"].contains($0.0) })
    }

    func testSelectedEmptyCellShowsNoSupportingReadsWithoutZeroCounts() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]),
                ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 0, passedUniqueReads: 0, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: []),
            ],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalB")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Evidence", "No supporting reads") })
        XCTAssertFalse(rows.contains { ["Unique Reads", "Alignments", "Support", "Selected Unique", "Selected Support"].contains($0.0) })
    }

    func testSelectedMultipleCellsShowEveryAlleleSamplePairAndExactEvidence() {
        let first = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let second = makeCall(sample: "AnimalB", genotype: "NHP99999", reads: 41)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [first, second], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        let targets: [GenotypeAnnotationSidecar.MatrixTarget] = [
            .cell(locus: "MHC-NHP01222", genotype: "NHP01222", sample: "AnimalA"),
            .cell(locus: "MHC-NHP99999", genotype: "NHP99999", sample: "AnimalA"),
            .cell(locus: "MHC-NHP99999", genotype: "NHP99999", sample: "AnimalB"),
        ]
        controller.testingShowMatrixTargetSelection(targets)

        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set(targets))
        let rows = controller.testingCurrentSelectionDetailRows
        let entries = rows.split { $0.0.hasPrefix("Cell ") }
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-A1*001:01") }
                && entry.contains { $0 == ("Sample", "AnimalA") }
                && entry.contains { $0 == ("Unique Reads", "73") }
        })
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-B*002:01") }
                && entry.contains { $0 == ("Sample", "AnimalA") }
                && entry.contains { $0 == ("Evidence", "No supporting reads") }
        })
        XCTAssertTrue(entries.contains { entry in
            entry.contains { $0 == ("Allele", "Mafa-B*002:01") }
                && entry.contains { $0 == ("Sample", "AnimalB") }
                && entry.contains { $0 == ("Unique Reads", "41") }
        })
    }

    func testSelectedGenBankRowPublishesFullAlleleTitle() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)

        XCTAssertEqual(try XCTUnwrap(selection).title, "Mafa-A1*001:01")
        XCTAssertEqual(try XCTUnwrap(selection).highlightTarget?.genotype, "NHP01222")
    }

    func testSelectedMultipleColumnsShowCompactSummaryForEachSample() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMultiSampleSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]),
                ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 0, passedUniqueReads: 0, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: []),
            ],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixColumns(samples: ["AnimalA", "AnimalB"])
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Selected cohort note"
        ))

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Samples"))
        XCTAssertTrue(text.contains("AnimalA"))
        XCTAssertTrue(text.contains("AnimalB"))
        XCTAssertFalse(text.contains("Supported Alleles"))
        XCTAssertFalse(text.contains("Mafa-A1*001:01"))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Sample 1", "AnimalA") })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Sample 2", "AnimalB") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0.hasPrefix("Allele ") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Support" })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Column Comment", "Selected cohort note")
        })
    }

    func testSelectedCellIncludesApplicableRowColumnAndCellComments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSelectionComments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let call = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call])],
            calls: [call], referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Row note"))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Column note"))
        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")
        controller.addMatrixComment(.init(targets: controller.testingCurrentSelectionMatrixTargets, body: "Cell note"))

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Row Comment", "Row note") })
        XCTAssertTrue(rows.contains { $0 == ("Column Comment", "Column note") })
        XCTAssertTrue(rows.contains { $0 == ("Cell Comment", "Cell note") })
    }

    func testKnownRowAndSupportedCellShowApplicableCommentsWithoutStaleViewsOrEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KnownAlleleComments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let firstID = "NHP01222"
        let secondID = "NHP99999"
        let first = makeCall(sample: "AnimalA", genotype: firstID, reads: 73)
        let second = makeCall(sample: "AnimalA", genotype: secondID, reads: 41)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 114, passedUniqueReads: 114,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [first, second]
            )],
            calls: [first, second],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeMHCReferenceVisualizationRecord(rawReferenceID: firstID, alleleName: "Mafa-A1*001:01"),
                    makeMHCReferenceVisualizationRecord(rawReferenceID: secondID, alleleName: "Mafa-B*002:01"),
                ]
            )
        ))

        controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "First row note"
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Animal column note"
        ))
        controller.testingSelectMatrixCell(genotype: firstID, sample: "AnimalA")
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "First cell note"
        ))

        controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)

        let rowDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        let rowText = visibleText(in: rowDetail)
        XCTAssertTrue(rowText.contains("Row Comment"))
        XCTAssertTrue(rowText.contains("First row note"))
        XCTAssertFalse(rowText.contains("Animal column note"))
        XCTAssertFalse(rowText.contains("First cell note"))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Row Comment", "First row note")
        })
        assertNoKnownAggregateEvidence(in: rowText)

        controller.testingSelectMatrixCell(genotype: firstID, sample: "AnimalA")

        let cellDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(rowDetail === cellDetail)
        let cellText = visibleText(in: cellDetail)
        for text in [
            "Row Comment", "First row note",
            "Column Comment", "Animal column note",
            "Cell Comment", "First cell note",
        ] {
            XCTAssertTrue(cellText.contains(text), text)
        }
        for row in [
            ("Row Comment", "First row note"),
            ("Column Comment", "Animal column note"),
            ("Cell Comment", "First cell note"),
        ] {
            XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == row })
        }
        assertNoKnownAggregateEvidence(in: cellText)
        let cellDescendantCount = descendants(of: cellDetail).count

        controller.testingSelectMatrixRows(genotypes: [secondID], sample: nil)
        controller.addMatrixComment(.init(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Second row note"
        ))

        let replacementDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(cellDetail === replacementDetail)
        let replacementText = visibleText(in: replacementDetail)
        XCTAssertTrue(replacementText.contains("Second row note"))
        XCTAssertFalse(replacementText.contains("First row note"))
        XCTAssertFalse(replacementText.contains("Animal column note"))
        XCTAssertFalse(replacementText.contains("First cell note"))
        XCTAssertEqual(descendants(of: replacementDetail).filter {
            $0.accessibilityIdentifier().hasPrefix("knownAlleleCommentRow.")
        }.count, 1)
        XCTAssertLessThan(descendants(of: replacementDetail).count, cellDescendantCount)
        assertNoKnownAggregateEvidence(in: replacementText)
    }

    func testMixedMatrixTargetsUseGenericMixedSummary() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)]
        ))

        controller.testingShowMatrixTargetSelection([
            .row(locus: "NHP01222", genotype: "NHP01222"),
            .column(sample: "AnimalA"),
        ])

        XCTAssertTrue(controller.testingDetailText.contains("Matrix Annotation Targets"))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Selection Type", "Mixed") })
    }

    private func makeManySampleMatrix(sampleCount: Int) -> GenotypeComparisonMatrixView {
        let matrix = GenotypeComparisonMatrixView()
        let genotype = "12_M3_B_075_01"
        var calls: [ONTGenotypeCall] = []
        var samples: [ONTGenotypeSampleResult] = []
        for i in 0..<sampleCount {
            let name = String(format: "SAMPLE_%03d", i)
            let call = makeCall(sample: name, genotype: genotype, reads: 100 + i)
            calls.append(call)
            samples.append(ONTGenotypeSampleResult(
                sample: name,
                passedAlignments: 100 + i,
                passedUniqueReads: 100 + i,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            ))
        }
        matrix.configure(result: makeResult(samples: samples, calls: calls))
        return matrix
    }

    private func makeManyRowComparisonMatrix(sampleCount: Int = 2) -> GenotypeComparisonMatrixView {
        let matrix = GenotypeComparisonMatrixView()
        var calls: [ONTGenotypeCall] = []
        let sampleNames = (0..<sampleCount).map { "Sample\($0)" }
        var callsBySample = Array(repeating: [ONTGenotypeCall](), count: sampleCount)

        for index in 0..<32 {
            let genotype = String(format: "Mafa-AG*%02d:01", index)
            for (sampleIndex, sample) in sampleNames.enumerated() {
                let call = makeCall(sample: sample, genotype: genotype, reads: 100 + sampleIndex + index)
                calls.append(call)
                callsBySample[sampleIndex].append(call)
            }
        }

        let samples = sampleNames.enumerated().map { sampleIndex, sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 100 + sampleIndex,
                passedUniqueReads: 100 + sampleIndex,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: callsBySample[sampleIndex]
            )
        }
        matrix.configure(result: makeResult(samples: samples, calls: calls))
        return matrix
    }

    func testComparisonMatrixSynchronizesVerticalScrollingFromEitherPanel() throws {
        let matrix = makeManyRowComparisonMatrix()
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()
        XCTAssertEqual(matrix.testingSampleMatrixBottomChromeHeight, 0)
        let sampleScrollView = try XCTUnwrap(
            matrix.subviews.compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller }
        )
        sampleScrollView.setFrameSize(NSSize(width: 99, height: sampleScrollView.frame.height))
        sampleScrollView.tile()

        matrix.testingScrollSampleMatrix(to: NSPoint(x: 37, y: 88))

        XCTAssertEqual(matrix.testingPinnedVerticalScrollOffset, 88)
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)

        matrix.testingScrollPinnedPanel(toY: 132)

        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.y, 132)
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)
    }

    func testComparisonMatrixDisablesVerticalScrollElasticity() throws {
        let matrix = GenotypeComparisonMatrixView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = host
        host.addSubview(matrix)
        NSLayoutConstraint.activate([
            matrix.topAnchor.constraint(equalTo: host.topAnchor),
            matrix.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            matrix.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            matrix.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        window.layoutIfNeeded()
        matrix.layoutSubtreeIfNeeded()

        let scrollViews = matrix.subviews.compactMap { $0 as? NSScrollView }
        let pinnedScrollView = try XCTUnwrap(scrollViews.first { !$0.hasVerticalScroller })
        let sampleScrollView = try XCTUnwrap(scrollViews.first { $0.hasVerticalScroller })

        XCTAssertEqual(pinnedScrollView.verticalScrollElasticity, .none)
        XCTAssertEqual(sampleScrollView.verticalScrollElasticity, .none)
    }

    func testComparisonMatrixClampsRawVerticalClipOrigins() throws {
        let matrix = makeManyRowComparisonMatrix()
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()

        let scrollViews = matrix.subviews.compactMap { $0 as? NSScrollView }
        let pinnedScrollView = try XCTUnwrap(scrollViews.first { !$0.hasVerticalScroller })
        let sampleScrollView = try XCTUnwrap(scrollViews.first { $0.hasVerticalScroller })

        sampleScrollView.contentView.scroll(to: NSPoint(x: 37, y: -1_000))
        let sampleBounds = sampleScrollView.contentView.bounds
        XCTAssertEqual(
            sampleBounds.origin.y,
            sampleScrollView.contentView.constrainBoundsRect(sampleBounds).origin.y,
            accuracy: 0.001
        )
        XCTAssertEqual(sampleBounds.origin.x, 37, accuracy: 0.001)

        pinnedScrollView.contentView.scroll(to: NSPoint(x: 19, y: 9_999))
        let pinnedBounds = pinnedScrollView.contentView.bounds
        XCTAssertEqual(
            pinnedBounds.origin.y,
            pinnedScrollView.contentView.constrainBoundsRect(pinnedBounds).origin.y,
            accuracy: 0.001
        )
        XCTAssertEqual(pinnedBounds.origin.x, 19, accuracy: 0.001)
    }

    func testComparisonMatrixAlignsBottomRowsWhenSampleScrollerOccupiesBottomChrome() {
        let matrix = makeManyRowComparisonMatrix(sampleCount: 6)
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 180)
        matrix.layoutSubtreeIfNeeded()
        matrix.testingConfigureSampleMatrixLegacyHorizontalScroller()

        XCTAssertGreaterThan(matrix.testingSampleMatrixBottomChromeHeight, 0)

        matrix.testingScrollSampleMatrixToBottom(x: 37)

        let finalRow = matrix.testingVisibleRows.count - 1
        XCTAssertEqual(matrix.testingSampleMatrixScrollOffset.x, 37)
        XCTAssertEqual(
            matrix.testingPinnedRowYInMatrix(row: finalRow),
            matrix.testingSampleMatrixRowYInMatrix(row: finalRow),
            accuracy: 0.001
        )
    }

    func testComparisonMatrixShowsEverySampleColumnByDefault() {
        let matrix = makeManySampleMatrix(sampleCount: 150)
        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
    }

    func testComparisonMatrixDoesNotShowSampleLimitBanner() {
        let matrix = makeManySampleMatrix(sampleCount: 150)
        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
        XCTAssertFalse(matrix.testingColumnWindowBannerVisible)
    }

    func testComparisonMatrixSmallCohortInstantiatesAllColumns() {
        let matrix = makeManySampleMatrix(sampleCount: 40)
        XCTAssertEqual(matrix.testingSampleColumnCount, 40)
        XCTAssertFalse(matrix.testingIsColumnWindowActive)
    }

    func testComparisonMatrixPinnedPaneCanResizeAndRemembersWidth() {
        let matrix = makeManySampleMatrix(sampleCount: 4)
        matrix.frame = NSRect(x: 0, y: 0, width: 1_000, height: 400)
        matrix.testingSetPinnedPaneWidth(430)
        XCTAssertEqual(matrix.testingPinnedPaneWidth, 430, accuracy: 1)

        let restored = makeManySampleMatrix(sampleCount: 4)
        restored.frame = NSRect(x: 0, y: 0, width: 1_000, height: 400)
        restored.layoutSubtreeIfNeeded()
        XCTAssertEqual(restored.testingPinnedPaneWidth, 430, accuracy: 1)
    }

    func testComparisonMatrixExportSeesEveryVisibleSample() {
        let matrix = makeManySampleMatrix(sampleCount: 150)

        XCTAssertEqual(matrix.testingSampleColumnCount, 150)
        // The full logical set is intact.
        XCTAssertEqual(matrix.testingActiveSampleNames.count, 150)
        XCTAssertEqual(matrix.testingVisibleSampleNames.count, 150)

        // Export must include every sample, not just the windowed 60.
        let snapshot = matrix.exportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            analysisName: "Example",
            lens: "summary.matrix"
        )
        XCTAssertEqual(snapshot.sampleNames.count, 150)
        XCTAssertTrue(snapshot.sampleNames.contains("SAMPLE_120"))
        // The single shared row records reads for all 150 samples.
        XCTAssertEqual(snapshot.rows.first?.sampleReads.count, 150)
    }

    func testControllerExportSnapshotIncludesSavedFilterContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeExportContext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW474", genotype: "12_M3_B_075_01", reads: 119),
        ]
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "DW472",
                passedAlignments: 148,
                passedUniqueReads: 148,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[0]]
            ),
            ONTGenotypeSampleResult(
                sample: "DW474",
                passedAlignments: 119,
                passedUniqueReads: 119,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[1]]
            ),
        ], calls: calls))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix))

        controller.testingSetUnifiedSampleFilter("DW472")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")
        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())

        XCTAssertEqual(snapshot.sampleNames, ["DW472"])
        XCTAssertEqual(snapshot.filters["activeSmartCohortName"], "Filter: DW472")
        XCTAssertEqual(snapshot.filters["activeSmartCohortScope"], "bundle")
        XCTAssertTrue(snapshot.filters["activeSmartCohortPredicate"]?.contains("DW472") ?? false)
    }

    func testControllerExportSnapshotUsesVisibleHaplotypeMatrixRows() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())

        XCTAssertEqual(snapshot.lens, "summary.matrix.haplotypeDefinitions")
        XCTAssertTrue(snapshot.sampleNames.contains("12_M3_B_075_01"))
        XCTAssertTrue(snapshot.rows.contains { $0.genotype == "M3B" && $0.locus == "DW472 MHC-B" })
        XCTAssertFalse(snapshot.rows.contains { $0.genotype == "12_M3_B_075_01" })
    }

    func testExportRevealTargetsExportedWorkbookFile() {
        let controller = GenotypeResultViewController()
        let outputURL = URL(fileURLWithPath: "/tmp/export.xlsx")
        let result = GenotypeViewportExportResult(
            outputURL: outputURL,
            provenanceURL: outputURL.appendingPathExtension("lungfish-provenance.json")
        )

        XCTAssertEqual(controller.testingFileViewerSelectionURLs(for: result), [outputURL])
    }

    func testDisplayStateCanMoveListRightAndTop() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTrailing))

        XCTAssertTrue(controller.testingSplitIsVertical)
        XCTAssertFalse(controller.testingFirstPaneIsMatrix)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        XCTAssertFalse(controller.testingSplitIsVertical)
        XCTAssertTrue(controller.testingFirstPaneIsMatrix)
    }

    func testTopLayoutSplitMinimumsLeaveUsableViewportContent() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        let extents = controller.testingMinimumSplitExtents

        XCTAssertGreaterThanOrEqual(extents.leading, 128)
        XCTAssertGreaterThanOrEqual(extents.trailing, 100)
    }

    func testSplitMaxCoordinateReservesTrailingPaneAndDivider() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.testingApplyDisplayState(GenotypeResultDisplayState(layout: .listTop))

        let maxCoordinate = controller.testingConstrainedMaxSplitCoordinate(containerExtent: 600)

        XCTAssertEqual(
            maxCoordinate,
            600 - controller.testingSplitDividerThickness - controller.testingMinimumSplitExtents.trailing,
            accuracy: 0.5
        )
    }

    func testSupportThresholdFiltersRowsAndCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let high = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 990,
            passedUniqueReads: 990,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let low = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_002_01",
            passedAlignments: 9,
            passedUniqueReads: 9,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 1_000,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [high, low]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: true, minimumSupportPercent: 1.0))

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }

    func testMinimumReadsThresholdHidesRowsWhoseEverySupporterIsBelowThreshold() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let highRow = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_HIGH", reads: 6_000)
        let lowRow = makeCall(sample: "AnimalB", genotype: "01_Mafa_A1_LOW", reads: 1_000)
        controller.configure(result: makeResult(samples: [], calls: [highRow, lowRow]))

        // With the filter off (default 0) both rows stay visible.
        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 0))
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_HIGH", "01_Mafa_A1_LOW"])

        // At 5,000 the low-support row drops because its only supporter has 1,000 reads.
        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 5_000))
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_HIGH"])
    }

    func testMinimumReadsThresholdKeepsRowWithAtLeastOneSupporterAboveThreshold() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        // One shared genotype supported by a strong sample and a weak sample.
        let strong = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SHARED", reads: 6_000)
        let weak = makeCall(sample: "AnimalB", genotype: "01_Mafa_A1_SHARED", reads: 1_000)
        controller.configure(result: makeResult(samples: [], calls: [strong, weak]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(hideLowSupport: false, minimumReads: 5_000))

        // The row survives because at least one supporter clears the threshold.
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_SHARED"])
    }

    func testFilteredSampleCellsCanHideManualRowHighlights() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let sharedGenotype = "01_Mafa_A1_001_01"
        let denominatorGenotype = "02_Mafa_A2_001_01"
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: sharedGenotype,
                passedAlignments: 5,
                passedUniqueReads: 5,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 1_000,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalB",
                genotype: sharedGenotype,
                passedAlignments: 100,
                passedUniqueReads: 100,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 100,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: denominatorGenotype,
                passedAlignments: 995,
                passedUniqueReads: 995,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 1_000,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: GenotypeResultHighlightTarget(genotype: sharedGenotype, locus: "MHC-A"),
            scope: .selectedRow,
            channel: .fill,
            color: AnnotationColor(red: 0.9, green: 0.2, blue: 0.7, alpha: 1.0)
        ))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            hideLowSupport: true,
            minimumSupportPercent: 1.0,
            hideFilteredHighlights: true
        ))

        XCTAssertNil(controller.testingBackgroundColor(genotype: sharedGenotype, sample: "AnimalA"))
        XCTAssertNotNil(controller.testingBackgroundColor(genotype: sharedGenotype, sample: "AnimalB"))
    }

    func testMatrixSearchMatchesImportedSampleMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort
        AnimalA\ttreated
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))
        controller.testingSetComparisonFilter("treated")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }

    func testUnifiedMatrixFilterAppliesGenotypeTextAsRowFilter() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "04_Mafa_B_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        controller.configure(result: makeResult(samples: [], calls: calls))

        controller.testingSetUnifiedSampleFilter("MHC-B")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
    }

    func testQuickSearchTreatsGenotypeTextAsMatrixRowFilterWithoutSampleColumnNarrowing() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
            makeCall(sample: "AnimalB", genotype: "04_Mafa_B_001_01", reads: 42),
        ]
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[0]]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[1]]
            ),
        ], calls: calls))

        XCTAssertEqual(Set(controller.testingVisibleGenotypes), Set(["01_Mafa_A1_001_01", "04_Mafa_B_001_01"]))
        controller.testingSetUnifiedSampleFilter("MHC-B")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])

        controller.testingSetUnifiedSampleFilter("AnimalB")
        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
    }

    func testUnifiedMatrixFilterMatchesMetadataFieldQueries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort
        AnimalA\ttreated
        AnimalB\tcontrol
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalB",
                genotype: "02_Mafa_A2_001_01",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: calls))

        controller.testingSetUnifiedSampleFilter("Cohort=treated")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }

    func testApplyingImportedSampleMetadataRefreshesExistingMatrixSearch() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSetComparisonFilter("treated")
        XCTAssertTrue(controller.testingVisibleGenotypes.isEmpty)

        let metadata = Data("""
        Sample\tCohort
        AnimalA\ttreated
        """.utf8)
        let store = try SampleMetadataStore(csvData: metadata, knownSampleIds: ["AnimalA"])
        controller.applySampleMetadataStore(store)

        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_001_01"])
    }

    func testUnifiedSampleFilterMatchesImportedMetadataFieldsInOutline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort\tAnimal Type
        AnimalA\ttreated\tcase
        AnimalB\tcontrol\tcontrol
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalA",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["A1"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "AnimalB",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["A2"]
                        )
                    ]
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))

        controller.testingSetUnifiedSampleFilter("Cohort=treated")

        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["AnimalA"])
    }

    func testSaveCurrentFilterPersistsMetadataSmartCohortWithAudit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: []))
        controller.testingSetUnifiedSampleFilter("Cohort=Kenyon20")

        try controller.testingSaveCurrentFilterAsSmartCohort()

        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        let saved = sidecar.smartCohorts.first { $0.name == "Filter: Cohort=Kenyon20" }
        XCTAssertEqual(saved?.predicate, .metadataFieldContains(field: "Cohort", value: "Kenyon20"))
        XCTAssertTrue(sidecar.auditLog.contains { $0.action == "saveSmartCohort" && $0.after?.contains("Cohort=Kenyon20") == true })
    }

    func testSavedTextFilterRoundTripsAsMatrixRowFilter() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedTextFilter-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
            makeCall(sample: "AnimalA", genotype: "04_Mafa_B_001_01", reads: 42),
        ]
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: calls))
        controller.testingSetUnifiedSampleFilter("MHC-B")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
    }

    func testScopedSaveCurrentFilterOnlyMutatesMatchingWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleA = root.appendingPathComponent("a.lungfishgenotype", isDirectory: true)
        let bundleB = root.appendingPathComponent("b.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleB, withIntermediateDirectories: true)
        let scopeA = WindowStateScope()
        let scopeB = WindowStateScope()
        let controllerA = GenotypeResultViewController()
        let controllerB = GenotypeResultViewController()
        controllerA.windowStateScope = scopeA
        controllerB.windowStateScope = scopeB
        _ = controllerA.view
        _ = controllerB.view
        controllerA.configure(result: makeResult(bundleURL: bundleA, samples: [], calls: []))
        controllerB.configure(result: makeResult(bundleURL: bundleB, samples: [], calls: []))
        controllerA.testingSetUnifiedSampleFilter("Cohort=Kenyon20")
        controllerB.testingSetUnifiedSampleFilter("Cohort=Control")

        NotificationCenter.default.post(
            name: .genotypeResultSmartCohortSaveRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: scopeA]
        )

        let sidecarA = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleA)
        let sidecarB = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleB)
        XCTAssertTrue(sidecarA.smartCohorts.contains { $0.name == "Filter: Cohort=Kenyon20" })
        XCTAssertFalse(sidecarB.smartCohorts.contains { $0.name == "Filter: Cohort=Control" })
    }

    func testOutlineLayoutLeavesViewportVisibleBelowQuickFilterBar() throws {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M2A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_500, height: 900)
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .outline, layout: .listTop))

        controller.view.layoutSubtreeIfNeeded()

        let quickFilterBar = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeQuickFilterBarView.self))
        let outlineView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeOutlineView.self))
        XCTAssertLessThanOrEqual(quickFilterBar.frame.height, 72)
        XCTAssertGreaterThan(outlineView.frame.height, 200)
    }

    func testMatrixViewShowsDiagnosticGenotypesUsedForHaplotypeDefinitions() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03", reads: 123),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M2B",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_098_05", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04", "12_M2_B_150_01_01", "12_M2_B_162"],
                                    observedDiagnosticAlleles: ["12_M2_B_019_03"]
                                ),
                            ],
                            observedGenotypeCount: 3,
                            observedGenotypes: ["12_M2_B_019_03", "12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let text = controller.testingHaplotypeMatrixText

        XCTAssertTrue(text.contains("Diagnostic allele matrix"))
        XCTAssertTrue(text.contains("DW472"))
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        XCTAssertTrue(text.contains("12_M3_B_098_05 [not observed]"))
        XCTAssertTrue(text.contains("M2B"))
        XCTAssertTrue(text.contains("12_M2_B_019_03"))
    }

    func testWeakHaplotypeSlotIsTintedBelowFivePercent() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 3),
        ]
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertTrue(slot.h2.testingIsWeakSupport)
    }

    func testWeakHaplotypeTintUsesSameColorAtHalfOpacity() throws {
        let view = GenotypeHaplotypeTapeView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        view.appearance = NSAppearance(named: .aqua)
        let tokenIndex = HaplotypeColorToken.assigned(forName: "M2B").canonicalIndex
        let referenceColor = try XCTUnwrap(
            view.testingFillColor(for: .reference(tokenIndex: tokenIndex, label: "M2B"))?.testingSRGBComponents
        )
        let weakColor = try XCTUnwrap(
            view.testingFillColor(for: .weakReference(tokenIndex: tokenIndex, label: "M2B"))?.testingSRGBComponents
        )

        XCTAssertEqual(weakColor.red, referenceColor.red, accuracy: 0.001)
        XCTAssertEqual(weakColor.green, referenceColor.green, accuracy: 0.001)
        XCTAssertEqual(weakColor.blue, referenceColor.blue, accuracy: 0.001)
        XCTAssertEqual(weakColor.alpha, 0.5, accuracy: 0.001)
    }

    func testWeakHaplotypeSlotIsTintedBelowFiveReads() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 20),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 4),
        ]
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertTrue(slot.h2.testingIsWeakSupport)
    }

    func testManualHaplotypeSlotRestoresFullOpacity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultWeakSupport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-23T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h2,
                originalCall: "M2B",
                overrideCall: "M2B",
                reasonTag: .analystJudgment,
                rationale: "Manual review accepted the low-read call.",
                author: "test",
                timestamp: "2026-06-23T00:00:01Z"
            )
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M1_B_001_01", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M2_B_001_01", reads: 3),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: makeWeakSupportAnalysis(
                h1: "M1B",
                h2: "M2B",
                h1Allele: "12_M1_B_001_01",
                h2Allele: "12_M2_B_001_01"
            )
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })

        XCTAssertFalse(slot.h1.testingIsWeakSupport)
        XCTAssertFalse(slot.h2.testingIsWeakSupport)
    }

    func testObservedOnlyLociDoesNotActivateMatrixView() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
            makeCall(sample: "DW472", genotype: "04_M3_AG_04g1_156bp", reads: 100),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            layout: .listTop,
            showsAncillaryLoci: true
        ))

        let haplotypeMatrix = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        let sharedMatrix = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeComparisonMatrixView.self))

        XCTAssertTrue(haplotypeMatrix.isHidden)
        XCTAssertTrue(sharedMatrix.isHidden)
        XCTAssertTrue(controller.testingVisibleOutlineSamples.contains("DW472"))
    }

    func testHaplotypeDefinitionMatrixHeadersExposeSortDescriptors() throws {
        let view = GenotypeHaplotypeDefinitionMatrixView()
        view.configure(rows: [
            GenotypeHaplotypeDefinitionMatrixView.Row(
                sample: "DW472",
                locus: "MHC-B",
                callName: "M3B",
                haplotypeName: "M3B",
                observedCount: 2,
                diagnosticCount: 3,
                minimumMatches: 2,
                status: .called,
                alleles: [GenotypeHaplotypeDefinitionMatrixView.DiagnosticAllele(name: "12_M3_B_075_01", reads: 100)]
            ),
            GenotypeHaplotypeDefinitionMatrixView.Row(
                sample: "DW472",
                locus: "MHC-A",
                callName: "M1A",
                haplotypeName: "M1A",
                observedCount: 1,
                diagnosticCount: 4,
                minimumMatches: 2,
                status: .candidate,
                alleles: [GenotypeHaplotypeDefinitionMatrixView.DiagnosticAllele(name: "01_M1_F_01_w_06", reads: 30)]
            ),
        ], definitionName: "Test")

        let table = try XCTUnwrap(view.firstDescendant(ofType: NSTableView.self))
        XCTAssertTrue(table.tableColumns.allSatisfy { $0.sortDescriptorPrototype != nil })
    }

    func testHaplotypeMatrixSearchFiltersDefinitionRowsRatherThanWholeSamples() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: ["01_M1_F_01_w_06"],
                                    observedDiagnosticAlleles: ["01_M1_F_01_w_06"]
                                ),
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        controller.testingSetUnifiedSampleFilter("MHC-B")

        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        let matrixView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        XCTAssertTrue(matrixView.isHidden)
    }

    func testHaplotypeMatrixUsesSavedTextFilterWhenQuickSearchIsCleared() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSavedMatrixFilter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: ["01_M1_F_01_w_06"],
                                    observedDiagnosticAlleles: ["01_M1_F_01_w_06"]
                                ),
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"],
                                    observedDiagnosticAlleles: ["12_M3_B_075_01", "12_M3_B_165_01"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        controller.testingSetUnifiedSampleFilter("MHC-B")
        try controller.testingSaveCurrentFilterAsSmartCohort()
        controller.testingSetUnifiedSampleFilter("")

        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("MHC-B"))
        XCTAssertTrue(text.contains("M3B"))
        XCTAssertTrue(text.contains("12_M3_B_075_01"))
        let matrixView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        XCTAssertTrue(matrixView.isHidden)
    }

    func testSavingActiveHaplotypeDefinitionRefreshesLiveCalls() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeActiveDefinition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.active-definition"
        let store = HaplotypeDefinitionStore(projectRoot: projectRoot)
        try store.save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "OldB",
            diagnosticAllele: "12_M8_B_001_01"
        ))
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeDefinitionSetID: definitionID
        ))
        XCTAssertEqual(controller.callEvidence(sample: "DW472", locus: "MHC-B")?.h1Name, "ERR: NO HAP")

        try controller.testingSaveHaplotypeDefinition(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "NewB")
        XCTAssertEqual(evidence.status, .called)
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))
        XCTAssertTrue(controller.testingHaplotypeMatrixText.contains("NewB"))
        XCTAssertFalse(controller.testingHaplotypeMatrixText.contains("OldB"))
    }

    func testGenotypeOnlyResultUsesRawMatrixEvenWithResolvedDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeOnlyRawMatrixDefinition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.raw-matrix-definition"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
        ))
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeDefinitionSetID: definitionID
        ))

        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertFalse(controller.testingComparisonMatrixIsHidden)
        let definitionMatrix = try XCTUnwrap(
            controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self)
        )
        XCTAssertTrue(definitionMatrix.isHidden)
    }

    func testAIHaplotypingCompletionResetsGenotypeOnlyMatrixDefaultToOutline() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        controller.configure(result: makeResult(samples: [], calls: calls))
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)

        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "ai-provisional:test",
            definitionSetName: "AI provisional",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M9B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_001_01"]
                        )
                    ]
                )
            ]
        )

        controller.applyAIHaplotypingCompleted(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis
        ))

        XCTAssertEqual(controller.testingSummaryViewMode, .outline)
        XCTAssertFalse(controller.testingLensControlIsHidden)
        XCTAssertEqual(controller.testingContentHostTopInset, 48)

        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
    }

    func testHaplotypedBundleRemembersGenotypeMatrixSummaryPreference() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSummaryPreference-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "mcm-test",
            definitionSetName: "MCM test",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M9B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_001_01"]
                        )
                    ]
                )
            ]
        )
        let result = makeResult(bundleURL: bundleURL, samples: [], calls: calls, haplotypeAnalysis: analysis)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        XCTAssertEqual(controller.testingSummaryViewMode, .outline)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix))
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        XCTAssertEqual(sidecar.settings.preferredSummaryViewMode, GenotypeSummaryViewMode.matrix.rawValue)

        let restored = GenotypeResultViewController()
        _ = restored.view
        restored.configure(result: result)

        XCTAssertEqual(restored.testingSummaryViewMode, .matrix)
    }

    func testUsingCustomHaplotypeDefinitionPersistsActiveDefinitionAndRefreshesCalls() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeUseDefinition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.use-definition"
        let customDefinition = makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "NewB",
            diagnosticAllele: "12_M9_B_001_01"
        )
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(customDefinition)
        let calls = [makeCall(sample: "DW472", genotype: "12_M9_B_001_01", reads: 150)]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "DW472",
                    passedAlignments: 150,
                    passedUniqueReads: 150,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))
        XCTAssertNotEqual(controller.callEvidence(sample: "DW472", locus: "MHC-B")?.h1Name, "NewB")

        try controller.testingUseHaplotypeDefinition(id: definitionID)

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "NewB")
        XCTAssertEqual(evidence.status, .called)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        XCTAssertEqual(sidecar.settings.activeHaplotypeDefinitionSetID, definitionID)
        XCTAssertEqual(sidecar.settings.activeHaplotypeAssayID, "custom-assay")
        XCTAssertTrue(sidecar.auditLog.contains { entry in
            entry.action == "updateSettings" && (entry.after?.contains(definitionID) ?? false)
        })
        let definitionURL = try XCTUnwrap(HaplotypeDefinitionStore(projectRoot: projectRoot).definitionURL(for: definitionID))
        let snapshot = try XCTUnwrap(controller.testingCurrentExportSnapshot())
        XCTAssertTrue(snapshot.provenanceInputURLs.contains(definitionURL))
        XCTAssertEqual(snapshot.filters["activeHaplotypeDefinitionSetID"], definitionID)
        XCTAssertEqual(snapshot.filters["activeHaplotypeAssayID"], "custom-assay")
    }

    func testReviewEvidenceIncludesCrossFamilyMCMClassIDiagnostics() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW474", genotype: "01_M1_F_01_w_06", reads: 200),
            makeCall(sample: "DW474", genotype: "02_M1_G_02_07_2mis_156bp", reads: 180),
            makeCall(sample: "DW474", genotype: "04_M1_AG_05_3mis_156bp", reads: 160),
            makeCall(sample: "DW474", genotype: "14_M2_DQA1_01_04", reads: 140),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1A",
                                    diagnosticAlleles: [
                                        "01_M1_F_01_w_06",
                                        "02_M1_G_02_07_2mis_156bp",
                                        "04_M1_AG_05_3mis_156bp",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "01_M1_F_01_w_06",
                                        "02_M1_G_02_07_2mis_156bp",
                                        "04_M1_AG_05_3mis_156bp",
                                    ]
                                )
                            ],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "01_M1_F_01_w_06",
                                "02_M1_G_02_07_2mis_156bp",
                                "04_M1_AG_05_3mis_156bp",
                            ]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW474", locus: "MHC-A"))
        let alleles = evidence.diagnosticAlleles.map(\.allele)
        XCTAssertTrue(alleles.contains("01_M1_F_01_w_06"))
        XCTAssertTrue(alleles.contains("02_M1_G_02_07_2mis_156bp"))
        XCTAssertTrue(alleles.contains("04_M1_AG_05_3mis_156bp"))
        XCTAssertFalse(alleles.contains("14_M2_DQA1_01_04"))
    }

    func testReviewEvidenceUsesObservedGenotypeHeaderForAnimalGenotypeDisplay() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let enrichedHeader = "MCM_MHC_MiSeq_0073|source_loci=MHC-B|haplotypes=M1B|alleles=Mafa-B_073:01:01:01|evidence_classes=primary_expressed"
        let calls = [
            makeCall(sample: "LF2830", genotype: enrichedHeader, reads: 66),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M1B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M1B",
                                    diagnosticAlleles: ["MCM_MHC_MiSeq_0073"],
                                    observedDiagnosticAlleles: ["MCM_MHC_MiSeq_0073"]
                                )
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: [enrichedHeader]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: calls, haplotypeAnalysis: analysis))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "LF2830", locus: "MHC-B"))
        XCTAssertEqual(evidence.animalGenotypes.first?.genotype, enrichedHeader)
        XCTAssertEqual(
            GenotypeCallEvidenceView.AlleleLabel(evidence.animalGenotypes.first?.genotype ?? "").primary,
            "Mafa-B*073:01:01:01"
        )
    }

    func testConfigureRendersHaplotypeCallFromRecordedAnalysisInOutline() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M2_B_019_03", reads: 400),
            makeCall(sample: "DW472", genotype: "12_M2_B_109_04", reads: 300),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M2B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04"],
                                    observedDiagnosticAlleles: ["12_M2_B_019_03", "12_M2_B_109_04"]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M2_B_019_03", "12_M2_B_109_04"]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })
        XCTAssertEqual(slot.h1.testingLabel, "M2B")
    }

    func testIncludedLociFilterOutlineAndCurrentWorkbookCalls() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "mcm-mhc-miseq",
            definitionSetID: "mcm-mhc-miseq-primary",
            definitionSetName: "MCM MHC MiSeq",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2832",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M1A-read"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-E",
                            sourceLocus: "MHC-E",
                            haplotype1: "M2E",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M2E-read"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "MHC-DRB",
                            haplotype1: "M3DR",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M3DR-read"]
                        ),
                    ]
                ),
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        XCTAssertEqual(controller.testingOutlineSlots(sample: "LF2832").map(\.locus), ["MHC-A", "MHC-DRB"])
        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls().map(\.locus), ["MHC-A"])

        controller.testingApplyDisplayState(GenotypeResultDisplayState(includedLoci: ["MHC-A", "MHC-E", "MHC-DRB"]))

        XCTAssertEqual(controller.testingOutlineSlots(sample: "LF2832").map(\.locus), ["MHC-A", "MHC-E", "MHC-DRB"])
        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls().map(\.locus), ["MHC-A"])
    }

    func testCurrentWorkbookSnapshotIncludesManualHaplotypeAssignments() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-22T00:00:00Z")
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "LF2832",
                locus: "MHC-A",
                slot: .h1,
                label: "Manual-M2B",
                colorTokenIndex: 2,
                diagnosticAlleles: ["M2B-read"],
                notes: "curated in GUI"
            )
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "mcm-mhc-miseq",
            definitionSetID: "mcm-mhc-miseq-primary",
            definitionSetName: "MCM MHC MiSeq",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2832",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "MHC-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["M1A-read"]
                        ),
                    ]
                ),
            ]
        )
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))

        XCTAssertEqual(controller.testingCurrentWorkbookHaplotypeCalls(), [
            GenotypeWorkbookHaplotypeCall(
                sample: "LF2832",
                locus: "MHC-A",
                haplotype1: "Manual-M2B",
                haplotype2: "-",
                status: GenotypeHaplotypeCallStatus.called.rawValue,
                notes: "curated in GUI"
            )
        ])
    }

    func testConfigureUsesPersistedHaplotypeAnalysisWhenSavedDropoutThresholdsExist() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        sidecar.settings.dropoutAbsolute = 50
        sidecar.settings.dropoutSampleFraction = nil
        sidecar.settings.dropoutLocusFraction = 0.05
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "13_M3_DRB1_10_02", reads: 1491),
            makeCall(sample: "DW472", genotype: "13_M2_DRB_W4_02", reads: 1117),
            makeCall(sample: "DW472", genotype: "13_M2_DRB1_10_01", reads: 570),
            makeCall(sample: "DW472", genotype: "13_M3_DRB_W49_01_01", reads: 153),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W21_01", reads: 5),
            makeCall(sample: "DW472", genotype: "13_M6_DRB1_04_02_01", reads: 2),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W5_01", reads: 1),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "ERR: TMH (M1DR, M2DR, M3DR)",
                            haplotype2: "ERR: TMH (M1DR, M2DR, M3DR)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DRB"))
        XCTAssertEqual(evidence.status, .tooManyHaplotypes)
        XCTAssertEqual(evidence.h1Name, "ERR: TMH (M1DR, M2DR, M3DR)")
        XCTAssertEqual(evidence.h2Name, "ERR: TMH (M1DR, M2DR, M3DR)")
    }

    func testConfigureUsesPersistedHaplotypeAnalysisWithoutSavedSidecar() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "13_M3_DRB1_10_02", reads: 1491),
            makeCall(sample: "DW472", genotype: "13_M2_DRB_W4_02", reads: 1117),
            makeCall(sample: "DW472", genotype: "13_M2_DRB1_10_01", reads: 570),
            makeCall(sample: "DW472", genotype: "13_M3_DRB_W49_01_01", reads: 153),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W21_01", reads: 5),
            makeCall(sample: "DW472", genotype: "13_M6_DRB1_04_02_01", reads: 2),
            makeCall(sample: "DW472", genotype: "13_M1_DRB_W5_01", reads: 1),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "ERR: TMH (M1DR, M2DR, M3DR)",
                            haplotype2: "ERR: TMH (M1DR, M2DR, M3DR)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DRB"))
        XCTAssertEqual(evidence.status, .tooManyHaplotypes)
        XCTAssertEqual(evidence.h1Name, "ERR: TMH (M1DR, M2DR, M3DR)")
        XCTAssertEqual(evidence.h2Name, "ERR: TMH (M1DR, M2DR, M3DR)")
    }

    func testConfigureKeepsPersistedDeterministicHaplotypesWhenDefinitionIsAvailable() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.persisted-deterministic"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "M9B",
            diagnosticAllele: "12_M9_B_001"
        ))

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: definitionID,
            definitionSetName: "Custom Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "PERSISTED-B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: definitionID
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "PERSISTED-B")
        XCTAssertEqual(evidence.h2Name, "-")
    }

    func testConfigureRecomputesWhenSavedSidecarSelectsDifferentDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let activeDefinitionID = "custom.test.active-sidecar-definition"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: activeDefinitionID,
            haplotypeName: "M9B",
            diagnosticAllele: "12_M9_B_001"
        ))
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = activeDefinitionID
        sidecar.settings.activeHaplotypeAssayID = "custom-assay"
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(sidecar, forBundleAt: bundleURL)

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: "custom.test.persisted-old-definition",
            definitionSetName: "Old Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "PERSISTED-B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: "custom.test.persisted-old-definition"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "M9B")
        XCTAssertEqual(evidence.h2Name, "-")
    }

    func testCallEvidenceCarriesUnsupportedDefinitionHaplotypesForOverrideMenus() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.unsupported-menu-haplotypes"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(GenotypeHaplotypeDefinitionSet(
            id: definitionID,
            assayID: "custom-assay",
            displayName: "Custom Test Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M9B", diagnosticAlleles: ["12_M9_B_001"]),
                        GenotypeHaplotypeDefinition(name: "M10B", diagnosticAlleles: ["12_M10_B_001"]),
                    ]
                )
            ]
        ))
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_001", reads: 100),
        ]
        let persistedAnalysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: definitionID,
            definitionSetName: "Custom Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M9B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: persistedAnalysis,
            haplotypeDefinitionSetID: definitionID
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.candidateHaplotypes.map(\.name), ["M9B"])
        XCTAssertEqual(evidence.availableHaplotypeNames, ["M9B", "M10B"])

        let menuSections = GenotypeCallEvidenceView.overrideActionSections(for: .h2, evidence: evidence)
        XCTAssertEqual(menuSections.recommended.map(\.haplotypeName), ["M9B"])
        XCTAssertEqual(menuSections.unsupported.map(\.haplotypeName), ["M10B"])
    }

    func testReviewEvidenceReportsDiagnosticAllelesOmittedByRunThresholds() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let definitionID = "custom.test.threshold-omission"
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(makeCustomHaplotypeDefinitionSet(
            id: definitionID,
            haplotypeName: "M9B",
            diagnosticAlleles: ["12_M9_B_high", "12_M9_B_low"]
        ))

        let calls = [
            makeCall(sample: "DW472", genotype: "12_M9_B_high", reads: 100),
            makeCall(sample: "DW472", genotype: "12_M9_B_low", reads: 3),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "custom-assay",
            definitionSetID: definitionID,
            definitionSetName: "Custom Test Definition",
            speciesName: "Test macaque",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "ERR: NO HAP",
                            haplotype2: "ERR: NO HAP",
                            status: .noHaplotype,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M9_B_high"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: definitionID,
            stats: ONTGenotypeRunStats(
                totalInputReads: 1_000,
                retainedUniqueReads: 103,
                rawMetrics: ["minSupport": "10"]
            )
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.observedGenotypes, ["12_M9_B_high"])
        XCTAssertEqual(evidence.omittedHaplotypeGenotypes.map(\.genotype), ["12_M9_B_low"])
        XCTAssertEqual(evidence.omittedHaplotypeGenotypes.first?.reads, 3)
        XCTAssertTrue(evidence.omittedHaplotypeGenotypes.first?.reason.contains("read minimum 10") ?? false)
    }

    func testDW472bLikeMHCBReviewEvidenceReflectsRecordedHaplotypeCall() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472b", genotype: "12_M3_B_165_01", reads: 150),
            makeCall(sample: "DW472b", genotype: "12_M2_B_109_04", reads: 100),
            makeCall(sample: "DW472b", genotype: "12_M2_B_109_06", reads: 84),
            makeCall(sample: "DW472b", genotype: "12_M2_B_019_03", reads: 75),
            makeCall(sample: "DW472b", genotype: "12_M3_B_075_01", reads: 69),
            makeCall(sample: "DW472b", genotype: "12_M2_B_162", reads: 33),
            makeCall(sample: "DW472b", genotype: "12_M2_B_150_01_01", reads: 26),
            makeCall(sample: "DW472b", genotype: "12_M2M5_B_098g|B_098_01,_B_098_04", reads: 22),
            makeCall(sample: "DW472b", genotype: "12_M3_B_098_05", reads: 20),
            makeCall(sample: "DW472b", genotype: "12_M2M3_B_079g", reads: 15),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472b",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M2B",
                            haplotype2: "M3B",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2B",
                                    diagnosticAlleles: [
                                        "12_M2_B_019_03",
                                        "12_M2_B_109_04",
                                        "12_M2_B_150_01_01",
                                        "12_M2_B_162",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "12_M2_B_019_03",
                                        "12_M2_B_109_04",
                                        "12_M2_B_150_01_01",
                                        "12_M2_B_162",
                                    ]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3B",
                                    diagnosticAlleles: [
                                        "12_M3_B_075_01",
                                        "12_M3_B_098_05",
                                        "12_M3_B_165_01",
                                    ],
                                    observedDiagnosticAlleles: [
                                        "12_M3_B_075_01",
                                        "12_M3_B_098_05",
                                        "12_M3_B_165_01",
                                    ]
                                ),
                            ],
                            observedGenotypeCount: calls.count,
                            observedGenotypes: calls.map(\.genotype)
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472b", locus: "MHC-B"))
        XCTAssertEqual(evidence.status, .called)
        XCTAssertEqual(evidence.h1Name, "M2B")
        XCTAssertEqual(evidence.h2Name, "M3B")
        XCTAssertEqual(evidence.errorExplanation, "")
        XCTAssertEqual(evidence.candidateHaplotypes.first?.name, "M2B")
    }

    func testMatrixModeRendersHaplotypeDefinitionMatrixFromRecordedAnalysis() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "DW472", genotype: "13_M2_DRB_W4_02", reads: 1117),
            makeCall(sample: "DW472", genotype: "13_M2_DRB1_10_01", reads: 570),
            makeCall(sample: "DW472", genotype: "13_M3_DRB_W49_01_01", reads: 153),
            makeCall(sample: "DW472", genotype: "13_M3_DRB1_10_02", reads: 1491),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DRB",
                            sourceLocus: "Mafa-DRB",
                            haplotype1: "M2DR",
                            haplotype2: "M3DR",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M2DR",
                                    diagnosticAlleles: ["13_M2_DRB_W4_02", "13_M2_DRB1_10_01"],
                                    observedDiagnosticAlleles: ["13_M2_DRB_W4_02", "13_M2_DRB1_10_01"]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "M3DR",
                                    diagnosticAlleles: ["13_M3_DRB_W49_01_01", "13_M3_DRB1_10_02"],
                                    observedDiagnosticAlleles: ["13_M3_DRB_W49_01_01", "13_M3_DRB1_10_02"]
                                ),
                            ],
                            observedGenotypeCount: 4,
                            observedGenotypes: [
                                "13_M2_DRB1_10_01",
                                "13_M2_DRB_W4_02",
                                "13_M3_DRB1_10_02",
                                "13_M3_DRB_W49_01_01",
                            ]
                        )
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let matrixView = try XCTUnwrap(controller.view.firstDescendant(ofType: GenotypeHaplotypeDefinitionMatrixView.self))
        XCTAssertTrue(matrixView.isHidden)
        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("Diagnostic allele matrix"))
        XCTAssertTrue(text.contains("MHC-DRB"))
        XCTAssertTrue(text.contains("M2DR"))
        XCTAssertTrue(text.contains("M3DR"))
    }

    func testRhesusHaplotypeMatrixCountsOnlyClassicalReadsForClassicalAAlleles() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            makeCall(sample: "A11N094", genotype: "01_Mamu-A1_006g|A1_006_02_01_01,A1_006_03", reads: 100),
            makeCall(sample: "A11N094", genotype: "15_Mamu-AG2_01g1|A1_006_02_01_01,A1_006_03", reads: 500),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.rhesus-macaques",
            definitionSetName: "Rhesus macaques",
            speciesName: "Rhesus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "A11N094",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mamu-A",
                            haplotype1: "A006.01",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: "A006.01",
                                    diagnosticAlleles: ["A1_006"],
                                    observedDiagnosticAlleles: ["A1_006"]
                                ),
                            ],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_Mamu-A1_006g|A1_006_02_01_01,A1_006_03"]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(
            samples: [],
            calls: calls,
            haplotypeAnalysis: analysis,
            haplotypeDefinitionSetID: nil
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, layout: .listTop))

        let text = controller.testingHaplotypeMatrixText
        XCTAssertTrue(text.contains("Rhesus macaques"))
        XCTAssertTrue(text.contains("A006.01"))
        XCTAssertTrue(text.contains("A1_006 100"))
        XCTAssertFalse(text.contains("A1_006 600"))
    }

    func testNotAssayedCallsDoNotMakeClearWholeMHCHomozygote() {
        let controller = GenotypeResultViewController()

        XCTAssertFalse(controller.testingIsClearWholeMHCHomozygote(calls: [
            (
                locus: "MHC-DPB",
                h1: "Not assayed",
                h2: "Not assayed",
                status: .notAssayed,
                observedGenotypeCount: 0,
                observedGenotypes: []
            ),
        ]))
    }

    func testNotAssayedCallsAreIgnoredWhenCalledLociAreClearHomozygous() {
        let controller = GenotypeResultViewController()

        XCTAssertTrue(controller.testingIsClearWholeMHCHomozygote(calls: [
            (
                locus: "MHC-A",
                h1: "M1A",
                h2: "-",
                status: .called,
                observedGenotypeCount: 3,
                observedGenotypes: ["01_M1_F_01_w_06", "04_M1_AG_05_3mis_156bp", "11_M1_E_02g3"]
            ),
            (
                locus: "MHC-DPB",
                h1: "Not assayed",
                h2: "Not assayed",
                status: .notAssayed,
                observedGenotypeCount: 0,
                observedGenotypes: []
            ),
        ]))
    }

    func testSelectedSampleCellCanBeHighlightedFromInspectorRequest() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSelectFirstSampleCell(sample: "AnimalA")

        controller.applyHighlight(
            GenotypeResultHighlightRequest(
                target: GenotypeResultHighlightTarget(genotype: call.genotype, locus: "MHC-A", sample: "AnimalA"),
                scope: .selectedCell,
                color: AnnotationColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0)
            )
        )

        XCTAssertEqual(controller.testingHighlightedCellCount, 1)
    }

    func testSelectedSampleCellCanCarrySeparateFillAndBorderHighlights() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSelectFirstSampleCell(sample: "AnimalA")

        let target = GenotypeResultHighlightTarget(genotype: call.genotype, locus: "MHC-A", sample: "AnimalA")
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: target,
            scope: .selectedCell,
            channel: .fill,
            color: AnnotationColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0)
        ))
        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: target,
            scope: .selectedCell,
            channel: .border,
            color: AnnotationColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1.0)
        ))

        XCTAssertEqual(controller.testingHighlightedCellCount, 1)
        XCTAssertEqual(controller.testingBorderedCellCount, 1)
        XCTAssertEqual(controller.testingCurrentSelectionStyle.fillColor, AnnotationColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1.0))
        XCTAssertEqual(controller.testingCurrentSelectionStyle.borderColor, AnnotationColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1.0))

        controller.applyHighlight(GenotypeResultHighlightRequest(
            target: target,
            scope: .selectedCell,
            channel: .border,
            color: nil
        ))

        XCTAssertEqual(controller.testingHighlightedCellCount, 1)
        XCTAssertEqual(controller.testingBorderedCellCount, 0)
        XCTAssertNil(controller.testingCurrentSelectionStyle.borderColor)
    }

    func testRawMatrixCanSelectEmptyCellTarget() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_001_01"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [call]))

        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalB")

        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalB"),
        ])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Selected Sample" && $0.1 == "AnimalB"
        })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Selected Unique" })
    }

    func testMatrixStylePrecedenceCombinesRowAndColumnAndLetsCellOverride() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixStyles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A", genotype: genotype),
                style: .init(fillColor: "#FFF2CC", textColor: nil, borderColor: nil, isBold: true, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:00:00Z"
            ),
            .init(
                target: .column(sample: "AnimalA"),
                style: .init(fillColor: nil, textColor: "#C00000", borderColor: nil, isBold: false, isItalic: true),
                author: "test",
                timestamp: "2026-06-30T12:01:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
                style: .init(fillColor: "#D9EAD3", textColor: nil, borderColor: "#666666", isBold: false, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:02:00Z"
            ),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))

        let style = try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(style.fillColor?.hexString, "#D9EAD3")
        XCTAssertEqual(style.textColor?.hexString, "#C00000")
        XCTAssertEqual(style.borderColor?.hexString, "#666666")
        XCTAssertTrue(style.isBold)
        XCTAssertTrue(style.isItalic)
    }

    func testMatrixCellStyleCanClearInheritedBold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixStyleOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A", genotype: genotype),
                style: .init(fillColor: nil, textColor: nil, borderColor: nil, isBold: true, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:00:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
                style: .init(
                    fillColor: "#D9EAD3",
                    textColor: nil,
                    borderColor: nil,
                    isBold: false,
                    isItalic: false,
                    boldOverride: false
                ),
                author: "test",
                timestamp: "2026-06-30T12:01:00Z"
            ),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))

        let style = try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(style.fillColor?.hexString, "#D9EAD3")
        XCTAssertFalse(style.isBold)
    }

    func testPerCellReadThresholdHidesCellsAndKeepsRowsWithVisibleCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 10)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        controller.configure(result: makeResult(samples: [], calls: [strong, weak]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, matrixMinimumReads: 5))

        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalA"), "10")
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalB"), "")
    }

    func testPercentThresholdCanUseSampleOrLocusDenominator() {
        let genotype = "01_Mafa_A1_LOW"
        let low = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: genotype,
            passedAlignments: 4,
            passedUniqueReads: 4,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let high = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_HIGH",
            passedAlignments: 20,
            passedUniqueReads: 20,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 24,
                passedUniqueReads: 100,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [low, high]
            ),
        ], calls: [low, high]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            matrixMinimumPercent: 10,
            matrixPercentDenominator: .sampleRetained
        ))
        XCTAssertFalse(controller.testingVisibleGenotypes.contains(genotype))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            summaryViewMode: .matrix,
            matrixMinimumPercent: 10,
            matrixPercentDenominator: .viewedLocus
        ))
        XCTAssertTrue(controller.testingVisibleGenotypes.contains(genotype))
    }

    func testSupportedCellSelectionHelperSkipsEmptyCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 2,
                passedUniqueReads: 2,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalC",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [strong, weak]))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalC")

        let targets = controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 5)

        XCTAssertEqual(targets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ))
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, targets)
        controller.addMatrixComment(GenotypeMatrixCommentEditRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Supported cell remains selected."
        ))
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, targets)
    }

    func testSupportedCellSelectionHelperStaysScopedToSelectedRow() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_A1_SECOND"
        let firstStrong = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let firstWeak = makeCall(sample: "AnimalB", genotype: first, reads: 2)
        let secondStrong = makeCall(sample: "AnimalB", genotype: second, reads: 7)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstStrong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstWeak, secondStrong]
            ),
        ], calls: [firstStrong, firstWeak, secondStrong]))

        controller.testingSelectMatrixRows(genotypes: [first], sample: nil)
        let targets = controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 5)

        XCTAssertEqual(targets, [
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
        ])
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: first, sample: "AnimalB"))
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: second, sample: "AnimalB"))
    }

    func testSupportedCellSelectionHelperWorksAfterRowChicletSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixSupportedChiclet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        let unrelated = makeCall(sample: "AnimalB", genotype: "02_Mafa_A1_SECOND", reads: 9)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 11,
                passedUniqueReads: 11,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak, unrelated]
            ),
        ], calls: [strong, weak, unrelated]))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .row(locus: "MHC-A", genotype: genotype),
        ])

        let targets = controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 5)
        XCTAssertEqual(targets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, targets)

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor?.hexString, "#33994C")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).fillColor)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: "02_Mafa_A1_SECOND", sample: "AnimalB")).fillColor)
    }

    func testSupportedCellSelectionHelperClearsRowSelectionWhenNoCellsPassThreshold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixSupportedNone-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let weak = makeCall(sample: "AnimalA", genotype: genotype, reads: 1)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 1,
                passedUniqueReads: 1,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
        ], calls: [weak]))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        let targets = controller.testingSelectSupportedCellsInSelectedRow(minimumReads: 5)

        XCTAssertEqual(targets, [])
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [])
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ))
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor)
    }

    func testMatrixReadThresholdPersistsAcrossLensSwitchAndReconfigure() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 10)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        let result = makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 10,
                passedUniqueReads: 10,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 2,
                passedUniqueReads: 2,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
        ], calls: [strong, weak])
        controller.configure(result: result)
        controller.testingApplyDisplayState(GenotypeResultDisplayState(summaryViewMode: .matrix, matrixMinimumReads: 5))

        controller.testingSelectLens(.audit)
        controller.testingSelectLens(.summary)
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalA"), "10")
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalB"), "")

        controller.configure(result: result)
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalA"), "10")
        XCTAssertEqual(controller.testingCellValue(genotype: genotype, sample: "AnimalB"), "")
    }

    func testMatrixSelectionDetailsDifferentiateRowsColumnsAndCells() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Selection Type" && $0.1 == "Row"
        })

        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Selection Type" && $0.1 == "Cell"
        })

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Selection Type" && $0.1 == "Column"
        })
    }

    func testMatrixExplicitSelectionChicletsAndCellClickPublishDistinctTargets() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingClickMatrixCell(genotype: genotype, sample: "AnimalA")
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))

        controller.testingClickMatrixCell(genotype: genotype, sample: "AnimalB", modifiers: .command)
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalB"),
        ]))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))

        controller.testingClickMatrixColumnChiclet(sample: "AnimalB")
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .column(sample: "AnimalB"),
        ])
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))

        controller.testingClickMatrixColumnChiclet(sample: "AnimalA", modifiers: .command)
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .column(sample: "AnimalA"),
            .column(sample: "AnimalB"),
        ]))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .row(locus: "MHC-A", genotype: genotype),
        ])
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))
    }

    func testMatrixDirectSelectionSupportsShiftRanges() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_001_01"
        let second = "02_Mafa_A1_002_01"
        let third = "03_Mafa_A1_003_01"
        let calls = [
            makeCall(sample: "AnimalA", genotype: first, reads: 6),
            makeCall(sample: "AnimalA", genotype: second, reads: 7),
            makeCall(sample: "AnimalA", genotype: third, reads: 8),
            makeCall(sample: "AnimalB", genotype: first, reads: 9),
            makeCall(sample: "AnimalB", genotype: second, reads: 10),
            makeCall(sample: "AnimalB", genotype: third, reads: 11),
        ]
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 21,
                passedUniqueReads: 21,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: Array(calls[0...2])
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 30,
                passedUniqueReads: 30,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: Array(calls[3...5])
            ),
        ], calls: calls))

        controller.testingClickMatrixRowChiclet(genotype: first)
        controller.testingClickMatrixRowChiclet(genotype: third, modifiers: .shift)
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first),
            .row(locus: "MHC-A", genotype: second),
            .row(locus: "MHC-A", genotype: third),
        ]))

        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        controller.testingClickMatrixCell(genotype: third, sample: "AnimalB", modifiers: .shift)
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalB"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalB"),
            .cell(locus: "MHC-A", genotype: third, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: third, sample: "AnimalB"),
        ]))
    }

    func testMatrixFreeTextSearchFiltersAllelesAndSamples() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: first, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: second, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSetComparisonFilter("B1")
        XCTAssertEqual(controller.testingVisibleGenotypes, [second])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])

        controller.testingSetComparisonFilter("AnimalA")
        XCTAssertEqual(controller.testingVisibleGenotypes, [first])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AnimalA"])

        controller.testingSetComparisonFilter("")
        XCTAssertEqual(Set(controller.testingVisibleGenotypes), Set([first, second]))
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
    }

    func testMatrixFreeTextSearchFiltersSampleColumnsWhenSampleNameAlsoAppearsInGenotype() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mamu_A1_AR3628_marker"
        let callA = makeCall(sample: "AR3628", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AR3629", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AR3628",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AR3629",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSetComparisonFilter("AR3628")

        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AR3628"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AR3628"])
    }

    func testUnifiedQuickFilterPrioritizesSampleColumnMatchOverGenotypeTextMatch() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mamu_A1_AR3628_marker"
        let callA = makeCall(sample: "AR3628", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AR3629", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AR3628",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AR3629",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSetQuickFilterSearchText("AR3628")

        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AR3628"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AR3628"])
    }

    func testMatrixFreeTextSearchDoesNotTreatLocusMatchAsImplicitSampleFilter() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixAmbiguousSearch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let metadataDir = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        try """
        Sample\tCohort
        AnimalA\tMHC-B review
        AnimalB\tcontrol
        """.write(to: metadataDir.appendingPathComponent("sample_metadata.tsv"), atomically: true, encoding: .utf8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let callA = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SHARED", reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: "04_Mafa_B_001_01", reads: 8)
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSetComparisonFilter("MHC-B")

        XCTAssertEqual(controller.testingVisibleGenotypes, ["04_Mafa_B_001_01"])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
    }

    func testMatrixSelectionFiltersRowsUntilCleared() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstCall]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [secondCall]
            ),
        ], calls: [firstCall, secondCall]))

        controller.testingClickMatrixRowChiclet(genotype: second)
        controller.testingShowOnlySelectedMatrixRows()

        XCTAssertEqual(controller.testingVisibleGenotypes, [second])
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])

        controller.testingClearMatrixSelectionFilter()

        XCTAssertEqual(Set(controller.testingVisibleGenotypes), Set([first, second]))
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
    }

    func testMatrixSelectionFiltersColumnsUntilCleared() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 9)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        controller.testingShowOnlySelectedMatrixColumns()

        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalB"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AnimalB"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleReadTitles, ["9"])

        controller.testingClearMatrixSelectionFilter()

        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA", "AnimalB"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleReadTitles, ["12", "9"])
    }

    func testMatrixKeepsIdentityColumnsSeparateFromScrollableSamples() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 9)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        XCTAssertEqual(controller.testingPinnedMatrixColumnTitles, ["", "Genotype", "Locus", "Samples", "Unique"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AnimalA", "AnimalB"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleReadTitles, ["12", "9"])
    }

    func testMatrixUpperLeftChicletSelectsAllVisibleRowsAndColumns() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstCall]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [secondCall]
            ),
        ], calls: [firstCall, secondCall]))

        controller.testingClickMatrixSelectAllChiclet()

        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first),
            .row(locus: "MHC-B", genotype: second),
            .column(sample: "AnimalA"),
            .column(sample: "AnimalB"),
        ]))
    }

    func testClearMatrixStyleWithAllRowsAndColumnsClearsIntersectingCellStyles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixClearAllStyles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_B_SHARED"
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-A", genotype: first),
                style: .init(fillColor: "#FFF2CC", textColor: nil, borderColor: nil, isBold: true, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:00:00Z"
            ),
            .init(
                target: .column(sample: "AnimalB"),
                style: .init(fillColor: "#D9EAD3", textColor: nil, borderColor: nil, isBold: false, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:01:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
                style: .init(fillColor: "#FF0000", textColor: nil, borderColor: nil, isBold: false, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:02:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-B", genotype: second, sample: "AnimalB"),
                style: .init(fillColor: "#B9AF1E", textColor: nil, borderColor: nil, isBold: false, isItalic: false),
                author: "test",
                timestamp: "2026-06-30T12:03:00Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
                body: "Keep this comment.",
                author: "test",
                timestamp: "2026-06-30T12:04:00Z"
            ),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let firstCall = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondCall = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstCall]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [secondCall]
            ),
        ], calls: [firstCall, secondCall]))

        controller.testingClickMatrixSelectAllChiclet()
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .clear
        ))

        let savedSidecar = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        )
        XCTAssertEqual(savedSidecar.matrixStyles, [])
        XCTAssertEqual(savedSidecar.matrixComments.count, 1)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalA")).fillColor)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalB")).fillColor)
    }

    func testMatrixRowSelectionFillAppliesOnlyCellsAtOrAboveReadThreshold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixRowThresholdStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let exact = makeCall(sample: "AnimalA", genotype: genotype, reads: 5)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 4)
        let strong = makeCall(sample: "AnimalC", genotype: genotype, reads: 8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 5,
                passedUniqueReads: 5,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [exact]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 4,
                passedUniqueReads: 4,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalC",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
        ], calls: [exact, weak, strong]))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(hex: "#FF0000")),
            minimumReads: 5
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor?.hexString, "#FF0000")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).fillColor)
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalC")).fillColor?.hexString, "#FF0000")
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalC"),
        ]))
    }

    func testMatrixColumnSelectionFillAppliesOnlyCellsAtOrAboveReadThreshold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixColumnThresholdStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_A1_SECOND"
        let firstA = makeCall(sample: "AnimalA", genotype: first, reads: 6)
        let firstB = makeCall(sample: "AnimalB", genotype: first, reads: 1)
        let secondA = makeCall(sample: "AnimalA", genotype: second, reads: 2)
        let secondB = makeCall(sample: "AnimalB", genotype: second, reads: 10)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstA, secondA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 11,
                passedUniqueReads: 11,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstB, secondB]
            ),
        ], calls: [firstA, firstB, secondA, secondB]))

        controller.testingSelectMatrixColumns(samples: ["AnimalA", "AnimalB"])
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(hex: "#00AAFF")),
            minimumReads: 5
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalA")).fillColor?.hexString, "#00AAFF")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalB")).fillColor)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalA")).fillColor)
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalB")).fillColor?.hexString, "#00AAFF")
    }

    func testMatrixThresholdedRowFillRemovesExistingBroadRowFill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixRowBroadThresholdStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 2,
                passedUniqueReads: 2,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
        ], calls: [strong, weak]))

        let rowTarget = GenotypeAnnotationSidecar.MatrixTarget.row(locus: "MHC-A", genotype: genotype)
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: [rowTarget],
            field: .fillColor(AnnotationColor(hex: "#FF0000"))
        ))
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: [rowTarget],
            field: .fillColor(AnnotationColor(hex: "#00AAFF")),
            minimumReads: 5
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor?.hexString, "#00AAFF")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).fillColor)
    }

    func testMatrixThresholdedColumnFillRemovesExistingBroadColumnFillIncludingEmptyCells() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixColumnBroadThresholdStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_A1_SECOND"
        let strong = makeCall(sample: "AnimalA", genotype: first, reads: 6)
        let weak = makeCall(sample: "AnimalA", genotype: second, reads: 2)
        let other = makeCall(sample: "AnimalB", genotype: first, reads: 8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong, weak]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [other]
            ),
        ], calls: [strong, weak, other]))

        let columnTarget = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: [columnTarget],
            field: .fillColor(AnnotationColor(hex: "#FF0000"))
        ))
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: [columnTarget],
            field: .fillColor(AnnotationColor(hex: "#00AAFF")),
            minimumReads: 5
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalA")).fillColor?.hexString, "#00AAFF")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalA")).fillColor)
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalB")).fillColor)
    }

    func testMatrixSupportThresholdPreviewOutlinesEligibleCellsForRowAndColumnSelections() {
        let genotype = "01_Mafa_A1_SHARED"
        let strong = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let weak = makeCall(sample: "AnimalB", genotype: genotype, reads: 2)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [strong]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 2,
                passedUniqueReads: 2,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [weak]
            ),
        ], calls: [strong, weak]))

        controller.testingClickMatrixRowChiclet(genotype: genotype)
        controller.testingSetMatrixSupportSelectionPreviewMinimumReads(5)

        XCTAssertTrue(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalB"))
        XCTAssertFalse(controller.testingDrawsMatrixCellSelectionFocus(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingDrawsMatrixCellSelectionFocus(genotype: genotype, sample: "AnimalB"))

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        XCTAssertFalse(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalB"))
        XCTAssertFalse(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingDrawsMatrixCellSelectionFocus(genotype: genotype, sample: "AnimalB"))

        controller.testingSetMatrixSupportSelectionPreviewMinimumReads(2)
        XCTAssertTrue(controller.testingShowsSupportSelectionPreviewBorder(genotype: genotype, sample: "AnimalB"))
    }

    func testMatrixAnnotationStyleRedrawsOnlyAffectedSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixReloadScope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_SHARED"
        let second = "02_Mafa_A1_SECOND"
        let firstA = makeCall(sample: "AnimalA", genotype: first, reads: 12)
        let secondB = makeCall(sample: "AnimalB", genotype: second, reads: 9)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [firstA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [secondB]
            ),
        ], calls: [firstA, secondB]))
        controller.testingResetMatrixReloadCounters()
        controller.testingSelectMatrixCell(genotype: first, sample: "AnimalA")
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .textColor(AnnotationColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1.0))
        ))

        XCTAssertEqual(controller.testingMatrixFullReloadCount, 0)
        XCTAssertGreaterThan(controller.testingMatrixPartialReloadCount, 0)
    }

    func testMatrixAnnotationWorkbookRefreshPreservesViewportState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixWorkbookRefreshState-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 12)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 9)
        let result = makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 12,
                passedUniqueReads: 12,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 9,
                passedUniqueReads: 9,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB])
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSetQuickFilterSearchText("AnimalA")
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(hex: "#00AAFF"))
        ))

        controller.applyCurrentWorkbookUpdateCompleted(result: result)
        controller.testingSetMatrixSupportSelectionPreviewMinimumReads(5)

        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])
        XCTAssertEqual(controller.testingVisibleMatrixSampleColumnTitles, ["AnimalA"])
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")?.fillColor?.hexString, "#00AAFF")
    }

    func testCurrentWorkbookFallbackReloadAppliesAsyncResult() async {
        let bundleURL = URL(fileURLWithPath: "/tmp/current-workbook-async.lungfishgenotype")
        let original = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(totalInputReads: 10, retainedUniqueReads: 5)
        )
        let updated = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(totalInputReads: 20, retainedUniqueReads: 9)
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: original)
        controller.genotypeResultLoader = { _ in updated }

        controller.testingReloadCurrentWorkbookResult()
        for _ in 0..<20 where controller.testingResultTotalInputReads != 20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.testingResultTotalInputReads, 20)
    }

    func testCurrentWorkbookFallbackReloadIgnoresCancelledStaleResult() async {
        let firstBundleURL = URL(fileURLWithPath: "/tmp/current-workbook-first.lungfishgenotype")
        let secondBundleURL = URL(fileURLWithPath: "/tmp/current-workbook-second.lungfishgenotype")
        let first = makeResult(bundleURL: firstBundleURL, samples: [], calls: [])
        let staleUpdate = makeResult(
            bundleURL: firstBundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(totalInputReads: 99, retainedUniqueReads: 50)
        )
        let replacement = makeResult(
            bundleURL: secondBundleURL,
            samples: [],
            calls: [],
            stats: ONTGenotypeRunStats(totalInputReads: 2, retainedUniqueReads: 1)
        )
        let loader = DeferredGenotypeResultLoader()
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: first)
        controller.genotypeResultLoader = { url in
            await loader.load(url)
        }

        controller.testingReloadCurrentWorkbookResult()
        await loader.waitUntilStarted()
        controller.configure(result: replacement)
        await loader.resume(returning: staleUpdate)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.testingResultBundleURL, secondBundleURL.standardizedFileURL)
        XCTAssertEqual(controller.testingResultTotalInputReads, 2)
    }

    func testMatrixColumnSelectionPublishesColumnTarget() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumn(sample: "AnimalB")

        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .column(sample: "AnimalB"),
        ])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Sample" && $0.1 == "AnimalB"
        })
    }

    func testMatrixColumnSelectionCanApplyStyleToMultipleColumns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixColumnStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalC",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumns(samples: ["AnimalA", "AnimalC"])
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .column(sample: "AnimalA"),
            .column(sample: "AnimalC"),
        ]))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalA"))
        XCTAssertFalse(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalB"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: genotype, sample: "AnimalC"))

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1.0))
        ))

        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(Set(sidecar.matrixStyles.map(\.target)), Set([
            .column(sample: "AnimalA"),
            .column(sample: "AnimalC"),
        ]))
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).fillColor?.hexString, "#F2BF33")
        XCTAssertNil(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).fillColor)
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalC")).fillColor?.hexString, "#F2BF33")
    }

    func testMatrixColumnSelectionDoesNotSurviveCellOrRowSelection() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .row(locus: "MHC-A", genotype: genotype),
        ])
    }

    func testMatrixColumnSelectionClearsWhenSampleFilterHidesSelectedColumn() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))

        controller.testingSelectMatrixColumn(sample: "AnimalB")
        controller.testingApplyDisplayState(GenotypeResultDisplayState(matrixSampleFilterText: "AnimalA"))

        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [])
    }

    func testMatrixAnnotationStyleRequestPersistsAndRenders() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixApplyStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1.0))
        ))
        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .isBold(true)
        ))

        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.matrixStyles.count, 1)
        XCTAssertEqual(sidecar.matrixStyles.first?.style.fillColor, "#33994C")
        XCTAssertEqual(sidecar.matrixStyles.first?.style.isBold, true)
        let style = try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(style.fillColor?.hexString, "#33994C")
        XCTAssertTrue(style.isBold)
    }

    func testMatrixAnnotationDarkFillRendersFullDepthWithWhiteText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixDarkFillStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [call]))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(hex: "#0C0000"))
        ))

        let style = try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA"))
        XCTAssertEqual(style.fillColor?.hexString, "#0C0000")
        XCTAssertEqual(style.textColor?.hexString, "#FFFFFF")
        let background = try XCTUnwrap(controller.testingBackgroundColor(genotype: genotype, sample: "AnimalA"))
        let components = try XCTUnwrap(background.testingSRGBComponents)
        XCTAssertEqual(components.red, 12.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(components.green, 0, accuracy: 0.01)
        XCTAssertEqual(components.blue, 0, accuracy: 0.01)
        XCTAssertEqual(components.alpha, 1, accuracy: 0.01)
    }

    func testMatrixAnnotationStyleRequestAppliesToMultipleSelectedCells() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixApplyMultiStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let first = "01_Mafa_A1_001_01"
        let second = "02_Mafa_A1_002_01"
        let calls = [
            makeCall(sample: "AnimalA", genotype: first, reads: 42),
            makeCall(sample: "AnimalA", genotype: second, reads: 21),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: calls))
        controller.testingSelectMatrixRows(genotypes: [first, second], sample: "AnimalA")

        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: first, sample: "AnimalA"))
        XCTAssertTrue(controller.testingIsSelectedMatrixCell(genotype: second, sample: "AnimalA"))

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .fillColor(AnnotationColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1.0))
        ))
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))
        controller.addMatrixComment(GenotypeMatrixCommentEditRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Review both calls."
        ))
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))

        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.matrixStyles.count, 2)
        XCTAssertEqual(sidecar.matrixComments.count, 2)
        XCTAssertEqual(Set(sidecar.matrixStyles.map(\.target)), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))
        XCTAssertEqual(Set(sidecar.matrixComments.map(\.target)), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalA"),
        ]))
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: first, sample: "AnimalA")).fillColor?.hexString, "#F2BF33")
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: second, sample: "AnimalA")).fillColor?.hexString, "#F2BF33")
    }

    func testMatrixRowSelectionCanApplyTextColorAcrossEntireRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixRowTextStyle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_SHARED"
        let callA = makeCall(sample: "AnimalA", genotype: genotype, reads: 6)
        let callB = makeCall(sample: "AnimalB", genotype: genotype, reads: 8)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 6,
                passedUniqueReads: 6,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callA]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 8,
                passedUniqueReads: 8,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [callB]
            ),
        ], calls: [callA, callB]))
        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)

        controller.applyMatrixStyle(GenotypeMatrixStyleRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            field: .textColor(AnnotationColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1.0))
        ))

        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalA")).textColor?.hexString, "#1933CC")
        XCTAssertEqual(try XCTUnwrap(controller.testingRenderedMatrixStyle(genotype: genotype, sample: "AnimalB")).textColor?.hexString, "#1933CC")
    }

    func testMatrixCommentsPersistAndAppearInSelectionDetails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMatrixComment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let genotype = "01_Mafa_A1_001_01"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "AnimalA",
                passedAlignments: 42,
                passedUniqueReads: 42,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            ),
            ONTGenotypeSampleResult(
                sample: "AnimalB",
                passedAlignments: 0,
                passedUniqueReads: 0,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: []
            ),
        ], calls: [call]))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalB")

        controller.addMatrixComment(GenotypeMatrixCommentEditRequest(
            targets: controller.testingCurrentSelectionMatrixTargets,
            body: "Expected but missing."
        ))

        let sidecarURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let sidecar = try GenotypeAnnotationSidecar.decode(Data(contentsOf: sidecarURL))
        XCTAssertEqual(sidecar.matrixComments.map(\.body), ["Expected but missing."])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Cell Comment" && $0.1 == "Expected but missing."
        })
    }

    func testSharedGenotypeDetailContentIsAnchoredAtTopOfDetailPane() {
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 100,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )

        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(controller.testingDetailContentTopInset, 24)
    }

    func testConfigureRetainedDemuxSizedBundleDoesNotBlockViewportLoad() {
        let controller = GenotypeResultViewController()
        _ = controller.view

        var calls: [ONTGenotypeCall] = []
        for sampleIndex in 0..<52 {
            let sample = "LF\(2800 + sampleIndex)"
            for genotypeIndex in 0..<120 {
                let locus = genotypeIndex.isMultiple(of: 2) ? "A1" : "DQB1"
                calls.append(ONTGenotypeCall(
                    sample: sample,
                    genotype: String(format: "%02d_Mafa_%@_%03d_01", genotypeIndex % 20, locus, genotypeIndex),
                    passedAlignments: genotypeIndex.isMultiple(of: 17) ? 1 : 100,
                    passedUniqueReads: genotypeIndex.isMultiple(of: 17) ? 1 : 100,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedReads: 12_000,
                    sampleUniqueRetainedPercent: nil,
                    overallInputReads: nil,
                    overallUniqueRetainedReads: nil,
                    overallUniqueRetainedPercent: nil
                ))
            }
        }

        let start = Date()
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingRenderVisibleCells(rowLimit: 30)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "Genotype viewport configuration and cell rendering should not rescan support denominators per row")
        XCTAssertFalse(controller.testingVisibleGenotypes.isEmpty)
    }

    func testManualHaplotypeOverrideAppearsInReviewEvidenceAndOutlineTape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultViewportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-23T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-B",
                slot: .h2,
                originalCall: "-",
                overrideCall: "M2B",
                reasonTag: .misCall,
                rationale: "Promoted M2B from Review inspector candidate matrix.",
                author: "test",
                timestamp: "2026-05-23T00:00:01Z"
            )
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW472", genotype: "12_M3_B_165_01", reads: 119),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .noHaplotype,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["12_M3_B_075_01", "12_M3_B_165_01"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [
            ONTGenotypeSampleResult(
                sample: "DW472",
                passedAlignments: 442,
                passedUniqueReads: 442,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls
            )
        ], calls: calls, haplotypeAnalysis: analysis))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-B"))
        XCTAssertEqual(evidence.h1Name, "M3B")
        XCTAssertEqual(evidence.h2Name, "M2B")
        XCTAssertEqual(evidence.status, .called)
        XCTAssertEqual(evidence.errorExplanation, "")
        XCTAssertFalse(evidence.isHomozygous)

        let mhcBSlot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-B" })
        XCTAssertEqual(mhcBSlot.h1.testingLabel, "M3B")
        XCTAssertEqual(mhcBSlot.h2.testingLabel, "M2B")
    }

    func testInspectorOverrideAppliesExplicitSelectedHaplotypeSlot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultExplicitOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DP",
                            sourceLocus: "Mafa-DP",
                            haplotype1: "M4DP",
                            haplotype2: "M7DP",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: ["15_M3_DPA1_01", "15_M4_DPA1_01", "15_M7_DPB1_01"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-DP")

        controller.testingApplyOverrideFromInspector(haplotype: "M3DP", slot: .h1)
        controller.testingApplyOverrideFromInspector(haplotype: "M5DP", slot: .h2)

        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        let h1Override = try XCTUnwrap(sidecar.callOverrides.first { $0.sample == "DW472" && $0.locus == "MHC-DP" && $0.slot == .h1 })
        let h2Override = try XCTUnwrap(sidecar.callOverrides.first { $0.sample == "DW472" && $0.locus == "MHC-DP" && $0.slot == .h2 })

        XCTAssertEqual(h1Override.originalCall, "M4DP")
        XCTAssertEqual(h1Override.overrideCall, "M3DP")
        XCTAssertEqual(h2Override.originalCall, "M7DP")
        XCTAssertEqual(h2Override.overrideCall, "M5DP")
        XCTAssertTrue(h1Override.rationale.contains("MHC-DP H1 M4DP -> M3DP"))
        XCTAssertTrue(h2Override.rationale.contains("MHC-DP H2 M7DP -> M5DP"))
    }

    func testInspectorOverrideCanApplyBothHaplotypeSlotsInOneBatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultBatchOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DP",
                            sourceLocus: "Mafa-DP",
                            haplotype1: "M4DP",
                            haplotype2: "M7DP",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: ["15_M3_DPA1_01", "15_M4_DPA1_01", "15_M7_DPB1_01"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-DP")

        controller.testingApplyOverridesFromInspector([
            .init(slot: .h1, haplotypeName: "M3DP"),
            .init(slot: .h2, haplotypeName: "M5DP"),
        ])

        let sidecar = try GenotypeAnnotationSidecar.decode(Data(
            contentsOf: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        ))
        let h1Override = try XCTUnwrap(sidecar.callOverrides.first { $0.sample == "DW472" && $0.locus == "MHC-DP" && $0.slot == .h1 })
        let h2Override = try XCTUnwrap(sidecar.callOverrides.first { $0.sample == "DW472" && $0.locus == "MHC-DP" && $0.slot == .h2 })
        XCTAssertEqual(h1Override.originalCall, "M4DP")
        XCTAssertEqual(h1Override.overrideCall, "M3DP")
        XCTAssertEqual(h2Override.originalCall, "M7DP")
        XCTAssertEqual(h2Override.overrideCall, "M5DP")

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DP"))
        XCTAssertEqual(evidence.h1Name, "M3DP")
        XCTAssertEqual(evidence.h2Name, "M5DP")
    }

    func testQuestionMarkOverrideRemainsUnresolvedInEvidenceAndOutline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeResultUnknownOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-DP",
                            sourceLocus: "Mafa-DP",
                            haplotype1: "M4DP",
                            haplotype2: "M7DP",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: ["15_M4M7_DPA1_04_01", "15_M4M7_DPB1_03_03"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(bundleURL: bundleURL, samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-DP")

        controller.testingApplyOverrideFromInspector(haplotype: "?", slot: .h1)

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "DW472", locus: "MHC-DP"))
        XCTAssertEqual(evidence.h1Name, "?")
        XCTAssertEqual(evidence.status, .tooManyHaplotypes)
        let dpSlot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW472").first { $0.locus == "MHC-DP" })
        XCTAssertEqual(dpSlot.h1.testingLabel, "?")
        XCTAssertTrue(dpSlot.h1.testingIsError)
    }

    private func makeResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
        samples: [ONTGenotypeSampleResult],
        calls: [ONTGenotypeCall],
        kind: String = "ont-barcode-genotype",
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil,
        haplotypeDefinitionSetID: String? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil,
        mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs = .empty,
        mhcAlignmentArtifactURLs: ONTMHCAlignmentArtifactURLs = .empty,
        stats: ONTGenotypeRunStats = ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
        referenceMetadata: ONTGenotypeReferenceMetadata? = nil,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact? = nil
    ) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                kind: kind,
                outputName: "example",
                analysisName: "Example",
                primaryWorkbookPath: "example.xlsx",
                longSummaryCSVPath: "example.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "example.retained-demux-samples.csv",
                statsJSONPath: "example.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json",
                haplotypeDefinitionSetID: haplotypeDefinitionSetID,
                mhcCandidateArtifacts: mhcCandidateArtifacts
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/example.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/example.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/example.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: mhcCandidateGenBankArtifactURLs,
            mhcAlignmentArtifactURLs: mhcAlignmentArtifactURLs,
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            integrityWarnings: [],
            referenceMetadata: referenceMetadata
        )
    }

    private func makeMHCReferenceVisualizationRecord(
        rawReferenceID: String,
        alleleName: String
    ) -> ONTMHCReferenceVisualizationRecord {
        ONTMHCReferenceVisualizationRecord(
            rawReferenceID: rawReferenceID,
            sourceOrdinal: 1,
            alleleName: alleleName,
            locus: alleleName.components(separatedBy: "*").first,
            sequence: "ACGTACGTACGT",
            sequenceSHA256: "test-checksum",
            recordFields: ["definition": ["Synthetic known allele"]],
            features: [],
            annotatedTranslation: nil,
            genBankText: "LOCUS       \(rawReferenceID) 12 bp DNA\n//\n",
            fastaText: ">\(rawReferenceID) \(alleleName)\nACGTACGTACGT\n",
            roles: [ONTMHCReferenceVisualizationRoleAssignment(
                role: .exactKnownCall,
                candidateStableClusterIDs: []
            )]
        )
    }

    private func knownAlleleDetails(in root: NSView) -> [GenotypeKnownAlleleDetailView] {
        ([root] + descendants(of: root)).compactMap { $0 as? GenotypeKnownAlleleDetailView }
    }

    private func candidateAlleleDetails(in root: NSView) -> [GenotypeCandidateAlleleDetailView] {
        ([root] + descendants(of: root)).compactMap { $0 as? GenotypeCandidateAlleleDetailView }
    }

    private func onlyAlleleSequenceDetail(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GenotypeAlleleSequenceDetailView? {
        let details = ([root] + descendants(of: root))
            .compactMap { $0 as? GenotypeAlleleSequenceDetailView }
        XCTAssertEqual(details.count, 1, file: file, line: line)
        return details.first
    }

    private func onlyKnownAlleleDetail(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GenotypeKnownAlleleDetailView? {
        let details = knownAlleleDetails(in: root)
        XCTAssertEqual(details.count, 1, file: file, line: line)
        return details.first
    }

    private func onlyCandidateAlleleDetail(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GenotypeCandidateAlleleDetailView? {
        let details = candidateAlleleDetails(in: root)
        XCTAssertEqual(details.count, 1, file: file, line: line)
        return details.first
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func firstAncestor<View: NSView>(
        of view: NSView,
        ofType type: View.Type
    ) -> View? {
        var current = view.superview
        while let ancestor = current {
            if let match = ancestor as? View {
                return match
            }
            current = ancestor.superview
        }
        return nil
    }

    private func activeConstraints(in root: NSView) -> [NSLayoutConstraint] {
        ([root] + descendants(of: root)).flatMap(\.constraints).filter(\.isActive)
    }

    private func text(_ identifier: String, in root: NSView?) -> String? {
        guard let root else { return nil }
        return ([root] + descendants(of: root))
            .first { $0.accessibilityIdentifier() == identifier }
            .flatMap { ($0 as? NSTextField)?.stringValue }
    }

    private func visibleText(in root: NSView) -> String {
        ([root] + descendants(of: root))
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
            .joined(separator: "\n")
    }

    private func assertNoKnownAggregateEvidence(
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for phrase in [
            "Support Summary", "Unique Reads", "Alignments", "Support Metric",
            "Anchor Evidence", "Same-Locus Co-occurrence", "Supporting Samples",
            "Top Sample", "Aggregate Samples", "Aggregate Unique Reads", "Aggregate Alignments",
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(phrase), phrase, file: file, line: line)
        }
        let lines = Set(text.components(separatedBy: .newlines))
        for label in ["Support", "Samples"] {
            XCTAssertFalse(lines.contains(label), label, file: file, line: line)
        }
    }

    private func makeGenBankReferenceMetadata() -> ONTGenotypeReferenceMetadata {
        let fields = [
            GenBankRecordDatabase.FieldDefinition(key: "feature.allele", displayTitle: "Allele", valueType: "text", sourceCategory: "feature", preferredOrder: 0),
            GenBankRecordDatabase.FieldDefinition(key: "source.organism", displayTitle: "Organism", valueType: "text", sourceCategory: "source", preferredOrder: 1),
            GenBankRecordDatabase.FieldDefinition(key: "feature.product", displayTitle: "Product", valueType: "text", sourceCategory: "feature", preferredOrder: 2),
            GenBankRecordDatabase.FieldDefinition(key: "record.definition", displayTitle: "Definition", valueType: "text", sourceCategory: "record", preferredOrder: 3),
        ]
        return ONTGenotypeReferenceMetadata(
            fields: fields,
            recordsBySequenceName: [
                "NHP01222": [
                    "feature.allele": "Mafa-A1*001:01",
                    "source.organism": "Macaca fascicularis",
                    "feature.product": "MHC class I A1 antigen",
                    "record.definition": "Mafa-A1 complete coding sequence",
                ],
                "NHP99999": [
                    "feature.allele": "Mafa-B*002:01",
                    "source.organism": "Macaca fascicularis",
                    "feature.product": "MHC class I B antigen",
                    "record.definition": "Mafa-B complete coding sequence",
                ],
            ],
            alleleFieldKey: "feature.allele"
        )
    }

    private func makeCandidateResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
        calls: [ONTGenotypeCall],
        candidates: [ONTMHCCandidateRecord],
        observations: [ONTMHCCandidateObservation],
        candidateSequences: [String: String] = [:],
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact? = nil,
        integrityWarnings: [ONTGenotypeIntegrityWarning] = [],
        candidateDocumentSchemaVersion: Int = 1,
        candidateArtifactManifestSchemaVersion: Int = 1,
        referenceMetadata: ONTGenotypeReferenceMetadata? = nil,
        mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs = .empty
    ) -> ONTGenotypeResultBundleData {
        let sampleIDs = Set(calls.map(\.sample) + observations.map(\.sampleID))
        let samples = sampleIDs.sorted().map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: sampleCalls.reduce(0) { $0 + $1.passedAlignments },
                passedUniqueReads: sampleCalls.reduce(0) { $0 + $1.passedUniqueReads },
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: sampleCalls
            )
        }
        let candidateReference = ONTMHCArtifactReference(
            path: "artifacts/candidates/candidates.json",
            sha256: String(repeating: "c", count: 64),
            sizeBytes: 1
        )
        let fastaReference = ONTMHCArtifactReference(
            path: "artifacts/candidates/candidates.fasta",
            sha256: String(repeating: "d", count: 64),
            sizeBytes: 1
        )
        let base = makeResult(
            bundleURL: bundleURL,
            samples: samples,
            calls: calls,
            kind: "full-length-ont-mhc-genotype",
            mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest(
                schemaVersion: candidateArtifactManifestSchemaVersion,
                genotypingEvidence: ONTMHCBAMArtifactPair(
                    bam: .init(path: "artifacts/alignments/genotyping-evidence.bam", sha256: String(repeating: "e", count: 64), sizeBytes: 2),
                    bai: .init(path: "artifacts/alignments/genotyping-evidence.bam.bai", sha256: String(repeating: "f", count: 64), sizeBytes: 3)
                ),
                reciprocalEvidence: ONTMHCBAMArtifactPair(
                    bam: .init(path: "artifacts/alignments/unmatched-to-reference.bam", sha256: String(repeating: "1", count: 64), sizeBytes: 4),
                    bai: .init(path: "artifacts/alignments/unmatched-to-reference.bam.bai", sha256: String(repeating: "2", count: 64), sizeBytes: 5)
                ),
                candidateJSON: candidateReference,
                candidateFASTA: fastaReference,
                unnameableJSON: nil,
                unnameableFASTA: nil
            ),
            referenceMetadata: referenceMetadata
        )
        let document = ONTMHCCandidateAllelesDocument(
            schemaVersion: candidateDocumentSchemaVersion,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: .init(path: "candidates.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 1),
            candidates: candidates,
            observations: observations
        )
        return ONTGenotypeResultBundleData(
            bundleURL: base.bundleURL,
            manifest: base.manifest,
            artifacts: base.artifacts,
            stats: base.stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: nil,
            mhcCandidates: document,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: candidateSequences,
            mhcCandidateGenBankArtifactURLs: mhcCandidateGenBankArtifactURLs,
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            integrityWarnings: integrityWarnings,
            referenceMetadata: referenceMetadata
        )
    }

    private func makeCandidateReferenceVisualizationRecord(
        rawReferenceID: String,
        alleleName: String,
        stableClusterID: String
    ) -> ONTMHCReferenceVisualizationRecord {
        let sequence = String(repeating: "A", count: 2_000)
        return ONTMHCReferenceVisualizationRecord(
            rawReferenceID: rawReferenceID,
            sourceOrdinal: 1,
            alleleName: alleleName,
            locus: "MHC-A1",
            sequence: sequence,
            sequenceSHA256: "test-checksum",
            recordFields: ["definition": ["Synthetic closest reference"]],
            features: [],
            annotatedTranslation: nil,
            genBankText: "LOCUS       \(rawReferenceID) 2000 bp DNA\n//\n",
            fastaText: ">\(rawReferenceID) \(alleleName)\n\(sequence)\n",
            roles: [.init(
                role: .closestNovelReference,
                candidateStableClusterIDs: [stableClusterID]
            )]
        )
    }

    private func makeSequenceDetailCandidateResult(
        includeKnown: Bool = false,
        includeInvalidCandidate: Bool = false
    ) throws -> (
        root: URL,
        result: ONTGenotypeResultBundleData
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSequenceDetail-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        let candidateURL = bundleURL.appendingPathComponent(
            "artifacts/candidates/candidate_alleles.gb"
        )
        try FileManager.default.createDirectory(
            at: candidateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sequence = "ACGTACGT"
        var genBankText = """
        LOCUS       candidate-accession 8 bp DNA linear
        DEFINITION  Exact candidate record.
        ACCESSION   candidate-accession
        FEATURES             Location/Qualifiers
             CDS             1..8
                             /allele="Mafa-A1*001:01_1nt_nov"
        ORIGIN
                1 acgtacgt
        //
        """
        if includeInvalidCandidate {
            genBankText += """

            LOCUS       invalid-accession 8 bp DNA linear
            DEFINITION  Checksum-invalid candidate record.
            ACCESSION   invalid-accession
            ORIGIN
                    1 cccccccc
            //
            """
        }
        try genBankText.write(to: candidateURL, atomically: true, encoding: .utf8)
        let checksum = SHA256.hash(data: Data(sequence.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let stableID = "candidate-stable"
        let candidate = makeCandidate(
            id: stableID,
            name: "Mafa-A1*001:01_1nt_nov",
            classification: .novel,
            support: .singleton,
            samples: ["AnimalA"],
            fastaRecordID: "candidate-accession",
            sequenceSHA256: checksum
        )
        let invalidCandidate = makeCandidate(
            id: "candidate-invalid",
            name: "Mafa-A1*002:01_1nt_nov",
            classification: .novel,
            support: .singleton,
            samples: ["AnimalA"],
            fastaRecordID: "invalid-accession",
            sequenceSHA256: checksum
        )
        let closest = makeCandidateReferenceVisualizationRecord(
            rawReferenceID: "closest-reference",
            alleleName: "Mafa-A1*001:01",
            stableClusterID: stableID
        )
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*000:01"
        )
        return (
            root,
            makeCandidateResult(
                bundleURL: bundleURL,
                calls: includeKnown
                    ? [makeCall(sample: "AnimalA", genotype: "known-a", reads: 6)]
                    : [],
                candidates: includeInvalidCandidate ? [candidate, invalidCandidate] : [candidate],
                observations: [
                    makeCandidateObservation(cluster: stableID, sample: "AnimalA", reads: 5),
                ] + (includeInvalidCandidate
                    ? [makeCandidateObservation(
                        cluster: "candidate-invalid",
                        sample: "AnimalA",
                        reads: 4
                    )]
                    : []),
                mhcReferenceVisualizations: .init(
                    schemaVersion: 1,
                    records: includeKnown ? [known, closest] : [closest]
                ),
                referenceMetadata: includeKnown ? ONTGenotypeReferenceMetadata(
                    fields: [.init(
                        key: "feature.allele",
                        displayTitle: "Allele",
                        valueType: "text",
                        sourceCategory: "feature",
                        preferredOrder: 0
                    )],
                    recordsBySequenceName: [
                        "known-a": ["feature.allele": "Mafa-A1*000:01"],
                    ],
                    alleleFieldKey: "feature.allele"
                ) : nil,
                mhcCandidateGenBankArtifactURLs: .init(
                    candidateAlleles: candidateURL,
                    unnameableClusters: nil,
                    candidateFASTA: nil,
                    unnameableFASTA: nil
                )
            )
        )
    }

    private func makeCandidate(
        id: String,
        name: String,
        classification: ONTMHCCandidateClassification,
        support: ONTMHCCandidateSupportClass,
        samples: [String],
        fastaRecordID: String? = nil,
        sequenceSHA256: String = String(repeating: "b", count: 64)
    ) -> ONTMHCCandidateRecord {
        ONTMHCCandidateRecord(
            stableClusterID: id,
            provisionalName: name,
            locus: "MHC-A1",
            classification: classification,
            supportClass: support,
            closestReferenceName: "Mafa-A1*018:01:01:01",
            closestReferenceClass: .genomicDNA,
            snpCount: classification == .novel ? 5 : 0,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: classification == .extension ? 100 : 0,
            comparableBases: 2_000,
            shorterCoverage: 1,
            identity: 0.99,
            mappingQuality: 60,
            alignmentScore: 2_000,
            independentSampleCount: samples.count,
            occurrenceCount: samples.count,
            totalClusterReads: samples.count * 5,
            supportingSampleIDs: samples,
            fastaRecordID: fastaRecordID ?? id,
            sequenceSHA256: sequenceSHA256,
            selectedEvidence: .init(
                bamPath: "artifacts/alignments/unmatched-to-reference.bam",
                queryName: id,
                referenceName: "Mafa-A1*018:01:01:01",
                readGroupID: nil,
                referenceStart: 1,
                cigar: "2000M"
            )
        )
    }

    private func makeCandidateObservation(
        cluster: String,
        sample: String,
        reads: Int,
        evidenceCount: Int = 1
    ) -> ONTMHCCandidateObservation {
        let evidence = (0..<evidenceCount).map { index in
            ONTMHCEvidenceLocator(
                bamPath: "artifacts/alignments/genotyping-evidence.bam",
                queryName: evidenceCount == 1
                    ? "\(cluster)|\(sample)"
                    : "\(cluster)|\(sample)|\(index)",
                referenceName: "Mafa-A1*018:01:01:01",
                readGroupID: sample,
                referenceStart: 1,
                cigar: "2000M"
            )
        }
        return ONTMHCCandidateObservation(
            stableClusterID: cluster,
            sampleID: sample,
            readGroupID: sample,
            sourceClusterIDs: ["source-\(cluster)-\(sample)"],
            sourceClusterReadCounts: ["source-\(cluster)-\(sample)": reads],
            aggregatedSampleReadCount: reads,
            evidence: evidence
        )
    }

    private func makeCall(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        ONTGenotypeCall(
            sample: sample,
            genotype: genotype,
            passedAlignments: reads,
            passedUniqueReads: reads,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
    }

    private func makeWeakSupportAnalysis(
        h1: String,
        h2: String,
        h1Allele: String,
        h2Allele: String
    ) -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: h1,
                            haplotype2: h2,
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: h1,
                                    diagnosticAlleles: [h1Allele],
                                    observedDiagnosticAlleles: [h1Allele]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: h2,
                                    diagnosticAlleles: [h2Allele],
                                    observedDiagnosticAlleles: [h2Allele]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: [h1Allele, h2Allele]
                        )
                    ]
                )
            ]
        )
    }

    private func makeCustomHaplotypeDefinitionSet(
        id: String,
        haplotypeName: String,
        diagnosticAllele: String
    ) -> GenotypeHaplotypeDefinitionSet {
        makeCustomHaplotypeDefinitionSet(
            id: id,
            haplotypeName: haplotypeName,
            diagnosticAlleles: [diagnosticAllele]
        )
    }

    private func makeCustomHaplotypeDefinitionSet(
        id: String,
        haplotypeName: String,
        diagnosticAlleles: [String]
    ) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "custom-assay",
            displayName: "Custom Test Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: haplotypeName,
                            diagnosticAlleles: diagnosticAlleles
                        )
                    ]
                )
            ]
        )
    }
}

private actor DeferredGenotypeResultLoader {
    private var hasStarted = false
    private var continuation: CheckedContinuation<ONTGenotypeResultBundleData, Never>?

    func load(_ url: URL) async -> ONTGenotypeResultBundleData {
        hasStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !hasStarted {
            await Task.yield()
        }
    }

    func resume(returning result: ONTGenotypeResultBundleData) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor KnownSelectionResultLoaderSpy {
    private let result: ONTGenotypeResultBundleData
    private(set) var invocationCount = 0

    init(result: ONTGenotypeResultBundleData) {
        self.result = result
    }

    func load(_ url: URL) -> ONTGenotypeResultBundleData {
        invocationCount += 1
        return result
    }

    func currentInvocationCount() -> Int {
        invocationCount
    }
}

private extension GenotypeHaplotypeTapeView.Cell {
    var testingLabel: String? {
        switch self {
        case .reference(_, let label),
             .weakReference(_, let label),
             .manual(_, let label),
             .recombinant(_, _, let label),
             .notAssayed(let label),
             .error(let label):
            return label
        case .empty, .unanalyzed:
            return nil
        }
    }

    var testingIsError: Bool {
        if case .error = self { return true }
        return false
    }

    var testingIsWeakSupport: Bool {
        if case .weakReference = self { return true }
        return false
    }
}

private extension NSColor {
    var testingSRGBComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }
}
