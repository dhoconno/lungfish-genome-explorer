// GenotypeOverrideSection.swift - Inspector Selection tab section for analyst call overrides
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO

/// Inspector Selection tab section that captures an analyst's override for a single
/// genotype call.
///
/// Inputs:
/// - `draft`: the editable override draft (target, reason chip, rationale).
/// - `originalCall`: the pipeline's original call, surfaced as a colored swatch + label.
/// - `allowedTargets`: an optional whitelist of override targets. Reference-set bundles
///   (MCM / MAMU / MANE) supply the whitelist; manual-mode bundles pass an empty array
///   to fall back to a free-text input.
/// - `onSave`: invoked when the analyst commits the draft.
/// - `onCancel`: invoked when the analyst dismisses the draft.
struct GenotypeOverrideSection: View {
    struct OverrideDraft: Equatable {
        var target: String
        var reason: GenotypeAnnotationSidecar.OverrideReasonTag
        var rationale: String

        init(target: String = "",
             reason: GenotypeAnnotationSidecar.OverrideReasonTag = .confirmed,
             rationale: String = "") {
            self.target = target
            self.reason = reason
            self.rationale = rationale
        }
    }

    @Binding var draft: OverrideDraft
    let originalCall: String
    /// Empty array means free-text mode (manual haplotyping bundles).
    let allowedTargets: [String]
    var onSave: (OverrideDraft) -> Void
    var onCancel: () -> Void

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Override Call", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                originalRow
                Divider()
                targetRow
                reasonRow
                rationaleRow
                buttonsRow
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    // MARK: - Sub-views

    private var originalRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Original")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
            Text(originalCall.isEmpty ? "(no call)" : originalCall)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var targetRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Override To")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
            if allowedTargets.isEmpty {
                TextField("Haplotype name", text: $draft.target)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .controlSize(.small)
                    .accessibilityIdentifier("genotypeOverrideTargetField")
            } else {
                Picker(selection: $draft.target) {
                    Text("(none)").tag("")
                    ForEach(allowedTargets, id: \.self) { name in
                        Text(name).tag(name)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .font(.caption)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("genotypeOverrideTargetPicker")
            }
        }
    }

    private var reasonRow: some View {
        HStack(alignment: .top) {
            Text("Reason")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(GenotypeAnnotationSidecar.OverrideReasonTag.allCases, id: \.self) { tag in
                        reasonChip(tag)
                    }
                }
            }
            .accessibilityIdentifier("genotypeOverrideReasonChips")
        }
    }

    @ViewBuilder
    private func reasonChip(_ tag: GenotypeAnnotationSidecar.OverrideReasonTag) -> some View {
        let isSelected = draft.reason == tag
        Button(action: { draft.reason = tag }) {
            Text(reasonLabel(tag))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                lineWidth: isSelected ? 1.0 : 0.5)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("genotypeOverrideReasonChip.\(tag.rawValue)")
    }

    private var rationaleRow: some View {
        HStack(alignment: .top) {
            Text("Rationale")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
            TextEditor(text: $draft.rationale)
                .font(.caption)
                .frame(minHeight: 60)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
                .accessibilityIdentifier("genotypeOverrideRationaleEditor")
        }
    }

    private var buttonsRow: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            Button("Save") { onSave(draft) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.target.isEmpty)
        }
    }

    private func reasonLabel(_ tag: GenotypeAnnotationSidecar.OverrideReasonTag) -> String {
        switch tag {
        case .dropout: return "Dropout"
        case .contamination: return "Contamination"
        case .novel: return "Novel"
        case .misCall: return "Mis-call"
        case .confirmed: return "Confirmed"
        }
    }
}

#if DEBUG
private struct GenotypeOverrideSectionPreviewHost: View {
    @State private var draft = GenotypeOverrideSection.OverrideDraft()

    let allowedTargets: [String]

    var body: some View {
        GenotypeOverrideSection(
            draft: $draft,
            originalCall: "M2A",
            allowedTargets: allowedTargets,
            onSave: { _ in },
            onCancel: { }
        )
        .padding()
    }
}

#Preview("Override - Whitelist") {
    GenotypeOverrideSectionPreviewHost(allowedTargets: ["M1A", "M2A", "M3A", "A1_063", "-"])
        .frame(width: 360, height: 360)
}

#Preview("Override - Free Text") {
    GenotypeOverrideSectionPreviewHost(allowedTargets: [])
        .frame(width: 360, height: 360)
}
#endif
