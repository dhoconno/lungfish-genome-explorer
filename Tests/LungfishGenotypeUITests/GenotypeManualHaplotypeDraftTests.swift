import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

final class GenotypeManualHaplotypeDraftTests: XCTestCase {
    func testDraftExposesFourteenSlotsInCanonicalWorkbookOrder() {
        let draft = makeDraft(sample: "Animal-1", assignments: [])

        XCTAssertEqual(
            draft.orderedSlots.map(\.address),
            GenotypeManualHaplotypeLocus.allCases.flatMap { locus in
                [
                    .init(locus: locus, slot: .h1),
                    .init(locus: locus, slot: .h2),
                ]
            }
        )
        XCTAssertEqual(draft.totalSlotCount, 14)
        XCTAssertEqual(draft.assignedSlotCount, 0)
        XCTAssertFalse(draft.isComplete)
        XCTAssertEqual(draft.completenessSummary, "0 of 14 assigned")
    }

    func testEditingNormalizesWhitespaceAndUnicodeButAcceptsFormulaLeadingLabels() throws {
        var draft = makeDraft(sample: " Animal-1 ", assignments: [])

        draft.setLabel("  e\u{301}  ", locus: .a, slot: .h1)
        draft.setLabel(" =SUM(A1:A2) ", locus: .a, slot: .h2)

        XCTAssertEqual(draft.sample, "Animal-1")
        XCTAssertEqual(draft[.a, .h1]?.label, "\u{e9}")
        XCTAssertEqual(draft[.a, .h2]?.label, "=SUM(A1:A2)")
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(
            try draft.validatedAssignments().map(\.label),
            ["\u{e9}", "=SUM(A1:A2)"]
        )
    }

    func testDraftReportsScalarLimitAndControlCharacterValidationWithoutDiscardingInput() {
        var draft = makeDraft(sample: "Animal-1", assignments: [])
        let tooLong = String(repeating: "x", count: 129)

        draft.setLabel(tooLong, locus: .a, slot: .h1)
        draft.setLabel("Line\u{0007}Bell", locus: .a, slot: .h2)

        XCTAssertEqual(draft[.a, .h1]?.label, tooLong)
        XCTAssertEqual(draft[.a, .h2]?.label, "Line\u{0007}Bell")
        XCTAssertEqual(
            draft.validationIssue(locus: .a, slot: .h1)?.error,
            .labelTooLong(maximumUnicodeScalars: 128)
        )
        XCTAssertEqual(
            draft.validationIssue(locus: .a, slot: .h2)?.error,
            .controlCharacter
        )
        XCTAssertEqual(draft.validationIssues.count, 2)
        XCTAssertFalse(draft.isValid)
        XCTAssertThrowsError(try draft.validatedAssignments())
    }

    func testSameLabelIsAllowedInH1AndH2() throws {
        var draft = makeDraft(sample: "Animal-1", assignments: [])

        draft.setLabel("M2", locus: .b, slot: .h1)
        draft.setLabel("M2", locus: .b, slot: .h2)

        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(try draft.validatedAssignments().count, 2)
        XCTAssertEqual(draft[.b, .h1]?.colorTokenIndex, 2)
        XCTAssertEqual(draft[.b, .h2]?.colorTokenIndex, 2)
    }

    func testAutocompleteIsCaseInsensitiveDeduplicatedAndUsesCatalogColors() {
        let assignments = [
            assignment(
                sample: "Animal-2",
                locus: .a,
                slot: .h1,
                label: "Alpha",
                color: 5,
                updatedAt: "2026-07-25T10:00:00Z"
            ),
            assignment(
                sample: "Animal-3",
                locus: .b,
                slot: .h1,
                label: "ALPHA",
                color: 6,
                updatedAt: "2026-07-25T11:00:00Z"
            ),
            assignment(
                sample: "Animal-4",
                locus: .drb,
                slot: .h1,
                label: "Beta",
                color: 7
            ),
        ]
        var draft = makeDraft(sample: "Animal-1", assignments: assignments)

        XCTAssertEqual(
            draft.autocompleteSuggestions(matching: "lPh"),
            [.init(label: "ALPHA", colorTokenIndex: 6)]
        )
        draft.setLabel("alpha", locus: .a, slot: .h1)

        XCTAssertEqual(draft[.a, .h1]?.label, "alpha")
        XCTAssertEqual(draft[.a, .h1]?.colorTokenIndex, 6)
    }

    func testSaveDraftUsesAnalysisCatalogColorForConflictingKnownLabel() throws {
        let selectedOlder = assignment(
            sample: "Animal-1",
            locus: .a,
            slot: .h1,
            label: "Shared Family",
            color: 2,
            updatedAt: "2026-07-25T10:00:00Z"
        )
        let analysisNewest = assignment(
            sample: "Animal-2",
            locus: .a,
            slot: .h1,
            label: "SHARED FAMILY",
            color: 7,
            updatedAt: "2026-07-25T11:00:00Z"
        )
        var draft = makeDraft(
            sample: "Animal-1",
            assignments: [selectedOlder, analysisNewest]
        )

        draft.setLabel("Another Family", locus: .b, slot: .h1)

        XCTAssertTrue(draft.isDirty)
        let savedKnownLabel = try XCTUnwrap(
            draft.validatedAssignments().first {
                $0.locus == GenotypeManualHaplotypeLocus.a.rawValue
                    && $0.slot == .h1
            }
        )
        XCTAssertEqual(savedKnownLabel.label, "Shared Family")
        XCTAssertEqual(savedKnownLabel.colorTokenIndex, 7)
    }

