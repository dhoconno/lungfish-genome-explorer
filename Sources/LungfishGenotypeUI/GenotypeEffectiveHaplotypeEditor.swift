import AppKit
import Combine
import LungfishCore
import LungfishIO
import LungfishKit
import SwiftUI

@MainActor
final class GenotypeEffectiveHaplotypeEditorModel: ObservableObject {
    struct Address: Hashable, Sendable {
        let locus: String
        let slot: HaplotypeSlot
    }

    struct Snapshot: Equatable, Sendable {
        let sample: String
        let orderedLoci: [String]
        let values: [Address: String]
        let suggestions: [String]
        let isReadOnly: Bool

        init(
            sample: String,
            orderedLoci: [String],
            values: [Address: String],
            suggestions: [String],
            isReadOnly: Bool
        ) {
            var seenLoci = Set<String>()
            self.sample = sample
            self.orderedLoci = orderedLoci.filter {
                !$0.isEmpty && seenLoci.insert($0).inserted
            }
            self.values = values
            var seenSuggestions = Set<String>()
            self.suggestions = suggestions.filter {
                !$0.isEmpty && seenSuggestions.insert($0).inserted
            }
            self.isReadOnly = isReadOnly
        }
    }

    struct SlotPresentation: Equatable, Sendable {
        let locus: String
        let slot: HaplotypeSlot
        let label: String
        let colorTokenIndex: Int?
        let validationDescription: String?

        var accessibilityIdentifier: String {
            "effective-haplotype-\(locus)-\(slot.rawValue)"
        }
    }

    struct RowPresentation: Equatable, Identifiable, Sendable {
        let locus: String
        let h1: SlotPresentation
        let h2: SlotPresentation

        var id: String { locus }
    }

    @Published private var snapshot: Snapshot
    @Published private var draftValues: [Address: String]
    @Published private(set) var persistenceErrorMessage: String?

    private let onSave: ([Address: String]) throws -> Snapshot
    private let onReload: () throws -> Snapshot
    private let onDidSave: () -> Void

    init(
        snapshot: Snapshot,
        onSave: @escaping ([Address: String]) throws -> Snapshot,
        onReload: @escaping () throws -> Snapshot,
        onDidSave: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.draftValues = snapshot.values
        self.onSave = onSave
        self.onReload = onReload
        self.onDidSave = onDidSave
    }

    var sample: String { snapshot.sample }
    var isReadOnly: Bool { snapshot.isReadOnly }
    var totalSlotCount: Int { snapshot.orderedLoci.count * 2 }
    var assignedSlotCount: Int {
        snapshot.orderedLoci.reduce(into: 0) { count, locus in
            for slot in HaplotypeSlot.allCases {
                if !(draftValues[Address(locus: locus, slot: slot)] ?? "")
                    .isEmpty {
                    count += 1
                }
            }
        }
    }
    var completenessSummary: String {
        "\(assignedSlotCount) of \(totalSlotCount) assigned"
    }
    var isDirty: Bool { !changedValues.isEmpty }
    var canSave: Bool { !isReadOnly && isDirty && validationIssues.isEmpty }
    var changedValues: [Address: String] {
        Dictionary(uniqueKeysWithValues: snapshot.orderedLoci.flatMap { locus in
            HaplotypeSlot.allCases.compactMap { slot in
                let address = Address(locus: locus, slot: slot)
                let before = snapshot.values[address] ?? ""
                let after = draftValues[address] ?? ""
                return before == after ? nil : (address, after)
            }
        })
    }
    var readOnlyMessage: String? {
        isReadOnly
            ? "This bundle is read-only. Save a writable copy to edit assignments."
            : nil
    }
    var rows: [RowPresentation] {
        snapshot.orderedLoci.map { locus in
            .init(
                locus: locus,
                h1: presentation(locus: locus, slot: .h1),
                h2: presentation(locus: locus, slot: .h2)
            )
        }
    }

    func updateLabel(_ label: String, locus: String, slot: HaplotypeSlot) {
        guard !isReadOnly, snapshot.orderedLoci.contains(locus) else { return }
        persistenceErrorMessage = nil
        draftValues[Address(locus: locus, slot: slot)] = label
    }

    func clear(locus: String, slot: HaplotypeSlot) {
        updateLabel("", locus: locus, slot: slot)
    }

