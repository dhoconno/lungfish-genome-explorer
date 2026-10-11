import Foundation
import XCTest
@testable import LungfishIO

/// The dismissed built-in cohorts in the sidecar settings (plan decision S13).
final class GenotypeAnnotationSidecarDismissalTests: XCTestCase {
    func testASidecarWithoutTheFieldDecodesAsNoDismissalsAndEncodesItsOwnBytes() throws {
        var older = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T10:00:00Z")
        older.settings.preferredSummaryViewMode = "matrix"
        older.settings.genotypeLocusDisplayOrder = ["MHC-B", "MHC-A"]
        let bytes = try older.encoded()
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("dismissedBuiltInSmartCohorts"))

        let decoded = try GenotypeAnnotationSidecar.decode(bytes)

        XCTAssertNil(decoded.settings.dismissedBuiltInSmartCohorts)
        XCTAssertEqual(try decoded.encoded(), bytes, "an older sidecar keeps its exact bytes")
    }

    func testAnOlderFileWrittenBeforeTheFieldExistedDecodes() throws {
        let legacy = #"""
        {"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":3,
         "settings":{"viewMode":"outline","panelLayout":"aLeading","cardDensity":"auto",
                     "cardDensityThreshold":30,"preferredSummaryViewMode":"matrix"},
         "smartCohorts":[]}
        """#

        let decoded = try GenotypeAnnotationSidecar.decode(Data(legacy.utf8))

        XCTAssertNil(decoded.settings.dismissedBuiltInSmartCohorts)
        XCTAssertEqual(decoded.settings.preferredSummaryViewMode, "matrix")
    }

    func testDismissalsRoundTripUnderTheirOwnKey() throws {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-22T10:00:00Z")
        sidecar.settings.dismissedBuiltInSmartCohorts = ["Homozygous", "Recombinants"]

        let bytes = try sidecar.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let settings = try XCTUnwrap(object["settings"] as? [String: Any])

        XCTAssertEqual(settings["dismissedBuiltInSmartCohorts"] as? [String], ["Homozygous", "Recombinants"])
        XCTAssertEqual(try GenotypeAnnotationSidecar.decode(bytes), sidecar)
    }
}
