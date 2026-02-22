// ReadStyleSection.swift - Mapped reads style and statistics inspector section
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO

// MARK: - ReadStyleSectionViewModel

/// View model for the mapped reads inspector section.
///
/// Provides both display controls (height, colors, toggles) and summary statistics
/// loaded from the AlignmentMetadataDatabase at bundle open time.
@Observable
@MainActor
public final class ReadStyleSectionViewModel {

    // MARK: - Display Settings

    /// Maximum number of read rows to display before overflow.
    public var maxReadRows: Double = 75

    /// Whether to highlight mismatches relative to the reference.
    public var showMismatches: Bool = true

    /// Whether to show soft-clipped regions at reduced opacity.
    public var showSoftClips: Bool = true

    /// Whether to show insertion/deletion markers.
    public var showIndels: Bool = true

    /// Minimum mapping quality filter (reads below this are hidden).
    public var minMapQ: Double = 0

    /// Whether reads are currently visible in the viewer.
    public var showReads: Bool = true

    /// Forward strand display color.
    public var forwardReadColor: Color = Color(red: 0.69, green: 0.77, blue: 0.87)

    /// Reverse strand display color.
    public var reverseReadColor: Color = Color(red: 0.87, green: 0.69, blue: 0.69)

    // MARK: - Alignment Statistics

    /// Whether alignment tracks are present in the current bundle.
    public var hasAlignmentTracks: Bool = false

    /// Total mapped reads across all chromosomes.
    public var totalMappedReads: Int64 = 0

    /// Total unmapped reads.
    public var totalUnmappedReads: Int64 = 0

    /// Per-chromosome read statistics.
    public var chromosomeStats: [ChromosomeReadStat] = []

    /// Flag statistics from samtools flagstat.
    public var flagStats: [FlagStatEntry] = []

    /// Read group records from BAM header.
    public var readGroups: [ReadGroupEntry] = []

    /// File-level metadata key-value pairs.
    public var fileInfo: [(key: String, value: String)] = []

    /// Alignment track names.
    public var trackNames: [String] = []

    // MARK: - Selected Read Detail

    /// The currently selected read (set via notification from viewer).
    public var selectedRead: AlignedRead?

    /// Whether a read is currently selected.
    public var hasSelectedRead: Bool { selectedRead != nil }

    // MARK: - Callbacks

    /// Called when display settings change; viewer should redraw.
    public var onSettingsChanged: (() -> Void)?

    // MARK: - Methods

    /// Clears all statistics (called when bundle is unloaded).
    public func clear() {
        hasAlignmentTracks = false
        totalMappedReads = 0
        totalUnmappedReads = 0
        chromosomeStats = []
        flagStats = []
        readGroups = []
        fileInfo = []
        trackNames = []
    }

    /// Loads alignment statistics from bundle's metadata databases.
    public func loadStatistics(from bundle: ReferenceBundle) {
        let trackIds = bundle.alignmentTrackIds
        guard !trackIds.isEmpty else {
            clear()
            return
        }

        hasAlignmentTracks = true
        trackNames = trackIds.compactMap { bundle.alignmentTrack(id: $0)?.name }

        var aggMapped: Int64 = 0
        var aggUnmapped: Int64 = 0
        var chromStatsList: [ChromosomeReadStat] = []
        var flagStatsList: [FlagStatEntry] = []
        var readGroupList: [ReadGroupEntry] = []
        var infoList: [(key: String, value: String)] = []

        for trackId in trackIds {
            guard let trackInfo = bundle.alignmentTrack(id: trackId),
                  let dbRelPath = trackInfo.metadataDBPath else { continue }
            let dbURL = bundle.url.appendingPathComponent(dbRelPath)
            guard let db = try? AlignmentMetadataDatabase(url: dbURL) else { continue }

            // Chromosome stats
            for stat in db.chromosomeStats() {
                aggMapped += stat.mappedReads
                aggUnmapped += stat.unmappedReads
                chromStatsList.append(ChromosomeReadStat(
                    chromosome: stat.chromosome,
                    length: stat.length,
                    mappedReads: stat.mappedReads,
                    unmappedReads: stat.unmappedReads
                ))
            }

            // Flag stats
            for fs in db.flagStats() {
                flagStatsList.append(FlagStatEntry(
                    category: fs.category,
                    qcPass: fs.qcPass,
                    qcFail: fs.qcFail
                ))
            }

            // Read groups
            for rg in db.readGroups() {
                readGroupList.append(ReadGroupEntry(
                    id: rg.id,
                    sample: rg.sample,
                    library: rg.library,
                    platform: rg.platform
                ))
            }

            // File info
            for (key, value) in db.allFileInfo().sorted(by: { $0.key < $1.key }) {
                infoList.append((key: key, value: value))
            }
        }

        totalMappedReads = aggMapped
        totalUnmappedReads = aggUnmapped
        chromosomeStats = chromStatsList
        flagStats = flagStatsList
        readGroups = readGroupList
        fileInfo = infoList
    }
}

