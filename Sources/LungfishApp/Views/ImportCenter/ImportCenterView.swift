// ImportCenterView.swift - SwiftUI view for the Import Center
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import UniformTypeIdentifiers

/// Main SwiftUI view for the Import Center window.
///
/// Uses the same in-window sidebar pattern as the welcome screen so import
/// categories stay visible as the catalog grows.
struct ImportCenterView: View {

    /// The shared view model, owned by ``ImportCenterWindowController``.
    @Bindable var viewModel: ImportCenterViewModel

    var body: some View {
        ZStack {
            Color.lungfishCanvasBackground
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 18) {
                importSidebar

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerRow
                        selectedSectionContent
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 30)
                }
                .background(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(Color.lungfishCanvasBackground)
                )
            }
            .padding(18)
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(Color.lungfishCanvasBackground)
        .tint(.lungfishCreamsicleFallback)
        .accessibilityIdentifier(ImportCenterAccessibilityID.root)
    }

    private var headerRow: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.selectedTab.title)
                    .font(.system(size: 34, weight: .bold))

                Text(sectionSubtitle)
                    .font(.title3)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }

            Spacer(minLength: 12)
        }
        .padding(.bottom, 4)
        .accessibilityIdentifier(ImportCenterAccessibilityID.header)
    }

    private var sectionSubtitle: String {
        switch viewModel.selectedTab {
        case .sequencingReads:
            return "Import raw sequencing reads and run folders for processing and analysis."
        case .alignments:
            return "Import aligned read files for coverage, duplicate marking, and track display."
        case .variants:
            return "Import variant calls for annotation and bundle creation."
        case .classificationResults:
            return "Import metagenomic result files that Lungfish can open and analyze."
        case .references:
            return "Import reference sequences and create Lungfish reference bundles."
        case .applicationExports:
            return "Import migration exports from other bioinformatics applications into Lungfish collections."
        }
    }

    @ViewBuilder
    private var selectedSectionContent: some View {
        if viewModel.visibleCards.isEmpty {
            emptyState(
                title: "Nothing to Import Here Yet",
                message: "The selected category does not have any import actions available right now."
            )
        } else {
            cardSection(cards: viewModel.visibleCards)
        }
    }

    private func cardSection(cards: [ImportCardInfo]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(cards) { card in
                ImportCardView(card: card) {
                    viewModel.performImport(for: card)
                } onDrop: { urls in
                    viewModel.performDropImport(urls: urls, for: card)
                }
            }
        }
        .accessibilityIdentifier(ImportCenterAccessibilityID.cardList)
    }

    private func emptyState(title: String, message: String) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.lungfishCardBackground)
            .overlay {
                VStack(spacing: 10) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color.lungfishSecondaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 180)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.lungfishStroke, lineWidth: 1)
            )
    }

    private var importSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Import Center")
                    .font(.system(size: 28, weight: .bold))

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ImportCenterViewModel.Tab.allCases, id: \.self) { tab in
                        Button {
                            viewModel.selectedTab = tab
                        } label: {
                            HStack(spacing: 12) {
                                Text(tab.title)
                                    .font(.system(size: 15, weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(viewModel.selectedTab == tab ? Color.lungfishWelcomeSelectionFill : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(viewModel.selectedTab == tab ? Color.lungfishCreamsicleFallback : Color.primary)
                        .accessibilityIdentifier(ImportCenterAccessibilityID.tab(tab))
                    }
                }
            }

            Spacer(minLength: 28)

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                    .overlay(Color.lungfishStroke)
                Text("Imports are routed into the current project.")
                    .font(.caption)
                    .foregroundStyle(Color.lungfishSecondaryText)
            }
            .padding(.top, 22)
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.lungfishWelcomeSidebarBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.lungfishStroke, lineWidth: 1)
        )
        .accessibilityIdentifier(ImportCenterAccessibilityID.sidebar)
    }
}

// MARK: - Import Card View

/// A single import type card with title, description, and Import button.
///
/// Supports drag-and-drop: files dragged onto the card trigger the same
/// import path as clicking "Import...". The card highlights with a creamsicle
/// border while a compatible drag is in progress over it.
private struct ImportCardView: View {

    let card: ImportCardInfo
    let onImport: () -> Void
    let onDrop: ([URL]) -> Void

    /// Whether a drag is currently hovering over this card.
    @State private var isDropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.headline)

                Text(card.description)
                    .font(.subheadline)
                    .foregroundStyle(Color.lungfishSecondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = card.fileHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(Color.lungfishSecondaryText)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            Button("Import…") {
                onImport()
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            .accessibilityIdentifier(ImportCenterAccessibilityID.buttonID(card.id))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.lungfishCardBackground)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTargeted ? Color.lungfishCreamsicleFallback : Color.lungfishStroke,
                    lineWidth: isDropTargeted ? 2 : 0.5
                )
                .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            resolveDroppedURLs(from: providers)
            return true
        }
        .accessibilityIdentifier(ImportCenterAccessibilityID.cardID(card.id))
    }

    /// Resolves file URLs from the given item providers and forwards them to ``onDrop``.
    private func resolveDroppedURLs(from providers: [NSItemProvider]) {
        let collector = LockedURLCollector()
        let group = DispatchGroup()

        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    collector.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let resolved = collector.snapshot()
                guard !resolved.isEmpty else { return }
                onDrop(resolved)
            }
        }
    }
}

private final class LockedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
