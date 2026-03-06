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

/// Logger for database browser operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "DatabaseBrowser")

/// Executes a MainActor-isolated block on the main thread in a way that works during modal sessions.
/// Uses Timer with commonModes run loop mode to ensure execution during modal sheet display.
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
/// Provides search interface for NCBI and ENA databases with download capability.
@MainActor
public class DatabaseBrowserViewController: NSViewController {

    // MARK: - Properties

    /// The database source being browsed
    public let databaseSource: DatabaseSource

    /// The SwiftUI hosting view
    private var hostingView: NSHostingView<DatabaseBrowserView>!

    /// View model for the browser
    private var viewModel: DatabaseBrowserViewModel!

    /// Completion handler called when user cancels
    public var onCancel: (() -> Void)?

    /// Called when a download is kicked off (sheet should dismiss immediately).
    public var onDownloadStarted: (() -> Void)?

    /// Optional initial NCBI search type to pre-select when the browser opens.
    ///
    /// Set this before presenting the controller to open with a specific search type
    /// (e.g., `.genome` for the "Download Genome Assembly" menu action).
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
        viewModel = DatabaseBrowserViewModel(source: databaseSource)

        // Apply initial search type if specified (e.g., for genome assembly downloads)
        if let searchType = initialSearchType {
            viewModel.ncbiSearchType = searchType
        }

        // Set up download started callback — dismiss sheet immediately
        viewModel.onDownloadStarted = { [weak self] in
            guard let self = self else { return }
            self.onDownloadStarted?()
        }

        // Set up cancel callback
        viewModel.onCancel = { [weak self] in
            guard let self = self else { return }
            if let window = self.view.window {
                if let parent = window.sheetParent {
                    parent.endSheet(window)
                } else {
                    window.close()
                }
            }
            self.onCancel?()
        }

