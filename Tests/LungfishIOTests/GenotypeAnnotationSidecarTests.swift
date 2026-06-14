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
