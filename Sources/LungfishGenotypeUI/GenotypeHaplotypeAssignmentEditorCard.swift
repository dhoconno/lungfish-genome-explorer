import AppKit
import LungfishCore
import LungfishKit
import SwiftUI

struct GenotypeHaplotypeAssignmentEditorAddress: Hashable, Sendable {
    let locus: String
    let slot: HaplotypeSlot
}

struct GenotypeHaplotypeAssignmentEditorSlot: Identifiable, Sendable {
    let address: GenotypeHaplotypeAssignmentEditorAddress
    let label: String
    let suggestions: [String]
    let colorTokenIndex: Int?
    let validationDescription: String?
    let accessibilityLabel: String
    let clearAccessibilityLabel: String
    let accessibilityIdentifier: String
    let canRestoreWorkflowCall: Bool
    let restoreAccessibilityLabel: String?
    let restoreHelp: String?

    init(
        address: GenotypeHaplotypeAssignmentEditorAddress,
        label: String,
        suggestions: [String],
        colorTokenIndex: Int?,
        validationDescription: String?,
        accessibilityLabel: String,
        clearAccessibilityLabel: String,
        accessibilityIdentifier: String,
        canRestoreWorkflowCall: Bool = false,
        restoreAccessibilityLabel: String? = nil,
        restoreHelp: String? = nil
    ) {
        self.address = address
        self.label = label
        self.suggestions = suggestions
        self.colorTokenIndex = colorTokenIndex
        self.validationDescription = validationDescription
        self.accessibilityLabel = accessibilityLabel
        self.clearAccessibilityLabel = clearAccessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.canRestoreWorkflowCall = canRestoreWorkflowCall
        self.restoreAccessibilityLabel = restoreAccessibilityLabel
        self.restoreHelp = restoreHelp
    }

    var id: GenotypeHaplotypeAssignmentEditorAddress { address }
}

struct GenotypeHaplotypeAssignmentEditorRow: Identifiable, Sendable {
    let locusLabel: String
    let h1: GenotypeHaplotypeAssignmentEditorSlot
    let h2: GenotypeHaplotypeAssignmentEditorSlot

    var id: String { locusLabel }
}

struct GenotypeHaplotypeAssignmentEditorWarning: Sendable {
    let message: String
    let details: [String]
    let accessibilityIdentifier: String
}

@MainActor
struct GenotypeHaplotypeAssignmentEditorCard: View {
    static let accessibilityIdentifier =
        "shared-haplotype-assignment-card"

    let sample: String
    let completenessSummary: String
    let instruction: String
    let rows: [GenotypeHaplotypeAssignmentEditorRow]
    let isDirty: Bool
    let canSave: Bool
    let isReadOnly: Bool
    let readOnlyMessage: String?
    let emptyStateMessage: String?
    let warning: GenotypeHaplotypeAssignmentEditorWarning?
    let persistenceErrorMessage: String?
    let accessibilityPrefix: String
    let typographyModel: ContentTypographyModel
    let compareAndCopyIsEnabled: Bool?
    let onSave: () -> Void
    let onRetry: () -> Void
    let onReload: () -> Void
    let onChange: (GenotypeHaplotypeAssignmentEditorAddress, String) -> Void
    let onClear: (GenotypeHaplotypeAssignmentEditorAddress) -> Void
    let onRestore: ((GenotypeHaplotypeAssignmentEditorAddress) -> Void)?
    let onCompareAndCopy: (() -> Void)?

