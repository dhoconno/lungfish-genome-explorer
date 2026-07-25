// NaoMgsChartViews.swift - SwiftUI overview chart for NAO-MGS results
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO
import LungfishKit

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

@MainActor
struct NaoMgsOverviewTypography {
    let model: ContentTypographyModel

    static let taxonLabelPointSize: CGFloat = 10
    static let taxonCountPointSize: CGFloat = 10
    static let taxonBarHeight: CGFloat = 8

    func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(
            size: model.scaledPointSize(fromCanonicalPointSize: size),
            weight: weight,
            design: design
        )
    }

#if DEBUG
    struct TestingMetrics: Equatable {
        let metricLabelPointSize: CGFloat
        let metricValuePointSize: CGFloat
        let titlePointSize: CGFloat
        let explanationPointSize: CGFloat
        let sectionPointSize: CGFloat
        let taxonLabelPointSize: CGFloat
        let taxonCountPointSize: CGFloat
        let taxonBarHeight: CGFloat
    }

    struct TestingQuickStatsLayout: Equatable {
        let columnCount: Int
        let itemWidth: CGFloat
    }

    static func testingMetrics(model: ContentTypographyModel) -> TestingMetrics {
        TestingMetrics(
            metricLabelPointSize: model.scaledPointSize(fromCanonicalPointSize: 9),
            metricValuePointSize: model.scaledPointSize(fromCanonicalPointSize: 13),
            titlePointSize: model.scaledPointSize(fromCanonicalPointSize: 14),
            explanationPointSize: model.scaledPointSize(fromCanonicalPointSize: 11),
            sectionPointSize: model.scaledPointSize(fromCanonicalPointSize: 11),
            taxonLabelPointSize: taxonLabelPointSize,
            taxonCountPointSize: taxonCountPointSize,
            taxonBarHeight: taxonBarHeight
        )
    }

    static func testingQuickStatsLayout(
        availableWidth: CGFloat
    ) -> TestingQuickStatsLayout {
        let minimumItemWidth: CGFloat = 120
        let spacing: CGFloat = 8
        let columnCount = max(
            1,
            Int(floor((availableWidth + spacing) / (minimumItemWidth + spacing)))
        )
        return TestingQuickStatsLayout(
            columnCount: columnCount,
            itemWidth: (
                availableWidth - CGFloat(columnCount - 1) * spacing
            ) / CGFloat(columnCount)
        )
    }
#endif
}

struct NaoMgsTaxonBarPresentation {
    let accessibilityLabel: String
    let accessibilityValue: String

    init(summary: NaoMgsTaxonSummary) {
        accessibilityLabel = summary.name.isEmpty
            ? "Taxid \(summary.taxId)"
            : summary.name
        let count = NumberFormatter.localizedString(
            from: NSNumber(value: summary.hitCount),
            number: .decimal
        )
        accessibilityValue = "\(count) reads"
    }
}

/// A compact metric card used in the NAO-MGS overview's quick-stats row.
private struct MetricCard: View {
    let label: String
    let value: String
    let typography: NaoMgsOverviewTypography

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(typography.font(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(typography.font(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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

    @State private var typographyModel: ContentTypographyModel

    init(
        taxonSummaries: [NaoMgsTaxonSummary],
        totalHitReads: Int,
        sampleNames: [String],
        typographyModel: ContentTypographyModel = .shared,
        onTaxonSelected: ((Int) -> Void)? = nil
    ) {
        self.taxonSummaries = taxonSummaries
        self.totalHitReads = totalHitReads
        self.sampleNames = sampleNames
        self.onTaxonSelected = onTaxonSelected
        _typographyModel = State(initialValue: typographyModel)
    }

    private var typography: NaoMgsOverviewTypography {
        NaoMgsOverviewTypography(model: typographyModel)
    }

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
                        .font(typography.font(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Select a taxon in the table to view metrics and read evidence.")
                        .font(typography.font(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Quick stats
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 120), spacing: 8),
                    ],
                    spacing: 8
                ) {
                    MetricCard(
                        label: "Total Hits",
                        value: naoMgsFormatReadCount(totalHitReads),
                        typography: typography
                    )
                    MetricCard(
                        label: "Unique Taxa",
                        value: "\(taxonSummaries.count)",
                        typography: typography
                    )
                    if sampleNames.count == 1 {
                        MetricCard(
                            label: "Sample",
                            value: sampleNames[0],
                            typography: typography
                        )
                    } else if sampleNames.count > 1 {
                        MetricCard(
                            label: "Samples",
                            value: "\(sampleNames.count)",
                            typography: typography
                        )
                    }
                }

                // Top taxa bar chart
                if !topTaxa.isEmpty {
                    Text("Top Taxa by Read Count")
                        .font(typography.font(size: 11, weight: .semibold))
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
        let presentation = NaoMgsTaxonBarPresentation(summary: summary)
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(summary.name.isEmpty ? "Taxid \(summary.taxId)" : summary.name)
                    .font(.system(size: NaoMgsOverviewTypography.taxonLabelPointSize))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(summary.hitCount)")
                    .font(.system(
                        size: NaoMgsOverviewTypography.taxonCountPointSize,
                        design: .monospaced
                    ))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(lungfishOrange.opacity(0.6))
                    .frame(width: geo.size.width * barFraction)
            }
            .frame(height: NaoMgsOverviewTypography.taxonBarHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
    }
}
