// ImportCenterView.swift - SwiftUI view for the Import Center
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import UniformTypeIdentifiers

/// Main SwiftUI view for the Import Center window.
///
/// Displays four tabs controlled by the toolbar segmented control:
/// - **Alignments**: BAM/CRAM alignment imports.
/// - **Variants**: VCF variant file imports.
/// - **Classification Results**: NAO-MGS, Kraken2, EsViritu, TaxTriage.
/// - **References**: Reference FASTA imports.
struct ImportCenterView: View {

    /// The shared view model, owned by ``ImportCenterWindowController``.
    @Bindable var viewModel: ImportCenterViewModel

    var body: some View {
        Group {
            if viewModel.filteredCards.isEmpty {
                emptyState
            } else {
                cardList
            }
        }
        .frame(minWidth: 600, minHeight: 350)
    }

    // MARK: - Card List

    private var cardList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Tab header
                tabHeader
                    .padding(.top, 8)

                ForEach(viewModel.filteredCards) { card in
                    ImportCardView(card: card) {
                        viewModel.performImport(for: card)
                    } onDrop: { urls in
                        viewModel.performDropImport(urls: urls, for: card)
                    }
                }

                // Recent Imports section (only when history exists for this tab)
                if !viewModel.recentHistory.isEmpty {
                    recentImportsSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var tabHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.selectedTab.sfSymbol)
                .font(.title2)
                .foregroundStyle(Color.lungfishOrangeFallback)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedTab.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(tabSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private var tabSubtitle: String {
        switch viewModel.selectedTab {
        case .alignments:
            return "Import aligned reads for visualization"
        case .variants:
            return "Import variant calls for annotation"
        case .classificationResults:
            return "Import metagenomic classification results"
        case .references:
            return "Import reference genome sequences"
        }
    }

    // MARK: - Recent Imports Section

    private var recentImportsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Text("Recent Imports")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)

            // Entry rows (last 5 from recentHistory)
            VStack(spacing: 0) {
                ForEach(Array(viewModel.recentHistory.prefix(5).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 36)
                    }
                    ImportHistoryRow(entry: entry)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )

            // Clear History link
            HStack {
                Spacer()
                Button("Clear History") {
                    viewModel.clearHistory()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Matching Import Types")
                .font(.title2)
                .fontWeight(.medium)
            Text("Try a different search term or select another category.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.body)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Import Card View

/// A single import type card with icon, title, description, and Import button.
///
/// Supports drag-and-drop: files dragged onto the card trigger the same
/// import path as clicking "Import...". The card highlights with an orange
/// border while a compatible drag is in progress over it.
private struct ImportCardView: View {

    let card: ImportCardInfo
    let onImport: () -> Void
    let onDrop: ([URL]) -> Void

    /// Whether a drag is currently hovering over this card.
    @State private var isDropTargeted = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon
            Group {
                if let customImage = card.customImage {
                    Image(nsImage: customImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: card.sfSymbol)
                        .font(.system(size: 28))
                        .foregroundStyle(Color.lungfishOrangeFallback)
                }
            }
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.lungfishOrangeFallback.opacity(0.1))
            )

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.headline)

                Text(card.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = card.fileHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            // Import button
            Button("Import\u{2026}") {
                onImport()
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTargeted
                        ? Color.lungfishOrangeFallback
                        : Color(.separatorColor),
                    lineWidth: isDropTargeted ? 2 : 0.5
                )
                .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            resolveDroppedURLs(from: providers)
            return true
        }
    }

    /// Resolves file URLs from the given item providers and forwards them to ``onDrop``.
    private func resolveDroppedURLs(from providers: [NSItemProvider]) {
        var resolved: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    resolved.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                guard !resolved.isEmpty else { return }
                onDrop(resolved)
            }
        }
    }
}

// MARK: - Import History Row

/// A compact row displaying a single ``ImportHistoryEntry``.
private struct ImportHistoryRow: View {

    let entry: ImportHistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            // Success / failure indicator
            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                .frame(width: 18)

            // File name
            Text(entry.fileName)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)

            // Import type badge
            Text(entry.importAction)
                .font(.caption)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.lungfishOrangeFallback.opacity(0.12))
                )
                .foregroundStyle(Color.lungfishOrangeFallback)

            Spacer()

            // Relative date
            Text(entry.date.relativeFormatted)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Date Relative Formatting

private extension Date {
    /// Returns a short relative description such as "2 hours ago" or "just now".
    var relativeFormatted: String {
        let seconds = Date.now.timeIntervalSince(self)
        switch seconds {
        case ..<60:
            return "just now"
        case 60..<3600:
            let mins = Int(seconds / 60)
            return "\(mins) min\(mins == 1 ? "" : "s") ago"
        case 3600..<86400:
            let hrs = Int(seconds / 3600)
            return "\(hrs) hour\(hrs == 1 ? "" : "s") ago"
        case 86400..<604800:
            let days = Int(seconds / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return formatter.string(from: self)
        }
    }
}
