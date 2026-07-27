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

    @Published private(set) var draft: GenotypeManualHaplotypeDraft
    @Published private(set) var persistenceErrorMessage: String?
    @Published private(set) var copySearchText = ""

    let isReadOnly: Bool

    private let copyAssignmentSnapshots:
        [GenotypeManualHaplotypeAssignmentIndex.SampleAssignments]
    private let onSave:
        (GenotypeManualHaplotypeDraft) throws
            -> GenotypeManualHaplotypeDraft
    private let onReload: () throws -> GenotypeManualHaplotypeDraft
    private let onExport: () -> Void
    private let announcementPoster: any AccessibilityAnnouncementPosting

    init(
        draft: GenotypeManualHaplotypeDraft,
        copyCandidates:
            [GenotypeManualHaplotypeAssignmentIndex.SampleAssignments],
        isReadOnly: Bool,
        onSave: @escaping (
            GenotypeManualHaplotypeDraft
        ) throws -> GenotypeManualHaplotypeDraft,
        onReload: @escaping () throws -> GenotypeManualHaplotypeDraft,
        onExport: @escaping () -> Void,
        announcementPoster: any AccessibilityAnnouncementPosting =
            AccessibilityAnnouncementPoster()
    ) {
        self.draft = draft
        self.copyAssignmentSnapshots = copyCandidates.filter {
            $0.sample != draft.sample
        }
        self.isReadOnly = isReadOnly
        self.onSave = onSave
        self.onReload = onReload
        self.onExport = onExport
        self.announcementPoster = announcementPoster
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
        copyAssignmentSnapshots.map(Self.copyCandidate)
    }

    var filteredCopyCandidates: [CopyCandidate] {
        let query = copySearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        guard !query.isEmpty else { return copyCandidates }
        return copyCandidates.filter { candidate in
            [candidate.sample, candidate.compactSummary]
                .joined(separator: " ")
                .folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .contains(query)
        }
    }

    var canSave: Bool {
        !isReadOnly && draft.isDirty && draft.isValid
    }

    var canExport: Bool { true }

    var emptyStateMessage: String? {
        guard draft.assignedSlotCount == 0 else { return nil }
        return "No assignments yet. Enter a label or copy from another sample."
    }

    var copyEmptyStateMessage: String? {
        guard copyAssignmentSnapshots.isEmpty else { return nil }
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
        draft = updated
        announceAutocomplete(for: label, locus: locus, slot: slot)
    }

    func clear(
        locus: GenotypeManualHaplotypeLocus,
        slot: HaplotypeSlot
    ) {
        guard !isReadOnly else { return }
        var updated = draft
        updated.clear(locus: locus, slot: slot)
        draft = updated
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
        copySearchText = query
    }

    func copyAssignments(from sample: String) {
        guard !isReadOnly,
              let source = copyAssignmentSnapshots.first(where: {
                  $0.sample == sample
              }) else {
            return
        }
        var updated = draft
        updated.copyAssignments(from: source)
        draft = updated
        persistenceErrorMessage = nil
        announcementPoster.post(
            "Copied \(Self.copyCandidate(source).completenessSummary) from \(source.sample).",
            priority: .medium
        )
    }

    func save() {
        guard canSave else { return }
        do {
            draft = try onSave(draft)
            persistenceErrorMessage = nil
            announcementPoster.post(
                "Saved haplotype assignments for \(draft.sample).",
                priority: .high
            )
        } catch {
            persistenceErrorMessage = error.localizedDescription
            announcementPoster.post(
                "Could not save haplotype assignments for \(draft.sample). \(error.localizedDescription)",
                priority: .high
            )
        }
    }

    func retry() {
        save()
    }

    func reload() {
        do {
            draft = try onReload()
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
}

@MainActor
struct GenotypeManualHaplotypeEditor: View {
    @ObservedObject var model: GenotypeManualHaplotypeEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Haplotype Assignments")
                .font(.headline)
            Text("Edit the two manual assignments for each workbook locus.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let readOnlyMessage = model.readOnlyMessage {
                Label(readOnlyMessage, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "manual-haplotype-read-only-message"
                    )
            }
            if let emptyStateMessage = model.emptyStateMessage {
                Text(emptyStateMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "manual-haplotype-empty-message"
                    )
            }

            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.locus.workbookLabel)
                        .font(.caption.weight(.semibold))
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
                        .font(.caption)
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
                .font(.caption)
                .frame(width: 22, alignment: .leading)
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
                isEnabled: !model.isReadOnly,
                onChange: {
                    model.updateLabel(
                        $0,
                        locus: slot.locus,
                        slot: slot.slot
                    )
                }
            )
            .frame(minWidth: 120, idealWidth: 180, maxWidth: .infinity)

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
                        .font(.caption)
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
                    .accessibilityLabel(
                        "Search samples to copy haplotype assignments"
                    )
                    .accessibilityIdentifier(
                        "manual-haplotype-copy-search"
                    )

                    if model.filteredCopyCandidates.isEmpty {
                        Text("No samples match this search.")
                            .font(.caption)
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
                                            Text(
                                                "\(candidate.completenessSummary) \u{2022} \(candidate.compactSummary)"
                                            )
                                            .font(.caption2)
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
private struct ManualHaplotypeComboBox: NSViewRepresentable {
    let text: String
    let suggestions: [String]
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let isEnabled: Bool
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.usesDataSource = false
        comboBox.controlSize = .small
        comboBox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
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
        comboBox.setAccessibilityLabel(accessibilityLabel)
        comboBox.setAccessibilityIdentifier(accessibilityIdentifier)
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
