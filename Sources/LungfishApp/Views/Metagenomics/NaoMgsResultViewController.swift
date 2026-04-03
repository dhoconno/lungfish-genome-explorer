// NaoMgsResultViewController.swift - NAO-MGS metagenomic surveillance result viewer
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "NaoMgsResultVC")

/// Type alias to disambiguate the database accession summary from the in-app one.
private typealias DBAccessionSummary = LungfishIO.NaoMgsAccessionSummary

// MARK: - NaoMgsResultViewController

/// A full-screen NAO-MGS metagenomic surveillance result browser.
///
/// `NaoMgsResultViewController` is the primary UI for displaying imported
/// NAO-MGS workflow results. It uses a SQLite database for fast random-access
/// queries instead of holding all hits in memory.
///
/// ## Layout
///
/// ```
/// +--------------------------------------------------+
/// | Summary Bar (48pt)                                |
/// +--------------------------------------------------+
/// |  Detail Pane       |  Taxonomy Table              |
/// |  (miniBAM viewer,  |                              |
/// |   accession info,  |  - Taxid 130309              |
/// |   metrics)         |    125,727 hits              |
/// |                    |  - Taxid 28284               |
/// |                    |    36,577 hits               |
/// |                    |  ...                         |
/// +--------------------------------------------------+
/// | Action Bar (36pt)                                 |
/// +--------------------------------------------------+
/// ```
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated and uses raw `NSSplitView` (not
/// `NSSplitViewController`) per macOS 26 deprecated API rules.
@MainActor
public final class NaoMgsResultViewController: NSViewController, NSSplitViewDelegate, NSPopoverDelegate {

    // MARK: - Data (Database-backed)

    /// SQLite database for virus hits and taxon summaries.
    private var database: NaoMgsDatabase?

    /// Bundle manifest metadata.
    private var manifest: NaoMgsManifest?

    /// Total hits for percentage display in the action bar.
    private var naoMgsTotalHits: Int = 0

    /// URL of the NAO-MGS bundle directory.
    private var bundleURL: URL?

    /// All samples with their hit counts from the database.
    private var allSamples: [(sample: String, hitCount: Int)] = []

    /// Currently selected sample names for filtering.
    private var selectedSamples: Set<String> = []

    /// Sample entries for the picker view.
    var sampleEntries: [NaoMgsSampleEntry] = []

    /// NAO-MGS sample entry for the unified picker.
    struct NaoMgsSampleEntry: ClassifierSampleEntry {
        let id: String
        let displayName: String
        let hitCount: Int

        var metricLabel: String { "hits" }
        var metricValue: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: hitCount)) ?? "\(hitCount)"
        }
    }

    /// Common prefix stripped from sample display names.
    var strippedPrefix: String = ""

    /// Currently displayed taxonomy rows (filtered + sorted).
    private var displayedRows: [NaoMgsTaxonSummaryRow] = []

    /// Currently selected taxon summary row.
    private var selectedRow: NaoMgsTaxonSummaryRow?

    /// Currently selected accession within the detail pane.
    private var selectedAccession: String?

    // MARK: - Child Views

    private let summaryBar = NaoMgsSummaryBar()
    let splitView = NSSplitView()
    private let taxonomyTableScrollView = NSScrollView()
    private let taxonomyTableView = NSTableView()
    private let taxonomyFilterBar = NSStackView()
    private let sampleFilterButton = NSButton(title: "All Samples", target: nil, action: nil)
    private let taxonFilterField = NSSearchField()
    private let hitsFilterField = NSTextField()
    private let uniqueReadsFilterField = NSTextField()
    private let refsFilterField = NSTextField()
    private let detailScrollView = NSScrollView()
    private let detailContentView = FlippedNaoMgsContentView()
    let actionBar = ClassifierActionBar()

    // MARK: - Multi-Selection Placeholder

    private lazy var multiSelectionPlaceholder: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let primary = NSTextField(labelWithString: "")
        primary.font = .systemFont(ofSize: 13, weight: .semibold)
        primary.alignment = .center
        primary.translatesAutoresizingMaskIntoConstraints = false

        let secondary = NSTextField(labelWithString: "Select a single row to view details")
        secondary.font = .systemFont(ofSize: 11)
        secondary.textColor = .tertiaryLabelColor
        secondary.alignment = .center
        secondary.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [primary, secondary])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        container.isHidden = true
        return container
    }()

    // MARK: - MiniBAM

    /// Embedded miniBAM controllers currently shown in the detail pane.
    private var miniBAMControllers: [MiniBAMViewController] = []

    /// Per-accession preferred miniBAM heights.
    private var miniBAMPreferredHeights: [String: CGFloat] = [:]

    private let miniBAMDefaultHeight: CGFloat = 220
    private let miniBAMMinHeight: CGFloat = 140
    private let miniBAMMaxHeight: CGFloat = 900
    /// Number of accession miniBAM panels to show per selected taxon.
    private let miniBAMDisplayLimit: Int = 5

    // MARK: - Loading State

    /// Overlay view shown during initial load and filter operations.
    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Loading…")

    /// Debounce work item for filter field changes.
    private var filterDebounceWorkItem: DispatchWorkItem?

    /// Task for asynchronously loading miniBAM reads.
    private var miniBAMLoadingTask: Task<Void, Never>?

    /// Per-card loading spinners for miniBAM skeleton views.
    private var miniBAMCardSpinners: [NSProgressIndicator] = []

    /// Accession summaries for the currently displayed taxon (retained for async loading).
    private var currentAccessionSummaries: [DBAccessionSummary] = []

    // MARK: - Split View State

    /// The left (detail) pane container in the split view.
    private var detailContainer: NaoMgsDetailContainer?

    /// The right (table) pane container in the split view.
    private var tableContainer: NSView?

    /// Whether the initial divider position has been applied.
    private var didSetInitialSplitPosition = false

    /// Active bottom constraint for the split view. Re-pinned when BLAST drawer opens.
    private var splitViewBottomConstraint: NSLayoutConstraint?

    /// Bottom BLAST results drawer shown after in-app verification.
    private var blastDrawerView: BlastResultsDrawerTab?
    private var blastDrawerBottomConstraint: NSLayoutConstraint?
    private var isBlastDrawerOpen = false

    /// Active sample picker popover.
    private var samplePopover: NSPopover?

    /// Observable state shared with the SwiftUI sample picker popover and Inspector.
    var samplePickerState: ClassifierSamplePickerState!

    /// Sample metadata for dynamic column display in the taxonomy table.
    var sampleMetadataStore: SampleMetadataStore? {
        didSet {
            updateMetadataColumnsForCurrentSamples()
        }
    }

    /// Controller for dynamic sample metadata columns (from imported CSV/TSV).
    private let metadataColumnController = MetadataColumnController()

    // MARK: - Selection Sync

    /// Prevents infinite feedback loops when syncing selection between views.
    private var suppressSelectionSync = false

    // MARK: - Callbacks

    /// Called when the user confirms BLAST verification for a taxon.
    public var onBlastVerification: ((NaoMgsTaxonSummary, Int, [NaoMgsVirusHit]) -> Void)?

    /// Called when the user wants to export results.
    public var onExport: (() -> Void)?

    /// Called when the user selects a taxon and wants to view it on NCBI.
    public var onViewOnNCBI: ((NaoMgsTaxonSummary) -> Void)?

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view = container

        setupSummaryBar()
        setupSplitView()
        setupActionBar()
        setupLoadingOverlay()
        layoutSubviews()
        wireCallbacks()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        applySplitPositionIfNeeded(force: false)
    }

    // MARK: - Public API

    /// Configures the view with cached taxon rows from the manifest.
    ///
    /// Shows the taxon list immediately from cached data in manifest.json.
    /// The database is not yet available — detail pane and filters are disabled
    /// until `configure(database:manifest:bundleURL:)` is called.
    public func configureWithCachedRows(_ rows: [NaoMgsTaxonSummaryRow], manifest: NaoMgsManifest, bundleURL: URL? = nil) {
        self.manifest = manifest
        self.bundleURL = bundleURL

        // Populate the taxonomy table from cached data
        displayedRows = rows
        taxonomyTableView.reloadData()

        // Update summary bar with cached counts
        let totalHits = manifest.hitCount
        let taxonCount = rows.count
        naoMgsTotalHits = totalHits
        actionBar.updateInfoText("Select a taxon to view details")

        // Show loading indicator in the detail pane since database isn't ready
        showLoadingOverlay("Opening database…")

        // Force the split view to re-apply its 40/60 position.
        applySplitPositionIfNeeded(force: true)
        logger.info("Configured with \(rows.count) cached taxon rows from manifest")
    }

    /// Configures the view with a SQLite database and manifest.
    public func configure(database: NaoMgsDatabase, manifest: NaoMgsManifest, bundleURL: URL? = nil) {
        showLoadingOverlay("Loading taxonomy data…")

        self.database = database
        self.manifest = manifest
        self.bundleURL = bundleURL

        // Fetch samples from database
        do {
            allSamples = try database.fetchSamples()
        } catch {
            logger.error("Failed to fetch samples: \(error.localizedDescription, privacy: .public)")
            allSamples = []
        }

        // Resolve human-readable display names via manifest lookup.
        // bundleURL is the .lungfishfastq bundle; project is its parent.
        let sampleNames = allSamples.map(\.sample)
        let projectURL = bundleURL?.deletingLastPathComponent()
        strippedPrefix = ""

        // Create sample entries with resolved display names
        sampleEntries = allSamples.map { item in
            let displayName = FASTQDisplayNameResolver.resolveDisplayName(
                sampleId: item.sample, projectURL: projectURL)
            return NaoMgsSampleEntry(id: item.sample, displayName: displayName, hitCount: item.hitCount)
        }

        // Select all samples initially
        selectedSamples = Set(sampleNames)
        samplePickerState = ClassifierSamplePickerState(allSamples: selectedSamples)

        // Update summary bar
        summaryBar.update(database: database, manifest: manifest, selectedSamples: Array(selectedSamples))

        // Reload taxonomy table
        reloadTaxonomyTable()

        // Update action bar
        let totalHits = (try? database.totalHitCount()) ?? manifest.hitCount
        let taxonCount = displayedRows.count
        naoMgsTotalHits = totalHits
        actionBar.updateInfoText("Select a taxon to view details")

        // Auto-select top taxon so miniBAM panels are visible immediately.
        if displayedRows.isEmpty {
            showOverview()
        } else {
            selectRowByIndex(0)
        }

        // Force the split view to re-apply its 40/60 position now that we have content.
        applySplitPositionIfNeeded(force: true)

        // Update sample column visibility
        updateSampleColumnVisibility()

        hideLoadingOverlay()
        logger.info("Configured NAO-MGS viewer with database, \(self.allSamples.count) samples")
    }

    /// Legacy configure method — kept for backward compatibility during transition.
    public func configure(result: NaoMgsResult, bundleURL: URL? = nil) {
        logger.warning("configure(result:) called — this code path is deprecated, use configure(database:manifest:bundleURL:)")
    }

    // MARK: - Taxonomy Table Reload

    private func reloadTaxonomyTable() {
        guard let database else {
            displayedRows = []
            taxonomyTableView.reloadData()
            return
        }

        do {
            var rows = try database.fetchTaxonSummaryRows(samples: Array(selectedSamples))

            // Apply in-memory filters
            let taxonFilter = taxonFilterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !taxonFilter.isEmpty {
                rows = rows.filter {
                    ($0.name.isEmpty ? "Taxid \($0.taxId)" : $0.name)
                        .localizedCaseInsensitiveContains(taxonFilter)
                }
            }

            if let minHits = parseMinFilter(hitsFilterField.stringValue) {
                rows = rows.filter { $0.hitCount >= minHits }
            }
            if let minUnique = parseMinFilter(uniqueReadsFilterField.stringValue) {
                rows = rows.filter { $0.uniqueReadCount >= minUnique }
            }
            if let minRefs = parseMinFilter(refsFilterField.stringValue) {
                rows = rows.filter { $0.accessionCount >= minRefs }
            }

            // Apply sort
            if let sortDescriptor = taxonomyTableView.sortDescriptors.first {
                switch sortDescriptor.key {
                case "sample":
                    rows.sort {
                        let compare = $0.sample.localizedCaseInsensitiveCompare($1.sample)
                        return sortDescriptor.ascending ? compare == .orderedAscending : compare == .orderedDescending
                    }
                case "name":
                    rows.sort {
                        let compare = $0.name.localizedCaseInsensitiveCompare($1.name)
                        return sortDescriptor.ascending ? compare == .orderedAscending : compare == .orderedDescending
                    }
                case "hits":
                    rows.sort {
                        sortDescriptor.ascending ? $0.hitCount < $1.hitCount : $0.hitCount > $1.hitCount
                    }
                case "unique":
                    rows.sort {
                        sortDescriptor.ascending
                            ? $0.uniqueReadCount < $1.uniqueReadCount
                            : $0.uniqueReadCount > $1.uniqueReadCount
                    }
                case "refs":
                    rows.sort {
                        sortDescriptor.ascending
                            ? $0.accessionCount < $1.accessionCount
                            : $0.accessionCount > $1.accessionCount
                    }
                default:
                    break
                }
            }

            displayedRows = rows
        } catch {
            logger.error("Failed to fetch taxon summaries: \(error.localizedDescription, privacy: .public)")
            displayedRows = []
        }

        let selectedTaxId = selectedRow?.taxId
        let selectedSample = selectedRow?.sample
        taxonomyTableView.reloadData()

        guard !displayedRows.isEmpty else {
            suppressSelectionSync = true
            taxonomyTableView.deselectAll(nil)
            suppressSelectionSync = false
            showOverview()
            return
        }

        // Try to preserve selection
        if let selectedTaxId, let selectedSample,
           let idx = displayedRows.firstIndex(where: { $0.taxId == selectedTaxId && $0.sample == selectedSample }) {
            suppressSelectionSync = true
            taxonomyTableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            suppressSelectionSync = false
            return
        }

        // Fall back to first row
        suppressSelectionSync = true
        taxonomyTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        suppressSelectionSync = false
        showTaxonDetail(displayedRows[0])
    }

    // MARK: - Sample Column Visibility

    private func updateSampleColumnVisibility() {
        // Sample column is always visible — even with a single sample,
        // it provides useful context about which dataset the rows come from.
    }

    // MARK: - Sample Filter Button

    private func updateSampleFilterButtonTitle() {
        let total = allSamples.count
        let selected = selectedSamples.count
        if selected == total {
            sampleFilterButton.title = "All Samples"
        } else {
            sampleFilterButton.title = "\(selected) of \(total) Samples"
        }
    }

    @objc private func sampleFilterButtonClicked(_ sender: NSButton) {
        if let existing = samplePopover, existing.isShown {
            existing.close()
            samplePopover = nil
            return
        }

        // Sync current selection into the observable state object.
        samplePickerState.selectedSamples = selectedSamples

        let pickerView = ClassifierSamplePickerView(
            samples: sampleEntries,
            pickerState: samplePickerState,
            strippedPrefix: strippedPrefix,
            isInline: false
        )

        let hostingController = NSHostingController(rootView: pickerView)
        let popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        samplePopover = popover
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        // Sync the observable state back to the view controller when the popover closes.
        let newSelection = samplePickerState.selectedSamples
        guard newSelection != selectedSamples else { return }

        selectedSamples = newSelection
        updateSampleFilterButtonTitle()
        updateSampleColumnVisibility()
        updateMetadataColumnsForCurrentSamples()
        reloadTaxonomyTable()
        summaryBar.update(
            database: database,
            manifest: manifest,
            selectedSamples: Array(newSelection)
        )
        samplePopover = nil
    }

    // MARK: - Detail Pane Content

    /// Shows the overview when no taxon is selected.
    private func showOverview() {
        miniBAMLoadingTask?.cancel()
        miniBAMLoadingTask = nil
        selectedRow = nil
        selectedAccession = nil

        hideMultiSelectionPlaceholder()
        rebuildDetailContent()
        actionBar.updateInfoText("Select a taxon to view details")
        actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
        actionBar.setExtractEnabled(false)
    }

    /// Shows the detail pane for the selected taxon row.
    private func showTaxonDetail(_ row: NaoMgsTaxonSummaryRow) {
        miniBAMLoadingTask?.cancel()
        miniBAMLoadingTask = nil
        selectedRow = row
        selectedAccession = nil
        hideMultiSelectionPlaceholder()
        rebuildDetailContent()
        // Create a lightweight summary for the action bar
        updateActionBarForRow(row, totalHits: (try? database?.totalHitCount(samples: Array(selectedSamples))) ?? 0)
        actionBar.setExtractEnabled(true)
    }

    /// Stores accession selection from legacy list/table widgets.
    private func switchToAccession(_ accession: String) {
        selectedAccession = accession
    }

    // MARK: - Detail Content Rebuild

    private func rebuildDetailContent() {
        teardownEmbeddedMiniBAMControllers()
        for subview in detailContentView.subviews {
            subview.removeFromSuperview()
        }
        // Reset any active constraints on the content view
        detailContentView.removeConstraints(detailContentView.constraints)

        if let row = selectedRow {
            buildTaxonDetailContent(row)
        } else {
            buildOverviewContent()
        }

        // Use a deferred layout pass so the scroll view has real bounds.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeDetailContentToFit()
        }
    }

    /// Sizes the detail content view to match the scroll view width and fit content height.
    private func resizeDetailContentToFit() {
        let clipWidth = detailScrollView.contentView.bounds.width
        guard clipWidth > 0 else { return }

        // Set width to match clip view, then let Auto Layout compute height.
        detailContentView.frame.size.width = clipWidth
        detailContentView.layoutSubtreeIfNeeded()

        let fittingSize = detailContentView.fittingSize
        detailContentView.frame = NSRect(
            x: 0, y: 0,
            width: clipWidth,
            height: max(fittingSize.height, 400)
        )

        detailScrollView.contentView.scroll(to: .zero)
        detailScrollView.reflectScrolledClipView(detailScrollView.contentView)
    }

    // MARK: - Overview Content

    private func buildOverviewContent() {
        let titleLabel = NSTextField(labelWithString: "NAO-MGS Results Overview")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Select a taxon in the table to view alignments and statistics.")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(subtitleLabel)

        // Build a lightweight summary for the overview
        let sampleName = manifest?.sampleName ?? "Unknown"
        let totalHits = (try? database?.totalHitCount(samples: Array(selectedSamples))) ?? 0

        // Build NaoMgsTaxonSummary array from displayed rows for the overview chart
        let summaries = displayedRows.map { row in
            NaoMgsTaxonSummary(
                taxId: row.taxId,
                name: row.name,
                hitCount: row.hitCount,
                avgIdentity: row.avgIdentity,
                avgBitScore: row.avgBitScore,
                avgEditDistance: row.avgEditDistance,
                accessions: row.topAccessions,
                pcrDuplicateCount: row.pcrDuplicateCount
            )
        }

        let statsView = NaoMgsOverviewView(
            taxonSummaries: summaries,
            totalHitReads: totalHits,
            sampleName: sampleName,
            onTaxonSelected: { [weak self] taxId in
                self?.selectTaxonById(taxId)
            }
        )
        let hostingView = NSHostingView(rootView: statsView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: detailContentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            hostingView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            hostingView.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor),
        ])
        let overviewBottomConstraint = hostingView.bottomAnchor.constraint(lessThanOrEqualTo: detailContentView.bottomAnchor, constant: -16)
        overviewBottomConstraint.priority = .defaultHigh
        overviewBottomConstraint.isActive = true
    }

    // MARK: - Taxon Detail Content

    private func buildTaxonDetailContent(_ row: NaoMgsTaxonSummaryRow) {
        guard let database else { return }

        // Fetch accession summaries from database
        let accessionSummaries: [DBAccessionSummary]
        do {
            accessionSummaries = try database.fetchAccessionSummaries(sample: row.sample, taxId: row.taxId)
        } catch {
            logger.error("Failed to fetch accession summaries: \(error.localizedDescription, privacy: .public)")
            accessionSummaries = []
        }

        // Taxon name header
        let nameLabel = NSTextField(labelWithString: row.name.isEmpty ? "Taxid \(row.taxId)" : row.name)
        nameLabel.font = .systemFont(ofSize: 14, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(nameLabel)

        let subtitleLabel = NSTextField(
            labelWithString: "Taxid: \(row.taxId)  \u{2022}  \(row.uniqueReadCount) unique / \(row.hitCount) total reads  \u{2022}  \(row.accessionCount) accessions"
        )
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(subtitleLabel)

        // Metrics row
        let metricsView = buildMetricsView(for: row)
        detailContentView.addSubview(metricsView)

        // Scrollable list of miniBAM panels for top accessions (skeleton with spinners)
        currentAccessionSummaries = accessionSummaries
        let miniBAMListView = buildMiniBAMList(
            accessionSummaries: accessionSummaries,
            sample: row.sample,
            taxId: row.taxId
        )
        detailContentView.addSubview(miniBAMListView)

        // Fetch reads asynchronously — populates miniBAM cards one at a time
        loadMiniBAMsAsync(accessionSummaries: accessionSummaries, sample: row.sample, taxId: row.taxId)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: detailContentView.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            metricsView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            metricsView.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            metricsView.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            miniBAMListView.topAnchor.constraint(equalTo: metricsView.bottomAnchor, constant: 12),
            miniBAMListView.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 8),
            miniBAMListView.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -8),
        ])

        // Bottom constraint at lower priority — the FlippedNaoMgsContentView is frame-based
        // (documentView of scroll view) so its autoresizing mask creates a required-priority
        // height constraint. This bottom anchor defines the content size for resizeDetailContentToFit()
        // but must yield during the initial layout pass before the frame is expanded.
        let bottomConstraint = miniBAMListView.bottomAnchor.constraint(lessThanOrEqualTo: detailContentView.bottomAnchor, constant: -8)
        bottomConstraint.priority = .defaultHigh
        bottomConstraint.isActive = true
    }

    private func buildMiniBAMList(
        accessionSummaries: [DBAccessionSummary],
        sample: String,
        taxId: Int
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let totalCount = accessionSummaries.count
        let displayedAccessions = Array(accessionSummaries.prefix(miniBAMDisplayLimit))
        let shownCount = displayedAccessions.count
        let scopeLabel = totalCount <= miniBAMDisplayLimit ? "All" : "Top \(miniBAMDisplayLimit)"

        let headerLabel = NSTextField(
            labelWithString: "miniBAM Panels (\(scopeLabel): \(shownCount) of \(totalCount) accessions)"
        )
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        let noteLabel = NSTextField(
            labelWithString: "Top references by unique read count. Drag a panel handle downward to make it taller."
        )
        noteLabel.font = .systemFont(ofSize: 10)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(noteLabel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .gravityAreas
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            noteLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 2),
            noteLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            noteLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            stack.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        guard let database else {
            let emptyLabel = NSTextField(labelWithString: "No database available.")
            emptyLabel.font = .systemFont(ofSize: 11)
            emptyLabel.textColor = .secondaryLabelColor
            stack.addArrangedSubview(emptyLabel)
            return container
        }

        for accessionSummary in displayedAccessions {
            let card = NSView()
            // All views are layer-backed by default on macOS 26 — no wantsLayer needed.
            card.layer?.cornerRadius = 6
            card.layer?.borderWidth = 1
            card.layer?.borderColor = NSColor.separatorColor.cgColor
            card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
            card.translatesAutoresizingMaskIntoConstraints = false

            let uniqueReadCount = NumberFormatter.localizedString(
                from: NSNumber(value: accessionSummary.uniqueReadCount),
                number: .decimal
            )
            let readCount = NumberFormatter.localizedString(
                from: NSNumber(value: accessionSummary.readCount),
                number: .decimal
            )
            let coveredBP = NumberFormatter.localizedString(
                from: NSNumber(value: accessionSummary.coveredBasePairs),
                number: .decimal
            )
            let refLenStr = NumberFormatter.localizedString(
                from: NSNumber(value: accessionSummary.referenceLength),
                number: .decimal
            )
            let coveragePct = String(format: "%.0f%%", accessionSummary.coverageFraction * 100)

            // Accession button — clickable link to GenBank, with context menu
            let accessionButton = NSButton(title: accessionSummary.accession, target: self, action: #selector(openGenBankFromButton(_:)))
            accessionButton.bezelStyle = .inline
            accessionButton.isBordered = false
            accessionButton.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
            accessionButton.contentTintColor = .linkColor
            accessionButton.translatesAutoresizingMaskIntoConstraints = false

            let accMenu = NSMenu()
            let viewItem = NSMenuItem(
                title: "View \(accessionSummary.accession) on NCBI GenBank",
                action: #selector(contextViewAccessionOnNCBI(_:)),
                keyEquivalent: ""
            )
            viewItem.target = self
            viewItem.representedObject = accessionSummary.accession
            accMenu.addItem(viewItem)

            let copyItem = NSMenuItem(
                title: "Copy Accession",
                action: #selector(contextCopyAccession(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            copyItem.representedObject = accessionSummary.accession
            accMenu.addItem(copyItem)
            accessionButton.menu = accMenu

            // Stats label (non-selectable, informational)
            let statsLabel = NSTextField(
                labelWithString: "\(uniqueReadCount) unique / \(readCount) total  \u{2022}  \(coveredBP) / \(refLenStr) bp covered (\(coveragePct))"
            )
            statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            statsLabel.textColor = .secondaryLabelColor
            statsLabel.lineBreakMode = .byTruncatingTail
            statsLabel.translatesAutoresizingMaskIntoConstraints = false

            // Header strip: accession button + stats in an HStack
            let headerStrip = NSStackView(views: [accessionButton, statsLabel])
            headerStrip.orientation = .horizontal
            headerStrip.alignment = .firstBaseline
            headerStrip.spacing = 8
            headerStrip.translatesAutoresizingMaskIntoConstraints = false
            // Let the stats label compress but not the accession button
            accessionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            statsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            statsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            card.addSubview(headerStrip)

            let miniBAM = MiniBAMViewController()
            miniBAM.subjectNoun = "reference"
            miniBAM.showsPCRDuplicates = false
            miniBAM.keyboardShortcutsEnabled = true
            addChild(miniBAM)
            miniBAMControllers.append(miniBAM)

            let bamView = miniBAM.view
            bamView.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(bamView)

            let preferredHeight = miniBAMPreferredHeights[accessionSummary.accession] ?? miniBAMDefaultHeight
            let heightConstraint = bamView.heightAnchor.constraint(equalToConstant: preferredHeight)
            miniBAM.onResizeBy = { [weak self] deltaY in
                self?.adjustMiniBAMHeight(
                    accession: accessionSummary.accession,
                    constraint: heightConstraint,
                    by: deltaY
                )
            }

            NSLayoutConstraint.activate([
                headerStrip.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
                headerStrip.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
                headerStrip.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),

                bamView.topAnchor.constraint(equalTo: headerStrip.bottomAnchor, constant: 6),
                bamView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
                bamView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
                bamView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
                heightConstraint,
            ])

            // Per-card loading spinner — reads fetched async via loadMiniBAMsAsync()
            let cardSpinner = NSProgressIndicator()
            cardSpinner.style = .spinning
            cardSpinner.controlSize = .small
            cardSpinner.translatesAutoresizingMaskIntoConstraints = false
            bamView.addSubview(cardSpinner)
            NSLayoutConstraint.activate([
                cardSpinner.centerXAnchor.constraint(equalTo: bamView.centerXAnchor),
                cardSpinner.centerYAnchor.constraint(equalTo: bamView.centerYAnchor),
            ])
            cardSpinner.startAnimation(nil)
            miniBAMCardSpinners.append(cardSpinner)

            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return container
    }

    // MARK: - Loading Overlay

    private func setupLoadingOverlay() {
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.isHidden = true

        // Semi-transparent background
        let backing = NSVisualEffectView()
        backing.material = .hudWindow
        backing.blendingMode = .withinWindow
        backing.state = .active
        backing.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(backing)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingSpinner)

        loadingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingLabel)

        view.addSubview(loadingOverlay)

        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: loadingOverlay.topAnchor),
            backing.leadingAnchor.constraint(equalTo: loadingOverlay.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: loadingOverlay.trailingAnchor),
            backing.bottomAnchor.constraint(equalTo: loadingOverlay.bottomAnchor),

            loadingOverlay.topAnchor.constraint(equalTo: splitView.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: splitView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: splitView.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -12),

            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 8),
            loadingLabel.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }

    private func showLoadingOverlay(_ message: String) {
        loadingLabel.stringValue = message
        loadingOverlay.isHidden = false
        loadingSpinner.startAnimation(nil)
    }

    private func hideLoadingOverlay() {
        loadingSpinner.stopAnimation(nil)
        loadingOverlay.isHidden = true
    }

    // MARK: - Async MiniBAM Loading

    /// Asynchronously fetches reads and populates miniBAM cards one at a time.
    ///
    /// Cards are built as skeletons with spinners by `buildMiniBAMList()`. This method
    /// then fills them sequentially, yielding between cards for UI responsiveness.
    private func loadMiniBAMsAsync(
        accessionSummaries: [DBAccessionSummary],
        sample: String,
        taxId: Int
    ) {
        miniBAMLoadingTask?.cancel()
        let displayed = Array(accessionSummaries.prefix(miniBAMDisplayLimit))

        miniBAMLoadingTask = Task { [weak self] in
            guard let self else { return }

            for (index, summary) in displayed.enumerated() {
                guard !Task.isCancelled else { return }
                guard let database = self.database else { return }
                guard index < self.miniBAMControllers.count else { return }

                do {
                    let reads = try database.fetchReadsForAccession(
                        sample: sample,
                        taxId: taxId,
                        accession: summary.accession,
                        maxReads: max(1, summary.readCount)
                    )
                    guard !Task.isCancelled else { return }

                    self.miniBAMControllers[index].displayReads(
                        reads: reads,
                        contig: summary.accession,
                        contigLength: max(summary.referenceLength, 1)
                    )
                } catch {
                    logger.error("Failed to fetch reads for \(summary.accession): \(error.localizedDescription, privacy: .public)")
                }

                // Remove per-card spinner
                if index < self.miniBAMCardSpinners.count {
                    self.miniBAMCardSpinners[index].stopAnimation(nil)
                    self.miniBAMCardSpinners[index].removeFromSuperview()
                }

                // Yield between cards to keep UI responsive
                await Task.yield()
            }
        }
    }

    private func adjustMiniBAMHeight(
        accession: String,
        constraint: NSLayoutConstraint,
        by deltaY: CGFloat
    ) {
        let current = miniBAMPreferredHeights[accession] ?? miniBAMDefaultHeight
        let next = min(max(miniBAMMinHeight, current + deltaY), miniBAMMaxHeight)
        miniBAMPreferredHeights[accession] = next
        constraint.constant = next
        detailContentView.layoutSubtreeIfNeeded()
    }

    private func teardownEmbeddedMiniBAMControllers() {
        miniBAMLoadingTask?.cancel()
        miniBAMLoadingTask = nil
        for spinner in miniBAMCardSpinners {
            spinner.stopAnimation(nil)
            spinner.removeFromSuperview()
        }
        miniBAMCardSpinners.removeAll()
        currentAccessionSummaries.removeAll()
        for controller in miniBAMControllers {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        miniBAMControllers.removeAll()
    }

    private func buildMetricsView(for row: NaoMgsTaxonSummaryRow) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .top
        container.distribution = .fillEqually
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let metrics: [(String, String)] = [
            ("Avg Identity", String(format: "%.1f%%", row.avgIdentity)),
            ("Avg Bit Score", String(format: "%.0f", row.avgBitScore)),
            ("Avg Edit Dist", String(format: "%.1f", row.avgEditDistance)),
            ("Unique Reads", naoMgsFormatCount(row.uniqueReadCount)),
            ("Accessions", "\(row.accessionCount)"),
        ]

        for (label, value) in metrics {
            let pill = makeMetricPill(label: label, value: value)
            container.addArrangedSubview(pill)
        }

        return container
    }

    private func makeMetricPill(label: String, value: String) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 9, weight: .medium)
        labelField.textColor = .tertiaryLabelColor
        labelField.alignment = .center
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueField.textColor = .labelColor
        valueField.alignment = .center
        valueField.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(labelField)
        pill.addSubview(valueField)

        NSLayoutConstraint.activate([
            labelField.topAnchor.constraint(equalTo: pill.topAnchor),
            labelField.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            valueField.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: 2),
            valueField.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            valueField.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            valueField.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])

        return pill
    }

    private func buildAccessionList(accessionSummaries: [DBAccessionSummary]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let headerLabel = NSTextField(labelWithString: "Reference Accessions (\(accessionSummaries.count))")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        // Create accession table
        let tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true

        let accessionTable = NSTableView()
        accessionTable.headerView = nil
        accessionTable.rowHeight = 20
        accessionTable.style = .plain
        accessionTable.usesAlternatingRowBackgroundColors = false

        let accColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("accession"))
        accColumn.title = "Accession"
        accessionTable.addTableColumn(accColumn)

        // Use tags to identify this table vs the taxonomy table
        accessionTable.tag = 999

        // Store summaries for the data source
        let wrapper = AccessionDataWrapper(summaries: accessionSummaries, selected: selectedAccession)
        accessionTable.dataSource = wrapper
        accessionTable.delegate = wrapper
        objc_setAssociatedObject(container, &accessionDataKey, wrapper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        wrapper.onSelect = { [weak self] accession in
            self?.selectedAccession = accession
            self?.switchToAccession(accession)
        }

        // Right-click context menu for copying accession
        let menu = NSMenu(title: "Accession Actions")
        wrapper.contextMenu = menu
        wrapper.populateMenu = { [weak self] menu, accession in
            menu.removeAllItems()
            let copyItem = NSMenuItem(title: "Copy Accession", action: #selector(self?.contextCopyAccession(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = accession
            menu.addItem(copyItem)

            let viewNCBI = NSMenuItem(title: "View on NCBI", action: #selector(self?.contextViewAccessionOnNCBI(_:)), keyEquivalent: "")
            viewNCBI.target = self
            viewNCBI.representedObject = accession
            menu.addItem(viewNCBI)
        }
        accessionTable.menu = menu

        tableScrollView.documentView = accessionTable

        container.addSubview(tableScrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            tableScrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            tableScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            tableScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    // MARK: - Taxon Selection

    /// Selects a taxon by its taxonomy ID, updating both the table and detail pane.
    private func selectTaxonById(_ taxId: Int) {
        guard database != nil else { return }
        guard let index = displayedRows.firstIndex(where: { $0.taxId == taxId }) else { return }
        selectRowByIndex(index)
    }

    /// Selects a row by its index in the displayed rows.
    private func selectRowByIndex(_ index: Int) {
        guard index < displayedRows.count else { return }

        suppressSelectionSync = true
        taxonomyTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        taxonomyTableView.scrollRowToVisible(index)
        suppressSelectionSync = false

        showTaxonDetail(displayedRows[index])
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
    }

    // MARK: - Setup: Split View

    /// Configures the NSSplitView with detail pane (left) and taxonomy table (right).
    ///
    /// Uses raw NSSplitView (not NSSplitViewController) per macOS 26 rules.
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Left pane: detail (miniBAM + metrics + accessions).
        // The detail pane is a self-contained NSView that uses an internal scroll view.
        let detail = NaoMgsDetailContainer(scrollView: detailScrollView, contentView: detailContentView)
        detailContainer = detail

        // Right pane: taxonomy table
        let tableCont = NSView()
        self.tableContainer = tableCont
        setupTaxonomyTable()
        setupTaxonomyFilterBar(in: tableCont)

        splitView.addArrangedSubview(detail)
        splitView.addArrangedSubview(tableCont)

        // Multi-selection placeholder overlay on the detail container
        detail.addSubview(multiSelectionPlaceholder)
        NSLayoutConstraint.activate([
            multiSelectionPlaceholder.topAnchor.constraint(equalTo: detail.topAnchor),
            multiSelectionPlaceholder.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            multiSelectionPlaceholder.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            multiSelectionPlaceholder.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
        ])

        // Table pane resizes first; detail pane holds width firmly.
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        // Force initial layout so both panes are visible.
        splitView.adjustSubviews()

        view.addSubview(splitView)

        // Respect saved layout preference (table on left vs right).
        applyLayoutPreference()
    }

    /// Configures the taxonomy table with columns for taxon data.
    private func setupTaxonomyTable() {
        taxonomyTableView.headerView = NSTableHeaderView()
        taxonomyTableView.usesAlternatingRowBackgroundColors = true
        taxonomyTableView.allowsMultipleSelection = true
        taxonomyTableView.allowsColumnReordering = true
        taxonomyTableView.allowsColumnResizing = true
        taxonomyTableView.style = .inset
        taxonomyTableView.intercellSpacing = NSSize(width: 8, height: 2)
        taxonomyTableView.rowHeight = 22

        // Columns
        let sampleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sample"))
        sampleColumn.title = "Sample"
        sampleColumn.width = 130
        sampleColumn.minWidth = 60
        sampleColumn.maxWidth = 600
        sampleColumn.resizingMask = .userResizingMask
        sampleColumn.sortDescriptorPrototype = NSSortDescriptor(key: "sample", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        taxonomyTableView.addTableColumn(sampleColumn)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Taxon"
        nameColumn.width = 210
        nameColumn.minWidth = 120
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        taxonomyTableView.addTableColumn(nameColumn)

        let hitsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hits"))
        hitsColumn.title = "Hits"
        hitsColumn.width = 64
        hitsColumn.minWidth = 48
        hitsColumn.sortDescriptorPrototype = NSSortDescriptor(key: "hits", ascending: false)
        taxonomyTableView.addTableColumn(hitsColumn)

        let uniqueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("unique"))
        uniqueColumn.title = "Unique Reads"
        uniqueColumn.width = 96
        uniqueColumn.minWidth = 72
        uniqueColumn.sortDescriptorPrototype = NSSortDescriptor(key: "unique", ascending: false)
        taxonomyTableView.addTableColumn(uniqueColumn)

        let refsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("refs"))
        refsColumn.title = "Refs"
        refsColumn.width = 52
        refsColumn.minWidth = 40
        refsColumn.sortDescriptorPrototype = NSSortDescriptor(key: "refs", ascending: false)
        taxonomyTableView.addTableColumn(refsColumn)

        taxonomyTableView.dataSource = self
        taxonomyTableView.delegate = self
        taxonomyTableView.menu = buildContextMenu()

        // Sort by hits descending initially
        taxonomyTableView.sortDescriptors = [
            NSSortDescriptor(key: "hits", ascending: false)
        ]

        // Scroll view setup
        taxonomyTableScrollView.documentView = taxonomyTableView
        taxonomyTableScrollView.hasVerticalScroller = true
        taxonomyTableScrollView.hasHorizontalScroller = false
        taxonomyTableScrollView.autohidesScrollers = true
        taxonomyTableScrollView.drawsBackground = true

        taxonomyTableView.setAccessibilityLabel("NAO-MGS Taxonomy Table")

        // Install metadata column controller for dynamic sample metadata columns.
        metadataColumnController.standardColumnNames = [
            "Sample", "Taxon", "Hits", "Unique Reads", "Refs",
        ]
        metadataColumnController.install(on: taxonomyTableView)
    }

    private func setupTaxonomyFilterBar(in container: NSView) {
        container.translatesAutoresizingMaskIntoConstraints = false

        taxonomyFilterBar.translatesAutoresizingMaskIntoConstraints = false
        taxonomyFilterBar.orientation = .horizontal
        taxonomyFilterBar.alignment = .centerY
        taxonomyFilterBar.spacing = 6
        container.addSubview(taxonomyFilterBar)

        // Sample filter button (replaces old search field)
        sampleFilterButton.translatesAutoresizingMaskIntoConstraints = false
        sampleFilterButton.bezelStyle = .push
        sampleFilterButton.controlSize = .small
        sampleFilterButton.font = .systemFont(ofSize: 11)
        sampleFilterButton.target = self
        sampleFilterButton.action = #selector(sampleFilterButtonClicked(_:))
        sampleFilterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        configureFilterField(taxonFilterField, placeholder: "Taxon", width: 180, numeric: false)
        configureFilterField(hitsFilterField, placeholder: "Min Hits", width: 70, numeric: true)
        configureFilterField(uniqueReadsFilterField, placeholder: "Min Unique", width: 82, numeric: true)
        configureFilterField(refsFilterField, placeholder: "Min Refs", width: 70, numeric: true)

        taxonomyFilterBar.addArrangedSubview(sampleFilterButton)
        taxonomyFilterBar.addArrangedSubview(taxonFilterField)
        taxonomyFilterBar.addArrangedSubview(hitsFilterField)
        taxonomyFilterBar.addArrangedSubview(uniqueReadsFilterField)
        taxonomyFilterBar.addArrangedSubview(refsFilterField)

        taxonomyTableScrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(taxonomyTableScrollView)

        NSLayoutConstraint.activate([
            taxonomyFilterBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            taxonomyFilterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            taxonomyFilterBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -6),

            taxonomyTableScrollView.topAnchor.constraint(equalTo: taxonomyFilterBar.bottomAnchor, constant: 6),
            taxonomyTableScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            taxonomyTableScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            taxonomyTableScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func configureFilterField(
        _ field: NSTextField,
        placeholder: String,
        width: CGFloat,
        numeric: Bool
    ) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.delegate = self
        field.target = self
        field.action = #selector(taxonomyFilterChanged(_:))
        if numeric {
            field.alignment = .right
        }
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @objc private func taxonomyFilterChanged(_ sender: Any?) {
        reloadTaxonomyTable()
    }

    // MARK: - Setup: Action Bar

    private func setupActionBar() {
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)
    }

    // MARK: - Layout

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            // Summary bar (top)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            // Action bar (bottom, fixed height)
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 36),

            // Split view (fills remaining space)
            splitView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let bottomConstraint = splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor)
        bottomConstraint.isActive = true
        splitViewBottomConstraint = bottomConstraint
    }

    private func applySplitPositionIfNeeded(force: Bool) {
        guard splitView.arrangedSubviews.count >= 2 else { return }
        guard splitView.bounds.width > 0 else {
            if force {
                didSetInitialSplitPosition = false
            }
            return
        }

        guard force || !didSetInitialSplitPosition else { return }

        // Detail pane on left gets 40%, taxonomy table on right gets 60%.
        let position = round(splitView.bounds.width * 0.4)
        splitView.setPosition(position, ofDividerAt: 0)
        didSetInitialSplitPosition = true
        resizeDetailContentToFit()
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        // Action bar Extract FASTQ -> present extraction sheet for selected taxa
        actionBar.onExtractFASTQ = { [weak self] in
            guard let self else { return }
            let selectedIndexes = self.taxonomyTableView.selectedRowIndexes
            let rows: [NaoMgsTaxonSummaryRow] = selectedIndexes.compactMap { index in
                guard index < self.displayedRows.count else { return nil }
                return self.displayedRows[index]
            }
            guard !rows.isEmpty else { return }

            let items = rows.map { "\($0.name) (taxid:\($0.taxId))" }
            let source = self.bundleURL?.lastPathComponent ?? "NAO-MGS result"
            let suggestedName = "\(rows.first?.sample ?? "sample")_\(rows.first?.name ?? "extract")_extract"
            self.presentExtractionSheet(items: items, source: source, suggestedName: suggestedName)
        }

        // Action bar BLAST verify (NAO-MGS triggers BLAST via context menu)
        actionBar.onBlastVerify = { [weak self] in
            // NAO-MGS BLAST is triggered via the table context menu per-taxon;
            // the action bar button is intentionally a no-op placeholder
        }

        // Action bar export
        actionBar.onExport = { [weak self] in
            self?.exportResults()
        }

        // Action bar provenance
        actionBar.onProvenance = { [weak self] sender in
            self?.showProvenance(from: sender)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutSwapRequested),
            name: .metagenomicsLayoutSwapRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInspectorSampleSelectionChanged),
            name: .metagenomicsSampleSelectionChanged,
            object: nil
        )
    }

    // MARK: - Extraction Sheet

    /// Presents a ``ClassifierExtractionSheet`` for the given selected items.
    private func presentExtractionSheet(items: [String], source: String, suggestedName: String) {
        guard let window = view.window else { return }

        // Collect tax IDs from the currently selected rows for database extraction.
        let selectedIndexes = taxonomyTableView.selectedRowIndexes
        let selectedRows: [NaoMgsTaxonSummaryRow] = selectedIndexes.compactMap { index in
            guard index < displayedRows.count else { return nil }
            return displayedRows[index]
        }
        let taxIds = Set(selectedRows.map(\.taxId))
        let capturedDatabaseURL = database?.databaseURL
        let capturedSampleId = selectedRows.first?.sample
        // Derive project URL: bundleURL is the NAO-MGS result bundle directory.
        // Navigate up to the project: bundle.lungfishfastq/derivatives/naomgs-* -> project
        let capturedProjectURL = bundleURL?
            .deletingLastPathComponent()  // derivatives/ or bundle root
            .deletingLastPathComponent()  // bundle.lungfishfastq/
            .deletingLastPathComponent()  // project/

        let sheet = ClassifierExtractionSheet(
            selectedItems: items,
            sourceDescription: source,
            suggestedName: suggestedName,
            onExtract: { [weak window] outputName in
                guard let window else { return }
                if let attached = window.attachedSheet { window.endSheet(attached) }

                guard let databaseURL = capturedDatabaseURL else {
                    let alert = NSAlert()
                    alert.messageText = "Database Not Available"
                    alert.informativeText = "NAO-MGS database is not available for read extraction."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.beginSheetModal(for: window)
                    return
                }

                let opID = OperationCenter.shared.start(
                    title: "Extract \(outputName)",
                    detail: "Extracting reads from NAO-MGS database\u{2026}",
                    operationType: .taxonomyExtraction,
                    cliCommand: "# database extraction via ReadExtractionService"
                )

                let task = Task.detached {
                    do {
                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent("naomgs-extract-\(UUID().uuidString)")

                        let config = DatabaseExtractionConfig(
                            databaseURL: databaseURL,
                            sampleId: capturedSampleId,
                            taxIds: taxIds,
                            outputDirectory: tempDir,
                            outputBaseName: outputName
                        )
                        let service = ReadExtractionService()
                        let result = try await service.extractFromDatabase(
                            config: config,
                            progress: { fraction, message in
                                DispatchQueue.main.async {
                                    MainActor.assumeIsolated {
                                        OperationCenter.shared.update(id: opID, progress: fraction * 0.8, detail: message)
                                    }
                                }
                            }
                        )

                        let metadata = ExtractionMetadata(
                            sourceDescription: databaseURL.deletingPathExtension().lastPathComponent,
                            toolName: "NAO-MGS",
                            parameters: ["taxIds": taxIds.sorted().map(String.init).joined(separator: ",")]
                        )
                        let bundleDir = capturedProjectURL ?? tempDir
                        let bundleURL = try await service.createBundle(from: result, metadata: metadata, in: bundleDir)

                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.complete(id: opID, detail: "Created \(bundleURL.lastPathComponent)")
                                if let appDelegate = NSApp.delegate as? AppDelegate {
                                    if let sidebar = appDelegate.mainWindowController?.mainSplitViewController?.sidebarController {
                                        sidebar.reloadFromFilesystem()
                                    }
                                }
                            }
                        }
                    } catch {
                        let errorDesc = error.localizedDescription
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.fail(id: opID, detail: errorDesc)
                            }
                        }
                    }
                }
                OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }
            },
            onCancel: { [weak window] in
                guard let window else { return }
                if let attached = window.attachedSheet { window.endSheet(attached) }
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = NSHostingController(rootView: sheet)
        window.beginSheet(panel)
    }

    @objc private func handleLayoutSwapRequested(_ notification: Notification) {
        applyLayoutPreference()
    }

    @objc private func handleInspectorSampleSelectionChanged(_ notification: Notification) {
        let newSelection = samplePickerState.selectedSamples
        guard newSelection != selectedSamples else { return }
        selectedSamples = newSelection
        updateSampleFilterButtonTitle()
        updateSampleColumnVisibility()
        updateMetadataColumnsForCurrentSamples()
        reloadTaxonomyTable()
        if let database, let manifest {
            summaryBar.update(database: database, manifest: manifest, selectedSamples: Array(newSelection))
        }
    }

    /// Swaps the split view pane order based on the persisted layout preference.
    private func applyLayoutPreference() {
        let tableOnLeft = UserDefaults.standard.bool(forKey: "metagenomicsTableOnLeft")
        guard splitView.arrangedSubviews.count == 2,
              let detail = detailContainer,
              let table = tableContainer else { return }

        let currentTableIsFirst = (splitView.arrangedSubviews[0] === table)
        guard tableOnLeft != currentTableIsFirst else { return }  // Already correct

        // Preserve split ratio
        let totalWidth = max(splitView.bounds.width, 1)
        let leftRatio = splitView.arrangedSubviews[0].frame.width / totalWidth

        splitView.removeArrangedSubview(detail)
        splitView.removeArrangedSubview(table)
        detail.removeFromSuperview()
        table.removeFromSuperview()

        if tableOnLeft {
            splitView.addArrangedSubview(table)
            splitView.addArrangedSubview(detail)
        } else {
            splitView.addArrangedSubview(detail)
            splitView.addArrangedSubview(table)
        }

        // Table always gets low holding priority (resizes first on window resize)
        let tableIndex = tableOnLeft ? 0 : 1
        let detailIndex = tableOnLeft ? 1 : 0
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: tableIndex)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: detailIndex)

        // Apply inverse ratio to maintain visual proportion
        let newPosition = round(totalWidth * (1.0 - leftRatio))
        splitView.setPosition(newPosition, ofDividerAt: 0)
        splitView.adjustSubviews()
    }

    // MARK: - BLAST Drawer

    public func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        let drawer = ensureBlastDrawer()
        drawer.showLoading(phase: phase, requestId: requestId)
        openBlastDrawerIfNeeded()
    }

    public func showBlastResults(_ result: BlastVerificationResult) {
        let drawer = ensureBlastDrawer()
        drawer.showResults(result)
        openBlastDrawerIfNeeded()
    }

    public func showBlastFailure(_ message: String) {
        let drawer = ensureBlastDrawer()
        drawer.showFailure(message: message)
        openBlastDrawerIfNeeded()
    }

    private func ensureBlastDrawer() -> BlastResultsDrawerTab {
        if let blastDrawerView {
            return blastDrawerView
        }

        let drawer = BlastResultsDrawerTab()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawer)

        let bottomConstraint = drawer.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: 220)

        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawer.heightAnchor.constraint(equalToConstant: 220),
            bottomConstraint,
        ])

        splitViewBottomConstraint?.isActive = false
        let newSplitBottom = splitView.bottomAnchor.constraint(equalTo: drawer.topAnchor)
        newSplitBottom.isActive = true
        splitViewBottomConstraint = newSplitBottom

        blastDrawerView = drawer
        blastDrawerBottomConstraint = bottomConstraint
        view.layoutSubtreeIfNeeded()

        return drawer
    }

    private func openBlastDrawerIfNeeded() {
        guard !isBlastDrawerOpen else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            blastDrawerBottomConstraint?.animator().constant = 0
            view.layoutSubtreeIfNeeded()
        }
        isBlastDrawerOpen = true
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Taxon Actions")
        menu.delegate = self
        return menu
    }

    private func populateContextMenu(_ menu: NSMenu, for row: NaoMgsTaxonSummaryRow) {
        menu.removeAllItems()

        // BLAST verification items (single selection only)
        if database != nil, onBlastVerification != nil,
           taxonomyTableView.selectedRowIndexes.count <= 1 {
            let uniqueCount = row.uniqueReadCount
            if uniqueCount > 0 {
                // Smart BLAST count options
                let blastCounts: [(label: String, count: Int)]
                if uniqueCount <= 20 {
                    blastCounts = [("BLAST All \(uniqueCount) Reads", uniqueCount)]
                } else if uniqueCount <= 50 {
                    blastCounts = [
                        ("BLAST 20 Reads", 20),
                        ("BLAST All \(uniqueCount) Reads", uniqueCount),
                    ]
                } else {
                    blastCounts = [
                        ("BLAST 20 Reads", 20),
                        ("BLAST 50 Reads", 50),
                    ]
                }
                for (label, count) in blastCounts {
                    let item = NSMenuItem(title: label, action: #selector(contextBlastVerify(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = BlastMenuSelection(row: row, readCount: count)
                    menu.addItem(item)
                }
                menu.addItem(NSMenuItem.separator())
            }
        }

        // Copy Taxon ID
        let copyTaxId = NSMenuItem(title: "Copy Taxon ID", action: #selector(contextCopyTaxonId(_:)), keyEquivalent: "")
        copyTaxId.target = self
        copyTaxId.representedObject = row.taxId
        menu.addItem(copyTaxId)

        // Copy accessions
        if !row.topAccessions.isEmpty {
            let copyAccessions = NSMenuItem(title: "Copy Top Accessions", action: #selector(contextCopyAccessions(_:)), keyEquivalent: "")
            copyAccessions.target = self
            copyAccessions.representedObject = row.topAccessions
            menu.addItem(copyAccessions)
        }

        // Copy unique reads as FASTQ
        if row.uniqueReadCount > 0 {
            let copyReads = NSMenuItem(
                title: "Copy Unique Reads as FASTQ (\(row.uniqueReadCount))",
                action: #selector(contextCopyUniqueReadsFASTQ(_:)),
                keyEquivalent: ""
            )
            copyReads.target = self
            copyReads.representedObject = row
            menu.addItem(copyReads)
        }

        menu.addItem(NSMenuItem.separator())

        // View on NCBI
        let viewNCBI = NSMenuItem(title: "View on NCBI", action: #selector(contextViewOnNCBI(_:)), keyEquivalent: "")
        viewNCBI.target = self
        viewNCBI.representedObject = row.taxId
        menu.addItem(viewNCBI)

        let viewTaxonomy = NSMenuItem(title: "View Taxonomy on NCBI", action: #selector(contextViewTaxonomyOnNCBI(_:)), keyEquivalent: "")
        viewTaxonomy.target = self
        viewTaxonomy.representedObject = row.taxId
        menu.addItem(viewTaxonomy)

        let searchPubMed = NSMenuItem(title: "Search PubMed", action: #selector(contextSearchPubMed(_:)), keyEquivalent: "")
        searchPubMed.target = self
        searchPubMed.representedObject = row.name
        menu.addItem(searchPubMed)
    }

    // MARK: - Context Menu Actions

    /// Selection data passed through the BLAST context menu item's representedObject.
    private struct BlastMenuSelection {
        let row: NaoMgsTaxonSummaryRow
        let readCount: Int
    }

    @objc private func contextBlastVerify(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? BlastMenuSelection,
              let database else { return }

        let row = selection.row
        let sample = row.sample

        do {
            // Fetch deduplicated virus hits from the database for BLAST
            let hits = try database.fetchVirusHitsForBLAST(
                sample: sample,
                taxId: row.taxId,
                maxReads: selection.readCount
            )
            guard !hits.isEmpty else {
                logger.warning("No reads found for BLAST: taxId=\(row.taxId), sample=\(sample)")
                return
            }

            // Build a NaoMgsTaxonSummary from the row data for the callback
            let summary = NaoMgsTaxonSummary(
                taxId: row.taxId,
                name: row.name,
                hitCount: row.hitCount,
                avgIdentity: row.avgIdentity,
                avgBitScore: row.avgBitScore,
                avgEditDistance: row.avgEditDistance,
                accessions: row.topAccessions
            )

            // Select reads using the coverage-stratified strategy
            let selectedHits = NaoMgsDataConverter.selectBlastReads(
                hits: hits,
                count: selection.readCount
            )

            onBlastVerification?(summary, selection.readCount, selectedHits)
        } catch {
            logger.error("Failed to fetch BLAST reads: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func contextCopyTaxonId(_ sender: NSMenuItem) {
        guard let taxId = sender.representedObject as? Int else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(taxId)", forType: .string)
    }

    @objc private func contextCopyAccessions(_ sender: NSMenuItem) {
        guard let accessions = sender.representedObject as? [String] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accessions.joined(separator: "\n"), forType: .string)
    }

    @objc private func contextCopyUniqueReadsFASTQ(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? NaoMgsTaxonSummaryRow,
              let database else { return }
        do {
            // Fetch deduplicated reads (same logic as BLAST verification)
            let hits = try database.fetchVirusHitsForBLAST(
                sample: row.sample,
                taxId: row.taxId,
                maxReads: row.uniqueReadCount
            )
            guard !hits.isEmpty else { return }

            // Format as FASTQ if quality data is available, otherwise FASTA
            var lines: [String] = []
            let hasFASTQ = hits.contains { !$0.readQuality.isEmpty && $0.readQuality != "*" }
            for hit in hits {
                if hasFASTQ {
                    lines.append("@\(hit.seqId)")
                    lines.append(hit.readSequence)
                    lines.append("+")
                    lines.append(hit.readQuality.isEmpty ? String(repeating: "I", count: hit.readSequence.count) : hit.readQuality)
                } else {
                    lines.append(">\(hit.seqId)")
                    lines.append(hit.readSequence)
                }
            }

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            logger.info("Copied \(hits.count) unique reads as \(hasFASTQ ? "FASTQ" : "FASTA") for taxId \(row.taxId)")
        } catch {
            logger.error("Failed to fetch reads for copy: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc func contextCopyAccession(_ sender: NSMenuItem) {
        guard let accession = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accession, forType: .string)
    }

    @objc func contextViewAccessionOnNCBI(_ sender: NSMenuItem) {
        guard let accession = sender.representedObject as? String else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(accession)")!
        NSWorkspace.shared.open(url)
    }

    /// Opens GenBank for an accession button click (extracts accession from button title).
    @objc private func openGenBankFromButton(_ sender: Any) {
        let accession: String?
        if let button = sender as? NSButton {
            accession = button.title
        } else if let menuItem = sender as? NSMenuItem {
            accession = menuItem.representedObject as? String
        } else {
            accession = nil
        }
        guard let accession, !accession.isEmpty else { return }
        if let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(accession)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextViewOnNCBI(_ sender: NSMenuItem) {
        guard let taxId = sender.representedObject as? Int else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/?term=txid\(taxId)[Organism:exp]")!
        NSWorkspace.shared.open(url)
    }

    @objc private func contextViewTaxonomyOnNCBI(_ sender: NSMenuItem) {
        guard let taxId = sender.representedObject as? Int else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/\(taxId)/")!
        NSWorkspace.shared.open(url)
    }

    @objc private func contextSearchPubMed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(encodedName)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - NSSplitViewDelegate

    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, 250)
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 300)
    }

    // MARK: - Multi-Selection Helpers

    private func showMultiSelectionPlaceholder(count: Int) {
        miniBAMLoadingTask?.cancel()
        miniBAMLoadingTask = nil
        selectedRow = nil
        selectedAccession = nil

        if let stack = multiSelectionPlaceholder.subviews.first as? NSStackView,
           let primary = stack.arrangedSubviews.first as? NSTextField {
            primary.stringValue = "\(count) items selected"
        }
        detailScrollView.isHidden = true
        multiSelectionPlaceholder.isHidden = false
        actionBar.updateInfoText("\(count) items selected")
        actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
        actionBar.setExtractEnabled(true)
    }

    private func hideMultiSelectionPlaceholder() {
        multiSelectionPlaceholder.isHidden = true
        detailScrollView.isHidden = false
    }

    // MARK: - Action Bar Selection Helper

    /// Updates the unified action bar info text from a taxon row.
    private func updateActionBarForRow(_ row: NaoMgsTaxonSummaryRow, totalHits: Int) {
        naoMgsTotalHits = totalHits
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let readStr = formatter.string(from: NSNumber(value: row.hitCount)) ?? "\(row.hitCount)"

        let pct = totalHits > 0
            ? Double(row.hitCount) / Double(totalHits) * 100
            : 0
        let pctStr = String(format: "%.1f%%", pct)

        let displayName = row.name.isEmpty ? "Taxid \(row.taxId)" : row.name
        actionBar.updateInfoText("\(displayName) \u{2014} \(readStr) hits (\(pctStr))")
        actionBar.setBlastEnabled(true)
    }

    // MARK: - Provenance Popover

    private func showProvenance(from button: NSButton) {
        guard let manifest else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 220)
        popover.contentViewController = NSHostingController(rootView: NaoMgsProvenanceView(manifest: manifest))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    // MARK: - Metadata Column Updates

    /// Updates metadata columns for the current sample selection.
    private func updateMetadataColumnsForCurrentSamples() {
        let isMulti = selectedSamples.count > 1
        let sampleId: String?
        if selectedSamples.count == 1 {
            sampleId = selectedSamples.first
        } else {
            sampleId = nil
        }
        metadataColumnController.isMultiSampleMode = isMulti
        metadataColumnController.update(store: sampleMetadataStore, sampleId: sampleId)
    }

    // MARK: - Export

    public func exportResults() {
        guard database != nil, let window = view.window else { return }
        let sampleName = manifest?.sampleName ?? "naomgs"

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.tabSeparatedText]
        savePanel.nameFieldStringValue = "\(sampleName)_naomgs_summary.tsv"
        savePanel.title = "Export NAO-MGS Summary"

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }

            var lines: [String] = []
            var header = "sample\ttaxon_id\tname\thit_count\tunique_read_count\tpcr_duplicate_count\tavg_identity\tavg_bit_score\tavg_edit_distance\taccession_count"
            // Append visible metadata column headers
            let metaHeaders = self.metadataColumnController.exportHeaders
            if !metaHeaders.isEmpty {
                header += "\t" + metaHeaders.joined(separator: "\t")
            }
            lines.append(header)

            for row in self.displayedRows {
                var line = "\(row.sample)\t\(row.taxId)\t\(row.name)\t\(row.hitCount)\t\(row.uniqueReadCount)\t\(row.pcrDuplicateCount)\t\(String(format: "%.2f", row.avgIdentity))\t\(String(format: "%.1f", row.avgBitScore))\t\(String(format: "%.1f", row.avgEditDistance))\t\(row.accessionCount)"
                // Append metadata values for this row's sample
                let metaValues = self.metadataColumnController.exportValues(for: row.sample)
                if !metaValues.isEmpty {
                    line += "\t" + metaValues.joined(separator: "\t")
                }
                lines.append(line)
            }

            let content = lines.joined(separator: "\n") + "\n"
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.info("Exported NAO-MGS summary to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Failed to export NAO-MGS summary: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Filter Helpers

    private func parseMinFilter(_ rawValue: String) -> Int? {
        let trimmed = rawValue
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasSuffix("k"), let value = Double(lower.dropLast()) {
            return Int(value * 1_000)
        }
        if lower.hasSuffix("m"), let value = Double(lower.dropLast()) {
            return Int(value * 1_000_000)
        }
        return Int(lower)
    }
}

// MARK: - FlippedNaoMgsContentView

/// Flipped container so Auto Layout `topAnchor` maps to visual top.
private final class FlippedNaoMgsContentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - NaoMgsDetailContainer

/// A self-contained detail pane container that manages a scroll view filling its bounds.
///
/// This is added directly as an NSSplitView arranged subview. NSSplitView
/// manages its frame via frame-based layout. The container fills itself
/// with the scroll view using autoresizing masks.
private final class NaoMgsDetailContainer: NSView {

    let scrollView: NSScrollView
    let contentView: FlippedNaoMgsContentView

    init(scrollView: NSScrollView, contentView: FlippedNaoMgsContentView) {
        self.scrollView = scrollView
        self.contentView = contentView
        super.init(frame: .zero)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = contentView
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scrollView.frame = bounds
    }
}

// MARK: - NSTableViewDataSource

extension NaoMgsResultViewController: NSTableViewDataSource {

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        reloadTaxonomyTable()
    }
}

// MARK: - NSTableViewDelegate

extension NaoMgsResultViewController: NSTableViewDelegate {

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < displayedRows.count, let tableColumn else { return nil }

        // Check for dynamic metadata columns first
        if let cell = metadataColumnController.cellForColumn(tableColumn) {
            return cell
        }

        let summaryRow = displayedRows[row]
        let identifier = tableColumn.identifier

        let cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: identifier)

        switch identifier.rawValue {
        case "sample":
            cellView.textField?.stringValue = summaryRow.sample
            cellView.textField?.font = .systemFont(ofSize: 11)
            cellView.textField?.lineBreakMode = .byTruncatingTail
            cellView.textField?.alignment = .left
        case "name":
            cellView.textField?.stringValue = summaryRow.name.isEmpty ? "Taxid \(summaryRow.taxId)" : summaryRow.name
            cellView.textField?.font = .systemFont(ofSize: 11)
            cellView.textField?.lineBreakMode = .byTruncatingTail
            cellView.textField?.alignment = .left
        case "hits":
            cellView.textField?.stringValue = naoMgsFormatCount(summaryRow.hitCount)
            cellView.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            cellView.textField?.alignment = .right
        case "unique":
            cellView.textField?.stringValue = naoMgsFormatCount(summaryRow.uniqueReadCount)
            cellView.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cellView.textField?.alignment = .right
        case "refs":
            cellView.textField?.stringValue = "\(summaryRow.accessionCount)"
            cellView.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cellView.textField?.alignment = .right
        default:
            cellView.textField?.stringValue = ""
        }

        return cellView
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSync else { return }

        let selectedIndexes = taxonomyTableView.selectedRowIndexes
        if selectedIndexes.count > 1 {
            showMultiSelectionPlaceholder(count: selectedIndexes.count)
        } else if selectedIndexes.count == 1, let row = selectedIndexes.first, row < displayedRows.count {
            showTaxonDetail(displayedRows[row])
        } else {
            showOverview()
        }
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.truncatesLastVisibleLine = true
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

/// Formats a count with K/M suffixes for the taxonomy table.
private func naoMgsFormatCount(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return "\(count)"
}

// MARK: - NSMenuDelegate

extension NaoMgsResultViewController: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = taxonomyTableView.clickedRow

        guard clickedRow >= 0, clickedRow < displayedRows.count else {
            menu.removeAllItems()
            return
        }

        populateContextMenu(menu, for: displayedRows[clickedRow])
    }
}

extension NaoMgsResultViewController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        // Debounce filter changes to avoid excessive database queries on every keystroke.
        filterDebounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.reloadTaxonomyTable()
                }
            }
        }
        filterDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }
}

