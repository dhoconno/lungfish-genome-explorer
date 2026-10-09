import AppKit
import Combine
import LungfishCore
import LungfishIO
import LungfishKit
import SwiftUI

@MainActor
struct GenotypeManualHaplotypeEditor: View {
    @ObservedObject var model: GenotypeManualHaplotypeEditorModel
    var typographyModel: ContentTypographyModel = .shared
    var onCompareAndCopy: () -> Void = {}

    private var comboFieldFont: NSFont {
        typographyModel.resolvedNSFont(for: .body)
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
        GenotypeHaplotypeAssignmentEditorCard(
            sample: model.draft.sample,
            completenessSummary:
                "\(model.draft.assignedSlotCount) of 14 assigned",
            instruction:
                "Edit the two manual assignments for each workbook locus.",
            rows: sharedRows,
            isDirty: model.draft.isDirty,
            canSave: model.canSave,
            isReadOnly: model.isReadOnly,
            readOnlyMessage: model.readOnlyMessage,
            emptyStateMessage: model.emptyStateMessage,
            warning: sharedWarning,
            persistenceErrorMessage: model.persistenceErrorMessage,
            accessibilityPrefix: "manual-haplotype",
            typographyModel: typographyModel,
            compareAndCopyIsEnabled: !model.copyCandidates.isEmpty,
            onSave: model.save,
            onRetry: model.retry,
            onReload: model.reload,
            onChange: { address, label in
                guard let locus = GenotypeManualHaplotypeLocus(
                    normalizing: address.locus
                ) else { return }
                model.updateLabel(
                    label,
                    locus: locus,
                    slot: address.slot
                )
            },
            onClear: { address in
                guard let locus = GenotypeManualHaplotypeLocus(
                    normalizing: address.locus
                ) else { return }
                model.clear(locus: locus, slot: address.slot)
            },
            onRestore: nil,
            onCompareAndCopy: onCompareAndCopy
        )
    }

    var testingSharedAssignmentCardIdentifier: String {
        GenotypeHaplotypeAssignmentEditorCard.accessibilityIdentifier
    }

    private var sharedRows: [GenotypeHaplotypeAssignmentEditorRow] {
        model.rows.map { row in
            .init(
                locusLabel: row.locus.workbookLabel,
                h1: sharedSlot(row.h1),
                h2: sharedSlot(row.h2)
            )
        }
    }

    private func sharedSlot(
        _ slot: GenotypeManualHaplotypeEditorModel.SlotPresentation
    ) -> GenotypeHaplotypeAssignmentEditorSlot {
        .init(
            address: .init(
                locus: slot.locus.workbookLabel,
                slot: slot.slot
            ),
            label: slot.label,
            suggestions: model.autocompleteSuggestions(
                matching: slot.label,
                locus: slot.locus,
                slot: slot.slot
            ).map(\.label),
            colorTokenIndex: slot.colorTokenIndex,
            validationDescription: slot.validationDescription,
            accessibilityLabel: slot.accessibilityLabel,
            clearAccessibilityLabel: slot.clearAccessibilityLabel,
            accessibilityIdentifier: slot.accessibilityIdentifier
        )
    }

    private var sharedWarning:
        GenotypeHaplotypeAssignmentEditorWarning? {
        guard let message = model.orphanLegacyWarningMessage else {
            return nil
        }
        return .init(
            message: message,
            details: model.orphanLegacyAssignments.map {
                "\($0.locus) \($0.slot.displayName): \($0.label)"
            },
            accessibilityIdentifier:
                "manual-haplotype-orphan-legacy-warning"
        )
    }
}

@MainActor
func makeGenotypeManualHaplotypeEditorHostingView(
    model: GenotypeManualHaplotypeEditorModel,
    typographyModel: ContentTypographyModel,
    onCompareAndCopy: @escaping () -> Void = {}
) -> NSHostingView<GenotypeManualHaplotypeEditor> {
    let host = NSHostingView(
        rootView: GenotypeManualHaplotypeEditor(
            model: model,
            typographyModel: typographyModel,
            onCompareAndCopy: onCompareAndCopy
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
