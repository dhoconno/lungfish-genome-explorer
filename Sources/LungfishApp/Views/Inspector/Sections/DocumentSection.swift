// DocumentSection.swift - Bundle metadata display for Inspector Document tab
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO

// MARK: - DocumentSectionViewModel

/// View model for the document section of the inspector.
///
/// Displays bundle-level metadata including source information, genome summary,
/// extended metadata groups, and chromosome details when a chromosome is selected.
@Observable
@MainActor
public final class DocumentSectionViewModel {

    /// The currently loaded bundle manifest, if any.
    var manifest: BundleManifest?

    /// The bundle URL for display.
    var bundleURL: URL?

    /// Currently selected chromosome info (for chromosome-level metadata).
    var selectedChromosome: ChromosomeInfo?

    /// Updates the view model with a new bundle manifest.
    ///
    /// - Parameters:
    ///   - manifest: The bundle manifest to display, or nil to clear
    ///   - bundleURL: The URL of the loaded bundle
    func update(manifest: BundleManifest?, bundleURL: URL?) {
        self.manifest = manifest
        self.bundleURL = bundleURL
        self.selectedChromosome = nil
    }

    /// Updates the selected chromosome for detail display.
    ///
    /// - Parameter chromosome: The chromosome to display details for, or nil to clear
    func selectChromosome(_ chromosome: ChromosomeInfo?) {
        self.selectedChromosome = chromosome
    }

    // MARK: - FASTQ Statistics

    /// FASTQ dataset statistics (shown when a FASTQ file is loaded).
    var fastqStatistics: FASTQDatasetStatistics?

    /// SRA run info metadata (set when available from download or sidecar).
    var sraRunInfo: SRARunInfo?

    /// ENA read record metadata (set when available from download or sidecar).
    var enaReadRecord: ENAReadRecord?

    /// Ingestion pipeline metadata (clumpify/compress/index status).
    var ingestionMetadata: IngestionMetadata?

    /// FASTQ derivative lineage metadata, when this dataset is pointer-based.
    var fastqDerivativeManifest: FASTQDerivedBundleManifest?

    /// Updates the view model with FASTQ dataset statistics.
    func updateFASTQStatistics(_ stats: FASTQDatasetStatistics) {
        self.fastqStatistics = stats
        // Clear bundle-related data since this is a standalone FASTQ
        self.manifest = nil
        self.bundleURL = nil
        self.selectedChromosome = nil
    }

    /// Updates the view model with SRA/ENA metadata.
    func updateSRAMetadata(sra: SRARunInfo?, ena: ENAReadRecord?) {
        self.sraRunInfo = sra
        self.enaReadRecord = ena
    }

    /// Updates the view model with ingestion metadata.
    func updateIngestionMetadata(_ ingestion: IngestionMetadata?) {
        self.ingestionMetadata = ingestion
    }

    /// Updates FASTQ derivative metadata.
    func updateFASTQDerivativeMetadata(_ manifest: FASTQDerivedBundleManifest?) {
        self.fastqDerivativeManifest = manifest
    }

    // MARK: - NAO-MGS Metadata

    /// NAO-MGS manifest when displaying a surveillance result.
    var naoMgsManifest: NaoMgsManifest?

    /// Updates the view model with NAO-MGS manifest data.
    func updateNaoMgsManifest(_ manifest: NaoMgsManifest?) {
        self.naoMgsManifest = manifest
    }

    // MARK: - NVD Metadata

    /// NVD manifest when displaying an NVD result bundle.
    var nvdManifest: NvdManifest?

    /// Updates the view model with NVD manifest data.
    func updateNvdManifest(_ manifest: NvdManifest?) {
        self.nvdManifest = manifest
    }

    // MARK: - Layout Preferences
    /// When true, taxonomy table is on the left instead of the default right.
    var isTableOnLeft: Bool = UserDefaults.standard.bool(forKey: "metagenomicsTableOnLeft")

    // MARK: - Unified Classifier Sample Picker
    /// Shared classifier sample picker state for Inspector-embedded sample selector.
    var classifierPickerState: ClassifierSamplePickerState?
    /// Classifier sample entries for the picker view.
    var classifierSampleEntries: [any ClassifierSampleEntry] = []
    /// Common prefix stripped from classifier sample display names.
    var classifierStrippedPrefix: String = ""

