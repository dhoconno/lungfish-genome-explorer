import AppKit
import LungfishCore
import SwiftUI

public struct GenotypeMatrixAnnotationSection: View {
    @Bindable var viewModel: GenotypeResultDisplaySectionViewModel

    public init(viewModel: GenotypeResultDisplaySectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Matrix Annotations")
                .font(.headline)

            if viewModel.hasMatrixSelection {
                selectedControls
            } else {
                Text("Select a matrix row, sample column, or cell to edit saved annotations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            reviewControls
            commentCards
            appearanceControls

            Text("Edits are saved to annotations.json and synced to current.xlsx.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reviewControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review Annotation")
                .font(.subheadline.weight(.semibold))

            Text(viewModel.matrixSelectionSummary)
                .font(.caption)
                .accessibilityIdentifier("genotype-annotation-review-selection-summary")
            Text(viewModel.matrixEvidenceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("genotype-annotation-review-evidence-summary")
            valueRow(label: "Current", value: viewModel.matrixCurrentReviewSummary)
                .font(.caption)
                .accessibilityIdentifier("genotype-annotation-review-current-state")

            HStack(spacing: 8) {
                Button("False Positive") {
                    viewModel.markMatrixFalsePositive()
                }
                .disabled(!viewModel.matrixFalsePositiveAvailability.isEnabled)
                .help(viewModel.matrixFalsePositiveAvailability.disabledReason ?? "Mark as false positive")
                .accessibilityIdentifier("genotype-annotation-review-false-positive-button")

                Button("False Negative") {
                    viewModel.markMatrixFalseNegative()
                }
                .disabled(!viewModel.matrixFalseNegativeAvailability.isEnabled)
                .help(viewModel.matrixFalseNegativeAvailability.disabledReason ?? "Mark as false negative")
                .accessibilityIdentifier("genotype-annotation-review-false-negative-button")
            }
            .controlSize(.small)

            Button {
                viewModel.clearMatrixReview()
            } label: {
                Label("Clear Review Mark", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!viewModel.matrixClearReviewAvailability.isEnabled)
            .help(viewModel.matrixClearReviewAvailability.disabledReason ?? "Clear review mark")
            .accessibilityIdentifier("genotype-annotation-review-clear-button")

            if let reason = viewModel.matrixReviewDisabledReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("genotype-annotation-review-disabled-reason")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("genotype-annotation-review-group")
    }

    private var commentCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comments")
                .font(.subheadline.weight(.semibold))
            ForEach(viewModel.matrixCommentCards, id: \.scope) { card in
                commentCard(card)
            }
        }
    }

    private func commentCard(_ card: GenotypeMatrixCommentCardState) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.scope.displayName)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if card.targetCount > 1 {
                    Text("\(card.targetCount) targets")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(card.currentValueSummary)
                .font(.caption2)
                .foregroundStyle(card.valueState == .mixed ? .primary : .secondary)

            if let comment = card.currentComment {
                Text("\(comment.author) · \(formattedTimestamp(comment.timestamp))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            TextField("Comment", text: Binding(
                get: { viewModel.matrixCommentDraft(scope: card.scope) },
                set: { viewModel.setMatrixCommentDraft($0, scope: card.scope) }
            ), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)
            .controlSize(.small)
            .accessibilityIdentifier(commentFieldAccessibilityIdentifier(card.scope))

            HStack(spacing: 10) {
                Button {
                    viewModel.saveMatrixComment(scope: card.scope)
                } label: {
                    Label(
                        card.actionTitle,
                        systemImage: card.requiresExplicitReplace
                            ? "arrow.triangle.2.circlepath"
                            : "text.bubble"
                    )
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(
                    !viewModel.matrixReviewCapability.upsertComment.isEnabled
                        || viewModel.matrixCommentDraft(scope: card.scope)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                )
                .accessibilityIdentifier(commentSaveAccessibilityIdentifier(card))

                if card.hasAnyComment {
                    Button {
                        viewModel.removeMatrixComment(scope: card.scope)
                    } label: {
                        Label(
                            card.targetCount == 1
                                ? "Remove Comment"
                                : "Remove Comments on \(card.targetCount) Targets",
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(!viewModel.matrixReviewCapability.upsertComment.isEnabled)
                    .accessibilityIdentifier(commentRemoveAccessibilityIdentifier(card.scope))
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: NSColor.separatorColor), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(commentCardAccessibilityIdentifier(card.scope))
    }

    private var appearanceControls: some View {
        DisclosureGroup("Appearance", isExpanded: $viewModel.isMatrixAppearanceExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MatrixAnnotationColorWell(
                        color: GenotypeResultDisplaySectionViewModel.nsColor(
                            from: viewModel.matrixFillColor
                        ),
                        onChange: { viewModel.setMatrixFillColor($0) }
                    )
                    .frame(width: 34, height: 22)
                    Text("Fill")
                        .font(.caption)

                    MatrixAnnotationColorWell(
                        color: GenotypeResultDisplaySectionViewModel.nsColor(
                            from: viewModel.matrixTextColor
                        ),
                        onChange: { viewModel.setMatrixTextColor($0) }
                    )
                    .frame(width: 34, height: 22)
                    Text("Text")
                        .font(.caption)
                }

                HStack(spacing: 10) {
                    MatrixAnnotationColorWell(
                        color: GenotypeResultDisplaySectionViewModel.nsColor(
                            from: viewModel.matrixBorderColor
                        ),
                        onChange: { viewModel.setMatrixBorderColor($0) }
                    )
                    .frame(width: 34, height: 22)
                    Text("Border")
                        .font(.caption)

                    Toggle("B", isOn: Binding(
                        get: { viewModel.matrixIsBold },
                        set: { viewModel.setMatrixBold($0) }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)

                    Toggle("I", isOn: Binding(
                        get: { viewModel.matrixIsItalic },
                        set: { viewModel.setMatrixItalic($0) }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.small)
                }

                paletteControls

                Button {
                    viewModel.clearMatrixStyle()
                } label: {
                    Label("Clear Style", systemImage: "eraser")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                if viewModel.canUseSupportedCellThreshold {
                    Stepper(
                        "Highlight cells with at least \(viewModel.supportedCellMinimumReads) reads",
                        value: Binding(
                            get: { viewModel.supportedCellMinimumReads },
                            set: { viewModel.setSupportedCellMinimumReads($0) }
                        ),
                        in: 0...100_000
                    )
                    .controlSize(.small)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        }
        .accessibilityIdentifier("genotype-annotation-appearance-disclosure")
    }

    private var paletteControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Colors")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Palette Target", selection: $viewModel.matrixPaletteTarget) {
                ForEach(GenotypeMatrixPaletteTarget.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)

            paletteGrid(
                title: "mcm",
                colors: viewModel.matrixMCMQuickPaletteColors
            )
            paletteGrid(
                title: "generic",
                colors: viewModel.matrixGenericQuickPaletteColors
            )
        }
    }

    private func paletteGrid(title: String, colors: [AnnotationColor]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 4), count: 8), spacing: 4) {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    Button {
                        viewModel.applyMatrixPaletteColor(color)
                    } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(swiftUIColor(from: color))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color(nsColor: NSColor.separatorColor), lineWidth: 0.5)
                            )
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help("\(title) color \(index + 1) \(color.hexString)")
                }
            }
        }
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func swiftUIColor(from color: AnnotationColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

    private func formattedTimestamp(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: timestamp) else { return timestamp }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func commentCardAccessibilityIdentifier(
        _ scope: GenotypeMatrixCommentScope
    ) -> String {
        switch scope {
        case .cell:
            return "genotype-annotation-comment-card-cell"
        case .alleleRow:
            return "genotype-annotation-comment-card-allele-row"
        case .sampleColumn:
            return "genotype-annotation-comment-card-sample-column"
        }
    }

    private func commentFieldAccessibilityIdentifier(
        _ scope: GenotypeMatrixCommentScope
    ) -> String {
        switch scope {
        case .cell:
            return "genotype-annotation-comment-field-cell"
        case .alleleRow:
            return "genotype-annotation-comment-field-allele-row"
        case .sampleColumn:
            return "genotype-annotation-comment-field-sample-column"
        }
    }

    private func commentSaveAccessibilityIdentifier(
        _ card: GenotypeMatrixCommentCardState
    ) -> String {
        if card.requiresExplicitReplace {
            switch card.scope {
            case .cell:
                return "genotype-annotation-comment-bulk-replace-cell"
            case .alleleRow:
                return "genotype-annotation-comment-bulk-replace-allele-row"
            case .sampleColumn:
                return "genotype-annotation-comment-bulk-replace-sample-column"
            }
        }
        switch card.scope {
        case .cell:
            return "genotype-annotation-comment-save-cell"
        case .alleleRow:
            return "genotype-annotation-comment-save-allele-row"
        case .sampleColumn:
            return "genotype-annotation-comment-save-sample-column"
        }
    }

    private func commentRemoveAccessibilityIdentifier(
        _ scope: GenotypeMatrixCommentScope
    ) -> String {
        switch scope {
        case .cell:
            return "genotype-annotation-comment-remove-cell"
        case .alleleRow:
            return "genotype-annotation-comment-remove-allele-row"
        case .sampleColumn:
            return "genotype-annotation-comment-remove-sample-column"
        }
    }
}

private struct MatrixAnnotationColorWell: NSViewRepresentable {
    var color: NSColor
    var onChange: (NSColor) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let colorWell = NSColorWell(frame: .zero)
        colorWell.isContinuous = true
        colorWell.color = color
        colorWell.target = context.coordinator
        colorWell.action = #selector(Coordinator.colorChanged(_:))
        return colorWell
    }

    func updateNSView(_ colorWell: NSColorWell, context: Context) {
        context.coordinator.onChange = onChange
        if colorWell.color != color {
            colorWell.color = color
        }
    }

    final class Coordinator: NSObject {
        var onChange: (NSColor) -> Void

        init(onChange: @escaping (NSColor) -> Void) {
            self.onChange = onChange
        }

        @MainActor @objc func colorChanged(_ sender: NSColorWell) {
            onChange(sender.color)
        }
    }
}
