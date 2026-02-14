// AnnotationTableDrawerView.swift - Geneious-style bottom annotation drawer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation drawer operations
private let drawerLogger = Logger(subsystem: "com.lungfish.browser", category: "AnnotationDrawer")

// MARK: - AnnotationTableDrawerDelegate

/// Delegate protocol for annotation table selection events.
@MainActor
protocol AnnotationTableDrawerDelegate: AnyObject {
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int)
}

private extension String {
    func value(after prefix: String) -> String? {
        guard lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

// MARK: - AnnotationTableDrawerView

/// A bottom drawer panel that displays a sortable, filterable table of annotations.
///
/// Modeled after Geneious's annotation table panel. Shows all annotations loaded from
/// the search index with columns for Name, Type, Chromosome, Start, End, and Size.
/// Supports filtering by name (text field) and type (chip toggle buttons).
@MainActor
public class AnnotationTableDrawerView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    // MARK: - Types

    /// The active tab in the drawer.
    enum DrawerTab: Int {
        case annotations = 0
        case variants = 1
        case samples = 2
    }

    /// A single row in the samples tab display.
    struct SampleDisplayRow {
        let name: String
        let sourceFile: String
        var isVisible: Bool
        var metadata: [String: String]
    }

    // MARK: - Properties

    weak var delegate: AnnotationTableDrawerDelegate?

    /// Reference to the search index for direct SQL queries.
    private var searchIndex: AnnotationSearchIndex?

    /// The currently active tab.
    private(set) var activeTab: DrawerTab = .annotations

    /// Total annotation count in the database (annotation tab only).
    private var totalAnnotationCount: Int = 0

    /// Total variant count in the database (variant tab only).
    private var totalVariantCount: Int = 0

    /// Filtered and displayed annotations/variants.
    private(set) var displayedAnnotations: [AnnotationSearchIndex.SearchResult] = []

    /// Per-tab filter text so each tab preserves its own search state.
    private var annotationFilterText: String = ""
    private var variantFilterText: String = ""
    private var sampleFilterText: String = ""

    /// Visible types for the annotation tab (empty means show all).
    private var visibleAnnotationTypes: Set<String> = []

    /// Visible types for the variant tab (empty means show all).
    private var visibleVariantTypes: Set<String> = []

    /// Convenience accessor for the active tab's visible types.
    private var visibleTypes: Set<String> {
        get {
            switch activeTab {
            case .annotations: return visibleAnnotationTypes
            case .variants: return visibleVariantTypes
            case .samples: return []
            }
        }
        set {
            switch activeTab {
            case .annotations: visibleAnnotationTypes = newValue
            case .variants: visibleVariantTypes = newValue
            case .samples: break
            }
        }
    }

    /// All distinct annotation types found in the data.
    private var availableAnnotationTypes: [String] = []

    /// All distinct variant types found in the data.
    private var availableVariantTypes: [String] = []

    /// Convenience accessor for the active tab's available types.
    private var availableTypes: [String] {
        switch activeTab {
        case .annotations: return availableAnnotationTypes
        case .variants: return availableVariantTypes
        case .samples: return []
        }
    }

    /// Whether the index is currently loading.
    private(set) var isLoading: Bool = true {
        didSet { updateLoadingState() }
    }

    /// Guard flag to prevent notification re-entry when programmatically selecting rows.
    private var isSuppressingDelegateCallbacks = false

    /// INFO field definitions for dynamic variant columns (key + type for sort awareness).
    private var infoColumnKeys: [(key: String, type: String, description: String)] = []

    /// Whether to auto-sync variant table with viewport (when variants tab is active).
    private(set) var viewportSyncEnabled: Bool = true

    /// Current viewport region for auto-sync (set by viewer notification).
    private var viewportRegion: (chromosome: String, start: Int, end: Int)?

    /// Debounce work item for viewport sync to avoid thrashing during rapid panning.
    private var viewportSyncWorkItem: DispatchWorkItem?

    /// Optional source object to scope viewport sync notifications to a single viewer.
    private weak var viewportSyncSourceObject: AnyObject?

    /// Stable source identifier for viewport sync scoping (survives weak-reference timing races).
    private var viewportSyncSourceIdentifier: ObjectIdentifier?

    // MARK: - Annotation→Variant Cross-Reference

    /// Bounding region from current annotation search results (union of all annotation regions on the same chromosome).
    private var annotationSearchRegion: (chromosome: String, start: Int, end: Int)?

    /// Specific annotation region selected by the user (e.g., via "Show Overlapping Variants").
    private var selectedAnnotationRegion: (chromosome: String, start: Int, end: Int)?

    // MARK: - Sample Tab State

    /// All sample names from variant databases.
    private var allSampleNames: [String] = []

    /// Per-sample metadata dictionaries.
    private var sampleMetadata: [String: [String: String]] = [:]

    /// Source file/track per sample.
    private var sampleSourceFiles: [String: String] = [:]

    /// Available metadata field names (union of all sample metadata keys).
    private var sampleMetadataFields: [String] = []

    /// Filtered and displayed samples for the samples tab.
    private var displayedSamples: [SampleDisplayRow] = []

    /// Local copy of sample display state for driving visibility toggles.
    private var currentSampleDisplayState: SampleDisplayState = SampleDisplayState()

    /// Whether we have received an authoritative sample display state from viewer/inspector.
    private var hasSampleDisplayStateSeed = false

    /// Scope of the last variant query, for status label display.
    private enum VariantQueryScope {
        case global
        case viewport
        case annotations
        case annotation
        case placeholder
    }

    /// Last variant query match count used for status labeling (especially capped result sets).
    private var lastVariantQueryMatchCount: Int?

    /// Last variant query scope for status labeling.
    private var lastVariantQueryScope: VariantQueryScope = .global

    // MARK: - UI Components

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let annotationFilterField = NSSearchField()
    private let variantFilterField = NSSearchField()
    private let sampleFilterField = NSSearchField()
    private let addSampleFieldButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let headerBar = NSView()
    private let searchBar = NSView()
    private let searchHintLabel = NSTextField(labelWithString: "")
    private let chipBar = NSView()
    private let chipScrollView = NSScrollView()
    private let chipStackView = NSStackView()
    private let dragHandle = NSView()
    private let tabControl = NSSegmentedControl()
    private let loadingIndicator = NSProgressIndicator()
    private let tooManyLabel = NSTextField(wrappingLabelWithString: "")
    private let allTypesButton = NSButton()
    private let noneTypesButton = NSButton()
    private let downloadTemplateButton = NSButton()

    /// Maximum number of annotations to display in the table.
    /// Beyond this, user must filter to narrow down results.
    private static let maxDisplayCount = 5_000

    /// Chip buttons keyed by type name.
    private var chipButtons: [String: NSButton] = [:]

    // Annotation column identifiers
    private static let nameColumn = NSUserInterfaceItemIdentifier("NameColumn")
    private static let typeColumn = NSUserInterfaceItemIdentifier("TypeColumn")
    private static let chromosomeColumn = NSUserInterfaceItemIdentifier("ChromosomeColumn")
    private static let startColumn = NSUserInterfaceItemIdentifier("StartColumn")
    private static let endColumn = NSUserInterfaceItemIdentifier("EndColumn")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("SizeColumn")
    private static let strandColumn = NSUserInterfaceItemIdentifier("StrandColumn")

    // Variant column identifiers
    private static let variantIdColumn = NSUserInterfaceItemIdentifier("VariantIdColumn")
    private static let variantTypeColumn = NSUserInterfaceItemIdentifier("VariantTypeColumn")
    private static let variantChromColumn = NSUserInterfaceItemIdentifier("VariantChromColumn")
    private static let positionColumn = NSUserInterfaceItemIdentifier("PositionColumn")
    private static let refColumn = NSUserInterfaceItemIdentifier("RefColumn")
    private static let altColumn = NSUserInterfaceItemIdentifier("AltColumn")
    private static let qualityColumn = NSUserInterfaceItemIdentifier("QualityColumn")
    private static let filterColumn = NSUserInterfaceItemIdentifier("FilterColumn")
    private static let samplesColumn = NSUserInterfaceItemIdentifier("SamplesColumn")
    private static let sourceColumn = NSUserInterfaceItemIdentifier("SourceColumn")

    // Sample column identifiers
    private static let sampleVisibleColumn = NSUserInterfaceItemIdentifier("SampleVisibleColumn")
    private static let sampleNameColumn = NSUserInterfaceItemIdentifier("SampleNameColumn")
    private static let sampleSourceColumn = NSUserInterfaceItemIdentifier("SampleSourceColumn")

    /// Number formatter for genomic coordinates.
    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    // MARK: - Setup

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Drag handle bar at top (visual divider)
        dragHandle.wantsLayer = true
        dragHandle.layer?.backgroundColor = NSColor.separatorColor.cgColor
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragHandle)