    /// Sample metadata store for the current classifier bundle.
    var sampleMetadataStore: SampleMetadataStore?
    /// Bundle attachment store for the current classifier bundle.
    var bundleAttachmentStore: BundleAttachmentStore?

    /// Whether any content is available for display (bundle, FASTQ, SRA, NAO-MGS, or NVD metadata).
    var hasAnyContent: Bool {
        manifest != nil || fastqStatistics != nil || sraRunInfo != nil || enaReadRecord != nil || naoMgsManifest != nil || nvdManifest != nil
    }

    // MARK: - Analyses History

    /// Analysis manifest entries for the currently selected FASTQ bundle, sorted newest-first.
    var analysisManifestEntries: [AnalysisManifestEntry] = []

    /// Callback invoked when the user taps an analysis entry to navigate to it.
    var navigateToAnalysis: ((AnalysisManifestEntry) -> Void)?

    /// Loads the analysis manifest for the given bundle and project, pruning stale entries.
    ///
    /// - Parameters:
    ///   - bundleURL: The FASTQ bundle URL, or nil to clear.
    ///   - projectURL: The enclosing project folder URL, or nil to clear.
    func updateAnalysisManifest(bundleURL: URL?, projectURL: URL?) {
        guard let bundleURL, let projectURL else {
            analysisManifestEntries = []
            return
        }
        let manifest = AnalysisManifestStore.load(bundleURL: bundleURL, projectURL: projectURL)
        analysisManifestEntries = manifest.analyses.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Batch Operation Details

    /// The tool name for a batch operation (e.g. "Kraken2", "EsViritu"), or nil when not in batch context.
    var batchOperationTool: String?

    /// Key-value parameters from the batch manifest (e.g. database name, confidence threshold).
    var batchOperationParameters: [String: String] = [:]

    /// Timestamp from the batch manifest header indicating when the batch was created.
    var batchOperationTimestamp: Date?

    /// Source sample entries for the batch, each pairing a sample ID with its originating bundle URL (if resolvable).
    var batchSourceSampleURLs: [(sampleId: String, bundleURL: URL?)] = []

    // MARK: - Batch Manifest Cache Status

    /// Represents the caching state of the aggregated batch manifest file.
    enum BatchManifestStatus: String {
        /// No manifest has been built yet (first load or manifest absent).
        case notCached = "Not cached"
        /// The manifest is currently being built from per-sample files.
        case building = "Building..."
        /// A manifest file exists and was loaded (or has just been saved).
        case cached = "Cached"
    }

    /// The current manifest cache status for the displayed batch result.
    var batchManifestStatus: BatchManifestStatus = .notCached
}

// MARK: - DocumentSection

/// SwiftUI view displaying bundle-level metadata in the Inspector Document tab.
///
/// Shows source information, genome summary, extended metadata groups from the
/// manifest, and chromosome details when a chromosome is selected. Each section
/// uses a collapsible `DisclosureGroup` for a compact, Keynote-style layout.
public struct DocumentSection: View {
    var viewModel: DocumentSectionViewModel

    @State private var isSourceExpanded = true
    @State private var isGenomeExpanded = true
    @State private var isChromosomeExpanded = true
    @State private var isFASTQStatsExpanded = true
    @State private var isSRAMetadataExpanded = true
    @State private var isENAMetadataExpanded = true
    @State private var isFASTQDerivativeExpanded = true
    @State private var isAnalysesExpanded = true
    @State private var expandedMetadataGroups: Set<String> = []
    @State private var trackedManifestIdentifier: String?

    public init(viewModel: DocumentSectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        if let manifest = viewModel.manifest {
            bundleContent(manifest)
                .onChange(of: manifest.modifiedDate) { _, _ in
                    expandAllSections(manifest: manifest)
                    trackedManifestIdentifier = manifest.identifier
                }
                .onAppear {
                    if trackedManifestIdentifier != manifest.identifier {
                        expandAllSections(manifest: manifest)
                        trackedManifestIdentifier = manifest.identifier
                    }
                }
        } else if let stats = viewModel.fastqStatistics {
            fastqContent(stats)
        } else {
            noDocumentView
        }
    }

