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

    /// Whether to enforce `maxReadRows`; off means all rows are retained.
    public var limitReadRows: Bool = false

    /// Whether to render read rows in compact vertical mode.
    public var verticallyCompressContig: Bool = true

    /// When true, matches are shown as dots and mismatches as colored letters (default).
    /// When false, all bases are shown as letters (matches in gray, mismatches in color).
    /// Mismatches (SNPs) are always displayed regardless of this setting.
    public var showMismatches: Bool = true

    /// Whether to show soft-clipped regions at reduced opacity.
    public var showSoftClips: Bool = true

    /// Whether to show insertion/deletion markers.
    public var showIndels: Bool = true

    /// Whether to apply consensus-style masking for sites with mostly gaps.
    public var consensusMaskingEnabled: Bool = false

    /// Hide columns where gaps exceed this percentage among spanning reads.
    public var consensusGapThresholdPercent: Double = 90

    /// Minimum depth required before a consensus base is emitted.
    public var consensusMinDepth: Double = 8

    /// Minimum spanning depth required before high-gap masking is applied.
    public var consensusMaskingMinDepth: Double = 8

    /// Minimum mapping quality used by consensus/depth calculations.
    public var consensusMinMapQ: Double = 0

    /// Minimum base quality used by consensus/depth calculations.
    public var consensusMinBaseQ: Double = 0

    /// Whether to show consensus sequence beneath the coverage graph.
    public var showConsensusTrack: Bool = true

    /// Consensus caller mode.
    public var consensusMode: AlignmentConsensusMode = .bayesian

    /// Whether to emit IUPAC ambiguity codes in consensus output.
    public var consensusUseAmbiguity: Bool = false

    /// Minimum mapping quality filter (reads below this are hidden).
    public var minMapQ: Double = 0

    /// Whether to show duplicate reads (SAM flag 0x400).
    public var showDuplicates: Bool = false

    /// Whether to show secondary alignments (SAM flag 0x100).
    public var showSecondary: Bool = false

    /// Whether to show supplementary alignments (SAM flag 0x800).
    public var showSupplementary: Bool = false

    /// Selected read group IDs to display (empty = show all).
    public var selectedReadGroups: Set<String> = []

    /// Whether reads are currently visible in the viewer.
    public var showReads: Bool = true

    /// Whether to tint read backgrounds by strand (forward=blue, reverse=pink).
    /// When off, all reads share a neutral gray background.
    public var showStrandColors: Bool = true

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

    /// Program records from @PG header lines.
    public var programRecords: [ProgramRecordEntry] = []

    /// Provenance history from import.
    public var provenanceRecords: [ProvenanceEntry] = []

    /// Alignment track names.
    public var trackNames: [String] = []

    // MARK: - BAM Filter Inspector State

    /// Alignment tracks available as BAM-filter sources.
    public var alignmentFilterTrackOptions: [AlignmentFilterTrackOption] = []

    /// Currently selected BAM-filter source track.
    public var selectedAlignmentFilterSourceTrackID: String? = nil {
        didSet {
            refreshAlignmentFilterOutputTrackNameIfNeeded()
        }
    }

    /// BAM-filter toggle for mapped reads only.
    public var alignmentFilterMappedOnly: Bool = true

    /// BAM-filter toggle for primary alignments only.
    public var alignmentFilterPrimaryOnly: Bool = true

    /// Minimum MAPQ threshold for BAM filtering.
    public var alignmentFilterMinimumMAPQ: Int = 0

    /// BAM-filter duplicate handling choice shown in Inspector UI.
    public var alignmentFilterDuplicateMode: AlignmentFilterInspectorDuplicateChoice = .keepAll {
        didSet {
            refreshAlignmentFilterOutputTrackNameIfNeeded()
        }
    }

    /// Whether BAM filtering should require exact matches only.
    public var alignmentFilterExactMatchOnly: Bool = false

    /// Minimum percent identity text entered in the Inspector.
    public var alignmentFilterMinimumPercentIdentityText: String = ""

    /// Output alignment track name for the derived BAM.
    public var alignmentFilterOutputTrackName: String = ""

    /// Whether the BAM-filter workflow is currently running.
    public var isAlignmentFilterWorkflowRunning: Bool = false

    /// Called to derive a filtered BAM track from the selected source track.
    public var onCreateFilteredAlignmentRequested: ((AlignmentFilterInspectorLaunchRequest) -> Void)?

    private var lastAutoGeneratedAlignmentFilterOutputTrackName: String = ""

    // MARK: - Computed Filters

    /// Computes the samtools exclude flags bitmask from the toggle settings.
    ///
    /// Default excludes: unmapped (0x4) + secondary (0x100) + dup (0x400) + supplementary (0x800)
    /// = 0x904 when showSecondary/showDuplicates/showSupplementary are all off.
    public var computedExcludeFlags: UInt16 {
        var flags: UInt16 = 0x4  // Always exclude unmapped
        if !showSecondary { flags |= 0x100 }
        if !showDuplicates { flags |= 0x400 }
        if !showSupplementary { flags |= 0x800 }
        return flags
    }

    // MARK: - Selected Read Detail

    /// The currently selected read (set via notification from viewer).
    public var selectedRead: AlignedRead?

    /// Whether a read is currently selected.
    public var hasSelectedRead: Bool { selectedRead != nil }

    // MARK: - Callbacks

    /// Called when display settings change; viewer should redraw.
    public var onSettingsChanged: (() -> Void)?

    /// Called to run duplicate marking workflow for loaded alignment tracks.
    public var onMarkDuplicatesRequested: (() -> Void)?

    /// Called to build a separate deduplicated bundle.
    public var onCreateDeduplicatedBundleRequested: (() -> Void)?

    /// Called to launch the BAM-backed variant calling workflow for the loaded bundle.
    public var onCallVariantsRequested: (() -> Void)?

    /// Whether mapping mode should expose biological consensus export.
    public var supportsConsensusExtraction: Bool = false

    /// Called to export biological consensus from the active mapping viewer.
    public var onExtractConsensusRequested: (() -> Void)?

    /// Whether duplicate workflow is currently running.
    public var isDuplicateWorkflowRunning: Bool = false

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
        programRecords = []
        provenanceRecords = []
        trackNames = []
        resetAlignmentFilterState()
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
        configureAlignmentFilterTracks(
            trackIds.map { trackID in
                AlignmentFilterTrackOption(
                    id: trackID,
                    name: bundle.alignmentTrack(id: trackID)?.name ?? trackID
                )
            }
        )

        var aggMapped: Int64 = 0
        var aggUnmapped: Int64 = 0
        var chromStatsList: [ChromosomeReadStat] = []
        var flagStatsList: [FlagStatEntry] = []
        var readGroupList: [ReadGroupEntry] = []
        var infoList: [(key: String, value: String)] = []
        var programList: [ProgramRecordEntry] = []
        var provenanceList: [ProvenanceEntry] = []

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

            // Program records
            for pg in db.programRecords() {
                programList.append(ProgramRecordEntry(
                    id: pg.id,
                    name: pg.name,
                    version: pg.version,
                    commandLine: pg.commandLine
                ))
            }

            // Provenance
            for prov in db.provenanceHistory() {
                provenanceList.append(ProvenanceEntry(
                    stepOrder: prov.stepOrder,
                    tool: prov.tool,
                    subcommand: prov.subcommand,
                    version: prov.version,
                    command: prov.command,
                    timestamp: prov.timestamp,
                    duration: prov.duration
                ))
            }
        }

        totalMappedReads = aggMapped
        totalUnmappedReads = aggUnmapped
        chromosomeStats = chromStatsList
        flagStats = flagStatsList
        readGroups = readGroupList
        fileInfo = infoList
        programRecords = programList
        provenanceRecords = provenanceList
    }

    /// Seeds the BAM-filter source track choices and default selection/output name.
    public func configureAlignmentFilterTracks(_ options: [AlignmentFilterTrackOption]) {
        alignmentFilterTrackOptions = options

        if let current = selectedAlignmentFilterSourceTrackID,
           options.contains(where: { $0.id == current }) == false {
            selectedAlignmentFilterSourceTrackID = nil
        }

        if selectedAlignmentFilterSourceTrackID == nil {
            selectedAlignmentFilterSourceTrackID = options.first?.id
        } else {
            refreshAlignmentFilterOutputTrackNameIfNeeded(force: true)
        }
    }

    /// Builds a validated Inspector-local launch request for BAM derivation.
    public func makeAlignmentFilterLaunchRequest() throws -> AlignmentFilterInspectorLaunchRequest {
        guard let sourceTrackID = selectedAlignmentFilterSourceTrackID,
              alignmentFilterTrackOptions.contains(where: { $0.id == sourceTrackID }) else {
            throw AlignmentFilterInspectorValidationError.missingSourceTrackSelection
        }

        let trimmedOutputName = alignmentFilterOutputTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutputName.isEmpty else {
            throw AlignmentFilterInspectorValidationError.missingOutputTrackName
        }

        let trimmedIdentityText = alignmentFilterMinimumPercentIdentityText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if alignmentFilterExactMatchOnly && !trimmedIdentityText.isEmpty {
            throw AlignmentFilterInspectorValidationError.conflictingIdentityFilters
        }

        let identityFilter: AlignmentFilterIdentityFilter?
        if alignmentFilterExactMatchOnly {
            identityFilter = .exactMatch
        } else if trimmedIdentityText.isEmpty {
            identityFilter = nil
        } else if let threshold = Double(trimmedIdentityText) {
            identityFilter = .minimumPercentIdentity(threshold)
        } else {
            throw AlignmentFilterInspectorValidationError
                .invalidMinimumPercentIdentity(alignmentFilterMinimumPercentIdentityText)
        }

        let minimumMAPQ = alignmentFilterMinimumMAPQ > 0 ? alignmentFilterMinimumMAPQ : nil

        return AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: sourceTrackID,
            outputTrackName: trimmedOutputName,
            filterRequest: AlignmentFilterRequest(
                mappedOnly: alignmentFilterMappedOnly,
                primaryOnly: alignmentFilterPrimaryOnly,
                minimumMAPQ: minimumMAPQ,
                duplicateMode: alignmentFilterDuplicateMode.serviceValue,
                identityFilter: identityFilter,
                region: nil
            )
        )
    }

    private func resetAlignmentFilterState() {
        alignmentFilterTrackOptions = []
        selectedAlignmentFilterSourceTrackID = nil
        alignmentFilterMappedOnly = true
        alignmentFilterPrimaryOnly = true
        alignmentFilterMinimumMAPQ = 0
        alignmentFilterDuplicateMode = .keepAll
        alignmentFilterExactMatchOnly = false
        alignmentFilterMinimumPercentIdentityText = ""
        alignmentFilterOutputTrackName = ""
        isAlignmentFilterWorkflowRunning = false
        lastAutoGeneratedAlignmentFilterOutputTrackName = ""
    }

    private func refreshAlignmentFilterOutputTrackNameIfNeeded(force: Bool = false) {
        let suggestedName = defaultAlignmentFilterOutputTrackName()
        guard !suggestedName.isEmpty else { return }

        let currentName = alignmentFilterOutputTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
        if force || currentName.isEmpty || currentName == lastAutoGeneratedAlignmentFilterOutputTrackName {
            alignmentFilterOutputTrackName = suggestedName
        }
        lastAutoGeneratedAlignmentFilterOutputTrackName = suggestedName
    }

    private func defaultAlignmentFilterOutputTrackName() -> String {
        guard let sourceTrackID = selectedAlignmentFilterSourceTrackID,
              let sourceTrack = alignmentFilterTrackOptions.first(where: { $0.id == sourceTrackID }) else {
            return ""
        }

        switch alignmentFilterDuplicateMode {
        case .keepAll, .excludeMarked:
            return "\(sourceTrack.name) filtered"
        case .removeDuplicates:
            return "\(sourceTrack.name) deduplicated filtered"
        }
    }
}

