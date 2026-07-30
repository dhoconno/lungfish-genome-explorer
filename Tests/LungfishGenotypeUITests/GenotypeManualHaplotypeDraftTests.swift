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
        let normalizedLabel = try! GenotypeManualHaplotypeAssignmentInputValidator
            .normalizedLabelKey(for: "Novel Family")

        first.setLabel("Novel Family", locus: .dqa, slot: .h1)
        second.setLabel("Novel Family", locus: .dpb, slot: .h2)

        XCTAssertEqual(
            first[.dqa, .h1]?.colorTokenIndex,
            HaplotypeColorToken.assigned(
                forName: normalizedLabel
            ).canonicalIndex
        )
        XCTAssertEqual(
            first[.dqa, .h1]?.colorTokenIndex,
            second[.dpb, .h2]?.colorTokenIndex
        )
    }

    func testCaseInsensitiveVariantsShareColorWithinDraftAndPreserveDisplayText() {
        var draft = makeDraft(sample: "Animal-1", assignments: [])

        draft.setLabel("m2", locus: .a, slot: .h1)
        draft.setLabel("M2", locus: .a, slot: .h2)
        draft.setLabel("novel family", locus: .b, slot: .h1)
        draft.setLabel("Novel Family", locus: .b, slot: .h2)

        XCTAssertEqual(draft[.a, .h1]?.label, "m2")
        XCTAssertEqual(draft[.a, .h2]?.label, "M2")
        XCTAssertEqual(draft[.a, .h1]?.colorTokenIndex, 2)
        XCTAssertEqual(draft[.a, .h2]?.colorTokenIndex, 2)
        XCTAssertEqual(draft[.b, .h1]?.label, "novel family")
        XCTAssertEqual(draft[.b, .h2]?.label, "Novel Family")
        XCTAssertEqual(
            draft[.b, .h1]?.colorTokenIndex,
            draft[.b, .h2]?.colorTokenIndex
        )
    }

    func testCaseInsensitiveFallbackIsStableAcrossOppositeDraftEntryOrders() {
        var titleCaseFirst = makeDraft(
            sample: "Animal-1",
            assignments: []
        )
        var lowercaseFirst = makeDraft(
            sample: "Animal-2",
            assignments: []
        )

        titleCaseFirst.setLabel(
            "Novel Family",
            locus: .a,
            slot: .h1
        )
        titleCaseFirst.setLabel(
            "novel family",
            locus: .a,
            slot: .h2
        )
        lowercaseFirst.setLabel(
            "novel family",
            locus: .a,
            slot: .h1
        )
        lowercaseFirst.setLabel(
            "Novel Family",
            locus: .a,
            slot: .h2
        )

        XCTAssertEqual(
            titleCaseFirst[.a, .h1]?.colorTokenIndex,
            lowercaseFirst[.a, .h1]?.colorTokenIndex
        )
        XCTAssertEqual(
            titleCaseFirst[.a, .h2]?.colorTokenIndex,
            lowercaseFirst[.a, .h2]?.colorTokenIndex
        )
        XCTAssertEqual(titleCaseFirst[.a, .h1]?.label, "Novel Family")
        XCTAssertEqual(lowercaseFirst[.a, .h1]?.label, "novel family")
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

    func testSelectiveCopyAppliesIndependentH1AndH2Subsets() {
        let targetAssignments = [
            assignment(
                sample: "Target",
                locus: .a,
                slot: .h1,
                label: "Target-A-H1",
                color: 1
            ),
            assignment(
                sample: "Target",
                locus: .a,
                slot: .h2,
                label: "Target-A-H2",
                color: 2
            ),
        ]
        let sourceAssignments = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "Source-A-H1",
                color: 3
            ),
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h2,
                label: "Source-A-H2",
                color: 4
            ),
        ]
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: targetAssignments + sourceAssignments
        )
        let h1 = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        var h1Draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        var h2Draft = h1Draft

        let h1Result = h1Draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [h1]
        )
        let h2 = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h2
        )
        let h2Result = h2Draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [h2]
        )

        XCTAssertEqual(h1Result.applied, [h1])
        XCTAssertEqual(h1Draft[.a, .h1]?.label, "Source-A-H1")
        XCTAssertEqual(h1Draft[.a, .h2]?.label, "Target-A-H2")
        XCTAssertEqual(h2Result.applied, [h2])
        XCTAssertEqual(h2Draft[.a, .h1]?.label, "Target-A-H1")
        XCTAssertEqual(h2Draft[.a, .h2]?.label, "Source-A-H2")
    }

    func testSelectiveCopyLeavesEveryUnselectedSlotExactlyEqual() {
        let targetAssignments = [
            assignment(
                sample: "Target",
                locus: .a,
                slot: .h1,
                label: "Target-A-H1",
                color: 1
            ),
            assignment(
                sample: "Target",
                locus: .b,
                slot: .h2,
                label: "Target-B-H2",
                color: 2,
                diagnosticAlleles: ["B*001"],
                notes: "Keep exactly"
            ),
        ]
        let sourceAssignments = [
            assignment(
                sample: "Source",
                locus: .a,
                slot: .h1,
                label: "Source-A-H1",
                color: 3
            ),
            assignment(
                sample: "Source",
                locus: .b,
                slot: .h2,
                label: "Source-B-H2",
                color: 4
            ),
        ]
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: targetAssignments + sourceAssignments
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let selected = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        let before = Dictionary(
            uniqueKeysWithValues: draft.orderedSlots.map {
                ($0.address, $0.value)
            }
        )

        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [selected]
        )

        for slot in draft.orderedSlots where slot.address != selected {
            XCTAssertEqual(slot.value, before[slot.address]!)
        }
    }

    func testSelectiveCopyReportsBlankSourceWithoutClearingTarget() {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Keep",
            color: 1
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [target]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Blank Source"),
            addresses: [address]
        )

        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(
            result.skipped,
            [.init(address: address, reason: .sourceMissing)]
        )
        XCTAssertEqual(draft[.a, .h1]?.label, "Keep")
        XCTAssertFalse(draft.isDirty)
    }

    func testSelectiveCopyBlocksDifferentLabelOverDiagnosticAllelesOnly() {
        assertSelectiveCopyBlockedByHiddenMetadata(
            diagnosticAlleles: ["Mafa-A1*001:01"],
            notes: ""
        )
    }

    func testSelectiveCopyBlocksDifferentLabelOverNotesOnly() {
        assertSelectiveCopyBlockedByHiddenMetadata(
            diagnosticAlleles: [],
            notes: "Analyst note"
        )
    }

    func testSelectiveCopyBlocksDifferentLabelOverDiagnosticsAndNotes() {
        assertSelectiveCopyBlockedByHiddenMetadata(
            diagnosticAlleles: ["Mafa-A1*001:01"],
            notes: "Analyst note"
        )
    }

    func testSelectiveCopyAllowsSameNormalizedLabelAndPreservesTargetMetadata() throws {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Family One",
            color: 1,
            diagnosticAlleles: ["Mafa-A1*001:01"],
            notes: "Target note",
            assignmentID: "target-id",
            updatedAt: "2026-07-25T10:00:00Z",
            author: "Target Analyst"
        )
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "family one",
            color: 4,
            diagnosticAlleles: ["source diagnostic"],
            notes: "Source note",
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
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address]
        )

        XCTAssertEqual(result.applied, [address])
        XCTAssertEqual(result.skipped, [])
        let value = try XCTUnwrap(draft[.a, .h1])
        XCTAssertEqual(value.label, "family one")
        XCTAssertEqual(value.diagnosticAlleles, target.diagnosticAlleles)
        XCTAssertEqual(value.notes, target.notes)
        XCTAssertEqual(value.assignmentID, target.assignmentID)
        XCTAssertEqual(value.updatedAt, target.updatedAt)
        XCTAssertEqual(value.author, target.author)
    }

    func testSelectiveCopyIntoEmptyTargetHasEmptyHiddenMetadata() throws {
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Copied",
            color: 4,
            diagnosticAlleles: ["Do not copy"],
            notes: "Do not copy",
            assignmentID: "source-id",
            updatedAt: "2026-07-25T11:00:00Z",
            author: "Source Analyst"
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address]
        )

        XCTAssertEqual(result.applied, [address])
        let value = try XCTUnwrap(draft[.a, .h1])
        XCTAssertEqual(value.diagnosticAlleles, [])
        XCTAssertEqual(value.notes, "")
        XCTAssertNil(value.assignmentID)
        XCTAssertNil(value.updatedAt)
        XCTAssertNil(value.author)
    }

    func testSelectiveCopyDoesNotCopySourceMetadataAndPreservesTargetIdentity() throws {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Old",
            color: 1,
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
            notes: "Do not copy",
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
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address]
        )

        let value = try XCTUnwrap(draft[.a, .h1])
        XCTAssertEqual(value.diagnosticAlleles, [])
        XCTAssertEqual(value.notes, "")
        XCTAssertEqual(value.assignmentID, target.assignmentID)
        XCTAssertEqual(value.updatedAt, target.updatedAt)
        XCTAssertEqual(value.author, target.author)
    }

    func testSelectiveCopyBlocksLegacyMetadataThatWasClearedOnlyInDraft() {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Old",
            color: 1,
            diagnosticAlleles: ["Mafa-A1*001:01"]
        )
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Copied",
            color: 4
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [target, source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        draft.clear(locus: .a, slot: .h1)
        XCTAssertTrue(
            draft.slotSnapshot(at: address)
                .hasHiddenCompatibilityMetadata
        )

        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address]
        )

        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(
            result.skipped,
            [
                .init(
                    address: address,
                    reason: .hiddenMetadataRequiresSavedClear
                )
            ]
        )
        XCTAssertNil(draft[.a, .h1])
    }

    func testSelectiveCopyRejectsSourceValueMissingFromExpectation() {
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Current",
            color: 4
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address],
            expectedSourceValues: [:]
        )

        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(
            result.skipped,
            [.init(address: address, reason: .sourceChanged)]
        )
        XCTAssertNil(draft[.a, .h1])
    }

    func testSelectiveCopyRejectsChangedExpectedSourceValue() {
        let expected = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Expected",
            color: 3
        )
        let current = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Current",
            color: 4
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [current]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address],
            expectedSourceValues: [address: expected]
        )

        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(
            result.skipped,
            [.init(address: address, reason: .sourceChanged)]
        )
        XCTAssertNil(draft[.a, .h1])
    }

    func testSelectiveNoOpCopyKeepsManualDirtyOrigin() {
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Same Value",
            color: 3
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        draft.setLabel("Same Value", locus: .a, slot: .h1)
        XCTAssertNil(draft.copySource)

        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address]
        )

        XCTAssertNil(draft.copySource)
        XCTAssertEqual(draft.dirtySlotAddresses, [address])
    }

    func testLegacyNoOpCopyKeepsManualDirtyOrigin() {
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Same Value",
            color: 3
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        draft.setLabel("Same Value", locus: .a, slot: .h1)
        XCTAssertNil(draft.copySource)

        draft.copyAssignments(
            from: index.sampleAssignments(for: "Source")
        )

        XCTAssertNil(draft.copySource)
        XCTAssertEqual(draft.dirtySlotAddresses, [address])
    }

    func testSelectiveCopyReportsChangedWhenExpectedSourceDisappeared() {
        let expected = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Expected",
            color: 3
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: []
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address],
            expectedSourceValues: [address: expected]
        )

        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(
            result.skipped,
            [.init(address: address, reason: .sourceChanged)]
        )
        XCTAssertFalse(draft.isDirty)
    }

    func testCopySourceReportsOneSourceForEveryFinalDirtySlot() {
        let sourceAssignments = [
            assignment(
                sample: " Source ",
                locus: .a,
                slot: .h1,
                label: "Copied-A",
                color: 3
            ),
            assignment(
                sample: " Source ",
                locus: .b,
                slot: .h2,
                label: "Copied-B",
                color: 4
            ),
        ]
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: sourceAssignments
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let addresses: Set<GenotypeManualHaplotypeDraft.SlotAddress> = [
            .init(locus: .a, slot: .h1),
            .init(locus: .b, slot: .h2),
        ]

        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: " Source "),
            addresses: addresses
        )

        XCTAssertEqual(draft.dirtySlotAddresses, addresses)
        XCTAssertEqual(draft.copySource, "Source")
    }

    func testCopySourceIsNilForFinalDirtySlotsCopiedFromMixedSources() {
        let sources = [
            assignment(
                sample: "Source-1",
                locus: .a,
                slot: .h1,
                label: "Copied-A",
                color: 3
            ),
            assignment(
                sample: "Source-2",
                locus: .b,
                slot: .h2,
                label: "Copied-B",
                color: 4
            ),
        ]
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: sources
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )

        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source-1"),
            addresses: [.init(locus: .a, slot: .h1)]
        )
        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source-2"),
            addresses: [.init(locus: .b, slot: .h2)]
        )

        XCTAssertNil(draft.copySource)
    }

    func testCopySourceIsNilWhenFinalDirtySlotsMixManualAndCopiedEdits() {
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Copied-A",
            color: 3
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )

        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [.init(locus: .a, slot: .h1)]
        )
        draft.setLabel("Manual-B", locus: .b, slot: .h2)

        XCTAssertNil(draft.copySource)
    }

    func testCopySourceTracksOverwrittenFinalOriginAndDropsRevertedOrigins() {
        let sources = [
            assignment(
                sample: "Source-1",
                locus: .a,
                slot: .h1,
                label: "Source One",
                color: 3
            ),
            assignment(
                sample: "Source-2",
                locus: .a,
                slot: .h1,
                label: "Source Two",
                color: 4
            ),
        ]
        let original = assignment(
            sample: "Target",
            locus: .b,
            slot: .h2,
            label: "Original",
            color: 2
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: sources + [original]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let copiedAddress = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source-1"),
            addresses: [copiedAddress]
        )
        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source-2"),
            addresses: [copiedAddress]
        )
        XCTAssertEqual(draft.copySource, "Source-2")

        draft.setLabel("Temporary", locus: .b, slot: .h2)
        XCTAssertNil(draft.copySource)

        draft.setLabel("Original", locus: .b, slot: .h2)
        XCTAssertEqual(draft.copySource, "Source-2")

        draft.clear(locus: .a, slot: .h1)
        XCTAssertNil(draft.copySource)
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.dirtySlotAddresses, [])
    }

    func testManualOverwriteOfCopiedSlotRemovesCopySource() {
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Copied",
            color: 3
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        _ = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address]
        )

        draft.setLabel("Manual", locus: .a, slot: .h1)

        XCTAssertNil(draft.copySource)
    }

    func testSlotSnapshotsExposeCanonicalDirtyAndHiddenMetadataState() {
        let existing = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Existing",
            color: 2,
            notes: "Hidden"
        )
        var draft = makeDraft(
            sample: "Target",
            assignments: [existing]
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        draft.setLabel("Edited", locus: .a, slot: .h1)

        XCTAssertEqual(
            draft.slotSnapshots.map(\.address),
            GenotypeManualHaplotypeDraft.orderedSlotAddresses
        )
        XCTAssertEqual(
            draft.slotSnapshot(at: address),
            .init(
                address: address,
                label: "Edited",
                colorTokenIndex: draft[.a, .h1]?.colorTokenIndex,
                hasHiddenCompatibilityMetadata: true,
                isDirty: true,
                hiddenCompatibilityLabels: ["Edited", "Existing"]
            )
        )
        XCTAssertEqual(draft.dirtySlotAddresses, [address])
    }

    func testSnapshotKeepsPersistedHiddenLabelProtectionAfterUnsavedRelabel() {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Old",
            color: 1,
            diagnosticAlleles: ["Mafa-A1*001:01"],
            notes: "Older notes"
        )
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "New",
            color: 2
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [target, source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )
        draft.setLabel("New", locus: .a, slot: .h1)

        XCTAssertTrue(
            draft.slotSnapshot(at: address)
                .blocksSelectiveCopy(sourceLabel: "New")
        )
        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address]
        )
        XCTAssertEqual(
            result.skipped,
            [
                .init(
                    address: address,
                    reason: .hiddenMetadataRequiresSavedClear
                ),
            ]
        )

        let unchanged = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        XCTAssertFalse(
            unchanged.slotSnapshot(at: address)
                .blocksSelectiveCopy(sourceLabel: " old ")
        )
    }

    private func assertSelectiveCopyBlockedByHiddenMetadata(
        diagnosticAlleles: [String],
        notes: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = assignment(
            sample: "Target",
            locus: .a,
            slot: .h1,
            label: "Old",
            color: 1,
            diagnosticAlleles: diagnosticAlleles,
            notes: notes
        )
        let source = assignment(
            sample: "Source",
            locus: .a,
            slot: .h1,
            label: "Copied",
            color: 4
        )
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: [target, source]
        )
        var draft = GenotypeManualHaplotypeDraft(
            sample: "Target",
            index: index
        )
        let address = GenotypeManualHaplotypeDraft.SlotAddress(
            locus: .a,
            slot: .h1
        )

        let result = draft.copySelectedAssignments(
            from: index.sampleAssignments(for: "Source"),
            addresses: [address]
        )

        XCTAssertEqual(result.applied, [], file: file, line: line)
        XCTAssertEqual(
            result.skipped,
            [
                .init(
                    address: address,
                    reason: .hiddenMetadataRequiresSavedClear
                )
            ],
            file: file,
            line: line
        )
        XCTAssertEqual(
            draft[.a, .h1]?.label,
            "Old",
            file: file,
            line: line
        )
        XCTAssertFalse(draft.isDirty, file: file, line: line)
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
