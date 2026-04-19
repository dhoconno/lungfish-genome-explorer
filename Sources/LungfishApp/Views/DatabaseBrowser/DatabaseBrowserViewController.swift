// DatabaseBrowserViewController.swift - Database search and download UI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12), ENA Integration Specialist (Role 13)

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Logger for database browser operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowser")

/// Executes a MainActor-isolated block on the main thread in a way that works during modal sessions.
/// Uses Timer with commonModes run loop mode to ensure execution during modal sheet display.
/// Appends Pathoplexus-specific metadata to a bundle's manifest.
///
/// Reads the existing manifest, creates a new one with appended Pathoplexus metadata group,
/// and writes it back. This preserves all GenBank metadata while adding provenance info.
private func appendPathoplexusMetadata(_ meta: PathoplexusMetadata, organism: String, toBundleAt bundleURL: URL) {
    do {
        let existing = try BundleManifest.load(from: bundleURL)

        // Build Pathoplexus metadata groups

        // Record group
        var recordItems: [MetadataItem] = []
        let ppVersion = meta.accessionVersion ?? meta.accession
        let encodedVersion = ppVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ppVersion
        let ppRecordURL = "https://pathoplexus.org/\(organism)/search?accession=\(encodedVersion)"
        recordItems.append(MetadataItem(label: "Accession", value: meta.accession, url: ppRecordURL))
        if let v = meta.accessionVersion { recordItems.append(MetadataItem(label: "Version", value: v, url: ppRecordURL)) }
        if let v = meta.displayName { recordItems.append(MetadataItem(label: "Display Name", value: v)) }
        if let v = meta.bestINSDCAccession {
            let genbankURL = "https://www.ncbi.nlm.nih.gov/nuccore/\(v)"
            recordItems.append(MetadataItem(label: "INSDC Accession", value: v, url: genbankURL))
        }
        if let v = meta.bioprojectAccession, !v.isEmpty {
            recordItems.append(MetadataItem(label: "BioProject", value: v, url: "https://www.ncbi.nlm.nih.gov/bioproject/\(v)"))
        }
        if let v = meta.biosampleAccession, !v.isEmpty {
            recordItems.append(MetadataItem(label: "BioSample", value: v, url: "https://www.ncbi.nlm.nih.gov/biosample/\(v)"))
        }
        if let v = meta.ncbiSourceDb, !v.isEmpty { recordItems.append(MetadataItem(label: "NCBI Source", value: v)) }
        if let v = meta.dataUseTerms { recordItems.append(MetadataItem(label: "Data Use Terms", value: v)) }
        if let v = meta.versionStatus { recordItems.append(MetadataItem(label: "Version Status", value: v)) }

        // Classification group
        var classItems: [MetadataItem] = []
        if let v = meta.organism { classItems.append(MetadataItem(label: "Organism", value: v)) }
        if let v = meta.ncbiVirusName, !v.isEmpty { classItems.append(MetadataItem(label: "Virus Name", value: v)) }
        if let v = meta.ncbiVirusTaxId {
            classItems.append(MetadataItem(label: "Taxonomy ID", value: "\(v)", url: "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=\(v)"))
        }
        if let v = meta.subtype, !v.isEmpty { classItems.append(MetadataItem(label: "Subtype", value: v)) }
        if let v = meta.clade { classItems.append(MetadataItem(label: "Clade", value: v)) }
        if let v = meta.lineage { classItems.append(MetadataItem(label: "Lineage", value: v)) }

        // Sample group
        var sampleItems: [MetadataItem] = []
        if let v = meta.bestLocation { sampleItems.append(MetadataItem(label: "Location", value: v)) }
        if let v = meta.sampleCollectionDate { sampleItems.append(MetadataItem(label: "Collection Date", value: v)) }
        if let v = meta.hostNameScientific { sampleItems.append(MetadataItem(label: "Host (Scientific)", value: v)) }
        if let v = meta.hostNameCommon { sampleItems.append(MetadataItem(label: "Host (Common)", value: v)) }
        if let v = meta.purposeOfSampling, !v.isEmpty { sampleItems.append(MetadataItem(label: "Sampling Purpose", value: v)) }

        // Sequencing group
        var seqItems: [MetadataItem] = []
        if let v = meta.length { seqItems.append(MetadataItem(label: "Length", value: "\(v) bp")) }
        if let v = meta.sequencedByOrganization, !v.isEmpty { seqItems.append(MetadataItem(label: "Sequencing Lab", value: v)) }
        if let v = meta.sequencingInstrument, !v.isEmpty { seqItems.append(MetadataItem(label: "Instrument", value: v)) }
        if let v = meta.purposeOfSequencing, !v.isEmpty { seqItems.append(MetadataItem(label: "Sequencing Purpose", value: v)) }
        if let n = meta.consensusSequenceSoftwareName, !n.isEmpty {
            let ver = meta.consensusSequenceSoftwareVersion.map { " \($0)" } ?? ""
            seqItems.append(MetadataItem(label: "Consensus Software", value: "\(n)\(ver)"))
        }

        // Quality group
        var qualItems: [MetadataItem] = []
        if let v = meta.depthOfCoverage { qualItems.append(MetadataItem(label: "Depth of Coverage", value: String(format: "%.1fx", v))) }
        if let v = meta.breadthOfCoverage { qualItems.append(MetadataItem(label: "Breadth of Coverage", value: String(format: "%.1f%%", v * 100))) }
        if let v = meta.completeness { qualItems.append(MetadataItem(label: "Completeness", value: String(format: "%.1f%%", v * 100))) }
        if let v = meta.qualityControlDetermination, !v.isEmpty { qualItems.append(MetadataItem(label: "QC Determination", value: v)) }
        if let v = meta.totalSnps, v > 0 { qualItems.append(MetadataItem(label: "Total SNPs", value: "\(v)")) }
        if let v = meta.totalDeletedNucs, v > 0 { qualItems.append(MetadataItem(label: "Total Deletions", value: "\(v)")) }
        if let v = meta.totalInsertedNucs, v > 0 { qualItems.append(MetadataItem(label: "Total Insertions", value: "\(v)")) }
        if let v = meta.totalUnknownNucs, v > 0 { qualItems.append(MetadataItem(label: "Unknown Nucs", value: "\(v)")) }

        // Provenance group
        var provItems: [MetadataItem] = []
        if let v = meta.groupName, !v.isEmpty { provItems.append(MetadataItem(label: "Submitter Group", value: v)) }
        if let v = meta.authors, !v.isEmpty { provItems.append(MetadataItem(label: "Authors", value: v)) }
        if let v = meta.submittedDate { provItems.append(MetadataItem(label: "Submitted", value: v)) }
        if let v = meta.releasedDate { provItems.append(MetadataItem(label: "Released", value: v)) }

        var groups = existing.metadata ?? []
        groups.append(MetadataGroup(name: "Pathoplexus Record", items: recordItems))
        if !classItems.isEmpty { groups.append(MetadataGroup(name: "Classification", items: classItems)) }
        if !sampleItems.isEmpty { groups.append(MetadataGroup(name: "Sample", items: sampleItems)) }
        if !seqItems.isEmpty { groups.append(MetadataGroup(name: "Sequencing", items: seqItems)) }
        if !qualItems.isEmpty { groups.append(MetadataGroup(name: "Quality", items: qualItems)) }
        if !provItems.isEmpty { groups.append(MetadataGroup(name: "Provenance", items: provItems)) }

        // Create updated manifest with Pathoplexus metadata appended
        let updated = BundleManifest(
            formatVersion: existing.formatVersion,
            name: existing.name,
            identifier: existing.identifier,
            description: existing.description,
            createdDate: existing.createdDate,
            modifiedDate: Date(),
            source: existing.source,
            genome: existing.genome,
            annotations: existing.annotations,
            variants: existing.variants,
            tracks: existing.tracks,
            alignments: existing.alignments,
            metadata: groups
        )

        try updated.save(to: bundleURL)
        logger.info("appendPathoplexusMetadata: Added Pathoplexus metadata group to \(bundleURL.lastPathComponent)")
    } catch {
        logger.error("appendPathoplexusMetadata: Failed to append metadata: \(error)")
    }

}

private func performOnMainRunLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
    // Create a timer that fires immediately and runs in common modes (works during modals)
    let timer = Timer(timeInterval: 0, repeats: false) { _ in
        // Timer callback runs on main thread but not in MainActor context
        // We use assumeIsolated since Timer callbacks on main thread are MainActor-safe
        MainActor.assumeIsolated {
            block()
        }
    }
    // Add to run loop with common modes so it fires during modal sessions
    RunLoop.main.add(timer, forMode: .common)
}

/// Controller for the database browser panel.
///
/// Provides search interface for NCBI, SRA (via ENA), and Pathoplexus with download capability.
@MainActor
public class DatabaseBrowserViewController: NSViewController {

    // MARK: - Properties

    /// The database source being browsed
    public let databaseSource: DatabaseSource

    /// The SwiftUI hosting view
    private var hostingView: NSHostingView<DatabaseSearchDialog>!

    /// Shared dialog state backing the hosted SwiftUI dialog.
    private var dialogState: DatabaseSearchDialogState!

    /// Completion handler called when user cancels
    public var onCancel: (() -> Void)?

    /// Called when a download is kicked off (sheet should dismiss immediately).
    public var onDownloadStarted: (() -> Void)?

    /// Optional initial NCBI search type to pre-select when the browser opens.
    ///
    /// Set this before presenting the controller to open with a specific search type
    /// (e.g., `.genome` to focus on assembly-centric NCBI search).
    public var initialSearchType: NCBISearchType?

    // MARK: - Initialization

    /// Creates a new database browser for the specified source.
    ///
    /// - Parameter source: The database source (.ncbi or .ena)
    public init(source: DatabaseSource) {
        self.databaseSource = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func loadView() {
        let automationBackend = DatabaseSearchAutomationBackend(configuration: AppUITestConfiguration.current)

        dialogState = DatabaseSearchDialogState(
            initialDestination: DatabaseSearchDestination(databaseSource: databaseSource),
            automationBackend: automationBackend
        )

        if let searchType = initialSearchType {
            dialogState.genBankGenomesViewModel.ncbiSearchType = searchType
        }

        dialogState.applyCallbacks(
            onCancel: { [weak self] in
                guard let self = self else { return }
                if let window = self.view.window {
                    if let parent = window.sheetParent {
                        parent.endSheet(window)
                    } else {
                        window.close()
                    }
                }
                self.onCancel?()
            },
            onDownloadStarted: { [weak self] in
                guard let self = self else { return }
                self.onDownloadStarted?()
            }
        )

        hostingView = NSHostingView(rootView: DatabaseSearchDialog(state: dialogState))
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("Database browser loaded for \(self.databaseSource.displayName, privacy: .public)")
    }
}

// MARK: - Search Scope

/// Defines what fields the search will query
public enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All Fields"
    case accession = "Accession"
    case organism = "Organism"
    case title = "Title"
    case bioProject = "BioProject"
    case author = "Author"

    public var id: String { rawValue }

    /// SF Symbol for the scope
    var icon: String {
        switch self {
        case .all: return "magnifyingglass"
        case .accession: return "number"
        case .organism: return "leaf"
        case .title: return "text.alignleft"
        case .bioProject: return "folder"
        case .author: return "person.text.rectangle"
        }
    }

    /// Help text explaining what this scope searches
    var helpText: String {
        switch self {
        case .all: return "Searches accession numbers, organism names, titles, and descriptions"
        case .accession: return "Search by accession number (e.g., NC_002549, MN908947)"
        case .organism: return "Search by organism or species name"
        case .title: return "Search within sequence titles and descriptions"
        case .bioProject: return "Search by BioProject accession (e.g., PRJNA989177)"
        case .author: return "Search by submitter or author name"
        }
    }
}

// MARK: - Search Phase

/// Represents the current phase of a search operation for progress tracking.
public enum SearchPhase: Equatable {
    case idle
    case connecting
    case searching
    case loadingDetails
    case loadingAllResults(loaded: Int, total: Int)
    case complete(count: Int)
    case failed(String)

    /// Progress value from 0 to 1
    var progress: Double {
        switch self {
        case .idle: return 0
        case .connecting: return 0.15
        case .searching: return 0.4
        case .loadingDetails: return 0.7
        case .loadingAllResults(let loaded, let total):
            guard total > 0 else { return 0.75 }
            let fraction = min(1.0, max(0.0, Double(loaded) / Double(total)))
            return 0.55 + (0.4 * fraction)
        case .complete: return 1.0
        case .failed: return 0
        }
    }

    /// Status message for the phase
    var message: String {
        switch self {
        case .idle: return ""
        case .connecting: return "Connecting to server..."
        case .searching: return "Searching database..."
        case .loadingDetails: return "Loading record details..."
        case .loadingAllResults(let loaded, let total):
            return "Loading all records from server... \(loaded)/\(total)"
        case .complete(let count):
            return "Found \(count) result\(count == 1 ? "" : "s")"
        case .failed(let error):
            return "Error: \(error)"
        }
    }

    /// Whether the search is in progress
    var isInProgress: Bool {
        switch self {
        case .idle, .complete, .failed: return false
        case .connecting, .searching, .loadingDetails, .loadingAllResults: return true
        }
    }
}

// MARK: - Molecule Type Filter

/// Molecule type options for NCBI nucleotide search filtering.
public enum MoleculeTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case genomicDNA = "Genomic DNA"
    case mRNA = "mRNA"
    case rRNA = "rRNA"
    case tRNA = "tRNA"
    case genomicRNA = "Genomic RNA"
    case crRNA = "crRNA"

    public var id: String { rawValue }

    /// Entrez field value for [Molecule Type] queries
    var entrezValue: String? {
        switch self {
        case .any: return nil
        case .genomicDNA: return "genomic DNA"
        case .mRNA: return "mRNA"
        case .rRNA: return "rRNA"
        case .tRNA: return "tRNA"
        case .genomicRNA: return "genomic RNA"
        case .crRNA: return "crRNA"
        }
    }
}

