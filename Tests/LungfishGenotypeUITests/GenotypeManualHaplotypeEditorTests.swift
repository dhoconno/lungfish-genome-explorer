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

    func testDraftRevisionTokenChangesOnlyWhenDraftContentChanges() {
        let model = makeModel(sample: "Animal-1")
        let initial = model.draftRevisionToken

        model.updateCopySearch("other sample")
        XCTAssertEqual(model.draftRevisionToken, initial)

        model.updateLabel("M2", locus: .a, slot: .h1)
        let edited = model.draftRevisionToken
        XCTAssertNotEqual(edited, initial)

        model.updateLabel("M2", locus: .a, slot: .h1)
        XCTAssertEqual(model.draftRevisionToken, edited)

        model.clear(locus: .a, slot: .h1)
        XCTAssertNotEqual(model.draftRevisionToken, edited)
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

    func testReloadAtomicallyRefreshesDraftCatalogCandidatesOrphansAndWritability() {
        let oldOrphan = ManualHaplotypeAssignment(
            sample: "Animal-1",
            locus: "MHC-OLD-OPAQUE",
            slot: .h1,
            label: "Old opaque",
            colorTokenIndex: 1,
            diagnosticAlleles: [],
            notes: "old"
        )
        let newOrphan = ManualHaplotypeAssignment(
            sample: "Animal-1",
            locus: "MHC-NEW-OPAQUE",
            slot: .h2,
            label: "New opaque",
            colorTokenIndex: 7,
            diagnosticAlleles: [],
            notes: "new"
        )
        let oldAssignments = [
            assignment(
                sample: "Animal-2",
                locus: .a,
                slot: .h1,
                label: "Old source",
                color: 1
            ),
            oldOrphan,
        ]
        let newAssignments = [
            assignment(
                sample: "Animal-1",
                locus: .b,
                slot: .h2,
                label: "Reloaded current",
                color: 3
            ),
            assignment(
                sample: "Animal-2",
                locus: .a,
                slot: .h1,
                label: "New source",
                color: 5
            ),
            newOrphan,
        ]
        var nextSnapshot = makeSnapshot(
            sample: "Animal-1",
            assignments: newAssignments,
            candidateSamples: ["Animal-2"],
            orphanLegacyAssignments: [newOrphan],
            isReadOnly: true
        )
        var savedDraft: GenotypeManualHaplotypeDraft?
        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: makeSnapshot(
                sample: "Animal-1",
                assignments: oldAssignments,
                candidateSamples: ["Animal-2"],
                orphanLegacyAssignments: [oldOrphan],
                isReadOnly: false
            ),
            onSave: {
                savedDraft = $0
                return self.cleanDraft(from: $0)
            },
            onReload: { nextSnapshot },
            onExport: {},
            announcementPoster: RecordingManualHaplotypeAnnouncements()
        )

        model.reload()

        XCTAssertEqual(model.draft[.b, .h2]?.label, "Reloaded current")
        XCTAssertEqual(model.copyCandidates.map(\.compactSummary), ["MHC-A H1 New source"])
        XCTAssertEqual(model.orphanLegacyAssignments, [newOrphan])
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(
            model.autocompleteSuggestions(
                matching: "new",
                locus: .a,
                slot: .h1
            ).map(\.label),
            ["New source"]
        )
        XCTAssertTrue(
            model.autocompleteSuggestions(
                matching: "old",
                locus: .a,
                slot: .h1
            ).isEmpty
        )

        nextSnapshot = makeSnapshot(
            sample: "Animal-1",
            assignments: newAssignments,
            candidateSamples: ["Animal-2"],
            orphanLegacyAssignments: [newOrphan],
            isReadOnly: false
        )
        model.reload()
        model.copyAssignments(from: "Animal-2")
        model.save()

        XCTAssertEqual(savedDraft?[.a, .h1]?.label, "New source")
        XCTAssertEqual(savedDraft?.copySource, "Animal-2")
    }

    func testCopyCandidatePresentationAndFilteringAreCachedPerChange() {
        let assignments = (0..<120).map { index in
            assignment(
                sample: "Animal-\(index)",
                locus: .a,
                slot: .h1,
                label: "Family \(index)",
                color: index % 8
            )
        }
        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: makeSnapshot(
                sample: "Selected",
                assignments: assignments,
                candidateSamples: assignments.map(\.sample)
            ),
            onSave: { self.cleanDraft(from: $0) },
            onReload: {
                self.makeSnapshot(
                    sample: "Selected",
                    assignments: assignments,
                    candidateSamples: assignments.map(\.sample)
                )
            },
            onExport: {},
            announcementPoster: RecordingManualHaplotypeAnnouncements()
        )
        let initialBuilds = model.copyCandidatePresentationBuildCount
        let initialEvaluations = model.copyFilterEvaluationCount

        for _ in 0..<20 {
            _ = model.copyCandidates
            _ = model.filteredCopyCandidates
        }

        XCTAssertEqual(initialBuilds, 120)
        XCTAssertEqual(model.copyCandidatePresentationBuildCount, initialBuilds)
        XCTAssertEqual(model.copyFilterEvaluationCount, initialEvaluations)

        model.updateCopySearch("family 11")

        XCTAssertEqual(model.copyFilterEvaluationCount, initialEvaluations + 1)
        XCTAssertLessThanOrEqual(model.copyFilterCandidateScanCount, 120)
        XCTAssertEqual(model.filteredCopyCandidates.map(\.sample), [
            "Animal-11",
            "Animal-110",
            "Animal-111",
            "Animal-112",
            "Animal-113",
            "Animal-114",
            "Animal-115",
            "Animal-116",
            "Animal-117",
            "Animal-118",
            "Animal-119",
        ])

        model.updateCopySearch("family 11")
        XCTAssertEqual(model.copyFilterEvaluationCount, initialEvaluations + 1)
    }

    func testContentTypographyScalesHeadingsCaptionsAndComboFieldsWithoutChangingAccessibility() {
        let notifications = NotificationCenter()
        let preference = MutableManualHaplotypeTextSizePreference(.custom(100))
        let provider = MutableManualHaplotypePreferredFonts(pointSize: 13)
        let typography = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        let model = makeModel(sample: "Animal-1")
        let view = GenotypeManualHaplotypeEditor(
            model: model,
            typographyModel: typography
        )
        let baseline = view.testingContentTypographyPointSizes
        let accessibilityLabels = model.rows.flatMap {
            [$0.h1.accessibilityLabel, $0.h2.accessibilityLabel]
        }

        preference.value = .custom(200)
        notifications.post(name: .contentTextSizeDidChange, object: nil)

        XCTAssertEqual(
            view.testingContentTypographyPointSizes.heading,
            baseline.heading * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            view.testingContentTypographyPointSizes.caption,
            baseline.caption * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            view.testingContentTypographyPointSizes.comboField,
            baseline.comboField * 2,
            accuracy: 0.01
        )
        XCTAssertEqual(
            model.rows.flatMap {
                [$0.h1.accessibilityLabel, $0.h2.accessibilityLabel]
            },
            accessibilityLabels
        )
    }

    func testSaveFailureKeepsDraftAndOffersRetryAndReload() {
        struct SaveFailure: Error, LocalizedError {
            var errorDescription: String? { "Sidecar changed elsewhere." }
        }
        var saveAttempts = 0
        let original = makeDraft(sample: "Animal-1", assignments: [])
        let announcements = RecordingManualHaplotypeAnnouncements()
        let model = GenotypeManualHaplotypeEditorModel(
            snapshot: GenotypeManualHaplotypeEditorModel.Snapshot(
                draft: original,
                copyCandidates: [],
                isReadOnly: false
            ),
            onSave: { draft in
                saveAttempts += 1
                if saveAttempts == 1 {
                    throw SaveFailure()
                }
                return self.cleanDraft(from: draft)
            },
            onReload: {
                GenotypeManualHaplotypeEditorModel.Snapshot(
                    draft: original,
                    copyCandidates: [],
                    isReadOnly: false
                )
            },
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
            snapshot: GenotypeManualHaplotypeEditorModel.Snapshot(
                draft: makeDraft(sample: "Animal-1", assignments: [orphan]),
                copyCandidates: [],
                orphanLegacyAssignments: [orphan],
                isReadOnly: false
            ),
            onSave: { self.cleanDraft(from: $0) },
            onReload: {
                GenotypeManualHaplotypeEditorModel.Snapshot(
                    draft: self.makeDraft(
                        sample: "Animal-1",
                        assignments: [orphan]
                    ),
                    copyCandidates: [],
                    orphanLegacyAssignments: [orphan],
                    isReadOnly: false
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
            snapshot: GenotypeManualHaplotypeEditorModel.Snapshot(
                draft: draft,
                copyCandidates: copyCandidates,
                isReadOnly: isReadOnly
            ),
            onSave: { self.cleanDraft(from: $0) },
            onReload: {
                GenotypeManualHaplotypeEditorModel.Snapshot(
                    draft: draft,
                    copyCandidates: copyCandidates,
                    isReadOnly: isReadOnly
                )
            },
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

    private func makeSnapshot(
        sample: String,
        assignments: [ManualHaplotypeAssignment],
        candidateSamples: [String],
        orphanLegacyAssignments: [ManualHaplotypeAssignment] = [],
        isReadOnly: Bool = false
    ) -> GenotypeManualHaplotypeEditorModel.Snapshot {
        let index = GenotypeManualHaplotypeAssignmentIndex(
            assignments: assignments
        )
        return GenotypeManualHaplotypeEditorModel.Snapshot(
            draft: GenotypeManualHaplotypeDraft(
                sample: sample,
                index: index
            ),
            copyCandidates: candidateSamples.map(
                index.sampleAssignments(for:)
            ),
            orphanLegacyAssignments: orphanLegacyAssignments,
            isReadOnly: isReadOnly
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

@MainActor
private final class MutableManualHaplotypeTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }
}

@MainActor
private final class MutableManualHaplotypePreferredFonts:
    ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(
                ofSize: pointSize,
                weight: .regular
            )
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: pointSize, weight: .semibold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }

    func canonicalUnscaledPointSize(
        for role: ContentTypography.Role
    ) -> CGFloat {
        13
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