// MARK: - NaoMgsSummaryBar

@MainActor
final class NaoMgsSummaryBar: GenomicSummaryCardBar {

    private var samplesLabel: String = ""
    private var taxaLabel: String = ""

    func update(database: NaoMgsDatabase?, manifest: NaoMgsManifest?, selectedSamples: [String]) {
        guard let database else { return }

        let allSampleCount = (try? database.fetchSamples().count) ?? 0
        let selectedCount = selectedSamples.count
        if selectedCount == allSampleCount {
            samplesLabel = allSampleCount == 1 ? "1 sample" : "\(allSampleCount) samples"
        } else {
            samplesLabel = "\(selectedCount) of \(allSampleCount) samples"
        }

        let rows = (try? database.fetchTaxonSummaryRows(samples: selectedSamples)) ?? []
        taxaLabel = rows.count == 1 ? "1 taxon" : "\(rows.count) taxa"

        needsDisplay = true
    }

    /// Legacy update method kept for compatibility.
    func update(result: NaoMgsResult) {
        samplesLabel = "1 sample"
        taxaLabel = result.taxonSummaries.count == 1 ? "1 taxon" : "\(result.taxonSummaries.count) taxa"
        needsDisplay = true
    }

    override var cards: [Card] {
        [
            Card(label: "Samples", value: samplesLabel),
            Card(label: "Taxa", value: taxaLabel),
        ]
    }
}

