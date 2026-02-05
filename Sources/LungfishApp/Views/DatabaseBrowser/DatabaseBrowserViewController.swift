// DatabaseBrowserViewController.swift - Database search and download UI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12), ENA Integration Specialist (Role 13)

import AppKit
import SwiftUI
import LungfishCore
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

/// Formats a byte count as a human-readable file size string.
private func formatFileSize(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
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

    /// Completion handler called when a download completes
    public var onDownloadComplete: ((URL) -> Void)?

    /// Completion handler called when multiple downloads complete (batch)
    public var onMultipleDownloadsComplete: (([URL]) -> Void)?

    /// Completion handler called when user cancels
    public var onCancel: (() -> Void)?

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

        // Set up download completion callback (single file)
        viewModel.onDownloadComplete = { [weak self] url in
            self?.onDownloadComplete?(url)
        }

        // Set up multiple downloads completion callback (batch)
        viewModel.onMultipleDownloadsComplete = { [weak self] urls in
            self?.onMultipleDownloadsComplete?(urls)
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

// MARK: - DatabaseBrowserViewModel

/// View model for the database browser.
@MainActor
public class DatabaseBrowserViewModel: ObservableObject {

    // MARK: - Published Properties

    /// The database source
    let source: DatabaseSource

    /// NCBI search type (GenBank, Genome, Virus)
    @Published var ncbiSearchType: NCBISearchType = .nucleotide

    /// Download format for NCBI (GenBank or FASTA)
    @Published var downloadFormat: NCBIFormat = .genbank

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

    /// Minimum sequence length filter
    @Published var minLength: String = ""

    /// Maximum sequence length filter
    @Published var maxLength: String = ""

    /// Whether to filter to RefSeq sequences only (for Virus search)
    @Published var refseqOnly: Bool = false

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
            (record.organism?.lowercased().contains(filter) ?? false)
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

    /// Status message (computed from search phase when searching)
    var statusMessage: String? {
        if searchPhase.isInProgress || searchPhase != .idle {
            switch searchPhase {
            case .complete, .failed:
                return searchPhase.message
            default:
                return searchPhase.message
            }
        }
        return _statusMessage
    }

    /// Internal status message for non-search operations
    @Published private var _statusMessage: String?

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

    /// Whether search text is valid (non-empty after trimming)
    var isSearchTextValid: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Count of active advanced filters
    var activeFilterCount: Int {
        var count = 0
        if !organismFilter.isEmpty { count += 1 }
        if !locationFilter.isEmpty { count += 1 }
        if !minLength.isEmpty || !maxLength.isEmpty { count += 1 }
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

    /// Called when a download completes with the file URL (single file)
    var onDownloadComplete: ((URL) -> Void)?

    /// Called when multiple downloads complete (for batch downloads)
    var onMultipleDownloadsComplete: (([URL]) -> Void)?

    /// Called when user cancels
    var onCancel: (() -> Void)?

    // MARK: - Services

    private let ncbiService = NCBIService()
    private let enaService = ENAService()

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
        organismFilter = ""
        locationFilter = ""
        minLength = ""
        maxLength = ""
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
        let searchTerm = buildSearchTerm()
        logger.info("performSearch: Built search term: '\(searchTerm, privacy: .public)'")
        logger.info("performSearch: Search scope: \(self.searchScope.rawValue, privacy: .public)")

        let query = SearchQuery(
            term: searchTerm,
            organism: organismFilter.isEmpty ? nil : organismFilter,
            location: locationFilter.isEmpty ? nil : locationFilter,
            minLength: Int(minLength),
            maxLength: Int(maxLength),
            limit: 200  // Increased from 50 to show more results
        )
        let currentSource = source
        let searchType = ncbiSearchType
        let useRefseqOnly = refseqOnly

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
                        logger.info("performSearch: Calling NCBI nucleotide search")
                        searchResults = try await ncbi.search(query)
                        logger.info("performSearch: NCBI returned \(searchResults.totalCount) total, \(searchResults.records.count) records")

                    case .virus:
                        // Use viral taxonomy filter
                        logger.info("performSearch: Calling NCBI virus search (refseqOnly=\(useRefseqOnly))")
                        let virusResult = try await ncbi.searchVirus(
                            term: query.term,
                            retmax: query.limit,
                            retstart: query.offset,
                            refseqOnly: useRefseqOnly
                        )
                        logger.info("performSearch: Virus search returned \(virusResult.totalCount) total, \(virusResult.ids.count) IDs")

                        // Get summaries for the results
                        guard !virusResult.ids.isEmpty else {
                            performOnMainRunLoop { [weak self] in
                                self?.objectWillChange.send()
                                self?.results = []
                                self?.totalResultCount = virusResult.totalCount
                                self?.hasMoreResults = false
                                self?.searchPhase = .complete(count: 0)
                            }
                            return
                        }

                        let summaries = try await ncbi.esummary(database: .nucleotide, ids: virusResult.ids)
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
                        let hasMore = virusResult.totalCount > (query.offset + records.count)
                        searchResults = SearchResults(
                            totalCount: virusResult.totalCount,
                            records: records,
                            hasMore: hasMore,
                            nextCursor: hasMore ? String(query.offset + records.count) : nil
                        )

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
                    logger.info("performSearch: Calling Pathoplexus search")
                    let pathoplexusService = PathoplexusService()
                    searchResults = try await pathoplexusService.search(query)
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
    private func buildSearchTerm() -> String {
        let term = searchText.trimmingCharacters(in: .whitespaces)

        // Log the raw input for debugging
        logger.debug("buildSearchTerm: Raw input='\(term, privacy: .public)', scope=\(self.searchScope.rawValue, privacy: .public)")

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
            return term
        case .accession:
            // Accession searches work best without a field qualifier
            // NCBI automatically matches accession patterns
            logger.debug("buildSearchTerm: Using unqualified term for Accession scope")
            return term
        case .organism:
            let result = "\(term)[Organism]"
            logger.debug("buildSearchTerm: Built organism query='\(result, privacy: .public)'")
            return result
        case .title:
            let result = "\(term)[Title]"
            logger.debug("buildSearchTerm: Built title query='\(result, privacy: .public)'")
            return result
        }
    }

    /// Initiates a download operation for the selected record.
    ///
    /// For NCBI downloads, this fetches the raw GenBank format file preserving
    /// all annotations, features, and metadata. The file is saved with a .gb extension.
    func performDownload() {

        guard let record = selectedRecord else {
            errorMessage = "No record selected"
            return
        }

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        _statusMessage = "Downloading \(record.accession)..."

        // Capture services and values for use in detached task
        let ncbi = ncbiService
        let ena = enaService
        let currentSource = source
        let accession = record.accession


        // Use Task.detached to ensure download runs even in modal context
        // All network work happens in this detached context, with UI updates via performOnMainRunLoop
        Task.detached { [weak self] in

            do {
                // Update UI: connecting
                performOnMainRunLoop { [weak self] in
                    self?.objectWillChange.send()
                    self?.downloadProgress = 0.1
                    self?._statusMessage = "Connecting to \(currentSource.displayName)..."
                }


                // Update UI: fetching
                performOnMainRunLoop { [weak self] in
                    self?.objectWillChange.send()
                    self?.downloadProgress = 0.2
                    self?._statusMessage = "Fetching \(accession)..."
                }

                let fileURL: URL

                switch currentSource {
                case .ncbi:
                    // Fetch raw GenBank format to preserve all annotations
                    let (genBankContent, resolvedAccession) = try await ncbi.fetchRawGenBank(accession: accession)

                    // Update UI: saving
                    performOnMainRunLoop { [weak self] in
                        self?.objectWillChange.send()
                        self?.downloadProgress = 0.7
                        self?._statusMessage = "Saving \(resolvedAccession)..."
                    }

                    // Save raw GenBank content directly with .gb extension
                    let tempDir = FileManager.default.temporaryDirectory
                    let filename = "\(resolvedAccession).gb"
                    fileURL = tempDir.appendingPathComponent(filename)

                    try genBankContent.write(to: fileURL, atomically: true, encoding: .utf8)

                case .ena:
                    // Check if this is an SRA run accession (SRR, ERR, DRR)
                    let isSRAAccession = accession.hasPrefix("SRR") || accession.hasPrefix("ERR") || accession.hasPrefix("DRR")

                    if isSRAAccession {
                        // Download FASTQ files via ENA
                        performOnMainRunLoop { [weak self] in
                            self?.objectWillChange.send()
                            self?.downloadProgress = 0.3
                            self?._statusMessage = "Downloading FASTQ for \(accession)..."
                        }

                        let sraService = SRAService()
                        let fastqFiles = try await sraService.downloadFASTQFromENA(
                            accession: accession,
                            progress: { [weak self] progress in
                                Task { @MainActor [weak self] in
                                    // Scale progress: 0.3 to 0.9 for download
                                    self?.objectWillChange.send()
                                    self?.downloadProgress = 0.3 + (progress * 0.6)
                                }
                            }
                        )

                        guard let firstFile = fastqFiles.first else {
                            throw DatabaseServiceError.parseError(message: "No FASTQ files downloaded for \(accession)")
                        }

                        fileURL = firstFile
                        logger.info("Downloaded \(fastqFiles.count) FASTQ file(s) for \(accession)")
                    } else {
                        // ENA sequence: fetch and save as FASTA
                        let dbRecord = try await ena.fetch(accession: accession)

                        // Update UI: saving
                        performOnMainRunLoop { [weak self] in
                            self?.objectWillChange.send()
                            self?.downloadProgress = 0.7
                            self?._statusMessage = "Saving \(accession)..."
                        }

                        // Save to temporary file as FASTA
                        let tempDir = FileManager.default.temporaryDirectory
                        let filename = "\(dbRecord.accession).fasta"
                        fileURL = tempDir.appendingPathComponent(filename)

                        var fastaContent = ">\(dbRecord.accession)"
                        if !dbRecord.title.isEmpty {
                            fastaContent += " \(dbRecord.title)"
                        }
                        fastaContent += "\n"

                        // Format sequence in 80-character lines
                        let sequence = dbRecord.sequence
                        var index = sequence.startIndex
                        while index < sequence.endIndex {
                            let endIndex = sequence.index(index, offsetBy: 80, limitedBy: sequence.endIndex) ?? sequence.endIndex
                            fastaContent += String(sequence[index..<endIndex]) + "\n"
                            index = endIndex
                        }

                        try fastaContent.write(to: fileURL, atomically: true, encoding: .utf8)
                    }

                default:
                    throw DatabaseServiceError.invalidQuery(reason: "Unsupported database: \(currentSource)")
                }

                // Update UI: complete
                performOnMainRunLoop { [weak self] in
                    self?.objectWillChange.send()
                    self?.downloadProgress = 1.0
                    self?._statusMessage = "Download complete: \(accession)"
                }

                // Notify completion
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.objectWillChange.send()
                    self.isDownloading = false
                    self.onDownloadComplete?(fileURL)
                }

            } catch {
                let errorMsg = error.localizedDescription
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.objectWillChange.send()
                    self.errorMessage = "Download failed: \(errorMsg)"
                    self._statusMessage = nil
                    self.isDownloading = false
                }
            }
        }
    }

    /// Downloads the selected record.
    func downloadSelected() async {
        guard let record = selectedRecord else {
            errorMessage = "No record selected"
            return
        }

        await download(record: record)
    }

    /// Downloads a specific record.
    func download(record: SearchResultRecord) async {
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        _statusMessage = "Downloading \(record.accession)..."

        await executeDownload(record: record, ncbi: ncbiService, ena: enaService, source: source)
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
        _statusMessage = "Downloading \(totalCount) file\(totalCount == 1 ? "" : "s")..."

        // Capture services and values for task
        let ncbi = ncbiService
        let ena = enaService
        let currentSource = source
        let format = downloadFormat
        let searchType = ncbiSearchType

        // Log details about selected records for debugging
        logger.info("performBatchDownload: Starting download of \(totalCount) record(s)")
        logger.info("performBatchDownload: selectedRecords.count = \(self.selectedRecords.count)")
        for (idx, record) in recordsToDownload.enumerated() {
            logger.info("performBatchDownload: Record[\(idx)] id=\(record.id, privacy: .public) accession=\(record.accession, privacy: .public)")
        }

        // Use Task.detached to break out of MainActor context.
        // This is critical when running in a modal sheet - regular Task {}
        // inherits MainActor isolation and may not execute due to the modal
        // run loop blocking task scheduling on MainActor.
        Task.detached { [weak self] in
            var downloadedURLs: [URL] = []
            var failedCount = 0
            
            // Create a unique batch directory once for all downloads in this batch
            // This avoids filename collisions when records have the same accession
            let batchDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-batch-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: batchDir, withIntermediateDirectories: true)
            logger.info("performBatchDownload: Created batch directory at \(batchDir.path, privacy: .public)")

            for (index, record) in recordsToDownload.enumerated() {
                // Update progress via performOnMainRunLoop for modal compatibility
                let progressFraction = Double(index) / Double(totalCount)
                performOnMainRunLoop { [weak self] in
                    guard let self = self else { return }
                    self.objectWillChange.send()
                    self.downloadProgress = progressFraction
                    self._statusMessage = "Downloading \(record.accession) (\(index + 1)/\(totalCount))..."
                }

                do {
                    let fileURL: URL

                    switch currentSource {
                    case .ncbi:
                        // Handle genome downloads differently (large files with progress tracking)
                        if searchType == .genome {
                            // For genome downloads, we need to get assembly info first
                            let assemblySummaries = try await ncbi.assemblyEsummary(ids: [record.id])
                            guard let summary = assemblySummaries.first else {
                                throw DatabaseServiceError.notFound(accession: record.accession)
                            }
                            
                            // Get genome file info (URL and size)
                            let fileInfo = try await ncbi.getGenomeFileInfo(for: summary)
                            
                            // Update UI with file size info
                            let sizeStr = fileInfo.estimatedSize.map { formatFileSize($0) } ?? "unknown size"
                            performOnMainRunLoop { [weak self] in
                                self?.objectWillChange.send()
                                self?._statusMessage = "Downloading \(record.accession) (\(sizeStr))..."
                            }
                            
                            // Download with progress tracking
                            let filename = "\(fileInfo.assemblyAccession)_\(record.id)_genomic.fna.gz"
                            let destURL = batchDir.appendingPathComponent(filename)
                            let totalBytes = fileInfo.estimatedSize
                            
                            fileURL = try await ncbi.downloadGenomeFile(fileInfo, to: destURL) { [weak self] bytesDownloaded, expectedTotal in
                                let total = expectedTotal ?? totalBytes
                                let progressFraction: Double
                                if let total = total, total > 0 {
                                    progressFraction = Double(bytesDownloaded) / Double(total)
                                } else {
                                    progressFraction = 0.5 // Indeterminate
                                }
                                let downloadedStr = formatFileSize(bytesDownloaded)
                                let totalStr = total.map { formatFileSize($0) } ?? "?"
                                
                                performOnMainRunLoop {
                                    self?.objectWillChange.send()
                                    self?.downloadProgress = progressFraction
                                    self?._statusMessage = "Downloading \(record.accession): \(downloadedStr) / \(totalStr)"
                                }
                            }
                            logger.info("performBatchDownload: Downloaded genome file \(filename, privacy: .public)")
                        } else if format == .fasta {
                            // Standard nucleotide FASTA download
                            let (fastaContent, resolvedAccession) = try await ncbi.fetchRawFASTA(accession: record.accession)
                            // Use record.id to ensure unique filename even if accessions match
                            let filename = "\(resolvedAccession)_\(record.id).fasta"
                            fileURL = batchDir.appendingPathComponent(filename)
                            try fastaContent.write(to: fileURL, atomically: true, encoding: .utf8)
                            logger.info("performBatchDownload: Wrote file \(filename, privacy: .public)")
                        } else {
                            // Default to GenBank format
                            let (genBankContent, resolvedAccession) = try await ncbi.fetchRawGenBank(accession: record.accession)
                            // Use record.id to ensure unique filename even if accessions match
                            let filename = "\(resolvedAccession)_\(record.id).gb"
                            fileURL = batchDir.appendingPathComponent(filename)
                            try genBankContent.write(to: fileURL, atomically: true, encoding: .utf8)
                            logger.info("performBatchDownload: Wrote file \(filename, privacy: .public)")
                        }

                    case .ena:
                        let dbRecord = try await ena.fetch(accession: record.accession)
                        let tempDir = FileManager.default.temporaryDirectory
                        let filename = "\(dbRecord.accession).fasta"
                        fileURL = tempDir.appendingPathComponent(filename)

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

                    case .pathoplexus:
                        // Pathoplexus downloads as FASTA
                        let pathoplexusService = PathoplexusService()
                        let dbRecord = try await pathoplexusService.fetch(accession: record.accession)
                        let tempDir = FileManager.default.temporaryDirectory
                        let filename = "\(dbRecord.accession).fasta"
                        fileURL = tempDir.appendingPathComponent(filename)

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

                    default:
                        throw DatabaseServiceError.invalidQuery(reason: "Unsupported database")
                    }

                    downloadedURLs.append(fileURL)
                    logger.info("Downloaded \(record.accession, privacy: .public)")

                } catch {
                    logger.error("Failed to download \(record.accession, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failedCount += 1
                }
            }

            // Complete - update UI via performOnMainRunLoop
            let finalDownloadedURLs = downloadedURLs
            let finalFailedCount = failedCount
            performOnMainRunLoop { [weak self] in
                guard let self = self else { return }
                self.objectWillChange.send()
                self.downloadProgress = 1.0
                self.isDownloading = false

                if finalFailedCount > 0 {
                    self._statusMessage = "Downloaded \(finalDownloadedURLs.count) files (\(finalFailedCount) failed)"
                } else {
                    self._statusMessage = "Downloaded \(finalDownloadedURLs.count) file\(finalDownloadedURLs.count == 1 ? "" : "s")"
                }

                logger.info("performBatchDownload: Complete - \(finalDownloadedURLs.count) downloaded, \(finalFailedCount) failed")

                // Notify completion with all downloaded URLs
                if let multiCallback = self.onMultipleDownloadsComplete {
                    multiCallback(finalDownloadedURLs)
                } else if let singleCallback = self.onDownloadComplete, let firstURL = finalDownloadedURLs.first {
                    // Fall back to single callback for first file
                    singleCallback(firstURL)
                }
            }
        }
    }

    /// Executes the actual download operation.
    /// - Parameters:
    ///   - record: The record to download
    ///   - ncbi: The NCBI service actor
    ///   - ena: The ENA service actor
    ///   - source: The database source
    private func executeDownload(record: SearchResultRecord, ncbi: NCBIService, ena: ENAService, source: DatabaseSource) async {

        do {
            performOnMainRunLoop { [weak self] in
                self?.objectWillChange.send()
                self?.downloadProgress = 0.1
                self?._statusMessage = "Connecting to \(source.displayName)..."
            }

            let tempURL: URL

            switch source {
            case .ncbi:
                performOnMainRunLoop { [weak self] in
                    self?.objectWillChange.send()
                    self?.downloadProgress = 0.2
                    self?._statusMessage = "Fetching \(record.accession)..."
                }

                // Fetch raw GenBank format to preserve all annotations
                let (genBankContent, resolvedAccession) = try await ncbi.fetchRawGenBank(accession: record.accession)

                performOnMainRunLoop { [weak self] in
                    self?.objectWillChange.send()
                    self?.downloadProgress = 0.7
                    self?._statusMessage = "Saving \(resolvedAccession)..."
                }

                // Save raw GenBank content directly with .gb extension
                let tempDir = FileManager.default.temporaryDirectory
                let filename = "\(resolvedAccession).gb"
                tempURL = tempDir.appendingPathComponent(filename)

                try genBankContent.write(to: tempURL, atomically: true, encoding: .utf8)

            case .ena:
                performOnMainRunLoop { [weak self] in
                    self?.objectWillChange.send()
                    self?.downloadProgress = 0.2
                    self?._statusMessage = "Fetching \(record.accession)..."
                }
                let dbRecord = try await ena.fetch(accession: record.accession)

                performOnMainRunLoop { [weak self] in
                    self?.objectWillChange.send()
                    self?.downloadProgress = 0.7
                    self?._statusMessage = "Saving \(record.accession)..."
                }

                // Save to temporary file as FASTA
                tempURL = try saveToTemporaryFile(record: dbRecord)

            default:
                throw DatabaseServiceError.invalidQuery(reason: "Unsupported database: \(source)")
            }


            performOnMainRunLoop { [weak self] in
                self?.objectWillChange.send()
                self?.downloadProgress = 1.0
                self?._statusMessage = "Download complete: \(record.accession)"
            }
            logger.info("Downloaded \(record.accession, privacy: .public) to \(tempURL.path, privacy: .public)")

            // Notify completion via performOnMainRunLoop
            performOnMainRunLoop { [weak self] in
                guard let self = self else { return }
                self.objectWillChange.send()
                self.isDownloading = false
                self.onDownloadComplete?(tempURL)
            }

        } catch {
            let errorMsg = error.localizedDescription
            performOnMainRunLoop { [weak self] in
                guard let self = self else { return }
                self.objectWillChange.send()
                self.errorMessage = "Download failed: \(errorMsg)"
                self._statusMessage = nil
                self.isDownloading = false
            }
            logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private Methods

    private func saveToTemporaryFile(record: DatabaseRecord) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "\(record.accession).fasta"
        let fileURL = tempDir.appendingPathComponent(filename)

        // Create FASTA content
        var fastaContent = ">\(record.accession)"
        if !record.title.isEmpty {
            fastaContent += " \(record.title)"
        }
        if let organism = record.organism {
            fastaContent += " [\(organism)]"
        }
        fastaContent += "\n"

        // Wrap sequence at 80 characters
        let sequence = record.sequence
        let lineLength = 80
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: lineLength, limitedBy: sequence.endIndex) ?? sequence.endIndex
            fastaContent += String(sequence[index..<end]) + "\n"
            index = end
        }

        try fastaContent.write(to: fileURL, atomically: true, encoding: .utf8)

        return fileURL
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

                    // RefSeq filter (only for Virus search)
                    if viewModel.ncbiSearchType == .virus {
                        Toggle("RefSeq Only", isOn: $viewModel.refseqOnly)
                            .font(.caption)
                            .toggleStyle(.checkbox)
                            .help("Filter to NCBI Reference Sequences only (curated, representative sequences)")
                    }

                    Spacer()

                    // Download format selector
                    HStack(spacing: 8) {
                        Text("Format:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $viewModel.downloadFormat) {
                            ForEach(NCBIFormat.downloadFormats) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                        .help("Choose download format: GenBank (with annotations) or FASTA (sequence only)")
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

            // Expandable filters
            if viewModel.isAdvancedExpanded {
                advancedFiltersGrid
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

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

            // Length range row
            HStack(spacing: 16) {
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

            // Help text
            Text("Advanced filters are combined with AND logic. Leave empty to ignore a filter.")
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

// MARK: - SearchResultRow

/// A single row in the search results list.
struct SearchResultRow: View {
    let record: SearchResultRecord
    var isSelected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.accession)
                    .font(.headline.monospaced())

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

                if let date = record.date {
                    Label(formatDate(date), systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
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

                    if let date = record.date {
                        Label(formatDate(date), systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
