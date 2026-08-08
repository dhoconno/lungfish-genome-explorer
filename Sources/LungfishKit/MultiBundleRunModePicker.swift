// MultiBundleRunModePicker.swift - Shared multi-bundle run-mode wizard section (MB-0)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

// MARK: - MultiBundleRunModePicker

/// A standard wizard section offering "run separately per bundle" vs.
/// "combine all inputs, run once" when N>1 bundles are selected.
///
/// Matches the wizard-sheet idiom used across `ClassificationWizardSheet` /
/// `AssemblyWizardSheet`: a labeled section with a description caption,
/// Lungfish Orange accent. Renders nothing when `bundleCount < 2` (a single
/// bundle has no mode to choose). When `policy.allowedModes` excludes a
/// mode, that mode's row renders disabled with `policy.lockReason` as its
/// caption instead of the normal description.
public struct MultiBundleRunModePicker: View {

    /// Number of bundles currently selected. The picker is hidden when this
    /// is less than 2.
    let bundleCount: Int

    /// Which modes are selectable and which is locked (if any).
    let policy: MultiBundleRunPolicy

    /// The currently selected mode.
    @Binding var selection: MultiBundleRunMode

    public init(bundleCount: Int, policy: MultiBundleRunPolicy, selection: Binding<MultiBundleRunMode>) {
        self.bundleCount = bundleCount
        self.policy = policy
        self._selection = selection
    }

    // MARK: - Visibility

    /// Whether the picker should render any content. Exposed as a pure,
    /// testable predicate mirroring the body's early-return.
    public nonisolated static func isVisible(bundleCount: Int) -> Bool {
        bundleCount >= 2
    }

    // MARK: - Row Model

    /// Pure, testable description of one radio row's rendered state.
    public struct RowState: Equatable, Sendable {
        public let mode: MultiBundleRunMode
        public let title: String
        public let isEnabled: Bool
        public let caption: String

        public init(mode: MultiBundleRunMode, title: String, isEnabled: Bool, caption: String) {
            self.mode = mode
            self.title = title
            self.isEnabled = isEnabled
            self.caption = caption
        }
    }

    /// Computes the two rows' rendered state for a given bundle count and
    /// policy, without any SwiftUI involvement. Used both by the view body
    /// and directly by unit tests.
    public nonisolated static func rowStates(bundleCount: Int, policy: MultiBundleRunPolicy) -> [RowState] {
        MultiBundleRunMode.allCases.map { mode in
            let isEnabled = policy.allowedModes.contains(mode)
            return RowState(
                mode: mode,
                title: title(for: mode, bundleCount: bundleCount),
                isEnabled: isEnabled,
                caption: isEnabled ? description(for: mode) : (policy.lockReason ?? description(for: mode))
            )
        }
    }

    nonisolated static func title(for mode: MultiBundleRunMode, bundleCount: Int) -> String {
        switch mode {
        case .perBundle:
            return "Run separately per bundle (\(bundleCount) results)"
        case .combined:
            return "Combine all inputs, run once (1 result)"
        }
    }

    nonisolated static func description(for mode: MultiBundleRunMode) -> String {
        switch mode {
        case .perBundle:
            return "Each bundle is processed independently."
        case .combined:
            return "All bundles are pooled into a single input."
        }
    }

    /// The mode selection should fall back to when the currently-selected
    /// mode becomes locked out by `policy`. Pure helper used by the view's
    /// `.onAppear`/`.onChange` and directly testable.
    public nonisolated static func resolvedSelection(
        current: MultiBundleRunMode,
        policy: MultiBundleRunPolicy
    ) -> MultiBundleRunMode {
        if policy.allowedModes.contains(current) {
            return current
        }
        if policy.allowedModes.contains(policy.defaultMode) {
            return policy.defaultMode
        }
        return policy.allowedModes.first ?? current
    }

    // MARK: - Body

    public var body: some View {
        if Self.isVisible(bundleCount: bundleCount) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run Mode")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.lungfishSecondaryText)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.rowStates(bundleCount: bundleCount, policy: policy), id: \.mode) { row in
                        rowButton(row)
                    }
                }
            }
            .onAppear {
                selection = Self.resolvedSelection(current: selection, policy: policy)
            }
        }
    }

    private func rowButton(_ row: RowState) -> some View {
        Button {
            guard row.isEnabled else { return }
            selection = row.mode
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selection == row.mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(row.isEnabled ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText)
                    .imageScale(.medium)

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 12))
                        .foregroundStyle(row.isEnabled ? Color.primary : Color.lungfishSecondaryText)
                    Text(row.caption)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!row.isEnabled)
        .accessibilityIdentifier("multi-bundle-run-mode-\(row.mode.rawValue)")
    }
}