// MARK: - AccessionDataWrapper

/// Lightweight data source for the accession table in the detail pane.
///
/// Stored as an associated object on the container view to keep it alive.
nonisolated(unsafe) private var accessionDataKey: UInt8 = 0

@MainActor
private final class AccessionDataWrapper: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let summaries: [DBAccessionSummary]
    var selectedAccession: String?
    var onSelect: ((String) -> Void)?
    var contextMenu: NSMenu?
    var populateMenu: ((NSMenu, String) -> Void)?

    init(summaries: [DBAccessionSummary], selected: String?) {
        self.summaries = summaries
        self.selectedAccession = selected
        super.init()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        summaries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < summaries.count else { return nil }
        let summary = summaries[row]

        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("accRow"), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = NSUserInterfaceItemIdentifier("accRow")
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        let coveredBP = NumberFormatter.localizedString(from: NSNumber(value: summary.coveredBasePairs), number: .decimal)
        let coveragePct = String(format: "%.0f%%", summary.coverageFraction * 100)
        cell.textField?.stringValue = "\(summary.accession)  \(naoMgsFormatCount(summary.readCount)) reads  \(coveredBP) bp (\(coveragePct))"
        cell.textField?.font = .monospacedSystemFont(ofSize: 10, weight: .regular)

        if summary.accession == selectedAccession {
            cell.textField?.textColor = .controlAccentColor
        } else {
            cell.textField?.textColor = .labelColor
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < summaries.count else { return }
        let accession = summaries[row].accession
        selectedAccession = accession
        onSelect?(accession)
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        []
    }
}
