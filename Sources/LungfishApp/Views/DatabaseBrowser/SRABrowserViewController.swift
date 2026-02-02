// SRABrowserViewController.swift - SRA search and FASTQ download UI
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import AppKit
import SwiftUI
import LungfishCore
import os.log

/// Logger for SRA browser operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "SRABrowser")

/// Controller for the SRA browser panel.
///
/// Provides search interface for NCBI SRA with FASTQ download capability.
@MainActor
public class SRABrowserViewController: NSViewController {

    // MARK: - Properties

    /// The SwiftUI hosting view
    private var hostingView: NSHostingView<SRABrowserView>!

    /// View model for the browser
    private var viewModel: SRABrowserViewModel!

    /// Completion handler called when downloads complete
    public var onDownloadComplete: (([URL]) -> Void)?

    /// Completion handler called when user cancels
    public var onCancel: (() -> Void)?

    // MARK: - Initialization

    public override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func loadView() {
        viewModel = SRABrowserViewModel()

        // Set up download completion callback
        viewModel.onDownloadComplete = { [weak self] urls in
            self?.onDownloadComplete?(urls)
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

        let browserView = SRABrowserView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: browserView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 550)
        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("SRA browser loaded")
    }
}

// MARK: - SRABrowserViewModel

/// View model for the SRA browser.
@MainActor
public class SRABrowserViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Search query text
    @Published var searchText = ""

    /// Search results
    @Published var results: [SRARunInfo] = []

    /// Currently selected run
    @Published var selectedRun: SRARunInfo?

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

    /// Whether SRA Toolkit is available
    @Published var sraToolkitAvailable = false

    // MARK: - Computed Properties

    /// Whether search text is valid (non-empty after trimming)
    var isSearchTextValid: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Callbacks

    /// Called when downloads complete with file URLs
    var onDownloadComplete: (([URL]) -> Void)?

    /// Called when user cancels
    var onCancel: (() -> Void)?

    // MARK: - Services

    private let sraService = SRAService()

    // MARK: - Initialization

    init() {
        Task {
            sraToolkitAvailable = await sraService.isSRAToolkitAvailable
        }
    }

    // MARK: - Actions

    /// Initiates a search operation.
    func performSearch() {
        guard isSearchTextValid else {
            errorMessage = "Please enter a search term"
            return
        }

        isSearching = true
        statusMessage = "Searching SRA..."
        errorMessage = nil
        results = []

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
        logger.info("Starting SRA search for: \(self.searchText, privacy: .public)")

        do {
            let query = SearchQuery(term: searchText, limit: 50)
            let searchResults = try await sraService.search(query)

            results = searchResults.runs
            statusMessage = "Found \(results.count) SRA runs"
            logger.info("SRA search completed: \(self.results.count, privacy: .public) results")

        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            logger.error("SRA search failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = nil
        }

        isSearching = false
    }

    /// Initiates a download operation for the selected run.
    func performDownload() {
        guard let run = selectedRun else {
            errorMessage = "No run selected"
            return
        }

        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        statusMessage = "Downloading \(run.accession)..."

        // Use Timer to ensure the Task runs on the main run loop
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.executeDownload(run: run)
            }
        }
    }

    /// Executes the actual download operation.
    private func executeDownload(run: SRARunInfo) async {
        do {
            let files: [URL]

            // Try SRA Toolkit first, fall back to ENA direct download
            if sraToolkitAvailable {
                logger.info("Downloading via SRA Toolkit: \(run.accession, privacy: .public)")
                files = try await sraService.downloadFASTQ(
                    accession: run.accession,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            self?.downloadProgress = progress
                        }
                    }
                )
            } else {
                logger.info("Downloading via ENA: \(run.accession, privacy: .public)")
                files = try await sraService.downloadFASTQFromENA(
                    accession: run.accession,
                    progress: { [weak self] progress in
                        Task { @MainActor in
                            self?.downloadProgress = progress
                        }
                    }
                )
            }

            downloadProgress = 1.0
            statusMessage = "Downloaded \(files.count) files for \(run.accession)"
            logger.info("Downloaded \(files.count, privacy: .public) files for \(run.accession, privacy: .public)")

            // Notify completion
            onDownloadComplete?(files)

        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            logger.error("Download failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = nil
        }

        isDownloading = false
    }
}

// MARK: - SRABrowserView

/// SwiftUI view for the SRA browser.
public struct SRABrowserView: View {
    @ObservedObject var viewModel: SRABrowserViewModel

    public var body: some View {
        VStack(spacing: 0) {
            // Header
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
        .frame(minWidth: 700, minHeight: 450)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text("NCBI Sequence Read Archive")
                .font(.headline)

            Spacer()

            // SRA Toolkit status
            if viewModel.sraToolkitAvailable {
                Label("SRA Toolkit available", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Label("Using ENA download", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Search field
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)

                    TextField("Search SRA (e.g., SARS-CoV-2, SRR11140748, WGS Illumina)", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
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
                        .padding(.trailing, 8)
                        .help("Clear search")
                    }
                }
                .padding(.vertical, 6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

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

            // Help text
            Text("Search by organism, accession, study title, or keywords. Results are limited to 50 runs.")
                .font(.caption)
                .foregroundColor(.secondary)
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
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Search for sequencing data")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Enter a search term to find SRA runs.\nYou can search by organism, accession, or keywords.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var resultsList: some View {
        List(viewModel.results, selection: $viewModel.selectedRun) { run in
            SRARunRow(run: run)
                .tag(run)
        }
        .listStyle(.inset)
    }

    private var footerSection: some View {
        HStack {
            // Cancel button
            Button("Cancel") {
                viewModel.onCancel?()
            }
            .keyboardShortcut(.cancelAction)

            if let error = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .lineLimit(1)
            }

            Spacer()

            if viewModel.isDownloading {
                ProgressView(value: viewModel.downloadProgress)
                    .frame(width: 100)
                Text("Downloading...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button("Download FASTQ") {
                viewModel.performDownload()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedRun == nil || viewModel.isDownloading)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - SRARunRow

/// A single row in the SRA results list.
struct SRARunRow: View {
    let run: SRARunInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // First row: accession and size
            HStack {
                Text(run.accession)
                    .font(.headline.monospaced())

                Spacer()

                Text(run.sizeString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
            }

            // Second row: organism and read info
            HStack {
                if let organism = run.organism, !organism.isEmpty {
                    Label(organism, systemImage: "leaf")
                        .font(.subheadline)
                        .foregroundColor(.green)
                }

                Spacer()

                Text(run.spotsString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Third row: platform and library info
            HStack(spacing: 12) {
                if let platform = run.platform {
                    Label(platform, systemImage: "cpu")
                        .font(.caption)
                        .foregroundColor(.blue)
                }

                if let strategy = run.libraryStrategy {
                    Label(strategy, systemImage: "books.vertical")
                        .font(.caption)
                        .foregroundColor(.purple)
                }

                if let layout = run.libraryLayout {
                    Label(layout, systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                Spacer()

                if let date = run.releaseDate {
                    Label(formatDate(date), systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Fourth row: study/project info
            HStack(spacing: 8) {
                if let study = run.study {
                    Text(study)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let bioproject = run.bioproject {
                    Text(bioproject)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

// MARK: - SRARunInfo Hashable

extension SRARunInfo: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(accession)
    }
}
