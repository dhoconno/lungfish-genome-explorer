import XCTest
import LungfishCore
@testable import LungfishIO

final class GenotypeManualHaplotypeAssignmentIndexTests: XCTestCase {
    func testLookupCanonicalizesLocusAliasesAndDistinguishesH1AndH2() throws {
        let h1 = assignment(
            sample: "AnimalA",
            locus: "Mafa-A1*001:01",
            slot: .h1,
            label: "Family H1",
            color: 1
        )
        let h2 = assignment(
            sample: "AnimalA",
            locus: "MHC A",
            slot: .h2,
            label: "Family H2",
            color: 2
        )

        let index = GenotypeManualHaplotypeAssignmentIndex(assignments: [h1, h2])

        XCTAssertEqual(index.assignment(sample: "AnimalA", locus: .a, slot: .h1), h1)
        XCTAssertEqual(index.assignment(sample: "AnimalA", locus: .a, slot: .h2), h2)
        XCTAssertEqual(index.assignments(sample: "AnimalA", locus: .a).h1, h1)
        XCTAssertEqual(index.assignments(sample: "AnimalA", locus: .a).h2, h2)
        XCTAssertNil(index.assignment(sample: "AnimalA", locus: .b, slot: .h1))
    }

    func testNewestStructuredRecordWinsRegardlessOfArrayPosition() {
        let newest = assignment(
            sample: "AnimalA",
            locus: "MHC-A",
            slot: .h1,
            label: "Newest",
            color: 4,
            id: "newest-id",
            updatedAt: "2026-07-26T12:00:00Z",
            author: "Bob"
        )
        let older = assignment(
            sample: "AnimalA",
            locus: "A",
            slot: .h1,
            label: "Older",
            color: 2,
            id: "older-id",
            updatedAt: "2026-07-26T11:00:00Z",
            author: "Alice"
        )
        let trailingLegacy = assignment(
            sample: "AnimalA",
            locus: "MHC-A",
            slot: .h1,
            label: "Trailing Legacy",
            color: 6
        )

        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [newest, older, trailingLegacy]
        )

        XCTAssertEqual(
            index.assignment(sample: "AnimalA", locus: .a, slot: .h1),
            newest
        )
    }

    func testLastArrayPositionWinsForDuplicateLegacyRecords() {
        let first = assignment(
            sample: "AnimalA",
            locus: "MHC-DRB",
            slot: .h2,
            label: "First",
            color: 1
        )
        let last = assignment(
            sample: "AnimalA",
            locus: "DRB",
            slot: .h2,
            label: "Last",
            color: 7
        )

        let index = GenotypeManualHaplotypeAssignmentIndex(assignments: [first, last])

        XCTAssertEqual(index.assignment(sample: "AnimalA", locus: .drb, slot: .h2), last)
    }

    func testExactlyOneCurrentRecordExistsForEachSemanticKey() {
        let assignments = [
            assignment(sample: "S1", locus: "MHC-DQA", slot: .h1, label: "Old", color: 1),
            assignment(sample: "S1", locus: "DQA", slot: .h1, label: "Current", color: 2),
            assignment(sample: "S1", locus: "DQA", slot: .h2, label: "Other Slot", color: 3),
            assignment(sample: "S2", locus: "DQA", slot: .h1, label: "Other Sample", color: 4),
            assignment(sample: "S2", locus: "not-a-locus", slot: .h2, label: "Orphan", color: 5),
        ]

        let index = GenotypeManualHaplotypeAssignmentIndex(assignments: assignments)

        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(Set(index.currentAssignments.map {
            GenotypeManualHaplotypeAssignmentKey(
                sample: $0.sample,
                locus: GenotypeManualHaplotypeLocus(normalizing: $0.locus)!,
                slot: $0.slot
            )
        }).count, 3)
    }

    func testLabelCatalogDeduplicatesNFCAndCaseInsensitivelyPreservingWinningDisplayCaseAndColor() {
        let decomposed = "Caf\u{0065}\u{0301}"
        let assignments = [
            assignment(sample: "S1", locus: "A", slot: .h1, label: decomposed, color: 1),
            assignment(
                sample: "S2",
                locus: "B",
                slot: .h1,
                label: "CAFÉ",
                color: 7,
                id: "assignment-002",
                updatedAt: "2026-07-26T12:00:00Z",
                author: "Bob"
            ),
            assignment(sample: "S3", locus: "DRB", slot: .h1, label: "beta", color: 3),
            assignment(sample: "S4", locus: "DQA", slot: .h1, label: "Alpha", color: 2),
        ]

        let index = GenotypeManualHaplotypeAssignmentIndex(assignments: assignments)

        XCTAssertEqual(index.labelCatalog.map(\.label), ["Alpha", "beta", "CAFÉ"])
        XCTAssertEqual(index.catalogEntry(for: "café")?.label, "CAFÉ")
        XCTAssertEqual(index.catalogEntry(for: decomposed)?.colorTokenIndex, 7)
    }

    func testLabelCatalogUsesLastPositionForLegacyColorConflicts() {
        let assignments = [
            assignment(sample: "S1", locus: "A", slot: .h1, label: "Family", color: 1),
            assignment(sample: "S2", locus: "B", slot: .h1, label: "family", color: 6),
        ]

        let index = GenotypeManualHaplotypeAssignmentIndex(assignments: assignments)

        XCTAssertEqual(index.labelCatalog.count, 1)
        XCTAssertEqual(index.labelCatalog[0].label, "family")
        XCTAssertEqual(index.labelCatalog[0].colorTokenIndex, 6)
    }

    private func assignment(
        sample: String,
        locus: String,
        slot: HaplotypeSlot,
        label: String,
        color: Int,
        id: String? = nil,
        updatedAt: String? = nil,
        author: String? = nil
    ) -> ManualHaplotypeAssignment {
        ManualHaplotypeAssignment(
            sample: sample,
            locus: locus,
            slot: slot,
            label: label,
            colorTokenIndex: color,
            diagnosticAlleles: ["diagnostic"],
            notes: "preserve",
            assignmentID: id,
            updatedAt: updatedAt,
            author: author
        )
    }
}
