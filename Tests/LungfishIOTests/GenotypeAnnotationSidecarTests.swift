import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeAnnotationSidecarTests: XCTestCase {
    func testEmptyRoundTrip() throws {
        let sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T00:00:00Z")
        let data = try sidecar.encoded()
        let decoded = try GenotypeAnnotationSidecar.decode(data)
        XCTAssertEqual(decoded, sidecar)
    }

    func testCallOverrideRoundTrip() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T00:00:00Z")
        sidecar.callOverrides.append(.init(
            sample: "H22C112", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .crossContamination, rationale: "Adjacent contamination",
            author: "dho", timestamp: "2026-05-22T16:02:11Z"
        ))
        let decoded = try GenotypeAnnotationSidecar.decode(sidecar.encoded())
        XCTAssertEqual(decoded.callOverrides.count, 1)
        XCTAssertEqual(decoded.callOverrides[0].overrideCall, "A1_063")
    }

    func testAIHaplotypeReviewEntryRoundTripsWithoutHumanOverrides() throws {
        let callReview = GenotypeAnnotationSidecar.AIHaplotypeCallReview(
            sample: "DW472",
            locus: "MHC-A",
            slot: .h1,
            callState: .novelCandidate,
            confidenceTier: .medium,
            supportEvidenceRefs: ["obs:DW472:MHC-A:M1A"],
            counterevidenceRefs: ["dropout:DW472:MHC-A:M2A"],
            reviewerDecision: .needsReview,
            reviewer: nil,
            reviewedAt: nil,
            provenancePath: "artifacts/ai-haplotyping/provenance/ai-refine.lungfish-provenance.json"
        )
        let review = GenotypeAnnotationSidecar.AIHaplotypeReviewEntry(
            id: "airev-0001",
            analysisRevisionID: "haprev-ai-0001",
            createdAt: "2026-06-14T18:00:00Z",
            source: .ai,
            reviewState: .needsReview,
            callReviews: [callReview],
            evidenceSnapshotPath: "artifacts/ai-haplotyping/evidence/evidence.json",
            callsPath: "artifacts/ai-haplotyping/calls/calls.json",
            validationReportPath: "artifacts/ai-haplotyping/validation/report.json",
            provenancePath: "artifacts/ai-haplotyping/provenance/ai-refine.lungfish-provenance.json"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-14T17:00:00Z")
        sidecar.activeAIHaplotypeReviewID = review.id
        sidecar.aiHaplotypeReviews = [review]

        let decoded = try GenotypeAnnotationSidecar.decode(try sidecar.encoded())

        XCTAssertEqual(decoded.activeAIHaplotypeReviewID, "airev-0001")
        XCTAssertEqual(decoded.aiHaplotypeReviews, [review])
        XCTAssertTrue(decoded.callOverrides.isEmpty)
        XCTAssertTrue(decoded.manualHaplotypeAssignments.isEmpty)
    }

    func testMatrixStyleRoundTripsForRowColumnAndCellTargets() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: "MHC-B", genotype: "Mamu-I*01"),
                style: .init(fillColor: "#FFF2CC", textColor: "#C00000", borderColor: nil, isBold: true, isItalic: false),
                author: "dho",
                timestamp: "2026-06-30T12:00:00Z"
            ),
            .init(
                target: .column(sample: "AR3628"),
                style: .init(fillColor: nil, textColor: "#0070C0", borderColor: "#666666", isBold: false, isItalic: true),
                author: "dho",
                timestamp: "2026-06-30T12:01:00Z"
            ),
            .init(
                target: .cell(locus: "MHC-B", genotype: "Mamu-I*01", sample: "AR3628"),
                style: .init(fillColor: "#D9EAD3", textColor: nil, borderColor: nil, isBold: true, isItalic: true),
                author: "dho",
                timestamp: "2026-06-30T12:02:00Z"
            ),
        ]

        let decoded = try GenotypeAnnotationSidecar.decode(sidecar.encoded())

        XCTAssertEqual(decoded.matrixStyles, sidecar.matrixStyles)
        XCTAssertEqual(decoded.matrixStyles.map(\.target), [
            .row(locus: "MHC-B", genotype: "Mamu-I*01"),
            .column(sample: "AR3628"),
            .cell(locus: "MHC-B", genotype: "Mamu-I*01", sample: "AR3628"),
        ])
    }

    func testCandidateMatrixTargetStableClusterIDRoundTripsAndLegacyTargetDecodesNil() throws {
        let candidateRow = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            stableClusterID: "cluster-a"
        )
        let candidateCell = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-a"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode(GenotypeAnnotationSidecar.MatrixTarget.self, from: encoder.encode(candidateRow)), candidateRow)
        XCTAssertEqual(try decoder.decode(GenotypeAnnotationSidecar.MatrixTarget.self, from: encoder.encode(candidateCell)), candidateCell)
        XCTAssertEqual(candidateRow.stableClusterID, "cluster-a")
        XCTAssertEqual(candidateCell.stableClusterID, "cluster-a")

        let legacyRow = try decoder.decode(
            GenotypeAnnotationSidecar.MatrixTarget.self,
            from: Data(#"{"kind":"row","locus":"MHC-A1","genotype":"Legacy"}"#.utf8)
        )
        let legacyCell = try decoder.decode(
            GenotypeAnnotationSidecar.MatrixTarget.self,
            from: Data(#"{"kind":"cell","locus":"MHC-A1","genotype":"Legacy","sample":"AnimalA"}"#.utf8)
        )
        XCTAssertNil(legacyRow.stableClusterID)
        XCTAssertNil(legacyCell.stableClusterID)
        XCTAssertEqual(legacyRow, .row(locus: "MHC-A1", genotype: "Legacy"))
        XCTAssertEqual(legacyCell, .cell(locus: "MHC-A1", genotype: "Legacy", sample: "AnimalA"))
    }

    func testMatrixCommentPersistsForEmptyCellTarget() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-30T00:00:00Z")
        sidecar.matrixComments = [
            .init(
                target: .cell(locus: "MHC-B", genotype: "Mamu-I*expected", sample: "AR3628"),
                body: "Expected allele absent from this sample.",
                author: "dho",
                timestamp: "2026-06-30T12:03:00Z"
            ),
        ]

        let decoded = try GenotypeAnnotationSidecar.decode(sidecar.encoded())

        XCTAssertEqual(decoded.matrixComments, sidecar.matrixComments)
    }

    func testVersionOneSidecarDecodesWithNoMatrixReviews() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-06-30T00:00:00Z"
        }
        """.data(using: .utf8)!

        let decoded = try GenotypeAnnotationSidecar.decode(json)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.matrixReviews.isEmpty)
    }

    func testVersionThreeSidecarRoundTripsStableIdentityReview() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T00:00:00Z")
        let review = GenotypeAnnotationSidecar.MatrixReviewAnnotation(
            target: .cell(
                locus: "MHC-A1",
                genotype: "Mafa-A1*018:01:01:01_5nt_nov",
                sample: "AnimalA",
                stableClusterID: "cluster-a"
            ),
            disposition: .falseNegative,
            author: "dho",
            timestamp: "2026-07-01T12:00:00Z"
        )
        sidecar.matrixReviews = [review]

        let decoded = try GenotypeAnnotationSidecar.decode(sidecar.encoded())

        XCTAssertEqual(GenotypeAnnotationSidecar.currentSchemaVersion, 3)
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.matrixReviews, [review])
    }

    func testVersionThreeRoundTripsStructuredManualAssignmentAuditPayload() throws {
        let before = ManualHaplotypeAssignment(
            sample: "AnimalA",
            locus: "MHC-A",
            slot: .h1,
            label: "Family A",
            colorTokenIndex: 2,
            diagnosticAlleles: ["A1*001"],
            notes: "preserved",
            assignmentID: "assignment-001",
            updatedAt: "2026-07-26T11:00:00Z",
            author: "Alice"
        )
        let after = ManualHaplotypeAssignment(
            sample: before.sample,
            locus: before.locus,
            slot: before.slot,
            label: "Family B",
            colorTokenIndex: 7,
            diagnosticAlleles: before.diagnosticAlleles,
            notes: before.notes,
            assignmentID: before.assignmentID,
            updatedAt: "2026-07-26T12:00:00Z",
            author: "Bob"
        )
        let payload = GenotypeAnnotationSidecar.ManualHaplotypeAssignmentAuditPayload(
            operationID: "operation-001",
            priorSidecarSHA256: String(repeating: "a", count: 64),
            before: before,
            after: after,
            copySourceSample: "AnimalB"
        )
        let audit = GenotypeAnnotationSidecar.AuditEntry(
            action: "updateManualHaplotypeAssignment",
            sample: "AnimalA",
            locus: "MHC-A",
            slot: .h1,
            before: "Family A",
            after: "Family B",
            color: "7",
            reason: "manual-haplotype-assignment",
            rationale: nil,
            author: "Bob",
            timestamp: "2026-07-26T12:00:00Z",
            manualHaplotypeAssignment: payload
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-26T10:00:00Z")
        sidecar.append(audit: audit)

        let decoded = try GenotypeAnnotationSidecar.decode(sidecar.encoded())

        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.auditLog, [audit])
        XCTAssertEqual(
            decoded.auditLog[0].manualHaplotypeAssignment?.before?.diagnosticAlleles,
            ["A1*001"]
        )
        XCTAssertEqual(decoded.auditLog[0].manualHaplotypeAssignment?.after?.assignmentID, "assignment-001")
        XCTAssertEqual(decoded.auditLog[0].manualHaplotypeAssignment?.copySourceSample, "AnimalB")
    }

    func testLegacyAuditEntryDecodesWithoutStructuredManualAssignmentPayload() throws {
        let json = Data(
            #"""
            {
              "schemaVersion": 2,
              "generatedAt": "2026-07-01T00:00:00Z",
              "auditLog": [{
                "action": "highlight",
                "sample": "S1",
                "locus": "MHC-A",
                "slot": "h1",
                "color": "#FFEB3B",
                "author": "Analyst",
                "timestamp": "2026-07-01T01:00:00Z"
              }]
            }
            """#.utf8
        )

        let decoded = try GenotypeAnnotationSidecar.decode(json)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.auditLog.count, 1)
        XCTAssertNil(decoded.auditLog[0].manualHaplotypeAssignment)
        XCTAssertEqual(decoded.auditLog[0].action, "highlight")
    }

    func testResolvedMatrixCommentsUsesLatestParseableTimestamp() {
        let target = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-B",
            genotype: "Mamu-I*01",
            stableClusterID: "cluster-b"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T00:00:00Z")
        sidecar.matrixComments = [
            .init(target: target, body: "Older.", author: "alice", timestamp: "2026-07-01T10:00:00Z"),
            .init(target: target, body: "Latest.", author: "bob", timestamp: "2026-07-01T10:01:00Z"),
        ]
        let originalComments = sidecar.matrixComments

        let resolved = sidecar.resolvedMatrixComments

        XCTAssertEqual(resolved[target]?.body, "Latest.")
        XCTAssertEqual(sidecar.matrixComments, originalComments)
    }

    func testResolvedMatrixCommentsUsesLastFileOrderForTiesAndUnparseableDates() throws {
        let tiedTarget = GenotypeAnnotationSidecar.MatrixTarget.row(locus: "MHC-B", genotype: "Mamu-I*01")
        let unparseableTarget = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "AnimalA")
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-01T00:00:00Z")
        sidecar.matrixComments = [
            .init(target: tiedTarget, body: "First tie.", author: "alice", timestamp: "2026-07-01T10:00:00Z"),
            .init(target: tiedTarget, body: "Last tie.", author: "bob", timestamp: "2026-07-01T10:00:00Z"),
            .init(target: unparseableTarget, body: "First invalid.", author: "alice", timestamp: "not-a-date"),
            .init(target: unparseableTarget, body: "Last invalid.", author: "bob", timestamp: "still-not-a-date"),
        ]
        let originalComments = sidecar.matrixComments
        let originalData = try sidecar.encoded()
        let sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolvedMatrixComments-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: sidecarURL) }
        try originalData.write(to: sidecarURL)

        let resolved = sidecar.resolvedMatrixComments

        XCTAssertEqual(resolved[tiedTarget]?.body, "Last tie.")
        XCTAssertEqual(resolved[unparseableTarget]?.body, "Last invalid.")
        XCTAssertEqual(sidecar.matrixComments, originalComments)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), originalData)
    }

    func testStableAuditDescriptionIncludesTargetKindAndStableClusterID() {
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*018:01:01:01_5nt_nov",
            sample: "AnimalA",
            stableClusterID: "cluster-a"
        )

        XCTAssertEqual(
            target.stableAuditDescription,
            "cell AnimalA MHC-A1 Mafa-A1*018:01:01:01_5nt_nov [cluster-a]"
        )
    }

    func testLegacySidecarDecodesWithEmptyAIHaplotypeReviewFields() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-05-22T00:00:00Z",
          "callOverrides": [],
          "cellHighlights": [],
          "rowHighlights": [],
          "sampleNotes": [],
          "cellComments": [],
          "sampleStatusFlags": [],
          "callStatusFlags": [],
          "smartCohorts": [],
          "manualHaplotypeAssignments": [],
          "settings": {
            "viewMode": "outline",
            "panelLayout": "aLeading",
            "cardDensity": "auto",
            "cardDensityThreshold": 30,
            "dropoutAbsolute": 50,
            "dropoutLocusFraction": 0.01
          },
          "auditLog": []
        }
        """.data(using: .utf8)!

        let decoded = try GenotypeAnnotationSidecar.decode(json)

        XCTAssertTrue(decoded.aiHaplotypeReviews.isEmpty)
        XCTAssertNil(decoded.activeAIHaplotypeReviewID)
        XCTAssertTrue(decoded.matrixStyles.isEmpty)
        XCTAssertTrue(decoded.matrixComments.isEmpty)
    }

    func testOverrideReasonTagsUseReviewInspectorVocabulary() {
        let rawValues = GenotypeAnnotationSidecar.OverrideReasonTag.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues, [
            "mis-call",
            "dropout-suspected",
            "cross-contamination",
            "novel",
            "pedigree-conflict",
            "analyst-judgment",
            "confirmed",
            "other",
        ])
    }

    func testOverrideReasonTagDecodesLegacyAliases() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(GenotypeAnnotationSidecar.OverrideReasonTag.self, from: Data(#""dropout""#.utf8)),
            .dropoutSuspected
        )
        XCTAssertEqual(
            try decoder.decode(GenotypeAnnotationSidecar.OverrideReasonTag.self, from: Data(#""contamination""#.utf8)),
            .crossContamination
        )
        XCTAssertEqual(
            try decoder.decode(GenotypeAnnotationSidecar.OverrideReasonTag.self, from: Data(#""misCall""#.utf8)),
            .misCall
        )
    }

    func testAuditLogAppendMaintainsLastEdited() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "t")
        sidecar.append(audit: .init(
            action: "highlight", sample: "S1", locus: "MHC-A", slot: .h1,
            before: nil, after: nil, color: "#FFEB3B",
            reason: nil, rationale: nil, author: "u", timestamp: "2026-05-22T10:00:00Z"
        ))
        XCTAssertEqual(sidecar.auditLog.count, 1)
        XCTAssertEqual(sidecar.lastEditedAt, "2026-05-22T10:00:00Z")
        XCTAssertEqual(sidecar.lastEditor, "u")
        sidecar.append(audit: .init(
            action: "override", sample: "S1", locus: "MHC-A", slot: .h1,
            before: "M2A", after: "A1_063", color: nil,
            reason: "contamination", rationale: "x",
            author: "v", timestamp: "2026-05-22T10:00:01Z"
        ))
        XCTAssertEqual(sidecar.auditLog.count, 2)
        XCTAssertEqual(sidecar.lastEditor, "v")
    }

    func testSidecarFilename() {
        XCTAssertEqual(GenotypeAnnotationSidecar.filename, "annotations.json")
    }

    func testDefaultSettings() {
        let settings = GenotypeAnnotationSidecar.Settings.default
        XCTAssertEqual(settings.viewMode, "outline")
        XCTAssertEqual(settings.panelLayout, "aLeading")
        XCTAssertEqual(settings.cardDensity, "auto")
        XCTAssertEqual(settings.cardDensityThreshold, 30)
        XCTAssertEqual(settings.dropoutAbsolute, 50)
        XCTAssertNil(settings.dropoutSampleFraction)
        // 1% per-locus default — the 5% default was overcalling
        // "too many genotypes" on real ONT bundles.
        XCTAssertEqual(settings.dropoutLocusFraction, 0.01)
        XCTAssertNil(settings.locusFractionOverrides)
    }
}