// MARK: - Supporting Types

public struct AlignmentFilterTrackOption: Identifiable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum AlignmentFilterInspectorDuplicateChoice: String, CaseIterable, Identifiable {
    case keepAll
    case excludeMarked
    case removeDuplicates

    public var id: String { rawValue }

    var serviceValue: AlignmentFilterDuplicateMode? {
        switch self {
        case .keepAll:
            return nil
        case .excludeMarked:
            return .exclude
        case .removeDuplicates:
            return .remove
        }
    }

    var title: String {
        switch self {
        case .keepAll:
            return "Keep All"
        case .excludeMarked:
            return "Exclude Marked"
        case .removeDuplicates:
            return "Remove Duplicates"
        }
    }
}

public struct AlignmentFilterInspectorLaunchRequest: Equatable {
    public let sourceTrackID: String
    public let outputTrackName: String
    public let filterRequest: AlignmentFilterRequest
}

public enum AlignmentFilterInspectorValidationError: Error, LocalizedError, Equatable {
    case missingSourceTrackSelection
    case missingOutputTrackName
    case conflictingIdentityFilters
    case invalidMinimumPercentIdentity(String)

    public var errorDescription: String? {
        switch self {
        case .missingSourceTrackSelection:
            return "Choose a source alignment track before launching BAM filtering."
        case .missingOutputTrackName:
            return "Enter an output track name for the filtered BAM."
        case .conflictingIdentityFilters:
            return "Exact-match filtering cannot be combined with a minimum percent identity threshold."
        case .invalidMinimumPercentIdentity(let value):
            return "Enter a numeric minimum percent identity value. Received '\(value)'."
        }
    }
}

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

