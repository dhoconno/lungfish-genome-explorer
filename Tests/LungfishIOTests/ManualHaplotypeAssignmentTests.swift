import XCTest
import LungfishCore
@testable import LungfishIO

final class ManualHaplotypeAssignmentTests: XCTestCase {
    func testRoundTrip() throws {
        let a = ManualHaplotypeAssignment(
            sample: "S1", locus: "MHC-A", slot: .h1, label: "Custom1",
            colorTokenIndex: 3, diagnosticAlleles: ["A1*001"], notes: "novel"
        )
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(ManualHaplotypeAssignment.self, from: data)
        XCTAssertEqual(decoded, a)
    }

    func testGroupedByLabel() {
        let assignments = [
            ManualHaplotypeAssignment(sample: "S1", locus: "MHC-A", slot: .h1,
                                      label: "Custom1", colorTokenIndex: 1,
                                      diagnosticAlleles: ["A"], notes: ""),
            ManualHaplotypeAssignment(sample: "S2", locus: "MHC-A", slot: .h1,
                                      label: "Custom1", colorTokenIndex: 1,
                                      diagnosticAlleles: ["A"], notes: ""),
            ManualHaplotypeAssignment(sample: "S3", locus: "MHC-A", slot: .h1,
                                      label: "Custom2", colorTokenIndex: 2,
                                      diagnosticAlleles: ["B"], notes: ""),
        ]
        let groups = ManualHaplotypeAssignment.groupedByLabel(assignments)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups["Custom1"]?.count, 2)
        XCTAssertEqual(groups["Custom2"]?.count, 1)
    }

    func testGroupedByLocusAndLabel() {
        let assignments = [
            ManualHaplotypeAssignment(sample: "S1", locus: "MHC-A", slot: .h1,
                                      label: "Custom1", colorTokenIndex: 1,
                                      diagnosticAlleles: ["A"], notes: ""),
            ManualHaplotypeAssignment(sample: "S2", locus: "MHC-B", slot: .h1,
                                      label: "Custom1", colorTokenIndex: 1,
                                      diagnosticAlleles: ["B"], notes: ""),
        ]
        let groups = ManualHaplotypeAssignment.groupedByLocusAndLabel(assignments)
        XCTAssertEqual(groups.count, 2)
        XCTAssertNotNil(groups["MHC-A"])
        XCTAssertNotNil(groups["MHC-B"])
    }
}
