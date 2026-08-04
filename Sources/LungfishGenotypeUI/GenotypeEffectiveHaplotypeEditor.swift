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
    @Published private(set) var draftRevisionToken = UUID()

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
        let address = Address(locus: locus, slot: slot)
        guard draftValues[address] != label else { return }
        draftValues[address] = label
        draftRevisionToken = UUID()
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
        _ = saveAndReturnSuccess()
    }

    @discardableResult
    func saveAndReturnSuccess() -> Bool {
        guard canSave else { return false }
        do {
            apply(try onSave(changedValues))
            persistenceErrorMessage = nil
            onDidSave()
            return true
        } catch {
            persistenceErrorMessage = error.localizedDescription
            return false
        }
    }

    func prepareSave() -> Bool {
        canSave
    }

    func finalizePreparedSave() -> Bool {
        saveAndReturnSuccess()
    }

    func cancelPreparedSave() {}

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
        draftRevisionToken = UUID()
    }
}

@MainActor
struct GenotypeEffectiveHaplotypeEditor: View {
    @ObservedObject var model: GenotypeEffectiveHaplotypeEditorModel
    var typographyModel: ContentTypographyModel = .shared

    var body: some View {
        GenotypeHaplotypeAssignmentEditorCard(
            sample: model.sample,
            completenessSummary: model.completenessSummary,
            instruction:
                "Edit the two haplotype calls for each included locus.",
            rows: sharedRows,
            isDirty: model.isDirty,
            canSave: model.canSave,
            isReadOnly: model.isReadOnly,
            readOnlyMessage: model.readOnlyMessage,
            emptyStateMessage: nil,
            warning: nil,
            persistenceErrorMessage: model.persistenceErrorMessage,
            accessibilityPrefix: "effective-haplotype",
            typographyModel: typographyModel,
            compareAndCopyIsEnabled: nil,
            onSave: model.save,
            onRetry: model.retry,
            onReload: model.reload,
            onChange: { address, label in
                model.updateLabel(
                    label,
                    locus: address.locus,
                    slot: address.slot
                )
            },
            onClear: { address in
                model.clear(
                    locus: address.locus,
                    slot: address.slot
                )
            },
            onCompareAndCopy: nil
        )
    }

    var testingSharedAssignmentCardIdentifier: String {
        GenotypeHaplotypeAssignmentEditorCard.accessibilityIdentifier
    }

    private var sharedRows: [GenotypeHaplotypeAssignmentEditorRow] {
        model.rows.map { row in
            .init(
                locusLabel: row.locus,
                h1: sharedSlot(row.h1),
                h2: sharedSlot(row.h2)
            )
        }
    }

    private func sharedSlot(
        _ slot: GenotypeEffectiveHaplotypeEditorModel.SlotPresentation
    ) -> GenotypeHaplotypeAssignmentEditorSlot {
        let accessibilityLabel =
            "\(slot.locus) \(slot.slot.displayName) haplotype label"
        return .init(
            address: .init(locus: slot.locus, slot: slot.slot),
            label: slot.label,
            suggestions: model.autocompleteSuggestions(
                matching: slot.label
            ),
            colorTokenIndex: slot.colorTokenIndex,
            validationDescription: slot.validationDescription,
            accessibilityLabel: accessibilityLabel,
            clearAccessibilityLabel:
                "Clear \(slot.locus) \(slot.slot.displayName) haplotype",
            accessibilityIdentifier: slot.accessibilityIdentifier
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