// MARK: - Supporting Types

/// Per-chromosome read statistics for display.
public struct ChromosomeReadStat: Identifiable {
    public var id: String { chromosome }
    public let chromosome: String
    public let length: Int64
    public let mappedReads: Int64
    public let unmappedReads: Int64

    /// Approximate coverage depth (mapped reads × avg read length / chrom length).
    /// Uses 150 bp assumed read length when unknown.
    public var estimatedCoverage: Double {
        guard length > 0 else { return 0 }
        return Double(mappedReads) * 150.0 / Double(length)
    }
}

/// Flag statistics entry for display.
public struct FlagStatEntry: Identifiable {
    public var id: String { category }
    public let category: String
    public let qcPass: Int64
    public let qcFail: Int64
}

/// Read group entry for display.
public struct ReadGroupEntry: Identifiable {
    public var id: String { rgId }
    let rgId: String
    public let sample: String?
    public let library: String?
    public let platform: String?

    init(id: String, sample: String?, library: String?, platform: String?) {
        self.rgId = id
        self.sample = sample
        self.library = library
        self.platform = platform
    }
}

// MARK: - ReadStyleSection View

/// Inspector section for alignment track settings and statistics.
///
/// Shows:
/// - Summary statistics (total reads, mapped %, chromosomes)
/// - Display controls (max rows, mismatch toggle, MAPQ filter, colors)
/// - Read group information (sample, library, platform)
/// - Flag statistics (from samtools flagstat)
/// - Per-chromosome statistics
public struct ReadStyleSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel
    @State private var isStyleExpanded = true
    @State private var isStatsExpanded = true
    @State private var isReadGroupsExpanded = false
    @State private var isFlagStatsExpanded = false
    @State private var isChromStatsExpanded = false

    public init(viewModel: ReadStyleSectionViewModel) {
        self.viewModel = viewModel
    }

    @State private var isReadDetailExpanded = true

    public var body: some View {
        if viewModel.hasAlignmentTracks {
            // Selected read detail
            if let read = viewModel.selectedRead {
                DisclosureGroup(isExpanded: $isReadDetailExpanded) {
                    selectedReadDetail(read)
                        .padding(.top, 4)
                } label: {
                    Label("Selected Read", systemImage: "line.horizontal.3")
                        .font(.headline)
                }

                Divider()
            }

            // Summary statistics
            DisclosureGroup(isExpanded: $isStatsExpanded) {
                alignmentSummary
                    .padding(.top, 4)
            } label: {
                Label("Alignment Summary", systemImage: "chart.bar")
                    .font(.headline)
            }

            Divider()

            // Display controls
            DisclosureGroup(isExpanded: $isStyleExpanded) {
                displayControls
                    .padding(.top, 4)
            } label: {
                Label("Read Display", systemImage: "paintbrush")
                    .font(.headline)
            }

            // Read groups (if any)
            if !viewModel.readGroups.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $isReadGroupsExpanded) {
                    readGroupsSection
                        .padding(.top, 4)
                } label: {
                    Label("Read Groups (\(viewModel.readGroups.count))", systemImage: "person.2")
                        .font(.headline)
                }
            }

            // Flag statistics (if any)
            if !viewModel.flagStats.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $isFlagStatsExpanded) {
                    flagStatsSection
                        .padding(.top, 4)
                } label: {
                    Label("Flag Statistics", systemImage: "flag")
                        .font(.headline)
                }
            }

            // Per-chromosome stats
            if viewModel.chromosomeStats.count > 1 {
                Divider()
                DisclosureGroup(isExpanded: $isChromStatsExpanded) {
                    chromosomeStatsSection
                        .padding(.top, 4)
                } label: {
                    Label("Per-Chromosome (\(viewModel.chromosomeStats.count))", systemImage: "list.number")
                        .font(.headline)
                }
            }
        } else {
            DisclosureGroup(isExpanded: $isStyleExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No alignment tracks loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Import a BAM or CRAM file via File > Import BAM/CRAM Alignments.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            } label: {
                Label("Alignment", systemImage: "chart.bar")
                    .font(.headline)
            }
        }
    }

    // MARK: - Summary Statistics

    @ViewBuilder
    private var alignmentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Track names
            if !viewModel.trackNames.isEmpty {
                ForEach(viewModel.trackNames, id: \.self) { name in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Divider()

            // Key numbers
            statRow("Total Mapped", value: formatCount(viewModel.totalMappedReads))
            statRow("Total Unmapped", value: formatCount(viewModel.totalUnmappedReads))

            if viewModel.totalMappedReads + viewModel.totalUnmappedReads > 0 {
                let total = viewModel.totalMappedReads + viewModel.totalUnmappedReads
                let pct = Double(viewModel.totalMappedReads) / Double(total) * 100
                statRow("Mapped %", value: String(format: "%.1f%%", pct))

                // Mapping rate bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 6)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Rectangle()
                            .fill(Color.green)
                            .frame(width: geometry.size.width * CGFloat(pct / 100), height: 6)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .frame(height: 6)
            }

            statRow("Chromosomes", value: "\(viewModel.chromosomeStats.count)")

            // Estimated mean coverage (if single chromosome)
            if viewModel.chromosomeStats.count == 1, let stat = viewModel.chromosomeStats.first {
                statRow("Est. Coverage", value: String(format: "%.1fx", stat.estimatedCoverage))
            }
        }
    }

    // MARK: - Display Controls

    @ViewBuilder
    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show Reads", isOn: $viewModel.showReads)
                .onChange(of: viewModel.showReads) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Divider()

            HStack {
                Text("Max Rows")
                Spacer()
                Text("\(Int(viewModel.maxReadRows))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $viewModel.maxReadRows, in: 10...200, step: 5)
                .onChange(of: viewModel.maxReadRows) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            HStack {
                Text("Min MAPQ")
                Spacer()
                Text("\(Int(viewModel.minMapQ))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $viewModel.minMapQ, in: 0...60, step: 1)
                .onChange(of: viewModel.minMapQ) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Divider()

            Toggle("Show Mismatches", isOn: $viewModel.showMismatches)
                .onChange(of: viewModel.showMismatches) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Show Soft Clips", isOn: $viewModel.showSoftClips)
                .onChange(of: viewModel.showSoftClips) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Show Insertions/Deletions", isOn: $viewModel.showIndels)
                .onChange(of: viewModel.showIndels) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Divider()

            HStack {
                Text("Forward")
                Spacer()
                ColorPicker("", selection: $viewModel.forwardReadColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: viewModel.forwardReadColor) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
            }

            HStack {
                Text("Reverse")
                Spacer()
                ColorPicker("", selection: $viewModel.reverseReadColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: viewModel.reverseReadColor) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
            }
        }
    }

    // MARK: - Read Groups

    @ViewBuilder
    private var readGroupsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.readGroups) { rg in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rg.rgId)
                        .font(.system(.caption, design: .monospaced).bold())
                    if let sample = rg.sample {
                        inlineField("Sample", value: sample)
                    }
                    if let library = rg.library {
                        inlineField("Library", value: library)
                    }
                    if let platform = rg.platform {
                        inlineField("Platform", value: platform)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Flag Statistics

    @ViewBuilder
    private var flagStatsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.flagStats) { stat in
                HStack {
                    Text(stat.category)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(formatCount(stat.qcPass))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                    if stat.qcFail > 0 {
                        Text("(\(formatCount(stat.qcFail)) fail)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    // MARK: - Per-Chromosome Statistics

    @ViewBuilder
    private var chromosomeStatsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.chromosomeStats) { stat in
                HStack {
                    Text(stat.chromosome)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .frame(width: 80, alignment: .leading)
                    Spacer()
                    Text(formatCount(stat.mappedReads))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 60, alignment: .trailing)
                    Text("reads")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Selected Read Detail

    @ViewBuilder
    private func selectedReadDetail(_ read: AlignedRead) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name
            Text(read.name)
                .font(.system(.caption, design: .monospaced).bold())
                .textSelection(.enabled)
                .lineLimit(2)

            Divider()

            // Position & Strand
            statRow("Position", value: "\(read.chromosome):\(read.position + 1)-\(read.alignmentEnd)")
            statRow("Strand", value: read.isReverse ? "Reverse (-)" : "Forward (+)")
            statRow("Length", value: "\(read.referenceLength) bp")
            statRow("MAPQ", value: "\(read.mapq)")

            // CIGAR
            let cigar = read.cigarString
            statRow("CIGAR", value: String(cigar.prefix(50)) + (cigar.count > 50 ? "..." : ""))

            Divider()

            // Flags
            HStack(spacing: 4) {
                flagBadge("Paired", active: read.isPaired)
                flagBadge("Proper", active: read.isProperPair)
                flagBadge("Rev", active: read.isReverse)
                flagBadge("Dup", active: read.isDuplicate)
            }

            HStack(spacing: 4) {
                flagBadge("1st", active: read.isFirstInPair)
                flagBadge("2nd", active: read.isSecondInPair)
                flagBadge("Sec", active: read.isSecondary)
                flagBadge("Sup", active: read.isSupplementary)
            }

            // Mate info
            if read.isPaired {
                Divider()
                if let mateChr = read.mateChromosome, let matePos = read.matePosition {
                    statRow("Mate", value: "\(mateChr):\(matePos + 1)")
                } else {
                    statRow("Mate", value: "Unmapped")
                }
                if read.insertSize != 0 {
                    statRow("Insert Size", value: "\(read.insertSize)")
                }
            }

            // Read group
            if let rg = read.readGroup {
                statRow("Read Group", value: rg)
            }

            // Quality scores summary
            if !read.qualities.isEmpty {
                let meanQ = Double(read.qualities.reduce(0, { $0 + Int($1) })) / Double(read.qualities.count)
                let minQ = read.qualities.min() ?? 0
                let maxQ = read.qualities.max() ?? 0
                Divider()
                Text("Base Quality")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statRow("Mean Q", value: String(format: "%.1f", meanQ))
                statRow("Range", value: "Q\(minQ)-Q\(maxQ)")
                let q20Count = read.qualities.filter { $0 >= 20 }.count
                let q20Pct = Double(q20Count) / Double(read.qualities.count) * 100
                statRow(">= Q20", value: String(format: "%.1f%%", q20Pct))
            }

            // Insertions
            let ins = read.insertions
            if !ins.isEmpty {
                Divider()
                Text("Insertions (\(ins.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(ins.prefix(5).enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text("pos \(item.position + 1)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.bases.prefix(20) + (item.bases.count > 20 ? "..." : ""))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.purple)
                    }
                }
                if ins.count > 5 {
                    Text("... and \(ins.count - 5) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func flagBadge(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 9))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(active ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
            .foregroundStyle(active ? .primary : .tertiary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }

    @ViewBuilder
    private func inlineField(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2)
                .textSelection(.enabled)
        }
    }

    private func formatCount(_ count: Int64) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
