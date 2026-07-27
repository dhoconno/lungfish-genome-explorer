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

    func testLabelInputContractTrimsNormalizesAndAcceptsFormulaLeadingLiterals() throws {
        XCTAssertEqual(
            try GenotypeManualHaplotypeAssignmentInputValidator.validatedLabel(
                "  Caf\u{0065}\u{0301}  "
            ),
            "Café"
        )
        for formulaLiteral in ["=M1+M2", "+M1", "-M2", "@family"] {
            XCTAssertEqual(
                try GenotypeManualHaplotypeAssignmentInputValidator.validatedLabel(
                    formulaLiteral
                ),
                formulaLiteral
            )
        }
    }

    func testLabelInputContractEnforcesUnicodeScalarLimitAndControlCharacters() throws {
        let exactlyMaximum = String(
            repeating: "🧬",
            count: GenotypeManualHaplotypeAssignmentInputValidator
                .maximumLabelUnicodeScalarCount
        )
        let tooLong = exactlyMaximum + "x"

        XCTAssertEqual(
            try GenotypeManualHaplotypeAssignmentInputValidator.validatedLabel(
                exactlyMaximum
            ).unicodeScalars.count,
            128
        )
        XCTAssertThrowsError(
            try GenotypeManualHaplotypeAssignmentInputValidator.validatedLabel(
                tooLong
            )
        ) { error in
            XCTAssertEqual(
                error as? GenotypeManualHaplotypeAssignmentInputValidator.ValidationError,
                .labelTooLong(maximumUnicodeScalars: 128)
            )
        }
        for invalid in ["", "   ", "Family\u{0000}A", "Family\u{0007}A"] {
            XCTAssertThrowsError(
                try GenotypeManualHaplotypeAssignmentInputValidator.validatedLabel(
                    invalid
                )
            )
        }
    }

    func testCatalogExcludesInvalidLabelsAndOrphanLoci() {
        let assignments = [
            assignment(sample: "S1", locus: "not-a-locus", slot: .h1, label: "Orphan", color: 1),
            assignment(sample: "S2", locus: "A", slot: .h1, label: "Bad\u{0007}", color: 2),
            assignment(sample: "S3", locus: "B", slot: .h1, label: String(repeating: "x", count: 129), color: 3),
            assignment(sample: "S4", locus: "DRB", slot: .h1, label: "=M1+M2", color: 4),
        ]

        let index = GenotypeManualHaplotypeAssignmentIndex(assignments: assignments)

        XCTAssertEqual(index.labelCatalog, [
            .init(label: "=M1+M2", colorTokenIndex: 4),
        ])
        XCTAssertNil(index.catalogEntry(for: "Orphan"))
    }

    func testCatalogReplacesInvalidColorIndicesWithCaseNormalizedDeterministicFallback() {
        let invalidLow = assignment(
            sample: "S1",
            locus: "A",
            slot: .h1,
            label: "Family Alpha",
            color: -1
        )
        let invalidHighCaseVariant = assignment(
            sample: "S2",
            locus: "B",
            slot: .h1,
            label: "FAMILY ALPHA",
            color: HaplotypeColorToken.canonicalPalette.count
        )
        let lowIndex = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [invalidLow]
        )
        let highIndex = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [invalidHighCaseVariant]
        )

        let expected = HaplotypeColorToken.assigned(
            forName: "family alpha"
        ).canonicalIndex
        XCTAssertEqual(lowIndex.labelCatalog[0].colorTokenIndex, expected)
        XCTAssertEqual(highIndex.labelCatalog[0].colorTokenIndex, expected)
        XCTAssertEqual(
            GenotypeManualHaplotypeAssignmentIndex(
                assignments: [invalidLow]
            ).labelCatalog[0].colorTokenIndex,
            expected
        )
    }

    func testCatalogPreservesEveryCanonicalPaletteIndex() {
        let assignments = HaplotypeColorToken.canonicalPalette.map { token in
            assignment(
                sample: "S\(token.canonicalIndex)",
                locus: "A",
                slot: .h1,
                label: "Label \(token.canonicalIndex)",
                color: token.canonicalIndex
            )
        }

        let index = GenotypeManualHaplotypeAssignmentIndex(assignments: assignments)

        XCTAssertEqual(
            Set(index.labelCatalog.map(\.colorTokenIndex)),
            Set(HaplotypeColorToken.canonicalPalette.map(\.canonicalIndex))
        )
    }

    func testOffsetEquivalentTimestampsTieBreakByLaterArrayPosition() {
        let first = assignment(
            sample: "S1",
            locus: "A",
            slot: .h1,
            label: "First",
            color: 1,
            id: "first",
            updatedAt: "2026-07-26T12:00:00Z",
            author: "Alice"
        )
        let equivalentLaterPosition = assignment(
            sample: "S1",
            locus: "A",
            slot: .h1,
            label: "Equivalent",
            color: 2,
            id: "second",
            updatedAt: "2026-07-26T07:00:00-05:00",
            author: "Bob"
        )

        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [first, equivalentLaterPosition]
        )

        XCTAssertEqual(
            index.assignment(sample: "S1", locus: .a, slot: .h1),
            equivalentLaterPosition
        )
    }

    func testValidStructuredTimestampBeatsMalformedAndMalformedTiesUseFileOrder() {
        let valid = assignment(
            sample: "S1",
            locus: "A",
            slot: .h1,
            label: "Valid",
            color: 1,
            updatedAt: "2026-07-26T12:00:00Z"
        )
        let malformed = assignment(
            sample: "S1",
            locus: "A",
            slot: .h1,
            label: "Malformed",
            color: 2,
            updatedAt: "tomorrow-ish"
        )
        let malformedLast = assignment(
            sample: "S2",
            locus: "B",
            slot: .h1,
            label: "Malformed Last",
            color: 3,
            updatedAt: "also-not-a-date"
        )
        let malformedFirst = assignment(
            sample: "S2",
            locus: "B",
            slot: .h1,
            label: "Malformed First",
            color: 4,
            updatedAt: "not-a-date"
        )

        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [valid, malformed, malformedFirst, malformedLast]
        )

        XCTAssertEqual(index.assignment(sample: "S1", locus: .a, slot: .h1), valid)
        XCTAssertEqual(
            index.assignment(sample: "S2", locus: .b, slot: .h1),
            malformedLast
        )
    }

    func testDuplicateHeavyConstructionKeepsBoundedResolvedState() {
        let assignments = (0..<20_000).map { position in
            assignment(
                sample: "S1",
                locus: position.isMultiple(of: 2) ? "MHC-A" : "A",
                slot: .h1,
                label: position.isMultiple(of: 2) ? "Family" : "FAMILY",
                color: position % HaplotypeColorToken.canonicalPalette.count
            )
        }

        let index = GenotypeManualHaplotypeAssignmentIndex(assignments: assignments)

        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.labelCatalog.count, 1)
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
