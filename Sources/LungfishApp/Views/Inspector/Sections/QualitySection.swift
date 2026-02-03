// QualitySection.swift - Quality statistics and overlay toggle inspector section
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

/// Quality statistics for a sequence.
///
/// Contains computed metrics for FASTQ quality scores.
public struct QualityStatistics: Sendable {
    /// Mean quality score across all bases
    public let meanQuality: Double

    /// Percentage of bases with quality >= 20
    public let q20Percentage: Double

    /// Percentage of bases with quality >= 30
    public let q30Percentage: Double

    /// Total number of bases analyzed
    public let totalBases: Int

    /// Minimum quality score observed
    public let minQuality: Int

    /// Maximum quality score observed
    public let maxQuality: Int

    public init(
        meanQuality: Double,
        q20Percentage: Double,
        q30Percentage: Double,
        totalBases: Int,
        minQuality: Int,
        maxQuality: Int
    ) {
        self.meanQuality = meanQuality
        self.q20Percentage = q20Percentage
        self.q30Percentage = q30Percentage
        self.totalBases = totalBases
        self.minQuality = minQuality
        self.maxQuality = maxQuality
    }
}

/// View model for the quality section.
///
/// Manages quality overlay visibility and quality statistics display.
@MainActor
public class QualitySectionViewModel: ObservableObject {
    // MARK: - Default Values

    /// Default setting for quality overlay (disabled by default)
    public static let defaultQualityOverlayEnabled: Bool = false

    // MARK: - Published Properties

    /// Whether the quality overlay is enabled
    @Published public var isQualityOverlayEnabled: Bool = defaultQualityOverlayEnabled

    /// Whether quality data is available (false for FASTA files)
    @Published public var hasQualityData: Bool = false

    /// Quality statistics, if available
    @Published public var statistics: QualityStatistics?

    /// Callback when overlay toggle changes
    public var onOverlayToggleChanged: ((Bool) -> Void)?

    public init() {}

    /// Updates the view model with new quality data.
    ///
    /// - Parameters:
    ///   - hasData: Whether quality data is available
    ///   - statistics: Quality statistics if available
    public func update(hasData: Bool, statistics: QualityStatistics?) {
        self.hasQualityData = hasData
        self.statistics = statistics

        // Disable overlay if no quality data
        if !hasData {
            isQualityOverlayEnabled = false
        }
    }

    /// Resets quality overlay settings to their default values.
    ///
    /// Note: This only resets the overlay toggle, not the quality data/statistics
    /// which depend on the loaded file.
    public func resetToDefaults() {
        isQualityOverlayEnabled = Self.defaultQualityOverlayEnabled
        onOverlayToggleChanged?(isQualityOverlayEnabled)
    }
}

// MARK: - QualitySection

/// SwiftUI view for quality statistics and overlay toggle.
///
/// Displays quality metrics when FASTQ data is loaded and provides
/// a toggle to enable/disable quality visualization overlay.
public struct QualitySection: View {
    @ObservedObject var viewModel: QualitySectionViewModel
    @State private var isExpanded = true

    public init(viewModel: QualitySectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if viewModel.hasQualityData {
                qualityContent
            } else {
                noQualityDataView
            }
        } label: {
            Label("Quality", systemImage: "chart.bar.fill")
                .font(.headline)
        }
    }

    // MARK: - Quality Content

    @ViewBuilder
    private var qualityContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Quality overlay toggle
            Toggle(isOn: $viewModel.isQualityOverlayEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d")
                        .foregroundStyle(.secondary)
                    Text("Quality Overlay")
                }
            }
            .toggleStyle(.switch)
            .onChange(of: viewModel.isQualityOverlayEnabled) { _, newValue in
                viewModel.onOverlayToggleChanged?(newValue)
            }

            if let stats = viewModel.statistics {
                Divider()
                    .padding(.vertical, 4)

                statisticsView(stats: stats)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Statistics View

    @ViewBuilder
    private func statisticsView(stats: QualityStatistics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Statistics")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Mean Quality with visual indicator
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mean Quality")
                        .font(.callout)
                    Spacer()
                    Text(String(format: "%.1f", stats.meanQuality))
                        .font(.callout)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                QualityBar(value: stats.meanQuality, maxValue: 40)
                    .frame(height: 6)
            }

            // Q20 percentage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 4) {
                        Text("Q20")
                            .font(.callout)
                        Text("(>= 20)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(String(format: "%.1f%%", stats.q20Percentage))
                        .font(.callout)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                PercentageBar(percentage: stats.q20Percentage, color: .orange)
                    .frame(height: 6)
            }

            // Q30 percentage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 4) {
                        Text("Q30")
                            .font(.callout)
                        Text("(>= 30)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(String(format: "%.1f%%", stats.q30Percentage))
                        .font(.callout)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }

                PercentageBar(percentage: stats.q30Percentage, color: .green)
                    .frame(height: 6)
            }

            Divider()
                .padding(.vertical, 4)

            // Additional stats
            VStack(spacing: 4) {
                LabeledContent("Total Bases") {
                    Text(formatNumber(stats.totalBases))
                        .monospacedDigit()
                }
                LabeledContent("Quality Range") {
                    Text("\(stats.minQuality) - \(stats.maxQuality)")
                        .monospacedDigit()
                }
            }
            .font(.callout)
        }
    }

    // MARK: - No Quality Data View

    @ViewBuilder
    private var noQualityDataView: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No quality data available")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Quality scores are only available for FASTQ files")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Helper Functions

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}

// MARK: - QualityBar

/// A horizontal bar indicating quality level with color gradient.
struct QualityBar: View {
    let value: Double
    let maxValue: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))

                // Filled portion
                RoundedRectangle(cornerRadius: 3)
                    .fill(qualityColor)
                    .frame(width: geometry.size.width * min(value / maxValue, 1.0))
            }
        }
    }

    private var qualityColor: Color {
        let normalized = value / maxValue
        if normalized >= 0.75 {
            return .green
        } else if normalized >= 0.5 {
            return .yellow
        } else if normalized >= 0.25 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - PercentageBar

/// A horizontal bar showing a percentage value.
struct PercentageBar: View {
    let percentage: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))

                // Filled portion
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.8))
                    .frame(width: geometry.size.width * min(percentage / 100.0, 1.0))
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct QualitySection_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                // With quality data
                QualitySection(viewModel: {
                    let vm = QualitySectionViewModel()
                    vm.update(
                        hasData: true,
                        statistics: QualityStatistics(
                            meanQuality: 32.5,
                            q20Percentage: 95.2,
                            q30Percentage: 87.8,
                            totalBases: 1_234_567,
                            minQuality: 2,
                            maxQuality: 40
                        )
                    )
                    return vm
                }())

                Divider()

                // Without quality data (FASTA file)
                QualitySection(viewModel: {
                    let vm = QualitySectionViewModel()
                    vm.update(hasData: false, statistics: nil)
                    return vm
                }())
            }
            .padding()
        }
        .frame(width: 280, height: 600)
    }
}
#endif
