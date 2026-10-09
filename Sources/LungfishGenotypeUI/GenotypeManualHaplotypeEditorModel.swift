import AppKit
import Combine
import LungfishCore
import LungfishIO
import LungfishKit
import SwiftUI

@MainActor
final class GenotypeManualHaplotypeEditorModel: ObservableObject {
    struct SlotPresentation: Equatable, Sendable {
        let locus: GenotypeManualHaplotypeLocus
        let slot: HaplotypeSlot
        let label: String
        let colorTokenIndex: Int?
        let validationDescription: String?
        let accessibilityLabel: String
        let clearAccessibilityLabel: String
        let accessibilityIdentifier: String
    }

    struct RowPresentation: Equatable, Identifiable, Sendable {
        let locus: GenotypeManualHaplotypeLocus
        let h1: SlotPresentation
        let h2: SlotPresentation

        var id: String { locus.rawValue }
    }

    struct CopyCandidate: Equatable, Identifiable, Sendable {
        let sample: String
        let assignedSlotCount: Int
        let completenessSummary: String
        let compactSummary: String
        let accessibilityLabel: String

        var id: String { sample }
    }

    private struct CopyCandidateRecord: Sendable {
        let presentation: CopyCandidate
        let assignments:
            GenotypeManualHaplotypeAssignmentIndex.SampleAssignments
        let normalizedSearchKey: String
    }

    @MainActor
    struct Snapshot: Sendable {
        let draft: GenotypeManualHaplotypeDraft
        let orphanLegacyAssignments: [ManualHaplotypeAssignment]
        let isReadOnly: Bool
        private let copyCandidateRecords: [CopyCandidateRecord]
        private let copyCandidatePresentations: [CopyCandidate]
        private let copyCandidateBySample: [String: CopyCandidate]
        private let copyAssignmentsBySample: [
            String:
                GenotypeManualHaplotypeAssignmentIndex.SampleAssignments
        ]

        init(
            draft: GenotypeManualHaplotypeDraft,
            copyCandidates:
                [GenotypeManualHaplotypeAssignmentIndex.SampleAssignments],
            orphanLegacyAssignments: [ManualHaplotypeAssignment] = [],
            isReadOnly: Bool
        ) {
            var seenSamples = Set<String>()
            let candidates = copyCandidates.filter {
                $0.sample != draft.sample
                    && seenSamples.insert($0.sample).inserted
            }
            let records = candidates.map { assignments in
                let presentation =
                    GenotypeManualHaplotypeEditorModel.copyCandidate(
                        assignments
                    )
                return CopyCandidateRecord(
                    presentation: presentation,
                    assignments: assignments,
                    normalizedSearchKey:
                        GenotypeManualHaplotypeEditorModel
                            .normalizedSearchKey(
                                "\(presentation.sample) \(presentation.compactSummary)"
                            )
                )
            }
            self.draft = draft
            self.orphanLegacyAssignments = orphanLegacyAssignments
            self.isReadOnly = isReadOnly
            self.copyCandidateRecords = records
            self.copyCandidatePresentations =
                records.map(\.presentation)
            self.copyCandidateBySample = Dictionary(
                uniqueKeysWithValues: records.map {
                    ($0.presentation.sample, $0.presentation)
                }
            )
            self.copyAssignmentsBySample = Dictionary(
                uniqueKeysWithValues: records.map {
                    ($0.presentation.sample, $0.assignments)
                }
            )
        }

        private init(
            draft: GenotypeManualHaplotypeDraft,
            orphanLegacyAssignments: [ManualHaplotypeAssignment],
            isReadOnly: Bool,
            copyCandidateRecords: [CopyCandidateRecord],
            copyCandidatePresentations: [CopyCandidate],
            copyCandidateBySample: [String: CopyCandidate],
            copyAssignmentsBySample: [
                String:
                    GenotypeManualHaplotypeAssignmentIndex.SampleAssignments
            ]
        ) {
            self.draft = draft
            self.orphanLegacyAssignments = orphanLegacyAssignments
            self.isReadOnly = isReadOnly
            self.copyCandidateRecords = copyCandidateRecords
            self.copyCandidatePresentations =
                copyCandidatePresentations
            self.copyCandidateBySample = copyCandidateBySample
            self.copyAssignmentsBySample = copyAssignmentsBySample
        }

        fileprivate var copyCandidates: [CopyCandidate] {
            copyCandidatePresentations
        }

        fileprivate var copyCandidateCount: Int {
            copyCandidateRecords.count
        }

        fileprivate func copyAssignments(
            for sample: String
        ) -> GenotypeManualHaplotypeAssignmentIndex.SampleAssignments? {
            copyAssignmentsBySample[sample]
        }

