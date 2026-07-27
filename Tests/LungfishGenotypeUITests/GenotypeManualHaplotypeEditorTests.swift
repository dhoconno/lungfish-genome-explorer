import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeManualHaplotypeEditorTests: XCTestCase {
    func testRowsUseWorkbookOrderAndExposeLocusSlotAccessibility() {
        let model = makeModel(sample: "Animal-1")

        XCTAssertEqual(
            model.rows.map(\.locus),
            GenotypeManualHaplotypeLocus.allCases
        )
        XCTAssertEqual(model.rows.count, 7)
        XCTAssertEqual(model.rows[0].h1.accessibilityLabel, "MHC-A H1 haplotype label")
        XCTAssertEqual(model.rows[0].h2.accessibilityLabel, "MHC-A H2 haplotype label")
        XCTAssertEqual(model.rows[0].h1.clearAccessibilityLabel, "Clear MHC-A H1 haplotype")
        XCTAssertEqual(model.rows[6].h2.accessibilityLabel, "MHC-DPB H2 haplotype label")
        XCTAssertEqual(
            Set(model.rows.flatMap { [$0.h1.accessibilityIdentifier, $0.h2.accessibilityIdentifier] }).count,
            14
        )
    }

    func testFreeFormEditingUsesAutocompleteAndAnnouncesResultsAndValidation() {
        let announcements = RecordingManualHaplotypeAnnouncements()
        let catalogAssignments = [
            assignment(
                sample: "Animal-2",
                locus: .a,
                slot: .h1,
                label: "Alpha Family",
                color: 4
            ),
            assignment(
                sample: "Animal-3",
                locus: .b,
                slot: .h1,
                label: "Beta Family",
                color: 5
            ),
        ]
        let model = makeModel(
            sample: "Animal-1",
            assignments: catalogAssignments,
            announcements: announcements
        )

        model.updateLabel("alp", locus: .a, slot: .h1)

        XCTAssertEqual(model.draft[.a, .h1]?.label, "alp")
        XCTAssertEqual(
            model.autocompleteSuggestions(
                matching: "ALP",
                locus: .a,
                slot: .h1
            ).map(\.label),
            ["Alpha Family"]
        )
        XCTAssertEqual(
            announcements.messages,
            ["1 autocomplete suggestion for MHC-A H1. Label is valid."]
        )

        model.updateLabel("bad\u{0007}", locus: .a, slot: .h1)

        XCTAssertFalse(model.draft.isValid)
        XCTAssertEqual(
            announcements.messages.last,
            "0 autocomplete suggestions for MHC-A H1. A manual haplotype label must not contain control characters."
        )
    }

    func testSaveAvailabilityTracksDirtyValidationAndReadOnlyState() {
        let writable = makeModel(sample: "Animal-1")
        XCTAssertFalse(writable.canSave)
        XCTAssertNotNil(writable.emptyStateMessage)

        writable.updateLabel("M2", locus: .a, slot: .h1)
        XCTAssertTrue(writable.canSave)
        XCTAssertNil(writable.emptyStateMessage)

        writable.updateLabel("", locus: .a, slot: .h1)
        XCTAssertFalse(writable.canSave)

        writable.clear(locus: .a, slot: .h1)
        XCTAssertFalse(writable.canSave)

        let readOnly = makeModel(sample: "Animal-1", isReadOnly: true)
        readOnly.updateLabel("M2", locus: .a, slot: .h1)
        XCTAssertFalse(readOnly.draft.isDirty)
        XCTAssertFalse(readOnly.canSave)
        XCTAssertEqual(
            readOnly.readOnlyMessage,
            "This bundle is read-only. Save a writable copy to edit assignments."
        )
    }

    func testCopyPickerSearchesOtherSamplesAndReportsCompleteness() {
        let assignments = [
            assignment(
                sample: "Animal-2",
                locus: .a,
                slot: .h1,
                label: "M2",
                color: 2
            ),
            assignment(
                sample: "Animal-2",
                locus: .b,
                slot: .h2,
                label: "M4",
                color: 4
            ),
            assignment(
                sample: "Control-7",
                locus: .dqa,
                slot: .h1,
                label: "Control Family",
                color: 6
            ),
        ]
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: assignments
        )
        let model = makeModel(
            sample: "Animal-1",
            assignments: assignments,
            copyCandidates: [
                index.sampleAssignments(for: "Animal-2"),
                index.sampleAssignments(for: "Control-7"),
            ]
        )

        XCTAssertEqual(
            model.copyCandidates.map(\.completenessSummary),
            ["2 of 14 assigned", "1 of 14 assigned"]
        )
        model.updateCopySearch("control")
        XCTAssertEqual(model.filteredCopyCandidates.map(\.sample), ["Control-7"])
        XCTAssertTrue(
            model.filteredCopyCandidates[0].accessibilityLabel.contains(
                "1 of 14 assigned"
            )
        )

        model.copyAssignments(from: "Control-7")

        XCTAssertEqual(model.draft.copySource, "Control-7")
        XCTAssertEqual(model.draft[.dqa, .h1]?.label, "Control Family")
        XCTAssertTrue(model.canSave)
    }

    func testSaveFailureKeepsDraftAndOffersRetryAndReload() {
        struct SaveFailure: Error, LocalizedError {
            var errorDescription: String? { "Sidecar changed elsewhere." }
        }
        var saveAttempts = 0
        let original = makeDraft(sample: "Animal-1", assignments: [])
        let announcements = RecordingManualHaplotypeAnnouncements()
        let model = GenotypeManualHaplotypeEditorModel(
            draft: original,
            copyCandidates: [],
            isReadOnly: false,
            onSave: { draft in
                saveAttempts += 1
                if saveAttempts == 1 {
                    throw SaveFailure()
                }
                return self.cleanDraft(from: draft)
            },
            onReload: { original },
            onExport: {},
            announcementPoster: announcements
        )
        model.updateLabel("M2", locus: .a, slot: .h1)

        model.save()

        XCTAssertEqual(saveAttempts, 1)
        XCTAssertTrue(model.draft.isDirty)
        XCTAssertEqual(model.persistenceErrorMessage, "Sidecar changed elsewhere.")
        XCTAssertTrue(model.showsRecoveryActions)
        XCTAssertEqual(
            announcements.messages.last,
            "Could not save haplotype assignments for Animal-1. Sidecar changed elsewhere."
        )

        model.retry()

        XCTAssertEqual(saveAttempts, 2)
        XCTAssertFalse(model.draft.isDirty)
        XCTAssertNil(model.persistenceErrorMessage)
        XCTAssertEqual(
            announcements.messages.last,
            "Saved haplotype assignments for Animal-1."
        )

        model.updateLabel("M3", locus: .a, slot: .h1)
        model.save()
        model.reload()

        XCTAssertFalse(model.draft.isDirty)
        XCTAssertNil(model.persistenceErrorMessage)
        XCTAssertEqual(
            announcements.messages.last,
            "Reloaded haplotype assignments for Animal-1."
        )
    }

    func testEmptyCopyStateAndExportActionRemainAvailable() {
        var exportCount = 0
        let model = makeModel(
            sample: "Animal-1",
            onExport: { exportCount += 1 }
        )

        XCTAssertEqual(model.copyEmptyStateMessage, "No other samples are available to copy.")
        XCTAssertTrue(model.canExport)

        model.export()

        XCTAssertEqual(exportCount, 1)
    }

    func testOrphanOnlyLegacyAssignmentsAreReadOnlyAndNotReportedAsEmpty() {
        let orphan = ManualHaplotypeAssignment(
            sample: "Animal-1",
            locus: "MHC-OPAQUE",
            slot: .h2,
            label: "Legacy Opaque",
            colorTokenIndex: 8,
            diagnosticAlleles: ["opaque"],
            notes: "preserve exactly"
        )
        let model = GenotypeManualHaplotypeEditorModel(
            draft: makeDraft(sample: "Animal-1", assignments: [orphan]),
            copyCandidates: [],
            orphanLegacyAssignments: [orphan],
            isReadOnly: false,
            onSave: { self.cleanDraft(from: $0) },
            onReload: {
                self.makeDraft(
                    sample: "Animal-1",
                    assignments: [orphan]
                )
            },
            onExport: {},
            announcementPoster: RecordingManualHaplotypeAnnouncements()
        )

        XCTAssertNil(model.emptyStateMessage)
        XCTAssertEqual(
            model.orphanLegacyWarningMessage,
            "1 legacy assignment uses an unrecognized locus. It is read-only and will be preserved when recognized assignments are saved."
        )
        XCTAssertEqual(model.orphanLegacyAssignments, [orphan])
        XCTAssertFalse(model.canSave)

        model.updateLabel("M2", locus: .a, slot: .h1)
        model.save()

        XCTAssertEqual(model.orphanLegacyAssignments, [orphan])
        XCTAssertNil(model.persistenceErrorMessage)
    }

    private func makeModel(
        sample: String,
        assignments: [ManualHaplotypeAssignment] = [],
        copyCandidates:
            [GenotypeManualHaplotypeAssignmentIndex.SampleAssignments] = [],
        isReadOnly: Bool = false,
        onExport: @escaping () -> Void = {},
        announcements: any AccessibilityAnnouncementPosting =
            RecordingManualHaplotypeAnnouncements()
    ) -> GenotypeManualHaplotypeEditorModel {
        let draft = makeDraft(sample: sample, assignments: assignments)
        return GenotypeManualHaplotypeEditorModel(
            draft: draft,
            copyCandidates: copyCandidates,
            isReadOnly: isReadOnly,
            onSave: { self.cleanDraft(from: $0) },
            onReload: { draft },
            onExport: onExport,
            announcementPoster: announcements
        )
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

    private func cleanDraft(
        from draft: GenotypeManualHaplotypeDraft
    ) -> GenotypeManualHaplotypeDraft {
        let assignments = (try? draft.validatedAssignments()) ?? []
        return makeDraft(sample: draft.sample, assignments: assignments)
    }

    private func assignment(
        sample: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot,
        label: String,
        color: Int
    ) -> ManualHaplotypeAssignment {
        ManualHaplotypeAssignment(
            sample: sample,
            locus: locus.rawValue,
            slot: slot,
            label: label,
            colorTokenIndex: color,
            diagnosticAlleles: [],
            notes: ""
        )
    }
}

private final class RecordingManualHaplotypeAnnouncements:
    AccessibilityAnnouncementPosting {
    private(set) var messages: [String] = []

    func post(
        _ message: String,
        priority: ContentAccessibilityAnnouncementPriority
    ) {
        messages.append(message)
    }
}
