import Foundation
import XCTest
import LungfishIO
import LungfishCore
@testable import LungfishGenotypeUI

final class GenotypeViewportStyleCaptureTests: XCTestCase {
    func testAuthoritativeEmptyCellStyleDoesNotInheritRowFill() throws {
        let row = GenotypeViewportExportRow(genotype: "G", locus: "MHC-A", sampleCount: 1, totalUniqueReads: 5,
            sampleReads: ["S": 5], rowStyle: .init(fillColor: .init(red: 1, green: 0, blue: 0), borderColor: nil), cellStyles: [:],
            renderedRowStyle: .init(fillColor: .init(red: 1, green: 0, blue: 0), isBold: true), renderedCellStyles: ["S": .default])
        let snapshot = GenotypeViewportExportSnapshot(bundleURL: URL(fileURLWithPath: "/tmp/style"), analysisName: "Style", lens: "matrix", filters: [:], sampleNames: ["S"], rows: [row])
        let projection = GenotypeViewProjectionSerializer.makeProjection(from: snapshot)
        XCTAssertNil(projection.rows[0].cellColorsHex)
        XCTAssertEqual(projection.rows[0].cellStyles, [.init()])
        XCTAssertEqual(projection.rows[0].rowStyle?.fillHex, "#FF0000")
        XCTAssertEqual(projection.rows[0].rowStyle?.isBold, true)
        XCTAssertEqual(projection.rows[0].cells, ["5"])
    }

    func testTranslucentCapturedColorIsCompositedOnWhite() {
        XCTAssertEqual(GenotypeViewProjectionSerializer.normalizedHex(.init(red: 0, green: 0, blue: 1, alpha: 0.2)), "#CCCCFF")
        XCTAssertEqual(GenotypeViewProjectionSerializer.normalizedHex(.init(red: 1, green: 0, blue: 0, alpha: 0)), "#FFFFFF")
    }
}

/// Reads the actual serialized boundary, so omitting optional style fields
/// cannot silently pass a view-only style assertion.
func exportedStyle(_ snapshot: GenotypeViewportExportSnapshot, genotype: String, sample: String?) throws -> [String: Any] {
    let projection = GenotypeViewProjectionSerializer.makeProjection(from: snapshot)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any])
    let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
    let row = try XCTUnwrap(rows.first { $0["rawGenotype"] as? String == genotype })
    if let sample {
        let index = try XCTUnwrap(projection.sampleColumns.firstIndex(of: sample))
        return try XCTUnwrap((row["cellStyles"] as? [[String: Any]])?[index])
    }
    return try XCTUnwrap(row["rowStyle"] as? [String: Any])
}