        let browserView = DatabaseBrowserView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: browserView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 750, height: 550)
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

    public var id: String { rawValue }

    /// SF Symbol for the scope
    var icon: String {
        switch self {
        case .all: return "magnifyingglass"
        case .accession: return "number"
        case .organism: return "leaf"
        case .title: return "text.alignleft"
        }
    }

    /// Help text explaining what this scope searches
    var helpText: String {
        switch self {
        case .all: return "Searches accession numbers, organism names, titles, and descriptions"
        case .accession: return "Search by accession number (e.g., NC_002549, MN908947)"
        case .organism: return "Search by organism or species name"
        case .title: return "Search within sequence titles and descriptions"
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
    case complete(count: Int)
    case failed(String)

    /// Progress value from 0 to 1
    var progress: Double {
        switch self {
        case .idle: return 0
        case .connecting: return 0.15
        case .searching: return 0.4
        case .loadingDetails: return 0.7
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
        case .connecting, .searching, .loadingDetails: return true
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

// MARK: - DatabaseBrowserViewModel

/// View model for the database browser.
@MainActor
public class DatabaseBrowserViewModel: ObservableObject {

    // MARK: - Published Properties

    /// The database source
    let source: DatabaseSource

    /// NCBI search type (GenBank, Genome, Virus)
    @Published var ncbiSearchType: NCBISearchType = .nucleotide

    /// Search query text
    @Published var searchText = ""

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

    /// Search results from the API
    @Published var results: [SearchResultRecord] = []

    /// Local filter text for filtering displayed results without re-querying the API
    @Published var localFilterText: String = ""

    /// Filtered results based on localFilterText (computed property)
    var filteredResults: [SearchResultRecord] {
        guard !localFilterText.isEmpty else { return results }
        let filter = localFilterText.lowercased()
        return results.filter { record in
            record.accession.lowercased().contains(filter) ||
            record.title.lowercased().contains(filter) ||
            (record.organism?.lowercased().contains(filter) ?? false) ||
            (record.host?.lowercased().contains(filter) ?? false) ||
            (record.geoLocation?.lowercased().contains(filter) ?? false) ||
            (record.isolateName?.lowercased().contains(filter) ?? false) ||
            (record.pangolinClassification?.lowercased().contains(filter) ?? false)
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

    /// Data use terms filter for Pathoplexus
    @Published var pathoplexusDataUseTerms: DataUseTerms?

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
        if pathoplexusDataUseTerms != nil { count += 1 }
        if !pathoplexusDateFrom.isEmpty || !pathoplexusDateTo.isEmpty { count += 1 }
        if !minLength.isEmpty || !maxLength.isEmpty { count += 1 }
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
        pathoplexusDataUseTerms = nil
        pathoplexusDateFrom = ""
        pathoplexusDateTo = ""
        minLength = ""
        maxLength = ""
    }

    // MARK: - Services

    private let ncbiService = NCBIService()
    private let enaService = ENAService()

    /// View model for genome assembly downloads (FASTA + GFF3 + bundle building).
    private lazy var genomeDownloadViewModel = GenomeDownloadViewModel(ncbiService: ncbiService)

    /// View model for GenBank nucleotide downloads to .lungfishref bundles.
    private lazy var genBankDownloadViewModel = GenBankBundleDownloadViewModel(ncbiService: ncbiService)

    // MARK: - Initialization

    init(source: DatabaseSource) {
        self.source = source
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
        // Pathoplexus filters
        clearPathoplexusFilters()
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

        // Capture Pathoplexus-specific filters
        let capturedPpOrganism = pathoplexusOrganism
        let capturedPpCountry = pathoplexusCountryFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpClade = pathoplexusCladeFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpLineage = pathoplexusLineageFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpHost = pathoplexusHostFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpNucMutations = pathoplexusNucMutationsFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpAAMutations = pathoplexusAAMutationsFilter.trimmingCharacters(in: .whitespaces)
        let capturedPpDataUseTerms = pathoplexusDataUseTerms
        let capturedPpDateFrom = pathoplexusDateFrom.trimmingCharacters(in: .whitespaces)
        let capturedPpDateTo = pathoplexusDateTo.trimmingCharacters(in: .whitespaces)

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

                let searchResults: SearchResults

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
                        let nucleotideResult = try await ncbi.searchNucleotide(
                            term: query.term,
                            retmax: query.limit,
                            retstart: query.offset,
                            refseqOnly: useRefseqOnly
                        )
                        logger.info("performSearch: Nucleotide search returned \(nucleotideResult.totalCount) total, \(nucleotideResult.ids.count) IDs")

                        guard !nucleotideResult.ids.isEmpty else {
                            performOnMainRunLoop { [weak self] in
                                self?.objectWillChange.send()
                                self?.results = []
                                self?.totalResultCount = nucleotideResult.totalCount
                                self?.hasMoreResults = false
                                self?.searchPhase = .complete(count: 0)
                            }
                            return
                        }

                        let summaries = try await ncbi.esummary(database: .nucleotide, ids: nucleotideResult.ids)
                        let records = summaries.map { summary in
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
                        let hasMore = nucleotideResult.totalCount > (query.offset + records.count)
                        searchResults = SearchResults(
                            totalCount: nucleotideResult.totalCount,
                            records: records,
                            hasMore: hasMore,
                            nextCursor: hasMore ? String(query.offset + records.count) : nil
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
                        // Search assemblies
                        logger.info("performSearch: Calling NCBI genome search")
                        let genomeResult = try await ncbi.searchGenome(
                            term: query.term,
                            retmax: query.limit,
                            retstart: query.offset
                        )
                        logger.info("performSearch: Genome search returned \(genomeResult.totalCount) total, \(genomeResult.ids.count) IDs")

                        guard !genomeResult.ids.isEmpty else {
                            performOnMainRunLoop { [weak self] in
                                self?.objectWillChange.send()
                                self?.results = []
                                self?.totalResultCount = genomeResult.totalCount
                                self?.hasMoreResults = false
                                self?.searchPhase = .complete(count: 0)
                            }
                            return
                        }

                        let assemblySummaries = try await ncbi.assemblyEsummary(ids: genomeResult.ids)
                        let records = assemblySummaries.map { summary in
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
                        let hasMore = genomeResult.totalCount > (query.offset + records.count)
                        searchResults = SearchResults(
                            totalCount: genomeResult.totalCount,
                            records: records,
                            hasMore: hasMore,
                            nextCursor: hasMore ? String(query.offset + records.count) : nil
                        )
                    }

                case .ena:
                    performOnMainRunLoop { [weak self] in
                        guard let self = self else { return }
                        self.objectWillChange.send()
                        self.searchPhase = .loadingDetails
                    }
                    // Use searchReads() for SRA run data (SRR accessions) instead of search() which is for sequences
                    logger.info("performSearch: Calling ENA searchReads for SRA data")
                    let readRecords = try await ena.searchReads(term: query.term, limit: query.limit, offset: query.offset)
                    // Convert ENAReadRecord to SearchResultRecord
                    let records = readRecords.map { record -> SearchResultRecord in
                        SearchResultRecord(
                            id: record.runAccession,
                            accession: record.runAccession,
                            title: record.experimentTitle ?? "\(record.runAccession) - \(record.libraryStrategy ?? "Unknown") \(record.libraryLayout ?? "")",
                            organism: nil,  // ENAReadRecord doesn't have organism
                            length: record.baseCount,
                            date: record.firstPublic,
                            source: .ena
                        )
                    }
                    searchResults = SearchResults(
                        totalCount: records.count,  // ENA searchReads doesn't return total count
                        records: records,
                        hasMore: records.count >= query.limit,
                        nextCursor: records.count >= query.limit ? String(query.offset + records.count) : nil
                    )
                    logger.info("performSearch: ENA searchReads returned \(records.count) SRA runs")

                case .pathoplexus:
                    performOnMainRunLoop { [weak self] in
                        guard let self = self else { return }
                        self.objectWillChange.send()
                        self.searchPhase = .loadingDetails
                    }

                    let ppOrganism = capturedPpOrganism?.id ?? "mpox"
                    logger.info("performSearch: Calling Pathoplexus search for organism=\(ppOrganism, privacy: .public)")

                    // Build Pathoplexus-specific filters
                    let dateFormatter = DateFormatter()
                    dateFormatter.dateFormat = "yyyy-MM-dd"

                    var ppFilters = PathoplexusFilters()
                    if !capturedPpCountry.isEmpty { ppFilters.geoLocCountry = capturedPpCountry }
                    if !capturedPpClade.isEmpty { ppFilters.clade = capturedPpClade }
                    if !capturedPpLineage.isEmpty { ppFilters.lineage = capturedPpLineage }
                    if !capturedPpHost.isEmpty { ppFilters.hostNameScientific = capturedPpHost }
                    ppFilters.dataUseTerms = capturedPpDataUseTerms
                    if let minLen = query.minLength, minLen > 0 { ppFilters.lengthFrom = minLen }
                    if let maxLen = query.maxLength, maxLen > 0 { ppFilters.lengthTo = maxLen }

                    if !capturedPpNucMutations.isEmpty {
                        ppFilters.nucleotideMutations = capturedPpNucMutations.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    }
                    if !capturedPpAAMutations.isEmpty {
                        ppFilters.aminoAcidMutations = capturedPpAAMutations.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    }

                    if !capturedPpDateFrom.isEmpty {
                        ppFilters.sampleCollectionDateFrom = dateFormatter.date(from: capturedPpDateFrom)
                    }
                    if !capturedPpDateTo.isEmpty {
                        ppFilters.sampleCollectionDateTo = dateFormatter.date(from: capturedPpDateTo)
                    }

                    // If the search text looks like an accession, filter by it
                    let ppSearchText = query.term.trimmingCharacters(in: .whitespaces)
                    if !ppSearchText.isEmpty {
                        ppFilters.accession = ppSearchText
                    }

                    let pathoplexusService = PathoplexusService()
                    searchResults = try await pathoplexusService.search(
                        organism: ppOrganism,
                        filters: ppFilters,
                        limit: query.limit,
                        offset: query.offset
                    )
                    logger.info("performSearch: Pathoplexus returned \(searchResults.totalCount) total, \(searchResults.records.count) records")

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
        let downloadCenterTaskID = DownloadCenter.shared.start(
            title: downloadTitle,
            detail: "Preparing \(totalCount) record(s)..."
        )

        // Log details about selected records for debugging
        logger.info("performBatchDownload: Starting download of \(totalCount) record(s)")
        logger.info("performBatchDownload: selectedRecords.count = \(self.selectedRecords.count)")
        for (idx, record) in recordsToDownload.enumerated() {
            logger.info("performBatchDownload: Record[\(idx)] id=\(record.id, privacy: .public) accession=\(record.accession, privacy: .public)")
        }

        // Dismiss the sheet immediately so the user can see the main window
        // while the download progresses in the background via DownloadCenter.
        // Bundle delivery happens through DownloadCenter.onBundleReady (set by
        // AppDelegate at startup), eliminating the fragile callback chain through
        // the sheet controller which gets deallocated on dismissal.
        onDownloadStarted?()

        // Use Task.detached to break out of MainActor context.
        // This is critical when running in a modal sheet - regular Task {}
        // inherits MainActor isolation and may not execute due to the modal
        // run loop blocking task scheduling on MainActor.
        Task.detached {
            var downloadedURLs: [URL] = []
            var failedCount = 0

            // Create a unique batch directory once for all downloads in this batch
            // This avoids filename collisions when records have the same accession
            let batchDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-batch-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
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
                    let fileURL: URL

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
                        // SRA run accessions (SRR/ERR/DRR) must be downloaded as FASTQ
                        // files, NOT fetched as nucleotide sequences. The ENA source in
                        // the database browser is exclusively used for SRA read searches
                        // via searchReads(), so all records here are SRA runs.
                        logger.info("performBatchDownload: Downloading FASTQ for SRA run \(record.accession, privacy: .public)")
                        performOnMainRunLoop {
                            DownloadCenter.shared.update(
                                id: downloadCenterTaskID,
                                progress: progressFraction,
                                detail: "Fetching FASTQ URLs for \(record.accession)..."
                            )
                        }

                        // Query ENA for verified FASTQ download URLs
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

                        // Download each FASTQ file to the batch directory
                        var firstDownloaded: URL?
                        for (fileIdx, fastqURL) in fastqURLs.enumerated() {
                            let filename = fastqURL.lastPathComponent
                            let localPath = batchDir.appendingPathComponent(filename)
                            logger.info("performBatchDownload: Downloading \(fastqURL.absoluteString, privacy: .public)")
                            performOnMainRunLoop {
                                DownloadCenter.shared.update(
                                    id: downloadCenterTaskID,
                                    progress: progressFraction,
                                    detail: "Downloading \(filename) (\(fileIdx + 1)/\(fastqURLs.count))..."
                                )
                            }

                            var request = URLRequest(url: fastqURL)
                            request.setValue("Lungfish Genome Explorer", forHTTPHeaderField: "User-Agent")
                            request.timeoutInterval = 600

                            let (data, response) = try await URLSession.shared.data(for: request)
                            guard let httpResponse = response as? HTTPURLResponse,
                                  (200...299).contains(httpResponse.statusCode) else {
                                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                                throw DatabaseServiceError.serverError(
                                    message: "Failed to download \(filename) (HTTP \(statusCode))"
                                )
                            }
                            try data.write(to: localPath)
                            logger.info("performBatchDownload: Saved \(filename) (\(data.count) bytes)")
                            if firstDownloaded == nil { firstDownloaded = localPath }
                        }
                        fileURL = firstDownloaded ?? batchDir

                        // Save ENA metadata sidecar alongside each downloaded FASTQ
                        if let localURL = firstDownloaded {
                            let metadata = PersistedFASTQMetadata(
                                enaReadRecord: readRecord,
                                downloadDate: Date(),
                                downloadSource: "ENA"
                            )
                            FASTQMetadataStore.save(metadata, for: localURL)
                        }

                    case .pathoplexus:
                        // Check if this record has an INSDC accession for GenBank retrieval
                        let pathoplexusService = PathoplexusService()
                        let ppMeta = try await pathoplexusService.fetchMetadataForAccession(
                            organism: ppOrganism,
                            accession: record.accession
                        )

                        if let insdcAccession = ppMeta?.bestINSDCAccession {
                            // Has INSDC accession — fetch from GenBank with annotations
                            logger.info("performBatchDownload: Pathoplexus record \(record.accession, privacy: .public) has INSDC accession \(insdcAccession, privacy: .public), fetching from GenBank")
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
                            fileURL = bundleURL
                            logger.info("performBatchDownload: Built GenBank bundle from Pathoplexus INSDC at \(bundleURL.path, privacy: .public)")
                        } else {
                            // No INSDC accession — download FASTA only from Pathoplexus
                            logger.info("performBatchDownload: Pathoplexus record \(record.accession, privacy: .public) has no INSDC accession, downloading FASTA only")
                            performOnMainRunLoop {
                                DownloadCenter.shared.update(
                                    id: downloadCenterTaskID,
                                    progress: progressFraction,
                                    detail: "Downloading FASTA for \(record.accession)..."
                                )
                            }

                            let dbRecord = try await pathoplexusService.fetch(accession: record.accession)
                            let filename = "\(dbRecord.accession).fasta"
                            fileURL = batchDir.appendingPathComponent(filename)

                            var fastaContent = ">\(dbRecord.accession)"
                            if !dbRecord.title.isEmpty {
                                fastaContent += " \(dbRecord.title)"
                            }
                            fastaContent += "\n"
                            let sequence = dbRecord.sequence
                            var idx = sequence.startIndex
                            while idx < sequence.endIndex {
                                let endIdx = sequence.index(idx, offsetBy: 80, limitedBy: sequence.endIndex) ?? sequence.endIndex
                                fastaContent += String(sequence[idx..<endIdx]) + "\n"
                                idx = endIdx
                            }
                            try fastaContent.write(to: fileURL, atomically: true, encoding: .utf8)
                        }

                    default:
                        throw DatabaseServiceError.invalidQuery(reason: "Unsupported database")
                    }

                    downloadedURLs.append(fileURL)
                    logger.info("Downloaded \(record.accession, privacy: .public)")

                } catch {
                    logger.error("Failed to download \(record.accession, privacy: .public): \(error, privacy: .public)")
                    failedCount += 1
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
            performOnMainRunLoop {
                if finalFailedCount > 0 {
                    DownloadCenter.shared.fail(
                        id: downloadCenterTaskID,
                        detail: "Completed with \(finalFailedCount) failure(s)"
                    )
                } else {
                    let bundleNames = finalDownloadedURLs.map { $0.deletingPathExtension().lastPathComponent }
                    let detail = totalCount == 1
                        ? "Bundle ready: \(bundleNames.first ?? "unknown")"
                        : "Completed \(finalDownloadedURLs.count) bundle(s)"
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
}

// MARK: - AppKit TextField Wrapper

/// An NSViewRepresentable wrapper for NSTextField that properly handles keyboard events
/// including delete/backspace in modal contexts.
///
/// SwiftUI's TextField with `.plain` style can have issues with key event handling
/// when embedded in NSHostingView, especially in modal sheets. This wrapper uses
/// a native NSTextField to ensure proper responder chain behavior.
struct AppKitTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.sendsActionOnEndEditing = false
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.textFieldAction(_:))
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Only update if the text actually differs to avoid cursor jumping
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitTextField

        init(_ parent: AppKitTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        @objc func textFieldAction(_ sender: NSTextField) {
            parent.onSubmit?()
        }
    }
}

// MARK: - DatabaseBrowserView

/// SwiftUI view for the database browser.
public struct DatabaseBrowserView: View {
    @ObservedObject var viewModel: DatabaseBrowserViewModel

    public var body: some View {
        if viewModel.isShowingPathoplexusConsent {
            PathoplexusConsentView(
                onAccept: { viewModel.acceptPathoplexusConsent() },
                onCancel: { viewModel.onCancel?() }
            )
            .frame(minWidth: 650, minHeight: 450)
        } else {
            VStack(spacing: 0) {
                // Header with database name
                headerSection

                Divider()

                // Search controls
                searchSection

                Divider()

                // Results list
                resultsSection

                Divider()

                // Status bar and actions
                footerSection
            }
            .frame(minWidth: 650, minHeight: 450)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: databaseIcon)
                    .font(.title2)
                    .foregroundColor(.accentColor)

                Text(viewModel.source.displayName)
                    .font(.headline)

                Spacer()

                // Show result count in header (when complete and not searching)
                if case .complete(let count) = viewModel.searchPhase, !viewModel.isSearching {
                    Label("\(count) result\(count == 1 ? "" : "s")", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // NCBI-specific controls: database selector and format picker
            if viewModel.isNCBISearch {
                HStack(spacing: 16) {
                    // Database type selector
                    HStack(spacing: 8) {
                        Text("Database:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $viewModel.ncbiSearchType) {
                            ForEach(NCBISearchType.allCases) { type in
                                Label(type.displayName, systemImage: type.icon)
                                    .tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180)
                        .help(viewModel.ncbiSearchType.helpText)
                    }

                    // RefSeq filter for GenBank and Virus searches
                    if viewModel.ncbiSearchType == .virus || viewModel.ncbiSearchType == .nucleotide {
                        Toggle("RefSeq Only", isOn: $viewModel.refseqOnly)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .help("Filter to NCBI Reference Sequences only (curated, representative sequences)")
                    }

                    Spacer()
                }
            }

            // Pathoplexus-specific controls: organism smart chips
            if viewModel.isPathoplexusSearch {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Organism:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Wrap chips in a flow layout
                    FlowLayout(spacing: 6) {
                        ForEach(viewModel.pathoplexusOrganisms) { organism in
                            PathoplexusOrganismChip(
                                organism: organism,
                                isSelected: viewModel.pathoplexusOrganism?.id == organism.id,
                                onTap: {
                                    if viewModel.pathoplexusOrganism?.id == organism.id {
                                        viewModel.pathoplexusOrganism = nil
                                    } else {
                                        viewModel.pathoplexusOrganism = organism
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var databaseIcon: String {
        if viewModel.isNCBISearch {
            return viewModel.ncbiSearchType.icon
        }
        switch viewModel.source {
        case .ncbi:
            return "building.columns"
        case .ena:
            return "globe.europe.africa"
        case .pathoplexus:
            return "microbe"
        default:
            return "magnifyingglass"
        }
    }

    /// Button title that changes based on selection count
    private var downloadButtonTitle: String {
        let count = viewModel.selectedRecords.count
        if count == 0 {
            return "Download Selected"
        } else if count == 1 {
            return "Download Selected"
        } else {
            return "Download \(count) Selected"
        }
    }

    private var searchSection: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 12) {
                // Primary search bar with scope selector
                primarySearchBar

                // Scope help text (when not "All Fields")
                if viewModel.searchScope != .all {
                    searchScopeHelp
                }

                // Advanced search toggle and filters
                advancedSearchSection
            }

            // Autocomplete dropdown - positioned in ZStack to float above other content
            if !viewModel.autocompleteSuggestions.isEmpty {
                autocompleteDropdown
                    .padding(.top, 46)  // Offset below search field
                    .padding(.leading, 58)  // Align with text field (after scope selector)
            }
        }
        .padding()
        .animation(.easeInOut(duration: 0.2), value: viewModel.isAdvancedExpanded)
        .animation(.easeInOut(duration: 0.2), value: viewModel.searchScope)
    }

    private var primarySearchBar: some View {
        HStack(spacing: 8) {
            // Search field with scope menu
            HStack(spacing: 0) {
                // Scope selector button
                Menu {
                    ForEach(SearchScope.allCases) { scope in
                        Button {
                            viewModel.searchScope = scope
                        } label: {
                            Label(scope.rawValue, systemImage: scope.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.searchScope.icon)
                            .foregroundColor(.accentColor)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help("Choose what fields to search")

                // Divider
                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)

                // Search text field - using AppKit wrapper for proper key handling
                AppKitTextField(
                    text: $viewModel.searchText,
                    placeholder: searchPlaceholder,
                    onSubmit: {
                        viewModel.performSearch()
                    }
                )
                .frame(minWidth: 200)

                // Clear button
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            // Search button
            if viewModel.isSearching {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: 70)
            } else {
                Button("Search") {
                    viewModel.performSearch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isSearchTextValid)
            }
        }
    }

    /// Autocomplete dropdown that floats above other content
    private var autocompleteDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.autocompleteSuggestions, id: \.self) { suggestion in
                AutocompleteRow(
                    suggestion: suggestion,
                    onSelect: {
                        viewModel.searchText = suggestion
                    }
                )

                if suggestion != viewModel.autocompleteSuggestions.last {
                    Divider()
                }
            }
        }
        .background(Color.white)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .zIndex(1000)  // Ensure dropdown is above other content
    }

    private var searchPlaceholder: String {
        if viewModel.isPathoplexusSearch {
            return "Search by accession (or leave empty to browse all)"
        }
        switch viewModel.searchScope {
        case .all:
            return "Search all fields (accession, organism, title...)"
        case .accession:
            return "Enter accession number (e.g., NC_002549)"
        case .organism:
            return "Enter organism name (e.g., Homo sapiens)"
        case .title:
            return "Search in titles and descriptions"
        }
    }

    private var searchScopeHelp: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .font(.caption)
            Text(viewModel.searchScope.helpText)
                .font(.caption)

            Spacer()

            Button("Search all fields instead") {
                viewModel.searchScope = .all
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
    }

    private var advancedSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Toggle button with filter count badge
            HStack {
                Button {
                    withAnimation {
                        viewModel.isAdvancedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: viewModel.isAdvancedExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .frame(width: 10)

                        Text("Advanced Filters")
                            .font(.callout)

                        // Active filter count badge
                        if viewModel.hasActiveFilters {
                            Text("\(viewModel.activeFilterCount)")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .help(viewModel.isAdvancedExpanded ? "Hide advanced filters" : "Show advanced filters")

                Spacer()

                // Clear filters button (only when filters are active)
                if viewModel.hasActiveFilters {
                    Button("Clear Filters") {
                        withAnimation {
                            viewModel.clearFilters()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }

            // Expandable filters — each source gets its own filter set
            if viewModel.isAdvancedExpanded {
                if viewModel.isPathoplexusSearch {
                    pathoplexusFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if viewModel.ncbiSearchType == .virus {
                    virusFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    advancedFiltersGrid
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Virus Filters Grid (Datasets v2)

    private var virusFiltersGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Host and Geographic Location row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Host", systemImage: "person")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., Homo sapiens", text: $viewModel.virusHostFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Geographic Location", systemImage: "location")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., USA, China", text: $viewModel.virusGeoLocationFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Completeness and Released Since row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Completeness", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $viewModel.virusCompletenessFilter) {
                        ForEach(VirusCompletenessFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Released Since", systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("YYYY-MM-DD", text: $viewModel.virusReleasedSinceFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                Spacer()
            }

            // Checkbox options
            HStack(spacing: 16) {
                Toggle("Annotated Only", isOn: $viewModel.virusAnnotatedOnly)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .help("Show only sequences with gene annotations")
            }

            // Help text
            Text("Virus filters use the NCBI Datasets v2 API. Use RefSeq Only (above) for curated reference sequences.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Pathoplexus Filters Grid

    private var pathoplexusFiltersGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Country and Host row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Country", systemImage: "location")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., USA, Germany", text: $viewModel.pathoplexusCountryFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Host", systemImage: "person")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., Homo sapiens", text: $viewModel.pathoplexusHostFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Clade and Lineage row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Clade", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., IIb", text: $viewModel.pathoplexusCladeFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Lineage", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., B.1", text: $viewModel.pathoplexusLineageFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Mutations row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Nucleotide Mutations", systemImage: "dna")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., C180T, A200G", text: $viewModel.pathoplexusNucMutationsFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Amino Acid Mutations", systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., GP:440G", text: $viewModel.pathoplexusAAMutationsFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Date range and length row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Collection Date", systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        TextField("YYYY-MM-DD", text: $viewModel.pathoplexusDateFrom)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)

                        Text("to")
                            .foregroundColor(.secondary)

                        TextField("YYYY-MM-DD", text: $viewModel.pathoplexusDateTo)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Sequence Length", systemImage: "ruler")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        TextField("Min", text: $viewModel.minLength)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        Text("to")
                            .foregroundColor(.secondary)

                        TextField("Max", text: $viewModel.maxLength)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        Text("bp")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            // Data use terms
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Data Use Terms", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $viewModel.pathoplexusDataUseTerms) {
                        Text("Any").tag(nil as DataUseTerms?)
                        Text("Open").tag(DataUseTerms.open as DataUseTerms?)
                        Text("Restricted").tag(DataUseTerms.restricted as DataUseTerms?)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }

                Spacer()
            }

            Text("Pathoplexus filters are combined with AND logic. Records with INSDC accessions will be fetched from GenBank with annotations.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Entrez Filters Grid

    private var advancedFiltersGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Organism and Location row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Organism", systemImage: "leaf")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., Ebolavirus", text: $viewModel.organismFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Location", systemImage: "location")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., Africa", text: $viewModel.locationFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // GenBank-specific metadata filters
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Gene", systemImage: "dna")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., S", text: $viewModel.geneFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Author", systemImage: "person.text.rectangle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., Wu F", text: $viewModel.authorFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Journal", systemImage: "book.closed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g., Nature", text: $viewModel.journalFilter)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Molecule type and sequence length row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Molecule Type", systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $viewModel.moleculeType) {
                        ForEach(MoleculeTypeFilter.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 140)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("Sequence Length", systemImage: "ruler")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        TextField("Min", text: $viewModel.minLength)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        Text("to")
                            .foregroundColor(.secondary)

                        TextField("Max", text: $viewModel.maxLength)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        Text("bp")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            // Publication date range row
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Publication Date", systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        TextField("YYYY/MM/DD", text: $viewModel.pubDateFrom)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)

                        Text("to")
                            .foregroundColor(.secondary)

                        TextField("YYYY/MM/DD", text: $viewModel.pubDateTo)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }

                Spacer()
            }

            // Sequence properties row
            VStack(alignment: .leading, spacing: 4) {
                Label("Sequence Properties", systemImage: "tag")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    ForEach(SequencePropertyFilter.allCases) { prop in
                        Toggle(isOn: Binding(
                            get: { viewModel.propertyFilters.contains(prop) },
                            set: { selected in
                                if selected {
                                    viewModel.propertyFilters.insert(prop)
                                } else {
                                    viewModel.propertyFilters.remove(prop)
                                }
                            }
                        )) {
                            Label(prop.rawValue, systemImage: prop.icon)
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }

            // Help text
            Text("Advanced filters are combined with AND logic. Use RefSeq Only for curated reference records.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var resultsSection: some View {
        VStack(spacing: 0) {
            if viewModel.results.isEmpty && !viewModel.isSearching {
                emptyStateView
            } else {
                // Selection toolbar
                if !viewModel.results.isEmpty {
                    resultsToolbar
                }
                resultsList
            }
        }
    }

    /// Maximum number of downloads allowed at once (to be respectful of NCBI servers)
    private let maxDownloadLimit = 50

    private var resultsToolbar: some View {
        VStack(spacing: 6) {
            // Local filter field for narrowing results without re-querying
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(.secondary)

                TextField("Filter results locally...", text: $viewModel.localFilterText)
                    .textFieldStyle(.plain)
                    .font(.caption)

                if !viewModel.localFilterText.isEmpty {
                    Button {
                        viewModel.localFilterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                // Select all / Deselect all toggle (for filtered results)
                Button {
                    let displayedResults = viewModel.filteredResults
                    let allDisplayedSelected = displayedResults.allSatisfy { viewModel.selectedRecords.contains($0) }
                    if allDisplayedSelected {
                        // Deselect all displayed
                        for record in displayedResults {
                            viewModel.selectedRecords.remove(record)
                        }
                    } else {
                        // Select all displayed
                        viewModel.selectedRecords.formUnion(displayedResults)
                    }
                } label: {
                    let displayedResults = viewModel.filteredResults
                    let allDisplayedSelected = !displayedResults.isEmpty && displayedResults.allSatisfy { viewModel.selectedRecords.contains($0) }
                    HStack(spacing: 4) {
                        Image(systemName: allDisplayedSelected ? "checkmark.circle.fill" : "circle")
                        Text(allDisplayedSelected ? "Deselect All" : "Select All")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(viewModel.filteredResults.isEmpty)

                Spacer()

                // Selection count and total results info
                if !viewModel.selectedRecords.isEmpty {
                    Text("\(viewModel.selectedRecords.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Show filter status
                if !viewModel.localFilterText.isEmpty {
                    Text("Showing \(viewModel.filteredResults.count) of \(viewModel.results.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if viewModel.hasMoreResults {
                    // Show that there are more results in the database
                    Text("Showing \(viewModel.results.count) of \(viewModel.totalResultCount) total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(viewModel.results.count) results")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Warning when too many selected for download
            if viewModel.selectedRecords.count > maxDownloadLimit {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("To be respectful of NCBI servers, please select no more than \(maxDownloadLimit) records at a time.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Search for sequences")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Enter a search term above to find sequences in \(viewModel.source.displayName)")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var resultsList: some View {
        List(viewModel.filteredResults, selection: $viewModel.selectedRecords) { record in
            SearchResultRowWithCheckbox(
                record: record,
                isSelected: viewModel.selectedRecords.contains(record),
                onToggle: {
                    if viewModel.selectedRecords.contains(record) {
                        viewModel.selectedRecords.remove(record)
                    } else {
                        viewModel.selectedRecords.insert(record)
                    }
                }
            )
            .tag(record)
            .contentShape(Rectangle())
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 60)
        .onChange(of: viewModel.selectedRecords) { _, newSelection in
            // Keep single selection in sync for compatibility
            viewModel.selectedRecord = newSelection.first
        }
    }

    private var footerSection: some View {
        VStack(spacing: 0) {
            // Progress bar for search (when searching)
            if viewModel.isSearching {
                searchProgressBar
            }

            // Main footer controls
            HStack {
                // Cancel button
                Button("Cancel") {
                    if viewModel.isSearching {
                        viewModel.cancelSearch()
                    } else {
                        viewModel.onCancel?()
                    }
                }
                .keyboardShortcut(.cancelAction)

                // Error display
                if let error = viewModel.errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                }

                // Status message (when not showing in progress bar)
                if !viewModel.isSearching, let status = viewModel.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Download progress
                if viewModel.isDownloading {
                    ProgressView(value: viewModel.downloadProgress)
                        .frame(width: 100)
                    Text(viewModel.statusMessage ?? "Downloading...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Show selection count when multiple items selected
                if viewModel.selectedRecords.count > 1 {
                    Text("\(viewModel.selectedRecords.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Info for genome downloads (files can be large)
                if viewModel.ncbiSearchType == .genome && !viewModel.selectedRecords.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Large file download")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .help("Genome assemblies can be large (100s of MB to GB). Progress will be shown during download.")
                }

                Button(downloadButtonTitle) {
                    viewModel.performBatchDownload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    viewModel.selectedRecords.isEmpty ||
                    viewModel.selectedRecords.count > maxDownloadLimit ||
                    viewModel.isDownloading ||
                    viewModel.isSearching
                )
                .help(viewModel.selectedRecords.count > maxDownloadLimit
                    ? "Select \(maxDownloadLimit) or fewer records to download"
                    : "Download selected records")
            }
            .padding()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Progress bar shown during search operations
    private var searchProgressBar: some View {
        VStack(spacing: 4) {
            ProgressView(value: viewModel.searchPhase.progress)
                .progressViewStyle(.linear)

            HStack {
                Text(viewModel.searchPhase.message)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Show percentage
                Text("\(Int(viewModel.searchPhase.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - Pathoplexus Organism Chip

/// A selectable chip for a Pathoplexus organism.
struct PathoplexusOrganismChip: View {
    let organism: PathoplexusOrganism
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                }
                Text(organism.displayName)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FlowLayout

/// A horizontal flow layout that wraps children to new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                // Wrap to next line
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return (
            size: CGSize(width: totalWidth, height: currentY + lineHeight),
            positions: positions
        )
    }
}

// MARK: - Pathoplexus ABS Consent View

/// Access and Benefit Sharing consent screen shown on first Pathoplexus use.
struct PathoplexusConsentView: View {
    var onAccept: () -> Void
    var onCancel: () -> Void

    @State private var hasScrolledToBottom = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "microbe")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)

                Text("Pathoplexus: Pathogen Data Sharing")
                    .font(.title2.bold())

                Text("Access and Benefit Sharing Notice")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Scrollable consent text
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        Text("About Pathoplexus")
                            .font(.headline)

                        Text("Pathoplexus is an open database for viral pathogen genomic sequences that supports both open and time-limited data sharing. It was developed to promote equitable access to pathogen genomic data while respecting the rights and contributions of data generators.")

                        Text("Data Use Terms")
                            .font(.headline)

                        Text("Sequences in Pathoplexus may be shared under two types of data use terms:")

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lock.open")
                                    .foregroundColor(.green)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Data").bold()
                                    Text("Immediately available for public access and unrestricted use.")
                                        .foregroundColor(.secondary)
                                }
                            }

                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lock.shield")
                                    .foregroundColor(.orange)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Restricted Data").bold()
                                    Text("Time-limited protection (up to one year) to allow data generators a head start on analysis and publication.")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.leading, 8)
                    }

                    Group {
                        Text("Access and Benefit Sharing Principles")
                            .font(.headline)

                        Text("The Nagoya Protocol and related international frameworks recognize that the benefits arising from the use of genetic resources should be shared fairly and equitably. When using data from Pathoplexus, please:")

                        VStack(alignment: .leading, spacing: 6) {
                            bulletPoint("Respect the data use terms associated with each sequence")
                            bulletPoint("Acknowledge the contributions of data generators in publications")
                            bulletPoint("Consider the provenance of sequences and the communities from which they originated")
                            bulletPoint("Support equitable sharing of benefits arising from the use of pathogen genomic data")
                            bulletPoint("Cite Pathoplexus and the original data submitters when publishing results")
                        }
                        .padding(.leading, 8)

                        Text("Your Responsibilities")
                            .font(.headline)

                        Text("By proceeding, you acknowledge that you understand and agree to respect the data use terms of the sequences you access through Pathoplexus. You will use the data responsibly and in accordance with applicable legal and ethical frameworks for pathogen data sharing.")
                    }
                }
                .padding(24)
                .font(.body)
            }

            Divider()

            // Footer with buttons
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Text("You will only see this notice once.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("I Understand and Agree") {
                    onAccept()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
                .font(.body)
            Text(text)
        }
    }
}

// MARK: - SearchResultRowWithCheckbox

/// A search result row with a checkbox for explicit selection.
/// This enables easy multi-select including discontiguous selection.
struct SearchResultRowWithCheckbox: View {
    let record: SearchResultRecord
    var isSelected: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox for selection
            Button(action: onToggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Deselect this record" : "Select this record")

            // Record details
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.accession)
                        .font(.headline.monospaced())

                    if let db = record.sourceDatabase {
                        Text(db)
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(db == "RefSeq" ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15))
                            .cornerRadius(3)
                    }

                    Spacer()

                    if let length = record.length {
                        Text(formatLength(length))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Text(record.title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack {
                    if let organism = record.organism {
                        Label(organism, systemImage: "leaf")
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if let collectionDate = record.collectionDate {
                        Label(collectionDate, systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let date = record.date {
                        Label(formatDate(date), systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Virus-specific metadata row
                if record.host != nil || record.geoLocation != nil || record.completeness != nil || record.pangolinClassification != nil {
                    HStack(spacing: 10) {
                        if let host = record.host {
                            Label(host, systemImage: "person")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        if let location = record.geoLocation {
                            Label(location, systemImage: "location")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        if let completeness = record.completeness {
                            Text(completeness)
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(completeness == "COMPLETE" ? Color.green.opacity(0.2) : Color.yellow.opacity(0.2))
                                .cornerRadius(3)
                        }
                        if let pangolin = record.pangolinClassification {
                            Text(pangolin)
                                .font(.caption.monospaced())
                                .foregroundColor(.purple)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }

    private func formatLength(_ length: Int) -> String {
        if length >= 1_000_000 {
            return String(format: "%.1f Mb", Double(length) / 1_000_000)
        } else if length >= 1_000 {
            return String(format: "%.1f kb", Double(length) / 1_000)
        } else {
            return "\(length) bp"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - AutocompleteRow

/// A row in the autocomplete dropdown with hover highlighting.
struct AutocompleteRow: View {
    let suggestion: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(suggestion)
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.accentColor.opacity(0.1) : Color.white)
        .onHover { hovering in
            isHovered = hovering
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
            return "SRA (FASTQ Downloads)"
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
