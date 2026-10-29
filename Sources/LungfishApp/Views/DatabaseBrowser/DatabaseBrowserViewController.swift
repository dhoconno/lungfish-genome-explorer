// DatabaseBrowserViewController.swift - Database search and download UI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12), ENA Integration Specialist (Role 13)

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit

/// Logger for database browser operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "DatabaseBrowser")

/// Executes a MainActor-isolated block on the main thread in a way that works during modal sessions.
/// Uses Timer with commonModes run loop mode to ensure execution during modal sheet display.
func performOnMainRunLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
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

func performOnMainRunLoopAsync<T: Sendable>(_ block: @escaping @MainActor @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        performOnMainRunLoop {
            continuation.resume(returning: block())
        }
    }
}

private func effectiveSRABaseCount(enaRecord: ENAReadRecord?, ncbiRun: SRARunInfo?) -> Int? {
    if let baseCount = enaRecord?.baseCount, baseCount > 0 {
        return baseCount
    }
    if let bases = ncbiRun?.bases, bases > 0 {
        return bases
    }
    return nil
}

private func mergedSRASearchResultRecord(
    accession: String,
    enaRecord: ENAReadRecord?,
    ncbiRun: SRARunInfo?
) -> SearchResultRecord? {
    guard enaRecord != nil || ncbiRun != nil else { return nil }

    let title: String = {
        if let experimentTitle = enaRecord?.experimentTitle, !experimentTitle.isEmpty {
            return experimentTitle
        }
        let strategy = enaRecord?.libraryStrategy ?? ncbiRun?.libraryStrategy ?? "Unknown"
        let layout = enaRecord?.libraryLayout ?? ncbiRun?.libraryLayout ?? ""
        return layout.isEmpty ? "\(accession) - \(strategy)" : "\(accession) - \(strategy) \(layout)"
    }()

    return SearchResultRecord(
        id: accession,
        accession: accession,
        title: title,
        organism: ncbiRun?.organism,
        length: effectiveSRABaseCount(enaRecord: enaRecord, ncbiRun: ncbiRun),
        date: enaRecord?.firstPublic ?? ncbiRun?.releaseDate,
        source: .ena
    )
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
    private(set) var dialogState: DatabaseSearchDialogState!

    /// Completion handler called when user cancels
    public var onCancel: (() -> Void)?

    /// Called when a download is kicked off (sheet should dismiss immediately).
    public var onDownloadStarted: (() -> Void)?

    /// Project/window route used for completed bundle delivery.
    public var routeContext: OperationRouteContext? {
        didSet {
            dialogState?.routeContext = routeContext
        }
    }

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
        dialogState.routeContext = routeContext

        if let searchType = initialSearchType {
            dialogState.genBankGenomesViewModel.ncbiSearchType = searchType
        }

        dialogState.applyCallbacks(
            onCancel: { [weak self] in
                guard let self = self else { return }
                self.dialogState.cancelAllSearches()
                // The SRA lookup runs behind this Cancel, so Cancel ends the SRA rows that still prepare.
                self.dialogState.sraRunsViewModel.cancelPreparingSRADownloads()
                if let window = self.view.window {
                    if let parent = window.sheetParent {
                        parent.endSheet(window)
                    } else { window.close() }
                }
                self.onCancel?()
            },
            onDownloadStarted: { [weak self] in
                guard let self = self else { return }
                self.onDownloadStarted?()
            }
        )

        hostingView = Self.makeSheetHostingView(rootView: DatabaseSearchDialog(state: dialogState))
        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("Database browser loaded for \(self.databaseSource.displayName, privacy: .public)")
    }

    public override func viewDidDisappear() {
        super.viewDidDisappear()
        dialogState?.cancelAllSearches()
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
        case .accession: return "Search by accession number (e.g., NM_000546.6, NM_000059.4)"
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

enum LargeResultAction: Sendable {
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

private struct DatabaseSearchRequestIdentity: Hashable, Sendable {
    let source: String
    let ncbiSearchType: String
    let searchText: String
    let searchScope: String
    let filtersDigest: String
}

private struct DatabaseSearchRequestToken: Sendable {
    let generation: UInt64
    let identity: DatabaseSearchRequestIdentity
}

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
    /// Retains the exact imported query for retry without changing ordinary accession searches.
    private var importedGenBankQuery: String?

    /// Where the SRA "Download source" setting is stored, and NCBI's run info from the last SRA search.
    nonisolated let defaultsSuiteName: String? // nil is the standard defaults
    var sraNCBIRunsFromSearch: [String: SRARunInfo] = [:]
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

    /// Whether GenBank nucleotide downloads should prefer NCBI GFF3 annotations.
    @Published var includeGFF3Annotations: Bool = true

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

    var bulkSelectionActionTitle: String? {
        if !selectedRecords.isEmpty {
            return "Deselect all"
        }
        return filteredResults.isEmpty ? nil : "Select all"
    }

    var isBulkSelectionActionEnabled: Bool {
        bulkSelectionActionTitle != nil && !isSearching && !isDownloading
    }

    func selectAllVisibleResults() {
        selectedRecords.formUnion(filteredResults)
        selectedRecord = filteredResults.first ?? selectedRecords.first
    }

    func deselectAllResults() {
        selectedRecords.removeAll()
        selectedRecord = nil
    }

    func performBulkSelectionAction() {
        guard isBulkSelectionActionEnabled else { return }
        if selectedRecords.isEmpty {
            selectAllVisibleResults()
        } else {
            deselectAllResults()
        }
    }

    /// Current search phase (for progress tracking)
    @Published var searchPhase: SearchPhase = .idle

    /// Whether a search is in progress (computed from searchPhase)
    var isSearching: Bool {
        searchPhase.isInProgress
    }

    var testingHasCurrentSearchTask: Bool {
        currentSearchTask != nil
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
    private var searchValidationSession = AsyncValidationSession<DatabaseSearchRequestIdentity, SearchResults>()

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

    /// Whether search text is valid.
    var isSearchTextValid: Bool {
        if isPathoplexusSearch {
            return pathoplexusOrganism != nil
        }
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

    /// The hint under the search field. The SRA Runs pane finds run
    /// accessions, so its Accession hint gives run examples, not the RefSeq
    /// examples the GenBank pane uses.
    var searchScopeHelpText: String {
        if isSRASearch, searchScope == .accession {
            return "Search by run accession (e.g., SRR36291587, ERR12259924)"
        }
        return searchScope.helpText
    }

    // MARK: - Callbacks

    /// Called when user cancels
    var onCancel: (() -> Void)?

    /// Called when a download is kicked off so the sheet can dismiss immediately.
    var onDownloadStarted: (() -> Void)?

    /// Project/window route used for operation completion delivery.
    var routeContext: OperationRouteContext?

    /// The browser's owning window, independent of which window is currently key.
    weak var downloadPresentationWindow: NSWindow?

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

    let ncbiService: NCBIService
    let enaService: ENAService
    private let automationBackend: DatabaseSearchAutomationBackend?
    private let largeResultActionProvider: (@Sendable (_ totalCount: Int, _ sourceLabel: String) async -> LargeResultAction)?

    // MARK: - Initialization

    init(
        source: DatabaseSource,
        ncbiService: NCBIService = NCBIService(),
        enaService: ENAService = ENAService(),
        automationBackend: DatabaseSearchAutomationBackend? = nil,
        largeResultActionProvider: (@Sendable (_ totalCount: Int, _ sourceLabel: String) async -> LargeResultAction)? = nil,
        defaultsSuiteName: String? = nil
    ) {
        self.source = source
        self.defaultsSuiteName = defaultsSuiteName
        self.ncbiService = ncbiService
        self.enaService = enaService
        self.automationBackend = automationBackend
        self.largeResultActionProvider = largeResultActionProvider
        if source == .pathoplexus {
            self.pathoplexusOrganism = pathoplexusOrganisms.first { $0.id == "mpox" }
        }
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
        importedGenBankQuery = nil
        // Pathoplexus filters
        clearPathoplexusFilters()
    }

    /// Imports accession list from a CSV or text file.
    /// Opens a file panel, parses the file, and triggers batch search.
    func importAccessionList() {
        guard !isDownloading else { return }
        let panel = DatabaseBrowserFilePanelFactory.accessionListImportPanel()
        let importSource = source
        let importSearchType = ncbiSearchType

        let handleSelection: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self, self.source == importSource,
                  self.ncbiSearchType == importSearchType else { return }
            self.handleImportedAccessionList(url: url)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handleSelection)
        } else {
            panel.begin(completionHandler: handleSelection)
        }
    }

    /// Uses the same file-import entry point for SRA and GenBank nucleotide lists.
    /// Parsing finishes before mutating search state, so an invalid file is atomic.
    func importAccessionList(at url: URL) throws {
        guard !isDownloading else {
            throw DatabaseServiceError.invalidQuery(reason: "Wait for the current download before importing accessions.")
        }
        let accessions: [String]
        if isSRASearch {
            accessions = try SRAAccessionParser.parseCSVFile(at: url)
            guard !accessions.isEmpty else {
                throw DatabaseServiceError.invalidQuery(reason: "No valid SRA accessions were found in the selected file.")
            }
        } else if isNCBISearch && ncbiSearchType == .nucleotide {
            accessions = try GenBankAccessionParser.parseCSVFile(at: url)
        } else {
            throw DatabaseServiceError.invalidQuery(reason: "Accession lists are supported in SRA Runs and GenBank Nucleotide mode.")
        }
        importedAccessions = accessions
        searchText = isNCBISearch
            ? accessions.joined(separator: ", ")
            : "\(accessions.count) accessions from \(url.lastPathComponent)"
        importedGenBankQuery = isNCBISearch ? searchText : nil
        searchScope = .accession
        performSearch()
    }

    private func handleImportedAccessionList(url: URL) {
        do {
            try importAccessionList(at: url)
        } catch {
            presentDatabaseBrowserAlert(FailurePresenter.alert(for: DatabaseBrowserFailureReports.importAccessionList(error)))
        }
    }

    private func presentDatabaseBrowserAlert(_ alert: NSAlert) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.window.center()
            alert.window.makeKeyAndOrderFront(nil)
        }
    }

    /// Cancels the current search operation
    func cancelSearch() {
        currentSearchTask?.cancel()
        currentSearchTask = nil
        searchValidationSession.cancel()
        searchPhase = .idle
    }

    private func currentSearchIdentity() -> DatabaseSearchRequestIdentity {
        DatabaseSearchRequestIdentity(
            source: String(describing: source),
            ncbiSearchType: String(describing: ncbiSearchType),
            searchText: searchText,
            searchScope: String(describing: searchScope),
            filtersDigest: [
                organismFilter,
                locationFilter,
                geneFilter,
                authorFilter,
                journalFilter,
                minLength,
                maxLength,
                String(refseqOnly),
                String(describing: moleculeType),
                pubDateFrom,
                pubDateTo,
                propertyFilters.map { String(describing: $0) }.sorted().joined(separator: ","),
                virusHostFilter,
                virusGeoLocationFilter,
                String(describing: virusCompletenessFilter),
                virusReleasedSinceFilter,
                String(virusAnnotatedOnly),
                String(describing: sraPlatformFilter),
                String(describing: sraStrategyFilter),
                String(describing: sraLayoutFilter),
                sraMinMbases,
                sraPubDateFrom,
                sraPubDateTo,
                importedAccessions.joined(separator: ","),
                String(sraResultLimit),
                pathoplexusOrganism?.id ?? "",
                pathoplexusCountryFilter,
                pathoplexusCladeFilter,
                pathoplexusLineageFilter,
                pathoplexusHostFilter,
                pathoplexusNucMutationsFilter,
                pathoplexusAAMutationsFilter,
                pathoplexusDateFrom,
                pathoplexusDateTo,
                String(describing: pathoplexusINSDCFilter),
            ].joined(separator: "\u{1f}")
        )
    }

    private func beginSearchValidation() -> DatabaseSearchRequestToken {
        let token = searchValidationSession.begin(input: currentSearchIdentity())
        return DatabaseSearchRequestToken(generation: token.generation, identity: token.identity)
    }

    private func applySearchUpdate(
        for token: DatabaseSearchRequestToken,
        _ update: () -> Void
    ) {
        guard shouldAcceptSearchResult(for: token) else { return }
        objectWillChange.send()
        update()
    }

    private func shouldAcceptSearchResult(for token: DatabaseSearchRequestToken) -> Bool {
        let requestToken = AsyncRequestToken(
            generation: token.generation,
            identity: token.identity
        )
        guard searchValidationSession.shouldAccept(resultFor: requestToken),
              token.identity == currentSearchIdentity()
        else { return false }
        return true
    }

    private func finishSearchTask(for token: DatabaseSearchRequestToken) {
        let requestToken = AsyncRequestToken(
            generation: token.generation,
            identity: token.identity
        )
        guard searchValidationSession.shouldAccept(resultFor: requestToken) else { return }
        currentSearchTask = nil
        if token.identity != currentSearchIdentity(), searchPhase.isInProgress {
            searchPhase = .idle
        }
    }

    private func resolveLargeResultAction(
        totalCount: Int,
        sourceLabel: String,
        for token: DatabaseSearchRequestToken
    ) async throws -> LargeResultAction {
        guard shouldAcceptSearchResult(for: token) else {
            throw CancellationError()
        }
        let action: LargeResultAction
        if let largeResultActionProvider {
            action = await largeResultActionProvider(totalCount, sourceLabel)
        } else {
            action = await confirmLargeResultActionDialog(totalCount: totalCount, sourceLabel: sourceLabel)
        }
        guard shouldAcceptSearchResult(for: token) else {
            throw CancellationError()
        }
        return action
    }

    /// Initiates a search operation.
    ///
    /// Uses Task.detached to run the async search on a background executor,
    /// allowing the search to proceed even when presented in a modal sheet.
    /// This is necessary because Task {} inherits MainActor isolation and
    /// may not execute properly during modal sheet sessions.
    func performSearch() {
        guard isSearchTextValid else {
            errorMessage = isPathoplexusSearch
                ? "Select a Pathoplexus organism"
                : "Please enter a search term"
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
        selectedRecord = nil
        selectedRecords = []
        totalResultCount = 0
        hasMoreResults = false
        let capturedImportedAccessions: [String]
        if importedAccessions.isEmpty, isNCBISearch, ncbiSearchType == .nucleotide,
           searchScope == .accession, searchText == importedGenBankQuery,
           let accessions = try? GenBankAccessionParser.parseAccessionList(searchText) {
            capturedImportedAccessions = accessions
        } else {
            capturedImportedAccessions = importedAccessions
        }
        importedAccessions = []  // Clear after capture to prevent stale reuse on next search
        let searchToken = beginSearchValidation()

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

                    await performOnMainRunLoopAsync {
                        guard let self else { return }
                        self.applySearchUpdate(for: searchToken) {
                            self.errorMessage = nil
                            self.results = response.records
                            self.selectedRecord = nil
                            self.selectedRecords = []
                            self.totalResultCount = response.totalCount
                            self.hasMoreResults = response.hasMore
                            self.searchPhase = .complete(count: response.records.count)
                            self.currentSearchTask = nil
                        }
                    }
                } catch {
                    await performOnMainRunLoopAsync {
                        guard let self else { return }
                        self.applySearchUpdate(for: searchToken) {
                            self.errorMessage = error.localizedDescription
                            self.searchPhase = .failed(error.localizedDescription)
                            self.currentSearchTask = nil
                        }
                    }
                }

                await performOnMainRunLoopAsync {
                    guard let self else { return }
                    self.finishSearchTask(for: searchToken)
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
                    self.applySearchUpdate(for: searchToken) {
                        self.searchPhase = .searching
                    }
                }

                var searchResults: SearchResults
                // One line saying an archive failed while the other answered.
                var searchNotice: String?
                var ncbiRunsFromSearch: [String: SRARunInfo] = [:]

                switch currentSource {
                case .ncbi:
                    performOnMainRunLoop { [weak self] in
                        guard let self = self else { return }
                        self.applySearchUpdate(for: searchToken) {
                            self.searchPhase = .loadingDetails
                        }
                    }

                    // Use the appropriate search method based on search type
                    switch searchType {
                    case .nucleotide:
                        if !capturedImportedAccessions.isEmpty {
                            searchResults = try await ncbi.lookupNucleotideAccessions(capturedImportedAccessions)
                            break
                        }
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
                                    guard let self else { throw CancellationError() }
                                    let action = try await self.resolveLargeResultAction(
                                        totalCount: page.totalCount,
                                        sourceLabel: "NCBI GenBank",
                                        for: searchToken
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
                                self.applySearchUpdate(for: searchToken) {
                                    self.results = recordsSnapshot
                                    self.totalResultCount = totalSnapshot
                                    self.hasMoreResults = loadedSnapshot < totalSnapshot
                                    self.searchPhase = .loadingAllResults(loaded: loadedSnapshot, total: totalSnapshot)
                                }
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
                            guard let self = self else { return }
                            self.applySearchUpdate(for: searchToken) {
                                self.virusNextPageToken = nextToken
                            }
                        }

                        guard !searchResults.records.isEmpty else {
                            performOnMainRunLoop { [weak self] in
                                guard let self = self else { return }
                                self.applySearchUpdate(for: searchToken) {
                                    self.results = []
                                    self.totalResultCount = searchResults.totalCount
                                    self.hasMoreResults = false
                                    self.searchPhase = .complete(count: 0)
                                    self.currentSearchTask = nil
                                }
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
                                    guard let self else { throw CancellationError() }
                                    let action = try await self.resolveLargeResultAction(
                                        totalCount: page.totalCount,
                                        sourceLabel: "NCBI Assembly",
                                        for: searchToken
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
                                self.applySearchUpdate(for: searchToken) {
                                    self.results = recordsSnapshot
                                    self.totalResultCount = totalSnapshot
                                    self.hasMoreResults = loadedSnapshot < totalSnapshot
                                    self.searchPhase = .loadingAllResults(loaded: loadedSnapshot, total: totalSnapshot)
                                }
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
                        self.applySearchUpdate(for: searchToken) {
                            self.searchPhase = .searching
                        }
                    }

                    // ENA adds the FASTQ links and NCBI the organism and dates. Either
                    // archive may fail, and the search fails only when both do.
                    let runLookup = SRARunMetadataLookup(ena: ena, ncbi: ncbi)
                    let reportENAProgress: @Sendable (Int, Int) -> Void = { [weak self] completed, total in
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.applySearchUpdate(for: searchToken) {
                                self.searchPhase = .loadingAllResults(loaded: completed, total: total)
                            }
                        }
                    }
                    let lookup: SRARunMetadataLookup.Outcome

                    // Detect multi-accession input (paste or CSV import)
                    // Check for imported accession list first (from CSV import)
                    let parsedAccessions = !capturedImportedAccessions.isEmpty
                        ? capturedImportedAccessions
                        : SRAAccessionParser.parseAccessionList(query.term)
                    let singleAccession = query.term.trimmingCharacters(in: .whitespaces)
                    if parsedAccessions.count >= 2 || SRAAccessionParser.accessionType(singleAccession) == .run {
                        // An accession list, or one run: look each up in ENA and NCBI at once.
                        let accessions = parsedAccessions.count >= 2 ? parsedAccessions : [singleAccession]
                        logger.info("performSearch: Looking up \(accessions.count) accession(s) in ENA and NCBI")
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.applySearchUpdate(for: searchToken) {
                                self.searchPhase = .loadingDetails
                            }
                        }
                        lookup = try await runLookup.lookUpRuns(accessions, progress: reportENAProgress)

                    } else {
                        // Non-accession query (title, organism, bioproject, author, free text)
                        // Two-step: NCBI ESearch → EFetch runinfo → ENA batch lookup
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
                            guard let self else { throw CancellationError() }
                            let action = try await self.resolveLargeResultAction(
                                totalCount: esearchResult.totalCount,
                                sourceLabel: "NCBI SRA",
                                for: searchToken
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

                        // Step 2: EFetch to get SRA run info
                        performOnMainRunLoop { [weak self] in
                            guard let self = self else { return }
                            self.applySearchUpdate(for: searchToken) {
                                self.searchPhase = .loadingDetails
                            }
                        }
                        let ncbiRuns = try await ncbi.sraEFetchRunInfo(ids: esearchResult.ids)
                        logger.info("performSearch: EFetch resolved \(ncbiRuns.count) SRA runs")

                        guard !ncbiRuns.isEmpty else {
                            searchResults = SearchResults(totalCount: 0, records: [], hasMore: false, nextCursor: nil)
                            break
                        }

                        try Task.checkCancellation()

                        // Step 3: Batch ENA lookup for FASTQ metadata. ENA failures keep NCBI's rows.
                        lookup = try await runLookup.addingENARecords(to: ncbiRuns, progress: reportENAProgress)
                    }

                    let records = lookup.runs.compactMap { run in
                        mergedSRASearchResultRecord(accession: run.accession, enaRecord: run.enaRecord, ncbiRun: run.ncbiRun)
                    }
                    searchNotice = lookup.notice
                    ncbiRunsFromSearch = Self.ncbiRunsByAccession(in: lookup)
                    if let searchNotice {
                        logger.warning("performSearch: \(searchNotice, privacy: .public)")
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
                        self.applySearchUpdate(for: searchToken) {
                            self.searchPhase = .loadingDetails
                        }
                    }

                    guard let ppOrganism = capturedPpOrganism?.id else {
                        throw DatabaseServiceError.invalidQuery(reason: "Select a Pathoplexus organism")
                    }
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
                        guard let self else { throw CancellationError() }
                        let action = try await self.resolveLargeResultAction(
                            totalCount: totalCount,
                            sourceLabel: "Pathoplexus",
                            for: searchToken
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
                                self.applySearchUpdate(for: searchToken) {
                                    self.searchPhase = .loadingAllResults(loaded: loadedSnapshot, total: totalSnapshot)
                                }
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
                performOnMainRunLoop { [weak self, searchNotice, ncbiRunsFromSearch] in
                    guard let self = self else { return }
                    self.applySearchUpdate(for: searchToken) {
                        self.sraNCBIRunsFromSearch = ncbiRunsFromSearch
                        self.errorMessage = searchNotice
                        self.results = searchResults.records
                        self.totalResultCount = searchResults.totalCount
                        self.hasMoreResults = searchResults.hasMore
                        self.searchPhase = .complete(count: searchResults.records.count)
                        logger.info("performSearch: UI updated with \(searchResults.records.count) results")
                    }
                }

            } catch is CancellationError {
                logger.info("Search cancelled")
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.applySearchUpdate(for: searchToken) {
                        self.searchPhase = .idle
                    }
                }
            } catch {
                let errorMsg = error.localizedDescription
                logger.error("Search failed: \(errorMsg, privacy: .public)")
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.applySearchUpdate(for: searchToken) {
                        self.errorMessage = "Search failed: \(errorMsg)"
                        self.searchPhase = .failed(errorMsg)
                    }
                }
            }

            performOnMainRunLoop { [weak self] in
                guard let self = self else { return }
                self.finishSearchTask(for: searchToken)
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
                    await performOnMainRunLoopAsync {
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }

        // A download with no project is refused before the large-batch question, so nobody confirms
        // a download that cannot run. The begin helper keeps the same refusal for its other callers.
        guard routeContext?.projectURL != nil else {
            Self.refuseBatchDownloadWithoutProject(source: source, searchType: ncbiSearchType, window: NSApp?.keyWindow)
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
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                errorMessage = "No window available to confirm batch download"
                return
            }
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.continueBatchDownload(recordsToDownload: recordsToDownload)
            }
            return
        }

        continueBatchDownload(recordsToDownload: recordsToDownload)
    }

    private func continueBatchDownload(recordsToDownload: [SearchResultRecord]) {
        if let projectURL = routeContext?.projectURL {
            guard AppDelegate.shared?.canWriteProjectOutputs(
                projectURL: projectURL,
                windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
                workflowName: "Database download",
                presentingWindow: AppDelegate.shared?.targetMainWindowController(routeContext: routeContext)?.window
                    ?? NSApp.keyWindow
                    ?? NSApp.mainWindow
            ) ?? true else {
                return
            }
        }

        let totalCount = recordsToDownload.count

        // Capture services and values for task
        let ncbi = ncbiService
        let currentSource = source
        let searchType = ncbiSearchType
        let includeGFF3Annotations = includeGFF3Annotations

        if currentSource == .pathoplexus, pathoplexusOrganism == nil {
            errorMessage = "Select a Pathoplexus organism"
            return
        }
        let ppOrganism = pathoplexusOrganism?.id ?? ""

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

        // Register the Operations panel row, and start downloading only when it began.
        Self.beginBatchDownloadOperation(
            title: downloadTitle,
            accessions: recordsToDownload.map(\.accession),
            source: currentSource,
            searchType: searchType,
            routeContext: routeContext,
            includeGFF3Annotations: includeGFF3Annotations,
            pathoplexusOrganism: currentSource == .pathoplexus ? ppOrganism : nil
        ) { downloadCenterTaskID in
            isDownloading = true
            downloadProgress = 0
            errorMessage = nil

            // Log details about selected records for debugging
            logger.info("performBatchDownload: Starting download of \(totalCount) record(s)")
            logger.info("performBatchDownload: selectedRecords.count = \(self.selectedRecords.count)")
            for (idx, record) in recordsToDownload.enumerated() {
                logger.info("performBatchDownload: Record[\(idx)] id=\(record.id, privacy: .public) accession=\(record.accession, privacy: .public)")
            }

            if currentSource == .ena {
                prepareSRADownload(records: recordsToDownload, operationID: downloadCenterTaskID)
                return
            }

            // Dismiss the sheet immediately so the user can see the main window
            // while the download progresses in the background via DownloadCenter.
            // Bundle delivery happens through DownloadCenter.onBundleReady (set by
            // AppDelegate at startup), eliminating the fragile callback chain through
            // the sheet controller which gets deallocated on dismissal.
            onDownloadStarted?()

            let batchProjectURL = routeContext?.projectURL

            // Use Task.detached to break out of MainActor context.
            // This is critical when running in a modal sheet - regular Task {}
            // inherits MainActor isolation and may not execute due to the modal
            // run loop blocking task scheduling on MainActor.
            Task.detached {
                var downloadedURLs: [URL] = []
                var failedCount = 0
                var failureDetails: [String] = []

                for (index, record) in recordsToDownload.enumerated() {
                    // Update progress via performOnMainRunLoop for modal compatibility.
                    // DownloadCenter update must not be gated on [weak self] since the
                    // view model may already be deallocated after sheet dismissal.
                    let progressFraction = Double(index) / Double(totalCount)
                    performOnMainRunLoop {
                        _ = DownloadCenter.shared.update(
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
                            // A genome row runs `lungfish-cli fetch genome` into the folder the
                            // row's command names (lane A44, DatabaseBrowserViewModel+GenomeRowDownload.swift).
                            if searchType == .genome {
                                fileURL = try await Self.downloadGenomeRow(
                                    record, index: index, totalCount: totalCount,
                                    operationID: downloadCenterTaskID, ncbi: ncbi, projectURL: batchProjectURL
                                )
                            } else {
                                // A nucleotide or virus row ends as a .lungfishref bundle. It runs
                                // `lungfish-cli fetch ncbi --bundle` into the folder the row's command
                                // names (lane A45, DatabaseBrowserViewModel+NucleotideRowDownload.swift).
                                fileURL = try await Self.downloadNucleotideRow(
                                    record, index: index, totalCount: totalCount, operationID: downloadCenterTaskID,
                                    ncbi: ncbi, includeGFF3Annotations: includeGFF3Annotations, projectURL: batchProjectURL
                                )
                            }

                        case .ena:
                            // This case should not be reachable since performBatchDownload()
                            // returns early for ENA source before entering this Task.detached.
                            assertionFailure("ENA downloads should not reach this code path")
                            throw DatabaseServiceError.invalidQuery(
                                reason: "Internal error: ENA downloads should use the config sheet path"
                            )

                        case .pathoplexus:
                            // A Pathoplexus row runs `lungfish-cli fetch pathoplexus` into the folder
                            // the row's command names (lane A45, DatabaseBrowserViewModel+PathoplexusRowDownload.swift).
                            fileURL = try await Self.downloadPathoplexusRow(
                                record, index: index, totalCount: totalCount,
                                operationID: downloadCenterTaskID, organism: ppOrganism,
                                ncbi: ncbi, includeGFF3Annotations: includeGFF3Annotations, projectURL: batchProjectURL
                            )

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
                            _ = DownloadCenter.shared.update(
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
                        _ = DownloadCenter.shared.fail(
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
                        _ = DownloadCenter.shared.complete(
                            id: downloadCenterTaskID,
                            detail: detail,
                            bundleURLs: finalDownloadedURLs
                        )
                    }

                    logger.info("performBatchDownload: Complete - \(finalDownloadedURLs.count) downloaded, \(finalFailedCount) failed")
                }
            }
        }
    }
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
