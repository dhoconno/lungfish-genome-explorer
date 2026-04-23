// ReadStyleSection.swift - Mapped reads style and statistics inspector section
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow

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

    /// Whether the current bundle includes at least one BAM track eligible for variant calling.
    public var hasVariantCallableAlignmentTracks: Bool = false

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

    /// Alignment tracks available for isolated viewing.
    public var visibleAlignmentTrackOptions: [AlignmentFilterTrackOption] = []

    /// Currently isolated alignment track for rendering. `nil` means show all alignments.
    public var selectedVisibleAlignmentTrackID: String? = nil

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

    /// Most recent user-facing derived-alignment outcome message.
    public var latestDerivedAlignmentMessage: String? = nil

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
        hasVariantCallableAlignmentTracks = false
        totalMappedReads = 0
        totalUnmappedReads = 0
        chromosomeStats = []
        flagStats = []
        readGroups = []
        fileInfo = []
        programRecords = []
        provenanceRecords = []
        trackNames = []
        visibleAlignmentTrackOptions = []
        selectedVisibleAlignmentTrackID = nil
        latestDerivedAlignmentMessage = nil
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
        hasVariantCallableAlignmentTracks = !BAMVariantCallingEligibility
            .eligibleAlignmentTracks(in: bundle)
            .isEmpty
        trackNames = trackIds.compactMap { bundle.alignmentTrack(id: $0)?.name }
        configureAlignmentFilterTracks(
            trackIds.map { trackID in
                AlignmentFilterTrackOption(
                    id: trackID,
                    name: bundle.alignmentTrack(id: trackID)?.name ?? trackID
                )
            }
        )
        configureVisibleAlignmentTracks(
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
        let hadValidSelection = selectedAlignmentFilterSourceTrackID.flatMap { current in
            options.first(where: { $0.id == current })
        } != nil

        if let current = selectedAlignmentFilterSourceTrackID,
           options.contains(where: { $0.id == current }) == false {
            selectedAlignmentFilterSourceTrackID = nil
        }

        if selectedAlignmentFilterSourceTrackID == nil {
            selectedAlignmentFilterSourceTrackID = options.first?.id
        } else if hadValidSelection {
            refreshAlignmentFilterOutputTrackNameIfNeeded()
        }
    }

    /// Seeds or validates the isolated-view alignment choices.
    public func configureVisibleAlignmentTracks(_ options: [AlignmentFilterTrackOption]) {
        visibleAlignmentTrackOptions = options

        if let current = selectedVisibleAlignmentTrackID,
           options.contains(where: { $0.id == current }) == false {
            selectedVisibleAlignmentTrackID = nil
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

        let identityFilter: LungfishWorkflow.AlignmentFilterIdentityFilter?
        if alignmentFilterExactMatchOnly {
            identityFilter = .exactMatch
        } else if trimmedIdentityText.isEmpty {
            identityFilter = nil
        } else if let threshold = Double(trimmedIdentityText) {
            guard (0...100).contains(threshold) else {
                throw AlignmentFilterInspectorValidationError
                    .outOfRangeMinimumPercentIdentity(alignmentFilterMinimumPercentIdentityText)
            }
            identityFilter = .minimumPercentIdentity(threshold)
        } else {
            throw AlignmentFilterInspectorValidationError
                .invalidMinimumPercentIdentityText(alignmentFilterMinimumPercentIdentityText)
        }

        let minimumMAPQ = alignmentFilterMinimumMAPQ > 0 ? alignmentFilterMinimumMAPQ : nil

        return AlignmentFilterInspectorLaunchRequest(
            sourceTrackID: sourceTrackID,
            outputTrackName: trimmedOutputName,
            filterRequest: LungfishWorkflow.AlignmentFilterRequest(
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

    /// Stores a plain-language outcome message for the most recently created derived alignment.
    public func noteDerivedAlignmentCreation(createdTrackName: String, sourceTrackName: String) {
        latestDerivedAlignmentMessage =
            "Created a new filtered alignment from \(sourceTrackName). The source alignment was not changed. Now viewing \(createdTrackName). Use Bundle > Alignment Tracks or View > Alignment to switch between them."
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

    var serviceValue: LungfishWorkflow.AlignmentFilterDuplicateMode? {
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
            return "Keep all reads"
        case .excludeMarked:
            return "Hide duplicate-marked reads"
        case .removeDuplicates:
            return "Remove duplicate reads"
        }
    }
}

public struct AlignmentFilterInspectorLaunchRequest: Equatable {
    public let sourceTrackID: String
    public let outputTrackName: String
    public let filterRequest: LungfishWorkflow.AlignmentFilterRequest
}

public enum AlignmentFilterInspectorValidationError: Error, LocalizedError, Equatable {
    case missingSourceTrackSelection
    case missingOutputTrackName
    case conflictingIdentityFilters
    case invalidMinimumPercentIdentityText(String)
    case outOfRangeMinimumPercentIdentity(String)

    public var errorDescription: String? {
        switch self {
        case .missingSourceTrackSelection:
            return "Choose a starting alignment before creating a filtered alignment."
        case .missingOutputTrackName:
            return "Enter a name for the new filtered alignment."
        case .conflictingIdentityFilters:
            return "Exact-match filtering cannot be combined with a minimum percent identity threshold."
        case .invalidMinimumPercentIdentityText(let value):
            return "Enter a numeric minimum percent identity value. Received '\(value)'."
        case .outOfRangeMinimumPercentIdentity(let value):
            return "Minimum percent identity must be between 0 and 100. Received '\(value)'."
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

public enum ReadStyleViewSubsection: String, CaseIterable, Identifiable {
    case alignment
    case annotations
    case reads

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .alignment:
            return "Alignment"
        case .annotations:
            return "Annotations"
        case .reads:
            return "Reads"
        }
    }
}

public enum AnalysisWorkflowSubsection: String, CaseIterable, Identifiable {
    case filtering
    case consensus
    case variantCalling
    case export

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .filtering:
            return "Filtering"
        case .consensus:
            return "Consensus"
        case .variantCalling:
            return "Variant Calling"
        case .export:
            return "Export"
        }
    }
}

// MARK: - Bundle Alignment Section

/// Bundle-scoped alignment summary and provenance shown in the Bundle tab.
public struct AlignmentBundleSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel
    @State private var isStatsExpanded = true
    @State private var isReadGroupsExpanded = false
    @State private var isFlagStatsExpanded = false
    @State private var isChromStatsExpanded = false
    @State private var isProgramRecordsExpanded = false
    @State private var isDerivedMetadataExpanded = false
    @State private var isProvenanceExpanded = false
    @State private var expandedProgramCommandIDs = Set<String>()
    @State private var expandedProvenanceCommandIDs = Set<Int>()

    public init(viewModel: ReadStyleSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.hasAlignmentTracks {
            DisclosureGroup("Alignment Summary", isExpanded: $isStatsExpanded) {
                alignmentSummary
                    .padding(.top, 4)
            }
            .font(.headline)

            if !viewModel.readGroups.isEmpty {
                Divider()
                DisclosureGroup("Read Groups (\(viewModel.readGroups.count))", isExpanded: $isReadGroupsExpanded) {
                    readGroupsSection
                        .padding(.top, 4)
                }
                .font(.headline)
            }

            if !viewModel.flagStats.isEmpty {
                Divider()
                DisclosureGroup("Flag Statistics", isExpanded: $isFlagStatsExpanded) {
                    flagStatsSection
                        .padding(.top, 4)
                }
                .font(.headline)
            }

            if viewModel.chromosomeStats.count > 1 {
                Divider()
                DisclosureGroup("Per-Chromosome (\(viewModel.chromosomeStats.count))", isExpanded: $isChromStatsExpanded) {
                    chromosomeStatsSection
                        .padding(.top, 4)
                }
                .font(.headline)
            }

            if !viewModel.programRecords.isEmpty {
                Divider()
                DisclosureGroup("Processing Pipeline (\(viewModel.programRecords.count))", isExpanded: $isProgramRecordsExpanded) {
                    programRecordsSection
                        .padding(.top, 4)
                }
                .font(.headline)
            }

            if !derivedMetadataEntries.isEmpty {
                Divider()
                DisclosureGroup("Derived Track Metadata", isExpanded: $isDerivedMetadataExpanded) {
                    derivedMetadataSection
                        .padding(.top, 4)
                }
                .font(.headline)
            }

            if !viewModel.provenanceRecords.isEmpty {
                Divider()
                DisclosureGroup("Import Provenance", isExpanded: $isProvenanceExpanded) {
                    provenanceSection
                        .padding(.top, 4)
                }
                .font(.headline)
            }
        }
    }

    @ViewBuilder
    private var alignmentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.trackNames.isEmpty {
                ForEach(viewModel.trackNames, id: \.self) { name in
                    HStack(alignment: .top, spacing: 6) {
                        Text("Track")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Divider()

            statRow("Total Mapped", value: formatCount(viewModel.totalMappedReads))
            statRow("Total Unmapped", value: formatCount(viewModel.totalUnmappedReads))

            if viewModel.totalMappedReads + viewModel.totalUnmappedReads > 0 {
                let total = viewModel.totalMappedReads + viewModel.totalUnmappedReads
                let pct = Double(viewModel.totalMappedReads) / Double(total) * 100
                statRow("Mapped %", value: String(format: "%.1f%%", pct))

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

            if viewModel.chromosomeStats.count == 1, let stat = viewModel.chromosomeStats.first {
                statRow("Est. Coverage", value: String(format: "%.1fx", stat.estimatedCoverage))
            }
        }
    }

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

    @ViewBuilder
    private var programRecordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Commands are collapsed by default. Click \"Show command\" to view the full invocation.")
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

// MARK: - Selected Read Section

/// Selected-read detail shown inside the Selected Item tab.
public struct ReadSelectionSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel
    @State private var isExpanded = true

    public init(viewModel: ReadStyleSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        DisclosureGroup("Selected Read", isExpanded: $isExpanded) {
            if let read = viewModel.selectedRead {
                selectedReadDetail(read)
                    .padding(.top, 4)
            } else {
                Text("Select a read in the viewer to inspect it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .font(.headline)
    }

    @ViewBuilder
    private func selectedReadDetail(_ read: AlignedRead) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(read.name)
                .font(.system(.caption, design: .monospaced).bold())
                .textSelection(.enabled)
                .lineLimit(2)

            Divider()

            statRow("Position", value: "\(read.chromosome):\(read.position + 1)-\(read.alignmentEnd)")
            statRow("Strand", value: read.isReverse ? "Reverse (-)" : "Forward (+)")
            statRow("Length", value: "\(read.referenceLength) bp")
            statRow("MAPQ", value: "\(read.mapq)")

            let cigar = read.cigarString
            statRow("CIGAR", value: String(cigar.prefix(50)) + (cigar.count > 50 ? "..." : ""))

            Divider()

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

            if let rg = read.readGroup {
                statRow("Read Group", value: rg)
            }

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

            let insertions = read.insertions
            if !insertions.isEmpty {
                Divider()
                Text("Insertions (\(insertions.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(insertions.prefix(5).enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text("pos \(item.position + 1)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(item.bases.prefix(20) + (item.bases.count > 20 ? "..." : ""))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.purple)
                    }
                }
                if insertions.count > 5 {
                    Text("... and \(insertions.count - 5) more")
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
}

// MARK: - AlignmentViewSection

/// Alignment-specific visibility controls shown in the View tab.
public struct AlignmentViewSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel
    private let allAlignmentsSelectionID = "__all_alignments__"

    public init(viewModel: ReadStyleSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                Text("Focus the viewer on one alignment or compare all alignments together. Panel layout belongs in this Alignment segment.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Choose whether the viewer shows every alignment track together or just one alignment track at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Visible Alignment", selection: visibleAlignmentSelection) {
                    Text("All Alignments").tag(allAlignmentsSelectionID)
                    ForEach(viewModel.visibleAlignmentTrackOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .disabled(viewModel.visibleAlignmentTrackOptions.isEmpty)

                Text(visibleAlignmentSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Show reads", isOn: $viewModel.showReads)
                    .onChange(of: viewModel.showReads) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                HStack {
                    Text("Minimum alignment confidence")
                    Spacer()
                    Text("\(Int(viewModel.minMapQ))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.minMapQ, in: 0...60, step: 1)
                    .onChange(of: viewModel.minMapQ) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Text("Read Inclusion")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Include duplicate-marked reads", isOn: $viewModel.showDuplicates)
                    .onChange(of: viewModel.showDuplicates) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Include secondary alignments", isOn: $viewModel.showSecondary)
                    .onChange(of: viewModel.showSecondary) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Include supplementary alignments", isOn: $viewModel.showSupplementary)
                    .onChange(of: viewModel.showSupplementary) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                if viewModel.readGroups.count > 1 {
                    Divider()
                    readGroupControls
                }
            }
        } else {
            inspectorEmptyState(
                title: "No alignment tracks loaded.",
                detail: "Import a BAM or CRAM file via File > Import Center."
            )
        }
    }

    @ViewBuilder
    private var readGroupControls: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            var all = Set(viewModel.readGroups.map(\.rgId))
                            if !isOn { all.remove(rg.rgId) }
                            viewModel.selectedReadGroups = all
                        } else if isOn {
                            viewModel.selectedReadGroups.insert(rg.rgId)
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
    }

    private var visibleAlignmentSelection: Binding<String> {
        Binding(
            get: { viewModel.selectedVisibleAlignmentTrackID ?? allAlignmentsSelectionID },
            set: { newValue in
                viewModel.selectedVisibleAlignmentTrackID = newValue == allAlignmentsSelectionID ? nil : newValue
                viewModel.onSettingsChanged?()
            }
        )
    }

    private var visibleAlignmentSummary: String {
        guard let selectedVisibleAlignmentTrackID = viewModel.selectedVisibleAlignmentTrackID else {
            return "Showing reads from every alignment track in this bundle."
        }

        let trackName = viewModel.visibleAlignmentTrackOptions
            .first(where: { $0.id == selectedVisibleAlignmentTrackID })?.name ?? selectedVisibleAlignmentTrackID
        return "Showing only \(trackName). Choose All Alignments to return to the aggregate view."
    }
}

// MARK: - ReadStyleSection View

/// Read rendering controls shown in the View tab.
public struct ReadStyleSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    public init(viewModel: ReadStyleSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 12) {
                Text("Control how reads are packed, labeled, and colored in the active alignment view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Maximum rows")
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

                Toggle("Limit visible rows", isOn: $viewModel.limitReadRows)
                    .onChange(of: viewModel.limitReadRows) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("Off keeps all mapped reads in the active view and enables stable vertical scrolling.")

                Toggle("Use compact row height", isOn: $viewModel.verticallyCompressContig)
                    .onChange(of: viewModel.verticallyCompressContig) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("Compact mode uses smaller row heights to fit more reads on screen.")

                Divider()

                Toggle("Show matching bases as dots", isOn: $viewModel.showMismatches)
                    .onChange(of: viewModel.showMismatches) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("When on, matching bases are shown as dots and mismatches as colored letters. When off, all bases are shown as letters. Mismatches remain highlighted.")

                Toggle("Show soft-clipped sequence", isOn: $viewModel.showSoftClips)
                    .onChange(of: viewModel.showSoftClips) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Show insertion and deletion markers", isOn: $viewModel.showIndels)
                    .onChange(of: viewModel.showIndels) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Divider()

                Toggle("Color reads by strand", isOn: $viewModel.showStrandColors)
                    .onChange(of: viewModel.showStrandColors) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("When on, forward reads are blue-tinted and reverse reads are pink-tinted. When off, all reads have a neutral gray background.")

                HStack {
                    Text("Forward strand color")
                    Spacer()
                    ColorPicker("", selection: $viewModel.forwardReadColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: viewModel.forwardReadColor) { _, _ in
                            viewModel.onSettingsChanged?()
                        }
                }

                HStack {
                    Text("Reverse strand color")
                    Spacer()
                    ColorPicker("", selection: $viewModel.reverseReadColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: viewModel.reverseReadColor) { _, _ in
                            viewModel.onSettingsChanged?()
                        }
                }
            }
        } else {
            inspectorEmptyState(
                title: "No alignment tracks loaded.",
                detail: "Import a BAM or CRAM file via File > Import Center."
            )
        }
    }
}

// MARK: - AnalysisSection

/// Durable alignment workflows shown in the Analysis tab.
public struct AnalysisSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel
    @State private var selectedSubsection: AnalysisWorkflowSubsection = .filtering
    @State private var alignmentFilterValidationMessage: String?

    public init(viewModel: ReadStyleSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run alignment analysis workflows, create derived outputs, and export bundle-ready results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Analysis Section", selection: $selectedSubsection) {
                    ForEach(AnalysisWorkflowSubsection.allCases) { section in
                        Text(section.displayTitle).tag(section)
                    }
                }
                .pickerStyle(.segmented)

                Group {
                    switch selectedSubsection {
                    case .filtering:
                        filteringSection
                    case .consensus:
                        consensusSection
                    case .variantCalling:
                        variantCallingSection
                    case .export:
                        exportSection
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("No alignment tracks loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Import a BAM or CRAM file before creating derived alignments or running BAM-based workflows.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var filteringSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Creates new outputs in this bundle. The original alignment stays unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("After creating a filtered alignment, find it under Bundle > Alignment Tracks and compare it separately under View > Alignment.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let latestDerivedAlignmentMessage = viewModel.latestDerivedAlignmentMessage,
               !latestDerivedAlignmentMessage.isEmpty {
                Text(latestDerivedAlignmentMessage)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            Button("Mark Duplicates in Bundle Tracks") {
                viewModel.onMarkDuplicatesRequested?()
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

            Text("Build a new alignment track from an existing BAM without changing the source track.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker(
                "Starting Alignment",
                selection: Binding(
                    get: { viewModel.selectedAlignmentFilterSourceTrackID ?? "" },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
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

            Toggle("Keep mapped reads only", isOn: Binding(
                get: { viewModel.alignmentFilterMappedOnly },
                set: { newValue in
                    alignmentFilterValidationMessage = nil
                    viewModel.alignmentFilterMappedOnly = newValue
                }
            ))

            Toggle("Keep one primary alignment per read", isOn: Binding(
                get: { viewModel.alignmentFilterPrimaryOnly },
                set: { newValue in
                    alignmentFilterValidationMessage = nil
                    viewModel.alignmentFilterPrimaryOnly = newValue
                }
            ))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum alignment confidence")
                    Spacer()
                    Stepper(
                        value: Binding(
                            get: { viewModel.alignmentFilterMinimumMAPQ },
                            set: { newValue in
                                alignmentFilterValidationMessage = nil
                                viewModel.alignmentFilterMinimumMAPQ = newValue
                            }
                        ),
                        in: 0...255
                    ) {
                        Text("\(viewModel.alignmentFilterMinimumMAPQ)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .labelsHidden()
                }
                Text("Uses SAM MAPQ. Set to 0 to keep every alignment confidence level.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("Duplicate handling", selection: Binding(
                get: { viewModel.alignmentFilterDuplicateMode },
                set: { newValue in
                    alignmentFilterValidationMessage = nil
                    viewModel.alignmentFilterDuplicateMode = newValue
                }
            )) {
                ForEach(AlignmentFilterInspectorDuplicateChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }

            Toggle("Keep reads with zero mismatches to reference", isOn: Binding(
                get: { viewModel.alignmentFilterExactMatchOnly },
                set: { newValue in
                    alignmentFilterValidationMessage = nil
                    viewModel.alignmentFilterExactMatchOnly = newValue
                }
            ))

            VStack(alignment: .leading, spacing: 4) {
                Text("Minimum identity to reference (%)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    viewModel.alignmentFilterExactMatchOnly ? "Disabled while exact-match filtering is on" : "Leave blank to keep all",
                    text: Binding(
                        get: { viewModel.alignmentFilterMinimumPercentIdentityText },
                        set: { newValue in
                            alignmentFilterValidationMessage = nil
                            viewModel.alignmentFilterMinimumPercentIdentityText = newValue
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.alignmentFilterExactMatchOnly)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name for New Alignment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "Filtered alignment name",
                    text: Binding(
                        get: { viewModel.alignmentFilterOutputTrackName },
                        set: { newValue in
                            alignmentFilterValidationMessage = nil
                            viewModel.alignmentFilterOutputTrackName = newValue
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            Button("Create Filtered Alignment") {
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
        }
    }

    @ViewBuilder
    private var consensusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Adjust consensus evidence settings here. Consensus controls are intentionally separate from View so display settings stay lighter.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Show consensus track in viewer", isOn: $viewModel.showConsensusTrack)
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

            Toggle("Use IUPAC ambiguity codes", isOn: $viewModel.consensusUseAmbiguity)
                .onChange(of: viewModel.consensusUseAmbiguity) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            Toggle("Hide high-gap sites", isOn: $viewModel.consensusMaskingEnabled)
                .onChange(of: viewModel.consensusMaskingEnabled) { _, _ in
                    viewModel.onSettingsChanged?()
                }
                .help("When enabled, columns where most spanning reads are gaps are masked in packed or base views.")

            HStack {
                Text("Consensus minimum depth")
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
                    Text("Gap threshold")
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
                    Text("Masking minimum depth")
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
                Text("Consensus minimum MAPQ")
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
                Text("Consensus minimum base quality")
                Spacer()
                Text("\(Int(viewModel.consensusMinBaseQ))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $viewModel.consensusMinBaseQ, in: 0...60, step: 1)
                .onChange(of: viewModel.consensusMinBaseQ) { _, _ in
                    viewModel.onSettingsChanged?()
                }

            if viewModel.supportsConsensusExtraction {
                Divider()

                Button("Extract Consensus…") {
                    viewModel.onExtractConsensusRequested?()
                }
                .disabled(!viewModel.hasAlignmentTracks)
            }
        }
    }

    @ViewBuilder
    private var variantCallingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Call variants from the currently loaded alignment evidence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.hasVariantCallableAlignmentTracks {
                Text("Use this when you want site-by-site differences summarized as variant calls rather than read-level evidence.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Variant calling is unavailable until this bundle includes an eligible alignment track.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Call Variants…") {
                viewModel.onCallVariantsRequested?()
            }
            .disabled(!viewModel.hasVariantCallableAlignmentTracks)
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Create bundle-level outputs that preserve the original source alignment.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Use export when you want a separate deliverable, not just another visible alignment inside the current bundle.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Create Deduplicated Bundle") {
                viewModel.onCreateDeduplicatedBundleRequested?()
            }
            .disabled(viewModel.isDuplicateWorkflowRunning || !viewModel.hasAlignmentTracks)
        }
    }
}

@ViewBuilder
private func inspectorEmptyState(title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
        Text(detail)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}
