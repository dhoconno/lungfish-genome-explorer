import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class FASTASelectionDetailFormatterTests: XCTestCase {
    func testRecordPreservesDescriptionAndWrapsAtEightyColumns() throws {
        let sequence = try Sequence(
            name: "cluster_ReadCount-12",
            description: "Savont consensus",
            alphabet: .dna,
            bases: String(repeating: "A", count: 85)
        )

        XCTAssertEqual(
            FASTASelectionDetailFormatter.record(for: sequence),
            ">cluster_ReadCount-12 Savont consensus\n"
                + String(repeating: "A", count: 80) + "\nAAAAA\n"
        )
    }

    func testTextJoinsRecordsWithOneBlankLine() throws {
        let first = try Sequence(name: "first", alphabet: .dna, bases: "ACGT")
        let second = try Sequence(name: "second", alphabet: .dna, bases: "TGCA")

        XCTAssertEqual(
            FASTASelectionDetailFormatter.text(for: [first, second]),
            ">first\nACGT\n\n>second\nTGCA\n"
        )
    }

    func testEmptySelectionProducesEmptyText() {
        XCTAssertEqual(FASTASelectionDetailFormatter.text(for: []), "")
    }

    func testEmptySequenceBodyStillProducesHeader() throws {
        let sequence = try Sequence(name: "empty", alphabet: .dna, bases: "")

        XCTAssertEqual(FASTASelectionDetailFormatter.record(for: sequence), ">empty\n")
    }
}