    func testNewLabelsReceiveStableDeterministicColors() {
        var first = makeDraft(sample: "Animal-1", assignments: [])
        var second = makeDraft(sample: "Animal-2", assignments: [])

        first.setLabel("Novel Family", locus: .dqa, slot: .h1)
        second.setLabel("Novel Family", locus: .dpb, slot: .h2)

        XCTAssertEqual(
            first[.dqa, .h1]?.colorTokenIndex,
            HaplotypeColorToken.assigned(forName: "Novel Family").canonicalIndex
        )
        XCTAssertEqual(
            first[.dqa, .h1]?.colorTokenIndex,
            second[.dpb, .h2]?.colorTokenIndex
        )
    }

    func testClearDirtyDiffAndCompletenessAreValueSemantic() {
        let existing = assignment(
            sample: "Animal-1",
            locus: .a,
            slot: .h1,
            label: "M1",
            color: 1
        )
        var draft = makeDraft(sample: "Animal-1", assignments: [existing])
        let unchangedCopy = draft

        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.assignedSlotCount, 1)
        XCTAssertEqual(draft.completenessSummary, "1 of 14 assigned")
        XCTAssertEqual(draft, unchangedCopy)

        draft.setLabel("  M1  ", locus: .a, slot: .h1)
        XCTAssertFalse(draft.isDirty)

        draft.clear(locus: .a, slot: .h1)
        XCTAssertTrue(draft.isDirty)
        XCTAssertEqual(draft.assignedSlotCount, 0)

        draft.setLabel("M1", locus: .a, slot: .h1)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft, unchangedCopy)
    }

    func testCopyUsesOnlySourceLabelsAndColorsWhilePreservingTargetScientificMetadata() throws {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Old",
            color: 1,
            diagnosticAlleles: ["Mafa-A1*001:01"],
            notes: "Target analyst note",
            assignmentID: "target-id",
            updatedAt: "2026-07-25T10:00:00Z",
            author: "Target Analyst"
        )
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Copied",
            color: 4,
            diagnosticAlleles: ["Do not copy"],
            notes: "Do not copy this note",
            assignmentID: "source-id",
            updatedAt: "2026-07-25T11:00:00Z",
            author: "Source Analyst"
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [target, source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )

        draft.copyAssignments(from: index.sampleAssignments(for: "Source"))

        XCTAssertEqual(draft.copySource, "Source")
        XCTAssertTrue(draft.isDirty)
        let copied = try XCTUnwrap(draft[.a, .h1])
        XCTAssertEqual(copied.label, "Copied")
        XCTAssertEqual(copied.colorTokenIndex, 4)
        XCTAssertEqual(copied.diagnosticAlleles, target.diagnosticAlleles)
        XCTAssertEqual(copied.notes, target.notes)
        XCTAssertEqual(copied.assignmentID, target.assignmentID)
        XCTAssertEqual(copied.updatedAt, target.updatedAt)
        XCTAssertEqual(copied.author, target.author)

        let saved = try XCTUnwrap(
            draft.validatedAssignments().first {
                $0.locus == GenotypeManualHaplotypeLocus.a.rawValue
                    && $0.slot == .h1
            }
        )
        XCTAssertEqual(saved.diagnosticAlleles, target.diagnosticAlleles)
        XCTAssertEqual(saved.notes, target.notes)
        XCTAssertEqual(saved.assignmentID, target.assignmentID)
    }

    func testCopyClearsSlotsMissingFromSourceAndDoesNotPersist() throws {
        let targetAssignments = [
            assignment(
                sample: "Target",
                locus: .a,
                slot: .h1,
                label: "A",
                color: 1
            ),
            assignment(
                sample: "Target",
                locus: .b,
                slot: .h2,
                label: "B",
                color: 2
            ),
        ]
        let sourceAssignments = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "Copied-A",
                color: 3
            ),
        ]
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: targetAssignments + sourceAssignments
        )
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GenotypeManualHaplotypeDraft-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sentinel = Data("persisted-sidecar-sentinel".utf8)
        try sentinel.write(to: scratch)
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )

        draft.copyAssignments(from: index.sampleAssignments(for: "Source"))

        XCTAssertEqual(draft[.a, .h1]?.label, "Copied-A")
        XCTAssertNil(draft[.b, .h2])
        XCTAssertEqual(draft.assignedSlotCount, 1)
        XCTAssertEqual(try Data(contentsOf: scratch), sentinel)
    }

    private func makeDraft(
        sample: String,
        assignments: [ManualHaplotypeAssignment]
    ) -> GenotypeManualHaplotypeDraft {
        GenotypeManualHaplotypeDraft(
            sample: sample,
            index: GenotypeManualHaplotypeAssignmentIndex(
                assignments: assignments
            )
        )
    }

    private func assignment(
        sample: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot,
        label: String,
        color: Int,
        diagnosticAlleles: [String] = [],
        notes: String = "",
        assignmentID: String? = nil,
        updatedAt: String? = nil,
        author: String? = nil
    ) -> ManualHaplotypeAssignment {
        ManualHaplotypeAssignment(
            sample: sample,
            locus: locus.rawValue,
            slot: slot,
            label: label,
            colorTokenIndex: color,
            diagnosticAlleles: diagnosticAlleles,
            notes: notes,
            assignmentID: assignmentID,
            updatedAt: updatedAt,
            author: author
        )
    }
}