    func autocompleteSuggestions(matching query: String) -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return snapshot.suggestions }
        return snapshot.suggestions.filter {
            $0.localizedCaseInsensitiveContains(normalized)
        }
    }

    func save() {
        guard canSave else { return }
        do {
            apply(try onSave(changedValues))
            persistenceErrorMessage = nil
            onDidSave()
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    func retry() {
        save()
    }

    func reload() {
        do {
            apply(try onReload())
            persistenceErrorMessage = nil
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    private var validationIssues: [Address: String] {
        Dictionary(uniqueKeysWithValues: draftValues.compactMap { address, value in
            guard !value.isEmpty else { return nil }
            do {
                _ = try GenotypeManualHaplotypeAssignmentInputValidator
                    .validatedLabel(value)
                return nil
            } catch {
                return (address, error.localizedDescription)
            }
        })
    }

    private func presentation(
        locus: String,
        slot: HaplotypeSlot
    ) -> SlotPresentation {
        let address = Address(locus: locus, slot: slot)
        let label = draftValues[address] ?? ""
        return .init(
            locus: locus,
            slot: slot,
            label: label,
            colorTokenIndex: label.isEmpty
                ? nil
                : HaplotypeColorToken.assigned(forName: label).canonicalIndex,
            validationDescription: validationIssues[address]
        )
    }

    private func apply(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        draftValues = snapshot.values
    }
}

@MainActor
struct GenotypeEffectiveHaplotypeEditor: View {
    @ObservedObject var model: GenotypeEffectiveHaplotypeEditorModel
    var typographyModel: ContentTypographyModel = .shared

    private var headingFont: Font {
        typographyModel.font(for: .emphasizedBody)
    }
    private var captionFont: Font { typographyModel.font(for: .caption) }
    private var comboFieldFont: NSFont {
        typographyModel.resolvedNSFont(for: .body)
    }
    private var typographyScale: CGFloat {
        typographyModel.scaledPointSize(fromCanonicalPointSize: 100) / 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Haplotype Assignments").font(headingFont)
                    Text(model.completenessSummary)
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isDirty {
                    Text("Unsaved")
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                }
                Button("Save Assignments") { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("effective-haplotype-save")
            }
            Text("Edit the two haplotype calls for each included locus.")
                .font(captionFont)
                .foregroundStyle(.secondary)
            if let message = model.readOnlyMessage {
                Label(message, systemImage: "lock.fill")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.rows) { row in
                ManualHaplotypeLocusLayout(
                    typographyScale: typographyScale
                ) {
                    Text(row.locus).font(headingFont)
                    slotEditor(row.h1)
                    slotEditor(row.h2)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(row.locus) haplotype assignments")
                if row.id != model.rows.last?.id { Divider() }
            }
            if let error = model.persistenceErrorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Retry") { model.retry() }
                        Button("Reload") { model.reload() }
                    }
                }
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
        .accessibilityLabel("Haplotype assignments for \(model.sample)")
    }

    private func slotEditor(
        _ slot: GenotypeEffectiveHaplotypeEditorModel.SlotPresentation
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(slot.slot.displayName)
                .font(captionFont)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityAddTraits(.isHeader)
            Group {
                if let index = slot.colorTokenIndex {
                    Circle().fill(color(forTokenIndex: index))
                } else {
                    Color.clear
                }
            }
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
            ManualHaplotypeComboBox(
                text: slot.label,
                suggestions: model.autocompleteSuggestions(
                    matching: slot.label
                ),
                accessibilityLabel:
                    "\(slot.locus) \(slot.slot.displayName) haplotype label",
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
            }
            Button {
                model.clear(locus: slot.locus, slot: slot.slot)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(model.isReadOnly || slot.label.isEmpty)
            .accessibilityLabel(
                "Clear \(slot.locus) \(slot.slot.displayName) haplotype"
            )
        }
        .help(
            slot.validationDescription
                ?? "\(slot.locus) \(slot.slot.displayName) haplotype label"
        )
    }

    private func color(forTokenIndex index: Int) -> Color {
        let palette = HaplotypeColorToken.canonicalPalette
        let token = palette[max(0, min(palette.count - 1, index))]
        return Color(
            red: token.fillColor.red,
            green: token.fillColor.green,
            blue: token.fillColor.blue
        )
    }
}

@MainActor
func makeGenotypeEffectiveHaplotypeEditorHostingView(
    model: GenotypeEffectiveHaplotypeEditorModel,
    typographyModel: ContentTypographyModel
) -> NSHostingView<GenotypeEffectiveHaplotypeEditor> {
    let host = NSHostingView(
        rootView: GenotypeEffectiveHaplotypeEditor(
            model: model,
            typographyModel: typographyModel
        )
    )
    host.sizingOptions = [.intrinsicContentSize]
    host.setContentHuggingPriority(.defaultLow, for: .horizontal)
    host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return host
}