        // Header bar with tab controls (row 1)
        headerBar.wantsLayer = true
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        // Search bar with tab-specific filter + advanced hint (row 2)
        searchBar.wantsLayer = true
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchBar)

        // Filter search fields (tab-specific, only one visible at a time)
        configureSearchField(
            annotationFilterField,
            placeholder: "Annotations: name, type:, chr:, strand:, region:chr:start-end",
            accessibilityLabel: "Filter annotations"
        )
        configureSearchField(
            variantFilterField,
            placeholder: "Variants: ID text + DP>20 AF>=0.05 chr: pos:100-200 qual>=30 sc>=2",
            accessibilityLabel: "Filter variants"
        )
        configureSearchField(
            sampleFilterField,
            placeholder: "Samples: name:, source:, visible:true/false, meta.FIELD:value",
            accessibilityLabel: "Filter samples"
        )
        searchBar.addSubview(annotationFilterField)
        searchBar.addSubview(variantFilterField)
        searchBar.addSubview(sampleFilterField)

        // "All"/"None" convenience buttons for annotation/variant type chips
        allTypesButton.title = "All"
        allTypesButton.font = .systemFont(ofSize: 10, weight: .medium)
        allTypesButton.controlSize = .small
        allTypesButton.bezelStyle = .recessed
        allTypesButton.target = self
        allTypesButton.action = #selector(selectAllTypes(_:))
        allTypesButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(allTypesButton)

        noneTypesButton.title = "None"
        noneTypesButton.font = .systemFont(ofSize: 10, weight: .medium)
        noneTypesButton.controlSize = .small
        noneTypesButton.bezelStyle = .recessed
        noneTypesButton.target = self
        noneTypesButton.action = #selector(selectNoTypes(_:))
        noneTypesButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(noneTypesButton)

        // Samples-tab convenience button for adding editable metadata fields.
        addSampleFieldButton.title = "Add Field"
        addSampleFieldButton.controlSize = .small
        addSampleFieldButton.bezelStyle = .rounded
        addSampleFieldButton.font = .systemFont(ofSize: 10, weight: .medium)
        addSampleFieldButton.translatesAutoresizingMaskIntoConstraints = false
        addSampleFieldButton.target = self
        addSampleFieldButton.action = #selector(addCustomFieldAction(_:))
        addSampleFieldButton.isHidden = true
        searchBar.addSubview(addSampleFieldButton)

        downloadTemplateButton.title = "Template TSV/CSV"
        downloadTemplateButton.controlSize = .small
        downloadTemplateButton.bezelStyle = .rounded
        downloadTemplateButton.font = .systemFont(ofSize: 10, weight: .medium)
        downloadTemplateButton.translatesAutoresizingMaskIntoConstraints = false
        downloadTemplateButton.target = self
        downloadTemplateButton.action = #selector(downloadSampleTemplateAction(_:))
        downloadTemplateButton.isHidden = true
        searchBar.addSubview(downloadTemplateButton)

        // Tab segmented control (Annotations | Variants | Samples)
        tabControl.segmentCount = 3
        tabControl.setLabel("Annotations", forSegment: 0)
        tabControl.setLabel("Variants", forSegment: 1)
        tabControl.setLabel("Samples", forSegment: 2)
        tabControl.selectedSegment = 0
        tabControl.segmentStyle = .texturedRounded
        tabControl.controlSize = .small
        tabControl.font = .systemFont(ofSize: 10, weight: .medium)
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.setAccessibilityLabel("Switch between annotations and variants")
        headerBar.addSubview(tabControl)

        // Count label
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        headerBar.addSubview(countLabel)

        // Loading indicator
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.startAnimation(nil)
        headerBar.addSubview(loadingIndicator)

        searchHintLabel.font = .systemFont(ofSize: 10)
        searchHintLabel.textColor = .secondaryLabelColor
        searchHintLabel.lineBreakMode = .byTruncatingTail
        searchHintLabel.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(searchHintLabel)

        // Chip bar (row 2) — horizontal scrolling row of type toggle chips
        chipBar.wantsLayer = true
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipBar)

        chipScrollView.translatesAutoresizingMaskIntoConstraints = false
        chipScrollView.hasHorizontalScroller = false
        chipScrollView.hasVerticalScroller = false
        chipScrollView.drawsBackground = false
        chipBar.addSubview(chipScrollView)

        chipStackView.orientation = .horizontal
        chipStackView.spacing = 4
        chipStackView.alignment = .centerY
        chipStackView.translatesAutoresizingMaskIntoConstraints = false
        chipScrollView.documentView = chipStackView

        // Configure initial table columns (annotation mode)
        configureColumnsForTab(.annotations)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.style = .plain
        tableView.gridStyleMask = .solidVerticalGridLineMask
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))
        tableView.registerForDraggedTypes([.string])

        // Context menu (built dynamically via NSMenuDelegate)
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // "Too many results" overlay label
        tooManyLabel.alignment = .center
        tooManyLabel.font = .systemFont(ofSize: 12)
        tooManyLabel.textColor = .secondaryLabelColor
        tooManyLabel.isHidden = true
        tooManyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tooManyLabel)

        // Layout
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: topAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: 1),

            headerBar.topAnchor.constraint(equalTo: dragHandle.bottomAnchor),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 28),

            loadingIndicator.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            loadingIndicator.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 8),

            tabControl.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            tabControl.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -8),

            countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),

            searchBar.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 50),

            annotationFilterField.topAnchor.constraint(equalTo: searchBar.topAnchor, constant: 4),
            annotationFilterField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            annotationFilterField.heightAnchor.constraint(equalToConstant: 24),
            annotationFilterField.trailingAnchor.constraint(lessThanOrEqualTo: allTypesButton.leadingAnchor, constant: -8),

            variantFilterField.topAnchor.constraint(equalTo: searchBar.topAnchor, constant: 4),
            variantFilterField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            variantFilterField.heightAnchor.constraint(equalToConstant: 24),
            variantFilterField.trailingAnchor.constraint(lessThanOrEqualTo: allTypesButton.leadingAnchor, constant: -8),

            sampleFilterField.topAnchor.constraint(equalTo: searchBar.topAnchor, constant: 4),
            sampleFilterField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            sampleFilterField.heightAnchor.constraint(equalToConstant: 24),
            sampleFilterField.trailingAnchor.constraint(lessThanOrEqualTo: addSampleFieldButton.leadingAnchor, constant: -8),

            allTypesButton.topAnchor.constraint(equalTo: searchBar.topAnchor, constant: 4),
            allTypesButton.trailingAnchor.constraint(equalTo: noneTypesButton.leadingAnchor, constant: -4),

            noneTypesButton.centerYAnchor.constraint(equalTo: allTypesButton.centerYAnchor),
            noneTypesButton.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),

            addSampleFieldButton.topAnchor.constraint(equalTo: searchBar.topAnchor, constant: 4),
            addSampleFieldButton.trailingAnchor.constraint(equalTo: downloadTemplateButton.leadingAnchor, constant: -6),

            downloadTemplateButton.centerYAnchor.constraint(equalTo: addSampleFieldButton.centerYAnchor),
            downloadTemplateButton.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),

            searchHintLabel.topAnchor.constraint(equalTo: annotationFilterField.bottomAnchor, constant: 4),
            searchHintLabel.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 10),
            searchHintLabel.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -10),

            chipBar.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            chipBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: 26),

            chipScrollView.topAnchor.constraint(equalTo: chipBar.topAnchor),
            chipScrollView.leadingAnchor.constraint(equalTo: chipBar.leadingAnchor, constant: 8),
            chipScrollView.trailingAnchor.constraint(equalTo: chipBar.trailingAnchor, constant: -8),
            chipScrollView.bottomAnchor.constraint(equalTo: chipBar.bottomAnchor),

            chipStackView.topAnchor.constraint(equalTo: chipScrollView.topAnchor),
            chipStackView.leadingAnchor.constraint(equalTo: chipScrollView.leadingAnchor),
            chipStackView.bottomAnchor.constraint(equalTo: chipScrollView.bottomAnchor),
            // No trailing constraint — let stack view expand beyond scroll view for horizontal scrolling

            scrollView.topAnchor.constraint(equalTo: chipBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tooManyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            tooManyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            tooManyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            tooManyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
        ])

        // Hide chip bar initially (shown after data loads)
        chipBar.isHidden = true
        updateSearchFieldVisibility()

        // Accessibility
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Annotation table drawer")
        setAccessibilityIdentifier("annotation-table-drawer")

        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityRole(.table)
        tableView.setAccessibilityLabel("Annotation table")

        updateCountLabel()

        // Observe variant selection from the viewer
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleVariantSelected(_:)),
            name: .variantSelected, object: nil
        )

        // Observe viewport variant updates for auto-sync
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleViewportVariantsUpdated(_:)),
            name: .viewportVariantsUpdated, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleViewerCoordinatesChanged(_:)),
            name: .viewerCoordinatesChanged, object: nil
        )

        // Observe sample display state changes from other sources (e.g. Inspector)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSampleDisplayStateChanged(_:)),
            name: .sampleDisplayStateChanged, object: nil
        )

        drawerLogger.info("AnnotationTableDrawerView: Setup complete")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Variant Selection Sync

    /// Handles `.variantSelected` notification from the viewer to sync the drawer's selection.
    @objc private func handleVariantSelected(_ notification: Notification) {
        guard let result = notification.userInfo?[NotificationUserInfoKey.searchResult]
                as? AnnotationSearchIndex.SearchResult else { return }
        // Ignore if we're the source of the notification
        if notification.object as AnyObject? === self { return }

        // Switch to variants tab if not already there
        if activeTab != .variants {
            switchToTab(.variants)
        }

        selectVariant(matching: result)
    }

    /// Finds and selects a variant in the table matching the given search result.
    func selectVariant(matching result: AnnotationSearchIndex.SearchResult) {
        guard let index = displayedAnnotations.firstIndex(where: {
            if let rowId = result.variantRowId, let myRowId = $0.variantRowId {
                return rowId == myRowId
            }
            return $0.chromosome == result.chromosome && $0.start == result.start
                && $0.ref == result.ref && $0.alt == result.alt
        }) else { return }

        isSuppressingDelegateCallbacks = true
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        isSuppressingDelegateCallbacks = false
    }

    /// Sets the viewer object that owns viewport-sync notifications for this drawer.
    func setViewportSyncSource(_ source: AnyObject?) {
        viewportSyncSourceObject = source
        viewportSyncSourceIdentifier = source.map(ObjectIdentifier.init)
    }

    /// Seeds the drawer's local sample display state from the viewer.
    func setSampleDisplayState(_ state: SampleDisplayState) {
        currentSampleDisplayState = state
        hasSampleDisplayStateSeed = true
        if activeTab == .samples {
            updateDisplayedSamples()
        }
    }

    // MARK: - Viewport Variant Sync

    /// Handles `.viewportVariantsUpdated` notification to auto-sync the variant table.
    @objc private func handleViewportVariantsUpdated(_ notification: Notification) {
        guard viewportSyncEnabled else { return }
        if let expectedSource = viewportSyncSourceIdentifier {
            guard let sender = notification.object as AnyObject?,
                  ObjectIdentifier(sender) == expectedSource else {
                return
            }
        }
        guard let userInfo = notification.userInfo,
              let chromosome = userInfo[NotificationUserInfoKey.chromosome] as? String,
              let start = userInfo[NotificationUserInfoKey.start] as? Int,
              let end = userInfo[NotificationUserInfoKey.end] as? Int else { return }

        viewportRegion = (chromosome: chromosome, start: start, end: end)
        guard activeTab == .variants else { return }

        // Debounce: cancel previous and schedule with 200ms delay
        viewportSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateDisplayedAnnotations()
        }
        viewportSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    /// Tracks viewer pan/zoom even when variant fetch notifications are delayed or skipped by cache reuse.
    @objc private func handleViewerCoordinatesChanged(_ notification: Notification) {
        guard viewportSyncEnabled else { return }
        if let expectedSource = viewportSyncSourceIdentifier {
            guard let sender = notification.object as AnyObject?,
                  ObjectIdentifier(sender) == expectedSource else {
                return
            }
        }
        guard let userInfo = notification.userInfo,
              let refChromosome = userInfo[NotificationUserInfoKey.chromosome] as? String,
              let start = userInfo[NotificationUserInfoKey.start] as? Int,
              let end = userInfo[NotificationUserInfoKey.end] as? Int else { return }
        let queryChromosome = (userInfo[NotificationUserInfoKey.variantChromosome] as? String) ?? refChromosome
        viewportRegion = (chromosome: queryChromosome, start: start, end: end)
        guard activeTab == .variants else { return }
        handleCoordinateSyncFromViewer()
    }

    private func handleCoordinateSyncFromViewer() {
        viewportSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateDisplayedAnnotations()
        }
        viewportSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    // MARK: - Chip Button Factory

    private func configureSearchField(_ field: NSSearchField, placeholder: String, accessibilityLabel: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.translatesAutoresizingMaskIntoConstraints = false
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(filterFieldChanged(_:))
        field.setAccessibilityLabel(accessibilityLabel)
        field.isHidden = true
    }

    private func updateSearchFieldVisibility() {
        annotationFilterField.isHidden = activeTab != .annotations
        variantFilterField.isHidden = activeTab != .variants
        sampleFilterField.isHidden = activeTab != .samples
        addSampleFieldButton.isHidden = activeTab != .samples
        downloadTemplateButton.isHidden = activeTab != .samples
        let showTypeControls = activeTab != .samples && !availableTypes.isEmpty
        allTypesButton.isHidden = !showTypeControls
        noneTypesButton.isHidden = !showTypeControls
        switch activeTab {
        case .annotations:
            searchHintLabel.stringValue = "Advanced: type:gene chr:NC_041760.1 strand:+ region:NC_041760.1:86680000-86690000"
        case .variants:
            searchHintLabel.stringValue = "Advanced: DP>20 AF>=0.01 chr:NC_041760.1 pos:86680000-86690000 qual>=30 sc>=2"
        case .samples:
            searchHintLabel.stringValue = "Advanced: name:Sample1 source:TrackA visible:true meta.Country:USA"
        }
    }

    private func makeTypeChipButton(type: String) -> NSButton {
        let button = NSButton(title: type, target: self, action: #selector(typeChipToggled(_:)))
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.controlSize = .small
        button.bezelStyle = .recessed
        button.isBordered = true
        button.setButtonType(.pushOnPushOff)
        button.state = .on  // All types visible by default
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel("Toggle \(type) annotations")
        return button
    }

    // MARK: - Column Configuration

    /// Column definitions for the annotation tab.
    private static let annotationColumnDefs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)] = [
        (nameColumn, "Name", 180, 80, "name"),
        (typeColumn, "Type", 80, 50, "type"),
        (chromosomeColumn, "Chromosome", 120, 60, "chromosome"),
        (startColumn, "Start", 100, 60, "start"),
        (endColumn, "End", 100, 60, "end"),
        (sizeColumn, "Size", 80, 50, "size"),
        (strandColumn, "Strand", 50, 30, "strand"),
    ]

    /// Column definitions for the variant tab.
    private static let variantColumnDefs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)] = [
        (variantIdColumn, "ID", 150, 80, "variant_id"),
        (variantTypeColumn, "Type", 60, 40, "variant_type"),
        (variantChromColumn, "Chrom", 100, 60, "chromosome"),
        (positionColumn, "Position", 90, 60, "position"),
        (refColumn, "Ref", 60, 30, "ref"),
        (altColumn, "Alt", 60, 30, "alt"),
        (qualityColumn, "Quality", 70, 40, "quality"),
        (filterColumn, "Filter", 70, 40, "filter"),
        (samplesColumn, "Samples", 60, 40, "samples"),
        (sourceColumn, "Source", 120, 60, "source"),
    ]

    /// Column definitions for the samples tab (fixed columns — metadata columns are dynamic).
    private static let sampleColumnDefs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)] = [
        (sampleVisibleColumn, "", 30, 30, "visible"),
        (sampleNameColumn, "Sample", 180, 80, "sample_name"),
        (sampleSourceColumn, "Source", 140, 60, "source_file"),
    ]

    /// Removes all existing columns and adds columns for the specified tab.
    private func configureColumnsForTab(_ tab: DrawerTab) {
        // Remove existing columns
        for column in tableView.tableColumns.reversed() {
            tableView.removeTableColumn(column)
        }

        let defs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)]
        switch tab {
        case .annotations: defs = Self.annotationColumnDefs
        case .variants: defs = Self.variantColumnDefs
        case .samples: defs = Self.sampleColumnDefs
        }

        for (identifier, title, width, minWidth, sortKey) in defs {
            let col = NSTableColumn(identifier: identifier)
            col.title = title
            col.width = width
            col.minWidth = minWidth
            col.resizingMask = .autoresizingMask
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: sortKey, ascending: true,
                selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
            )
            tableView.addTableColumn(col)
        }

        // Add dynamic INFO columns for variants tab
        if tab == .variants {
            for info in infoColumnKeys {
                let identifier = NSUserInterfaceItemIdentifier("info_\(info.key)")
                let col = NSTableColumn(identifier: identifier)
                col.title = info.description.isEmpty ? info.key : "\(info.description) (\(info.key))"
                col.width = info.description.isEmpty ? 60 : max(60, CGFloat(info.description.count + info.key.count + 3) * 7)
                col.minWidth = 40
                col.resizingMask = .autoresizingMask
                col.sortDescriptorPrototype = NSSortDescriptor(
                    key: "info_\(info.key)", ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
                tableView.addTableColumn(col)
            }
        }

        // Add dynamic metadata columns for samples tab
        if tab == .samples {
            for field in sampleMetadataFields {
                let identifier = NSUserInterfaceItemIdentifier("meta_\(field)")
                let col = NSTableColumn(identifier: identifier)
                col.title = field.capitalized
                col.width = max(60, CGFloat(field.count) * 8)
                col.minWidth = 40
                col.resizingMask = .autoresizingMask
                col.sortDescriptorPrototype = NSSortDescriptor(
                    key: "meta_\(field)", ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
                tableView.addTableColumn(col)
            }
        }
    }

    // MARK: - Tab Switching

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = DrawerTab(rawValue: sender.selectedSegment) else { return }
        switchToTab(tab)
    }

    /// Switches to the specified tab, reconfiguring columns, chip bar, and data.
    func switchToTab(_ tab: DrawerTab) {
        guard tab != activeTab || (tab == .samples ? displayedSamples.isEmpty : displayedAnnotations.isEmpty) else { return }
        viewportSyncWorkItem?.cancel()
        viewportSyncWorkItem = nil
        activeTab = tab
        tabControl.selectedSegment = tab.rawValue
        updateSearchFieldVisibility()

        // Multi-select for variants and samples tabs
        tableView.allowsMultipleSelection = (tab == .variants || tab == .samples)

        switch tab {
        case .annotations:
            annotationFilterField.stringValue = annotationFilterText
        case .variants:
            variantFilterField.stringValue = variantFilterText
        case .samples:
            sampleFilterField.stringValue = sampleFilterText
        }

        // Reconfigure columns for the new tab
        configureColumnsForTab(tab)

        // Rebuild chip buttons for the new tab's types (hidden for samples)
        rebuildChipButtons()

        // Re-query for the new tab's data
        if tab == .samples {
            updateDisplayedSamples()
        } else {
            updateDisplayedAnnotations()
        }

        // Keep viewport-synced variants fresh when the user switches to that tab.
        if tab == .variants {
            handleCoordinateSyncFromViewer()
        }
    }

    // MARK: - Data Loading

    /// Connects the drawer to a search index for direct SQL queries.
    /// Does NOT load all annotations into memory — queries the database on demand.
    func setSearchIndex(_ index: AnnotationSearchIndex) {
        searchIndex = index
        isLoading = false

        // Get metadata from the index — track annotation and variant counts separately
        totalAnnotationCount = index.entryCount
        totalVariantCount = index.variantCount
        availableAnnotationTypes = index.annotationTypes
        availableVariantTypes = index.variantTypes

        // Discover INFO field definitions for dynamic variant columns
        infoColumnKeys = index.variantInfoKeys.map { (key: $0.key, type: $0.type, description: $0.description) }

        // All types visible by default for both tabs
        visibleAnnotationTypes = Set(availableAnnotationTypes)
        visibleVariantTypes = Set(availableVariantTypes)

        // Populate sample data from variant databases
        populateSampleData(from: index)

        // Enable/disable variant tab based on whether variants exist
        tabControl.setEnabled(totalVariantCount > 0, forSegment: 1)
        // Enable/disable samples tab based on whether samples exist
        tabControl.setEnabled(!allSampleNames.isEmpty, forSegment: 2)
        // Show the tab control only when we have at least one type of data
        tabControl.isHidden = totalVariantCount == 0 && allSampleNames.isEmpty

        // Reconfigure columns if we're already on the variants tab so INFO columns appear
        if activeTab == .variants {
            configureColumnsForTab(.variants)
        } else if activeTab == .samples {
            configureColumnsForTab(.samples)
        }

        // Rebuild chip buttons for the active tab
        rebuildChipButtons()
        updateSearchFieldVisibility()

        // Query for initial display
        if activeTab == .samples {
            updateDisplayedSamples()
        } else {
            updateDisplayedAnnotations()
        }
        drawerLogger.info("AnnotationTableDrawerView: Connected to index with \(self.totalAnnotationCount) annotations, \(self.totalVariantCount) variants, \(self.allSampleNames.count) samples")
    }

    /// Legacy entry point for when no search index is available (fallback).
    func setAnnotations(_ results: [AnnotationSearchIndex.SearchResult]) {
        searchIndex = nil
        isLoading = false
        totalAnnotationCount = results.count

        let typeSet = Set(results.map { $0.type })
        availableAnnotationTypes = typeSet.sorted()
        visibleAnnotationTypes = typeSet

        rebuildChipButtons()

        // For legacy mode, set results directly (capped at maxDisplayCount)
        if results.count > Self.maxDisplayCount {
            displayedAnnotations = []
            tableView.reloadData()
            scrollView.isHidden = true
            let total = numberFormatter.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
            let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
            tooManyLabel.stringValue = "\(total) annotations match — use the search field or type filters to narrow to \(max) or fewer"
            tooManyLabel.isHidden = false
        } else {
            displayedAnnotations = results
            tableView.reloadData()
            scrollView.isHidden = false
            tooManyLabel.isHidden = true
        }
        updateCountLabel()
        drawerLogger.info("AnnotationTableDrawerView: Loaded \(results.count) annotations (legacy mode)")
    }

    // MARK: - Chip Management

    private func rebuildChipButtons() {
        // Remove existing chip buttons
        for view in chipStackView.arrangedSubviews {
            chipStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        chipButtons.removeAll()

        // Create a chip for each type
        for type in availableTypes {
            let chip = makeTypeChipButton(type: type)
            chip.state = visibleTypes.contains(type) ? .on : .off
            chipStackView.addArrangedSubview(chip)
            chipButtons[type] = chip
        }

        // Show chip bar if we have types (never for samples tab)
        chipBar.isHidden = activeTab == .samples || availableTypes.isEmpty
    }

    private func updateChipStates() {
        for (type, button) in chipButtons {
            button.state = visibleTypes.contains(type) ? .on : .off
        }
    }

    // MARK: - Filtering

    private func updateDisplayedAnnotations() {
        let currentFilterText: String = switch activeTab {
        case .annotations: annotationFilterText
        case .variants: variantFilterText
        case .samples: sampleFilterText
        }

        // Build the type filter set — only pass types if not all are selected
        let typeFilter: Set<String> = visibleTypes.count < availableTypes.count ? visibleTypes : []

        let entityName = activeTab == .annotations ? "annotations" : "variants"
        let activeTotal = activeTab == .annotations ? totalAnnotationCount : totalVariantCount

        // Parse tab-specific advanced search expressions.
        let annotationQuery = parseAnnotationFilterText(currentFilterText)
        let variantQuery = parseVariantFilterText(currentFilterText)
        let nameFilter = activeTab == .annotations ? annotationQuery.nameFilter : variantQuery.nameFilter

        // SQLite mode: query the database directly with filters
        if let index = searchIndex, (index.hasDatabaseBackend || index.hasVariantDatabase) {
            if activeTab == .variants {
                updateDisplayedVariants(index: index, typeFilter: typeFilter, query: variantQuery)
                updateCountLabel()
                return
            }

            // Annotations tab: global query
            let mergedTypeFilter: Set<String> = {
                guard let explicitType = annotationQuery.typeFilter, !explicitType.isEmpty else { return typeFilter }
                if typeFilter.isEmpty { return explicitType }
                return typeFilter.intersection(explicitType)
            }()
            let matchingCount = index.queryAnnotationCount(nameFilter: nameFilter, types: mergedTypeFilter)

            if matchingCount > Self.maxDisplayCount {
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                let total = numberFormatter.string(from: NSNumber(value: matchingCount)) ?? "\(matchingCount)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                tooManyLabel.stringValue = "\(total) \(entityName) match — use the search field or type filters to narrow to \(max) or fewer"
                tooManyLabel.isHidden = false
                annotationSearchRegion = nil
            } else {
                let results = index.queryAnnotationsOnly(nameFilter: nameFilter, types: mergedTypeFilter, limit: Self.maxDisplayCount * 3)
                displayedAnnotations = applyAnnotationAdvancedFilters(results, query: annotationQuery).prefix(Self.maxDisplayCount).map { $0 }
                tableView.reloadData()
                scrollView.isHidden = false
                tooManyLabel.isHidden = true
                updateAnnotationSearchRegion()
            }
            updateCountLabel()
            return
        }

        // Legacy in-memory mode (annotations only — variants always need SQLite)
        if let index = searchIndex, activeTab == .annotations {
            let hasFilters = !typeFilter.isEmpty || !nameFilter.isEmpty

            if !hasFilters && activeTotal > Self.maxDisplayCount {
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                let total = numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                tooManyLabel.stringValue = "\(total) \(entityName) — use the search field or type filters to narrow to \(max) or fewer"
                tooManyLabel.isHidden = false
            } else {
                var results = index.allResults
                if !typeFilter.isEmpty {
                    results = results.filter { typeFilter.contains($0.type) }
                }
                if !nameFilter.isEmpty {
                    let lower = nameFilter.lowercased()
                    results = results.filter { $0.name.lowercased().contains(lower) }
                }
                if results.count > Self.maxDisplayCount {
                    displayedAnnotations = []
                    tableView.reloadData()
                    scrollView.isHidden = true
                    let total = numberFormatter.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
                    let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                    tooManyLabel.stringValue = "\(total) \(entityName) match — use the search field or type filters to narrow to \(max) or fewer"
                    tooManyLabel.isHidden = false
                } else {
                    displayedAnnotations = results
                    tableView.reloadData()
                    scrollView.isHidden = false
                    tooManyLabel.isHidden = true
                }
            }
        } else if activeTab == .variants {
            // No variant data in legacy mode
            displayedAnnotations = []
            tableView.reloadData()
            scrollView.isHidden = false
            tooManyLabel.isHidden = true
        }
        updateCountLabel()
    }

    /// Populates the variant table using viewport-region-filtered or global queries.
    ///
    /// When viewport sync is enabled and a viewport region is available, queries
    /// only the visible region. Otherwise falls back to global query or shows a
    /// placeholder message.
    /// Whether viewport sync is effectively active: enabled, connected to a viewer, and region available.
    private var isViewportSyncActive: Bool {
        viewportSyncEnabled && (viewportSyncSourceIdentifier != nil || viewportSyncSourceObject != nil)
    }

    private func updateDisplayedVariants(
        index: AnnotationSearchIndex,
        typeFilter: Set<String>,
        query: VariantFilterQuery
    ) {
        // Determine the effective region for the query.
        // Priority:
        //   1. selectedAnnotationRegion (user clicked "Show Overlapping Variants")
        //   2. viewportRegion (when viewport sync active)
        //   3. annotationSearchRegion (bounding box of current annotation search results)
        //   4. Global query (no region constraint)
        let effectiveRegion: (chromosome: String, start: Int, end: Int)?
        var regionScope: VariantQueryScope = .global

        if let selected = selectedAnnotationRegion {
            effectiveRegion = selected
            regionScope = .annotation
        } else if isViewportSyncActive {
            if let vp = viewportRegion {
                effectiveRegion = vp
                regionScope = .viewport
            } else {
                // Connected to a viewer but no region yet — show placeholder
                lastVariantQueryMatchCount = nil
                lastVariantQueryScope = .placeholder
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                tooManyLabel.stringValue = "Navigate to a region to view variants"
                tooManyLabel.isHidden = false
                updateCountLabel()
                return
            }
        } else if let annotationRegion = annotationSearchRegion {
            // Use annotation bounding region as fallback when no higher-priority region is active.
            effectiveRegion = annotationRegion
            regionScope = .annotations
        } else {
            effectiveRegion = nil
        }

        // Let advanced query constraints tighten/override the region.
        let requestedRegion = query.region ?? effectiveRegion

        if let region = requestedRegion {
            let count = index.queryVariantCountInRegion(
                chromosome: region.chromosome,
                start: region.start,
                end: region.end,
                nameFilter: query.nameFilter,
                types: typeFilter,
                infoFilters: query.infoFilters
            )
            lastVariantQueryMatchCount = count
            lastVariantQueryScope = regionScope
            if count > Self.maxDisplayCount {
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                let total = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                let hint = regionScope == .viewport ? "zoom in" : "filter"
                tooManyLabel.stringValue = "\(total) variants in region — \(hint) to show \(max) or fewer"
                tooManyLabel.isHidden = false
            } else {
                let results = index.queryVariantsInRegion(
                    chromosome: region.chromosome,
                    start: region.start,
                    end: region.end,
                    nameFilter: query.nameFilter,
                    types: typeFilter,
                    infoFilters: query.infoFilters,
                    limit: Self.maxDisplayCount * 3
                )
                displayedAnnotations = applyVariantAdvancedFilters(results, query: query).prefix(Self.maxDisplayCount).map { $0 }
                if query.hasPostFilters {
                    lastVariantQueryMatchCount = displayedAnnotations.count
                }
                tableView.reloadData()
                scrollView.isHidden = false
                tooManyLabel.isHidden = true
            }
        } else {
            // No region constraint — global query over all variants
            let matchingCount = index.queryVariantCount(nameFilter: query.nameFilter, types: typeFilter, infoFilters: query.infoFilters)
            lastVariantQueryMatchCount = matchingCount
            lastVariantQueryScope = .global
            if matchingCount > Self.maxDisplayCount {
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                let total = numberFormatter.string(from: NSNumber(value: matchingCount)) ?? "\(matchingCount)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                tooManyLabel.stringValue = "\(total) variants match — use the search field or type filters to narrow to \(max) or fewer"
                tooManyLabel.isHidden = false
            } else {
                let results = index.queryVariantsOnly(
                    nameFilter: query.nameFilter,
                    types: typeFilter,
                    infoFilters: query.infoFilters,
                    limit: Self.maxDisplayCount * 3
                )
                displayedAnnotations = applyVariantAdvancedFilters(results, query: query).prefix(Self.maxDisplayCount).map { $0 }
                if query.hasPostFilters {
                    lastVariantQueryMatchCount = displayedAnnotations.count
                }
                tableView.reloadData()
                scrollView.isHidden = false
                tooManyLabel.isHidden = true
            }
        }
    }

    private func updateCountLabel() {
        if activeTab == .samples {
            let total = allSampleNames.count
            let shown = displayedSamples.count
            let hidden = currentSampleDisplayState.hiddenSamples.count
            if isLoading {
                countLabel.stringValue = "Loading..."
            } else if shown == total {
                let hiddenStr = hidden > 0 ? " (\(hidden) hidden)" : ""
                countLabel.stringValue = "\(total) samples\(hiddenStr)"
            } else {
                countLabel.stringValue = "\(shown) of \(total) samples"
            }
            return
        }

        let entityName = activeTab == .annotations ? "annotations" : "variants"
        let activeTotal = activeTab == .annotations ? totalAnnotationCount : totalVariantCount

        if isLoading {
            countLabel.stringValue = "Building annotation index (scanning all chromosomes)..."
        } else if activeTab == .variants {
            // Unified variant count label using tracked scope and match count
            let total = numberFormatter.string(from: NSNumber(value: totalVariantCount)) ?? "\(totalVariantCount)"
            switch lastVariantQueryScope {
            case .placeholder:
                countLabel.stringValue = "\(total) variants total"
            case .annotation:
                let count = lastVariantQueryMatchCount ?? displayedAnnotations.count
                let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                countLabel.stringValue = "\(shown) overlapping (\(total) total)"
            case .viewport:
                let count = lastVariantQueryMatchCount ?? displayedAnnotations.count
                let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                countLabel.stringValue = "\(shown) in viewport (\(total) total)"
            case .annotations:
                let count = lastVariantQueryMatchCount ?? displayedAnnotations.count
                let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                countLabel.stringValue = "\(shown) near annotations (\(total) total)"
            case .global:
                if !tooManyLabel.isHidden {
                    countLabel.stringValue = "\(total) total — filter to browse"
                } else if displayedAnnotations.count == totalVariantCount {
                    countLabel.stringValue = "\(total) variants"
                } else {
                    let shown = numberFormatter.string(from: NSNumber(value: displayedAnnotations.count)) ?? "\(displayedAnnotations.count)"
                    countLabel.stringValue = "\(shown) of \(total)"
                }
            }
        } else if !tooManyLabel.isHidden {
            let total = numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)"
            countLabel.stringValue = "\(total) total — filter to browse"
        } else if displayedAnnotations.count == activeTotal {
            countLabel.stringValue = "\(numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)") \(entityName)"
        } else {
            let shown = numberFormatter.string(from: NSNumber(value: displayedAnnotations.count)) ?? "\(displayedAnnotations.count)"
            let total = numberFormatter.string(from: NSNumber(value: activeTotal)) ?? "\(activeTotal)"
            countLabel.stringValue = "\(shown) of \(total)"
        }
    }

    private func updateLoadingState() {
        loadingIndicator.isHidden = !isLoading
        if isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
        updateCountLabel()
    }

    @objc private func filterFieldChanged(_ sender: NSSearchField) {
        switch activeTab {
        case .annotations:
            annotationFilterText = sender.stringValue
        case .variants:
            variantFilterText = sender.stringValue
        case .samples:
            sampleFilterText = sender.stringValue
        }
        // Clear annotation-specific region when user types on variants tab
        if activeTab == .variants {
            selectedAnnotationRegion = nil
        }
        if activeTab == .samples {
            updateDisplayedSamples()
        } else {
            updateDisplayedAnnotations()
        }
    }

    private struct AnnotationFilterQuery {
        var nameFilter: String = ""
        var typeFilter: Set<String>?
        var chromosome: String?
        var strand: String?
        var start: Int?
        var end: Int?
    }

    private struct VariantFilterQuery {
        var nameFilter: String = ""
        var infoFilters: [VariantDatabase.InfoFilter] = []
        var region: (chromosome: String, start: Int, end: Int)?
        var minQuality: Double?
        var minQualityInclusive: Bool = true
        var maxQuality: Double?
        var maxQualityInclusive: Bool = true
        var minSampleCount: Int?
        var minSampleCountInclusive: Bool = true
        var maxSampleCount: Int?
        var maxSampleCountInclusive: Bool = true

        var hasPostFilters: Bool {
            minQuality != nil || maxQuality != nil || minSampleCount != nil || maxSampleCount != nil
        }
    }

    private struct SampleFilterQuery {
        var textFilter: String = ""
        var nameFilter: String?
        var sourceFilter: String?
        var visibility: Bool?
        var metadataFilters: [(String, String)] = []
    }

    /// Parses advanced annotation search syntax:
    /// `type:gene chr:NC_045512 strand:+ region:NC_045512:100-900 myName`
    private func parseAnnotationFilterText(_ text: String) -> AnnotationFilterQuery {
        var query = AnnotationFilterQuery()
        var freeTokens: [String] = []
        for tokenSub in text.split(whereSeparator: \.isWhitespace) {
            let token = String(tokenSub)
            if let value = token.value(after: "type:") {
                query.typeFilter = [value]
            } else if let value = token.value(after: "chr:") ?? token.value(after: "chrom:") {
                query.chromosome = value
            } else if let value = token.value(after: "strand:") {
                query.strand = value
            } else if let value = token.value(after: "start:"), let parsed = Int(value) {
                query.start = parsed
            } else if let value = token.value(after: "end:"), let parsed = Int(value) {
                query.end = parsed
            } else if let value = token.value(after: "region:"), let parsed = parseRegion(value) {
                query.chromosome = parsed.chromosome
                query.start = parsed.start
                query.end = parsed.end
            } else {
                freeTokens.append(token)
            }
        }
        query.nameFilter = freeTokens.joined(separator: " ")
        return query
    }

    /// Parses advanced variant syntax:
    /// `chr:7 pos:100-200 DP>20 AF>=0.01 qual>=30 sc>=2 rs123`
    private func parseVariantFilterText(_ text: String) -> VariantFilterQuery {
        var query = VariantFilterQuery()
        var nameTokens: [String] = []

        for tokenSub in text.split(whereSeparator: \.isWhitespace) {
            let token = String(tokenSub)
            if let parsed = VariantDatabase.InfoFilter.parse(token) {
                query.infoFilters.append(parsed)
                continue
            }
            if let value = token.value(after: "chr:") ?? token.value(after: "chrom:") {
                if let region = query.region {
                    query.region = (value, region.start, region.end)
                } else {
                    query.region = (value, 0, Int.max)
                }
                continue
            }
            if let value = token.value(after: "pos:") ?? token.value(after: "range:"),
               let range = parseRange(value) {
                let chr = query.region?.chromosome ?? viewportRegion?.chromosome ?? ""
                if !chr.isEmpty {
                    query.region = (chr, range.start, range.end)
                }
                continue
            }
            if let opValue = parseComparisonToken(token, keys: ["qual", "quality"]) {
                if opValue.op == ">" || opValue.op == ">=" {
                    query.minQuality = opValue.value
                    query.minQualityInclusive = opValue.op == ">="
                } else if opValue.op == "<" || opValue.op == "<=" {
                    query.maxQuality = opValue.value
                    query.maxQualityInclusive = opValue.op == "<="
                }
                continue
            }
            if let opValue = parseComparisonToken(token, keys: ["sc", "samples", "samplecount"]) {
                let count = Int(opValue.value.rounded())
                if opValue.op == ">" || opValue.op == ">=" {
                    query.minSampleCount = count
                    query.minSampleCountInclusive = opValue.op == ">="
                } else if opValue.op == "<" || opValue.op == "<=" {
                    query.maxSampleCount = count
                    query.maxSampleCountInclusive = opValue.op == "<="
                }
                continue
            }
            nameTokens.append(token)
        }
        query.nameFilter = nameTokens.joined(separator: " ")
        // Discard placeholder region if no valid chromosome was specified.
        if let region = query.region, region.chromosome.isEmpty {
            query.region = nil
        }
        return query
    }

    /// Parses advanced sample syntax:
    /// `name:S1 source:run42 visible:true meta.Country:USA`
    private func parseSampleFilterText(_ text: String) -> SampleFilterQuery {
        var query = SampleFilterQuery()
        var freeTokens: [String] = []
        for tokenSub in text.split(whereSeparator: \.isWhitespace) {
            let token = String(tokenSub)
            if let value = token.value(after: "name:") {
                query.nameFilter = value
            } else if let value = token.value(after: "source:") {
                query.sourceFilter = value
            } else if let value = token.value(after: "visible:") {
                let lower = value.lowercased()
                if ["1", "true", "yes", "on"].contains(lower) { query.visibility = true }
                if ["0", "false", "no", "off"].contains(lower) { query.visibility = false }
            } else if token.lowercased().hasPrefix("meta."),
                      let sep = token.firstIndex(of: ":") {
                let key = String(token[token.index(token.startIndex, offsetBy: 5)..<sep])
                let value = String(token[token.index(after: sep)...])
                if !key.isEmpty, !value.isEmpty {
                    query.metadataFilters.append((key, value))
                }
            } else {
                freeTokens.append(token)
            }
        }
        query.textFilter = freeTokens.joined(separator: " ")
        return query
    }

    private func applyAnnotationAdvancedFilters(
        _ results: [AnnotationSearchIndex.SearchResult],
        query: AnnotationFilterQuery
    ) -> [AnnotationSearchIndex.SearchResult] {
        results.filter { row in
            if let chr = query.chromosome, row.chromosome.caseInsensitiveCompare(chr) != .orderedSame { return false }
            if let strand = query.strand, row.strand.caseInsensitiveCompare(strand) != .orderedSame { return false }
            if let start = query.start, row.end <= start { return false }
            if let end = query.end, row.start >= end { return false }
            return true
        }
    }

    private func applyVariantAdvancedFilters(
        _ results: [AnnotationSearchIndex.SearchResult],
        query: VariantFilterQuery
    ) -> [AnnotationSearchIndex.SearchResult] {
        results.filter { row in
            if let minQ = query.minQuality {
                let q = row.quality ?? -Double.greatestFiniteMagnitude
                if query.minQualityInclusive ? q < minQ : q <= minQ { return false }
            }
            if let maxQ = query.maxQuality {
                let q = row.quality ?? Double.greatestFiniteMagnitude
                if query.maxQualityInclusive ? q > maxQ : q >= maxQ { return false }
            }
            if let minSC = query.minSampleCount {
                let sc = row.sampleCount ?? 0
                if query.minSampleCountInclusive ? sc < minSC : sc <= minSC { return false }
            }
            if let maxSC = query.maxSampleCount {
                let sc = row.sampleCount ?? Int.max
                if query.maxSampleCountInclusive ? sc > maxSC : sc >= maxSC { return false }
            }
            return true
        }
    }

    private func parseRange(_ text: String) -> (start: Int, end: Int)? {
        let parts = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else { return nil }
        guard end > start else { return nil }
        return (start, end)
    }

    private func parseRegion(_ text: String) -> (chromosome: String, start: Int, end: Int)? {
        let pieces = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, !pieces[0].isEmpty else { return nil }
        guard let range = parseRange(pieces[1]) else { return nil }
        return (pieces[0], range.start, range.end)
    }

    private func parseComparisonToken(_ token: String, keys: [String]) -> (op: String, value: Double)? {
        let operators = [">=", "<=", ">", "<"]
        for key in keys {
            for op in operators {
                let prefix = "\(key)\(op)"
                if token.lowercased().hasPrefix(prefix),
                   let value = Double(token.dropFirst(prefix.count)) {
                    return (op, value)
                }
            }
        }
        return nil
    }

    @objc private func typeChipToggled(_ sender: NSButton) {
        let type = sender.title
        if sender.state == .on {
            visibleTypes.insert(type)
        } else {
            visibleTypes.remove(type)
        }
        updateDisplayedAnnotations()
    }

    @objc private func selectAllTypes(_ sender: Any) {
        visibleTypes = Set(availableTypes)
        updateChipStates()
        updateDisplayedAnnotations()
    }

    @objc private func selectNoTypes(_ sender: Any) {
        visibleTypes.removeAll()
        updateChipStates()
        updateDisplayedAnnotations()
    }

    // MARK: - Actions

    @objc private func tableViewDoubleClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        // Samples tab doesn't navigate on double-click
        guard activeTab != .samples else { return }
        guard row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        drawerLogger.info("AnnotationTableDrawerView: Double-clicked '\(annotation.name, privacy: .public)' on \(annotation.chromosome, privacy: .public)")
        delegate?.annotationDrawer(self, didSelectAnnotation: annotation)
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        activeTab == .samples ? displayedSamples.count : displayedAnnotations.count
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sortDescriptor = tableView.sortDescriptors.first,
              let key = sortDescriptor.key else { return }

        let ascending = sortDescriptor.ascending

        if activeTab == .samples {
            let sortedAllSamples = sortedSampleNames(key: key, ascending: ascending, names: resolvedSampleOrder())
            // Sync sort to SampleDisplayState so viewer rendering order matches
            let displayField: String
            switch key {
            case "visible": displayField = "visible"
            case "sample_name": displayField = "name"
            case "source_file": displayField = "source"
            default:
                if key.hasPrefix("meta_") {
                    displayField = String(key.dropFirst(5))
                } else {
                    displayField = key
                }
            }
            currentSampleDisplayState.sortFields = [SortField(field: displayField, ascending: ascending)]
            // Persist full-order sort, not just currently filtered rows.
            currentSampleDisplayState.sampleOrder = sortedAllSamples
            postSampleDisplayStateChange()
            updateDisplayedSamples()
            return
        }

        displayedAnnotations.sort { a, b in
            let result: ComparisonResult
            switch key {
            // Annotation columns
            case "name", "variant_id":
                result = a.name.localizedCaseInsensitiveCompare(b.name)
            case "type", "variant_type":
                result = a.type.localizedCaseInsensitiveCompare(b.type)
            case "chromosome":
                result = a.chromosome.localizedCaseInsensitiveCompare(b.chromosome)
            case "start", "position":
                result = a.start < b.start ? .orderedAscending : (a.start > b.start ? .orderedDescending : .orderedSame)
            case "end":
                result = a.end < b.end ? .orderedAscending : (a.end > b.end ? .orderedDescending : .orderedSame)
            case "size":
                let sizeA = a.end - a.start
                let sizeB = b.end - b.start
                result = sizeA < sizeB ? .orderedAscending : (sizeA > sizeB ? .orderedDescending : .orderedSame)
            case "strand":
                result = a.strand.compare(b.strand)
            // Variant columns
            case "ref":
                result = (a.ref ?? "").localizedCaseInsensitiveCompare(b.ref ?? "")
            case "alt":
                result = (a.alt ?? "").localizedCaseInsensitiveCompare(b.alt ?? "")
            case "quality":
                let qa = a.quality ?? -1
                let qb = b.quality ?? -1
                result = qa < qb ? .orderedAscending : (qa > qb ? .orderedDescending : .orderedSame)
            case "filter":
                result = (a.filter ?? "").localizedCaseInsensitiveCompare(b.filter ?? "")
            case "samples":
                let sa = a.sampleCount ?? 0
                let sb = b.sampleCount ?? 0
                result = sa < sb ? .orderedAscending : (sa > sb ? .orderedDescending : .orderedSame)
            case "source":
                result = (a.sourceFile ?? "").localizedCaseInsensitiveCompare(b.sourceFile ?? "")
            default:
                // Dynamic INFO column sort (key starts with "info_")
                if key.hasPrefix("info_") {
                    let infoKey = String(key.dropFirst(5))
                    let valA = a.infoDict?[infoKey] ?? ""
                    let valB = b.infoDict?[infoKey] ?? ""
                    if isNumericInfoKey(infoKey) {
                        let numA = Double(valA) ?? -.infinity
                        let numB = Double(valB) ?? -.infinity
                        result = numA < numB ? .orderedAscending : (numA > numB ? .orderedDescending : .orderedSame)
                    } else {
                        result = valA.localizedCaseInsensitiveCompare(valB)
                    }
                } else {
                    result = .orderedSame
                }
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }

        tableView.reloadData()
    }

    // MARK: - NSTableViewDelegate

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let identifier = column.identifier

        // Samples tab uses its own data source
        if activeTab == .samples {
            return sampleCellView(for: identifier, row: row)
        }

        guard row < displayedAnnotations.count else { return nil }
        let annotation = displayedAnnotations[row]

        let cellView: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let tf = cellView.textField!
        tf.alignment = .left  // Reset default alignment
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)  // Reset default font

        switch identifier {
        // Annotation columns
        case Self.nameColumn:
            tf.stringValue = annotation.name
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        case Self.typeColumn:
            tf.stringValue = annotation.type
            tf.font = .systemFont(ofSize: 11)
        case Self.chromosomeColumn:
            tf.stringValue = annotation.chromosome
        case Self.startColumn:
            tf.stringValue = numberFormatter.string(from: NSNumber(value: annotation.start)) ?? "\(annotation.start)"
            tf.alignment = .right
        case Self.endColumn:
            tf.stringValue = numberFormatter.string(from: NSNumber(value: annotation.end)) ?? "\(annotation.end)"
            tf.alignment = .right
        case Self.sizeColumn:
            let size = annotation.end - annotation.start
            tf.stringValue = formatSize(size)
            tf.alignment = .right
        case Self.strandColumn:
            tf.stringValue = annotation.strand
            tf.alignment = .center

        // Variant columns
        case Self.variantIdColumn:
            tf.stringValue = annotation.name
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        case Self.variantTypeColumn:
            tf.stringValue = annotation.type
            tf.font = .systemFont(ofSize: 11)
        case Self.variantChromColumn:
            tf.stringValue = annotation.chromosome
        case Self.positionColumn:
            // Display as 1-based (VCF convention) — internal storage is 0-based
            let displayPos = annotation.start + 1
            tf.stringValue = numberFormatter.string(from: NSNumber(value: displayPos)) ?? "\(displayPos)"
            tf.alignment = .right
        case Self.refColumn:
            tf.stringValue = annotation.ref ?? ""
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        case Self.altColumn:
            tf.stringValue = annotation.alt ?? ""
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        case Self.qualityColumn:
            if let q = annotation.quality {
                tf.stringValue = q < 0 ? "." : String(format: "%.1f", q)
            } else {
                tf.stringValue = "."
            }
            tf.alignment = .right
        case Self.filterColumn:
            tf.stringValue = annotation.filter ?? "."
        case Self.samplesColumn:
            tf.stringValue = "\(annotation.sampleCount ?? 0)"
            tf.alignment = .right
        case Self.sourceColumn:
            tf.stringValue = annotation.sourceFile ?? ""
            tf.font = .systemFont(ofSize: 11)

        default:
            // Dynamic INFO columns (identifier starts with "info_")
            if identifier.rawValue.hasPrefix("info_") {
                let infoKey = String(identifier.rawValue.dropFirst(5))
                tf.stringValue = annotation.infoDict?[infoKey] ?? ""
                tf.alignment = isNumericInfoKey(infoKey) ? .right : .left
            } else {
                tf.stringValue = ""
            }
        }

        return cellView
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSuppressingDelegateCallbacks else { return }
        // Samples tab doesn't navigate on selection
        guard activeTab != .samples else { return }
        let selectedRows = tableView.selectedRowIndexes
        // Only navigate to a single selection — multi-select doesn't trigger navigation
        guard selectedRows.count == 1, let row = selectedRows.first,
              row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        drawerLogger.debug("AnnotationTableDrawerView: Selected '\(annotation.name, privacy: .public)' at row \(row)")
        delegate?.annotationDrawer(self, didSelectAnnotation: annotation)
    }

    // MARK: - Formatting

    private func formatSize(_ bp: Int) -> String {
        switch bp {
        case 0..<1_000:
            return "\(bp) bp"
        case 1_000..<1_000_000:
            return String(format: "%.1f kb", Double(bp) / 1_000.0)
        default:
            return String(format: "%.1f Mb", Double(bp) / 1_000_000.0)
        }
    }

    /// Whether an INFO key represents a numeric type (Integer or Float) for sorting.
    private func isNumericInfoKey(_ key: String) -> Bool {
        infoColumnKeys.first(where: { $0.key == key }).map { $0.type == "Integer" || $0.type == "Float" } ?? false
    }

    // MARK: - Public API

    /// Selects and scrolls to an annotation by name.
    @discardableResult
    func selectAnnotation(named name: String) -> Bool {
        guard let index = displayedAnnotations.firstIndex(where: { $0.name == name }) else {
            return false
        }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        return true
    }

    // MARK: - Context Menu Actions

    /// Looks up the translation string for an annotation from the SQLite database.
    func lookupTranslation(for annotation: AnnotationSearchIndex.SearchResult) -> String? {
        guard let record = searchIndex?.lookupAnnotation(for: annotation) else { return nil }
        guard let attrs = record.attributes, !attrs.isEmpty else { return nil }
        let parsed = AnnotationDatabase.parseAttributes(attrs)
        return parsed["translation"]
    }

    @objc private func copyTranslationAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        guard let translation = lookupTranslation(for: annotation) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translation, forType: .string)
        drawerLogger.info("AnnotationTableDrawerView: Copied translation for '\(annotation.name, privacy: .public)' (\(translation.count) amino acids)")
    }

    @objc private func copyNameAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(annotation.name, forType: .string)
    }

    @objc private func copyCoordinatesAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        // Variants use 1-based coordinates (VCF convention); annotations use 0-based (BED convention)
        let start = activeTab == .variants ? annotation.start + 1 : annotation.start
        let coords = "\(annotation.chromosome):\(start)-\(annotation.end)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(coords, forType: .string)
    }

    // MARK: - Extraction Actions

    private func makeAnnotation(from result: AnnotationSearchIndex.SearchResult) -> SequenceAnnotation {
        if let record = searchIndex?.lookupAnnotation(for: result) {
            return record.toAnnotation()
        }

        let type = AnnotationType.from(rawString: result.type) ?? .gene
        let strand: Strand = result.strand == "+" ? .forward : (result.strand == "-" ? .reverse : .unknown)
        return SequenceAnnotation(
            type: type,
            name: result.name,
            chromosome: result.chromosome,
            start: result.start,
            end: result.end,
            strand: strand
        )
    }

    @objc private func copyAsFASTAAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationAsFASTARequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func copyTranslationAsFASTAAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyTranslationAsFASTARequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func extractSequenceAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .extractSequenceRequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func copySequenceAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationSequenceRequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func copyReverseComplementAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationReverseComplementRequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func zoomToAnnotationAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .zoomToAnnotationRequested,
            object: nil,
            userInfo: ["annotation": annotation]
        )
    }

    @objc private func showInInspectorAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        if result.isVariant {
            NotificationCenter.default.post(
                name: .variantSelected,
                object: self,
                userInfo: [NotificationUserInfoKey.searchResult: result]
            )
        } else {
            let annotation = makeAnnotation(from: result)
            NotificationCenter.default.post(
                name: .annotationSelected,
                object: nil,
                userInfo: [NotificationUserInfoKey.annotation: annotation]
            )
        }
        // Then show inspector
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
        )
    }

    // MARK: - Variant Context Menu Actions

    @objc private func copyRefAltAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let refAlt = "\(result.ref ?? "") > \(result.alt ?? "")"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(refAlt, forType: .string)
    }

    @objc private func copyAsVCFLineAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        // VCF uses 1-based positions
        let pos1Based = result.start + 1
        let qual = result.quality.map { String(format: "%.1f", $0) } ?? "."
        let filt = result.filter ?? "."
        let vcfLine = "\(result.chromosome)\t\(pos1Based)\t\(result.name)\t\(result.ref ?? ".")\t\(result.alt ?? ".")\t\(qual)\t\(filt)\t."
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(vcfLine, forType: .string)
    }

    @objc private func filterToTypeAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        // Set visible types to just this type
        visibleTypes = Set([result.type])
        updateChipStates()
        updateDisplayedAnnotations()
    }
}