    private func expandAllSections(manifest: BundleManifest) {
        isSourceExpanded = true
        isGenomeExpanded = true
        isChromosomeExpanded = true
        if let groups = manifest.metadata {
            expandedMetadataGroups = Set(groups.map(\.name))
        }
    }

    // MARK: - Bundle Content

    @ViewBuilder
    private func bundleContent(_ manifest: BundleManifest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Bundle header
            bundleHeader(manifest)

            Divider()

            // Source info
            sourceSection(manifest.source)

            Divider()

            // Genome summary
            if let genome = manifest.genome {
                genomeSection(genome, annotations: manifest.annotations, variants: manifest.variants)
            }

            // Extended metadata groups
            if let groups = manifest.metadata, !groups.isEmpty {
                ForEach(groups) { group in
                    Divider()
                    metadataGroupSection(group)
                }
            }

            // Chromosome detail
            if let chromosome = viewModel.selectedChromosome {
                Divider()
                chromosomeSection(chromosome)
            }
        }
    }

    // MARK: - Bundle Header

    @ViewBuilder
    private func bundleHeader(_ manifest: BundleManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(manifest.name)
                .font(.headline)
                .lineLimit(2)

            if !manifest.source.organism.isEmpty {
                Text(manifest.source.organism)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            if let commonName = manifest.source.commonName, !commonName.isEmpty {
                Text(commonName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let desc = manifest.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Source Section

    @ViewBuilder
    private func sourceSection(_ source: SourceInfo) -> some View {
        DisclosureGroup(isExpanded: $isSourceExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Organism", value: source.organism)

                if let commonName = source.commonName {
                    metadataRow(label: "Common Name", value: commonName)
                }

                metadataRow(label: "Assembly", value: source.assembly)

                if let accession = source.assemblyAccession {
                    metadataRow(label: "Accession", value: accession)
                }

                if let database = source.database {
                    metadataRow(label: "Database", value: database)
                }

                if let taxonomyId = source.taxonomyId {
                    metadataRow(label: "Taxonomy ID", value: "\(taxonomyId)")
                }

                if let downloadDate = source.downloadDate {
                    metadataRow(label: "Downloaded", value: formatDate(downloadDate))
                }

                if let notes = source.notes, !notes.isEmpty {
                    metadataRow(label: "Notes", value: notes)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Source")
                .font(.headline)
        }
    }

    // MARK: - Genome Section

    @ViewBuilder
    private func genomeSection(_ genome: GenomeInfo, annotations: [AnnotationTrackInfo], variants: [VariantTrackInfo]) -> some View {
        DisclosureGroup(isExpanded: $isGenomeExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Total Length", value: formatBases(genome.totalLength))
                metadataRow(label: "Chromosomes", value: "\(genome.chromosomes.count)")

                if !annotations.isEmpty {
                    let totalFeatures = annotations.compactMap(\.featureCount).reduce(0, +)
                    let featureSuffix = totalFeatures > 0 ? " (\(formatCount(totalFeatures)) features)" : ""
                    metadataRow(label: "Annotations", value: "\(annotations.count) track\(annotations.count == 1 ? "" : "s")\(featureSuffix)")
                } else {
                    metadataRow(label: "Annotations", value: "None")
                }

                if !variants.isEmpty {
                    let totalVariants = variants.compactMap(\.variantCount).reduce(0, +)
                    let variantSuffix = totalVariants > 0 ? " (\(formatCount(totalVariants)) variants)" : ""
                    metadataRow(label: "Variants", value: "\(variants.count) track\(variants.count == 1 ? "" : "s")\(variantSuffix)")
                } else {
                    metadataRow(label: "Variants", value: "None")
                }

                if let md5 = genome.md5Checksum {
                    metadataRow(label: "MD5", value: md5)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Genome")
                .font(.headline)
        }
    }

    // MARK: - Metadata Group Section

    @ViewBuilder
    private func metadataGroupSection(_ group: MetadataGroup) -> some View {
        DisclosureGroup(isExpanded: metadataGroupBinding(for: group.name)) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.items) { item in
                    metadataRow(label: item.label, value: item.value, url: item.url)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(group.name)
                .font(.headline)
        }
    }

    private func metadataGroupBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { expandedMetadataGroups.contains(name) },
            set: { newValue in
                if newValue {
                    expandedMetadataGroups.insert(name)
                } else {
                    expandedMetadataGroups.remove(name)
                }
            }
        )
    }

    // MARK: - Chromosome Section

    @ViewBuilder
    private func chromosomeSection(_ chromosome: ChromosomeInfo) -> some View {
        DisclosureGroup(isExpanded: $isChromosomeExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Name", value: chromosome.name)
                metadataRow(label: "Length", value: formatBases(chromosome.length))

                if let desc = chromosome.fastaDescription, !desc.isEmpty {
                    metadataRow(label: "Description", value: desc)
                }

                if chromosome.isPrimary {
                    metadataRow(label: "Status", value: "Primary assembly")
                }

                if chromosome.isMitochondrial {
                    metadataRow(label: "Type", value: "Mitochondrial")
                }

                if !chromosome.aliases.isEmpty {
                    metadataRow(label: "Aliases", value: chromosome.aliases.joined(separator: ", "))
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Chromosome")
                .font(.headline)
        }
    }

    // MARK: - FASTQ Content

    @ViewBuilder
    private func fastqContent(_ stats: FASTQDatasetStatistics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("FASTQ Dataset")
                    .font(.headline)
                Text("\(formatCount(stats.readCount)) reads")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Statistics
            fastqStatisticsSection(stats)

            // SRA Metadata
            if let sra = viewModel.sraRunInfo {
                Divider()
                sraMetadataSection(sra)
            }

            // ENA Metadata
            if let ena = viewModel.enaReadRecord {
                Divider()
                enaMetadataSection(ena)
            }

            // Ingestion Metadata
            if let ingestion = viewModel.ingestionMetadata {
                Divider()
                ingestionMetadataSection(ingestion)
            }

            if let derivative = viewModel.fastqDerivativeManifest {
                Divider()
                fastqDerivativeSection(derivative)
            }

            // Analysis history
            if !viewModel.analysisManifestEntries.isEmpty || viewModel.fastqStatistics != nil {
                Divider()
                DisclosureGroup(isExpanded: $isAnalysesExpanded) {
                    AnalysesSection(
                        analyses: viewModel.analysisManifestEntries,
                        onNavigate: { entry in viewModel.navigateToAnalysis?(entry) }
                    )
                } label: {
                    HStack {
                        Text("Analyses")
                            .font(.headline)
                        if !viewModel.analysisManifestEntries.isEmpty {
                            Text("(\(viewModel.analysisManifestEntries.count))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fastqStatisticsSection(_ stats: FASTQDatasetStatistics) -> some View {
        DisclosureGroup(isExpanded: $isFASTQStatsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Read Count", value: formatCount(stats.readCount))
                metadataRow(label: "Base Count", value: formatBases(stats.baseCount))
                metadataRow(label: "Mean Length", value: String(format: "%.1f bp", stats.meanReadLength))
                metadataRow(label: "Min Length", value: "\(stats.minReadLength) bp")
                metadataRow(label: "Max Length", value: "\(stats.maxReadLength) bp")
                metadataRow(label: "Median Length", value: "\(stats.medianReadLength) bp")
                metadataRow(label: "N50", value: "\(stats.n50ReadLength) bp")
                metadataRow(
                    label: "Quality Report",
                    value: hasCachedQualityReport(stats) ? "Cached" : "Not Computed"
                )

                Divider()

                metadataRow(label: "Mean Quality", value: String(format: "%.1f", stats.meanQuality))
                metadataRow(label: "Q20 Bases", value: String(format: "%.1f%%", stats.q20Percentage))
                metadataRow(label: "Q30 Bases", value: String(format: "%.1f%%", stats.q30Percentage))
                metadataRow(label: "GC Content", value: String(format: "%.1f%%", stats.gcContent * 100))
            }
            .padding(.top, 4)
        } label: {
            Text("Dataset Statistics")
                .font(.headline)
        }
    }

    private func hasCachedQualityReport(_ stats: FASTQDatasetStatistics) -> Bool {
        !stats.perPositionQuality.isEmpty && !stats.qualityScoreHistogram.isEmpty
    }

    @ViewBuilder
    private func sraMetadataSection(_ sra: SRARunInfo) -> some View {
        DisclosureGroup(isExpanded: $isSRAMetadataExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Run", value: sra.accession)
                if let exp = sra.experiment, !exp.isEmpty {
                    metadataRow(label: "Experiment", value: exp)
                }
                if let sample = sra.sample, !sample.isEmpty {
                    metadataRow(label: "Sample", value: sample)
                }
                if let study = sra.study, !study.isEmpty {
                    metadataRow(label: "Study", value: study)
                }
                if let bp = sra.bioproject, !bp.isEmpty {
                    metadataRow(label: "BioProject", value: bp)
                }
                if let bs = sra.biosample, !bs.isEmpty {
                    metadataRow(label: "BioSample", value: bs)
                }

                Divider()

                if let org = sra.organism, !org.isEmpty {
                    metadataRow(label: "Organism", value: org)
                }
                if let platform = sra.platform, !platform.isEmpty {
                    metadataRow(label: "Platform", value: platform)
                }
                if let strategy = sra.libraryStrategy, !strategy.isEmpty {
                    metadataRow(label: "Strategy", value: strategy)
                }
                if let source = sra.librarySource, !source.isEmpty {
                    metadataRow(label: "Source", value: source)
                }
                if let layout = sra.libraryLayout, !layout.isEmpty {
                    metadataRow(label: "Layout", value: layout)
                }

                Divider()

                if let spots = sra.spots {
                    metadataRow(label: "Spots", value: formatCount(spots))
                }
                if let bases = sra.bases {
                    metadataRow(label: "Bases", value: formatBases(Int64(bases)))
                }
                if let avgLen = sra.avgLength {
                    metadataRow(label: "Avg Length", value: "\(avgLen) bp")
                }
                if let size = sra.size, size > 0 {
                    metadataRow(label: "File Size", value: sra.sizeString)
                }
                if let date = sra.releaseDate {
                    metadataRow(label: "Released", value: formatDate(date))
                }
            }
            .padding(.top, 4)
        } label: {
            Text("SRA Metadata")
                .font(.headline)
        }
    }

    @ViewBuilder
    private func enaMetadataSection(_ ena: ENAReadRecord) -> some View {
        DisclosureGroup(isExpanded: $isENAMetadataExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Run", value: ena.runAccession)
                if let exp = ena.experimentAccession, !exp.isEmpty {
                    metadataRow(label: "Experiment", value: exp)
                }
                if let sample = ena.sampleAccession, !sample.isEmpty {
                    metadataRow(label: "Sample", value: sample)
                }
                if let study = ena.studyAccession, !study.isEmpty {
                    metadataRow(label: "Study", value: study)
                }
                if let title = ena.experimentTitle, !title.isEmpty {
                    metadataRow(label: "Title", value: title)
                }

                Divider()

                if let layout = ena.libraryLayout, !layout.isEmpty {
                    metadataRow(label: "Layout", value: layout)
                }
                if let source = ena.librarySource, !source.isEmpty {
                    metadataRow(label: "Source", value: source)
                }
                if let strategy = ena.libraryStrategy, !strategy.isEmpty {
                    metadataRow(label: "Strategy", value: strategy)
                }
                if let platform = ena.instrumentPlatform, !platform.isEmpty {
                    metadataRow(label: "Platform", value: platform)
                }

                Divider()

                if let count = ena.readCount, count > 0 {
                    metadataRow(label: "Read Count", value: formatCount(count))
                }
                if let bases = ena.baseCount, bases > 0 {
                    metadataRow(label: "Base Count", value: formatBases(Int64(bases)))
                }
                if let date = ena.firstPublic {
                    metadataRow(label: "Published", value: formatDate(date))
                }
            }
            .padding(.top, 4)
        } label: {
            Text("ENA Metadata")
                .font(.headline)
        }
    }

    // MARK: - Ingestion Metadata

    @ViewBuilder
    private func ingestionMetadataSection(_ ingestion: IngestionMetadata) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow(label: "Clumpified", value: ingestion.isClumpified ? "Yes" : "No")
                metadataRow(label: "Compressed", value: ingestion.isCompressed ? "Yes" : "No")
                metadataRow(label: "Pairing", value: ingestion.pairingMode.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                if let binning = ingestion.qualityBinning, binning != "none" {
                    metadataRow(label: "Quality Binning", value: binning)
                }

                if !ingestion.originalFilenames.isEmpty {
                    Divider()
                    Text("Original Files")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(ingestion.originalFilenames, id: \.self) { name in
                        Text(name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let size = ingestion.originalSizeBytes {
                    metadataRow(label: "Original Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }

                if let date = ingestion.ingestionDate {
                    metadataRow(label: "Processed", value: formatDate(date))
                }

                if let recipe = ingestion.recipeApplied {
                    Divider()
                    recipeAppliedSubsection(recipe)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Ingestion")
                .font(.headline)
        }
    }

    @ViewBuilder
    private func recipeAppliedSubsection(_ info: RecipeAppliedInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "wand.and.sparkles")
                    .foregroundStyle(.secondary)
                Text(info.recipeName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(formatDate(info.appliedDate))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let totalRemoved = info.totalReadsRemoved, totalRemoved > 0 {
                let pct = info.stepResults.first?.inputReadCount.map { i in
                    i > 0 ? String(format: " (%.1f%%)", Double(totalRemoved) / Double(i) * 100) : ""
                } ?? ""
                metadataRow(label: "Net reads removed", value: "\(formatCount(totalRemoved))\(pct)")
            }

            if !info.stepResults.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(info.stepResults.indices, id: \.self) { idx in
                        let step = info.stepResults[idx]
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(idx + 1).")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.stepName)
                                    .font(.caption)
                                    .lineLimit(2)
                                if let inCount = step.inputReadCount, let outCount = step.outputReadCount {
                                    let delta = inCount - outCount
                                    let isScrubStep = step.tool.contains("scrubber") || step.tool.contains("scrub")
                                    if delta > 0 {
                                        let verb = isScrubStep ? "masked" : "removed"
                                        let pct = inCount > 0 ? String(format: " (%.1f%%)", Double(delta) / Double(inCount) * 100) : ""
                                        Text("\(formatCount(inCount)) reads, \(formatCount(delta)) \(verb)\(pct)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else if delta < 0 {
                                        Text("\(formatCount(inCount)) → \(formatCount(outCount)) (+\(formatCount(-delta)))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("\(formatCount(outCount)) reads, none \(isScrubStep ? "masked" : "removed")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let ver = step.toolVersion {
                                    Text("\(step.tool) \(ver)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text(step.tool)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if let commandLine = step.commandLine,
                                   !commandLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(commandLine)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                        .contextMenu {
                                            Button("Copy Command") {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(commandLine, forType: .string)
                                            }
                                        }
                                        .help("Right-click to copy")
                                }
                            }
                            Spacer()
                            Text(formatDuration(step.durationSeconds))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

                // Copy All as Script button
                let commands = info.stepResults.compactMap(\.commandLine)
                if !commands.isEmpty {
                    Button {
                        let script = buildReproducibilityScript(info: info)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(script, forType: .string)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                            Text("Copy Pipeline as Script")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Builds a shell script that reproduces the pipeline steps.
    private func buildReproducibilityScript(info: RecipeAppliedInfo) -> String {
        var lines: [String] = []
        lines.append("#!/bin/bash")
        lines.append("# Pipeline: \(info.recipeName)")
        lines.append("# Generated by Lungfish on \(formatDate(info.appliedDate))")
        lines.append("# \(info.stepResults.count) step(s)")
        lines.append("")
        lines.append("set -euo pipefail")
        lines.append("")

        for (idx, step) in info.stepResults.enumerated() {
            lines.append("# Step \(idx + 1): \(step.stepName)")
            if let ver = step.toolVersion {
                lines.append("# Tool: \(step.tool) \(ver)")
            }
            if let cmd = step.commandLine,
               !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(cmd)
            } else {
                lines.append("# (no command recorded for this step)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let m = Int(seconds / 60)
        let s = Int(seconds) % 60
        return "\(m)m\(s)s"
    }

    private func fastqDerivativeSection(_ manifest: FASTQDerivedBundleManifest) -> some View {
        DisclosureGroup(isExpanded: $isFASTQDerivativeExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                // Operation card
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: sfSymbolForOperation(manifest.operation))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manifest.operation.displaySummary)
                            .font(.callout)
                            .fontWeight(.semibold)
                        if let tool = manifest.operation.toolUsed {
                            Text(tool)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(formatDate(manifest.createdAt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)

                // Payload type
                switch manifest.payload {
                case .subset:
                    metadataRow(label: "Storage", value: "Pointer (read IDs)")
                case .trim:
                    metadataRow(label: "Storage", value: "Pointer (trim positions)")
                case .full:
                    metadataRow(label: "Storage", value: "Materialized FASTQ")
                case .fullPaired:
                    metadataRow(label: "Storage", value: "Materialized R1/R2")
                case .fullMixed(let classification):
                    metadataRow(label: "Storage", value: "Materialized (\(classification.compositionLabel))")
                case .demuxedVirtual(let barcodeID, _, _, let trimFile, _):
                    metadataRow(label: "Storage", value: "Virtual demuxed barcode (\(barcodeID))\(trimFile != nil ? " + trim positions" : "")")
                case .demuxGroup(let count):
                    metadataRow(label: "Storage", value: "Demux group (\(count) barcodes)")
                case .fullFASTA:
                    metadataRow(label: "Storage", value: "Materialized FASTA")
                case .orientMap:
                    metadataRow(label: "Storage", value: "Orientation map (materialized on demand)")
                }

                // Command block (scrollable monospace with copy button)
                if let cmd = manifest.operation.toolCommand {
                    Divider()
                    ZStack(alignment: .topTrailing) {
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(cmd)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 60)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .cornerRadius(6)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy command to clipboard")
                        .padding(4)
                    }
                }

                // Vertical timeline lineage
                if manifest.lineage.count > 1 {
                    Divider()
                    Text("Lineage")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(manifest.lineage.enumerated()), id: \.offset) { index, op in
                            let isLast = index == manifest.lineage.count - 1
                            let isFirst = index == 0

                            HStack(alignment: .top, spacing: 8) {
                                // Step circle + connecting line
                                VStack(spacing: 0) {
                                    ZStack {
                                        Circle()
                                            .fill(isLast ? Color.accentColor : Color(nsColor: .quaternarySystemFill))
                                            .frame(width: 20, height: 20)
                                        Text("\(index + 1)")
                                            .font(.caption2)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(isLast ? .white : .secondary)
                                    }
                                    if !isLast {
                                        Rectangle()
                                            .fill(Color(nsColor: .separatorColor))
                                            .frame(width: 1, height: 16)
                                    }
                                }
                                .frame(width: 20)

                                // Step content
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(isFirst ? "Root FASTQ" : op.displaySummary)
                                        .font(.caption)
                                        .foregroundStyle(isLast ? .primary : .secondary)
                                    if isFirst {
                                        Text(manifest.rootFASTQFilename)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    } else if let tool = op.toolUsed {
                                        Text(tool)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.bottom, isLast ? 0 : 4)
                            }
                        }
                    }
                } else {
                    // Simple source reference
                    Divider()
                    metadataRow(label: "Root FASTQ", value: manifest.rootFASTQFilename)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                Text("Provenance")
                    .font(.headline)
            }
        }
    }

    // MARK: - No Document View

    @ViewBuilder
    private var noDocumentView: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No Bundle Loaded")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Open a reference bundle to view its metadata")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Metadata Row

    @ViewBuilder
    private func metadataRow(label: String, value: String, url: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

            if let urlString = url, let linkURL = URL(string: urlString) {
                Link(value, destination: linkURL)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contextMenu {
                        Button("Copy Value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
                        Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(urlString, forType: .string) }
                    }
            } else {
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Formatting Helpers

    /// Formats a base-pair count with appropriate unit suffix.
    private func formatBases(_ bases: Int64) -> String {
        if bases >= 1_000_000_000 {
            let gb = Double(bases) / 1_000_000_000.0
            return String(format: "%.2f Gb", gb)
        } else if bases >= 1_000_000 {
            let mb = Double(bases) / 1_000_000.0
            return String(format: "%.1f Mb", mb)
        } else if bases >= 1_000 {
            let kb = Double(bases) / 1_000.0
            return String(format: "%.1f Kb", kb)
        } else {
            return "\(bases) bp"
        }
    }

    /// Formats a count with comma separators.
    private func formatCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    /// Formats a date for display.
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// Maps a FASTQ derivative operation to an appropriate SF Symbol name.
    private func sfSymbolForOperation(_ op: FASTQDerivativeOperation) -> String {
        let summary = op.displaySummary.lowercased()
        if summary.contains("subsample") { return "dice" }
        if summary.contains("length filter") { return "ruler" }
        if summary.contains("search") || summary.contains("find") || summary.contains("motif") { return "magnifyingglass" }
        if summary.contains("dedup") { return "minus.circle" }
        if summary.contains("quality trim") || summary.contains("qtrim") { return "scissors" }
        if summary.contains("adapter") { return "minus.circle" }
        if summary.contains("fixed trim") { return "crop" }
        if summary.contains("contaminant") { return "xmark.shield" }
        if summary.contains("merge") { return "arrow.triangle.merge" }
        if summary.contains("repair") { return "wrench" }
        if summary.contains("primer") { return "eraser" }
        if summary.contains("error corr") { return "checkmark.circle" }
        if summary.contains("interleave") { return "arrow.left.arrow.right" }
        return "gearshape"
    }
}

// MARK: - Preview

#if DEBUG
struct DocumentSection_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(spacing: 16) {
                // With manifest
                DocumentSection(viewModel: {
                    let vm = DocumentSectionViewModel()
                    vm.update(
                        manifest: BundleManifest(
                            name: "Macaca mulatta T2T-MMU8v2.0",
                            identifier: "org.lungfish.macaque",
                            description: "Rhesus macaque telomere-to-telomere assembly",
                            source: SourceInfo(
                                organism: "Macaca mulatta",
                                commonName: "Rhesus macaque",
                                taxonomyId: 9544,
                                assembly: "T2T-MMU8v2.0",
                                assemblyAccession: "GCF_049350105.2",
                                database: "NCBI",
                                downloadDate: Date()
                            ),
                            genome: GenomeInfo(
                                path: "genome/sequence.fa.gz",
                                indexPath: "genome/sequence.fa.gz.fai",
                                totalLength: 2_936_875_000,
                                chromosomes: [
                                    ChromosomeInfo(
                                        name: "NC_041754.1",
                                        length: 227_556_264,
                                        offset: 0,
                                        lineBases: 80,
                                        lineWidth: 81,
                                        isPrimary: true,
                                        fastaDescription: "Macaca mulatta chromosome 1"
                                    )
                                ]
                            ),
                            annotations: [
                                AnnotationTrackInfo(
                                    id: "genes",
                                    name: "NCBI Genes",
                                    path: "annotations/genes.bb",
                                    featureCount: 159_000
                                )
                            ],
                            metadata: [
                                MetadataGroup(
                                    name: "Assembly",
                                    items: [
                                        MetadataItem(label: "Assembly Level", value: "Chromosome"),
                                        MetadataItem(label: "Coverage", value: "30x"),
                                        MetadataItem(label: "Contig N50", value: "56,413,054 bp")
                                    ]
                                )
                            ]
                        ),
                        bundleURL: URL(fileURLWithPath: "/tmp/test.lungfishref")
                    )
                    return vm
                }())

                Divider()

                // Without manifest
                DocumentSection(viewModel: DocumentSectionViewModel())
            }
            .padding()
        }
        .frame(width: 280, height: 800)
    }
}
#endif