/// Program record entry for display (from @PG header).
public struct ProgramRecordEntry: Identifiable {
    public var id: String { pgId }
    let pgId: String
    public let name: String?
    public let version: String?
    public let commandLine: String?

    init(id: String, name: String?, version: String?, commandLine: String?) {
        self.pgId = id
        self.name = name
        self.version = version
        self.commandLine = commandLine
    }
}

/// Provenance entry for display.
public struct ProvenanceEntry: Identifiable {
    public var id: Int { stepOrder }
    public let stepOrder: Int
    public let tool: String
    public let subcommand: String?
    public let version: String?
    public let command: String
    public let timestamp: String?
    public let duration: TimeInterval?
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
    @State private var isProgramRecordsExpanded = false
    @State private var isDerivedMetadataExpanded = false
    @State private var isProvenanceExpanded = false
    @State private var expandedProgramCommandIDs = Set<String>()
    @State private var expandedProvenanceCommandIDs = Set<Int>()
    @State private var alignmentFilterValidationMessage: String?

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

            // Program records (processing pipeline)
            if !viewModel.programRecords.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $isProgramRecordsExpanded) {
                    programRecordsSection
                        .padding(.top, 4)
                } label: {
                    Label("Processing Pipeline (\(viewModel.programRecords.count))", systemImage: "gear.badge")
                        .font(.headline)
                }
            }

            if !derivedMetadataEntries.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $isDerivedMetadataExpanded) {
                    derivedMetadataSection
                        .padding(.top, 4)
                } label: {
                    Label("Derived Track Metadata", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.headline)
                }
            }

            // Provenance
            if !viewModel.provenanceRecords.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $isProvenanceExpanded) {
                    provenanceSection
                        .padding(.top, 4)
                } label: {
                    Label("Import Provenance", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                }
            }
        } else {
            DisclosureGroup(isExpanded: $isStyleExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No alignment tracks loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Import a BAM or CRAM file via File > Import Center.")
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
            .opacity(viewModel.limitReadRows ? 1.0 : 0.5)
            Slider(value: $viewModel.maxReadRows, in: 10...2000, step: 10)
                .disabled(!viewModel.limitReadRows)
                .onChange(of: viewModel.maxReadRows) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Limit Visible Rows", isOn: $viewModel.limitReadRows)
                .onChange(of: viewModel.limitReadRows) { _, _ in
                    viewModel.onSettingsChanged?()
                }
                .help("Off keeps all mapped reads in the active view and enables stable vertical scrolling.")

            Toggle("Vertically Compress Contig", isOn: $viewModel.verticallyCompressContig)
                .onChange(of: viewModel.verticallyCompressContig) { _, _ in
                    viewModel.onSettingsChanged?()
                }
                .help("Compact mode uses smaller row heights to fit more reads on screen.")

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

            Text("Read Filters")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Include Duplicates", isOn: $viewModel.showDuplicates)
                .onChange(of: viewModel.showDuplicates) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Include Secondary", isOn: $viewModel.showSecondary)
                .onChange(of: viewModel.showSecondary) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Include Supplementary", isOn: $viewModel.showSupplementary)
                .onChange(of: viewModel.showSupplementary) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            // Read group filter (only show when multiple read groups exist)
            if viewModel.readGroups.count > 1 {
                Divider()

                Text("Read Groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(viewModel.readGroups) { rg in
                    Toggle(isOn: Binding(
                        get: {
                            viewModel.selectedReadGroups.isEmpty || viewModel.selectedReadGroups.contains(rg.rgId)
                        },
                        set: { isOn in
                            if viewModel.selectedReadGroups.isEmpty {
                                // First deselection: enable all except this one
                                var all = Set(viewModel.readGroups.map(\.rgId))
                                if !isOn { all.remove(rg.rgId) }
                                viewModel.selectedReadGroups = all
                            } else if isOn {
                                viewModel.selectedReadGroups.insert(rg.rgId)
                                // If all are selected, reset to empty (= show all)
                                if viewModel.selectedReadGroups.count == viewModel.readGroups.count {
                                    viewModel.selectedReadGroups = []
                                }
                            } else {
                                viewModel.selectedReadGroups.remove(rg.rgId)
                            }
                            viewModel.onSettingsChanged?()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(rg.rgId)
                                .font(.system(.caption, design: .monospaced))
                            if let sample = rg.sample {
                                Text(sample)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Divider()

            Toggle("Show Bases as Dots", isOn: $viewModel.showMismatches)
                .onChange(of: viewModel.showMismatches) { _, _ in
                    viewModel.onSettingsChanged?()
                }
                .help("When on, matching bases are shown as dots and mismatches as colored letters. When off, all bases are shown as letters. Mismatches (SNPs) are always highlighted.")

            Toggle("Show Soft Clips", isOn: $viewModel.showSoftClips)
                .onChange(of: viewModel.showSoftClips) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Show Insertions/Deletions", isOn: $viewModel.showIndels)
                .onChange(of: viewModel.showIndels) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Color by Strand", isOn: $viewModel.showStrandColors)
                .onChange(of: viewModel.showStrandColors) { _, _ in
                    viewModel.onSettingsChanged?()
                }
                .help("When on, forward reads are blue-tinted and reverse reads are pink-tinted. When off, all reads have a neutral gray background.")

            Divider()

            Text("Consensus (samtools-like)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Show Consensus Track", isOn: $viewModel.showConsensusTrack)
                .onChange(of: viewModel.showConsensusTrack) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Picker("Consensus Mode", selection: $viewModel.consensusMode) {
                Text("Bayesian").tag(AlignmentConsensusMode.bayesian)
                Text("Simple").tag(AlignmentConsensusMode.simple)
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.consensusMode) { _, _ in
                viewModel.onSettingsChanged?()
            }

            Toggle("Use IUPAC Ambiguity", isOn: $viewModel.consensusUseAmbiguity)
                .onChange(of: viewModel.consensusUseAmbiguity) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Hide High-Gap Sites", isOn: $viewModel.consensusMaskingEnabled)
                .onChange(of: viewModel.consensusMaskingEnabled) { _, _ in
                    viewModel.onSettingsChanged?()
                }
                .help("When enabled, columns where most spanning reads are gaps are masked in packed/base views.")

            HStack {
                Text("Consensus Min Depth")
                Spacer()
                Text("\(Int(viewModel.consensusMinDepth))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $viewModel.consensusMinDepth, in: 1...50, step: 1)
                .onChange(of: viewModel.consensusMinDepth) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            if viewModel.consensusMaskingEnabled {
                HStack {
                    Text("Gap Threshold")
                    Spacer()
                    Text("\(Int(viewModel.consensusGapThresholdPercent))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.consensusGapThresholdPercent, in: 50...99, step: 1)
                    .onChange(of: viewModel.consensusGapThresholdPercent) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                HStack {
                    Text("Masking Min Depth")
                    Spacer()
                    Text("\(Int(viewModel.consensusMaskingMinDepth))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.consensusMaskingMinDepth, in: 1...50, step: 1)
                    .onChange(of: viewModel.consensusMaskingMinDepth) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
            }

            HStack {
                Text("Consensus Min MAPQ")
                Spacer()
                Text("\(Int(viewModel.consensusMinMapQ))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $viewModel.consensusMinMapQ, in: 0...60, step: 1)
                .onChange(of: viewModel.consensusMinMapQ) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            HStack {
                Text("Consensus Min BaseQ")
                Spacer()
                Text("\(Int(viewModel.consensusMinBaseQ))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $viewModel.consensusMinBaseQ, in: 0...60, step: 1)
                .onChange(of: viewModel.consensusMinBaseQ) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Divider()

            Text("Duplicate Handling")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.supportsConsensusExtraction {
                Button("Extract Consensus…") {
                    viewModel.onExtractConsensusRequested?()
                }
                .disabled(!viewModel.hasAlignmentTracks)
            }

            Button("Call Variants…") {
                viewModel.onCallVariantsRequested?()
            }
            .disabled(!viewModel.hasAlignmentTracks)

            Button("Mark Duplicates in Bundle Tracks") {
                viewModel.onMarkDuplicatesRequested?()
            }
            .disabled(viewModel.isDuplicateWorkflowRunning || !viewModel.hasAlignmentTracks)

            Button("Create Deduplicated Bundle") {
                viewModel.onCreateDeduplicatedBundleRequested?()
            }
            .disabled(viewModel.isDuplicateWorkflowRunning || !viewModel.hasAlignmentTracks)

            if viewModel.isDuplicateWorkflowRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Running duplicate workflow...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Create Filtered Track")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(
                "Source Track",
                selection: Binding(
                    get: { viewModel.selectedAlignmentFilterSourceTrackID ?? "" },
                    set: { newValue in
                        viewModel.selectedAlignmentFilterSourceTrackID = newValue.isEmpty ? nil : newValue
                    }
                )
            ) {
                if viewModel.alignmentFilterTrackOptions.isEmpty {
                    Text("No alignment tracks").tag("")
                } else {
                    ForEach(viewModel.alignmentFilterTrackOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
            }
            .disabled(viewModel.alignmentFilterTrackOptions.isEmpty)

            Toggle("Mapped Only", isOn: $viewModel.alignmentFilterMappedOnly)
            Toggle("Primary Only", isOn: $viewModel.alignmentFilterPrimaryOnly)

            HStack {
                Text("Minimum MAPQ")
                Spacer()
                Stepper(
                    value: $viewModel.alignmentFilterMinimumMAPQ,
                    in: 0...255
                ) {
                    Text("\(viewModel.alignmentFilterMinimumMAPQ)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .labelsHidden()
            }

            Picker("Duplicates", selection: $viewModel.alignmentFilterDuplicateMode) {
                ForEach(AlignmentFilterInspectorDuplicateChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }

            Toggle("Exact Matches Only", isOn: $viewModel.alignmentFilterExactMatchOnly)

            TextField(
                "Minimum % identity",
                text: $viewModel.alignmentFilterMinimumPercentIdentityText
            )
            .textFieldStyle(.roundedBorder)

            TextField("Output Track Name", text: $viewModel.alignmentFilterOutputTrackName)
                .textFieldStyle(.roundedBorder)

            Button("Create Filtered Alignment Track") {
                do {
                    let request = try viewModel.makeAlignmentFilterLaunchRequest()
                    alignmentFilterValidationMessage = nil
                    viewModel.onCreateFilteredAlignmentRequested?(request)
                } catch {
                    alignmentFilterValidationMessage = error.localizedDescription
                }
            }
            .disabled(
                viewModel.isAlignmentFilterWorkflowRunning ||
                !viewModel.hasAlignmentTracks
            )

            if viewModel.isAlignmentFilterWorkflowRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Running BAM filter workflow...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let alignmentFilterValidationMessage, !alignmentFilterValidationMessage.isEmpty {
                Text(alignmentFilterValidationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
                            .foregroundStyle(Color.lungfishOrangeFallback)
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

    // MARK: - Program Records

    @ViewBuilder
    private var programRecordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commands are collapsed by default. Click “Show command” to view the full invocation.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            ForEach(Array(viewModel.programRecords.enumerated()), id: \.element.id) { index, pg in
                let step = index + 1
                let prov = provenanceForStep(step)
                let isExpanded = expandedProgramCommandIDs.contains(pg.id)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Step \(step)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Divider()
                            .frame(height: 10)
                        Text(pg.pgId)
                            .font(.system(.caption, design: .monospaced).bold())
                        if let name = pg.name {
                            Text("(\(name))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let version = pg.version {
                        inlineField("Version", value: version)
                    }
                    if let timestamp = prov?.timestamp, !timestamp.isEmpty {
                        inlineField("When", value: formattedTimestamp(timestamp))
                    }
                    if let dur = prov?.duration {
                        inlineField("Duration", value: String(format: "%.1fs", dur))
                    }
                    if let cmdLine = pg.commandLine, !cmdLine.isEmpty {
                        Button(isExpanded ? "Hide command" : "Show command") {
                            if isExpanded {
                                expandedProgramCommandIDs.remove(pg.id)
                            } else {
                                expandedProgramCommandIDs.insert(pg.id)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption2)

                        if isExpanded {
                            Text(cmdLine)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.bottom, 2)
            }
        }
    }

    // MARK: - Provenance

    @ViewBuilder
    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.provenanceRecords) { prov in
                let isExpanded = expandedProvenanceCommandIDs.contains(prov.stepOrder)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Step \(prov.stepOrder)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Divider()
                            .frame(height: 10)
                        Text(prov.tool)
                            .font(.system(.caption, design: .monospaced).bold())
                        if let sub = prov.subcommand {
                            Text(sub)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let ver = prov.version {
                            Text("v\(ver)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let ts = prov.timestamp {
                        Text(ts)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let dur = prov.duration {
                        inlineField("Duration", value: String(format: "%.1fs", dur))
                    }
                    if !prov.command.isEmpty {
                        Button(isExpanded ? "Hide command" : "Show command") {
                            if isExpanded {
                                expandedProvenanceCommandIDs.remove(prov.stepOrder)
                            } else {
                                expandedProvenanceCommandIDs.insert(prov.stepOrder)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption2)

                        if isExpanded {
                            Text(prov.command)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Derived Metadata

    @ViewBuilder
    private var derivedMetadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(derivedMetadataEntries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.key)
                        .font(.system(.caption, design: .monospaced).bold())
                    Text(entry.value)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
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

    private func provenanceForStep(_ step: Int) -> ProvenanceEntry? {
        if let exact = viewModel.provenanceRecords.first(where: { $0.stepOrder == step }) {
            return exact
        }
        let sorted = viewModel.provenanceRecords.sorted { $0.stepOrder < $1.stepOrder }
        guard step > 0, step <= sorted.count else { return nil }
        return sorted[step - 1]
    }

    private func formattedTimestamp(_ raw: String) -> String {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter.string(from: date)
        }
        return raw
    }

    private var derivedMetadataEntries: [(key: String, value: String)] {
        let hasDerivationInfo = viewModel.fileInfo.contains { $0.key.hasPrefix("derivation_") }
        guard hasDerivationInfo else { return [] }

        return viewModel.fileInfo.filter { entry in
            entry.key == "file_name" || entry.key.hasPrefix("derivation_")
        }
    }
}