// MARK: - NSMenuDelegate

extension AnnotationTableDrawerView: NSMenuDelegate {

    private static func supportsTranslationMenu(for type: String) -> Bool {
        let normalized = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "cds" || normalized == "mat_peptide"
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let targetRow: Int
        if tableView.clickedRow >= 0 {
            targetRow = tableView.clickedRow
        } else {
            // Keyboard-invoked context menu (or tests) may not have a clicked row.
            targetRow = tableView.selectedRow
        }

        // Samples tab context menu
        if activeTab == .samples {
            guard targetRow >= 0, targetRow < displayedSamples.count else {
                buildSampleGlobalContextMenu(menu)
                return
            }
            buildSampleContextMenu(menu, row: targetRow)
            return
        }

        guard targetRow >= 0, targetRow < displayedAnnotations.count else { return }

        let annotation = displayedAnnotations[targetRow]

        if annotation.isVariant {
            buildVariantContextMenu(menu, annotation: annotation)
        } else {
            buildAnnotationContextMenu(menu, annotation: annotation)
        }
    }

    private func buildAnnotationContextMenu(_ menu: NSMenu, annotation: AnnotationSearchIndex.SearchResult) {
        let isCDS = Self.supportsTranslationMenu(for: annotation.type)

        // --- Copy submenu ---
        let copyMenu = NSMenu(title: "Copy")

        let copyNameItem = NSMenuItem(title: "Copy Name", action: #selector(copyNameAction(_:)), keyEquivalent: "")
        copyNameItem.target = self
        copyNameItem.representedObject = annotation
        copyMenu.addItem(copyNameItem)

        let copyCoordsItem = NSMenuItem(title: "Copy Coordinates", action: #selector(copyCoordinatesAction(_:)), keyEquivalent: "")
        copyCoordsItem.target = self
        copyCoordsItem.representedObject = annotation
        copyMenu.addItem(copyCoordsItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copySeqItem = NSMenuItem(title: "Copy Sequence", action: #selector(copySequenceAction(_:)), keyEquivalent: "")
        copySeqItem.target = self
        copySeqItem.representedObject = annotation
        copyMenu.addItem(copySeqItem)

        let copyRevCompItem = NSMenuItem(title: "Copy Reverse Complement", action: #selector(copyReverseComplementAction(_:)), keyEquivalent: "")
        copyRevCompItem.target = self
        copyRevCompItem.representedObject = annotation
        copyMenu.addItem(copyRevCompItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copyFASTAItem = NSMenuItem(title: "Copy as FASTA", action: #selector(copyAsFASTAAction(_:)), keyEquivalent: "")
        copyFASTAItem.target = self
        copyFASTAItem.representedObject = annotation
        copyMenu.addItem(copyFASTAItem)

        if isCDS {
            let copyProteinItem = NSMenuItem(title: "Copy Translation as FASTA", action: #selector(copyTranslationAsFASTAAction(_:)), keyEquivalent: "")
            copyProteinItem.target = self
            copyProteinItem.representedObject = annotation
            copyMenu.addItem(copyProteinItem)
        }

        // Copy Translation (raw amino acids, only for CDS with stored translation)
        let translation = isCDS ? lookupTranslation(for: annotation) : nil
        if isCDS {
            copyMenu.addItem(NSMenuItem.separator())
            let copyTransItem = NSMenuItem(title: "Copy Translation", action: #selector(copyTranslationAction(_:)), keyEquivalent: "")
            copyTransItem.target = self
            copyTransItem.representedObject = annotation
            if translation == nil {
                copyTransItem.isEnabled = false
                copyTransItem.toolTip = "No translation data available for this annotation"
            }
            copyMenu.addItem(copyTransItem)
        }

        let copyMenuItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyMenuItem.submenu = copyMenu
        menu.addItem(copyMenuItem)

        // --- Extract ---
        let extractItem = NSMenuItem(title: "Extract Sequence\u{2026}", action: #selector(extractSequenceAction(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = annotation
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        // --- Navigation ---
        let zoomItem = NSMenuItem(title: "Zoom to Annotation", action: #selector(zoomToAnnotationAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.representedObject = annotation
        menu.addItem(zoomItem)

        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showInInspectorAction(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = annotation
        menu.addItem(inspectorItem)

        // --- Variant cross-reference (only if variant data exists) ---
        if totalVariantCount > 0 {
            menu.addItem(NSMenuItem.separator())
            let variantItem = NSMenuItem(title: "Show Overlapping Variants", action: #selector(showOverlappingVariantsAction(_:)), keyEquivalent: "")
            variantItem.target = self
            variantItem.representedObject = annotation
            menu.addItem(variantItem)
        }
    }

    private func buildVariantContextMenu(_ menu: NSMenu, annotation: AnnotationSearchIndex.SearchResult) {
        // --- Copy submenu ---
        let copyMenu = NSMenu(title: "Copy")

        let copyIdItem = NSMenuItem(title: "Copy Variant ID", action: #selector(copyNameAction(_:)), keyEquivalent: "")
        copyIdItem.target = self
        copyIdItem.representedObject = annotation
        copyMenu.addItem(copyIdItem)

        let copyCoordsItem = NSMenuItem(title: "Copy Coordinates", action: #selector(copyCoordinatesAction(_:)), keyEquivalent: "")
        copyCoordsItem.target = self
        copyCoordsItem.representedObject = annotation
        copyMenu.addItem(copyCoordsItem)

        copyMenu.addItem(NSMenuItem.separator())

        let copyRefAltItem = NSMenuItem(title: "Copy Ref/Alt", action: #selector(copyRefAltAction(_:)), keyEquivalent: "")
        copyRefAltItem.target = self
        copyRefAltItem.representedObject = annotation
        copyMenu.addItem(copyRefAltItem)

        let copyVCFLineItem = NSMenuItem(title: "Copy as VCF Line", action: #selector(copyAsVCFLineAction(_:)), keyEquivalent: "")
        copyVCFLineItem.target = self
        copyVCFLineItem.representedObject = annotation
        copyMenu.addItem(copyVCFLineItem)

        let copyMenuItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyMenuItem.submenu = copyMenu
        menu.addItem(copyMenuItem)

        menu.addItem(NSMenuItem.separator())

        // --- Navigation ---
        let zoomItem = NSMenuItem(title: "Zoom to Variant", action: #selector(zoomToAnnotationAction(_:)), keyEquivalent: "")
        zoomItem.target = self
        zoomItem.representedObject = annotation
        menu.addItem(zoomItem)

        let inspectorItem = NSMenuItem(title: "Show in Inspector", action: #selector(showInInspectorAction(_:)), keyEquivalent: "")
        inspectorItem.target = self
        inspectorItem.representedObject = annotation
        menu.addItem(inspectorItem)

        menu.addItem(NSMenuItem.separator())

        // --- Filter by Type ---
        let filterTypeItem = NSMenuItem(title: "Filter to \(annotation.type) Only", action: #selector(filterToTypeAction(_:)), keyEquivalent: "")
        filterTypeItem.target = self
        filterTypeItem.representedObject = annotation
        menu.addItem(filterTypeItem)

        menu.addItem(NSMenuItem.separator())

        // --- Delete ---
        let selectedCount = tableView.selectedRowIndexes.count
        let deleteTitle = selectedCount > 1 ? "Delete \(selectedCount) Selected Variants" : "Delete Selected Variant"
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteSelectedVariantsAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        let deleteAllItem = NSMenuItem(title: "Delete All Variants...", action: #selector(deleteAllVariantsAction(_:)), keyEquivalent: "")
        deleteAllItem.target = self
        menu.addItem(deleteAllItem)
    }

    // MARK: - Delete Actions

    @objc private func deleteSelectedVariantsAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        let selectedVariants = selectedRows.compactMap { idx -> AnnotationSearchIndex.SearchResult? in
            guard idx < displayedAnnotations.count else { return nil }
            return displayedAnnotations[idx]
        }
        let scopedIDs = variantIDsByTrack(from: selectedVariants)
        let count = scopedIDs.values.reduce(0) { $0 + $1.count }
        guard count > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(count) Variant\(count == 1 ? "" : "s")?"
        alert.informativeText = "This will permanently remove the selected variant\(count == 1 ? "" : "s") from the database."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performVariantDeletion(scopedIDs)
        }
    }

    @objc private func deleteAllVariantsAction(_ sender: NSMenuItem) {
        let count = totalVariantCount
        let alert = NSAlert()
        alert.messageText = "Delete All \(count) Variants?"
        alert.informativeText = "This will permanently remove all variants from the database. This cannot be undone."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .critical

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDeleteAllVariants()
        }
    }

    private func performVariantDeletion(_ idsByTrack: [String: [Int64]]) {
        guard let searchIndex else { return }
        guard !idsByTrack.isEmpty else { return }

        let handlesByTrack = Dictionary(uniqueKeysWithValues: searchIndex.variantDatabaseHandles.map { ($0.trackId, $0.db) })
        var deletedCount = 0

        for (trackId, ids) in idsByTrack {
            guard let db = handlesByTrack[trackId] else {
                drawerLogger.warning("performVariantDeletion: No variant database handle for track '\(trackId, privacy: .public)'")
                continue
            }
            do {
                let rwDB = try VariantDatabase(url: db.databaseURL, readWrite: true)
                deletedCount += try rwDB.deleteVariants(ids: ids)
            } catch {
                drawerLogger.error("performVariantDeletion[\(trackId, privacy: .public)]: \(error.localizedDescription)")
            }
        }

        if deletedCount > 0 {
            totalVariantCount = max(0, totalVariantCount - deletedCount)
            updateDisplayedAnnotations()
            updateCountLabel()
            delegate?.annotationDrawer(self, didDeleteVariants: deletedCount)
        }
    }

    private func performDeleteAllVariants() {
        guard let searchIndex else { return }

        var deletedCount = 0
        for (_, db) in searchIndex.variantDatabaseHandles {
            do {
                let rwDB = try VariantDatabase(url: db.databaseURL, readWrite: true)
                deletedCount += try rwDB.deleteAllVariants()
            } catch {
                drawerLogger.error("performDeleteAllVariants: \(error.localizedDescription)")
            }
        }

        if deletedCount > 0 {
            totalVariantCount = 0
            updateDisplayedAnnotations()
            updateCountLabel()
            delegate?.annotationDrawer(self, didDeleteVariants: deletedCount)
        }
    }

    /// Groups selected variant row IDs by their owning track ID.
    private func variantIDsByTrack(from variants: [AnnotationSearchIndex.SearchResult]) -> [String: [Int64]] {
        var grouped = Dictionary<String, Set<Int64>>()
        for variant in variants {
            guard variant.isVariant, !variant.trackId.isEmpty, let rowID = variant.variantRowId else { continue }
            grouped[variant.trackId, default: []].insert(rowID)
        }
        return grouped.mapValues { Array($0) }
    }

    // MARK: - Annotation→Variant Cross-Reference

    /// Computes a bounding region from the current annotation search results.
    /// Only sets the region if all displayed annotations are on the same chromosome.
    private func updateAnnotationSearchRegion() {
        guard !displayedAnnotations.isEmpty else {
            annotationSearchRegion = nil
            return
        }

        // Only compute a meaningful region when filtering is active
        guard !annotationFilterText.isEmpty || visibleAnnotationTypes.count < availableAnnotationTypes.count else {
            annotationSearchRegion = nil
            return
        }

        // Group by chromosome, use the largest group
        var byChr: [String: (start: Int, end: Int)] = [:]
        for ann in displayedAnnotations {
            if let existing = byChr[ann.chromosome] {
                byChr[ann.chromosome] = (min(existing.start, ann.start), max(existing.end, ann.end))
            } else {
                byChr[ann.chromosome] = (ann.start, ann.end)
            }
        }

        // Pick the chromosome with the most annotations
        let primaryChr = byChr.max(by: { a, b in
            displayedAnnotations.filter { $0.chromosome == a.key }.count <
            displayedAnnotations.filter { $0.chromosome == b.key }.count
        })

        guard let chr = primaryChr else {
            annotationSearchRegion = nil
            return
        }

        annotationSearchRegion = (chromosome: chr.key, start: chr.value.start, end: chr.value.end)
    }

    @objc private func showOverlappingVariantsAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        selectedAnnotationRegion = (chromosome: result.chromosome, start: result.start, end: result.end)
        if activeTab == .variants {
            // Already on variants tab — just refresh with the new region
            updateDisplayedAnnotations()
        } else {
            switchToTab(.variants)
        }
    }

    // MARK: - Sample Tab Data

    /// Populates sample data from all variant database handles in the search index.
    private func populateSampleData(from index: AnnotationSearchIndex) {
        allSampleNames = []
        sampleMetadata = [:]
        sampleSourceFiles = [:]
        var metadataKeySet = Set<String>()

        for handle in index.variantDatabaseHandles {
            let db = handle.db
            let sourceName = (db.databaseURL.deletingPathExtension().lastPathComponent)
                .replacingOccurrences(of: "_variants", with: "")

            let samples = db.allSampleMetadata()
            for (name, metadata) in samples {
                if !allSampleNames.contains(name) {
                    allSampleNames.append(name)
                }
                sampleSourceFiles[name] = sourceName
                if !metadata.isEmpty {
                    sampleMetadata[name] = metadata
                    for key in metadata.keys {
                        metadataKeySet.insert(key)
                    }
                }
            }

            // If allSampleMetadata() returned empty, fall back to sampleNames()
            if samples.isEmpty {
                for name in db.sampleNames() {
                    if !allSampleNames.contains(name) {
                        allSampleNames.append(name)
                    }
                    sampleSourceFiles[name] = sourceName
                }
            }
        }

        sampleMetadataFields = metadataKeySet.sorted()
        if !hasSampleDisplayStateSeed {
            currentSampleDisplayState = SampleDisplayState()
        }
    }

    /// Updates the displayed samples list based on the current filter text and sample order.
    private func updateDisplayedSamples() {
        let query = parseSampleFilterText(sampleFilterText)
        let freeText = query.textFilter.lowercased()

        displayedSamples = resolvedSampleOrder().compactMap { name in
            let sourceFile = sampleSourceFiles[name] ?? ""
            let metadata = sampleMetadata[name] ?? [:]
            let isVisible = !currentSampleDisplayState.hiddenSamples.contains(name)

            // Apply text filter across name, source, and metadata values
            if !freeText.isEmpty {
                let searchText = ([name, sourceFile] + metadata.values).joined(separator: " ").lowercased()
                guard searchText.contains(freeText) else { return nil }
            }
            if let specificName = query.nameFilter, !name.localizedCaseInsensitiveContains(specificName) { return nil }
            if let source = query.sourceFilter, !sourceFile.localizedCaseInsensitiveContains(source) { return nil }
            if let expectedVisibility = query.visibility, expectedVisibility != isVisible { return nil }
            for (key, expectedValue) in query.metadataFilters {
                let actual = metadata[key] ?? metadata.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value ?? ""
                if !actual.localizedCaseInsensitiveContains(expectedValue) { return nil }
            }

            return SampleDisplayRow(name: name, sourceFile: sourceFile, isVisible: isVisible, metadata: metadata)
        }

        tableView.reloadData()
        scrollView.isHidden = false
        tooManyLabel.isHidden = true
        updateCountLabel()
    }

    /// Returns sample names in effective display order (persisted order + any new samples).
    private func resolvedSampleOrder() -> [String] {
        guard let order = currentSampleDisplayState.sampleOrder else { return allSampleNames }
        let allSet = Set(allSampleNames)
        var ordered = order.filter { allSet.contains($0) }
        let orderedSet = Set(ordered)
        ordered.append(contentsOf: allSampleNames.filter { !orderedSet.contains($0) })
        return ordered
    }

    /// Sorts a set of sample names by samples-tab column key.
    private func sortedSampleNames(key: String, ascending: Bool, names: [String]) -> [String] {
        names.sorted { nameA, nameB in
            let metaA = sampleMetadata[nameA] ?? [:]
            let metaB = sampleMetadata[nameB] ?? [:]
            let sourceA = sampleSourceFiles[nameA] ?? ""
            let sourceB = sampleSourceFiles[nameB] ?? ""
            let visibleA = !currentSampleDisplayState.hiddenSamples.contains(nameA)
            let visibleB = !currentSampleDisplayState.hiddenSamples.contains(nameB)
            let result: ComparisonResult
            switch key {
            case "visible":
                result = visibleA == visibleB ? .orderedSame : (visibleA ? .orderedAscending : .orderedDescending)
            case "sample_name":
                result = nameA.localizedCaseInsensitiveCompare(nameB)
            case "source_file":
                result = sourceA.localizedCaseInsensitiveCompare(sourceB)
            default:
                if key.hasPrefix("meta_") {
                    let metaKey = String(key.dropFirst(5))
                    let valA = metaA[metaKey] ?? ""
                    let valB = metaB[metaKey] ?? ""
                    result = valA.localizedCaseInsensitiveCompare(valB)
                } else {
                    result = .orderedSame
                }
            }
            if result == .orderedSame {
                return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    /// Creates a cell view for the samples tab.
    private func sampleCellView(for identifier: NSUserInterfaceItemIdentifier, row: Int) -> NSView? {
        guard row < displayedSamples.count else { return nil }
        let sample = displayedSamples[row]

        // Checkbox column for visibility
        if identifier == Self.sampleVisibleColumn {
            let checkboxId = NSUserInterfaceItemIdentifier("SampleCheckbox")
            let checkbox: NSButton
            if let existing = tableView.makeView(withIdentifier: checkboxId, owner: nil) as? NSButton {
                checkbox = existing
            } else {
                checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(sampleVisibilityToggled(_:)))
                checkbox.identifier = checkboxId
                checkbox.controlSize = .small
            }
            checkbox.state = sample.isVisible ? .on : .off
            checkbox.tag = row
            return checkbox
        }

        let isMetaColumn = identifier.rawValue.hasPrefix("meta_")

        // Text cell for all other columns
        let cellView: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let tf: NSTextField
            if isMetaColumn {
                // Editable text field for metadata columns
                tf = NSTextField(string: "")
                tf.isBordered = false
                tf.drawsBackground = false
                tf.focusRingType = .exterior
                tf.delegate = self
            } else {
                tf = NSTextField(labelWithString: "")
            }
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(tf)
            cellView.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        let tf = cellView.textField!
        tf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        switch identifier {
        case Self.sampleNameColumn:
            tf.stringValue = sample.name
            tf.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            tf.textColor = sample.isVisible ? .labelColor : .tertiaryLabelColor
        case Self.sampleSourceColumn:
            tf.stringValue = sample.sourceFile
            tf.font = .systemFont(ofSize: 11)
            tf.textColor = sample.isVisible ? .secondaryLabelColor : .tertiaryLabelColor
        default:
            // Dynamic metadata columns (identifier starts with "meta_")
            if isMetaColumn {
                let metaKey = String(identifier.rawValue.dropFirst(5))
                tf.stringValue = sample.metadata[metaKey] ?? ""
                tf.textColor = sample.isVisible ? .labelColor : .tertiaryLabelColor
                tf.placeholderString = "Click to edit"
                // Store row in tag for identification during editing
                tf.tag = row
            } else {
                tf.stringValue = ""
            }
        }

        return cellView
    }

    // MARK: - Sample Visibility

    @objc private func sampleVisibilityToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < displayedSamples.count else { return }
        let name = displayedSamples[row].name
        let isNowVisible = sender.state == .on

        displayedSamples[row].isVisible = isNowVisible

        if isNowVisible {
            currentSampleDisplayState.hiddenSamples.remove(name)
        } else {
            currentSampleDisplayState.hiddenSamples.insert(name)
        }

        // Refresh the row to update text dimming
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))

        postSampleDisplayStateChange()
        updateCountLabel()
    }

    private func postSampleDisplayStateChange() {
        hasSampleDisplayStateSeed = true
        NotificationCenter.default.post(
            name: .sampleDisplayStateChanged,
            object: self,
            userInfo: [NotificationUserInfoKey.sampleDisplayState: currentSampleDisplayState]
        )
    }

    @objc private func handleSampleDisplayStateChanged(_ notification: Notification) {
        // Ignore if we are the source
        if notification.object as AnyObject? === self { return }
        guard let state = notification.userInfo?[NotificationUserInfoKey.sampleDisplayState] as? SampleDisplayState else { return }
        currentSampleDisplayState = state
        hasSampleDisplayStateSeed = true
        if activeTab == .samples {
            updateDisplayedSamples()
        }
    }

    // MARK: - Sample Context Menu Actions

    @objc private func showAllSamplesAction(_ sender: NSMenuItem) {
        currentSampleDisplayState.hiddenSamples.removeAll()
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc private func hideAllSamplesAction(_ sender: NSMenuItem) {
        currentSampleDisplayState.hiddenSamples = Set(allSampleNames)
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc private func toggleSampleVisibilityAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if currentSampleDisplayState.hiddenSamples.contains(name) {
            currentSampleDisplayState.hiddenSamples.remove(name)
        } else {
            currentSampleDisplayState.hiddenSamples.insert(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc private func copySampleNameAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
    }

    private func buildSampleContextMenu(_ menu: NSMenu, row: Int) {
        let sample = displayedSamples[row]
        let selectedRows = tableView.selectedRowIndexes
        let hasMultiSelection = selectedRows.count > 1

        // Visibility toggle for clicked row
        let visTitle = sample.isVisible ? "Hide \(sample.name)" : "Show \(sample.name)"
        let visItem = NSMenuItem(title: visTitle, action: #selector(toggleSampleVisibilityAction(_:)), keyEquivalent: "")
        visItem.target = self
        visItem.representedObject = sample.name
        menu.addItem(visItem)

        // Multi-selection visibility actions
        if hasMultiSelection {
            menu.addItem(NSMenuItem.separator())

            let hideSelectedItem = NSMenuItem(title: "Hide Selected (\(selectedRows.count))", action: #selector(hideSelectedSamplesAction(_:)), keyEquivalent: "")
            hideSelectedItem.target = self
            menu.addItem(hideSelectedItem)

            let showSelectedItem = NSMenuItem(title: "Show Selected (\(selectedRows.count))", action: #selector(showSelectedSamplesAction(_:)), keyEquivalent: "")
            showSelectedItem.target = self
            menu.addItem(showSelectedItem)

            let showOnlyItem = NSMenuItem(title: "Show Only Selected", action: #selector(showOnlySelectedSamplesAction(_:)), keyEquivalent: "")
            showOnlyItem.target = self
            menu.addItem(showOnlyItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Show All / Hide All
        let showAllItem = NSMenuItem(title: "Show All Samples", action: #selector(showAllSamplesAction(_:)), keyEquivalent: "")
        showAllItem.target = self
        menu.addItem(showAllItem)

        let hideAllItem = NSMenuItem(title: "Hide All Samples", action: #selector(hideAllSamplesAction(_:)), keyEquivalent: "")
        hideAllItem.target = self
        menu.addItem(hideAllItem)

        menu.addItem(NSMenuItem.separator())

        // Copy name
        let copyItem = NSMenuItem(title: "Copy Sample Name", action: #selector(copySampleNameAction(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = sample.name
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())

        // Import metadata
        let importItem = NSMenuItem(title: "Import Metadata\u{2026}", action: #selector(importMetadataAction(_:)), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let templateItem = NSMenuItem(title: "Download Template\u{2026}", action: #selector(downloadSampleTemplateAction(_:)), keyEquivalent: "")
        templateItem.target = self
        menu.addItem(templateItem)

        // Add custom field
        let addFieldItem = NSMenuItem(title: "Add Field\u{2026}", action: #selector(addCustomFieldAction(_:)), keyEquivalent: "")
        addFieldItem.target = self
        menu.addItem(addFieldItem)
    }

    private func buildSampleGlobalContextMenu(_ menu: NSMenu) {
        let showAllItem = NSMenuItem(title: "Show All Samples", action: #selector(showAllSamplesAction(_:)), keyEquivalent: "")
        showAllItem.target = self
        menu.addItem(showAllItem)

        let hideAllItem = NSMenuItem(title: "Hide All Samples", action: #selector(hideAllSamplesAction(_:)), keyEquivalent: "")
        hideAllItem.target = self
        menu.addItem(hideAllItem)

        menu.addItem(NSMenuItem.separator())

        let importItem = NSMenuItem(title: "Import Metadata\u{2026}", action: #selector(importMetadataAction(_:)), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let templateItem = NSMenuItem(title: "Download Template\u{2026}", action: #selector(downloadSampleTemplateAction(_:)), keyEquivalent: "")
        templateItem.target = self
        menu.addItem(templateItem)

        let addFieldItem = NSMenuItem(title: "Add Field\u{2026}", action: #selector(addCustomFieldAction(_:)), keyEquivalent: "")
        addFieldItem.target = self
        menu.addItem(addFieldItem)
    }

    // MARK: - Multi-Selection Visibility Actions

    @objc private func hideSelectedSamplesAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        for row in selectedRows {
            guard row < displayedSamples.count else { continue }
            let name = displayedSamples[row].name
            currentSampleDisplayState.hiddenSamples.insert(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc private func showSelectedSamplesAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        for row in selectedRows {
            guard row < displayedSamples.count else { continue }
            let name = displayedSamples[row].name
            currentSampleDisplayState.hiddenSamples.remove(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc private func showOnlySelectedSamplesAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        var selectedNames = Set<String>()
        for row in selectedRows {
            guard row < displayedSamples.count else { continue }
            selectedNames.insert(displayedSamples[row].name)
        }
        currentSampleDisplayState.hiddenSamples = Set(allSampleNames.filter { !selectedNames.contains($0) })
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    // MARK: - Import Metadata

    @objc private func downloadSampleTemplateAction(_ sender: Any?) {
        guard !allSampleNames.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Save Sample Metadata Template"
        panel.prompt = "Save Template"
        panel.nameFieldStringValue = "sample-metadata-template.tsv"
        panel.allowedContentTypes = [
            .init(filenameExtension: "tsv")!,
            .init(filenameExtension: "csv")!,
        ]

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let isCSV = url.pathExtension.lowercased() == "csv"
            let delimiter = isCSV ? "," : "\t"

            var columns = ["sample_name"]
            columns.append(contentsOf: self.sampleMetadataFields)
            let header = columns.joined(separator: delimiter)
            let rows = self.allSampleNames.map { name -> String in
                var values = [name]
                values.append(contentsOf: Array(repeating: "", count: self.sampleMetadataFields.count))
                return values.joined(separator: delimiter)
            }
            let content = ([header] + rows).joined(separator: "\n") + "\n"

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                drawerLogger.error("downloadSampleTemplateAction: \(error.localizedDescription)")
            }
        }
    }

    @objc private func importMetadataAction(_ sender: NSMenuItem) {
        guard let searchIndex else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "tsv")!,
            .init(filenameExtension: "csv")!,
            .init(filenameExtension: "txt")!,
        ]
        panel.message = "Select a TSV or CSV file with sample metadata"
        panel.prompt = "Import"

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let fileURL = panel.url else { return }
            let ext = fileURL.pathExtension.lowercased()
            let format: MetadataFormat = ext == "csv" ? .csv : .tsv

            var totalUpdated = 0
            for handle in searchIndex.variantDatabaseHandles {
                do {
                    let rwDB = try VariantDatabase(url: handle.db.databaseURL, readWrite: true)
                    let count = try rwDB.importSampleMetadata(from: fileURL, format: format)
                    totalUpdated += count
                } catch {
                    drawerLogger.warning("importSampleMetadata: \(error.localizedDescription)")
                }
            }

            drawerLogger.info("importSampleMetadata: Updated \(totalUpdated) samples from \(fileURL.lastPathComponent)")
            self.populateSampleData(from: searchIndex)
            self.configureColumnsForTab(.samples)
            self.updateDisplayedSamples()
        }
    }

    // MARK: - Add Custom Field

    @objc private func addCustomFieldAction(_ sender: Any) {
        let alert = NSAlert()
        alert.messageText = "Add Custom Field"
        alert.informativeText = "Enter a name for the new metadata field:"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "Field name"
        alert.accessoryView = textField

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let fieldName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fieldName.isEmpty else { return }
            guard !self.sampleMetadataFields.contains(fieldName) else { return }

            self.sampleMetadataFields.append(fieldName)
            self.sampleMetadataFields.sort()
            self.configureColumnsForTab(.samples)
            self.updateDisplayedSamples()
        }
    }

    // MARK: - Inline Metadata Editing

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard activeTab == .samples,
              let tf = notification.object as? NSTextField,
              let cellView = tf.superview as? NSTableCellView else { return }

        let column = tableView.column(for: cellView)
        guard column >= 0, column < tableView.tableColumns.count else { return }

        let row = tf.tag
        guard row >= 0, row < displayedSamples.count else { return }

        let columnId = tableView.tableColumns[column].identifier.rawValue
        guard columnId.hasPrefix("meta_") else { return }

        let metaKey = String(columnId.dropFirst(5))
        let newValue = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sampleName = displayedSamples[row].name

        // Update local model
        if newValue.isEmpty {
            displayedSamples[row].metadata.removeValue(forKey: metaKey)
        } else {
            displayedSamples[row].metadata[metaKey] = newValue
        }
        // Keep backing metadata cache in sync so refresh/sort/filter preserves edits.
        sampleMetadata[sampleName] = displayedSamples[row].metadata

        // Persist to database
        guard let searchIndex else { return }
        let fullMetadata = displayedSamples[row].metadata

        for handle in searchIndex.variantDatabaseHandles {
            do {
                let rwDB = try VariantDatabase(url: handle.db.databaseURL, readWrite: true)
                try rwDB.updateSampleMetadata(name: sampleName, metadata: fullMetadata)
            } catch {
                drawerLogger.warning("Inline metadata edit failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Sample Drag-and-Drop Reordering

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard activeTab == .samples, row < displayedSamples.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: .string)
        return item
    }

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard activeTab == .samples else { return [] }
        if dropOperation == .above {
            return .move
        }
        return []
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard activeTab == .samples else { return false }

        // Collect dragged row indices
        var draggedRows = IndexSet()
        info.enumerateDraggingItems(
            options: [],
            for: tableView,
            classes: [NSPasteboardItem.self],
            searchOptions: [:]
        ) { item, _, _ in
            if let pbItem = item.item as? NSPasteboardItem,
               let rowStr = pbItem.string(forType: .string),
               let sourceRow = Int(rowStr) {
                draggedRows.insert(sourceRow)
            }
        }

        guard !draggedRows.isEmpty else { return false }

        // Collect the dragged items in order
        let draggedItems = draggedRows.sorted().compactMap { idx -> SampleDisplayRow? in
            guard idx < displayedSamples.count else { return nil }
            return displayedSamples[idx]
        }
        let draggedNames = draggedItems.map(\.name)
        let draggedNameSet = Set(draggedNames)

        let fullOrder = resolvedSampleOrder()
        var reordered = fullOrder.filter { !draggedNameSet.contains($0) }

        // Insert relative to visible rows, but apply to full ordering.
        let insertionIndex: Int
        if row >= displayedSamples.count {
            insertionIndex = reordered.count
        } else {
            let anchorName = displayedSamples[row].name
            insertionIndex = reordered.firstIndex(of: anchorName) ?? reordered.count
        }
        reordered.insert(contentsOf: draggedNames, at: insertionIndex)

        // Persist explicit full order, including currently non-visible samples.
        allSampleNames = reordered

        // Update display state with new order
        currentSampleDisplayState.sampleOrder = allSampleNames
        postSampleDisplayStateChange()
        updateDisplayedSamples()
        return true
    }
}
