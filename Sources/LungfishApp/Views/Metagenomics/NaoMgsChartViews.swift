// NaoMgsChartViews.swift - SwiftUI chart views for NAO-MGS result detail pane
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishIO

// MARK: - Lungfish Orange

/// Lungfish brand accent color — uses the shared adaptive definition.
private let lungfishOrange = Color.lungfishOrangeFallback

// MARK: - CoveragePlotView

/// A coverage depth sparkline rendered as an area chart.
///
/// Displays windowed coverage data for a single accession's reads against
/// a reference genome. The X axis represents genome position (0% to 100%),
/// and the Y axis represents read depth at each window.
///
/// ## Rendering
///
/// The chart uses Canvas for GPU-accelerated drawing. The area fill uses
/// Lungfish Orange (#D47B3A) at 35% opacity, with a solid stroke on top.
/// Peak coverage is annotated with a dot and label.
///
/// ## Usage
///
/// ```swift
/// CoveragePlotView(
///     coverageWindows: [0, 2, 5, 12, 8, 3, 1, 0],
///     referenceLength: 29903,
///     accession: "NC_045512.2"
/// )
/// ```
struct CoveragePlotView: View {

    /// Per-window coverage depth values.
    let coverageWindows: [Int]

    /// Estimated reference genome length in bases.
    let referenceLength: Int

    /// GenBank accession identifier for the label.
    let accession: String

    /// Maximum coverage depth (computed from windows).
    private var maxCoverage: Int {
        coverageWindows.max() ?? 0
    }

    /// Fraction of windows with non-zero coverage.
    private var coverageFraction: Double {
        guard !coverageWindows.isEmpty else { return 0 }
        let covered = coverageWindows.filter { $0 > 0 }.count
        return Double(covered) / Double(coverageWindows.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header with accession and stats
            HStack {
                Text(accession)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                Spacer()

                Text("\(formatBases(referenceLength)) | \(String(format: "%.1f%%", coverageFraction * 100)) covered | peak \(maxCoverage)x")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Area chart
            Canvas { context, size in
                guard !coverageWindows.isEmpty, maxCoverage > 0 else { return }

                let windowCount = CGFloat(coverageWindows.count)
                let windowWidth = size.width / windowCount
                let yScale = (size.height - 2) / CGFloat(maxCoverage)

                // Build the filled area path
                var fillPath = Path()
                fillPath.move(to: CGPoint(x: 0, y: size.height))

                for (i, depth) in coverageWindows.enumerated() {
                    let x = CGFloat(i) * windowWidth
                    let y = size.height - CGFloat(depth) * yScale
                    fillPath.addLine(to: CGPoint(x: x, y: y))
                    fillPath.addLine(to: CGPoint(x: x + windowWidth, y: y))
                }

                fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
                fillPath.closeSubpath()

                // Fill with Lungfish Orange at 35% opacity
                context.fill(fillPath, with: .color(lungfishOrange.opacity(0.35)))

                // Stroke the top edge
                var strokePath = Path()
                for (i, depth) in coverageWindows.enumerated() {
                    let x = CGFloat(i) * windowWidth
                    let y = size.height - CGFloat(depth) * yScale
                    if i == 0 {
                        strokePath.move(to: CGPoint(x: x, y: y))
                    } else {
                        strokePath.addLine(to: CGPoint(x: x, y: y))
                    }
                    strokePath.addLine(to: CGPoint(x: x + windowWidth, y: y))
                }
                context.stroke(strokePath, with: .color(lungfishOrange.opacity(0.8)), lineWidth: 1)

                // Peak indicator dot
                if let peakIndex = coverageWindows.firstIndex(of: maxCoverage) {
                    let peakX = CGFloat(peakIndex) * windowWidth + windowWidth / 2
                    let peakY = size.height - CGFloat(maxCoverage) * yScale
                    let dotRect = CGRect(x: peakX - 2, y: peakY - 2, width: 4, height: 4)
                    context.fill(Path(ellipseIn: dotRect), with: .color(lungfishOrange))
                }
            }
            .frame(height: 48)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coverage plot for \(accession), \(String(format: "%.1f", coverageFraction * 100)) percent covered, peak depth \(maxCoverage)")
    }

    /// Formats a base count with bp/Kb/Mb suffixes.
    private func formatBases(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.2f Mb", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1f Kb", Double(count) / 1_000) }
        return "\(count) bp"
    }
}