        fileprivate func copyCandidate(
            for sample: String
        ) -> CopyCandidate? {
            copyCandidateBySample[sample]
        }

        fileprivate func filteredCopyCandidates(
            matching normalizedQuery: String
        ) -> [CopyCandidate] {
            guard !normalizedQuery.isEmpty else {
                return copyCandidates
            }
            return copyCandidateRecords.compactMap { record in
                record.normalizedSearchKey.contains(normalizedQuery)
                    ? record.presentation
                    : nil
            }
        }

        fileprivate func replacingDraft(
            _ draft: GenotypeManualHaplotypeDraft
        ) -> Snapshot {
            Snapshot(
                draft: draft,
                orphanLegacyAssignments: orphanLegacyAssignments,
                isReadOnly: isReadOnly,
                copyCandidateRecords: copyCandidateRecords,
                copyCandidatePresentations: copyCandidatePresentations,
                copyCandidateBySample: copyCandidateBySample,
                copyAssignmentsBySample: copyAssignmentsBySample
            )
        }
    }

    private struct EditorState: Sendable {
        let snapshot: Snapshot
        let filteredCopyCandidates: [CopyCandidate]
    }

    @Published private var editorState: EditorState
    @Published private(set) var persistenceErrorMessage: String?
    @Published private(set) var copySearchText = ""
    @Published private(set) var draftRevisionToken = UUID()

    private let onSave:
        (GenotypeManualHaplotypeDraft) throws
            -> GenotypeManualHaplotypeDraft
    private let onReload: () throws -> Snapshot
    private let onDidSave: () -> Void
    private let announcementPoster: any AccessibilityAnnouncementPosting
    private var preparedDraft: GenotypeManualHaplotypeDraft?

    private(set) var copyCandidatePresentationBuildCount: Int
    private(set) var copyFilterEvaluationCount = 1
    private(set) var copyFilterCandidateScanCount = 0

    init(
        snapshot: Snapshot,
        onSave: @escaping (
            GenotypeManualHaplotypeDraft
        ) throws -> GenotypeManualHaplotypeDraft,
        onReload: @escaping () throws -> Snapshot,
        onDidSave: @escaping () -> Void = {},
        announcementPoster: any AccessibilityAnnouncementPosting =
            AccessibilityAnnouncementPoster()
    ) {
        self.editorState = EditorState(
            snapshot: snapshot,
            filteredCopyCandidates: snapshot.copyCandidates
        )
        self.copyCandidatePresentationBuildCount =
            snapshot.copyCandidateCount
        self.onSave = onSave
        self.onReload = onReload
        self.onDidSave = onDidSave
        self.announcementPoster = announcementPoster
    }

    private var snapshot: Snapshot { editorState.snapshot }

    var draft: GenotypeManualHaplotypeDraft { snapshot.draft }
    var isReadOnly: Bool { snapshot.isReadOnly }
    var orphanLegacyAssignments: [ManualHaplotypeAssignment] {
        snapshot.orphanLegacyAssignments
    }
    var filteredCopyCandidates: [CopyCandidate] {
        editorState.filteredCopyCandidates
    }

    var rows: [RowPresentation] {
        GenotypeManualHaplotypeLocus.allCases.map { locus in
            RowPresentation(
                locus: locus,
                h1: slotPresentation(locus: locus, slot: .h1),
                h2: slotPresentation(locus: locus, slot: .h2)
            )
        }
    }

    var copyCandidates: [CopyCandidate] {
        snapshot.copyCandidates
    }

    var selectiveCopyTargetSlots: [
        GenotypeManualHaplotypeDraft.SlotAddress:
            GenotypeManualHaplotypeDraft.SlotSnapshot
    ] {
        Dictionary(
            uniqueKeysWithValues: draft.slotSnapshots.map {
                ($0.address, $0)
            }
        )
    }

    var canSave: Bool {
        !isReadOnly && draft.isDirty && draft.isValid
    }

    var emptyStateMessage: String? {
        guard draft.assignedSlotCount == 0,
              orphanLegacyAssignments.isEmpty else {
            return nil
        }
        return "No assignments yet. Enter a label or copy from another sample."
    }

    var orphanLegacyWarningMessage: String? {
        let count = orphanLegacyAssignments.count
        guard count > 0 else { return nil }
        let noun = count == 1 ? "assignment" : "assignments"
        let verb = count == 1 ? "uses" : "use"
        let pronoun = count == 1 ? "It is" : "They are"
        return "\(count) legacy \(noun) \(verb) an unrecognized locus. \(pronoun) read-only and will be preserved when recognized assignments are saved."
    }