// MARK: - Sequence Property Filter

/// Property filters for NCBI nucleotide searches (uses [Properties] field).
public enum SequencePropertyFilter: String, CaseIterable, Identifiable, Sendable {
    case hasCDS = "Has CDS"
    case hasGene = "Has Gene"
    case hasSource = "Has Source"
    case hasTRNA = "Has tRNA"
    case hasRRNA = "Has rRNA"

    public var id: String { rawValue }

    /// Entrez filter term for this property
    var entrezFilter: String {
        switch self {
        case .hasCDS: return "cds[Feature key]"
        case .hasGene: return "gene[Feature key]"
        case .hasSource: return "source[Feature key]"
        case .hasTRNA: return "tRNA[Feature key]"
        case .hasRRNA: return "rRNA[Feature key]"
        }
    }

    /// SF Symbol icon for the property
    var icon: String {
        switch self {
        case .hasCDS: return "chevron.left.forwardslash.chevron.right"
        case .hasGene: return "dna"
        case .hasSource: return "leaf"
        case .hasTRNA: return "arrow.triangle.branch"
        case .hasRRNA: return "waveform"
        }
    }
}

// MARK: - Virus Completeness Filter

/// Completeness options for NCBI Datasets v2 virus searches.
public enum VirusCompletenessFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case complete = "Complete"
    case partial = "Partial"

    public var id: String { rawValue }

    /// API value for the `filter.completeness` query parameter, or nil for "Any".
    var apiValue: String? {
        switch self {
        case .any: return nil
        case .complete: return "COMPLETE"
        case .partial: return "PARTIAL"
        }
    }
}

/// INSDC filter options for Pathoplexus results.
public enum PathoplexusINSDCFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case insdcOnly = "INSDC Only"
    case nonINSDCOnly = "Non-INSDC Only"

    public var id: String { rawValue }
}

// MARK: - SRA Filter Enums

/// SRA sequencing platform filter.
public enum SRAPlatformFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case illumina = "ILLUMINA"
    case oxfordNanopore = "OXFORD_NANOPORE"
    case pacbio = "PACBIO_SMRT"
    case ionTorrent = "ION_TORRENT"
    case ultima = "ULTIMA"
    case element = "ELEMENT"
    case bgiseq = "BGISEQ"

    public var id: String { rawValue }

    /// The value to use in NCBI ESearch `[Platform]` queries.
    var entrezValue: String? {
        self == .any ? nil : rawValue
    }
}

/// SRA library strategy filter.
public enum SRAStrategyFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case wgs = "WGS"
    case amplicon = "AMPLICON"
    case rnaSeq = "RNA-Seq"
    case wxs = "WXS"
    case targetedCapture = "Targeted-Capture"
    case other = "OTHER"

    public var id: String { rawValue }

    var entrezValue: String? {
        self == .any ? nil : rawValue
    }
}

/// SRA library layout filter.
public enum SRALayoutFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case paired = "PAIRED"
    case single = "SINGLE"

    public var id: String { rawValue }

    var entrezValue: String? {
        self == .any ? nil : rawValue
    }
}

// MARK: - Result Sort Order

/// Sort options for search results.
enum ResultSortOrder: String, CaseIterable, Identifiable, Sendable {
    case accession = "Accession"
    case dateNewest = "Date (Newest)"
    case dateOldest = "Date (Oldest)"
    case lengthLongest = "Length (Longest)"
    case lengthShortest = "Length (Shortest)"
    case location = "Location"
    case subtype = "Subtype"

    var id: String { rawValue }
}

private enum LargeResultAction {
    case firstThousand
    case loadAll
    case cancel
}

@MainActor
private func confirmLargeResultActionDialog(totalCount: Int, sourceLabel: String) async -> LargeResultAction {
    let alert = NSAlert()
    alert.messageText = "Large Result Set (\(totalCount.formatted()) records)"
    alert.informativeText =
        "\(sourceLabel) returned a large number of records. Loading fewer records is usually faster for you and gentler on shared host database resources.\n\nChoose how many records to load:"
    alert.alertStyle = .informational

    alert.addButton(withTitle: "Load First 1,000")
    alert.addButton(withTitle: "Load All \(totalCount.formatted())")
    alert.addButton(withTitle: "Cancel")

    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        return .cancel
    }
    let response = await alert.beginSheetModal(for: window)
    switch response {
    case .alertFirstButtonReturn:
        return .firstThousand
    case .alertSecondButtonReturn:
        return .loadAll
    default:
        return .cancel
    }
}

// MARK: - DatabaseBrowserViewModel

/// View model for the database browser.
@MainActor
public class DatabaseBrowserViewModel: ObservableObject {
    private let largeResultThreshold = 1_000

    // MARK: - Published Properties

    /// The database source
    let source: DatabaseSource

    /// NCBI search type (GenBank, Genome, Virus)
    @Published var ncbiSearchType: NCBISearchType = .nucleotide

    /// Search query text
    @Published var searchText = ""

    /// Accessions imported from a CSV/text file. Takes precedence over searchText parsing.
    @Published var importedAccessions: [String] = []

    /// Maximum number of SRA results to return for non-accession queries
    @Published var sraResultLimit: Int = 50

    /// Search scope
    @Published var searchScope: SearchScope = .all

    /// Whether advanced search is expanded
    @Published var isAdvancedExpanded = false

    /// Optional organism filter (advanced)
    @Published var organismFilter = ""

    /// Optional location filter (advanced)
    @Published var locationFilter = ""

    /// Optional gene name filter (advanced)
    @Published var geneFilter = ""

    /// Optional author filter (advanced)
    @Published var authorFilter = ""

    /// Optional journal filter (advanced)
    @Published var journalFilter = ""

    /// Minimum sequence length filter
    @Published var minLength: String = ""

    /// Maximum sequence length filter
    @Published var maxLength: String = ""

    /// Whether to filter to RefSeq sequences only (for Virus search)
    @Published var refseqOnly: Bool = false

    /// Molecule type filter (e.g., "genomic DNA", "mRNA")
    @Published var moleculeType: MoleculeTypeFilter = .any

    /// Publication date range: start date
    @Published var pubDateFrom: String = ""

    /// Publication date range: end date
    @Published var pubDateTo: String = ""

    /// Sequence property filters (Has CDS, Has Gene, etc.)
    @Published var propertyFilters: Set<SequencePropertyFilter> = []

    // MARK: Virus-Specific Filters (Datasets v2)

    /// Host organism filter for virus searches (e.g., "Homo sapiens")
    @Published var virusHostFilter: String = ""

    /// Geographic location filter for virus searches (e.g., "USA", "China")
    @Published var virusGeoLocationFilter: String = ""

    /// Completeness filter for virus searches
    @Published var virusCompletenessFilter: VirusCompletenessFilter = .any

    /// Released-since date filter for virus searches (YYYY-MM-DD)
    @Published var virusReleasedSinceFilter: String = ""

    /// Whether to filter to annotated sequences only (virus searches)
    @Published var virusAnnotatedOnly: Bool = false

    /// Opaque page token for Datasets v2 cursor-based pagination
    @Published var virusNextPageToken: String?

    // MARK: SRA-Specific Filters

    /// Platform filter for SRA searches (e.g., ILLUMINA, OXFORD_NANOPORE)
    @Published var sraPlatformFilter: SRAPlatformFilter = .any

    /// Library strategy filter for SRA searches (e.g., WGS, AMPLICON)
    @Published var sraStrategyFilter: SRAStrategyFilter = .any

    /// Library layout filter for SRA searches (e.g., PAIRED, SINGLE)
    @Published var sraLayoutFilter: SRALayoutFilter = .any

    /// Minimum dataset size in megabases for SRA searches
    @Published var sraMinMbases: String = ""

    /// Publication date range for SRA searches: start date
    @Published var sraPubDateFrom: String = ""

    /// Publication date range for SRA searches: end date
    @Published var sraPubDateTo: String = ""

    /// Search results from the API
    @Published var results: [SearchResultRecord] = []

    /// Local filter text for filtering displayed results without re-querying the API
    @Published var localFilterText: String = ""

    /// Whether advanced result filters are expanded
    @Published var isResultFilterExpanded: Bool = false

    // MARK: Advanced Result Filters (client-side)

    /// Collection date range filter (YYYY-MM-DD)
    @Published var resultCollectionDateFrom: String = ""
    @Published var resultCollectionDateTo: String = ""

    /// Sequence length range filter
    @Published var resultMinLength: String = ""
    @Published var resultMaxLength: String = ""

    /// Host filter (substring match)
    @Published var resultHostFilter: String = ""

    /// Geographic location filter (substring match)
    @Published var resultGeoLocationFilter: String = ""

    /// Completeness filter
    @Published var resultCompletenessFilter: VirusCompletenessFilter = .any

    /// Pangolin classification filter (substring match)
    @Published var resultPangolinFilter: String = ""

    /// Source database filter (e.g., "RefSeq", "GenBank")
    @Published var resultSourceDatabaseFilter: String = ""

    /// Whether any advanced result filters are active
    var hasActiveResultFilters: Bool {
        !resultCollectionDateFrom.isEmpty || !resultCollectionDateTo.isEmpty ||
        !resultMinLength.isEmpty || !resultMaxLength.isEmpty ||
        !resultHostFilter.isEmpty || !resultGeoLocationFilter.isEmpty ||
        resultCompletenessFilter != .any ||
        !resultPangolinFilter.isEmpty || !resultSourceDatabaseFilter.isEmpty
    }

    /// Clears all advanced result filters
    func clearResultFilters() {
        resultCollectionDateFrom = ""
        resultCollectionDateTo = ""
        resultMinLength = ""
        resultMaxLength = ""
        resultHostFilter = ""
        resultGeoLocationFilter = ""
        resultCompletenessFilter = .any
        resultPangolinFilter = ""
        resultSourceDatabaseFilter = ""
        localFilterText = ""
    }

    /// Sort order for results
    @Published var resultSortOrder: ResultSortOrder = .accession

