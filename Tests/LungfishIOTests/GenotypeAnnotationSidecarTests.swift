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
