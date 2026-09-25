// DemoProjectsView.swift - SwiftUI content of the Help > Demo Projects… sheet
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishKit
import LungfishWorkflow

enum DemoProjectsAccessibilityID {
    static let sheet = "demo-projects-sheet"
    static let folderPath = "demo-projects-folder-path"
    static let changeFolder = "demo-projects-change-folder"
    static let useDefaultFolder = "demo-projects-use-default-folder"
    static let done = "demo-projects-done"

    static func row(_ id: String) -> String { "demo-projects-row-\(id)" }
    static func primary(_ id: String) -> String { "demo-projects-primary-\(id)" }
    static func reveal(_ id: String) -> String { "demo-projects-reveal-\(id)" }
    static func replace(_ id: String) -> String { "demo-projects-replace-\(id)" }
    static func status(_ id: String) -> String { "demo-projects-status-\(id)" }
    static func chapter(_ id: String, _ index: Int) -> String { "demo-projects-chapter-\(id)-\(index)" }
}

struct DemoProjectsView: View {
    @Bindable var viewModel: DemoProjectsViewModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                // A second dialog lives on a different view so SwiftUI presents both reliably.
                .confirmationDialog(
                    "Replace \(viewModel.replaceConfirmation?.title ?? "Project") with a Fresh Copy?",
                    isPresented: Binding(
                        get: { viewModel.replaceConfirmation != nil },
                        set: { if !$0 { viewModel.replaceConfirmation = nil } }
                    ),
                    presenting: viewModel.replaceConfirmation
                ) { project in
                    Button("Replace with a Fresh Copy") {
                        viewModel.download(project, replaceExisting: true)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { _ in
                    Text("The current copy, including any changes you made to it, moves to the Trash after the new copy has downloaded and passed its checks.")
                }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 480, idealHeight: 600)
        .tint(Color.lungfishOrangeFallback)
        // `.contain` keeps this a container. Without it the identifier is copied onto every
        // descendant and replaces their own (Done, Change…) identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DemoProjectsAccessibilityID.sheet)
        .alert(item: $viewModel.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            existingCopyTitle,
            isPresented: Binding(
                get: { viewModel.existingCopyPrompt != nil },
                set: { if !$0 { viewModel.existingCopyPrompt = nil } }
            ),
            presenting: viewModel.existingCopyPrompt
        ) { project in
            Button("Open Existing Copy") { viewModel.open(project) }
            Button("Replace with a Fresh Copy") {
                viewModel.download(project, replaceExisting: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text(existingCopyMessage(for: project))
        }
    }

    private var existingCopyTitle: String {
        "\(viewModel.existingCopyPrompt?.title ?? "This project") Is Already Downloaded"
    }

    private func existingCopyMessage(for project: DemoProject) -> String {
        var message = "A copy is already in \(viewModel.installDirectory.path)."
        if case .updateAvailable(let installed, let available) = viewModel.status(for: project) {
            message += " It is version \(installed), and version \(available) is available."
        }
        message += " Replacing it moves the current copy to the Trash."
        return message
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Demo Projects")
                .font(.title2.weight(.semibold))
            Text("Ready-to-analyse projects that go with the user manual. Each one downloads once, then opens like any other project.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Save to:")
                    .foregroundStyle(.secondary)
                Text(viewModel.installDirectory.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(viewModel.installDirectory.path)
                    .accessibilityIdentifier(DemoProjectsAccessibilityID.folderPath)
                Spacer(minLength: 8)
                Button("Change…") { viewModel.chooseFolder() }
                    .accessibilityIdentifier(DemoProjectsAccessibilityID.changeFolder)
                if !viewModel.isUsingDefaultFolder {
                    Button("Use Default") { viewModel.resetInstallDirectory() }
                        .accessibilityIdentifier(DemoProjectsAccessibilityID.useDefaultFolder)
                }
            }
            .font(.callout)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.manifestError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("The demo project list could not be loaded.")
                    .font(.headline)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                // A plain VStack, not a LazyVStack: the handful of rows gains nothing from
                // laziness, and a lazy stack puts the rows behind an AXOpaqueProviderGroup,
                // an element with no press action that some accessibility clients stop at.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.projects) { project in
                        DemoProjectRow(project: project, viewModel: viewModel)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                        if project.id != viewModel.projects.last?.id {
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Downloads also appear in the Operations panel.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(DemoProjectsAccessibilityID.done)
        }
    }
}

private struct DemoProjectRow: View {
    let project: DemoProject
    let viewModel: DemoProjectsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project.title)
                        .font(.headline)
                    Text(viewModel.sizeText(for: project))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(viewModel.statusText(for: project))
                        .font(.callout)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier(DemoProjectsAccessibilityID.status(project.id))
                }
                Text(project.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !project.chapters.isEmpty {
                    DemoProjectFlowLayout(spacing: 10, lineSpacing: 4) {
                        Text("Manual:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(Array(project.chapters.enumerated()), id: \.element) { index, chapter in
                            Button(chapter.title) { viewModel.openChapter(chapter) }
                                .buttonStyle(.link)
                                .font(.callout)
                                .focusable(interactions: .activate)
                                .help(chapter.url?.absoluteString ?? chapter.path)
                                .accessibilityLabel(DemoProjectsViewModel.chapterAccessibilityLabel(for: chapter))
                                .accessibilityIdentifier(DemoProjectsAccessibilityID.chapter(project.id, index))
                        }
                    }
                }
                if let download = viewModel.downloads[project.id] {
                    VStack(alignment: .leading, spacing: 4) {
                        if let fraction = download.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(download.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
                if let reason = viewModel.unsupportedReason(for: project) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button(viewModel.primaryButtonTitle(for: project)) {
                    viewModel.performPrimaryAction(for: project)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isDownloading(project) || viewModel.unsupportedReason(for: project) != nil)
                .accessibilityLabel(viewModel.primaryAccessibilityLabel(for: project))
                .accessibilityIdentifier(DemoProjectsAccessibilityID.primary(project.id))

                if viewModel.status(for: project).isInstalled {
                    Button("Reveal in Finder") { viewModel.reveal(project) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .focusable(interactions: .activate)
                        .accessibilityLabel(DemoProjectsViewModel.revealAccessibilityLabel(for: project))
                        .accessibilityIdentifier(DemoProjectsAccessibilityID.reveal(project.id))
                    Button("Replace with a Fresh Copy…") { viewModel.requestReplace(project) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .focusable(interactions: .activate)
                        .disabled(viewModel.isDownloading(project) || viewModel.unsupportedReason(for: project) != nil)
                        .accessibilityLabel(DemoProjectsViewModel.replaceAccessibilityLabel(for: project))
                        .accessibilityIdentifier(DemoProjectsAccessibilityID.replace(project.id))
                }
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DemoProjectsAccessibilityID.row(project.id))
    }

    private var statusColor: Color {
        switch viewModel.status(for: project) {
        case .notDownloaded: return .secondary
        case .downloaded: return .primary
        case .updateAvailable: return Color.lungfishOrangeFallback
        }
    }
}

/// Wraps its children onto as many lines as the width needs.
struct DemoProjectFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