    private var headingFont: Font {
        typographyModel.font(for: .emphasizedBody)
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

    private var typographyScale: CGFloat {
        typographyModel.scaledPointSize(
            fromCanonicalPointSize: 100
        ) / 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Text(instruction)
                .font(captionFont)
                .foregroundStyle(.secondary)

            if let readOnlyMessage {
                Label(readOnlyMessage, systemImage: "lock.fill")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "\(accessibilityPrefix)-read-only-message"
                    )
            }

            if let warning {
                warningView(warning)
            }

            if let emptyStateMessage {
                Text(emptyStateMessage)
                    .font(captionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "\(accessibilityPrefix)-empty-message"
                    )
            }

            ForEach(Array(rows.enumerated()), id: \.element.id) {
                index, row in
                ManualHaplotypeLocusLayout(
                    typographyScale: typographyScale
                ) {
                    Text(row.locusLabel)
                        .font(headingFont)
                    slotEditor(row.h1)
                    slotEditor(row.h2)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    "\(row.locusLabel) haplotype assignments"
                )
                if index < rows.count - 1 {
                    Divider()
                }
            }

            if let onCompareAndCopy,
               let compareAndCopyIsEnabled {
                SharedHaplotypeAssignmentActionButton(
                    title: "Compare & Copy\u{2026}",
                    accessibilityLabel:
                        "Compare genotypes and copy haplotype assignments",
                    accessibilityIdentifier:
                        "manual-haplotype-compare-copy",
                    font: comboFieldFont,
                    isEnabled: compareAndCopyIsEnabled,
                    action: onCompareAndCopy
                )
            }

            if let persistenceErrorMessage {
                persistenceError(persistenceErrorMessage)
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
        .accessibilityLabel("Haplotype assignments for \(sample)")
        .accessibilityIdentifier(Self.accessibilityIdentifier)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Haplotype Assignments")
                    .font(headingFont)
                Text(completenessSummary)
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isDirty {
                Text("Unsaved")
                    .font(captionFont)
                    .foregroundStyle(.secondary)
            }
            Button("Save Assignments", action: onSave)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
                .accessibilityIdentifier(
                    "\(accessibilityPrefix)-save"
                )
        }
    }

    private func warningView(
        _ warning: GenotypeHaplotypeAssignmentEditorWarning
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                warning.message,
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(captionFont)
            .foregroundStyle(.secondary)
            ForEach(Array(warning.details.enumerated()), id: \.offset) {
                _, detail in
                Text(detail)
                    .font(monospacedFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(warning.accessibilityIdentifier)
    }

    private func slotEditor(
        _ slot: GenotypeHaplotypeAssignmentEditorSlot
    ) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(slot.address.slot.displayName)
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
                suggestions: slot.suggestions,
                accessibilityLabel: slot.accessibilityLabel,
                accessibilityIdentifier: slot.accessibilityIdentifier,
                accessibilityHelp: slot.validationDescription,
                isEnabled: !isReadOnly,
                font: comboFieldFont,
                onChange: { onChange(slot.address, $0) }
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

            if slot.canRestoreWorkflowCall,
               let onRestore,
               let restoreAccessibilityLabel =
                   slot.restoreAccessibilityLabel {
                Button { onRestore(slot.address) } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .disabled(isReadOnly)
                .help(slot.restoreHelp ?? restoreAccessibilityLabel)
                .accessibilityLabel(restoreAccessibilityLabel)
                .accessibilityIdentifier(
                    "\(slot.accessibilityIdentifier)-restore"
                )
            }

            Button { onClear(slot.address) } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isReadOnly || slot.label.isEmpty)
            .accessibilityLabel(slot.clearAccessibilityLabel)
            .accessibilityIdentifier(
                "\(slot.accessibilityIdentifier)-clear"
            )
        }
        .help(slot.validationDescription ?? slot.accessibilityLabel)
    }

    private func persistenceError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(captionFont)
                .foregroundStyle(.secondary)
            HStack {
                Button("Retry", action: onRetry)
                    .accessibilityIdentifier(
                        "\(accessibilityPrefix)-retry"
                    )
                Button("Reload", action: onReload)
                    .accessibilityIdentifier(
                        "\(accessibilityPrefix)-reload"
                    )
            }
        }
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
private struct SharedHaplotypeAssignmentActionButton:
    NSViewRepresentable {
    let title: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let font: NSFont
    let isEnabled: Bool
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: title,
            target: context.coordinator,
            action: #selector(Coordinator.performAction)
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(
        _ button: NSButton,
        coordinator: Coordinator
    ) {
        coordinator.action = action
        button.title = title
        button.font = font
        button.isEnabled = isEnabled
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() {
            action()
        }
    }
}