    /// Filtered and sorted results based on localFilterText, advanced filters, and resultSortOrder
    var filteredResults: [SearchResultRecord] {
        var filtered = results

        // Text search filter (substring across multiple fields)
        if !localFilterText.isEmpty {
            let filter = localFilterText.lowercased()
            filtered = filtered.filter { record in
                record.accession.lowercased().contains(filter) ||
                record.title.lowercased().contains(filter) ||
                (record.organism?.lowercased().contains(filter) ?? false) ||
                (record.host?.lowercased().contains(filter) ?? false) ||
                (record.geoLocation?.lowercased().contains(filter) ?? false) ||
                (record.isolateName?.lowercased().contains(filter) ?? false) ||
                (record.pangolinClassification?.lowercased().contains(filter) ?? false) ||
                (record.subtype?.lowercased().contains(filter) ?? false)
            }
        }

        // Advanced result filters (AND logic)
        if !resultCollectionDateFrom.isEmpty {
            let from = resultCollectionDateFrom
            filtered = filtered.filter { ($0.collectionDate ?? "") >= from }
        }
        if !resultCollectionDateTo.isEmpty {
            let to = resultCollectionDateTo
            filtered = filtered.filter { ($0.collectionDate ?? "9999") <= to }
        }
        if let min = Int(resultMinLength) {
            filtered = filtered.filter { ($0.length ?? 0) >= min }
        }
        if let max = Int(resultMaxLength) {
            filtered = filtered.filter { ($0.length ?? Int.max) <= max }
        }
        if !resultHostFilter.isEmpty {
            let host = resultHostFilter.lowercased()
            filtered = filtered.filter { $0.host?.lowercased().contains(host) ?? false }
        }
        if !resultGeoLocationFilter.isEmpty {
            let geo = resultGeoLocationFilter.lowercased()
            filtered = filtered.filter { $0.geoLocation?.lowercased().contains(geo) ?? false }
        }
        if resultCompletenessFilter != .any {
            let target = resultCompletenessFilter.apiValue?.uppercased()
            filtered = filtered.filter { $0.completeness?.uppercased() == target }
        }
        if !resultPangolinFilter.isEmpty {
            let pango = resultPangolinFilter.lowercased()
            filtered = filtered.filter { $0.pangolinClassification?.lowercased().contains(pango) ?? false }
        }
        if !resultSourceDatabaseFilter.isEmpty {
            let src = resultSourceDatabaseFilter.lowercased()
            filtered = filtered.filter { $0.sourceDatabase?.lowercased().contains(src) ?? false }
        }
        switch resultSortOrder {
        case .accession:
            return filtered // default API order
        case .dateNewest:
            return filtered.sorted {
                switch ($0.collectionDate, $1.collectionDate) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return a > b
                }
            }
        case .dateOldest:
            return filtered.sorted {
                switch ($0.collectionDate, $1.collectionDate) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case let (a?, b?): return a < b
                }
            }
        case .lengthLongest:
            return filtered.sorted { ($0.length ?? -1) > ($1.length ?? -1) }
        case .lengthShortest:
            return filtered.sorted { ($0.length ?? Int.max) < ($1.length ?? Int.max) }
        case .location:
            return filtered.sorted { ($0.geoLocation ?? "zzz") < ($1.geoLocation ?? "zzz") }
        case .subtype:
            return filtered.sorted { ($0.subtype ?? "zzz") < ($1.subtype ?? "zzz") }
        }
    }

    /// Total count of results from the database (may be larger than results.count)
    @Published var totalResultCount: Int = 0

    /// Whether there are more results available to load
    @Published var hasMoreResults: Bool = false

    /// Currently selected record (for single selection compatibility)
    @Published var selectedRecord: SearchResultRecord?

    /// Set of selected records (for multi-select)
    @Published var selectedRecords: Set<SearchResultRecord> = []

    /// Current search phase (for progress tracking)
    @Published var searchPhase: SearchPhase = .idle

    /// Whether a search is in progress (computed from searchPhase)
    var isSearching: Bool {
        searchPhase.isInProgress
    }

    /// Whether a download is in progress
    @Published var isDownloading = false

    /// Error message to display
    @Published var errorMessage: String?

    /// Download progress (0-1)
    @Published var downloadProgress: Double = 0

    /// Status message derived from current search phase
    var statusMessage: String? {
        searchPhase == .idle ? nil : searchPhase.message
    }

    /// Current search task (for cancellation support)
    private var currentSearchTask: Task<Void, Never>?

    /// Search history for autocomplete suggestions
    @Published var searchHistory: [String] = []

    /// Autocomplete suggestions filtered from search history
    var autocompleteSuggestions: [String] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return searchHistory.filter { $0.lowercased().hasPrefix(query) && $0.lowercased() != query }
            .prefix(5)
            .map { $0 }
    }

    /// UserDefaults key for search history
    private static let searchHistoryKey = "DatabaseBrowserSearchHistory"

    /// Maximum number of search history entries to keep
    private static let maxHistoryEntries = 50

    // MARK: - Computed Properties

    /// Whether search text is valid (non-empty after trimming, or any text for Pathoplexus which allows browsing)
    var isSearchTextValid: Bool {
        // Pathoplexus allows browsing all records without a search term
        if isPathoplexusSearch { return true }
        return !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Count of active advanced filters
    var activeFilterCount: Int {
        if isPathoplexusSearch {
            return pathoplexusActiveFilterCount
        }
        var count = 0
        if ncbiSearchType == .virus {
            // Virus-specific filters (Datasets v2)
            if !virusHostFilter.isEmpty { count += 1 }
            if !virusGeoLocationFilter.isEmpty { count += 1 }
            if virusCompletenessFilter != .any { count += 1 }
            if !virusReleasedSinceFilter.isEmpty { count += 1 }
            if virusAnnotatedOnly { count += 1 }
            if refseqOnly { count += 1 }
        } else if isSRASearch {
            // SRA-specific filters
            if sraPlatformFilter != .any { count += 1 }
            if sraStrategyFilter != .any { count += 1 }
            if sraLayoutFilter != .any { count += 1 }
            if !sraMinMbases.isEmpty { count += 1 }
            if !sraPubDateFrom.isEmpty || !sraPubDateTo.isEmpty { count += 1 }
        } else {
            // Entrez-based filters (nucleotide, genome)
            if !organismFilter.isEmpty { count += 1 }
            if !locationFilter.isEmpty { count += 1 }
            if !geneFilter.isEmpty { count += 1 }
            if !authorFilter.isEmpty { count += 1 }
            if !journalFilter.isEmpty { count += 1 }
            if !minLength.isEmpty || !maxLength.isEmpty { count += 1 }
            if refseqOnly && ncbiSearchType == .nucleotide { count += 1 }
            if moleculeType != .any { count += 1 }
            if !pubDateFrom.isEmpty || !pubDateTo.isEmpty { count += 1 }
            count += propertyFilters.count
        }
        return count
    }

    /// Whether any advanced filter is active
    var hasActiveFilters: Bool {
        activeFilterCount > 0
    }

    /// Whether we're searching NCBI (as opposed to ENA/SRA)
    var isNCBISearch: Bool {
        source == .ncbi
    }

    /// Whether we're searching SRA for FASTQ data
    var isSRASearch: Bool {
        source == .ena  // ENA is used for SRA/FASTQ downloads
    }

    // MARK: - Callbacks

    /// Called when user cancels
    var onCancel: (() -> Void)?

    /// Called when a download is kicked off so the sheet can dismiss immediately.
    var onDownloadStarted: (() -> Void)?

    // MARK: - Pathoplexus-Specific Properties

    /// Selected organism for Pathoplexus searches
    @Published var pathoplexusOrganism: PathoplexusOrganism?

    /// All available Pathoplexus organisms
    let pathoplexusOrganisms: [PathoplexusOrganism] = [
        PathoplexusOrganism(id: "cchf", displayName: "Crimean-Congo hemorrhagic fever", segmented: true, segments: ["S", "M", "L"]),
        PathoplexusOrganism(id: "ebola-sudan", displayName: "Sudan ebolavirus", segmented: false, segments: nil),
        PathoplexusOrganism(id: "ebola-zaire", displayName: "Zaire ebolavirus", segmented: false, segments: nil),
        PathoplexusOrganism(id: "hmpv", displayName: "Human metapneumovirus", segmented: false, segments: nil),
        PathoplexusOrganism(id: "marburg", displayName: "Marburg virus", segmented: false, segments: nil),
        PathoplexusOrganism(id: "measles", displayName: "Measles virus", segmented: false, segments: nil),
        PathoplexusOrganism(id: "mpox", displayName: "Mpox virus", segmented: false, segments: nil),
        PathoplexusOrganism(id: "rsv-a", displayName: "RSV-A", segmented: false, segments: nil),
        PathoplexusOrganism(id: "rsv-b", displayName: "RSV-B", segmented: false, segments: nil),
        PathoplexusOrganism(id: "west-nile", displayName: "West Nile virus", segmented: false, segments: nil)
    ]

    /// Country filter for Pathoplexus
    @Published var pathoplexusCountryFilter: String = ""

    /// Clade filter for Pathoplexus
    @Published var pathoplexusCladeFilter: String = ""

    /// Lineage filter for Pathoplexus
    @Published var pathoplexusLineageFilter: String = ""

    /// Host filter for Pathoplexus
    @Published var pathoplexusHostFilter: String = ""

    /// Nucleotide mutations filter for Pathoplexus (comma-separated, e.g. "C180T,A200G")
    @Published var pathoplexusNucMutationsFilter: String = ""

    /// Amino acid mutations filter for Pathoplexus (comma-separated, e.g. "GP:440G")
    @Published var pathoplexusAAMutationsFilter: String = ""

    /// INSDC source filter for Pathoplexus results.
    @Published var pathoplexusINSDCFilter: PathoplexusINSDCFilter = .any

    /// Collection date from for Pathoplexus
    @Published var pathoplexusDateFrom: String = ""

    /// Collection date to for Pathoplexus
    @Published var pathoplexusDateTo: String = ""

    /// Whether the user has accepted the Pathoplexus ABS consent
    @Published var hasAcceptedPathoplexusConsent: Bool = UserDefaults.standard.bool(forKey: "PathoplexusABSConsentAccepted")

    /// Whether we're showing the ABS consent screen
    var isShowingPathoplexusConsent: Bool {
        source == .pathoplexus && !hasAcceptedPathoplexusConsent
    }

    /// Whether this is a Pathoplexus search
    var isPathoplexusSearch: Bool {
        source == .pathoplexus
    }

    /// Accepts the Pathoplexus ABS consent
    func acceptPathoplexusConsent() {
        hasAcceptedPathoplexusConsent = true
        UserDefaults.standard.set(true, forKey: "PathoplexusABSConsentAccepted")
    }

    /// Active filter count for Pathoplexus
    var pathoplexusActiveFilterCount: Int {
        var count = 0
        if !pathoplexusCountryFilter.isEmpty { count += 1 }
        if !pathoplexusCladeFilter.isEmpty { count += 1 }
        if !pathoplexusLineageFilter.isEmpty { count += 1 }
        if !pathoplexusHostFilter.isEmpty { count += 1 }
        if !pathoplexusNucMutationsFilter.isEmpty { count += 1 }
        if !pathoplexusAAMutationsFilter.isEmpty { count += 1 }
        if !pathoplexusDateFrom.isEmpty || !pathoplexusDateTo.isEmpty { count += 1 }
        if !minLength.isEmpty || !maxLength.isEmpty { count += 1 }
        if pathoplexusINSDCFilter != .any { count += 1 }
        return count
    }

    /// Clears Pathoplexus-specific filters
    func clearPathoplexusFilters() {
        pathoplexusCountryFilter = ""
        pathoplexusCladeFilter = ""
        pathoplexusLineageFilter = ""
        pathoplexusHostFilter = ""
        pathoplexusNucMutationsFilter = ""
        pathoplexusAAMutationsFilter = ""
        pathoplexusDateFrom = ""
        pathoplexusDateTo = ""
        pathoplexusINSDCFilter = .any
        minLength = ""
        maxLength = ""
    }

    // MARK: - Services

    private let ncbiService = NCBIService()
    private let enaService = ENAService()
    private let automationBackend: DatabaseSearchAutomationBackend?

    /// View model for genome assembly downloads (FASTA + GFF3 + bundle building).
    private lazy var genomeDownloadViewModel = GenomeDownloadViewModel(ncbiService: ncbiService)

    /// View model for GenBank nucleotide downloads to .lungfishref bundles.
    private lazy var genBankDownloadViewModel = GenBankBundleDownloadViewModel(ncbiService: ncbiService)

    // MARK: - Initialization

    init(source: DatabaseSource, automationBackend: DatabaseSearchAutomationBackend? = nil) {
        self.source = source
        self.automationBackend = automationBackend
        loadSearchHistory()
    }

    // MARK: - Search History

    /// Loads search history from UserDefaults
    private func loadSearchHistory() {
        if let history = UserDefaults.standard.stringArray(forKey: Self.searchHistoryKey) {
            searchHistory = history
        }
    }

    /// Saves a search term to history
    func saveSearchTerm(_ term: String) {
        let trimmedTerm = term.trimmingCharacters(in: .whitespaces)
        guard !trimmedTerm.isEmpty else { return }

        // Remove if already exists (to move to front)
        searchHistory.removeAll { $0 == trimmedTerm }

        // Add to front
        searchHistory.insert(trimmedTerm, at: 0)

        // Trim to max entries
        if searchHistory.count > Self.maxHistoryEntries {
            searchHistory = Array(searchHistory.prefix(Self.maxHistoryEntries))
        }

        // Save to UserDefaults
        UserDefaults.standard.set(searchHistory, forKey: Self.searchHistoryKey)
    }

    /// Clears search history
    func clearSearchHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: Self.searchHistoryKey)
    }

    // MARK: - Actions

    /// Clears all advanced filters
    func clearFilters() {
        // Entrez filters
        organismFilter = ""
        locationFilter = ""
        geneFilter = ""
        authorFilter = ""
        journalFilter = ""
        minLength = ""
        maxLength = ""
        refseqOnly = false
        moleculeType = .any
        pubDateFrom = ""
        pubDateTo = ""
        propertyFilters = []
        // Virus Datasets v2 filters
        virusHostFilter = ""
        virusGeoLocationFilter = ""
        virusCompletenessFilter = .any
        virusReleasedSinceFilter = ""
        virusAnnotatedOnly = false
        // SRA filters
        sraPlatformFilter = .any
        sraStrategyFilter = .any
        sraLayoutFilter = .any
        sraMinMbases = ""
        sraPubDateFrom = ""
        sraPubDateTo = ""
        importedAccessions = []
        // Pathoplexus filters
        clearPathoplexusFilters()
    }

    /// Imports accession list from a CSV or text file.
    /// Opens NSOpenPanel, parses the file, and triggers batch search.
    func importAccessionList() {
        let panel = NSOpenPanel()
        panel.title = "Import Accession List"
        panel.allowedContentTypes = [
            .commaSeparatedText,
            .plainText,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let accessions = try SRAAccessionParser.parseCSVFile(at: url)
            if accessions.isEmpty {
                let alert = NSAlert()
                alert.messageText = "No Valid Accessions"
                alert.informativeText = "No valid SRA accessions were found in the selected file."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            logger.info("importAccessionList: Parsed \(accessions.count) accessions from \(url.lastPathComponent)")

            importedAccessions = accessions
            searchText = "\(accessions.count) accessions from \(url.lastPathComponent)"
            searchScope = .accession
            performSearch()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = "Could not read the file: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Cancels the current search operation
    func cancelSearch() {
        currentSearchTask?.cancel()
        currentSearchTask = nil
        searchPhase = .idle
    }

    /// Initiates a search operation.
    ///
    /// Uses Task.detached to run the async search on a background executor,
    /// allowing the search to proceed even when presented in a modal sheet.
    /// This is necessary because Task {} inherits MainActor isolation and
    /// may not execute properly during modal sheet sessions.
    func performSearch() {
        guard isSearchTextValid else {
            errorMessage = "Please enter a search term"
            return
        }

        // Save search term to history for autocomplete
        saveSearchTerm(searchText)

        // Cancel any existing search
        cancelSearch()

        // Reset state
        searchPhase = .connecting
        errorMessage = nil
        results = []
        selectedRecords = []

        if let automationBackend {
            let currentSource = source
            let currentSearchType = ncbiSearchType
            let currentSearchText = searchText

            // Match the live path's detached execution so UI-test searches still
            // progress reliably while the browser is presented in a modal sheet.
            currentSearchTask = Task.detached { [weak self] in
                do {
                    let response = try await automationBackend.search(
                        DatabaseSearchAutomationRequest(
                            source: currentSource,
                            ncbiSearchType: currentSearchType,
                            searchText: currentSearchText
                        )
                    )

                    await MainActor.run {
                        guard let self else { return }
                        self.errorMessage = nil
                        self.results = response.records
                        self.selectedRecord = nil
                        self.selectedRecords = []
                        self.totalResultCount = response.totalCount
                        self.hasMoreResults = response.hasMore
                        self.searchPhase = .complete(count: response.records.count)
                        self.currentSearchTask = nil
                    }
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.errorMessage = error.localizedDescription
                        self.searchPhase = .failed(error.localizedDescription)
                        self.currentSearchTask = nil
                    }
                }
            }
            return
        }

        logger.info("performSearch: Starting search task")

        // Capture values we need for the search (value types are safe to capture)
        let searchTerm = buildSearchTerm(
            for: ncbiSearchType,
            includeRefSeqFilter: refseqOnly
        )
        logger.info("performSearch: Built search term: '\(searchTerm, privacy: .public)'")
        logger.info("performSearch: Search scope: \(self.searchScope.rawValue, privacy: .public)")

        let query = SearchQuery(
            term: searchTerm,
            organism: nil,
            location: nil,
            minLength: Int(minLength),
            maxLength: Int(maxLength),
            limit: 200  // Increased from 50 to show more results
        )
        let currentSource = source
        let searchType = ncbiSearchType
        let useRefseqOnly = refseqOnly

        // Capture virus-specific filters for Datasets v2 API
        // For virus search, the taxon is the raw search text (not the Entrez-qualified term)
        let virusTaxon = searchText.trimmingCharacters(in: .whitespaces)
        let capturedVirusHost = virusHostFilter.trimmingCharacters(in: .whitespaces)
        let capturedVirusGeoLocation = virusGeoLocationFilter.trimmingCharacters(in: .whitespaces)
        let capturedVirusCompleteness = virusCompletenessFilter.apiValue
        let capturedVirusReleasedSince = virusReleasedSinceFilter.trimmingCharacters(in: .whitespaces)
        let capturedVirusAnnotatedOnly = virusAnnotatedOnly

        // Capture Pathoplexus-specific filters (use raw searchText, not NCBI-formatted term)
        let capturedPpOrganism = pathoplexusOrganism
        let capturedPpSearchText = searchText.trimmingCharacters(in: .whitespaces)
        let capturedPpCountry = pathoplexusCountryFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpClade = pathoplexusCladeFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpLineage = pathoplexusLineageFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpHost = pathoplexusHostFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpNucMutations = pathoplexusNucMutationsFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpAAMutations = pathoplexusAAMutationsFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpDateFrom = pathoplexusDateFrom.trimmingCharacters(in: .whitespaces)
        let capturedPpDateTo = pathoplexusDateTo.trimmingCharacters(in: .whitespaces)
        let capturedPpMinLength = Int(minLength)
        let capturedPpMaxLength = Int(maxLength)
        let capturedPpINSDCFilter = pathoplexusINSDCFilter
        let largeResultThreshold = self.largeResultThreshold

        // Capture SRA-specific filters
        let capturedSRAPlatform: SRAPlatformFilter? = isSRASearch ? sraPlatformFilter : nil
        let capturedSRAStrategy: SRAStrategyFilter? = isSRASearch ? sraStrategyFilter : nil
        let capturedSRALayout: SRALayoutFilter? = isSRASearch ? sraLayoutFilter : nil
        let capturedSRAMinMbases: String? = isSRASearch ? sraMinMbases.trimmingCharacters(in: .whitespaces) : nil
        let capturedSRAPubDateFrom: String? = isSRASearch ? sraPubDateFrom.trimmingCharacters(in: .whitespaces) : nil
        let capturedSRAPubDateTo: String? = isSRASearch ? sraPubDateTo.trimmingCharacters(in: .whitespaces) : nil
        let capturedImportedAccessions = importedAccessions
        importedAccessions = []  // Clear after capture to prevent stale reuse on next search
        let capturedSRAResultLimit = isSRASearch ? sraResultLimit : 200

        // Capture services as they are actors (safe to use across isolation boundaries)
        let ncbi = ncbiService
        let ena = enaService


        // Use Task.detached to break out of MainActor context.
        // This is critical when running in a modal sheet - regular Task {}
        // inherits MainActor isolation and may not execute due to the modal
        // run loop blocking task scheduling on MainActor.
        currentSearchTask = Task.detached { [weak self] in
            logger.info("performSearch: Task running, source=\(currentSource.displayName, privacy: .public), searchType=\(searchType.rawValue, privacy: .public)")
            logger.info("performSearch: Query term='\(query.term, privacy: .public)', organism='\(query.organism ?? "nil", privacy: .public)'")

            do {
                try Task.checkCancellation()

                // Update UI using performOnMainRunLoop for modal sheet compatibility
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.objectWillChange.send()
                    self.searchPhase = .searching
                }

                var searchResults: SearchResults

                switch currentSource {
                case .ncbi:
                    performOnMainRunLoop { [weak self] in
                        guard let self = self else { return }
                        self.objectWillChange.send()
                        self.searchPhase = .loadingDetails
                    }

                    // Use the appropriate search method based on search type
                    switch searchType {
                    case .nucleotide:
                        logger.info("performSearch: Calling NCBI nucleotide search (refseqOnly=\(useRefseqOnly))")
                        let pageSize = 200
                        var currentOffset = query.offset
                        var totalCount: Int?
                        var targetCount: Int?
                        var allRecords: [SearchResultRecord] = []

                        while true {
                            try Task.checkCancellation()
                            let page = try await ncbi.searchNucleotide(
                                term: query.term,
                                retmax: pageSize,
                                retstart: currentOffset,
                                refseqOnly: useRefseqOnly
                            )

                            if totalCount == nil {
                                totalCount = page.totalCount
                                logger.info("performSearch: Nucleotide total count = \(page.totalCount)")

                                if page.totalCount > largeResultThreshold {
                                    let action = await confirmLargeResultActionDialog(
                                            totalCount: page.totalCount,
                                            sourceLabel: "NCBI GenBank"
                                        )
                                    switch action {
                                    case .cancel:
                                        throw CancellationError()
                                    case .firstThousand:
                                        targetCount = min(largeResultThreshold, page.totalCount)
                                    case .loadAll:
                                        targetCount = page.totalCount
                                    }
                                } else {
                                    targetCount = page.totalCount
                                }
                            }

                            guard !page.ids.isEmpty else { break }

                            let summaries = try await ncbi.esummary(database: .nucleotide, ids: page.ids)
                            let pageRecords = summaries.map { summary in
                                SearchResultRecord(
                                    id: summary.uid,
                                    accession: summary.accessionVersion ?? summary.uid,
                                    title: summary.title ?? "Unknown",
                                    organism: summary.organism,
                                    length: summary.length,
                                    date: summary.createDate,
                                    source: .ncbi
                                )
                            }
                            allRecords.append(contentsOf: pageRecords)
                            currentOffset += page.ids.count

                            let loadedSnapshot = allRecords.count
                            let totalSnapshot = targetCount ?? totalCount ?? loadedSnapshot
                            let recordsSnapshot = allRecords
                            performOnMainRunLoop { [weak self] in
                                guard let self = self else { return }
                                self.objectWillChange.send()
                                self.results = recordsSnapshot
                                self.totalResultCount = totalSnapshot
                                self.hasMoreResults = loadedSnapshot < totalSnapshot
                                self.searchPhase = .loadingAllResults(loaded: loadedSnapshot, total: totalSnapshot)
                            }

                            if currentOffset >= (totalCount ?? 0) {
                                break
                            }
                            if currentOffset >= (targetCount ?? .max) {
                                break
                            }
                        }

                        let resolvedTotal = targetCount ?? totalCount ?? allRecords.count
                        searchResults = SearchResults(
                            totalCount: resolvedTotal,
                            records: Array(allRecords.prefix(resolvedTotal)),
                            hasMore: false,
                            nextCursor: nil
                        )

                    case .virus:
                        // Use NCBI Datasets v2 API for rich virus metadata
                        logger.info("performSearch: Calling NCBI Datasets v2 virus search for taxon='\(virusTaxon, privacy: .public)'")
                        searchResults = try await ncbi.searchVirusDatasets(
                            taxon: virusTaxon,
                            pageSize: query.limit,
                            pageToken: nil,
                            refseqOnly: useRefseqOnly,
                            annotatedOnly: capturedVirusAnnotatedOnly,
                            completeness: capturedVirusCompleteness,
                            host: capturedVirusHost.isEmpty ? nil : capturedVirusHost,
                            geoLocation: capturedVirusGeoLocation.isEmpty ? nil : capturedVirusGeoLocation,
                            releasedSince: capturedVirusReleasedSince.isEmpty ? nil : capturedVirusReleasedSince
                        )
                        logger.info("performSearch: Datasets v2 virus search returned \(searchResults.totalCount) total, \(searchResults.records.count) records")

                        // Store the page token for "Load More" pagination
                        let nextToken = searchResults.nextCursor
                        performOnMainRunLoop { [weak self] in
                            self?.virusNextPageToken = nextToken
                        }

                        guard !searchResults.records.isEmpty else {
                            performOnMainRunLoop { [weak self] in
                                self?.objectWillChange.send()
                                self?.results = []
                                self?.totalResultCount = searchResults.totalCount
                                self?.hasMoreResults = false
                                self?.searchPhase = .complete(count: 0)
                            }
                            return
                        }

                    case .genome:
                        // Search assemblies progressively (load all pages)
                        logger.info("performSearch: Calling NCBI genome search")
                        let pageSize = 200
                        var currentOffset = query.offset
                        var totalCount: Int?
                        var targetCount: Int?
                        var allRecords: [SearchResultRecord] = []

                        while true {
                            try Task.checkCancellation()
                            let page = try await ncbi.searchGenome(
                                term: query.term,
                                retmax: pageSize,
                                retstart: currentOffset
                            )

                            if totalCount == nil {
                                totalCount = page.totalCount
                                logger.info("performSearch: Genome total count = \(page.totalCount)")

                                if page.totalCount > largeResultThreshold {
                                    let action = await confirmLargeResultActionDialog(
                                            totalCount: page.totalCount,
                                            sourceLabel: "NCBI Assembly"
                                        )
                                    switch action {
                                    case .cancel:
                                        throw CancellationError()
                                    case .firstThousand:
                                        targetCount = min(largeResultThreshold, page.totalCount)
                                    case .loadAll:
                                        targetCount = page.totalCount
                                    }
                                } else {
                                    targetCount = page.totalCount
                                }
                            }

                            guard !page.ids.isEmpty else { break }

                            let assemblySummaries = try await ncbi.assemblyEsummary(ids: page.ids)
                            let pageRecords = assemblySummaries.map { summary in
                                SearchResultRecord(
                                    id: summary.uid,
                                    accession: summary.assemblyAccession ?? summary.uid,
                                    title: summary.assemblyName ?? "Assembly",
                                    organism: summary.organism ?? summary.speciesName,
                                    length: summary.contigN50,  // Use N50 as a proxy for size
                                    date: nil,
                                    source: .ncbi
                                )
                            }
                            allRecords.append(contentsOf: pageRecords)
                            currentOffset += page.ids.count

                            let loadedSnapshot = allRecords.count
                            let totalSnapshot = targetCount ?? totalCount ?? loadedSnapshot
                            let recordsSnapshot = allRecords
                            performOnMainRunLoop { [weak self] in
                                guard let self = self else { return }
                                self.objectWillChange.send()
                                self.results = recordsSnapshot
                                self.totalResultCount = totalSnapshot
                                self.hasMoreResults = loadedSnapshot < totalSnapshot
                                self.searchPhase = .loadingAllResults(loaded: loadedSnapshot, total: totalSnapshot)
                            }

                            if currentOffset >= (totalCount ?? 0) {
                                break
                            }
                            if currentOffset >= (targetCount ?? .max) {
                                break
                            }
                        }

                        let resolvedTotal = targetCount ?? totalCount ?? allRecords.count
                        searchResults = SearchResults(
                            totalCount: resolvedTotal,
                            records: Array(allRecords.prefix(resolvedTotal)),
                            hasMore: false,
                            nextCursor: nil
                        )
                    }

                case .ena:
                    performOnMainRunLoop { [weak self] in
                        guard let self = self else { return }
                        self.objectWillChange.send()
                        self.searchPhase = .searching
                    }

                    let records: [SearchResultRecord]

                    // Detect multi-accession input (paste or CSV import)
                    // Check for imported accession list first (from CSV import)
                    let parsedAccessions = !capturedImportedAccessions.isEmpty
                        ? capturedImportedAccessions
                        : SRAAccessionParser.parseAccessionList(query.term)
                    if parsedAccessions.count >= 2 {
                        // Batch mode: multiple accessions pasted or imported
                        logger.info("performSearch: Batch mode with \(parsedAccessions.count) accessions")
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.objectWillChange.send()
                            self.searchPhase = .loadingDetails
                        }

                        let readRecords = try await ena.searchReadsBatch(
                            accessions: parsedAccessions,
                            concurrency: 10,
                            progress: { [weak self] completed, total in
                                performOnMainRunLoop { [weak self] in
                                    guard let self = self else { return }
                                    self.objectWillChange.send()
                                    self.searchPhase = .loadingAllResults(loaded: completed, total: total)
                                }
                            }
                        )
                        records = readRecords.map { record in
                            SearchResultRecord(
                                id: record.runAccession,
                                accession: record.runAccession,
                                title: record.experimentTitle ?? "\(record.runAccession) - \(record.libraryStrategy ?? "Unknown") \(record.libraryLayout ?? "")",
                                organism: nil,
                                length: record.baseCount,
                                date: record.firstPublic,
                                source: .ena
                            )
                        }

                    } else if SRAAccessionParser.isSRAAccession(query.term.trimmingCharacters(in: .whitespaces)) {
                        // Single accession: direct ENA filereport (fast path)
                        logger.info("performSearch: Direct ENA lookup for single accession")
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.objectWillChange.send()
                            self.searchPhase = .loadingDetails
                        }
                        let readRecords = try await ena.searchReads(term: query.term, limit: query.limit, offset: query.offset)
                        records = readRecords.map { record in
                            SearchResultRecord(
                                id: record.runAccession,
                                accession: record.runAccession,
                                title: record.experimentTitle ?? "\(record.runAccession) - \(record.libraryStrategy ?? "Unknown") \(record.libraryLayout ?? "")",
                                organism: nil,
                                length: record.baseCount,
                                date: record.firstPublic,
                                source: .ena
                            )
                        }

                    } else {
                        // Non-accession query (title, organism, bioproject, author, free text)
                        // Two-step: NCBI ESearch → EFetch run accessions → ENA batch lookup
                        logger.info("performSearch: Two-step NCBI ESearch → ENA for non-accession query")

                        // Step 1: Build SRA search term with advanced filters
                        var sraClauses: [String] = [query.term]
                        if let platformValue = capturedSRAPlatform?.entrezValue {
                            sraClauses.append("\(platformValue)[Platform]")
                        }
                        if let strategyValue = capturedSRAStrategy?.entrezValue {
                            sraClauses.append("\(strategyValue)[Strategy]")
                        }
                        if let layoutValue = capturedSRALayout?.entrezValue {
                            sraClauses.append("\(layoutValue)[Layout]")
                        }
                        if let minMb = capturedSRAMinMbases, !minMb.isEmpty, let mbVal = Int(minMb) {
                            sraClauses.append("\(mbVal):*[Mbases]")
                        }
                        let sraDateFrom = capturedSRAPubDateFrom ?? ""
                        let sraDateTo = capturedSRAPubDateTo ?? ""
                        if !sraDateFrom.isEmpty || !sraDateTo.isEmpty {
                            let lower = sraDateFrom.isEmpty ? "1900/01/01" : sraDateFrom
                            let upper = sraDateTo.isEmpty ? "3000/12/31" : sraDateTo
                            sraClauses.append("\(lower):\(upper)[Publication Date]")
                        }
                        let sraSearchTerm = sraClauses.joined(separator: " AND ")
                        logger.info("performSearch: SRA ESearch term = '\(sraSearchTerm, privacy: .public)'")

                        var esearchResult = try await ncbi.sraESearch(term: sraSearchTerm, retmax: capturedSRAResultLimit)
                        logger.info("performSearch: ESearch returned \(esearchResult.ids.count) UIDs out of \(esearchResult.totalCount) total")

                        guard !esearchResult.ids.isEmpty else {
                            searchResults = SearchResults(totalCount: 0, records: [], hasMore: false, nextCursor: nil)
                            break
                        }

                        // Large result set confirmation
                        if esearchResult.totalCount > capturedSRAResultLimit {
                            let action = await confirmLargeResultActionDialog(
                                totalCount: esearchResult.totalCount,
                                sourceLabel: "NCBI SRA"
                            )
                            switch action {
                            case .cancel:
                                throw CancellationError()
                            case .firstThousand:
                                let expandedLimit = min(1_000, esearchResult.totalCount)
                                esearchResult = try await ncbi.sraESearch(term: sraSearchTerm, retmax: expandedLimit)
                                logger.info("performSearch: Re-fetched ESearch with limit \(expandedLimit), got \(esearchResult.ids.count) UIDs")
                            case .loadAll:
                                esearchResult = try await ncbi.sraESearch(term: sraSearchTerm, retmax: esearchResult.totalCount)
                                logger.info("performSearch: Re-fetched ESearch for all \(esearchResult.ids.count) UIDs")
                            }

                            guard !esearchResult.ids.isEmpty else {
                                searchResults = SearchResults(totalCount: 0, records: [], hasMore: false, nextCursor: nil)
                                break
                            }
                        }

                        try Task.checkCancellation()

                        // Step 2: EFetch to get SRR accessions
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.objectWillChange.send()
                            self.searchPhase = .loadingDetails
                        }
                        let runAccessions = try await ncbi.sraEFetchRunAccessions(uids: esearchResult.ids)
                        logger.info("performSearch: EFetch resolved \(runAccessions.count) run accessions")

                        guard !runAccessions.isEmpty else {
                            searchResults = SearchResults(totalCount: 0, records: [], hasMore: false, nextCursor: nil)
                            break
                        }

                        try Task.checkCancellation()

                        // Step 3: Batch ENA lookup for FASTQ metadata
                        let readRecords = try await ena.searchReadsBatch(
                            accessions: runAccessions,
                            concurrency: 10,
                            progress: { [weak self] completed, total in
                                performOnMainRunLoop { [weak self] in
                                    guard let self = self else { return }
                                    self.objectWillChange.send()
                                    self.searchPhase = .loadingAllResults(loaded: completed, total: total)
                                }
                            }
                        )
                        records = readRecords.map { record in
                            SearchResultRecord(
                                id: record.runAccession,
                                accession: record.runAccession,
                                title: record.experimentTitle ?? "\(record.runAccession) - \(record.libraryStrategy ?? "Unknown") \(record.libraryLayout ?? "")",
                                organism: nil,
                                length: record.baseCount,
                                date: record.firstPublic,
                                source: .ena
                            )
                        }
                    }

                    searchResults = SearchResults(
                        totalCount: records.count,
                        records: records,
                        hasMore: false,
                        nextCursor: nil
                    )
                    logger.info("performSearch: ENA search returned \(records.count) results")

                case .pathoplexus:
                    performOnMainRunLoop { [weak self] in
                        guard let self = self else { return }
                        self.objectWillChange.send()
                        self.searchPhase = .loadingDetails
                    }

                    let ppOrganism = capturedPpOrganism?.id ?? "mpox"
                    logger.info("performSearch: Calling Pathoplexus search for organism=\(ppOrganism, privacy: .public)")

                    // Build Pathoplexus-specific filters
                    var ppFilters = PathoplexusFilters()
                    // Default to latest version only to avoid duplicates
                    ppFilters.versionStatus = .latestVersion
                    if !capturedPpCountry.isEmpty { ppFilters.geoLocCountry = capturedPpCountry }
                    if !capturedPpClade.isEmpty { ppFilters.clade = capturedPpClade }
                    if !capturedPpLineage.isEmpty { ppFilters.lineage = capturedPpLineage }
                    if !capturedPpHost.isEmpty { ppFilters.hostNameScientific = capturedPpHost }
                    // Restrict browser results to downloadable/open records.
                    // Restricted Pathoplexus entries often provide metadata only.
                    ppFilters.dataUseTerms = .open
                    if let minLen = capturedPpMinLength, minLen > 0 { ppFilters.lengthFrom = minLen }
                    if let maxLen = capturedPpMaxLength, maxLen > 0 { ppFilters.lengthTo = maxLen }

                    if !capturedPpNucMutations.isEmpty {
                        ppFilters.nucleotideMutations = capturedPpNucMutations.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                    if !capturedPpAAMutations.isEmpty {
                        ppFilters.aminoAcidMutations = capturedPpAAMutations.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    }

                    if !capturedPpDateFrom.isEmpty {
                        ppFilters.sampleCollectionDateFrom = capturedPpDateFrom
                    }
                    if !capturedPpDateTo.isEmpty {
                        ppFilters.sampleCollectionDateTo = capturedPpDateTo
                    }

                    // Use raw search text (not NCBI-formatted term) for accession filter
                    if !capturedPpSearchText.isEmpty {
                        ppFilters.accession = capturedPpSearchText
                    }

                    let pathoplexusService = PathoplexusService()
                    let totalCount = try await pathoplexusService.getAggregatedCount(
                        organism: ppOrganism,
                        filters: ppFilters
                    )
                    logger.info("performSearch: Pathoplexus aggregated count = \(totalCount)")

                    let targetCount: Int
                    if totalCount > largeResultThreshold {
                        let action = await confirmLargeResultActionDialog(
                                totalCount: totalCount,
                                sourceLabel: "Pathoplexus"
                            )
                        switch action {
                        case .cancel:
                            throw CancellationError()
                        case .firstThousand:
                            targetCount = min(largeResultThreshold, totalCount)
                        case .loadAll:
                            targetCount = totalCount
                        }
                    } else {
                        targetCount = totalCount
                    }

                    if totalCount == 0 {
                        searchResults = SearchResults(totalCount: 0, records: [], hasMore: false, nextCursor: nil)
                    } else {
                        let pageSize = 500
                        var offset = 0
                        var fetchedCount = 0
                        var allRecords: [SearchResultRecord] = []
                        allRecords.reserveCapacity(totalCount)
                        let requiresPostFilter = capturedPpINSDCFilter != .any

                        while true {
                            try Task.checkCancellation()

                            let loadedSnapshot = fetchedCount
                            let totalSnapshot = totalCount
                            performOnMainRunLoop { [weak self] in
                                guard let self = self else { return }
                                self.objectWillChange.send()
                                self.searchPhase = .loadingAllResults(loaded: loadedSnapshot, total: totalSnapshot)
                            }

                            // For unfiltered mode we only need to scan up to targetCount.
                            // For filtered modes (INSDC/non-INSDC), continue scanning until
                            // we collect targetCount matches or exhaust all available records.
                            let remainingToScan: Int
                            if requiresPostFilter {
                                remainingToScan = totalCount - offset
                            } else {
                                remainingToScan = targetCount - offset
                            }
                            if remainingToScan <= 0 { break }
                            let batchSize = min(pageSize, remainingToScan)
                            let page = try await pathoplexusService.search(
                                organism: ppOrganism,
                                filters: ppFilters,
                                limit: batchSize,
                                offset: offset
                            )

                            fetchedCount += page.records.count
                            offset += page.records.count

                            // Safety guard for inconsistent pagination responses.
                            if page.records.isEmpty {
                                logger.warning("performSearch: Pathoplexus returned empty page before reaching total (offset=\(offset), total=\(totalCount))")
                                break
                            }

                            switch capturedPpINSDCFilter {
                            case .any:
                                allRecords.append(contentsOf: page.records)
                            case .insdcOnly:
                                allRecords.append(contentsOf: page.records.filter { $0.sourceDatabase == "INSDC" })
                            case .nonINSDCOnly:
                                allRecords.append(contentsOf: page.records.filter { $0.sourceDatabase != "INSDC" })
                            }

                            if !requiresPostFilter, offset >= targetCount {
                                break
                            }
                            if requiresPostFilter, allRecords.count >= targetCount {
                                break
                            }
                            if offset >= totalCount {
                                break
                            }
                        }

                        let retained = requiresPostFilter ? min(allRecords.count, targetCount) : allRecords.count
                        let resolvedTotal = retained
                        logger.info("performSearch: Pathoplexus loaded records (fetched=\(fetchedCount), retained=\(retained), requested=\(targetCount), available=\(totalCount), filter=\(capturedPpINSDCFilter.rawValue, privacy: .public))")

                        searchResults = SearchResults(
                            totalCount: resolvedTotal,
                            records: Array(allRecords.prefix(targetCount)),
                            hasMore: false,
                            nextCursor: nil
                        )
                    }

                default:
                    throw DatabaseServiceError.invalidQuery(reason: "Unsupported database: \(currentSource)")
                }

                try Task.checkCancellation()

                // Update UI with results via RunLoop for modal compatibility
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.objectWillChange.send()
                    self.results = searchResults.records
                    self.totalResultCount = searchResults.totalCount
                    self.hasMoreResults = searchResults.hasMore
                    self.searchPhase = .complete(count: searchResults.records.count)
                    logger.info("performSearch: UI updated with \(searchResults.records.count) results")
                }

            } catch is CancellationError {
                logger.info("Search cancelled")
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.objectWillChange.send()
                    self.searchPhase = .idle
                }
            } catch {
                let errorMsg = error.localizedDescription
                logger.error("Search failed: \(errorMsg, privacy: .public)")
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.objectWillChange.send()
                    self.errorMessage = "Search failed: \(errorMsg)"
                    self.searchPhase = .failed(errorMsg)
                }
            }

            performOnMainRunLoop { [weak self] in
                self?.currentSearchTask = nil
            }
        }
    }

    /// Builds the search term based on scope.
    ///
    /// For NCBI E-utilities, the search term behavior depends on the field qualifier:
    /// - No qualifier: NCBI searches a limited set of default fields
    /// - `[All Fields]`: Explicitly searches ALL indexed fields including organism,
    ///   description, keywords, features, and more
    /// - `[Title]`, `[Organism]`, etc.: Searches only that specific field
    ///
    /// When "All Fields" scope is selected, we do NOT add the [All Fields] qualifier
    /// because NCBI's default behavior (no qualifier) actually provides better results
    /// for general searches. The [All Fields] qualifier can be too strict in some cases.
    private func buildSearchTerm(
        for searchType: NCBISearchType,
        includeRefSeqFilter: Bool
    ) -> String {
        let term = searchText.trimmingCharacters(in: .whitespaces)

        // Log the raw input for debugging
        logger.debug("buildSearchTerm: Raw input='\(term, privacy: .public)', scope=\(self.searchScope.rawValue, privacy: .public)")

        let scopedTerm: String
        switch searchScope {
        case .all:
            // For "All Fields" scope, return the term without any qualifier.
            // NCBI's default search behavior (no field qualifier) provides good
            // coverage across multiple fields. Adding [All Fields] can actually
            // be more restrictive in some cases.
            //
            // If the user's term already contains field qualifiers (e.g., "[Organism]"),
            // we preserve those as-is.
            logger.debug("buildSearchTerm: Using unqualified term for All Fields scope")
            scopedTerm = term
        case .accession:
            // Accession searches work best without a field qualifier
            // NCBI automatically matches accession patterns
            logger.debug("buildSearchTerm: Using unqualified term for Accession scope")
            scopedTerm = term
        case .organism:
            let result = "\(term)[Organism]"
            logger.debug("buildSearchTerm: Built organism query='\(result, privacy: .public)'")
            scopedTerm = result
        case .title:
            let result = "\(term)[Title]"
            logger.debug("buildSearchTerm: Built title query='\(result, privacy: .public)'")
            scopedTerm = result
        case .bioProject:
            let result = "\(term)[BioProject]"
            logger.debug("buildSearchTerm: Built BioProject query='\(result, privacy: .public)'")
            scopedTerm = result
        case .author:
            let result = "\(term)[Author]"
            logger.debug("buildSearchTerm: Built author query='\(result, privacy: .public)'")
            scopedTerm = result
        }

        var clauses: [String] = [scopedTerm]

        if !organismFilter.isEmpty {
            clauses.append("\(fieldValue(organismFilter))[Organism]")
        }
        if !locationFilter.isEmpty {
            clauses.append("\(fieldValue(locationFilter))[Location]")
        }
        if !geneFilter.isEmpty {
            clauses.append("\(fieldValue(geneFilter))[Gene]")
        }
        if !authorFilter.isEmpty {
            clauses.append("\(fieldValue(authorFilter))[Author]")
        }
        if !journalFilter.isEmpty {
            clauses.append("\(fieldValue(journalFilter))[Journal]")
        }

        // Molecule type filter
        if let molValue = moleculeType.entrezValue {
            clauses.append("\"\(molValue)\"[Molecule Type]")
        }

        // Publication date range (YYYY/MM/DD format for Entrez)
        let dateFrom = pubDateFrom.trimmingCharacters(in: .whitespaces)
        let dateTo = pubDateTo.trimmingCharacters(in: .whitespaces)
        if !dateFrom.isEmpty || !dateTo.isEmpty {
            let lower = dateFrom.isEmpty ? "1900/01/01" : dateFrom
            let upper = dateTo.isEmpty ? "3000/12/31" : dateTo
            clauses.append("\(lower):\(upper)[Publication Date]")
        }

        // Sequence property filters (Feature key)
        for prop in propertyFilters.sorted(by: { $0.rawValue < $1.rawValue }) {
            clauses.append(prop.entrezFilter)
        }

        let minLen = minLength.trimmingCharacters(in: .whitespaces)
        let maxLen = maxLength.trimmingCharacters(in: .whitespaces)
        if !minLen.isEmpty || !maxLen.isEmpty {
            let lower = minLen.isEmpty ? "1" : minLen
            let upper = maxLen.isEmpty ? "*" : maxLen
            clauses.append("\(lower):\(upper)[SLEN]")
        }

        if includeRefSeqFilter && searchType == .nucleotide {
            clauses.append("refseq[filter]")
        }

        return clauses.joined(separator: " AND ")
    }

    private func fieldValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") {
            return "\"\(trimmed)\""
        }
        return trimmed
    }

    /// Downloads all selected records (batch download).
    ///
    /// This downloads each selected record sequentially, updating progress as each completes.
    /// Uses Task.detached to ensure downloads work in modal sheet context.
    func performBatchDownload() {
        // Get records to download - use multi-select if available, otherwise single selection
        let recordsToDownload: [SearchResultRecord]
        if !selectedRecords.isEmpty {
            recordsToDownload = Array(selectedRecords)
        } else if let single = selectedRecord {
            recordsToDownload = [single]
        } else {
            errorMessage = "No records selected"
            return
        }

        if let automationBackend {
            let currentSource = source
            onDownloadStarted?()

            // Use the same detached scheduling model as the live download path so
            // UI tests don't depend on modal-sheet MainActor behavior.
            Task.detached { [weak self] in
                do {
                    try await automationBackend.simulateDownload(
                        records: recordsToDownload,
                        source: currentSource
                    )
                } catch {
                    await MainActor.run {
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }

        // Confirm large batch downloads (>50 records)
        if recordsToDownload.count > 50 {
            let alert = NSAlert()
            alert.messageText = "Download \(recordsToDownload.count) Records?"
            alert.informativeText = "Downloading \(recordsToDownload.count) records will take a significant amount of time and bandwidth. Each record will be downloaded and processed individually."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Download All")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
        }

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        let totalCount = recordsToDownload.count

        // Capture services and values for task
        let ncbi = ncbiService
        let ena = enaService
        let currentSource = source
        let searchType = ncbiSearchType

        // Capture the genome download view model for genome assembly downloads
        let genomeVM = genomeDownloadViewModel
        let genBankVM = genBankDownloadViewModel
        let ppOrganism = pathoplexusOrganism?.id ?? "mpox"

        // Build a descriptive title including accession(s) for the Downloads popover
        let accessionList = recordsToDownload.prefix(3).map(\.accession).joined(separator: ", ")
        let accessionSuffix = totalCount > 3 ? " +\(totalCount - 3) more" : ""
        let downloadTitle: String
        if currentSource == .ncbi && searchType == .nucleotide {
            downloadTitle = totalCount == 1
                ? recordsToDownload[0].accession
                : "GenBank: \(accessionList)\(accessionSuffix)"
        } else if currentSource == .ncbi && searchType == .genome {
            downloadTitle = totalCount == 1
                ? recordsToDownload[0].accession
                : "Genome: \(accessionList)\(accessionSuffix)"
        } else if currentSource == .ncbi && searchType == .virus {
            downloadTitle = totalCount == 1
                ? recordsToDownload[0].accession
                : "Virus: \(accessionList)\(accessionSuffix)"
        } else {
            downloadTitle = totalCount == 1
                ? recordsToDownload[0].accession
                : "\(currentSource.displayName): \(accessionList)\(accessionSuffix)"
        }
        // Build CLI command for Operations Panel display
        let cliAccessions = recordsToDownload.map(\.accession)
        let cliCommand: String
        if currentSource == .ena {
            // ENA source is used for SRA/FASTQ downloads
            cliCommand = OperationCenter.buildCLICommand(
                subcommand: "fetch sra download",
                args: cliAccessions + ["--output-dir", "."]
            )
        } else if currentSource == .ncbi && searchType == .genome {
            cliCommand = OperationCenter.buildCLICommand(
                subcommand: "fetch genome",
                args: ["--accession"] + cliAccessions + ["-o", "."]
            )
        } else {
            cliCommand = OperationCenter.buildCLICommand(
                subcommand: "fetch ncbi",
                args: cliAccessions + ["--save-to", "."]
            )
        }
        let downloadCenterTaskID = DownloadCenter.shared.start(
            title: downloadTitle,
            detail: "Preparing \(totalCount) record(s)...",
            cliCommand: cliCommand
        )

        // Log details about selected records for debugging
        logger.info("performBatchDownload: Starting download of \(totalCount) record(s)")
        logger.info("performBatchDownload: selectedRecords.count = \(self.selectedRecords.count)")
        for (idx, record) in recordsToDownload.enumerated() {
            logger.info("performBatchDownload: Record[\(idx)] id=\(record.id, privacy: .public) accession=\(record.accession, privacy: .public)")
        }

        // For ENA/SRA downloads, present the FASTQ import config sheet so the
        // user can confirm platform, quality binning, and recipe before download.
        // The config sheet is shown before the browser sheet is dismissed, so
        // we need to detect platform info asynchronously then show the sheet.
        if currentSource == .ena {
            isDownloading = true  // prevent double-click while fetching metadata
            Task {
                // Quick fetch of the first record to detect platform / pairing
                let firstAccession = recordsToDownload[0].accession
                var detectedPlatform: LungfishIO.SequencingPlatform = .unknown
                var isPaired = false
                do {
                    let readRecords = try await ena.searchReads(term: firstAccession, limit: 1)
                    if let readRecord = readRecords.first {
                        switch readRecord.instrumentPlatform?.uppercased() {
                        case "ILLUMINA":       detectedPlatform = .illumina
                        case "OXFORD_NANOPORE": detectedPlatform = .oxfordNanopore
                        case "PACBIO_SMRT":     detectedPlatform = .pacbio
                        case "ULTIMA":          detectedPlatform = .ultima
                        default:                detectedPlatform = .unknown
                        }
                        isPaired = readRecord.libraryLayout?.uppercased() == "PAIRED"
                    }
                } catch {
                    logger.warning("Failed to fetch ENA metadata for config sheet, using defaults: \(error.localizedDescription, privacy: .public)")
                }

                // Build placeholder pairs for the config sheet display
                let placeholderPairs = recordsToDownload.map { record in
                    FASTQFilePair(
                        r1: URL(fileURLWithPath: "/\(record.accession)_1.fastq.gz"),
                        r2: isPaired ? URL(fileURLWithPath: "/\(record.accession)_2.fastq.gz") : nil
                    )
                }

                // Present config sheet on the main window. The database browser
                // sheet is dismissed first so the config sheet can attach to the
                // main window without sheet stacking issues.
                self.onDownloadStarted?()

                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                    logger.error("No window available for config sheet presentation")
                    self.isDownloading = false
                    return
                }

                FASTQImportConfigSheet.present(
                    on: window,
                    pairs: placeholderPairs,
                    detectedPlatform: detectedPlatform,
                    onImport: { [downloadCenterTaskID, totalCount] importConfig in
                        // User confirmed — start the actual download with captured config
                        self.startENADownloadTask(
                            records: recordsToDownload,
                            importConfig: importConfig,
                            downloadCenterTaskID: downloadCenterTaskID,
                            totalCount: totalCount
                        )
                    },
                    onCancel: { [downloadCenterTaskID] in
                        // User cancelled — cancel the DownloadCenter task
                        DownloadCenter.shared.fail(
                            id: downloadCenterTaskID,
                            detail: "Cancelled by user"
                        )
                    }
                )
            }
            return
        }

        // Dismiss the sheet immediately so the user can see the main window
        // while the download progresses in the background via DownloadCenter.
        // Bundle delivery happens through DownloadCenter.onBundleReady (set by
        // AppDelegate at startup), eliminating the fragile callback chain through
        // the sheet controller which gets deallocated on dismissal.
        onDownloadStarted?()

        // Capture project URL for project-local temp allocation
        let batchProjectURL = DocumentManager.shared.activeProject?.url

        // Use Task.detached to break out of MainActor context.
        // This is critical when running in a modal sheet - regular Task {}
        // inherits MainActor isolation and may not execute due to the modal
        // run loop blocking task scheduling on MainActor.
        Task.detached {
            var downloadedURLs: [URL] = []
            var failedCount = 0
            var failureDetails: [String] = []

            // Create a unique batch directory once for all downloads in this batch
            // This avoids filename collisions when records have the same accession
            let batchDir = try ProjectTempDirectory.create(prefix: "batch-", in: batchProjectURL)
            logger.info("performBatchDownload: Created batch directory at \(batchDir.path, privacy: .public)")

            for (index, record) in recordsToDownload.enumerated() {
                // Update progress via performOnMainRunLoop for modal compatibility.
                // DownloadCenter update must not be gated on [weak self] since the
                // view model may already be deallocated after sheet dismissal.
                let progressFraction = Double(index) / Double(totalCount)
                performOnMainRunLoop {
                    DownloadCenter.shared.update(
                        id: downloadCenterTaskID,
                        progress: progressFraction,
                        detail: "Downloading \(record.accession) (\(index + 1)/\(totalCount))"
                    )
                }

                do {
                    var fileURL: URL?
                    let normalizedRecordAccession = record.accession.trimmingCharacters(in: .whitespacesAndNewlines)

                    switch currentSource {
                    case .ncbi:
                        // Handle genome downloads: download FASTA + GFF3 and build .lungfishref bundle
                        if searchType == .genome {
                            // For genome downloads, get the assembly summary and use
                            // GenomeDownloadViewModel to download FASTA + GFF3 annotations
                            // and build a .lungfishref reference bundle.
                            logger.info("performBatchDownload: Fetching assembly summary for id=\(record.id, privacy: .public)")
                            let assemblySummaries = try await ncbi.assemblyEsummary(ids: [record.id])
                            guard let summary = assemblySummaries.first else {
                                throw DatabaseServiceError.notFound(accession: record.accession)
                            }
                            logger.info("performBatchDownload: Got assembly summary: \(summary.assemblyAccession ?? "nil", privacy: .public) organism=\(summary.organism ?? "nil", privacy: .public)")

                            performOnMainRunLoop {
                                DownloadCenter.shared.update(
                                    id: downloadCenterTaskID,
                                    progress: progressFraction,
                                    detail: "Downloading genome for \(record.accession)..."
                                )
                            }

                            logger.info("performBatchDownload: Calling genomeVM.downloadAndBuild for \(record.accession, privacy: .public)")
                            let bundleURL = try await genomeVM.downloadAndBuild(
                                assembly: summary,
                                outputDirectory: batchDir
                            ) { progress, message in
                                let overall = (Double(index) + progress) / Double(totalCount)
                                performOnMainRunLoop {
                                    DownloadCenter.shared.update(
                                        id: downloadCenterTaskID,
                                        progress: overall,
                                        detail: "\(record.accession): \(message)"
                                    )
                                }
                            }

                            fileURL = bundleURL
                            logger.info("performBatchDownload: Built genome bundle at \(bundleURL.path, privacy: .public)")
                        } else {
                            // Nucleotide and virus downloads always end as .lungfishref bundles.
                            logger.info("performBatchDownload: Starting GenBank bundle build for \(record.accession, privacy: .public)")
                            let bundleURL = try await genBankVM.downloadAndBuild(
                                accession: record.accession,
                                outputDirectory: batchDir
                            ) { progress, message in
                                let overall = (Double(index) + progress) / Double(totalCount)
                                performOnMainRunLoop {
                                    DownloadCenter.shared.update(
                                        id: downloadCenterTaskID,
                                        progress: overall,
                                        detail: "\(record.accession): \(message)"
                                    )
                                }
                            }
                            fileURL = bundleURL
                            logger.info("performBatchDownload: Built GenBank bundle at \(bundleURL.path, privacy: .public)")
                        }

                    case .ena:
                        // ENA/SRA downloads are now handled by startENADownloadTask()
                        // which is called after the user confirms the import config sheet.
                        // This case should not be reachable since performBatchDownload()
                        // returns early for ENA source before entering this Task.detached.
                        assertionFailure("ENA downloads should not reach this code path")
                        throw DatabaseServiceError.invalidQuery(
                            reason: "Internal error: ENA downloads should use the config sheet path"
                        )

                    case .pathoplexus:
                        // Check if this record has an INSDC accession for GenBank retrieval
                        let pathoplexusService = PathoplexusService()
                        let ppMeta = try await pathoplexusService.fetchMetadataForAccession(
                            organism: ppOrganism,
                            accession: normalizedRecordAccession
                        )

                        if ppMeta?.dataUseTerms?.uppercased() == DataUseTerms.restricted.rawValue {
                            throw DatabaseServiceError.invalidQuery(
                                reason: "Record \(normalizedRecordAccession) is restricted and cannot be downloaded"
                            )
                        } else if let insdcAccession = ppMeta?.bestINSDCAccession?.trimmingCharacters(in: .whitespacesAndNewlines), !insdcAccession.isEmpty {
                            // Prefer INSDC GenBank retrieval for rich annotations; if unavailable,
                            // fall back to direct Pathoplexus FASTA so the sample still downloads.
                            logger.info("performBatchDownload: Pathoplexus record \(record.accession, privacy: .public) has INSDC accession \(insdcAccession, privacy: .public), fetching from GenBank")
                            do {
                                performOnMainRunLoop {
                                    DownloadCenter.shared.update(
                                        id: downloadCenterTaskID,
                                        progress: progressFraction,
                                        detail: "Fetching GenBank record \(insdcAccession)..."
                                    )
                                }

                                let bundleURL = try await genBankVM.downloadAndBuild(
                                    accession: insdcAccession,
                                    outputDirectory: batchDir
                                ) { progress, message in
                                    let overall = (Double(index) + progress) / Double(totalCount)
                                    performOnMainRunLoop {
                                        DownloadCenter.shared.update(
                                            id: downloadCenterTaskID,
                                            progress: overall,
                                            detail: "\(insdcAccession): \(message)"
                                        )
                                    }
                                }

                                // Append Pathoplexus metadata to the bundle manifest
                                if let meta = ppMeta {
                                    appendPathoplexusMetadata(meta, organism: ppOrganism, toBundleAt: bundleURL)
                                }

                                fileURL = bundleURL
                                logger.info("performBatchDownload: Built GenBank bundle from Pathoplexus INSDC at \(bundleURL.path, privacy: .public)")
                            } catch {
                                logger.warning("performBatchDownload: INSDC fetch failed for \(record.accession, privacy: .public) (\(insdcAccession, privacy: .public)); falling back to Pathoplexus FASTA. Error: \(error.localizedDescription, privacy: .public)")
                                performOnMainRunLoop {
                                    DownloadCenter.shared.update(
                                        id: downloadCenterTaskID,
                                        progress: progressFraction,
                                        detail: "GenBank unavailable for \(record.accession); falling back to FASTA..."
                                    )
                                }

                                let dbRecord = try await pathoplexusService.fetch(accession: record.accession, organism: ppOrganism)
                                let bundleURL = try await genBankVM.buildBundleFromSequence(
                                    accession: dbRecord.accession,
                                    title: dbRecord.title,
                                    sequence: dbRecord.sequence,
                                    outputDirectory: batchDir,
                                    sourceDatabase: "Pathoplexus",
                                    sourceURL: URL(string: "https://pathoplexus.org/\(ppOrganism)/search?accession=\(dbRecord.accession)"),
                                    notes: "Generated from Pathoplexus FASTA fallback after INSDC lookup failed"
                                ) { progress, message in
                                    let overall = (Double(index) + progress) / Double(totalCount)
                                    performOnMainRunLoop {
                                        DownloadCenter.shared.update(
                                            id: downloadCenterTaskID,
                                            progress: overall,
                                            detail: "\(dbRecord.accession): \(message)"
                                        )
                                    }
                                }
                                if let meta = ppMeta {
                                    appendPathoplexusMetadata(meta, organism: ppOrganism, toBundleAt: bundleURL)
                                }
                                fileURL = bundleURL
                            }
                        } else {
                            // No INSDC accession — download FASTA only from Pathoplexus
                            logger.info("performBatchDownload: Pathoplexus record \(record.accession, privacy: .public) has no INSDC accession, building bundle from Pathoplexus FASTA")
                            performOnMainRunLoop {
                                DownloadCenter.shared.update(
                                    id: downloadCenterTaskID,
                                    progress: progressFraction,
                                    detail: "Building bundle from Pathoplexus sequence for \(record.accession)..."
                                )
                            }

                            let dbRecord = try await pathoplexusService.fetch(accession: normalizedRecordAccession, organism: ppOrganism)
                            let bundleURL = try await genBankVM.buildBundleFromSequence(
                                accession: dbRecord.accession,
                                title: dbRecord.title,
                                sequence: dbRecord.sequence,
                                outputDirectory: batchDir,
                                sourceDatabase: "Pathoplexus",
                                sourceURL: URL(string: "https://pathoplexus.org/\(ppOrganism)/search?accession=\(dbRecord.accession)"),
                                notes: "Generated from Pathoplexus sequence (no INSDC accession available)"
                            ) { progress, message in
                                let overall = (Double(index) + progress) / Double(totalCount)
                                performOnMainRunLoop {
                                    DownloadCenter.shared.update(
                                        id: downloadCenterTaskID,
                                        progress: overall,
                                        detail: "\(dbRecord.accession): \(message)"
                                    )
                                }
                            }
                            if let meta = ppMeta {
                                appendPathoplexusMetadata(meta, organism: ppOrganism, toBundleAt: bundleURL)
                            }
                            fileURL = bundleURL
                        }

                    default:
                        throw DatabaseServiceError.invalidQuery(reason: "Unsupported database")
                    }

                    if let fileURL {
                        downloadedURLs.append(fileURL)
                    }
                    logger.info("Downloaded \(normalizedRecordAccession, privacy: .public)")

                } catch {
                    logger.error("Failed to download \(record.accession.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public): \(error, privacy: .public)")
                    failedCount += 1
                    failureDetails.append("\(record.accession.trimmingCharacters(in: .whitespacesAndNewlines)): \(error.localizedDescription)")
                    // Store the last error detail for the DownloadCenter failure message
                    performOnMainRunLoop {
                        DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: Double(index + 1) / Double(totalCount),
                            detail: "Failed: \(record.accession) — \(error.localizedDescription)"
                        )
                    }
                }
            }

            // Complete - update DownloadCenter with bundle URLs.
            // DownloadCenter.onBundleReady (set by AppDelegate) handles importing
            // the bundles into the sidebar. This avoids the fragile callback chain
            // through the sheet controller which was deallocated on dismissal.
            let finalDownloadedURLs = downloadedURLs
            let finalFailedCount = failedCount
            let finalFailureDetails = failureDetails
            performOnMainRunLoop {
                if finalDownloadedURLs.isEmpty && finalFailedCount > 0 {
                    let reasonSummary = finalFailureDetails.prefix(3).joined(separator: "; ")
                    DownloadCenter.shared.fail(
                        id: downloadCenterTaskID,
                        detail: reasonSummary.isEmpty
                            ? "Completed with \(finalFailedCount) failure(s)"
                            : "Completed with \(finalFailedCount) failure(s): \(reasonSummary)"
                    )
                } else {
                    let bundleNames = finalDownloadedURLs.map { $0.deletingPathExtension().lastPathComponent }
                    let detail: String
                    if finalFailedCount > 0 {
                        let reasonSummary = finalFailureDetails.prefix(3).joined(separator: "; ")
                        detail = "Completed \(finalDownloadedURLs.count) download(s), \(finalFailedCount) failed. \(reasonSummary)"
                    } else if totalCount == 1 {
                        if currentSource == .ena {
                            detail = "FASTQ ready: \(bundleNames.first ?? "unknown")"
                        } else {
                            detail = "Bundle ready: \(bundleNames.first ?? "unknown")"
                        }
                    } else {
                        let unit = currentSource == .ena ? "file(s)" : "bundle(s)"
                        detail = "Completed \(finalDownloadedURLs.count) \(unit)"
                    }
                    DownloadCenter.shared.complete(
                        id: downloadCenterTaskID,
                        detail: detail,
                        bundleURLs: finalDownloadedURLs
                    )
                }

                logger.info("performBatchDownload: Complete - \(finalDownloadedURLs.count) downloaded, \(finalFailedCount) failed")
            }
        }
    }

    // MARK: - ENA/SRA Download with CLI Import

    /// Starts the SRA download and CLI import pipeline for the given records.
    ///
    /// Called from the `FASTQImportConfigSheet` `onImport` callback after the user
    /// confirms import settings. Downloads FASTQ files from ENA, then runs
    /// `CLIImportRunner` to create `.lungfishfastq` bundles, and finally augments
    /// each bundle's metadata sidecar with ENA provenance info.
    private func startENADownloadTask(
        records: [SearchResultRecord],
        importConfig: FASTQImportConfiguration,
        downloadCenterTaskID: UUID,
        totalCount: Int
    ) {
        let ena = enaService

        // Map confirmed platform to CLI string
        let platformStr: String
        switch importConfig.confirmedPlatform {
        case .illumina:       platformStr = "illumina"
        case .oxfordNanopore: platformStr = "ont"
        case .pacbio:         platformStr = "pacbio"
        case .ultima:         platformStr = "ultima"
        default:              platformStr = "illumina"
        }

        // Resolve recipe name — prefer V2 recipeName, fall back to legacy
        let recipeName: String? = {
            if let name = importConfig.recipeName { return name }
            guard let recipe = importConfig.postImportRecipe, !recipe.steps.isEmpty else { return nil }
            if recipe.name.lowercased().contains("vsp2") {
                if let nr = RecipeRegistryV2.allRecipes().first(where: { $0.name.lowercased().contains("vsp2") }) {
                    return nr.id
                }
            }
            return recipe.name.lowercased()
        }()

        let compressionStr = importConfig.compressionLevel?.rawValue ?? "balanced"
        let qualityBinning = importConfig.qualityBinning.rawValue
        let optimizeStorage = !importConfig.skipClumpify
        let confirmedPlatform = importConfig.confirmedPlatform

        // Capture project URL for project-local temp allocation
        let projectURL = DocumentManager.shared.activeProject?.url

        Task.detached {
            var downloadedURLs: [URL] = []
            var failedCount = 0
            var failureDetails: [String] = []

            let batchDir = try ProjectTempDirectory.create(prefix: "sra-batch-", in: projectURL)
            logger.info("startENADownloadTask: Created batch directory at \(batchDir.path, privacy: .public)")

            for (index, record) in records.enumerated() {
                let progressFraction = Double(index) / Double(totalCount)
                performOnMainRunLoop {
                    DownloadCenter.shared.update(
                        id: downloadCenterTaskID,
                        progress: progressFraction,
                        detail: "Downloading \(record.accession) (\(index + 1)/\(totalCount))"
                    )
                }

                do {
                    // 1. Fetch ENA read record for FASTQ URLs and metadata
                    logger.info("startENADownloadTask: Downloading FASTQ for SRA run \(record.accession, privacy: .public)")
                    performOnMainRunLoop {
                        DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: progressFraction,
                            detail: "Fetching FASTQ URLs for \(record.accession)..."
                        )
                    }

                    let readRecords = try await ena.searchReads(term: record.accession, limit: 1)
                    guard let readRecord = readRecords.first else {
                        throw DatabaseServiceError.notFound(accession: record.accession)
                    }

                    let fastqURLs = readRecord.fastqHTTPURLs
                    guard !fastqURLs.isEmpty else {
                        throw DatabaseServiceError.invalidQuery(
                            reason: "No FASTQ files available for \(record.accession). "
                                + "The data may not yet be processed by ENA."
                        )
                    }

                    // 2. Download each FASTQ file to the batch directory
                    var downloadedFASTQFiles: [URL] = []
                    let totalExpectedBytes = readRecord.totalFileSizeBytes.map { Int64($0) }
                    let perFileSizes: [Int64?] = {
                        guard let bytesStr = readRecord.fastqBytes else { return fastqURLs.map { _ in nil } }
                        let sizes = bytesStr.components(separatedBy: ";").map { Int64($0) }
                        return sizes + Array(repeating: nil, count: max(0, fastqURLs.count - sizes.count))
                    }()

                    var priorBytesDownloaded: Int64 = 0

                    for (fileIdx, fastqURL) in fastqURLs.enumerated() {
                        let filename = fastqURL.lastPathComponent
                        let localPath = batchDir.appendingPathComponent(filename)
                        let fileExpectedBytes = fileIdx < perFileSizes.count ? perFileSizes[fileIdx] : nil

                        logger.info("startENADownloadTask: Downloading \(fastqURL.absoluteString, privacy: .public)")

                        let capturedPrior = priorBytesDownloaded
                        let capturedTotal = totalExpectedBytes

                        let data = try await streamingDownload(
                            url: fastqURL,
                            totalBytes: fileExpectedBytes,
                            progressHandler: { bytesWritten, _ in
                                let totalSoFar = capturedPrior + bytesWritten
                                performOnMainRunLoop {
                                    DownloadCenter.shared.updateBytes(
                                        id: downloadCenterTaskID,
                                        bytesDownloaded: totalSoFar,
                                        totalBytes: capturedTotal
                                    )
                                }
                            }
                        )

                        try data.write(to: localPath)
                        logger.info("startENADownloadTask: Saved \(filename) (\(data.count) bytes)")
                        downloadedFASTQFiles.append(localPath)
                        priorBytesDownloaded += fileExpectedBytes ?? Int64(data.count)
                    }

                    guard !downloadedFASTQFiles.isEmpty else {
                        throw DatabaseServiceError.invalidQuery(
                            reason: "No FASTQ files were downloaded for \(record.accession)"
                        )
                    }

                    // 3. Detect R1/R2 pairing from downloaded files
                    let sortedFiles = downloadedFASTQFiles.sorted { lhs, rhs in
                        let left = lhs.lastPathComponent.lowercased()
                        let right = rhs.lastPathComponent.lowercased()
                        let leftIsR1 = left.contains("_1.fastq") || left.contains("_1.fq")
                            || left.contains("_r1.fastq") || left.contains("_r1.fq")
                        let rightIsR1 = right.contains("_1.fastq") || right.contains("_1.fq")
                            || right.contains("_r1.fastq") || right.contains("_r1.fq")
                        if leftIsR1 != rightIsR1 { return leftIsR1 }
                        return left.localizedStandardCompare(right) == .orderedAscending
                    }
                    let r1URL = sortedFiles[0]
                    let r2URL: URL? = sortedFiles.count == 2 ? sortedFiles[1] : nil

                    // 4. Run CLI import pipeline
                    performOnMainRunLoop {
                        DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: progressFraction,
                            detail: "\(record.accession) importing via CLI pipeline..."
                        )
                    }

                    // Use the real project directory so CLI creates bundles
                    // directly in <project>.lungfish/Imports/ (not inside .tmp/)
                    let projectDirectory = projectURL ?? batchDir

                    let args = CLIImportRunner.buildCLIArguments(
                        r1: r1URL,
                        r2: r2URL,
                        projectDirectory: projectDirectory,
                        platform: platformStr,
                        recipeName: recipeName,
                        qualityBinning: qualityBinning,
                        optimizeStorage: optimizeStorage,
                        compressionLevel: compressionStr
                    )

                    final class ResultTracker: @unchecked Sendable {
                        var bundleURL: URL?
                        var errorMessage: String?
                    }
                    let tracker = ResultTracker()

                    let runner = CLIImportRunner()
                    await runner.run(
                        arguments: args,
                        operationID: downloadCenterTaskID,
                        projectDirectory: projectDirectory,
                        onBundleCreated: { url in tracker.bundleURL = url },
                        onError: { error in tracker.errorMessage = error }
                    )

                    if let errorMsg = tracker.errorMessage, tracker.bundleURL == nil {
                        throw NSError(
                            domain: "DatabaseBrowser.SRAImport", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: errorMsg]
                        )
                    }

                    guard let bundleURL = tracker.bundleURL else {
                        throw NSError(
                            domain: "DatabaseBrowser.SRAImport", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "CLI import produced no output bundle for \(record.accession)"]
                        )
                    }

                    // 5. Augment metadata sidecar with ENA provenance info
                    let contents = try? FileManager.default.contentsOfDirectory(
                        at: bundleURL,
                        includingPropertiesForKeys: nil
                    )
                    if let fastqURL = contents?.first(where: {
                        $0.lastPathComponent.hasSuffix(".fastq.gz") || $0.lastPathComponent.hasSuffix(".fq.gz")
                    }) {
                        var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
                        metadata.enaReadRecord = readRecord
                        metadata.downloadDate = Date()
                        metadata.downloadSource = "ENA"
                        metadata.sequencingPlatform = confirmedPlatform
                        FASTQMetadataStore.save(metadata, for: fastqURL)
                    }

                    logger.info("startENADownloadTask: Created bundle at \(bundleURL.path, privacy: .public)")
                    downloadedURLs.append(bundleURL)

                    // Clean up raw downloaded FASTQ files from batch staging dir
                    for rawFile in downloadedFASTQFiles {
                        try? FileManager.default.removeItem(at: rawFile)
                    }

                    // Deliver bundle immediately so it appears in sidebar right away
                    let deliverURL = bundleURL
                    performOnMainRunLoop {
                        DownloadCenter.shared.onBundleReady?([deliverURL])
                    }

                } catch {
                    logger.error("startENADownloadTask: Failed for \(record.accession, privacy: .public): \(error, privacy: .public)")
                    failedCount += 1
                    failureDetails.append("\(record.accession): \(error.localizedDescription)")
                    performOnMainRunLoop {
                        DownloadCenter.shared.update(
                            id: downloadCenterTaskID,
                            progress: Double(index + 1) / Double(totalCount),
                            detail: "Failed: \(record.accession) — \(error.localizedDescription)"
                        )
                    }
                }
            }

            // Clean up the batch staging directory (raw FASTQs already removed per-record)
            try? FileManager.default.removeItem(at: batchDir)
            logger.info("startENADownloadTask: Cleaned up batch staging dir")

            // Complete — bundles were already delivered incrementally via onBundleReady
            let finalDownloadedCount = downloadedURLs.count
            let finalFailedCount = failedCount
            let finalFailureDetails = failureDetails
            performOnMainRunLoop {
                if finalDownloadedCount == 0 && finalFailedCount > 0 {
                    let reasonSummary = finalFailureDetails.prefix(3).joined(separator: "; ")
                    DownloadCenter.shared.fail(
                        id: downloadCenterTaskID,
                        detail: reasonSummary.isEmpty
                            ? "Completed with \(finalFailedCount) failure(s)"
                            : "Completed with \(finalFailedCount) failure(s): \(reasonSummary)"
                    )
                } else {
                    let detail: String
                    if finalFailedCount > 0 {
                        let reasonSummary = finalFailureDetails.prefix(3).joined(separator: "; ")
                        detail = "Completed \(finalDownloadedCount) download(s), \(finalFailedCount) failed. \(reasonSummary)"
                    } else if totalCount == 1 {
                        detail = "FASTQ ready"
                    } else {
                        detail = "Completed \(finalDownloadedCount) file(s)"
                    }
                    // Don't pass bundleURLs — they were already delivered incrementally
                    DownloadCenter.shared.complete(
                        id: downloadCenterTaskID,
                        detail: detail,
                        bundleURLs: []
                    )
                }

                logger.info("startENADownloadTask: Complete - \(finalDownloadedCount) downloaded, \(finalFailedCount) failed")
            }
        }
    }

    private func computeFASTQStatisticsFast(
        for fastqURL: URL,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> (FASTQDatasetStatistics, SeqkitStatsMetadata?) {
        do {
            let summary = try await fetchSeqkitSummary(for: fastqURL)
            let histogram = try await loadReadLengthHistogramFromFASTQ(
                from: fastqURL,
                progress: progress
            )

            let readCount = summary.numSeqs > 0 ? summary.numSeqs : histogram.reduce(0) { $0 + $1.value }
            let baseCount = summary.sumLen > 0 ? summary.sumLen : histogram.reduce(Int64(0)) { total, item in
                total + Int64(item.key * item.value)
            }
            let minLength = summary.minLen > 0 ? summary.minLen : histogram.keys.min() ?? 0
            let maxLength = summary.maxLen > 0 ? summary.maxLen : histogram.keys.max() ?? 0
            let meanLength = summary.avgLen > 0 ? summary.avgLen : (readCount > 0 ? Double(baseCount) / Double(readCount) : 0)
            let medianLength = histogramMedian(histogram, totalCount: readCount)
            let n50 = histogramN50(histogram, totalBases: baseCount)

            return (FASTQDatasetStatistics(
                readCount: readCount,
                baseCount: baseCount,
                meanReadLength: meanLength,
                minReadLength: minLength,
                maxReadLength: maxLength,
                medianReadLength: medianLength,
                n50ReadLength: n50,
                meanQuality: summary.avgQual,
                q20Percentage: summary.q20,
                q30Percentage: summary.q30,
                gcContent: summary.gcPercent / 100.0,
                readLengthHistogram: histogram,
                qualityScoreHistogram: [:],
                perPositionQuality: []
            ), summary.asMetadata())
        } catch {
            logger.warning("computeFASTQStatisticsFast: fast path failed for \(fastqURL.lastPathComponent, privacy: .public), falling back to full reader stats. Error: \(error.localizedDescription, privacy: .public)")
            let reader = FASTQReader()
            let (statistics, _) = try await reader.computeStatistics(
                from: fastqURL,
                sampleLimit: 0,
                progress: progress
            )
            return (statistics, nil)
        }
    }

    private struct SeqkitSummary {
        let numSeqs: Int
        let sumLen: Int64
        let minLen: Int
        let avgLen: Double
        let maxLen: Int
        let q20: Double
        let q30: Double
        let avgQual: Double
        let gcPercent: Double

        func asMetadata() -> SeqkitStatsMetadata {
            SeqkitStatsMetadata(
                numSeqs: numSeqs,
                sumLen: sumLen,
                minLen: minLen,
                avgLen: avgLen,
                maxLen: maxLen,
                q20Percentage: q20,
                q30Percentage: q30,
                averageQuality: avgQual,
                gcPercentage: gcPercent
            )
        }
    }

    private func fetchSeqkitSummary(for fastqURL: URL) async throws -> SeqkitSummary {
        let runner = NativeToolRunner.shared
        let result = try await runner.run(
            .seqkit,
            arguments: ["stats", "-a", "-T", fastqURL.path],
            timeout: 900
        )

        guard result.isSuccess else {
            throw DatabaseServiceError.parseError(
                message: "seqkit stats failed: \(result.stderr)"
            )
        }

        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else {
            throw DatabaseServiceError.parseError(
                message: "seqkit stats returned unexpected output"
            )
        }

        let headers = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let values = lines[1].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard headers.count == values.count else {
            throw DatabaseServiceError.parseError(
                message: "seqkit stats header/value mismatch (headers=\(headers.count), values=\(values.count))"
            )
        }

        var map: [String: String] = [:]
        for (header, value) in zip(headers, values) {
            map[header] = value
        }

        func parseInt(_ key: String) -> Int { Int(map[key] ?? "") ?? 0 }
        func parseInt64(_ key: String) -> Int64 { Int64(map[key] ?? "") ?? 0 }
        func parseDouble(_ key: String) -> Double { Double(map[key] ?? "") ?? 0 }

        return SeqkitSummary(
            numSeqs: parseInt("num_seqs"),
            sumLen: parseInt64("sum_len"),
            minLen: parseInt("min_len"),
            avgLen: parseDouble("avg_len"),
            maxLen: parseInt("max_len"),
            q20: parseDouble("Q20(%)"),
            q30: parseDouble("Q30(%)"),
            avgQual: parseDouble("AvgQual"),
            gcPercent: parseDouble("GC(%)")
        )
    }

    private func loadReadLengthHistogramFromFASTQ(
        from fastqURL: URL,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [Int: Int] {
        guard FileManager.default.fileExists(atPath: fastqURL.path) else {
            throw DatabaseServiceError.notFound(accession: fastqURL.lastPathComponent)
        }

        var histogram: [Int: Int] = [:]
        var readCount = 0
        let reader = FASTQReader(validateSequence: false)

        for try await record in reader.records(from: fastqURL) {
            histogram[record.length, default: 0] += 1
            readCount += 1
            if readCount % 10_000 == 0 {
                progress?(readCount)
                try Task.checkCancellation()
            }
        }

        progress?(readCount)
        return histogram
    }

    private func histogramMedian(_ histogram: [Int: Int], totalCount: Int) -> Int {
        guard totalCount > 0 else { return 0 }
        let target = (totalCount + 1) / 2
        var cumulative = 0
        for (length, count) in histogram.sorted(by: { $0.key < $1.key }) {
            cumulative += count
            if cumulative >= target {
                return length
            }
        }
        return histogram.keys.max() ?? 0
    }

    private func histogramN50(_ histogram: [Int: Int], totalBases: Int64) -> Int {
        guard totalBases > 0 else { return 0 }
        let target = Double(totalBases) / 2.0
        var cumulative: Double = 0
        for (length, count) in histogram.sorted(by: { $0.key > $1.key }) {
            cumulative += Double(length * count)
            if cumulative >= target {
                return length
            }
        }
        return histogram.keys.max() ?? 0
    }
}

// MARK: - Streaming Download Helper

/// Downloads a file using URLSession downloadTask with byte-level progress callbacks.
///
/// Unlike `URLSession.shared.data(for:)`, this uses the delegate-based `downloadTask`
/// API which reliably fires `didWriteData` progress callbacks. The file is written to
/// a temp location and its contents returned as Data.
///
/// - Parameters:
///   - url: The URL to download.
///   - totalBytes: Expected total size (used when Content-Length header is absent).
///   - progressHandler: Called with (bytesDownloaded, totalBytes?) during download.
/// - Returns: The downloaded data.
/// - Throws: `DatabaseServiceError` on network or HTTP errors.
private func streamingDownload(
    url: URL,
    totalBytes: Int64?,
    progressHandler: @escaping @Sendable (Int64, Int64?) -> Void
) async throws -> Data {
    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let knownTotal: Int64?
        let progress: @Sendable (Int64, Int64?) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(knownTotal: Int64?, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.knownTotal = knownTotal
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite expected: Int64) {
            let total: Int64? = expected > 0 ? expected : knownTotal
            progress(totalBytesWritten, total)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + location.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: location, to: tmp)
            } catch {
                continuation?.resume(throwing: error)
                continuation = nil
                return
            }
            guard let resp = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(resp.statusCode) else {
                let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
                continuation?.resume(throwing: DatabaseServiceError.serverError(
                    message: "HTTP \(code) downloading \(downloadTask.originalRequest?.url?.lastPathComponent ?? "file")"
                ))
                continuation = nil
                return
            }
            continuation?.resume(returning: tmp)
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: (any Error)?) {
            if let error, continuation != nil {
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }

    var request = URLRequest(url: url)
    request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 600

    let delegate = Delegate(knownTotal: totalBytes, progress: progressHandler)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

    let tempURL: URL = try await withCheckedThrowingContinuation { continuation in
        delegate.continuation = continuation
        session.downloadTask(with: request).resume()
    }
    session.invalidateAndCancel()

    let data = try Data(contentsOf: tempURL)
    try? FileManager.default.removeItem(at: tempURL)
    return data
}

// MARK: - DatabaseSource Extension

extension DatabaseSource {
    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .ncbi:
            return "NCBI Search"
        case .ena:
            return "SRA Search"
        case .ddbj:
            return "DNA Data Bank of Japan"
        case .pathoplexus:
            return "Pathoplexus"
        case .local:
            return "Local Database"
        }
    }
}

// MARK: - SearchResultRecord Hashable

extension SearchResultRecord: Hashable {
    public func hash(into hasher: inout Hasher) {
        // Use `id` (NCBI UID) instead of `accession` to match auto-synthesized Equatable.
        // Using only `accession` caused Set corruption when records had the same accession
        // but different UIDs (e.g., multiple viral isolates), resulting in selections being lost.
        hasher.combine(id)
    }
}

// NOTE: This view model uses detached tasks for modal-sheet compatibility and only
// mutates actor-isolated state through explicit main-runloop callbacks.
extension DatabaseBrowserViewModel: @unchecked Sendable {}