// MARK: - EditDistanceHistogramView

/// A bar chart showing the distribution of edit distances for a taxon's reads.
///
/// Each bar represents a single edit distance value (0, 1, 2, ...) with its
/// height proportional to the number of reads with that distance. Bars are
/// colored with Lungfish Orange, with the modal (most common) bar highlighted.
///
/// ## Biologist Context
///
/// Low edit distances (0-2) indicate high-quality alignments with few mismatches.
/// A distribution skewed toward higher values may indicate poor-quality matches
/// or divergent sequences that warrant BLAST verification.
struct EditDistanceHistogramView: View {

    /// Distribution data as (editDistance, count) pairs sorted ascending.
    let distribution: [(distance: Int, count: Int)]

    /// Title shown above the chart.
    var title: String = "Edit Distance Distribution"

    /// Maximum bar count for Y-axis scaling.
    private var maxCount: Int {
        distribution.map(\.count).max() ?? 1
    }

    /// Total reads across all bins.
    private var totalReads: Int {
        distribution.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(totalReads) reads")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if distribution.isEmpty {
                Text("No edit distance data available")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(height: 48)
            } else {
                Canvas { context, size in
                    let barCount = CGFloat(distribution.count)
                    let barSpacing: CGFloat = 1
                    let barWidth = max((size.width - barSpacing * (barCount - 1)) / barCount, 2)
                    let yScale = CGFloat(maxCount) > 0 ? (size.height - 14) / CGFloat(maxCount) : 0

                    for (i, entry) in distribution.enumerated() {
                        let x = CGFloat(i) * (barWidth + barSpacing)
                        let barHeight = CGFloat(entry.count) * yScale
                        let y = size.height - 14 - barHeight

                        // Bar fill
                        let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                        let isModal = entry.count == maxCount
                        let fillColor = isModal ? lungfishOrange : lungfishOrange.opacity(0.6)
                        context.fill(Path(roundedRect: barRect, cornerRadius: 1), with: .color(fillColor))

                        // X-axis label (every other bar when many bars, or all if few)
                        let showLabel = distribution.count <= 10 || i % 2 == 0
                        if showLabel {
                            let labelText = Text("\(entry.distance)")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            context.draw(
                                context.resolve(labelText),
                                at: CGPoint(x: x + barWidth / 2, y: size.height - 4),
                                anchor: .center
                            )
                        }
                    }
                }
                .frame(height: 64)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Edit distance histogram, \(distribution.count) bins, \(totalReads) total reads")
    }
}

// MARK: - FragmentLengthDistributionView

/// A bar chart showing the distribution of fragment (insert) lengths.
///
/// Fragment length is the distance between paired-end read mates. The
/// distribution shape reveals library preparation quality:
/// - Sharp unimodal peak: good library prep
/// - Broad or multimodal: possible contamination or degraded DNA
/// - Short fragments (< 150 bp): adapter read-through
///
/// Bins fragment lengths into ranges for display clarity when the raw
/// distribution has many distinct values.
struct FragmentLengthDistributionView: View {

    /// Raw distribution data as (fragmentLength, count) pairs sorted ascending.
    let distribution: [(length: Int, count: Int)]

    /// Title shown above the chart.
    var title: String = "Fragment Length Distribution"

    /// Number of histogram bins to use.
    var binCount: Int = 30

    /// Binned distribution for rendering.
    private var binnedData: [(binCenter: Int, count: Int)] {
        guard !distribution.isEmpty else { return [] }

        let minLen = distribution.first!.length
        let maxLen = distribution.last!.length
        let range = max(maxLen - minLen, 1)
        let effectiveBinCount = min(binCount, distribution.count)
        let binSize = max(range / effectiveBinCount, 1)

        var bins: [Int: Int] = [:]
        for entry in distribution {
            let binIndex = (entry.length - minLen) / binSize
            let binCenter = minLen + binIndex * binSize + binSize / 2
            bins[binCenter, default: 0] += entry.count
        }

        return bins.sorted { $0.key < $1.key }.map { (binCenter: $0.key, count: $0.value) }
    }

