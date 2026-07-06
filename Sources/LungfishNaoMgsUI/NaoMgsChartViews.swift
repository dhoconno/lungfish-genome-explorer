// NaoMgsChartViews.swift - SwiftUI overview chart for NAO-MGS results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

// MARK: - Lungfish Orange

/// Lungfish brand accent color — uses the shared adaptive definition.
private let lungfishOrange = Color.lungfishOrangeFallback

/// Formats a read count with K/M suffixes for display in overview rows.
///
/// Module-level free function to avoid `@MainActor` isolation issues in
/// `@Sendable` closures (see project memory: "Free Functions vs Instance Methods").
private func naoMgsFormatReadCount(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return "\(count)"
}

/// A compact metric card used in the NAO-MGS overview's quick-stats row.
private struct MetricCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - NaoMgsOverviewView

/// The overview shown when no taxon is selected.
///
/// Displays a summary of the entire NAO-MGS result with a bar chart of
/// the top taxa by hit count and a quick-stats section.
struct NaoMgsOverviewView: View {

    /// All taxon summaries sorted by hit count (deduplicated across samples).
    let taxonSummaries: [NaoMgsTaxonSummary]

    /// Total hit reads.
    let totalHitReads: Int

    /// Sample names included in this view.
    let sampleNames: [String]

    /// Called when a taxon row is clicked to select it in the table.
    var onTaxonSelected: ((Int) -> Void)?

    /// Top taxa to show in the bar chart.
    private var topTaxa: [NaoMgsTaxonSummary] {
        Array(taxonSummaries.prefix(15))
    }

    /// Maximum hit count for bar scaling.
    private var maxHitCount: Int {
        topTaxa.first?.hitCount ?? 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                VStack(alignment: .leading, spacing: 2) {
                    Text("NAO-MGS Results Overview")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Select a taxon in the table to view metrics and read evidence.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Quick stats
                HStack(spacing: 16) {
                    MetricCard(label: "Total Hits", value: naoMgsFormatReadCount(totalHitReads))
                    MetricCard(label: "Unique Taxa", value: "\(taxonSummaries.count)")
                    if sampleNames.count == 1 {
                        MetricCard(label: "Sample", value: sampleNames[0])
                    } else if sampleNames.count > 1 {
                        MetricCard(label: "Samples", value: "\(sampleNames.count)")
                    }
                }

                // Top taxa bar chart
                if !topTaxa.isEmpty {
                    Text("Top Taxa by Read Count")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)

                    ForEach(topTaxa, id: \.taxId) { summary in
                        TaxonBarRow(summary: summary, maxCount: maxHitCount)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onTaxonSelected?(summary.taxId)
                            }
                    }
                }
            }
            .padding(12)
        }
    }
}

/// A single bar in the top taxa chart.
private struct TaxonBarRow: View {
    let summary: NaoMgsTaxonSummary
    let maxCount: Int

    private var barFraction: CGFloat {
        guard maxCount > 0 else { return 0 }
        return CGFloat(summary.hitCount) / CGFloat(maxCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(summary.name.isEmpty ? "Taxid \(summary.taxId)" : summary.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(summary.hitCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(lungfishOrange.opacity(0.6))
                    .frame(width: geo.size.width * barFraction)
            }
            .frame(height: 8)
        }
    }
}
