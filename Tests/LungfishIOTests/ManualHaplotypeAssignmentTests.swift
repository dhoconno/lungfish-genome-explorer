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

    func testLegacyJSONDecodesWithAbsentStructuredMetadata() throws {
        let json = Data(
            #"""
            {
              "sample": "S1",
              "locus": "MHC-A",
              "slot": "h1",
              "label": "Legacy",
              "colorTokenIndex": 4,
              "diagnosticAlleles": ["A1*001"],
              "notes": "retain this note"
            }
            """#.utf8
        )

        let decoded = try JSONDecoder().decode(ManualHaplotypeAssignment.self, from: json)

        XCTAssertNil(decoded.assignmentID)
        XCTAssertNil(decoded.updatedAt)
        XCTAssertNil(decoded.author)
        XCTAssertEqual(decoded.diagnosticAlleles, ["A1*001"])
        XCTAssertEqual(decoded.notes, "retain this note")
    }

    func testStructuredMetadataRoundTripsWithoutChangingScientificFields() throws {
        let assignment = ManualHaplotypeAssignment(
            sample: "S1",
            locus: "MHC-A",
            slot: .h2,
            label: "Family A",
            colorTokenIndex: 6,
            diagnosticAlleles: ["A1*001", "A2*002"],
            notes: "analyst note",
            assignmentID: "assignment-001",
            updatedAt: "2026-07-26T15:30:00Z",
            author: "Analyst"
        )

        let decoded = try JSONDecoder().decode(
            ManualHaplotypeAssignment.self,
            from: JSONEncoder().encode(assignment)
        )

        XCTAssertEqual(decoded, assignment)
        XCTAssertEqual(decoded.assignmentID, "assignment-001")
        XCTAssertEqual(decoded.updatedAt, "2026-07-26T15:30:00Z")
        XCTAssertEqual(decoded.author, "Analyst")
        XCTAssertEqual(decoded.diagnosticAlleles, ["A1*001", "A2*002"])
        XCTAssertEqual(decoded.notes, "analyst note")
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