    /// Maximum bin count for Y-axis scaling.
    private var maxCount: Int {
        binnedData.map(\.count).max() ?? 1
    }

    /// Total reads across all bins.
    private var totalReads: Int {
        distribution.reduce(0) { $0 + $1.count }
    }

    /// Median fragment length.
    private var medianLength: Int {
        guard !distribution.isEmpty else { return 0 }
        // Expand to individual values for proper median
        var allLengths: [Int] = []
        for entry in distribution {
            allLengths.append(contentsOf: [Int](repeating: entry.length, count: entry.count))
        }
        allLengths.sort()
        return allLengths[allLengths.count / 2]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if totalReads > 0 {
                    Text("median \(medianLength) bp | \(totalReads) reads")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if binnedData.isEmpty {
                Text("No fragment length data available")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(height: 48)
            } else {
                Canvas { context, size in
                    let barCount = CGFloat(binnedData.count)
                    let barSpacing: CGFloat = 1
                    let barWidth = max((size.width - barSpacing * (barCount - 1)) / barCount, 2)
                    let yScale = CGFloat(maxCount) > 0 ? (size.height - 14) / CGFloat(maxCount) : 0

                    for (i, entry) in binnedData.enumerated() {
                        let x = CGFloat(i) * (barWidth + barSpacing)
                        let barHeight = CGFloat(entry.count) * yScale
                        let y = size.height - 14 - barHeight

                        let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                        context.fill(
                            Path(roundedRect: barRect, cornerRadius: 1),
                            with: .color(lungfishOrange.opacity(0.6))
                        )

                        // X-axis labels at edges and center
                        if i == 0 || i == binnedData.count - 1 || i == binnedData.count / 2 {
                            let labelText = Text("\(entry.binCenter)")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                            context.draw(
                                context.resolve(labelText),
                                at: CGPoint(x: x + barWidth / 2, y: size.height - 4),
                                anchor: .center
                            )
                        }
                    }

                    // Draw median indicator line
                    if let minBin = binnedData.first?.binCenter,
                       let maxBin = binnedData.last?.binCenter,
                       maxBin > minBin {
                        let medFrac = CGFloat(medianLength - minBin) / CGFloat(maxBin - minBin)
                        let medX = medFrac * size.width
                        var medLine = Path()
                        medLine.move(to: CGPoint(x: medX, y: 0))
                        medLine.addLine(to: CGPoint(x: medX, y: size.height - 14))
                        context.stroke(medLine, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .frame(height: 64)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fragment length distribution, median \(medianLength) base pairs, \(totalReads) reads")
    }
}

// MARK: - AccessionListView

/// A scrollable list of GenBank accessions with read counts and coverage sparklines.
///
/// Each row shows the accession identifier, read count, estimated reference
/// length, and a mini coverage sparkline. Clicking a row selects it and
/// triggers the ``onAccessionSelected`` callback for pileup display.
struct AccessionListView: View {

    /// Accession summaries to display, sorted by read count descending.
    let accessions: [NaoMgsAccessionSummary]

    /// Currently selected accession, if any.
    @Binding var selectedAccession: String?

    /// Called when an accession is double-clicked (for pileup view).
    var onAccessionDoubleClicked: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Reference Accessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(accessions.count) accessions")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(accessions, id: \.accession) { summary in
                        AccessionRow(
                            summary: summary,
                            isSelected: selectedAccession == summary.accession
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedAccession = summary.accession
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }
}

/// A single row in the accession list showing read count and coverage.
private struct AccessionRow: View {

    let summary: NaoMgsAccessionSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(summary.accession)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)

            Spacer()

            // Mini coverage sparkline
            MiniSparkline(values: summary.coverageWindows)
                .frame(width: 60, height: 14)

            Text("\(String(format: "%.0f%%", summary.coverageFraction * 100))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

            Text(naoMgsFormatReadCount(summary.readCount))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isSelected ? lungfishOrange.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// Formats a read count with K/M suffixes for display in accession rows.
///
/// Module-level free function to avoid `@MainActor` isolation issues in
/// `@Sendable` closures (see project memory: "Free Functions vs Instance Methods").
private func naoMgsFormatReadCount(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return "\(count)"
}

/// A tiny sparkline for the accession list rows.
private struct MiniSparkline: View {
    let values: [Int]

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let maxVal = CGFloat(values.max() ?? 1)
            guard maxVal > 0 else { return }

            let barWidth = size.width / CGFloat(values.count)

            for (i, val) in values.enumerated() {
                let x = CGFloat(i) * barWidth
                let barHeight = CGFloat(val) / maxVal * size.height
                let y = size.height - barHeight
                let rect = CGRect(x: x, y: y, width: max(barWidth - 0.5, 0.5), height: barHeight)
                context.fill(Path(rect), with: .color(lungfishOrange.opacity(val > 0 ? 0.5 : 0.05)))
            }
        }
    }
}

// MARK: - NaoMgsDetailPaneView

/// The complete detail pane for a selected taxon in the NAO-MGS result viewer.
///
/// Combines coverage plots, edit distance histogram, fragment length distribution,
/// and accession list into a scrollable detail view. This SwiftUI view is hosted
/// inside the AppKit split view via ``NSHostingView``.
struct NaoMgsDetailPaneView: View {

    /// The selected taxon summary.
    let taxonSummary: NaoMgsTaxonSummary

    /// All hits for this taxon (for computing distributions).
    let hits: [NaoMgsVirusHit]

    /// Accession summaries with coverage data.
    let accessionSummaries: [NaoMgsAccessionSummary]

    /// Edit distance distribution data.
    let editDistanceData: [(distance: Int, count: Int)]

    /// Fragment length distribution data.
    let fragmentLengthData: [(length: Int, count: Int)]

    /// Currently selected accession in the list.
    @Binding var selectedAccession: String?

    /// Called when an accession is double-clicked.
    var onAccessionDoubleClicked: ((String) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Taxon header
                VStack(alignment: .leading, spacing: 2) {
                    Text(taxonSummary.name.isEmpty ? "Taxid \(taxonSummary.taxId)" : taxonSummary.name)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    HStack(spacing: 12) {
                        Label("Taxid: \(taxonSummary.taxId)", systemImage: "tag")
                        Label("\(taxonSummary.hitCount) reads", systemImage: "waveform.path")
                        Label("\(taxonSummary.accessions.count) accessions", systemImage: "doc.on.doc")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }

                Divider()

                // Key metrics row
                HStack(spacing: 16) {
                    MetricCard(label: "Avg Identity", value: String(format: "%.1f%%", taxonSummary.avgIdentity))
                    MetricCard(label: "Avg Bit Score", value: String(format: "%.0f", taxonSummary.avgBitScore))
                    MetricCard(label: "Avg Edit Dist", value: String(format: "%.1f", taxonSummary.avgEditDistance))
                }

                // Coverage plots for top accessions (up to 5)
                let topAccessions = Array(accessionSummaries.prefix(5))
                if !topAccessions.isEmpty {
                    Text("Coverage by Reference")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)

                    ForEach(topAccessions, id: \.accession) { summary in
                        CoveragePlotView(
                            coverageWindows: summary.coverageWindows,
                            referenceLength: summary.referenceLength,
                            accession: summary.accession
                        )
                    }
                }

                // Histograms side by side
                HStack(alignment: .top, spacing: 12) {
                    EditDistanceHistogramView(distribution: editDistanceData)
                        .frame(maxWidth: .infinity)

                    FragmentLengthDistributionView(distribution: fragmentLengthData)
                        .frame(maxWidth: .infinity)
                }

                // Accession list
                AccessionListView(
                    accessions: accessionSummaries,
                    selectedAccession: $selectedAccession,
                    onAccessionDoubleClicked: onAccessionDoubleClicked
                )
            }
            .padding(12)
        }
    }
}

/// A compact metric card used in the detail pane's key metrics row.
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

    /// All taxon summaries sorted by hit count.
    let taxonSummaries: [NaoMgsTaxonSummary]

    /// Total hit reads.
    let totalHitReads: Int

    /// Sample name.
    let sampleName: String

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
                    Text("Select a taxon in the table to view detailed coverage and statistics.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Quick stats
                HStack(spacing: 16) {
                    MetricCard(label: "Total Hits", value: naoMgsFormatReadCount(totalHitReads))
                    MetricCard(label: "Unique Taxa", value: "\(taxonSummaries.count)")
                    MetricCard(label: "Sample", value: sampleName)
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
