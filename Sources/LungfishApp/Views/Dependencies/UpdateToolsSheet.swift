// UpdateToolsSheet.swift - The launch-time and on-demand "update your tools" sheet
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishKit
import LungfishWorkflow

enum UpdateToolsSheetAccessibilityID {
    static let root = "update-tools-sheet"
    static let updateButton = "update-tools-update-button"
    static let laterButton = "update-tools-later-button"
    static let quitButton = "update-tools-quit-button"
    static let doneButton = "update-tools-done-button"
    static let freeSpaceWarning = "update-tools-free-space-warning"
    static let failureSummary = "update-tools-failure-summary"

    static let removalsToggle = "updateTools.removals"

    static func environmentToggle(_ name: String) -> String { "updateTools.env.\(name)" }
    static func databaseToggle(_ id: String) -> String { "updateTools.db.\(id)" }
}

/// Presents a ``ReconciliationPlan`` for review and runs the pieces the user keeps.
///
/// Required work is shown but not unselectable: when the plan has any, the dismiss button
/// becomes "Quit" rather than "Later", because the app cannot run its pipelines without it.
struct UpdateToolsSheet: View {
    @Bindable var viewModel: UpdateToolsSheetViewModel

    /// Dismisses without running. "Later" when deferral is allowed, "Quit" when it is not.
    let onDismiss: () -> Void
    /// Closes the sheet after a finished run.
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 500)
        .frame(minHeight: 420, maxHeight: 560)
        .accessibilityIdentifier(UpdateToolsSheetAccessibilityID.root)
        .onAppear {
            // Re-sample here rather than reading the volume from a computed property: the
            // free-space figure is only meaningful at the moment the sheet is shown.
            viewModel.refreshFreeSpace()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Update tools to \(viewModel.plan.targetDependencySet)")
                .font(.headline)
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var headerSubtitle: String {
        if viewModel.completed {
            return viewModel.failureSummary ?? "All selected items finished."
        }
        if viewModel.plan.hasRequiredWork {
            return "Lungfish needs these tools before it can run analyses. Optional items can wait."
        }
        return "These updates are optional. You can run them now or later from the Plugin Manager."
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !viewModel.requiredEnvironments.isEmpty {
                    section(
                        title: "Required tools",
                        subtitle: "Always installed."
                    ) {
                        ForEach(viewModel.requiredEnvironments) { change in
                            environmentRow(change, isSelectable: false)
                        }
                    }
                }

                if !viewModel.optionalEnvironments.isEmpty {
                    section(
                        title: "Optional tools",
                        subtitle: "Installed packs that have a newer pinned version."
                    ) {
                        ForEach(viewModel.optionalEnvironments) { change in
                            environmentRow(change, isSelectable: true)
                        }
                    }
                }

                if !viewModel.plan.databaseUpdates.isEmpty {
                    section(
                        title: "Databases",
                        subtitle: "Required databases are always updated; others are yours to choose."
                    ) {
                        ForEach(viewModel.requiredDatabases) { change in
                            databaseRow(change, isSelectable: false)
                        }
                        ForEach(viewModel.advisoryDatabases) { change in
                            databaseRow(change, isSelectable: true)
                        }
                    }
                }

                if !viewModel.plan.removeEnvironments.isEmpty {
                    section(
                        title: "Removals",
                        subtitle: "Retired tools that are no longer part of the tool set."
                    ) {
                        Toggle(isOn: $viewModel.includeRemovals) {
                            Text("Remove retired tools")
                                .font(.callout)
                        }
                        .disabled(viewModel.isRunning || viewModel.completed)
                        .accessibilityIdentifier(UpdateToolsSheetAccessibilityID.removalsToggle)

                        ForEach(viewModel.plan.removeEnvironments.sorted(), id: \.self) { name in
                            HStack(spacing: 8) {
                                Text(name)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                statusBadge(
                                    for: UpdateToolsSheetViewModel.removalStatusKey(name)
                                )
                            }
                        }
                    }
                }

                if let bootstrap = viewModel.plan.bootstrapUpdate {
                    section(title: "Package manager", subtitle: nil) {
                        HStack {
                            Text("micromamba")
                                .font(.callout)
                            Spacer()
                            Text(versionTransition(from: bootstrap.currentVersion, to: bootstrap.targetVersion))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            statusBadge(for: "micromamba")
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func section(
        title: String,
        subtitle: String?,
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                rows()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func environmentRow(
        _ change: ReconciliationPlan.EnvironmentChange,
        isSelectable: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if isSelectable {
                Toggle(isOn: environmentBinding(change.environment)) {
                    Text(change.environment)
                        .font(.callout)
                }
                .disabled(viewModel.isRunning || viewModel.completed)
                .accessibilityIdentifier(
                    UpdateToolsSheetAccessibilityID.environmentToggle(change.environment)
                )
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.lungfishOrangeFallback)
                    .accessibilityHidden(true)
                Text(change.environment)
                    .font(.callout)
                    .accessibilityIdentifier(
                        UpdateToolsSheetAccessibilityID.environmentToggle(change.environment)
                    )
                    .accessibilityLabel("\(change.environment), required")
            }
            Spacer()
            Text(versionTransition(from: change.currentSpec, to: change.targetSpec))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            statusBadge(for: change.environment)
        }
    }

    private func databaseRow(
        _ change: ReconciliationPlan.DatabaseChange,
        isSelectable: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if isSelectable {
                Toggle(isOn: databaseBinding(change.id)) {
                    Text(change.displayName)
                        .font(.callout)
                }
                .disabled(viewModel.isRunning || viewModel.completed)
                .accessibilityIdentifier(
                    UpdateToolsSheetAccessibilityID.databaseToggle(change.id)
                )
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.lungfishOrangeFallback)
                    .accessibilityHidden(true)
                Text(change.displayName)
                    .font(.callout)
                    .accessibilityIdentifier(
                        UpdateToolsSheetAccessibilityID.databaseToggle(change.id)
                    )
                    .accessibilityLabel("\(change.displayName), required")
            }
            Spacer()
            Text(databaseDetail(change))
                .font(.caption)
                .foregroundStyle(.secondary)
            statusBadge(for: change.id)
        }
    }

    private func databaseDetail(_ change: ReconciliationPlan.DatabaseChange) -> String {
        let versions = versionTransition(from: change.installedVersion, to: change.targetVersion)
        guard change.estimatedBytes > 0 else { return versions }
        return "\(versions), \(formatted(change.estimatedBytes))"
    }

    private func versionTransition(from current: String?, to target: String) -> String {
        guard let current, !current.isEmpty else { return target }
        return "\(current) to \(target)"
    }

    @ViewBuilder
    private func statusBadge(for id: String) -> some View {
        switch viewModel.itemStatus[id] {
        case .running(let detail):
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Finished")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
                .accessibilityLabel("Failed: \(message)")
        case .skipped(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .pending, .none:
            EmptyView()
        }
    }

    private func environmentBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedOptionalEnvironments.contains(name) },
            set: { isOn in
                if isOn {
                    viewModel.selectedOptionalEnvironments.insert(name)
                } else {
                    viewModel.selectedOptionalEnvironments.remove(name)
                }
            }
        )
    }

    private func databaseBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedDatabases.contains(id) },
            set: { isOn in
                if isOn {
                    viewModel.selectedDatabases.insert(id)
                } else {
                    viewModel.selectedDatabases.remove(id)
                }
            }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = viewModel.freeSpaceWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(UpdateToolsSheetAccessibilityID.freeSpaceWarning)
            }
            if viewModel.completed, let failure = viewModel.failureSummary {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(UpdateToolsSheetAccessibilityID.failureSummary)
            }

            HStack(spacing: 12) {
                if !viewModel.completed {
                    Text("Estimated download: about \(formatted(viewModel.estimatedBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if viewModel.completed {
                    Button("Done") {
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.lungfishOrangeFallback)
                    .accessibilityIdentifier(UpdateToolsSheetAccessibilityID.doneButton)
                } else {
                    Button(viewModel.canDismissLater ? "Later" : "Quit") {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isRunning)
                    .accessibilityIdentifier(
                        viewModel.canDismissLater
                            ? UpdateToolsSheetAccessibilityID.laterButton
                            : UpdateToolsSheetAccessibilityID.quitButton
                    )

                    Button("Update") {
                        Task { await viewModel.run() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.lungfishOrangeFallback)
                    .disabled(!viewModel.canStartUpdate)
                    .accessibilityIdentifier(UpdateToolsSheetAccessibilityID.updateButton)
                }
            }
        }
        .padding(16)
    }

    private func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
