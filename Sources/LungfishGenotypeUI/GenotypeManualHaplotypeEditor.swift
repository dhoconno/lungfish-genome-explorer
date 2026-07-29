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

    private let onSave:
        (GenotypeManualHaplotypeDraft) throws
            -> GenotypeManualHaplotypeDraft
    private let onReload: () throws -> Snapshot
    private let onExport: () -> Void
    private let announcementPoster: any AccessibilityAnnouncementPosting
    private var preparedDraft: GenotypeManualHaplotypeDraft?
    private(set) var draftRevisionToken = UUID()

    private(set) var copyCandidatePresentationBuildCount: Int
    private(set) var copyFilterEvaluationCount = 1
    private(set) var copyFilterCandidateScanCount = 0

    init(
        snapshot: Snapshot,
        onSave: @escaping (
            GenotypeManualHaplotypeDraft
        ) throws -> GenotypeManualHaplotypeDraft,
        onReload: @escaping () throws -> Snapshot,
        onExport: @escaping () -> Void,
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
        self.onExport = onExport
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

    var canSave: Bool {
        !isReadOnly && draft.isDirty && draft.isValid
    }

    var canExport: Bool { true }

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

    func export() {
        onExport()
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

struct ManualHaplotypeLocusLayout: Layout {
    enum Mode: Equatable {
        case sideBySide
        case stacked
    }

    struct Geometry: Equatable {
        let mode: Mode
        let frames: [CGRect]

        var size: CGSize {
            CGSize(
                width: frames.map(\.maxX).max() ?? 0,
                height: frames.map(\.maxY).max() ?? 0
            )
        }
    }

    static let sideBySideBreakpoint: CGFloat = 430
    static let horizontalSpacing: CGFloat = 12
    static let verticalSpacing: CGFloat = 5

    let typographyScale: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let naturalSizes = subviews.map {
            $0.sizeThatFits(.unspecified)
        }
        let naturalWidth =
            naturalSizes.map(\.width).reduce(0, +)
            + Self.horizontalSpacing * CGFloat(max(0, subviews.count - 1))
        let availableWidth = max(
            0,
            proposal.width ?? naturalWidth
        )
        let measuredSizes = measuredSizes(
            for: subviews,
            availableWidth: availableWidth,
            proposedHeight: proposal.height,
            naturalSizes: naturalSizes
        )
        return Self.geometry(
            availableWidth: availableWidth,
            typographyScale: typographyScale,
            childSizes: measuredSizes
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        let availableWidth = max(0, bounds.width)
        let naturalSizes = subviews.map {
            $0.sizeThatFits(.unspecified)
        }
        let measuredSizes = measuredSizes(
            for: subviews,
            availableWidth: availableWidth,
            proposedHeight: proposal.height,
            naturalSizes: naturalSizes
        )
        let geometry = Self.geometry(
            availableWidth: availableWidth,
            typographyScale: typographyScale,
            childSizes: measuredSizes
        )
        for (index, subview) in subviews.enumerated()
        where index < geometry.frames.count {
            let frame = geometry.frames[index].offsetBy(
                dx: bounds.minX,
                dy: bounds.minY
            )
            subview.place(
                at: frame.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    static func testingGeometry(
        availableWidth: CGFloat,
        typographyScale: CGFloat,
        childSizes: [CGSize]
    ) -> Geometry {
        geometry(
            availableWidth: availableWidth,
            typographyScale: typographyScale,
            childSizes: childSizes
        )
    }

    private func measuredSizes(
        for subviews: Subviews,
        availableWidth: CGFloat,
        proposedHeight: CGFloat?,
        naturalSizes: [CGSize]
    ) -> [CGSize] {
        guard subviews.count == 3 else {
            return subviews.map {
                $0.sizeThatFits(
                    ProposedViewSize(
                        width: availableWidth,
                        height: proposedHeight
                    )
                )
            }
        }
        let mode = Self.mode(
            availableWidth: availableWidth,
            typographyScale: typographyScale
        )
        switch mode {
        case .sideBySide:
            let locusWidth = min(naturalSizes[0].width, availableWidth)
            let slotWidth = max(
                0,
                (
                    availableWidth
                        - locusWidth
                        - Self.horizontalSpacing * 2
                ) / 2
            )
            return [
                subviews[0].sizeThatFits(
                    ProposedViewSize(
                        width: locusWidth,
                        height: proposedHeight
                    )
                ),
                subviews[1].sizeThatFits(
                    ProposedViewSize(
                        width: slotWidth,
                        height: proposedHeight
                    )
                ),
                subviews[2].sizeThatFits(
                    ProposedViewSize(
                        width: slotWidth,
                        height: proposedHeight
                    )
                ),
            ]
        case .stacked:
            return subviews.map {
                $0.sizeThatFits(
                    ProposedViewSize(
                        width: availableWidth,
                        height: proposedHeight
                    )
                )
            }
        }
    }

    private static func mode(
        availableWidth: CGFloat,
        typographyScale: CGFloat
    ) -> Mode {
        availableWidth
            >= sideBySideBreakpoint * max(typographyScale, 0.01)
            ? .sideBySide
            : .stacked
    }

    private static func geometry(
        availableWidth: CGFloat,
        typographyScale: CGFloat,
        childSizes: [CGSize]
    ) -> Geometry {
        guard childSizes.count == 3 else {
            return Geometry(mode: .stacked, frames: [])
        }
        switch mode(
            availableWidth: availableWidth,
            typographyScale: typographyScale
        ) {
        case .sideBySide:
            let locusWidth = min(childSizes[0].width, availableWidth)
            let slotWidth = max(
                0,
                (
                    availableWidth
                        - locusWidth
                        - horizontalSpacing * 2
                ) / 2
            )
            return Geometry(
                mode: .sideBySide,
                frames: [
                    CGRect(
                        x: 0,
                        y: 0,
                        width: locusWidth,
                        height: childSizes[0].height
                    ),
                    CGRect(
                        x: locusWidth + horizontalSpacing,
                        y: 0,
                        width: slotWidth,
                        height: childSizes[1].height
                    ),
                    CGRect(
                        x:
                            locusWidth
                            + horizontalSpacing * 2
                            + slotWidth,
                        y: 0,
                        width: slotWidth,
                        height: childSizes[2].height
                    ),
                ]
            )
        case .stacked:
            let first = CGRect(
                x: 0,
                y: 0,
                width: availableWidth,
                height: childSizes[0].height
            )
            let second = CGRect(
                x: 0,
                y: first.maxY + verticalSpacing,
                width: availableWidth,
                height: childSizes[1].height
            )
            let third = CGRect(
                x: 0,
                y: second.maxY + verticalSpacing,
                width: availableWidth,
                height: childSizes[2].height
            )
            return Geometry(
                mode: .stacked,
                frames: [first, second, third]
            )
        }
    }
}

@MainActor
struct GenotypeManualHaplotypeEditor: View {
    @ObservedObject var model: GenotypeManualHaplotypeEditorModel
    var typographyModel: ContentTypographyModel = .shared

    private var headingFont: Font {
        typographyModel.font(for: .emphasizedBody)
    }
    private var bodyFont: Font {
        typographyModel.font(for: .body)
    }
    private var captionFont: Font {
        typographyModel.font(for: .caption)
    }
    private var monospacedFont: Font {
        typographyModel.font(for: .monospaced)
    }
    private var comboFieldFont: NSFont {
        typographyModel.resolvedNSFont(for: .body)
    }
    private var contentTypographyScale: CGFloat {
        typographyModel.scaledPointSize(
            fromCanonicalPointSize: 100
        ) / 100
    }

    var testingContentTypographyPointSizes: (
        heading: CGFloat,
        caption: CGFloat,
        comboField: CGFloat
    ) {
        (
            typographyModel.resolvedNSFont(for: .emphasizedBody).pointSize,
            typographyModel.resolvedNSFont(for: .caption).pointSize,
            comboFieldFont.pointSize
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Haplotype Assignments")
                .font(headingFont)
            Text("Edit the two manual assignments for each workbook locus.")
                .font(captionFont)
                .foregroundStyle(.secondary)

            if let readOnlyMessage = model.readOnlyMessage {
                Label(readOnlyMessage, systemImage: "lock.fill")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "manual-haplotype-read-only-message"
                    )
            }
            if let orphanWarning = model.orphanLegacyWarningMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        orphanWarning,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    ForEach(
                        Array(
                            model.orphanLegacyAssignments.enumerated()
                        ),
                        id: \.offset
                    ) { _, assignment in
                        Text(
                            "\(assignment.locus) \(assignment.slot.displayName): \(assignment.label)"
                        )
                        .font(monospacedFont)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(
                    "manual-haplotype-orphan-legacy-warning"
                )
            }
            if let emptyStateMessage = model.emptyStateMessage {
                Text(emptyStateMessage)
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "manual-haplotype-empty-message"
                    )
            }

            ForEach(model.rows) { row in
                ManualHaplotypeLocusLayout(
                    typographyScale: contentTypographyScale
                ) {
                    Text(row.locus.workbookLabel)
                        .font(headingFont)
                    slotEditor(row.h1)
                    slotEditor(row.h2)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    "\(row.locus.workbookLabel) haplotype assignments"
                )
                if row.locus != GenotypeManualHaplotypeLocus.allCases.last {
                    Divider()
                }
            }

            copyPicker

            if let error = model.persistenceErrorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") { model.retry() }
                            .accessibilityIdentifier(
                                "manual-haplotype-retry"
                            )
                        Button("Reload") { model.reload() }
                            .accessibilityIdentifier(
                                "manual-haplotype-reload"
                            )
                    }
                }
            }

            HStack {
                Button("Export Manual Definitions\u{2026}") {
                    model.export()
                }
                .disabled(!model.canExport)
                .accessibilityIdentifier("manual-haplotype-export")
                Spacer()
                Button("Save Assignments") {
                    model.save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .accessibilityIdentifier("manual-haplotype-save")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Haplotype assignments for \(model.draft.sample)"
        )
    }

    private func slotEditor(
        _ slot: GenotypeManualHaplotypeEditorModel.SlotPresentation
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(slot.slot.displayName)
                .font(captionFont)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isHeader)
            Group {
                if let colorTokenIndex = slot.colorTokenIndex {
                    Circle()
                        .fill(color(forTokenIndex: colorTokenIndex))
                } else {
                    Color.clear
                }
            }
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
            ManualHaplotypeComboBox(
                text: slot.label,
                suggestions: model.autocompleteSuggestions(
                    matching: slot.label,
                    locus: slot.locus,
                    slot: slot.slot
                ).map(\.label),
                accessibilityLabel: slot.accessibilityLabel,
                accessibilityIdentifier: slot.accessibilityIdentifier,
                accessibilityHelp: slot.validationDescription,
                isEnabled: !model.isReadOnly,
                font: comboFieldFont,
                onChange: {
                    model.updateLabel(
                        $0,
                        locus: slot.locus,
                        slot: slot.slot
                    )
                }
            )
            .frame(
                minWidth: 120,
                idealWidth: 180,
                maxWidth: .infinity,
                minHeight: ceil(comboFieldFont.pointSize + 10)
            )

            if let validation = slot.validationDescription {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(validation)
                    .accessibilityLabel(validation)
                    .accessibilityIdentifier(
                        "\(slot.accessibilityIdentifier)-validation"
                    )
            }

            Button {
                model.clear(locus: slot.locus, slot: slot.slot)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.isReadOnly || slot.label.isEmpty)
            .accessibilityLabel(slot.clearAccessibilityLabel)
            .accessibilityIdentifier(
                "\(slot.accessibilityIdentifier)-clear"
            )
        }
        .help(slot.validationDescription ?? slot.accessibilityLabel)
    }

    private var copyPicker: some View {
        DisclosureGroup("Copy from Sample\u{2026}") {
            VStack(alignment: .leading, spacing: 6) {
                if let empty = model.copyEmptyStateMessage {
                    Text(empty)
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                } else {
                    TextField(
                        "Search samples",
                        text: Binding(
                            get: { model.copySearchText },
                            set: { model.updateCopySearch($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(bodyFont)
                    .accessibilityLabel(
                        "Search samples to copy haplotype assignments"
                    )
                    .accessibilityIdentifier(
                        "manual-haplotype-copy-search"
                    )

                    if model.filteredCopyCandidates.isEmpty {
                        Text("No samples match this search.")
                            .font(captionFont)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(
                                    model.filteredCopyCandidates
                                ) { candidate in
                                    Button {
                                        model.copyAssignments(
                                            from: candidate.sample
                                        )
                                    } label: {
                                        VStack(
                                            alignment: .leading,
                                            spacing: 1
                                        ) {
                                            Text(candidate.sample)
                                                .font(bodyFont)
                                            Text(
                                                "\(candidate.completenessSummary) \u{2022} \(candidate.compactSummary)"
                                            )
                                            .font(captionFont)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(model.isReadOnly)
                                    .accessibilityLabel(
                                        candidate.accessibilityLabel
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }
            }
            .padding(.top, 4)
        }
        .disabled(model.isReadOnly)
        .font(bodyFont)
        .accessibilityIdentifier("manual-haplotype-copy-picker")
    }

    private func color(forTokenIndex index: Int) -> Color {
        let palette = HaplotypeColorToken.canonicalPalette
        let safeIndex = max(0, min(palette.count - 1, index))
        let token = palette[safeIndex]
        return Color(
            red: token.fillColor.red,
            green: token.fillColor.green,
            blue: token.fillColor.blue
        )
    }
}

@MainActor
func makeGenotypeManualHaplotypeEditorHostingView(
    model: GenotypeManualHaplotypeEditorModel,
    typographyModel: ContentTypographyModel
) -> NSHostingView<GenotypeManualHaplotypeEditor> {
    let host = NSHostingView(
        rootView: GenotypeManualHaplotypeEditor(
            model: model,
            typographyModel: typographyModel
        )
    )
    host.sizingOptions = [.intrinsicContentSize]
    host.setContentHuggingPriority(.defaultLow, for: .horizontal)
    host.setContentCompressionResistancePriority(
        .defaultLow,
        for: .horizontal
    )
    return host
}

@MainActor
private struct ManualHaplotypeComboBox: NSViewRepresentable {
    let text: String
    let suggestions: [String]
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let accessibilityHelp: String?
    let isEnabled: Bool
    let font: NSFont
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.usesDataSource = false
        comboBox.delegate = context.coordinator
        configure(comboBox)
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.onChange = onChange
        configure(comboBox)
    }

    private func configure(_ comboBox: NSComboBox) {
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }
        let existing = comboBox.objectValues.compactMap { $0 as? String }
        if existing != suggestions {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: suggestions)
        }
        comboBox.isEnabled = isEnabled
        comboBox.font = font
        comboBox.setAccessibilityLabel(accessibilityLabel)
        comboBox.setAccessibilityIdentifier(accessibilityIdentifier)
        comboBox.setAccessibilityHelp(accessibilityHelp)
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }
            onChange(comboBox.stringValue)
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }
            onChange(comboBox.stringValue)
        }
    }
}