    var copyEmptyStateMessage: String? {
        guard snapshot.copyCandidateCount == 0 else { return nil }
        return "No other samples are available to copy."
    }

    var readOnlyMessage: String? {
        guard isReadOnly else { return nil }
        return "This bundle is read-only. Save a writable copy to edit assignments."
    }

    var showsRecoveryActions: Bool {
        persistenceErrorMessage != nil
    }

    func updateLabel(
        _ label: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) {
        guard !isReadOnly else { return }
        var updated = draft
        updated.setLabel(label, locus: locus, slot: slot)
        replaceDraft(updated)
        announceAutocomplete(for: label, locus: locus, slot: slot)
    }

    func clear(
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) {
        guard !isReadOnly else { return }
        var updated = draft
        updated.clear(locus: locus, slot: slot)
        replaceDraft(updated)
    }

    func autocompleteSuggestions(
        matching query: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) -> [GenotypeManualHaplotypeAssignmentIndex.LabelCatalogEntry] {
        _ = locus
        _ = slot
        return draft.autocompleteSuggestions(matching: query)
    }

    func updateCopySearch(_ query: String) {
        guard query != copySearchText else { return }
        copySearchText = query
        refreshFilteredCopyCandidates()
    }

    func copyAssignments(from sample: String) {
        guard !isReadOnly,
              let source = snapshot.copyAssignments(for: sample) else {
            return
        }
        var updated = draft
        updated.copyAssignments(from: source)
        replaceDraft(updated)
        persistenceErrorMessage = nil
        announcementPoster.post(
            "Copied \(copyCandidate(for: sample).completenessSummary) from \(source.sample).",
            priority: .medium
        )
    }

    func copyAssignmentsSnapshot(
        for sample: String
    ) -> GenotypeManualHaplotypeAssignmentIndex.SampleAssignments? {
        snapshot.copyAssignments(for: sample)
    }

    @discardableResult
    func stageSelectedAssignments(
        from sample: String,
        addresses: Set<GenotypeManualHaplotypeDraft.SlotAddress>,
        expectedSourceValues: [
            GenotypeManualHaplotypeDraft.SlotAddress:
                ManualHaplotypeAssignment
        ]
    ) -> GenotypeManualHaplotypeDraft.SelectiveCopyResult {
        guard !isReadOnly,
              let source = snapshot.copyAssignments(for: sample) else {
            return .init(applied: [], skipped: [])
        }
        var updated = draft
        let result = updated.copySelectedAssignments(
            from: source,
            addresses: addresses,
            expectedSourceValues: expectedSourceValues
        )
        replaceDraft(updated)
        persistenceErrorMessage = nil

        let appliedCount = result.applied.count
        let skippedCount = result.skipped.count
        let appliedDescription =
            "\(appliedCount) assignment\(appliedCount == 1 ? "" : "s") staged"
        announcementPoster.post(
            "\(appliedDescription), \(skippedCount) skipped from \(source.sample).",
            priority: .medium
        )
        return result
    }

    func save() {
        guard prepareSave() else { return }
        _ = finalizePreparedSave()
    }

    @discardableResult
    func prepareSave() -> Bool {
        guard canSave else { return false }
        do {
            // Validate and retain only the value-semantic draft. Durable
            // sidecar/audit publication belongs to finalization after every
            // quitting window has passed preflight.
            _ = try draft.validatedAssignments()
            preparedDraft = draft
            persistenceErrorMessage = nil
            return true
        } catch {
            preparedDraft = nil
            persistenceErrorMessage = error.localizedDescription
            announcementPoster.post(
                "Could not save haplotype assignments for \(draft.sample). \(error.localizedDescription)",
                priority: .high
            )
            return false
        }
    }

    @discardableResult
    func finalizePreparedSave() -> Bool {
        guard let preparedDraft else { return false }
        do {
            let savedDraft = try onSave(preparedDraft)
            self.preparedDraft = nil
            replaceDraft(savedDraft)
            persistenceErrorMessage = nil
            onDidSave()
            announcementPoster.post(
                "Saved haplotype assignments for \(draft.sample).",
                priority: .high
            )
            return true
        } catch {
            self.preparedDraft = nil
            persistenceErrorMessage = error.localizedDescription
            announcementPoster.post(
                "Could not save haplotype assignments for \(draft.sample). \(error.localizedDescription)",
                priority: .high
            )
            return false
        }
    }

    func cancelPreparedSave() {
        preparedDraft = nil
    }

    func retry() {
        save()
    }

