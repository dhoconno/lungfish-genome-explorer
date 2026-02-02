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

        // Set up download completion callback
        viewModel.onDownloadComplete = { [weak self] url in
            self?.onDownloadComplete?(url)
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

    /// Search results
    @Published var results: [SearchResultRecord] = []

    /// Currently selected record
    @Published var selectedRecord: SearchResultRecord?

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

    // MARK: - Callbacks

    /// Called when a download completes with the file URL
    var onDownloadComplete: ((URL) -> Void)?

    /// Called when user cancels
    var onCancel: (() -> Void)?

    // MARK: - Services

    private let ncbiService = NCBIService()
    private let enaService = ENAService()

    // MARK: - Initialization

    init(source: DatabaseSource) {
        self.source = source
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
    /// Uses a Task with explicit @MainActor to ensure proper actor isolation.
    func performSearch() {
        guard isSearchTextValid else {
            errorMessage = "Please enter a search term"
            return
        }

        // Cancel any existing search
        cancelSearch()

        // Reset state
        searchPhase = .connecting
        errorMessage = nil
        results = []

        // Start new search task with explicit MainActor context
        currentSearchTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.executeSearch()
        }
    }

    /// Builds the search term based on scope
    private func buildSearchTerm() -> String {
        let term = searchText.trimmingCharacters(in: .whitespaces)

        switch searchScope {
        case .all:
            return term
        case .accession:
            return term
        case .organism:
            return "\(term)[Organism]"
        case .title:
            return "\(term)[Title]"
        }
    }

    /// Executes the actual search operation.
    private func executeSearch() async {
        let searchTerm = buildSearchTerm()
        logger.info("Starting search for: \(searchTerm, privacy: .public)")

        do {
            // Check for cancellation
            try Task.checkCancellation()

            // Update phase to searching
            searchPhase = .searching

            let query = SearchQuery(
                term: searchTerm,
                organism: organismFilter.isEmpty ? nil : organismFilter,
                location: locationFilter.isEmpty ? nil : locationFilter,
                minLength: Int(minLength),
                maxLength: Int(maxLength),
                limit: 50
            )

            // Check for cancellation before network call
            try Task.checkCancellation()

            let searchResults: SearchResults

            switch source {
            case .ncbi:
                // Update phase to loading details (NCBI does esearch + esummary)
                searchPhase = .loadingDetails
                searchResults = try await ncbiService.search(query)
            case .ena:
                searchPhase = .loadingDetails
                searchResults = try await enaService.search(query)
            default:
                throw DatabaseServiceError.invalidQuery(reason: "Unsupported database: \(source)")
            }

            // Check for cancellation after network call
            try Task.checkCancellation()

            results = searchResults.records
            searchPhase = .complete(count: results.count)
            logger.info("Search completed: \(self.results.count, privacy: .public) results")

        } catch is CancellationError {
            // Search was cancelled, don't show error
            logger.info("Search cancelled")
            searchPhase = .idle
        } catch {
            let errorMsg = error.localizedDescription
            errorMessage = "Search failed: \(errorMsg)"
            searchPhase = .failed(errorMsg)
            logger.error("Search failed: \(errorMsg, privacy: .public)")
        }

        currentSearchTask = nil
    }

    /// Public async search method.
    func search() async {
        await executeSearch()
    }

    /// Initiates a download operation for the selected record.
    func performDownload() {
        guard let record = selectedRecord else {
            errorMessage = "No record selected"
            return
        }

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        _statusMessage = "Downloading \(record.accession)..."

        // Use Task with explicit MainActor context
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.executeDownload(record: record)
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

        await executeDownload(record: record)
    }

    /// Executes the actual download operation.
    private func executeDownload(record: SearchResultRecord) async {
        do {
            let dbRecord: DatabaseRecord

            downloadProgress = 0.1
            _statusMessage = "Connecting to \(source.displayName)..."

            switch source {
            case .ncbi:
                downloadProgress = 0.2
                _statusMessage = "Fetching \(record.accession)..."
                dbRecord = try await ncbiService.fetch(accession: record.accession)
            case .ena:
                downloadProgress = 0.2
                _statusMessage = "Fetching \(record.accession)..."
                dbRecord = try await enaService.fetch(accession: record.accession)
            default:
                throw DatabaseServiceError.invalidQuery(reason: "Unsupported database: \(source)")
            }

            downloadProgress = 0.7
            _statusMessage = "Saving \(record.accession)..."

            // Save to temporary file
            let tempURL = try saveToTemporaryFile(record: dbRecord)

            downloadProgress = 1.0
            _statusMessage = "Download complete: \(record.accession)"
            logger.info("Downloaded \(record.accession, privacy: .public) to \(tempURL.path, privacy: .public)")

            // Notify completion
            onDownloadComplete?(tempURL)

        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
            _statusMessage = nil
        }

        isDownloading = false
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
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var databaseIcon: String {
        switch viewModel.source {
        case .ncbi:
            return "building.columns"
        case .ena:
            return "globe.europe.africa"
        default:
            return "magnifyingglass"
        }
    }

    private var searchSection: some View {
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

                // Search text field
                TextField(searchPlaceholder, text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.performSearch()
                    }

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
                resultsList
            }
        }
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
        List(viewModel.results, selection: $viewModel.selectedRecord) { record in
            SearchResultRow(record: record)
                .tag(record)
        }
        .listStyle(.inset)
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

                Button("Download Selected") {
                    viewModel.performDownload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedRecord == nil || viewModel.isDownloading || viewModel.isSearching)
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

// MARK: - DatabaseSource Extension

extension DatabaseSource {
    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .ncbi:
            return "NCBI Nucleotide"
        case .ena:
            return "European Nucleotide Archive"
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
        hasher.combine(accession)
    }
}
