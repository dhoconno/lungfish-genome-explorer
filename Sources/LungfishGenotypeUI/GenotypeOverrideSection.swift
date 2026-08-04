// GenotypeOverrideSection.swift - Inspector Selection tab section for analyst call overrides
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO

/// UI-facing result of an effective haplotype mutation. Views use this
/// outcome to retain analyst drafts on no-op and failed publications without
/// taking ownership of error presentation.
enum GenotypeHaplotypeMutationOutcome: Equatable {
    case changed
    case unchanged
    case failure
}

/// Concrete AppKit action control for mutation paths embedded in SwiftUI.
/// Stable NSButton identity makes keyboard and accessibility focus survive a
/// no-op or failed transaction while the surrounding draft remains mounted.
@MainActor
struct GenotypeMutationActionButton: NSViewRepresentable {
    let title: String
    let accessibilityIdentifier: String
    var systemImageName: String? = nil
    var controlSize: NSControl.ControlSize = .small
    var isBorderless = false
    var isEnabled = true
    var keyEquivalent = ""
    var help: String? = nil
    var tintColor: NSColor? = nil
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
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: NSButton, coordinator: Coordinator) {
        coordinator.action = action
        button.title = title
        button.controlSize = controlSize
        button.bezelStyle = .rounded
        button.isBordered = !isBorderless
        button.isEnabled = isEnabled
        button.keyEquivalent = keyEquivalent
        button.toolTip = help
        button.contentTintColor = tintColor
        if let systemImageName {
            button.image = NSImage(
                systemSymbolName: systemImageName,
                accessibilityDescription: nil
            )
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
        }
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
    }

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

    /// Free-text editor with suggestion chips. The user can type any value
    /// (manual mode, novel allele names) while still getting one-tap access
    /// to the definition set's whitelist. An off-whitelist indicator surfaces
    /// when a typed value isn't in the suggestion list so reviewers see it.
    @ViewBuilder
    private var targetRow: some View {
        HStack(alignment: .top) {
            Text("Override To")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField("Haplotype name", text: $draft.target)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .controlSize(.small)
                        .accessibilityIdentifier("genotypeOverrideTargetField")
                    if isOffWhitelist {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .lungfishDanger))
                            .help("Off-whitelist value. Reviewers will see this as a custom override.")
                            .accessibilityLabel("Off-whitelist override")
                    }
                }
                if !filteredSuggestions.isEmpty {
                    suggestionChips
                }
            }
        }
    }

    /// True when there's a typed value AND a whitelist AND the typed value
    /// doesn't match any whitelist entry. Used to surface a small triangle
    /// warning next to the field so analysts see they're going off-piste.
    private var isOffWhitelist: Bool {
        let trimmed = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !normalizedAllowedTargets.isEmpty
            && !normalizedAllowedTargets.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    }

    private var normalizedAllowedTargets: [String] {
        GenotypeHaplotypeOverrideTargets.expandedTargets(
            from: allowedTargets,
            includeUnknown: !allowedTargets.isEmpty
        )
    }

    /// Whitelist entries that prefix-match what the user has typed so far.
    /// When the field is empty, the full whitelist is offered. Capped at 8
    /// chips so a Rhesus definition set with hundreds of names doesn't blow
    /// out the inspector vertically — the analyst can keep typing to narrow.
    private var filteredSuggestions: [String] {
        let query = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [String]
        if query.isEmpty {
            candidates = normalizedAllowedTargets
        } else {
            candidates = normalizedAllowedTargets.filter {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
        return Array(candidates.prefix(8))
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(filteredSuggestions, id: \.self) { name in
                    Button(action: { draft.target = name }) {
                        Text(name)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(draft.target == name ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(draft.target == name ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                            .foregroundStyle(draft.target == name ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("genotypeOverrideSuggestion.\(name)")
                }
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
            GenotypeMutationActionButton(
                title: "Save",
                accessibilityIdentifier: "genotypeOverrideSaveButton",
                isEnabled: !draft.target.isEmpty,
                keyEquivalent: "\r",
                action: { onSave(draft) }
            )
        }
    }

    private func reasonLabel(_ tag: GenotypeAnnotationSidecar.OverrideReasonTag) -> String {
        switch tag {
        case .misCall: return "Mis-call"
        case .dropoutSuspected: return "Dropout suspected"
        case .crossContamination: return "Cross-contamination"
        case .novel: return "Novel"
        case .pedigreeConflict: return "Pedigree conflict"
        case .analystJudgment: return "Analyst judgment"
        case .confirmed: return "Confirmed"
        case .other: return "Other"
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
