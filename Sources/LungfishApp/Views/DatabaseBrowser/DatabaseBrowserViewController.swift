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

        let browserView = DatabaseBrowserView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: browserView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("Database browser loaded for \(self.databaseSource.displayName, privacy: .public)")
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

    /// Optional organism filter
    @Published var organismFilter = ""

    /// Minimum sequence length filter
    @Published var minLength: String = ""

    /// Maximum sequence length filter
    @Published var maxLength: String = ""

    /// Search results
    @Published var results: [SearchResultRecord] = []

    /// Currently selected record
    @Published var selectedRecord: SearchResultRecord?

    /// Whether a search is in progress
    @Published var isSearching = false

    /// Whether a download is in progress
    @Published var isDownloading = false

    /// Error message to display
    @Published var errorMessage: String?

    /// Download progress (0-1)
    @Published var downloadProgress: Double = 0

    /// Status message
    @Published var statusMessage: String?

    // MARK: - Callbacks

    /// Called when a download completes with the file URL
    var onDownloadComplete: ((URL) -> Void)?

    // MARK: - Services

    private let ncbiService = NCBIService()
    private let enaService = ENAService()

    // MARK: - Initialization

    init(source: DatabaseSource) {
        self.source = source
    }

    // MARK: - Actions

    /// Initiates a search operation.
    ///
    /// Uses a Timer to ensure the async task runs properly in the SwiftUI context.
    func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a search term"
            return
        }

        isSearching = true
        statusMessage = "Searching..."
        errorMessage = nil

        // Use Timer to ensure the Task runs on the main run loop
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.executeSearch()
            }
        }
    }

    /// Executes the actual search operation.
    private func executeSearch() async {
        logger.info("Starting search for: \(self.searchText, privacy: .public)")

        do {
            let query = SearchQuery(
                term: searchText,
                organism: organismFilter.isEmpty ? nil : organismFilter,
                minLength: Int(minLength),
                maxLength: Int(maxLength),
                limit: 50
            )

            let searchResults: SearchResults

            switch source {
            case .ncbi:
                searchResults = try await ncbiService.search(query)
            case .ena:
                searchResults = try await enaService.search(query)
            default:
                throw DatabaseServiceError.invalidQuery(reason: "Unsupported database: \(source)")
            }

            results = searchResults.records
            statusMessage = "Found \(results.count) results"
            logger.info("Search completed: \(self.results.count, privacy: .public) results")

        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            logger.error("Search failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = nil
        }

        isSearching = false
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
        statusMessage = "Downloading \(record.accession)..."

        // Use Timer to ensure the Task runs on the main run loop
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.executeDownload(record: record)
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
        statusMessage = "Downloading \(record.accession)..."

        await executeDownload(record: record)
    }

    /// Executes the actual download operation.
    private func executeDownload(record: SearchResultRecord) async {
        do {
            let dbRecord: DatabaseRecord

            downloadProgress = 0.3

            switch source {
            case .ncbi:
                dbRecord = try await ncbiService.fetch(accession: record.accession)
            case .ena:
                dbRecord = try await enaService.fetch(accession: record.accession)
            default:
                throw DatabaseServiceError.invalidQuery(reason: "Unsupported database: \(source)")
            }

            downloadProgress = 0.7

            // Save to temporary file
            let tempURL = try saveToTemporaryFile(record: dbRecord)

            downloadProgress = 1.0
            statusMessage = "Download complete: \(record.accession)"
            logger.info("Downloaded \(record.accession, privacy: .public) to \(tempURL.path, privacy: .public)")

            // Notify completion
            onDownloadComplete?(tempURL)

        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = nil
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
        .frame(minWidth: 600, minHeight: 400)
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

            if let status = viewModel.statusMessage {
                Text(status)
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
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search term (e.g., Ebola virus, NC_002549)", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        viewModel.performSearch()
                    }

                if viewModel.isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button("Search") {
                        viewModel.performSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.searchText.isEmpty)
                }
            }

            // Filters
            HStack(spacing: 16) {
                HStack {
                    Text("Organism:")
                        .foregroundColor(.secondary)
                    TextField("e.g., Ebolavirus", text: $viewModel.organismFilter)
                        .frame(width: 150)
                }

                HStack {
                    Text("Length:")
                        .foregroundColor(.secondary)
                    TextField("Min", text: $viewModel.minLength)
                        .frame(width: 70)
                    Text("-")
                    TextField("Max", text: $viewModel.maxLength)
                        .frame(width: 70)
                }
            }
            .font(.callout)
        }
        .padding()
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
        HStack {
            if let error = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Spacer()

            if viewModel.isDownloading {
                ProgressView(value: viewModel.downloadProgress)
                    .frame(width: 100)
                Text("Downloading...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("Download Selected") {
                viewModel.performDownload()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedRecord == nil || viewModel.isDownloading)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
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
