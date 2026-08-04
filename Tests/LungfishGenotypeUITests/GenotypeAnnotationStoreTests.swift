import XCTest
import Darwin
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeAnnotationStoreTests: XCTestCase {
    private struct InjectedPublicationFailure: Error {}

    private final class PublicationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func inject(_ point: GenotypeAnnotationPublicationFaultPoint) -> Error? {
            if point == .beforeProvenancePublication {
                lock.lock()
                storage += 1
                lock.unlock()
            }
            return nil
        }
    }

    private final class FailOncePublication: @unchecked Sendable {
        private let lock = NSLock()
        private var shouldFail = true

        func inject(_ point: GenotypeAnnotationPublicationFaultPoint) -> Error? {
            guard point == .beforeProvenancePublication else { return nil }
            lock.lock()
            defer { lock.unlock() }
            guard shouldFail else { return nil }
            shouldFail = false
            return InjectedPublicationFailure()
        }
    }

    func testSynchronousControllerReviewBridgeRevalidatesEvidenceBeforePublication() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1"
        )
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let before = try Data(contentsOf: annotationURL)

        XCTAssertThrowsError(
            try store.setMatrixReviewSynchronously(
                .falsePositive,
                targets: [target],
                evidence: .init([target: 0]),
                author: "reviewer"
            )
        ) { error in
            XCTAssertEqual(error as? GenotypeMatrixReviewMutationError, .ineligibleEvidence)
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), before)

        try store.setMatrixReviewSynchronously(
            .falsePositive,
            targets: [target],
            evidence: .init([target: 7]),
            author: "reviewer"
        )
        XCTAssertEqual(store.sidecar.matrixReviews.map(\.target), [target])
    }

    func testSemanticMatrixMutationPromotesPersistedSchemaVersionOneSidecar() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        var schemaVersionOne = seeded.sidecar
        schemaVersionOne.schemaVersion = 1
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try schemaVersionOne.encoded().write(to: annotationURL, options: .atomic)

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "reviewer")
        XCTAssertEqual(store.sidecar.schemaVersion, 1)
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1",
            stableClusterID: "cluster-1"
        )

        try store.setMatrixReviewSynchronously(
            .falsePositive,
            targets: [target],
            evidence: .init([target: 8]),
            author: "reviewer"
        )

        XCTAssertEqual(
            store.sidecar.schemaVersion,
            GenotypeAnnotationSidecar.currentSchemaVersion
        )
        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(Data(contentsOf: annotationURL)).schemaVersion,
            GenotypeAnnotationSidecar.currentSchemaVersion
        )
    }

    func testSemanticMatrixReplayPromotesRealSchemaVersionOneInput() throws {
        var prior = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-24T00:00:00Z"
        )
        prior.schemaVersion = 1
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1",
            stableClusterID: "cluster-1"
        )
        let review = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: target,
            disposition: .falsePositive,
            author: "reviewer",
            timestamp: "2026-07-24T00:01:00Z"
        )
        let audit = GenotypeAnnotationSidecar.AuditEntry(
            action: "setMatrixReview",
            sample: target.auditSample,
            locus: target.locus,
            slot: nil,
            before: nil,
            after: GenotypeAnnotationSidecar.MatrixReviewDisposition.falsePositive.rawValue,
            color: nil,
            reason: "matrix-review",
            rationale: target.stableAuditDescription,
            author: "reviewer",
            timestamp: "2026-07-24T00:01:00Z"
        )
        let replay = GenotypeMatrixAnnotationReplayPayload(
            action: .setMatrixReview,
            author: "reviewer",
            timestamp: "2026-07-24T00:01:00Z",
            targetMutations: [
                .init(
                    target: target,
                    beforeComments: nil,
                    resolvedCurrentComment: nil,
                    afterComments: nil,
                    beforeReviews: [],
                    afterReviews: [review],
                    canonicalizationAudits: [],
                    actionAudit: audit
                )
            ]
        )

        let replayed = try replay.applying(to: prior)

        XCTAssertEqual(
            replayed.schemaVersion,
            GenotypeAnnotationSidecar.currentSchemaVersion
        )
        XCTAssertEqual(replayed.matrixReviews, [review])
    }

    func testSemanticMatrixReplayRejectsFutureSchemaWithoutChangingInput() throws {
        var prior = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-24T00:00:00Z"
        )
        prior.schemaVersion = GenotypeAnnotationSidecar.currentSchemaVersion + 1
        let original = prior
        let replay = GenotypeMatrixAnnotationReplayPayload(
            action: .setMatrixReview,
            author: "reviewer",
            timestamp: "2026-07-24T00:01:00Z",
            targetMutations: []
        )

        XCTAssertThrowsError(try replay.applying(to: prior)) { error in
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecar.SchemaMutationError,
                .unsupportedFutureSchemaVersion(
                    found: prior.schemaVersion,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            )
        }
        XCTAssertEqual(prior, original)
    }

    func testStoreRejectsFutureSchemaBeforeAnnotationOrProvenanceWrite() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        var future = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-24T00:00:00Z"
        )
        future.schemaVersion = GenotypeAnnotationSidecar.currentSchemaVersion + 1
        let originalData = try future.encoded()
        try originalData.write(to: annotationURL, options: .atomic)
        let originalHash = SHA256.hash(data: originalData)
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "reviewer",
            seedBuiltInSmartCohorts: false
        )

        XCTAssertThrowsError(
            try store.applyOverride(
                sample: "Animal-1",
                locus: "MHC-A",
                slot: .h1,
                originalCall: "M1",
                overrideCall: "M2",
                reasonTag: .misCall,
                rationale: "review"
            )
        ) { error in
            XCTAssertEqual(
                error as? GenotypeAnnotationSidecar.SchemaMutationError,
                .unsupportedFutureSchemaVersion(
                    found: future.schemaVersion,
                    current: GenotypeAnnotationSidecar.currentSchemaVersion
                )
            )
        }

        let storedData = try Data(contentsOf: annotationURL)
        XCTAssertEqual(storedData, originalData)
        XCTAssertEqual(SHA256.hash(data: storedData), originalHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: provenanceURL.path))
        XCTAssertEqual(store.sidecar, future)
    }

    private func makeBundleURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"analysis":"test-fixture"}"#.utf8).write(
            to: url.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        return url
    }

    func testMutationMigratesTrustedGenerationLinkedAnnotationPublication() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-31T12:00:00Z"
        )
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let generationURL = try installTrustedGenerationLinkedPublication(
            annotationData: initial.encoded(),
            provenanceData: Data(#"{"legacy":"preserved"}"#.utf8),
            annotationFilename: annotationURL.lastPathComponent,
            provenanceFilename: provenanceURL.lastPathComponent,
            in: dir
        )
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "analyst",
            seedBuiltInSmartCohorts: false
        )

        try store.applyOverride(
            sample: "CR1178",
            locus: "MHC-A",
            slot: .h1,
            originalCall: "A1",
            overrideCall: "A2",
            reasonTag: .misCall,
            rationale: "manual review"
        )

        for url in [annotationURL, provenanceURL] {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertEqual(values.isSymbolicLink, false)
        }
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(
            try GenotypeAnnotationSidecar.decode(
                Data(contentsOf: annotationURL)
            ),
            store.sidecar
        )
        XCTAssertNotNil(
            try ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: generationURL
                    .appendingPathComponent(annotationURL.lastPathComponent)
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: generationURL
                    .appendingPathComponent(provenanceURL.lastPathComponent)
                    .path
            )
        )
    }

    func testLoadEmptyAndAppendOverride() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(store.sidecar.callOverrides.count, 0)

        try store.applyOverride(
            sample: "H22C112", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .crossContamination, rationale: "Adjacent contamination"
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        XCTAssertEqual(store.sidecar.auditLog[0].action, "override")

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(reloaded.sidecar.callOverrides.count, 1)
    }

    @discardableResult
    private func installTrustedGenerationLinkedPublication(
        annotationData: Data,
        provenanceData: Data,
        annotationFilename: String,
        provenanceFilename: String,
        in bundle: URL
    ) throws -> URL {
        let annotationRoot = bundle
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("genotype-annotations", isDirectory: true)
        let generationID = "46fc3db4-ea08-483d-9f6c-f67f4e2d6caa"
        let generationURL = annotationRoot
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(generationID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: generationURL,
            withIntermediateDirectories: true
        )
        try annotationData.write(
            to: generationURL.appendingPathComponent(annotationFilename)
        )
        try provenanceData.write(
            to: generationURL.appendingPathComponent(provenanceFilename)
        )
        try FileManager.default.createSymbolicLink(
            atPath: annotationRoot.appendingPathComponent("active").path,
            withDestinationPath: "generations/\(generationID)"
        )
        for filename in [annotationFilename, provenanceFilename] {
            try FileManager.default.createSymbolicLink(
                atPath: bundle.appendingPathComponent(filename).path,
                withDestinationPath:
                    "artifacts/genotype-annotations/active/\(filename)"
            )
        }
        return generationURL
    }

    func testApplyOverrideTwiceReplacesSameCellEntry() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "H1", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .crossContamination, rationale: "first"
        )
        try store.applyOverride(
            sample: "H1", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "M3A",
            reasonTag: .misCall, rationale: "second"
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.callOverrides[0].overrideCall, "M3A")
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
    }

    func testReplacingOverrideAuditsPreviousManualValueAndPreservesAutomatedOriginal() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "DW472", locus: "MHC-B", slot: .h2,
            originalCall: "M3B", overrideCall: "M2B",
            reasonTag: .misCall, rationale: "first manual correction"
        )
        try store.applyOverride(
            sample: "DW472", locus: "MHC-B", slot: .h2,
            originalCall: "M3B", overrideCall: "M4B",
            reasonTag: .misCall, rationale: "second manual correction"
        )

        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.callOverrides[0].originalCall, "M3B")
        XCTAssertEqual(store.sidecar.callOverrides[0].overrideCall, "M4B")
        XCTAssertEqual(store.sidecar.auditLog[1].before, "M2B")
        XCTAssertEqual(store.sidecar.auditLog[1].after, "M4B")
    }

    func testSettingOverrideBackToAutomatedCallClearsOverrideAndAuditsRevert() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "DW472", locus: "MHC-B", slot: .h2,
            originalCall: "M3B", overrideCall: "M2B",
            reasonTag: .misCall, rationale: "manual correction"
        )
        try store.applyOverride(
            sample: "DW472", locus: "MHC-B", slot: .h2,
            originalCall: "M3B", overrideCall: "M3B",
            reasonTag: .misCall, rationale: "restore automated call"
        )

        XCTAssertTrue(store.sidecar.callOverrides.isEmpty)
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
        XCTAssertEqual(store.sidecar.auditLog[1].action, "clearOverride")
        XCTAssertEqual(store.sidecar.auditLog[1].before, "M2B")
        XCTAssertEqual(store.sidecar.auditLog[1].after, "M3B")
    }

    func testManualHaplotypeAssignmentsWriteAuditEntries() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let assignment = ManualHaplotypeAssignment(
            sample: "DW472",
            locus: "MHC-B",
            slot: .h1,
            label: "Manual-M2B",
            colorTokenIndex: 2,
            diagnosticAlleles: ["12_M2_B_019_03"],
            notes: "reviewed in matrix"
        )

        try store.addManualHaplotypeAssignment(assignment)

        XCTAssertEqual(store.sidecar.manualHaplotypeAssignments, [assignment])
        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        XCTAssertEqual(store.sidecar.auditLog[0].action, "addManualHaplotypeAssignment")
        XCTAssertEqual(store.sidecar.auditLog[0].sample, "DW472")
        XCTAssertEqual(store.sidecar.auditLog[0].locus, "MHC-B")
        XCTAssertEqual(store.sidecar.auditLog[0].slot, .h1)
        XCTAssertNil(store.sidecar.auditLog[0].before)
        XCTAssertEqual(store.sidecar.auditLog[0].after, "Manual-M2B")
        XCTAssertEqual(store.sidecar.lastEditor, "test")

        try store.removeManualHaplotypeAssignments { $0.label == "Manual-M2B" }

        XCTAssertTrue(store.sidecar.manualHaplotypeAssignments.isEmpty)
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
        XCTAssertEqual(store.sidecar.auditLog[1].action, "removeManualHaplotypeAssignment")
        XCTAssertEqual(store.sidecar.auditLog[1].before, "Manual-M2B")
        XCTAssertNil(store.sidecar.auditLog[1].after)
    }

    func testUndoOverride() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "H22C112", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .crossContamination, rationale: ""
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        try store.undoLastOverride()
        XCTAssertEqual(store.sidecar.callOverrides.count, 0)
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
        XCTAssertEqual(store.sidecar.auditLog[1].action, "undoOverride")
    }

    func testSetSampleStatusOverrideExistingValue() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.setSampleStatus(.needsReview, sample: "H1")
        try store.setSampleStatus(.reviewed, sample: "H1")
        XCTAssertEqual(store.sidecar.sampleStatusFlags.count, 1)
        XCTAssertEqual(store.sidecar.sampleStatusFlags[0].value, .reviewed)
    }

    func testHighlightAndComment() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.setCellHighlight(
            sample: "H1", locus: "MHC-A", slot: .h1,
            fillHex: "#FFEB3B", borderHex: nil
        )
        XCTAssertEqual(store.sidecar.cellHighlights.count, 1)

        try store.setCellHighlight(
            sample: "H1", locus: "MHC-A", slot: .h1,
            fillHex: nil, borderHex: nil
        )
        XCTAssertEqual(store.sidecar.cellHighlights.count, 0)

        try store.addCellComment(
            sample: "H1", locus: "MHC-A", slot: .h1, body: "needs review"
        )
        XCTAssertEqual(store.sidecar.cellComments.count, 1)
    }

    func testMatrixAnnotationWritesAuditEntryAndProvenance() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mamu-I*expected",
            sample: "AR3628"
        )

        try store.setMatrixStyle(
            target: target,
            style: .init(fillColor: "#FFF2CC", textColor: "#C00000", borderColor: "#666666", isBold: true, isItalic: true)
        )
        try store.addMatrixComment(target: target, body: "Expected genotype missing from reads.")

        XCTAssertEqual(store.sidecar.matrixStyles.count, 1)
        XCTAssertEqual(store.sidecar.matrixComments.count, 1)
        XCTAssertEqual(store.sidecar.auditLog.suffix(2).map(\.action), ["setMatrixStyle", "addMatrixComment"])
        XCTAssertEqual(store.sidecar.auditLog.last?.sample, "AR3628")
        XCTAssertEqual(store.sidecar.auditLog.last?.locus, "MHC-B")

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.options.explicit["action"], .string("addMatrixComment"))
        XCTAssertEqual(envelope.argv, CommandLine.arguments)
        XCTAssertNil(envelope.durableReplayArgv)
        XCTAssertEqual(
            envelope.reproducibleCommand,
            CommandLine.arguments.map(shellEscape).joined(separator: " ")
        )
        XCTAssertNil(envelope.steps.first?.durableReplayArgv)
        XCTAssertNil(envelope.options.explicit["patch"])
        XCTAssertEqual(envelope.options.explicit["targetCount"], .integer(1))
        XCTAssertEqual(envelope.options.explicit["targets"], .array([
            .dictionary([
                "kind": .string("cell"),
                "locus": .string("MHC-B"),
                "genotype": .string("Mamu-I*expected"),
                "sample": .string("AR3628"),
            ]),
        ]))
        XCTAssertEqual(envelope.options.explicit["commentBodies"], .array([
            .string("Expected genotype missing from reads."),
        ]))
        XCTAssertEqual(envelope.options.resolvedDefaults["matrixStyleCount"], .integer(1))
        XCTAssertEqual(envelope.options.resolvedDefaults["matrixCommentCount"], .integer(1))
    }

    func testCandidateCollisionMatrixAnnotationsRemainDistinctByStableClusterID() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let genotype = "Mafa-A1*018:01:01:01_5nt_nov"
        let targetA = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: genotype,
            stableClusterID: "cluster-a"
        )
        let targetB = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: genotype,
            stableClusterID: "cluster-b"
        )

        try store.setMatrixStyles([
            (target: targetA, style: .init(fillColor: "#112233")),
            (target: targetB, style: .init(fillColor: "#445566")),
        ])
        try store.addMatrixComments([
            (target: targetA, body: "Cluster A note"),
            (target: targetB, body: "Cluster B note"),
        ])

        XCTAssertEqual(Set(store.sidecar.matrixStyles.map(\.target)), Set([targetA, targetB]))
        XCTAssertEqual(Set(store.sidecar.matrixComments.map(\.target)), Set([targetA, targetB]))
        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(Set(reloaded.sidecar.matrixStyles.map(\.target)), Set([targetA, targetB]))
        XCTAssertEqual(Set(reloaded.sidecar.matrixComments.map(\.target)), Set([targetA, targetB]))
    }

    func testMatrixBatchAnnotationProvenanceCapturesAllTargets() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.addMatrixComments([
            (
                target: .cell(locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AR3628"),
                body: "Expected in this animal."
            ),
            (
                target: .cell(locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AR3629"),
                body: "Expected in this animal."
            ),
        ])

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.options.explicit["action"], .string("addMatrixComments"))
        XCTAssertEqual(envelope.options.explicit["targetCount"], .integer(2))
        XCTAssertEqual(envelope.options.explicit["commentBodies"], .array([
            .string("Expected in this animal."),
            .string("Expected in this animal."),
        ]))
        XCTAssertEqual(envelope.options.resolvedDefaults["matrixCommentCount"], .integer(2))
    }

    func testConfirmCallWritesAuditWithoutOverride() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.confirmCall(
            sample: "DW472",
            locus: "MHC-B",
            h1: "M3B",
            h2: "M3B"
        )

        XCTAssertEqual(store.sidecar.callOverrides.count, 0)
        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        let audit = store.sidecar.auditLog[0]
        XCTAssertEqual(audit.action, "confirmed")
        XCTAssertEqual(audit.sample, "DW472")
        XCTAssertEqual(audit.locus, "MHC-B")
        XCTAssertNil(audit.slot)
        XCTAssertEqual(audit.before, "M3B/M3B")
        XCTAssertEqual(audit.after, "M3B/M3B")
        XCTAssertEqual(audit.reason, "confirmed")
    }

    func testUpdateSettingsWritesAuditWithBeforeAndAfterValues() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.updateSettings { settings in
            settings.dropoutLocusFraction = 0.05
            settings.viewMode = "matrix"
        }

        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        let audit = store.sidecar.auditLog[0]
        XCTAssertEqual(audit.action, "updateSettings")
        XCTAssertEqual(audit.sample, "bundle")
        XCTAssertEqual(audit.reason, "settings")
        XCTAssertTrue(audit.before?.contains("viewMode=outline") ?? false)
        XCTAssertTrue(audit.before?.contains("dropoutLocusFraction=0.01") ?? false)
        XCTAssertTrue(audit.after?.contains("viewMode=matrix") ?? false)
        XCTAssertTrue(audit.after?.contains("dropoutLocusFraction=0.05") ?? false)
    }

    func testUpdateSettingsRollsBackWhenSidecarCannotPersist() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let before = store.sidecar.settings
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try FileManager.default.removeItem(at: annotationURL)
        try FileManager.default.createDirectory(at: annotationURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.updateSettings { settings in
            settings.dropoutAbsolute = 999
        })

        XCTAssertEqual(store.sidecar.settings, before)
    }

    func testUpdateMHCCandidateDisplaySettingsIsBundleScopedAndPreservesScientificArtifacts() throws {
        let bundleA = try makeBundleURL()
        let bundleB = try makeBundleURL()
        defer {
            try? FileManager.default.removeItem(at: bundleA)
            try? FileManager.default.removeItem(at: bundleB)
        }
        let scientificPaths = [
            "manifest.json",
            "candidate-alleles.json",
            "artifacts/workbooks/initial.xlsx",
            "artifacts/workbooks/current.xlsx",
            "artifacts/alignments/genotyping-evidence.bam",
        ]
        for (offset, path) in scientificPaths.enumerated() {
            let url = bundleA.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("scientific-\(offset)".utf8).write(to: url)
        }

        let storeA = try GenotypeAnnotationStore(bundleURL: bundleA, author: "candidate-tester")
        let storeB = try GenotypeAnnotationStore(bundleURL: bundleB, author: "candidate-tester")
        let annotationA = bundleA.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let annotationB = bundleB.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let beforeAnnotationA = try Data(contentsOf: annotationA)
        let beforeAnnotationB = try Data(contentsOf: annotationB)
        let scientificBytes = try Dictionary(uniqueKeysWithValues: scientificPaths.map {
            ($0, try Data(contentsOf: bundleA.appendingPathComponent($0)))
        })
        var display = storeA.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false
        display.showSingletonCandidates = false
        display.tints[.sharedNovel] = try XCTUnwrap(AnnotationColor(hex: "#123456"))

        try storeA.updateMHCCandidateDisplaySettings(display)

        XCTAssertNotEqual(try Data(contentsOf: annotationA), beforeAnnotationA)
        XCTAssertEqual(try Data(contentsOf: annotationB), beforeAnnotationB)
        XCTAssertEqual(storeB.sidecar.settings.mhcCandidateDisplay, .default)
        for path in scientificPaths {
            XCTAssertEqual(try Data(contentsOf: bundleA.appendingPathComponent(path)), scientificBytes[path])
        }
    }

    func testUpdateMHCCandidateDisplaySettingsRecordsExactColorsAndFinalChecksumInProvenance() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate-tester")
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false
        display.showSharedCandidates = true
        display.showSingletonCandidates = false
        display.tints = [
            .sharedNovel: AnnotationColor(red: 0.123456789012345, green: 0.234567890123456, blue: 0.345678901234567, alpha: 0.456789012345678),
            .singletonNovel: AnnotationColor(red: 0.223456789012345, green: 0.334567890123456, blue: 0.445678901234567, alpha: 0.556789012345678),
            .sharedExtension: AnnotationColor(red: 0.323456789012345, green: 0.434567890123456, blue: 0.545678901234567, alpha: 0.656789012345678),
            .singletonExtension: AnnotationColor(red: 0.423456789012345, green: 0.534567890123456, blue: 0.645678901234567, alpha: 0.756789012345678),
        ]

        try store.updateMHCCandidateDisplaySettings(display)

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.options.explicit["action"], .string("updateMHCCandidateDisplaySettings"))
        XCTAssertEqual(envelope.options.explicit["showKnown"], .boolean(false))
        XCTAssertEqual(envelope.options.explicit["showSharedCandidates"], .boolean(true))
        XCTAssertEqual(envelope.options.explicit["showSingletonCandidates"], .boolean(false))
        XCTAssertEqual(envelope.options.explicit["candidateTints"], .dictionary([
            "sharedNovel": .dictionary([
                "red": .number(0.123456789012345),
                "green": .number(0.234567890123456),
                "blue": .number(0.345678901234567),
                "alpha": .number(0.456789012345678),
                "hexRGB": .string("#1F3B58"),
            ]),
            "singletonNovel": .dictionary([
                "red": .number(0.223456789012345),
                "green": .number(0.334567890123456),
                "blue": .number(0.445678901234567),
                "alpha": .number(0.556789012345678),
                "hexRGB": .string("#385571"),
            ]),
            "sharedExtension": .dictionary([
                "red": .number(0.323456789012345),
                "green": .number(0.434567890123456),
                "blue": .number(0.545678901234567),
                "alpha": .number(0.656789012345678),
                "hexRGB": .string("#526E8B"),
            ]),
            "singletonExtension": .dictionary([
                "red": .number(0.423456789012345),
                "green": .number(0.534567890123456),
                "blue": .number(0.645678901234567),
                "alpha": .number(0.756789012345678),
                "hexRGB": .string("#6B88A4"),
            ]),
        ]))
        XCTAssertEqual(envelope.outputs.first?.path, annotationURL.path)
        XCTAssertEqual(
            envelope.outputs.first?.checksumSHA256,
            try ProvenanceFileDescriptor.file(url: annotationURL, format: .json, role: .output).checksumSHA256
        )
        XCTAssertEqual(store.sidecar.auditLog.last?.action, "updateMHCCandidateDisplaySettings")
        XCTAssertTrue(store.sidecar.auditLog.last?.after?.contains(
            "sharedNovel={red=0.123456789012345,green=0.234567890123456,blue=0.345678901234567,alpha=0.456789012345678,hexRGB=#1F3B58}"
        ) == true)
    }

    func testUpdateMHCCandidateDisplaySettingsRollsBackWhenAtomicSidecarWriteFails() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate-tester")
        let before = store.sidecar
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try FileManager.default.removeItem(at: annotationURL)
        try FileManager.default.createDirectory(at: annotationURL, withIntermediateDirectories: true)
        var display = before.settings.mhcCandidateDisplay
        display.showKnown = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(store.sidecar, before)
    }

    func testCandidateDisplayPublicationRestoresAnnotationAndProvenanceBytesWhenProvenancePublishFails() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "initial")
        try initial.updateSettings { $0.viewMode = "matrix" }
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let priorProvenance = try Data(contentsOf: provenanceURL)
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "fault",
            publicationFaultInjector: { point in
                point == .beforeProvenancePublication ? InjectedPublicationFailure() : nil
            }
        )
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
        XCTAssertEqual(store.sidecar.settings.mhcCandidateDisplay.showKnown, true)
    }

    func testCandidateDisplayPublicationRestoresBothFilesWhenCommitDirectorySyncFails() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "initial")
        try initial.updateSettings { $0.panelLayout = "bLeading" }
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let priorProvenance = try Data(contentsOf: provenanceURL)
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "fault",
            publicationFaultInjector: { point in
                point == .commitDirectorySync ? InjectedPublicationFailure() : nil
            }
        )
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showSharedCandidates = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
    }

    func testPublicationReportsPrimaryAndRollbackFailuresTogether() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "initial")
        try initial.updateSettings { $0.cardDensity = "compact" }
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "fault",
            publicationFaultInjector: { point in
                guard point == .beforeProvenancePublication else { return nil }
                try? FileManager.default.removeItem(at: provenanceURL)
                try? FileManager.default.createDirectory(
                    at: provenanceURL,
                    withIntermediateDirectories: false
                )
                return InjectedPublicationFailure()
            }
        )
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display)) { error in
            let transactionError = error as? GenotypeAnnotationPublicationTransactionError
            XCTAssertTrue(transactionError?.primaryError is InjectedPublicationFailure)
            XCTAssertNotNil(transactionError?.rollbackError)
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
    }

    func testStaleCandidateStoreMergesOntoLatestUnrelatedSettingsEditUnderLock() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let candidateStore = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate")
        let settingsStore = try GenotypeAnnotationStore(bundleURL: dir, author: "settings")
        try settingsStore.updateSettings { $0.viewMode = "matrix" }
        var display = candidateStore.sidecar.settings.mhcCandidateDisplay
        display.showSingletonCandidates = false

        try candidateStore.updateMHCCandidateDisplaySettings(display)

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "reader")
        XCTAssertEqual(reloaded.sidecar.settings.viewMode, "matrix")
        XCTAssertFalse(reloaded.sidecar.settings.mhcCandidateDisplay.showSingletonCandidates)
        XCTAssertEqual(
            reloaded.sidecar.auditLog.suffix(2).map(\.action),
            ["updateSettings", "updateMHCCandidateDisplaySettings"]
        )
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(
            provenance.outputs.first?.checksumSHA256,
            try ProvenanceFileDescriptor.file(url: annotationURL, format: .json, role: .output).checksumSHA256
        )
    }

    func testStaleCandidateStoreConflictsWithConcurrentCandidateEdit() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let first = try GenotypeAnnotationStore(bundleURL: dir, author: "first")
        let stale = try GenotypeAnnotationStore(bundleURL: dir, author: "stale")
        var firstDisplay = first.sidecar.settings.mhcCandidateDisplay
        firstDisplay.showKnown = false
        try first.updateMHCCandidateDisplaySettings(firstDisplay)
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let firstAnnotation = try Data(contentsOf: annotationURL)
        let firstProvenance = try Data(contentsOf: provenanceURL)
        var staleDisplay = stale.sidecar.settings.mhcCandidateDisplay
        staleDisplay.showSingletonCandidates = false

        XCTAssertThrowsError(try stale.updateMHCCandidateDisplaySettings(staleDisplay))
        XCTAssertEqual(try Data(contentsOf: annotationURL), firstAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), firstProvenance)

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "reader")
        XCTAssertFalse(reloaded.sidecar.settings.mhcCandidateDisplay.showKnown)
        XCTAssertTrue(reloaded.sidecar.settings.mhcCandidateDisplay.showSingletonCandidates)
        XCTAssertEqual(stale.sidecar, reloaded.sidecar)
    }

    func testHeldCandidatePublicationLockCannotPartiallyMutateBundle() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate")
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let priorProvenance = try Data(contentsOf: provenanceURL)
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: dir)
        let lockFD = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        defer { if lockFD >= 0 { Darwin.close(lockFD) } }
        XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)
        defer { if lockFD >= 0 { _ = flock(lockFD, LOCK_UN) } }
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
    }

    func testUnsafeCandidatePublicationLockCannotPartiallyMutateBundle() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate")
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let priorProvenance = try Data(contentsOf: provenanceURL)
        let lockURL = ONTGenotypeBundlePublicationLock.lockURL(for: dir)
        try? FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showSharedCandidates = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
    }

    func testGenericStaleStoreConflictsWithoutOverwritingLatestEdit() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let first = try GenotypeAnnotationStore(bundleURL: dir, author: "first")
        let stale = try GenotypeAnnotationStore(bundleURL: dir, author: "stale")
        try first.setSampleStatus(.reviewed, sample: "sample-1")

        XCTAssertThrowsError(try stale.setCallStatus(
            .needsReview,
            sample: "sample-2",
            locus: "MHC-A",
            slot: .h1
        ))

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "reader")
        XCTAssertEqual(reloaded.sidecar.sampleStatusFlags.map(\.sample), ["sample-1"])
        XCTAssertTrue(reloaded.sidecar.callStatusFlags.isEmpty)
        XCTAssertEqual(stale.sidecar, reloaded.sidecar)
    }

    func testSmartCohortPersistence() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        // GenotypeAnnotationStore seeds three default cohorts on first open
        // (Needs review, Homozygous, Recombinants). Saving an analyst cohort
        // with a colliding name replaces the seeded one; deleting it does
        // not remove the others.
        let initialCount = store.sidecar.smartCohorts.count
        XCTAssertGreaterThanOrEqual(initialCount, 3)

        let customCohort = GenotypeCohortSmartFilter(
            name: "Analyst custom",
            scope: "bundle",
            isStarred: true,
            predicate: .hasErrorAtAnyLocus
        )
        try store.saveSmartCohort(customCohort)
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount + 1)

        // saving with same name+scope replaces
        try store.saveSmartCohort(customCohort)
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount + 1)

        try store.deleteSmartCohort(name: "Analyst custom", scope: "bundle")
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount)
    }

    func testAnnotationSidecarMutationWritesProvenanceSidecar() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let cohort = GenotypeCohortSmartFilter(
            name: "Metadata cohort",
            scope: "bundle",
            isStarred: true,
            predicate: .animalIdIn(["CR1178", "CR1178b"]),
            searchProjectionText: "A1*007"
        )

        try store.saveSmartCohort(cohort)

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.workflowName, "Genotype annotation sidecar edit")
        XCTAssertEqual(envelope.toolName, "Lungfish Genome Explorer")
        XCTAssertEqual(envelope.argv, CommandLine.arguments)
        XCTAssertNil(envelope.durableReplayArgv)
        XCTAssertEqual(
            envelope.reproducibleCommand,
            CommandLine.arguments.map(shellEscape).joined(separator: " ")
        )
        XCTAssertNil(envelope.steps.first?.durableReplayArgv)
        XCTAssertNil(envelope.options.explicit["patch"])
        XCTAssertEqual(envelope.options.explicit["bundle"]?.fileValue?.path, dir.path)
        XCTAssertEqual(envelope.options.explicit["annotationSidecar"]?.fileValue?.path, annotationURL.path)
        XCTAssertEqual(envelope.options.explicit["action"], .string("saveSmartCohort"))
        XCTAssertEqual(envelope.options.resolvedDefaults["author"], .string("test"))
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.outputs.map(\.path), [annotationURL.path])
        XCTAssertEqual(envelope.outputs.first?.role, .output)
        XCTAssertNotNil(envelope.outputs.first?.checksumSHA256)
        XCTAssertNotNil(envelope.outputs.first?.fileSize)
        let persisted = try JSONDecoder().decode(
            GenotypeAnnotationSidecar.self,
            from: Data(contentsOf: annotationURL)
        )
        XCTAssertEqual(
            persisted.smartCohorts.first { $0.name == cohort.name }?.searchProjectionText,
            "A1*007"
        )
        XCTAssertTrue(
            persisted.auditLog.last { $0.action == "saveSmartCohort" }?
                .after?.contains("searchProjectionText=A1*007") == true
        )
    }

    func testDefaultCohortsSeededOnFirstOpen() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let names = Set(store.sidecar.smartCohorts.map(\.name))
        XCTAssertTrue(names.contains("Incomplete haplotypes"))
        XCTAssertTrue(names.contains("Needs review"))
        XCTAssertTrue(names.contains("Homozygous"))
        XCTAssertTrue(names.contains("Recombinants"))
    }

    func testWritableNonseedingOpenPreservesSidecarAndProvenanceUntilExplicitMutation() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T00:00:00Z"
        )
        sidecar.smartCohorts = [
            GenotypeCohortSmartFilter(
                name: "Analyst custom",
                scope: "bundle",
                isStarred: true,
                predicate: .animalIdIn(["Animal-1"])
            ),
        ]
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try sidecar.encoded().write(to: annotationURL)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let provenanceBytes = Data("existing provenance".utf8)
        try provenanceBytes.write(to: provenanceURL)
        let sidecarBytes = try Data(contentsOf: annotationURL)

        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "test",
            seedBuiltInSmartCohorts: false
        )

        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(store.sidecar.smartCohorts.map(\.name), ["Analyst custom"])
        XCTAssertEqual(try Data(contentsOf: annotationURL), sidecarBytes)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), provenanceBytes)

        let target = GenotypeAnnotationSidecar.MatrixTarget.column(
            sample: "Animal-1"
        )
        try await store.upsertMatrixComment(
            body: "Unexpected sample behavior.",
            targets: [target],
            author: "test"
        )

        XCTAssertEqual(store.sidecar.matrixComments.map(\.body), [
            "Unexpected sample behavior.",
        ])
        XCTAssertEqual(store.sidecar.auditLog.last?.action, "upsertMatrixComment")
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(
                fromSidecar: provenanceURL
            )
        )
        XCTAssertEqual(
            envelope.options.explicit["action"],
            .string("upsertMatrixComment")
        )
    }

    func testDefaultCohortsDoNotOverwriteAnalystCustomVersion() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First open: seed.
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let customNeedsReview = GenotypeCohortSmartFilter(
            name: "Needs review",
            description: "Custom analyst predicate.",
            scope: "bundle",
            isStarred: true,
            predicate: .commentContains("escalate")
        )
        try initial.saveSmartCohort(customNeedsReview)

        // Reopen: should not re-seed Needs review now that one exists.
        let reopened = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let needsReview = reopened.sidecar.smartCohorts.first { $0.name == "Needs review" }
        XCTAssertEqual(needsReview?.description, "Custom analyst predicate.")
    }

    func testSetFalsePositivePublishesAllSupportedCellsOnce() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let publications = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "construction-author",
            publicationFaultInjector: publications.inject
        )
        let first = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1",
            stableClusterID: "cluster-1"
        )
        let second = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-2",
            stableClusterID: "cluster-2"
        )
        let evidence = GenotypeMatrixEvidenceIndex([first: 8, second: 2])

        try await store.setMatrixReview(
            .falsePositive,
            targets: [first, second, first],
            evidence: evidence,
            author: "reviewer"
        )

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(store.sidecar.matrixReviews.count, 2)
        XCTAssertEqual(Set(store.sidecar.matrixReviews.map(\.target)), Set([first, second]))
        XCTAssertEqual(Set(store.sidecar.matrixReviews.map(\.author)), ["reviewer"])
        let audit = Array(store.sidecar.auditLog.suffix(2))
        XCTAssertEqual(audit.map(\.action), ["setMatrixReview", "setMatrixReview"])
        XCTAssertEqual(Set(audit.map(\.timestamp)).count, 1)
        XCTAssertTrue(audit.contains { $0.rationale == first.stableAuditDescription })
        XCTAssertTrue(audit.contains { $0.rationale == second.stableAuditDescription })

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(envelope.options.explicit["action"], .string("setMatrixReview"))
        XCTAssertEqual(envelope.options.explicit["eligibilityRule"], .string("passedUniqueReads > 0"))
        XCTAssertEqual(envelope.options.explicit["supportedCount"], .integer(2))
        XCTAssertEqual(envelope.options.explicit["unsupportedCount"], .integer(0))
        XCTAssertEqual(envelope.options.explicit["targetCount"], .integer(2))
        XCTAssertEqual(envelope.options.resolvedDefaults["author"], .string("reviewer"))
        XCTAssertEqual(envelope.options.resolvedDefaults["absentEvidence"], .string("unsupported"))
        let provenanceInput = try XCTUnwrap(envelope.files.first { $0.role == .input })
        XCTAssertNotEqual(provenanceInput.path, annotationURL.path)
        XCTAssertEqual(provenanceInput.originPath, annotationURL.path)
        XCTAssertNotNil(provenanceInput.checksumSHA256)
        XCTAssertNotNil(provenanceInput.fileSize)
        XCTAssertEqual(envelope.outputs.first?.path, annotationURL.path)
        XCTAssertEqual(
            envelope.outputs.first?.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: annotationURL)
        )
        XCTAssertEqual(
            envelope.outputs.first?.fileSize,
            try ProvenanceFileHasher.fileSize(of: annotationURL)
        )
    }

    func testBulkSemanticMutationsExamineExistingCollectionsInBoundedPasses() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let targets = (0..<240).map { index in
            GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: "MHC-A1",
                genotype: "Allele-\(index)",
                sample: "Animal-\(index)",
                stableClusterID: "cluster-\(index)"
            )
        }
        let selected = Array(targets.prefix(120))
        var legacy = seeded.sidecar
        legacy.matrixReviews = targets.map {
            .init(
                target: $0,
                disposition: .falsePositive,
                author: "legacy",
                timestamp: "2025-01-01T00:00:00Z"
            )
        }
        legacy.matrixComments = targets.flatMap { target in
            [
                .init(
                    target: target,
                    body: "older \(target.auditSample)",
                    author: "legacy",
                    timestamp: "2025-01-01T00:00:00Z"
                ),
                .init(
                    target: target,
                    body: "newer \(target.auditSample)",
                    author: "legacy",
                    timestamp: "2025-02-01T00:00:00Z"
                ),
            ]
        }
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try legacy.encoded().write(to: annotationURL, options: .atomic)
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "reviewer")

        try await store.setMatrixReview(
            .falsePositive,
            targets: selected + selected,
            evidence: .init(Dictionary(uniqueKeysWithValues: selected.map { ($0, 7) })),
            author: "reviewer"
        )

        XCTAssertEqual(store.lastMatrixBulkMutationDiagnostics.reviewRecordsExamined, 240)
        XCTAssertEqual(store.sidecar.matrixReviews.count, 240)
        XCTAssertEqual(Array(store.sidecar.matrixReviews.suffix(120)).map(\.target), selected)

        let commentsBefore = store.sidecar.matrixComments.count
        let auditsBefore = store.sidecar.auditLog.count
        try await store.upsertMatrixComment(
            body: "reviewed",
            targets: selected + selected,
            author: "reviewer"
        )

        let diagnostics = store.lastMatrixBulkMutationDiagnostics
        XCTAssertLessThanOrEqual(diagnostics.commentRecordsExamined, commentsBefore * 2)
        XCTAssertEqual(diagnostics.auditRecordsExamined, auditsBefore)
        XCTAssertEqual(store.sidecar.matrixComments.count, 360)
        XCTAssertEqual(Array(store.sidecar.matrixComments.suffix(120)).map(\.target), selected)

        try await store.clearMatrixReview(targets: selected + selected, author: "reviewer")

        XCTAssertEqual(store.lastMatrixBulkMutationDiagnostics.reviewRecordsExamined, 240)
        XCTAssertEqual(store.sidecar.matrixReviews.map(\.target), Array(targets.dropFirst(120)))

        let commentsBeforeRemove = store.sidecar.matrixComments.count
        let auditsBeforeRemove = store.sidecar.auditLog.count
        try await store.removeMatrixComments(targets: selected + selected, author: "reviewer")

        let removeDiagnostics = store.lastMatrixBulkMutationDiagnostics
        XCTAssertLessThanOrEqual(
            removeDiagnostics.commentRecordsExamined,
            commentsBeforeRemove * 2
        )
        XCTAssertEqual(removeDiagnostics.auditRecordsExamined, auditsBeforeRemove)
        XCTAssertEqual(store.sidecar.matrixComments.count, 240)
        XCTAssertEqual(
            store.sidecar.matrixComments.map(\.target),
            targets.dropFirst(120).flatMap { [$0, $0] }
        )
    }

    func testSetFalseNegativeTreatsAbsentEvidenceAsUnsupported() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let zero = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mafa-B*001:01",
            sample: "Animal-1"
        )
        let absent = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mafa-B*002:01",
            sample: "Animal-2"
        )

        try await store.setMatrixReview(
            .falseNegative,
            targets: [zero, absent],
            evidence: .init([zero: 0]),
            author: "reviewer"
        )

        XCTAssertEqual(store.sidecar.matrixReviews.map(\.disposition), [.falseNegative, .falseNegative])
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(envelope.options.explicit["eligibilityRule"], .string("passedUniqueReads <= 0 or absent"))
        XCTAssertEqual(envelope.options.explicit["supportedCount"], .integer(0))
        XCTAssertEqual(envelope.options.explicit["unsupportedCount"], .integer(2))
    }

    func testResolvedAnalystIdentityIsCapturedByEachFutureMatrixEdit() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = AppSettings.shared
        let originalOverride = settings.analystIdentityOverride
        defer { settings.analystIdentityOverride = originalOverride }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "construction-author")
        let firstTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1",
            stableClusterID: "cluster-1"
        )
        let secondTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:02",
            sample: "Animal-2",
            stableClusterID: "cluster-2"
        )

        settings.analystIdentityOverride = "  First analyst  "
        try await store.upsertMatrixComment(
            body: "first note",
            targets: [firstTarget],
            author: settings.resolvedAnalystIdentity(fallback: "fallback analyst")
        )

        settings.analystIdentityOverride = "Second analyst"
        try await store.upsertMatrixComment(
            body: "second note",
            targets: [secondTarget],
            author: settings.resolvedAnalystIdentity(fallback: "fallback analyst")
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: store.sidecar.matrixComments.map { ($0.target, $0.author) }),
            [firstTarget: "First analyst", secondTarget: "Second analyst"]
        )
        XCTAssertEqual(
            store.sidecar.auditLog.filter { $0.action == "upsertMatrixComment" }.map(\.author),
            ["First analyst", "Second analyst"]
        )
    }

    func testMixedEvidenceRejectsEntireMutation() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let supported = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-1"
        )
        let unsupported = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-2"
        )
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let beforeAnnotation = try Data(contentsOf: annotationURL)
        let beforeProvenance = try Data(contentsOf: provenanceURL)

        do {
            try await store.setMatrixReview(
                .falsePositive,
                targets: [supported, unsupported],
                evidence: .init([supported: 5]),
                author: "reviewer"
            )
            XCTFail("Expected mixed evidence to reject the entire command")
        } catch let error as GenotypeMatrixReviewMutationError {
            XCTAssertEqual(error, .ineligibleEvidence)
        }

        XCTAssertTrue(store.sidecar.matrixReviews.isEmpty)
        XCTAssertEqual(try Data(contentsOf: annotationURL), beforeAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), beforeProvenance)
    }

    func testEvidenceChangedBeforePublishRejectsEntireMutation() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-1"
        )
        let cached = GenotypeMatrixReviewCapability.evaluate(
            selection: [target],
            evidence: .init([target: 5]),
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(cached.falsePositive, .enabled)
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let before = try Data(contentsOf: annotationURL)

        do {
            try await store.setMatrixReview(
                .falsePositive,
                targets: [target],
                evidence: .init([target: 0]),
                author: "reviewer"
            )
            XCTFail("Expected publication-time evidence validation to fail")
        } catch let error as GenotypeMatrixReviewMutationError {
            XCTAssertEqual(error, .ineligibleEvidence)
        }

        XCTAssertTrue(store.sidecar.matrixReviews.isEmpty)
        XCTAssertEqual(try Data(contentsOf: annotationURL), before)
    }

    func testReviewReplacementAndClearAuditBeforeAndAfterValues() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "A",
            sample: "Animal-1",
            stableClusterID: "candidate-9"
        )

        try await store.setMatrixReview(
            .falsePositive,
            targets: [target],
            evidence: .init([target: 5]),
            author: "first"
        )
        try await store.setMatrixReview(
            .falseNegative,
            targets: [target],
            evidence: .init([target: 0]),
            author: "second"
        )
        try await store.clearMatrixReview(targets: [target], author: "third")

        XCTAssertTrue(store.sidecar.matrixReviews.isEmpty)
        let audit = Array(store.sidecar.auditLog.suffix(3))
        XCTAssertEqual(audit.map(\.action), ["setMatrixReview", "setMatrixReview", "clearMatrixReview"])
        XCTAssertEqual(audit.map(\.before), [nil, "falsePositive", "falseNegative"])
        XCTAssertEqual(audit.map(\.after), ["falsePositive", "falseNegative", nil])
        XCTAssertEqual(audit.map(\.author), ["first", "second", "third"])
        XCTAssertEqual(audit.map(\.rationale), Array(repeating: target.stableAuditDescription, count: 3))
    }

    func testMatrixReviewProvenanceReplaysImmutablePriorInputToFinalSidecar() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "construction")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1",
            stableClusterID: "candidate-17"
        )
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let priorData = try Data(contentsOf: annotationURL)

        try await store.setMatrixReview(
            .falsePositive,
            targets: [target],
            evidence: .init([target: 9]),
            author: "Resolved Reviewer"
        )

        let finalData = try Data(contentsOf: annotationURL)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        let replayOutputProvenanceURL =
            GenotypeMatrixAnnotationReplayPayload.replayOutputProvenanceURL(for: annotationURL)
        let expectedReplayArgv = [
            CLICommandIdentity.executableName,
            "genotype",
            GenotypeMatrixAnnotationReplayPayload.cliSubcommandName,
            "--provenance", provenanceURL.path,
            "--output", annotationURL.path,
            "--output-provenance", replayOutputProvenanceURL.path,
            "--force",
        ]
        let expectedReplayCommand = expectedReplayArgv.map(shellEscape).joined(separator: " ")
        XCTAssertEqual(envelope.argv, CommandLine.arguments)
        XCTAssertEqual(envelope.durableReplayArgv, expectedReplayArgv)
        XCTAssertEqual(envelope.reproducibleCommand, expectedReplayCommand)
        XCTAssertEqual(envelope.steps.first?.argv, CommandLine.arguments)
        XCTAssertEqual(envelope.steps.first?.durableReplayArgv, expectedReplayArgv)
        XCTAssertEqual(envelope.steps.first?.reproducibleCommand, expectedReplayCommand)
        XCTAssertEqual(
            envelope.options.explicit["replayOutputProvenance"]?.fileValue?.path,
            replayOutputProvenanceURL.path
        )
        XCTAssertNil(envelope.options.explicit["patch"])

        let priorBase64 = try XCTUnwrap(
            envelope.options.explicit["replayPriorSidecarBase64"]?.stringValue
        )
        let recordedPriorData = try XCTUnwrap(Data(base64Encoded: priorBase64))
        XCTAssertEqual(recordedPriorData, priorData)
        let priorInput = try XCTUnwrap(envelope.files.first { $0.role == .input })
        XCTAssertNotEqual(priorInput.path, annotationURL.path)
        XCTAssertEqual(priorInput.fileSize, UInt64(priorData.count))
        XCTAssertEqual(
            priorInput.checksumSHA256,
            SHA256.hash(data: priorData).map { String(format: "%02x", $0) }.joined()
        )

        let replayBase64 = try XCTUnwrap(
            envelope.options.explicit["replayPayloadBase64"]?.stringValue
        )
        let replayData = try XCTUnwrap(Data(base64Encoded: replayBase64))
        XCTAssertEqual(
            envelope.options.explicit["replayPayloadSHA256"],
            .string(SHA256.hash(data: replayData).map { String(format: "%02x", $0) }.joined())
        )
        let replay = try GenotypeMatrixAnnotationReplayPayload.decode(replayData)
        XCTAssertEqual(replay.action, .setMatrixReview)
        XCTAssertEqual(replay.author, "Resolved Reviewer")
        XCTAssertEqual(replay.targetMutations.map(\.target), [target])
        XCTAssertEqual(
            replay.targetMutations.first?.afterReviews?.map(\.disposition),
            [.falsePositive]
        )

        let replayed = try replay.applying(
            to: GenotypeAnnotationSidecar.decode(recordedPriorData)
        )
        XCTAssertEqual(replayed, store.sidecar)
        XCTAssertEqual(try replayed.encoded(), finalData)
    }

    func testCommentAddEditRemoveUsesOneCurrentValuePerTarget() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let publications = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "construction",
            publicationFaultInjector: publications.inject
        )
        let target = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            stableClusterID: "candidate-1"
        )

        try await store.upsertMatrixComment(body: "first complete body", targets: [target], author: "A")
        XCTAssertEqual(store.sidecar.matrixComments.map(\.body), ["first complete body"])
        try await store.upsertMatrixComment(body: "replacement complete body", targets: [target], author: "B")
        XCTAssertEqual(store.sidecar.matrixComments.map(\.body), ["replacement complete body"])
        try await store.removeMatrixComments(targets: [target], author: "C")

        XCTAssertTrue(store.sidecar.matrixComments.isEmpty)
        let audit = Array(store.sidecar.auditLog.suffix(3))
        XCTAssertEqual(audit.map(\.action), ["upsertMatrixComment", "upsertMatrixComment", "removeMatrixComment"])
        XCTAssertEqual(audit.map(\.before), [nil, "first complete body", "replacement complete body"])
        XCTAssertEqual(audit.map(\.after), ["first complete body", "replacement complete body", nil])
        XCTAssertEqual(audit.map(\.author), ["A", "B", "C"])
        XCTAssertEqual(publications.count, 3)
    }

    func testFirstLegacyCommentMutationCanonicalizesAndAuditsMissingHistory() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "Animal-1")
        let unrelated = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "Animal-2")
        var legacy = seeded.sidecar
        legacy.matrixComments = [
            .init(target: target, body: "superseded without audit", author: "legacy", timestamp: "2025-01-01T00:00:00Z"),
            .init(target: target, body: "current legacy", author: "legacy", timestamp: "2025-02-01T00:00:00Z"),
            .init(target: unrelated, body: "leave both 1", author: "legacy", timestamp: "2025-01-01T00:00:00Z"),
            .init(target: unrelated, body: "leave both 2", author: "legacy", timestamp: "2025-02-01T00:00:00Z"),
        ]
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try legacy.encoded().write(to: annotationURL, options: .atomic)
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "construction")

        try await store.upsertMatrixComment(body: "new current", targets: [target], author: "editor")

        XCTAssertEqual(store.sidecar.matrixComments.filter { $0.target == target }.map(\.body), ["new current"])
        XCTAssertEqual(
            store.sidecar.matrixComments.filter { $0.target == unrelated }.map(\.body),
            ["leave both 1", "leave both 2"]
        )
        let canonicalize = try XCTUnwrap(store.sidecar.auditLog.last {
            $0.action == "canonicalizeLegacyMatrixComments"
        })
        XCTAssertEqual(canonicalize.before, "superseded without audit")
        XCTAssertEqual(canonicalize.after, "current legacy")
        XCTAssertEqual(canonicalize.author, "editor")
        XCTAssertEqual(canonicalize.rationale, target.stableAuditDescription)
        XCTAssertEqual(store.sidecar.auditLog.last?.action, "upsertMatrixComment")
        XCTAssertEqual(store.sidecar.auditLog.last?.before, "current legacy")
        XCTAssertEqual(store.sidecar.auditLog.last?.after, "new current")

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        let targetMutations = try XCTUnwrap(
            envelope.options.explicit["targetMutations"]?.arrayValue
        )
        let mutation = try XCTUnwrap(targetMutations.first?.dictionaryValue)
        XCTAssertEqual(mutation["legacyValues"], .array([
            .string("superseded without audit"),
            .string("current legacy"),
        ]))
        XCTAssertEqual(
            mutation["resolvedCurrent"]?.dictionaryValue?["body"],
            .string("current legacy")
        )
        let canonicalizationActions = try XCTUnwrap(
            mutation["canonicalizationActions"]?.arrayValue
        )
        XCTAssertEqual(canonicalizationActions.count, 1)
        XCTAssertEqual(
            canonicalizationActions.first?.dictionaryValue?["action"],
            .string("canonicalizeLegacyMatrixComments")
        )
        XCTAssertEqual(
            canonicalizationActions.first?.dictionaryValue?["before"],
            .string("superseded without audit")
        )
        XCTAssertEqual(
            canonicalizationActions.first?.dictionaryValue?["after"],
            .string("current legacy")
        )
        XCTAssertEqual(mutation["finalValue"], .string("new current"))

        let priorBase64 = try XCTUnwrap(
            envelope.options.explicit["replayPriorSidecarBase64"]?.stringValue
        )
        let replayBase64 = try XCTUnwrap(
            envelope.options.explicit["replayPayloadBase64"]?.stringValue
        )
        let replay = try GenotypeMatrixAnnotationReplayPayload.decode(
            try XCTUnwrap(Data(base64Encoded: replayBase64))
        )
        XCTAssertEqual(replay.action, .upsertMatrixComment)
        XCTAssertEqual(replay.author, "editor")
        XCTAssertEqual(
            replay.targetMutations.first?.resolvedCurrentComment?.body,
            "current legacy"
        )
        XCTAssertEqual(
            replay.targetMutations.first?.canonicalizationAudits.map(\.before),
            ["superseded without audit"]
        )
        let replayed = try replay.applying(to: GenotypeAnnotationSidecar.decode(
            try XCTUnwrap(Data(base64Encoded: priorBase64))
        ))
        XCTAssertEqual(replayed, store.sidecar)
    }

    func testReviewStyleAuditTextCollisionDoesNotSuppressLegacyCanonicalizationAudit() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let target = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01"
        )
        var legacy = seeded.sidecar
        legacy.matrixComments = [
            .init(target: target, body: "same text", author: "legacy", timestamp: "2025-01-01T00:00:00Z"),
            .init(target: target, body: "current legacy", author: "legacy", timestamp: "2025-02-01T00:00:00Z"),
        ]
        legacy.append(audit: .init(
            action: "setMatrixStyle",
            sample: target.auditSample,
            locus: target.locus,
            slot: nil,
            before: "same text",
            after: "current legacy",
            color: "#112233",
            reason: "matrix-style",
            rationale: target.stableAuditDescription,
            author: "stylist",
            timestamp: "2025-02-02T00:00:00Z"
        ))
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try legacy.encoded().write(to: annotationURL, options: .atomic)
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "construction")

        try await store.upsertMatrixComment(
            body: "new current",
            targets: [target],
            author: "editor"
        )

        let canonicalization = store.sidecar.auditLog.filter {
            $0.action == "canonicalizeLegacyMatrixComments"
                && $0.rationale == target.stableAuditDescription
        }
        XCTAssertEqual(canonicalization.count, 1)
        XCTAssertEqual(canonicalization.first?.before, "same text")
        XCTAssertEqual(canonicalization.first?.after, "current legacy")
    }

    func testReadOnlyAndStaleRevisionPublishNothing() async throws {
        let dir = try makeBundleURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let stale = try GenotypeAnnotationStore(bundleURL: dir, author: "stale")
        let fresh = try GenotypeAnnotationStore(bundleURL: dir, author: "fresh")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-1"
        )
        try await fresh.setMatrixReview(
            .falsePositive,
            targets: [target],
            evidence: .init([target: 5]),
            author: "fresh"
        )
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let freshAnnotation = try Data(contentsOf: annotationURL)
        let freshProvenance = try Data(contentsOf: provenanceURL)

        do {
            try await stale.upsertMatrixComment(body: "stale edit", targets: [target], author: "stale")
            XCTFail("Expected stale revision rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The genotype annotations changed in another process. Reload the bundle before saving this edit.")
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), freshAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), freshProvenance)
        XCTAssertEqual(stale.sidecar, fresh.sidecar)

        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: dir.path)
        let readOnly = try GenotypeAnnotationStore(bundleURL: dir, author: "read-only")
        XCTAssertTrue(readOnly.isReadOnly)
        do {
            try await readOnly.removeMatrixComments(targets: [target], author: "read-only")
            XCTFail("Expected read-only rejection")
        } catch let error as GenotypeMatrixReviewMutationError {
            XCTAssertEqual(error, .readOnly)
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), freshAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), freshProvenance)
    }

    func testEditTimeAuthorAppearsInAnnotationAuditAndProvenance() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "construction-author")
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "Animal-1")

        try await store.upsertMatrixComment(
            body: "authored at edit time",
            targets: [target],
            author: "Resolved Analyst"
        )

        XCTAssertEqual(store.sidecar.matrixComments.last?.author, "Resolved Analyst")
        XCTAssertEqual(store.sidecar.auditLog.last?.author, "Resolved Analyst")
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(envelope.options.explicit["resolvedAuthor"], .string("Resolved Analyst"))
        XCTAssertEqual(envelope.options.resolvedDefaults["author"], .string("Resolved Analyst"))
        XCTAssertEqual(envelope.runtimeIdentity.user, WorkflowRun.currentUser)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, 0)
    }

    func testReplacingManualHaplotypeAssignmentsPublishesOneAtomicAuditedReplay() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifestData = Data(#"{"schema":"manual-assignment-test"}"#.utf8)
        try manifestData.write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        let seeded = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "seed"
        )
        let retainedID = "assignment-existing"
        let removedID = "assignment-removed"
        var initial = seeded.sidecar
        initial.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "Animal-1",
                locus: "MHC-A",
                slot: .h1,
                label: "Old-A",
                colorTokenIndex: 1,
                diagnosticAlleles: ["Mafa-A1*001:01"],
                notes: "Preserve this scientific note.",
                assignmentID: retainedID,
                updatedAt: "2026-07-25T10:00:00Z",
                author: "Earlier Analyst"
            ),
            ManualHaplotypeAssignment(
                sample: "Animal-1",
                locus: "MHC-B",
                slot: .h2,
                label: "Remove-B",
                colorTokenIndex: 3,
                diagnosticAlleles: ["Mafa-B*002:01"],
                notes: "Removal must retain this in audit.",
                assignmentID: removedID,
                updatedAt: "2026-07-25T10:01:00Z",
                author: "Earlier Analyst"
            ),
            ManualHaplotypeAssignment(
                sample: "Animal-2",
                locus: "MHC-A",
                slot: .h1,
                label: "Other-Sample",
                colorTokenIndex: 4,
                diagnosticAlleles: [],
                notes: "",
                assignmentID: "assignment-other",
                updatedAt: "2026-07-25T10:02:00Z",
                author: "Earlier Analyst"
            ),
        ]
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try initial.encoded().write(to: annotationURL, options: .atomic)

        let publications = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "construction-author",
            publicationFaultInjector: publications.inject
        )
        let priorData = try Data(contentsOf: annotationURL)
        let result = try store.replaceManualHaplotypeAssignments(
            for: " Animal-1 ",
            with: [
                ManualHaplotypeAssignment(
                    sample: "Animal-1",
                    locus: " mhc_a ",
                    slot: .h1,
                    label: "  New-A  ",
                    colorTokenIndex: 2,
                    diagnosticAlleles: ["must", "be", "ignored"],
                    notes: "must be ignored"
                ),
                ManualHaplotypeAssignment(
                    sample: " Animal-1 ",
                    locus: "MHC DQB",
                    slot: .h2,
                    label: " New-DQB ",
                    colorTokenIndex: 5,
                    diagnosticAlleles: ["must be empty for a new slot"],
                    notes: "must be empty for a new slot"
                ),
            ],
            copySource: " Animal-9 ",
            author: " Resolved Analyst "
        )

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.sample, "Animal-1")
        XCTAssertEqual(result.added.count, 1)
        XCTAssertEqual(result.updated.count, 1)
        XCTAssertEqual(result.removed.count, 1)
        XCTAssertNotNil(result.operationID)
        XCTAssertNotNil(result.timestamp)
        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(store.manualHaplotypeAssignmentMutationRevision, 1)

        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: store.sidecar.manualHaplotypeAssignments
        )
        let updated = try XCTUnwrap(index.assignment(
            sample: "Animal-1",
            locus: .a,
            slot: .h1
        ))
        XCTAssertEqual(updated.label, "New-A")
        XCTAssertEqual(updated.colorTokenIndex, 2)
        XCTAssertEqual(updated.diagnosticAlleles, ["Mafa-A1*001:01"])
        XCTAssertEqual(updated.notes, "Preserve this scientific note.")
        XCTAssertEqual(updated.assignmentID, retainedID)
        XCTAssertEqual(updated.author, "Resolved Analyst")
        XCTAssertEqual(updated.updatedAt, result.timestamp)
        let added = try XCTUnwrap(index.assignment(
            sample: "Animal-1",
            locus: .dqb,
            slot: .h2
        ))
        XCTAssertEqual(added.label, "New-DQB")
        XCTAssertEqual(added.colorTokenIndex, 5)
        XCTAssertTrue(added.diagnosticAlleles.isEmpty)
        XCTAssertTrue(added.notes.isEmpty)
        XCTAssertFalse(try XCTUnwrap(added.assignmentID).isEmpty)
        XCTAssertEqual(added.author, "Resolved Analyst")
        XCTAssertEqual(added.updatedAt, result.timestamp)
        XCTAssertNotNil(index.assignment(
            sample: "Animal-2",
            locus: .a,
            slot: .h1
        ))

        let operationID = try XCTUnwrap(result.operationID)
        let audits = store.sidecar.auditLog.filter {
            $0.manualHaplotypeAssignment?.operationID == operationID
        }
        XCTAssertEqual(audits.count, 4)
        XCTAssertEqual(Set(audits.map(\.timestamp)), [try XCTUnwrap(result.timestamp)])
        XCTAssertEqual(Set(audits.map(\.author)), ["Resolved Analyst"])
        XCTAssertEqual(
            Set(audits.map { $0.manualHaplotypeAssignment?.copySourceSample }),
            ["Animal-9"]
        )
        XCTAssertEqual(
            audits.filter { $0.action == "replaceManualHaplotypeAssignments" }.count,
            1
        )
        let removalAudit = try XCTUnwrap(audits.first {
            $0.action == "removeManualHaplotypeAssignment"
        })
        XCTAssertEqual(
            removalAudit.manualHaplotypeAssignment?.before?.assignmentID,
            removedID
        )
        XCTAssertEqual(
            removalAudit.manualHaplotypeAssignment?.before?.diagnosticAlleles,
            ["Mafa-B*002:01"]
        )
        XCTAssertEqual(
            removalAudit.manualHaplotypeAssignment?.before?.notes,
            "Removal must retain this in audit."
        )
        XCTAssertNil(removalAudit.manualHaplotypeAssignment?.after)

        let provenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: annotationURL
        )
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL)
        )
        let replayOutputURL =
            GenotypeManualHaplotypeAssignmentReplayPayload
                .replayOutputProvenanceURL(forBundleAt: dir)
        let expectedReplayArgv = [
            CLICommandIdentity.executableName,
            "genotype",
            GenotypeManualHaplotypeAssignmentReplayPayload.cliSubcommandName,
            "--provenance", provenanceURL.path,
            "--bundle", dir.standardizedFileURL.path,
        ]
        XCTAssertEqual(envelope.durableReplayArgv, expectedReplayArgv)
        XCTAssertEqual(
            envelope.reproducibleCommand,
            expectedReplayArgv.map(shellEscape).joined(separator: " ")
        )
        XCTAssertEqual(
            envelope.options.explicit["replayFormat"],
            .string(GenotypeManualHaplotypeAssignmentReplayPayload.format)
        )
        XCTAssertEqual(
            envelope.options.explicit["replayOutputProvenance"],
            .file(replayOutputURL)
        )
        XCTAssertEqual(
            envelope.options.resolvedDefaults["author"],
            .string("Resolved Analyst")
        )
        let replayData = try XCTUnwrap(Data(
            base64Encoded: try XCTUnwrap(
                envelope.options.explicit["replayPayloadBase64"]?.stringValue
            )
        ))
        XCTAssertEqual(
            envelope.options.explicit["replayPayloadSHA256"],
            .string(SHA256.hash(data: replayData).map {
                String(format: "%02x", $0)
            }.joined())
        )
        let replay =
            try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
                replayData
            )
        XCTAssertEqual(replay.operation.operationID, operationID)
        XCTAssertEqual(replay.operation.sample, "Animal-1")
        XCTAssertEqual(replay.operation.copySourceSample, "Animal-9")
        XCTAssertEqual(
            replay.priorSidecar.descriptor.checksumSHA256,
            SHA256.hash(data: priorData).map {
                String(format: "%02x", $0)
            }.joined()
        )
        XCTAssertEqual(
            replay.targetBundle.manifest.checksumSHA256,
            SHA256.hash(data: manifestData).map {
                String(format: "%02x", $0)
            }.joined()
        )
        let replayed = try replay.applying(
            to: priorData,
            targetBundleURL: dir,
            targetManifestData: manifestData
        )
        XCTAssertEqual(replayed, store.sidecar)
        XCTAssertEqual(try replayed.encoded(), try Data(contentsOf: annotationURL))
    }

    func testSelectiveSaveAuditAttributesOnlyOneCleanSourceAndExactlyReplaysEveryFinalDiff()
        throws
    {
        struct Scenario {
            let name: String
            let edit: (
                inout GenotypeManualHaplotypeDraft,
                GenotypeManualHaplotypeAssignmentIndex
            ) -> Void
            let expectedCopySource: String?
            let expectedLabels: Set<String>
        }

        let sourceAssignments = [
            ManualHaplotypeAssignment(
                sample: "Source-1",
                locus: "MHC-A",
                slot: .h1,
                label: "Source-1 A",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
            ManualHaplotypeAssignment(
                sample: "Source-1",
                locus: "MHC-B",
                slot: .h1,
                label: "Source-1 B",
                colorTokenIndex: 2,
                diagnosticAlleles: [],
                notes: ""
            ),
            ManualHaplotypeAssignment(
                sample: "Source-2",
                locus: "MHC-B",
                slot: .h1,
                label: "Source-2 B",
                colorTokenIndex: 3,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: sourceAssignments
        )
        let aH1 = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        let bH1 = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .b,
            slot: .h1
        )
        let scenarios = [
            Scenario(
                name: "single source",
                edit: { draft, index in
                    _ = draft.copySelectedAssignments(
                        from: index.sampleAssignments(for: "Source-1"),
                        addresses: [aH1, bH1]
                    )
                },
                expectedCopySource: "Source-1",
                expectedLabels: ["Source-1 A", "Source-1 B"]
            ),
            Scenario(
                name: "mixed sources",
                edit: { draft, index in
                    _ = draft.copySelectedAssignments(
                        from: index.sampleAssignments(for: "Source-1"),
                        addresses: [aH1]
                    )
                    _ = draft.copySelectedAssignments(
                        from: index.sampleAssignments(for: "Source-2"),
                        addresses: [bH1]
                    )
                },
                expectedCopySource: nil,
                expectedLabels: ["Source-1 A", "Source-2 B"]
            ),
            Scenario(
                name: "manual and copied",
                edit: { draft, index in
                    _ = draft.copySelectedAssignments(
                        from: index.sampleAssignments(for: "Source-1"),
                        addresses: [aH1]
                    )
                    draft.setLabel(
                        "Manual B",
                        locus: .b,
                        slot: .h1
                    )
                },
                expectedCopySource: nil,
                expectedLabels: ["Source-1 A", "Manual B"]
            ),
        ]

        for scenario in scenarios {
            let dir = try makeBundleURL()
            defer { try? FileManager.default.removeItem(at: dir) }
            let manifestURL = dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
            try Data("{}".utf8).write(to: manifestURL)
            let store = try GenotypeAnnotationStore(
                bundleURL: dir,
                author: "Audit Analyst"
            )
            let annotationURL = dir.appendingPathComponent(
                GenotypeAnnotationSidecar.filename
            )
            let priorData = try Data(contentsOf: annotationURL)
            let manifestData = try Data(contentsOf: manifestURL)
            var draft = GenotypeManualHaplotypeDraft(
                sample: "Target",
                index: index
            )

            scenario.edit(&draft, index)

            XCTAssertEqual(
                draft.copySource,
                scenario.expectedCopySource,
                scenario.name
            )
            let replacement = try store.replaceManualHaplotypeAssignments(
                for: draft.sample,
                with: try draft.validatedAssignments(),
                copySource: draft.copySource,
                author: "Audit Analyst"
            )
            let operationID = try XCTUnwrap(
                replacement.operationID,
                scenario.name
            )
            let operationAudits = store.sidecar.auditLog.filter {
                $0.manualHaplotypeAssignment?.operationID == operationID
            }
            XCTAssertFalse(operationAudits.isEmpty, scenario.name)
            XCTAssertEqual(
                Set(operationAudits.map {
                    $0.manualHaplotypeAssignment?.copySourceSample
                }),
                [scenario.expectedCopySource],
                scenario.name
            )
            XCTAssertEqual(
                Set(
                    store.sidecar.manualHaplotypeAssignments
                        .filter { $0.sample == "Target" }
                        .map(\.label)
                ),
                scenario.expectedLabels,
                scenario.name
            )

            let provenanceURL = ProvenanceRecorder.fileSidecarURL(
                for: annotationURL
            )
            let envelope = try XCTUnwrap(
                ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL),
                scenario.name
            )
            let replayData = try XCTUnwrap(
                Data(base64Encoded: try XCTUnwrap(
                    envelope.options.explicit[
                        "replayPayloadBase64"
                    ]?.stringValue,
                    scenario.name
                )),
                scenario.name
            )
            let replay =
                try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
                    replayData
                )
            XCTAssertEqual(
                replay.operation.copySourceSample,
                scenario.expectedCopySource,
                scenario.name
            )
            XCTAssertEqual(
                replay.beforeAssignments,
                [],
                scenario.name
            )
            XCTAssertEqual(
                replay.afterAssignments,
                store.sidecar.manualHaplotypeAssignments,
                scenario.name
            )
            let replayed = try replay.applying(
                to: priorData,
                targetBundleURL: dir,
                targetManifestData: manifestData
            )
            XCTAssertEqual(replayed, store.sidecar, scenario.name)
            XCTAssertEqual(
                try replayed.encoded(),
                try Data(contentsOf: annotationURL),
                scenario.name
            )
        }
    }

    func testReplacingManualHaplotypeAssignmentsNoOpWritesNothing() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let existing = ManualHaplotypeAssignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "Manual-A",
            colorTokenIndex: 2,
            diagnosticAlleles: ["A1"],
            notes: "Existing note",
            assignmentID: "stable-id",
            updatedAt: "2026-07-25T10:00:00Z",
            author: "Earlier Analyst"
        )
        var initial = seeded.sidecar
        initial.manualHaplotypeAssignments = [existing]
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try initial.encoded().write(to: annotationURL, options: .atomic)
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let beforeAnnotation = try Data(contentsOf: annotationURL)
        let beforeProvenance = try Data(contentsOf: provenanceURL)

        let result = try store.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: [existing],
            copySource: "Animal-8",
            author: "Someone Else"
        )

        XCTAssertFalse(result.didChange)
        XCTAssertNil(result.operationID)
        XCTAssertNil(result.timestamp)
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertTrue(result.updated.isEmpty)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(store.manualHaplotypeAssignmentMutationRevision, 0)
        XCTAssertEqual(try Data(contentsOf: annotationURL), beforeAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), beforeProvenance)
        XCTAssertEqual(store.sidecar, initial)
    }

    func testFirstManualHaplotypeSaveCanonicalizesLegacyDuplicatesWithoutErasingHistory() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        var initial = seeded.sidecar
        let historicalAudit = GenotypeAnnotationSidecar.AuditEntry(
            action: "legacyManualAssignmentImport",
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            before: nil,
            after: "Older",
            color: "1",
            reason: "legacy-import",
            rationale: "Keep this historical record.",
            author: "Legacy Analyst",
            timestamp: "2025-01-01T00:00:00Z"
        )
        initial.append(audit: historicalAudit)
        initial.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "Animal-1",
                locus: "MHC_A",
                slot: .h1,
                label: "Older",
                colorTokenIndex: 1,
                diagnosticAlleles: ["older-allele"],
                notes: "older note",
                assignmentID: nil,
                updatedAt: "2025-01-01T00:00:00Z",
                author: "Legacy Analyst"
            ),
            ManualHaplotypeAssignment(
                sample: "Animal-1",
                locus: "MHC-A",
                slot: .h1,
                label: "Current",
                colorTokenIndex: 2,
                diagnosticAlleles: ["current-allele"],
                notes: "current note",
                assignmentID: " stable-exact-id ",
                updatedAt: "2025-02-01T00:00:00Z",
                author: "Legacy Analyst"
            ),
        ]
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try initial.encoded().write(to: annotationURL, options: .atomic)
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")

        let result = try store.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: [
                ManualHaplotypeAssignment(
                    sample: "Animal-1",
                    locus: "MHC-A",
                    slot: .h1,
                    label: "Current",
                    colorTokenIndex: 2,
                    diagnosticAlleles: [],
                    notes: ""
                ),
            ],
            copySource: nil,
            author: "Canonicalizing Analyst"
        )

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.added.isEmpty)
        XCTAssertEqual(result.updated.count, 1)
        XCTAssertTrue(result.removed.isEmpty)
        let selected = store.sidecar.manualHaplotypeAssignments.filter {
            $0.sample == "Animal-1"
        }
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected[0].locus, "MHC-A")
        XCTAssertEqual(selected[0].assignmentID, " stable-exact-id ")
        XCTAssertEqual(selected[0].diagnosticAlleles, ["current-allele"])
        XCTAssertEqual(selected[0].notes, "current note")
        XCTAssertEqual(store.sidecar.auditLog.first, historicalAudit)
        let operationID = try XCTUnwrap(result.operationID)
        let operationAudits = store.sidecar.auditLog.filter {
            $0.manualHaplotypeAssignment?.operationID == operationID
        }
        XCTAssertEqual(
            operationAudits.map(\.action),
            [
                "updateManualHaplotypeAssignment",
                "replaceManualHaplotypeAssignments",
            ]
        )
    }

    func testEmptyDraftRemovesWhitespaceAndDecomposedLegacySampleWhilePreservingSelectedOrphanAndExactReplay() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifestData = Data(#"{"revision":"legacy-sample"}"#.utf8)
        try manifestData.write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let canonicalSample = "\u{00C1}nimal-1"
        let legacySample = "  A\u{0301}nimal-1  "
        let recognized = ManualHaplotypeAssignment(
            sample: legacySample,
            locus: "MHC-A",
            slot: .h1,
            label: "Legacy-A",
            colorTokenIndex: 2,
            diagnosticAlleles: ["Mafa-A1*001:01"],
            notes: "remove but audit exactly",
            assignmentID: "legacy-a-id",
            updatedAt: "2026-07-26T15:02:00Z",
            author: "Legacy Analyst"
        )
        let selectedOrphan = ManualHaplotypeAssignment(
            sample: legacySample,
            locus: "MHC-OPAQUE",
            slot: .h2,
            label: "Opaque",
            colorTokenIndex: 8,
            diagnosticAlleles: ["opaque"],
            notes: "preserve exact orphan",
            assignmentID: nil,
            updatedAt: "not-a-date",
            author: "Legacy Analyst"
        )
        let unrelated = ManualHaplotypeAssignment(
            sample: "Animal-2",
            locus: "MHC-B",
            slot: .h1,
            label: "Other",
            colorTokenIndex: 4,
            diagnosticAlleles: ["other"],
            notes: "unrelated exact",
            assignmentID: "other-id",
            updatedAt: "2026-07-26T15:03:00Z",
            author: "Other Analyst"
        )
        var initial = seeded.sidecar
        initial.manualHaplotypeAssignments = [
            recognized,
            selectedOrphan,
            unrelated,
        ]
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try initial.encoded().write(to: annotationURL, options: .atomic)
        let priorData = try Data(contentsOf: annotationURL)
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")

        let result = try store.replaceManualHaplotypeAssignments(
            for: canonicalSample,
            with: [],
            copySource: nil,
            author: "Canonicalizing Analyst"
        )

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.removed, [recognized])
        XCTAssertEqual(
            store.sidecar.manualHaplotypeAssignments,
            [unrelated, selectedOrphan]
        )
        let removalAudit = try XCTUnwrap(store.sidecar.auditLog.last {
            $0.action == "removeManualHaplotypeAssignment"
        })
        XCTAssertEqual(
            removalAudit.manualHaplotypeAssignment?.before,
            recognized
        )
        XCTAssertNil(removalAudit.manualHaplotypeAssignment?.after)
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(
                fromSidecar: ProvenanceRecorder.fileSidecarURL(
                    for: annotationURL
                )
            )
        )
        let replayData = try XCTUnwrap(Data(
            base64Encoded: try XCTUnwrap(
                envelope.options.explicit["replayPayloadBase64"]?.stringValue
            )
        ))
        let replay =
            try GenotypeManualHaplotypeAssignmentReplayPayload.decode(
                replayData
            )
        let replayed = try replay.applying(
            to: priorData,
            targetBundleURL: dir,
            targetManifestData: manifestData
        )
        XCTAssertEqual(replayed, store.sidecar)
    }

    func testManualHaplotypePublicationFailurePreservesBytesAndObservableStateThenRetrySucceedsOnce() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        var initial = seeded.sidecar
        initial.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "Animal-1",
                locus: "MHC-A",
                slot: .h1,
                label: "Remove-Me",
                colorTokenIndex: 2,
                diagnosticAlleles: ["Mafa-A1*001:01"],
                notes: "rollback me",
                assignmentID: "remove-me-id",
                updatedAt: "2026-07-26T15:02:00Z",
                author: "Legacy Analyst"
            ),
        ]
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try initial.encoded().write(to: annotationURL, options: .atomic)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(
            for: annotationURL
        )
        let failure = FailOncePublication()
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "test",
            publicationFaultInjector: failure.inject
        )
        let sidecarBefore = store.sidecar
        let annotationBefore = try Data(contentsOf: annotationURL)
        let provenanceBefore = try Data(contentsOf: provenanceURL)

        XCTAssertThrowsError(try store.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: [],
            copySource: nil,
            author: "Retry Analyst"
        ))
        XCTAssertEqual(try Data(contentsOf: annotationURL), annotationBefore)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), provenanceBefore)
        XCTAssertEqual(store.sidecar, sidecarBefore)
        XCTAssertEqual(store.manualHaplotypeAssignmentMutationRevision, 0)

        let retry = try store.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: [],
            copySource: nil,
            author: "Retry Analyst"
        )
        XCTAssertTrue(retry.didChange)
        XCTAssertTrue(store.sidecar.manualHaplotypeAssignments.isEmpty)
        XCTAssertEqual(store.manualHaplotypeAssignmentMutationRevision, 1)
    }

    func testReplacingManualHaplotypeAssignmentsRejectsInvalidAndDuplicateDraftKeys() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let beforeAnnotation = try Data(contentsOf: annotationURL)
        let beforeProvenance = try Data(contentsOf: provenanceURL)
        let assignment = ManualHaplotypeAssignment(
            sample: "Animal-1",
            locus: "MHC-A",
            slot: .h1,
            label: "Manual-A",
            colorTokenIndex: 2,
            diagnosticAlleles: [],
            notes: ""
        )

        XCTAssertThrowsError(try store.replaceManualHaplotypeAssignments(
            for: " \n ",
            with: [assignment],
            copySource: nil,
            author: nil
        )) {
            XCTAssertEqual(
                $0 as? ManualHaplotypeReplacementError,
                .emptySample
            )
        }
        var invalidLocus = assignment
        invalidLocus.locus = " "
        XCTAssertThrowsError(try store.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: [invalidLocus],
            copySource: nil,
            author: nil
        )) {
            XCTAssertEqual(
                $0 as? ManualHaplotypeReplacementError,
                .invalidLocus(" ")
            )
        }
        var aliasDuplicate = assignment
        aliasDuplicate.locus = "MHC A"
        XCTAssertThrowsError(try store.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: [assignment, aliasDuplicate],
            copySource: nil,
            author: nil
        )) {
            XCTAssertEqual(
                $0 as? ManualHaplotypeReplacementError,
                .duplicateKey(
                    sample: "Animal-1",
                    locus: .a,
                    slot: .h1
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), beforeAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), beforeProvenance)
        XCTAssertEqual(store.manualHaplotypeAssignmentMutationRevision, 0)
    }

    func testStaleManualHaplotypeReplacementLeavesPublishedBytesUntouched() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(
            to: dir.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let stale = try GenotypeAnnotationStore(bundleURL: dir, author: "stale")
        let staleBefore = stale.sidecar
        let fresh = try GenotypeAnnotationStore(bundleURL: dir, author: "fresh")
        let freshDraft = [
            ManualHaplotypeAssignment(
                sample: "Animal-1",
                locus: "MHC-A",
                slot: .h1,
                label: "Fresh",
                colorTokenIndex: 2,
                diagnosticAlleles: [],
                notes: ""
            )
        ]
        _ = try fresh.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: freshDraft,
            copySource: nil,
            author: "Fresh Analyst"
        )
        let annotationURL = dir.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let freshAnnotation = try Data(contentsOf: annotationURL)
        let freshProvenance = try Data(contentsOf: provenanceURL)

        var staleDraft = freshDraft
        staleDraft[0].label = "Stale"
        XCTAssertThrowsError(try stale.replaceManualHaplotypeAssignments(
            for: "Animal-1",
            with: staleDraft,
            copySource: nil,
            author: "Stale Analyst"
        )) {
            XCTAssertEqual(
                $0.localizedDescription,
                "The genotype annotations changed in another process. Reload the bundle before saving this edit."
            )
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), freshAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), freshProvenance)
        XCTAssertEqual(stale.sidecar, staleBefore)
        XCTAssertEqual(stale.manualHaplotypeAssignmentMutationRevision, 0)
    }
}