    func reload() {
        do {
            let reloadedSnapshot = try onReload()
            copyCandidatePresentationBuildCount +=
                reloadedSnapshot.copyCandidateCount
            let query = Self.normalizedSearchKey(copySearchText)
            recordFilterEvaluation(
                query: query,
                candidateCount: reloadedSnapshot.copyCandidateCount
            )
            let draftChanged = reloadedSnapshot.draft != draft
            editorState = EditorState(
                snapshot: reloadedSnapshot,
                filteredCopyCandidates:
                    reloadedSnapshot.filteredCopyCandidates(
                        matching: query
                    )
            )
            if draftChanged {
                draftRevisionToken = UUID()
            }
            persistenceErrorMessage = nil
            announcementPoster.post(
                "Reloaded haplotype assignments for \(draft.sample).",
                priority: .high
            )
        } catch {
            persistenceErrorMessage = error.localizedDescription
            announcementPoster.post(
                "Could not reload haplotype assignments for \(draft.sample). \(error.localizedDescription)",
                priority: .high
            )
        }
    }

    private func slotPresentation(
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) -> SlotPresentation {
        let value = draft[locus, slot]
        let validation = draft.validationIssue(
            locus: locus,
            slot: slot
        )?.error.localizedDescription
        let locusAndSlot = "\(locus.workbookLabel) \(slot.displayName)"
        return SlotPresentation(
            locus: locus,
            slot: slot,
            label: value?.label ?? "",
            colorTokenIndex: value?.colorTokenIndex,
            validationDescription: validation,
            accessibilityLabel: "\(locusAndSlot) haplotype label",
            clearAccessibilityLabel: "Clear \(locusAndSlot) haplotype",
            accessibilityIdentifier:
                "manual-haplotype-\(locus.rawValue)-\(slot.rawValue)"
        )
    }

    private func announceAutocomplete(
        for query: String,
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) {
        let count = autocompleteSuggestions(
            matching: query,
            locus: locus,
            slot: slot
        ).count
        let resultWord = count == 1 ? "suggestion" : "suggestions"
        let validation = draft.validationIssue(
            locus: locus,
            slot: slot
        )?.error.localizedDescription ?? "Label is valid."
        announcementPoster.post(
            "\(count) autocomplete \(resultWord) for \(locus.workbookLabel) \(slot.displayName). \(validation)",
            priority: .medium
        )
    }

    private static func copyCandidate(
        _ assignments:
            GenotypeManualHaplotypeAssignmentIndex.SampleAssignments
    ) -> CopyCandidate {
        let values = assignments.assignments
        let count = values.count
        let completeness = "\(count) of 14 assigned"
        let compactSummary = values.prefix(4).map {
            let locus =
                GenotypeManualHaplotypeLocus(normalizing: $0.locus)?
                    .workbookLabel ?? $0.locus
            return "\(locus) \($0.slot.displayName) \($0.label)"
        }.joined(separator: ", ")
        let displaySummary = compactSummary.isEmpty
            ? "No assignments"
            : compactSummary
        return CopyCandidate(
            sample: assignments.sample,
            assignedSlotCount: count,
            completenessSummary: completeness,
            compactSummary: displaySummary,
            accessibilityLabel:
                "\(assignments.sample), \(completeness), \(displaySummary)"
        )
    }

    private func copyCandidate(for sample: String) -> CopyCandidate {
        snapshot.copyCandidate(for: sample)
            ?? CopyCandidate(
                sample: sample,
                assignedSlotCount: 0,
                completenessSummary: "0 of 14 assigned",
                compactSummary: "No assignments",
                accessibilityLabel:
                    "\(sample), 0 of 14 assigned, No assignments"
            )
    }

    private func refreshFilteredCopyCandidates() {
        let query = Self.normalizedSearchKey(copySearchText)
        recordFilterEvaluation(
            query: query,
            candidateCount: snapshot.copyCandidateCount
        )
        editorState = EditorState(
            snapshot: snapshot,
            filteredCopyCandidates:
                snapshot.filteredCopyCandidates(matching: query)
        )
    }

    private func replaceDraft(_ draft: GenotypeManualHaplotypeDraft) {
        guard draft != self.draft else { return }
        editorState = EditorState(
            snapshot: snapshot.replacingDraft(draft),
            filteredCopyCandidates: filteredCopyCandidates
        )
        draftRevisionToken = UUID()
    }

    private func recordFilterEvaluation(
        query: String,
        candidateCount: Int
    ) {
        copyFilterEvaluationCount += 1
        copyFilterCandidateScanCount = query.isEmpty ? 0 : candidateCount
    }

    private static func normalizedSearchKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }
}
