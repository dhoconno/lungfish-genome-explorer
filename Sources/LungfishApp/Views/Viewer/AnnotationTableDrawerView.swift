// AnnotationTableDrawerView.swift - Geneious-style bottom annotation drawer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import os.log

/// Logger for annotation drawer operations
private let drawerLogger = Logger(subsystem: LogSubsystem.app, category: "AnnotationDrawer")

// MARK: - WideColumnDividerHeaderView

/// Custom header view that expands the column-resize grab zone from ~3px to 8px each side.
private final class WideColumnDividerHeaderView: NSTableHeaderView {
    private let expandedHitZone: CGFloat = 8

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let dividerX = nearestColumnDivider(at: location.x) {
            let adjusted = NSPoint(x: dividerX, y: location.y)
            if let adjustedEvent = NSEvent.mouseEvent(
                with: event.type,
                location: convert(adjusted, to: nil),
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
            ) {
                super.mouseDown(with: adjustedEvent)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tableView else { return }
        for i in 0..<tableView.numberOfColumns {
            let rect = headerRect(ofColumn: i)
            let cursorRect = NSRect(
                x: rect.maxX - expandedHitZone,
                y: 0,
                width: expandedHitZone * 2,
                height: bounds.height
            )
            addCursorRect(cursorRect, cursor: .resizeLeftRight)
        }
    }

    private func nearestColumnDivider(at x: CGFloat) -> CGFloat? {
        guard let tableView else { return nil }
        for i in 0..<tableView.numberOfColumns {
            let dividerX = headerRect(ofColumn: i).maxX
            if abs(x - dividerX) <= expandedHitZone {
                return dividerX
            }
        }
        return nil
    }
}

// MARK: - DrawerDividerView

/// Drag handle at the top of the annotation drawer for resizing.
final class DrawerDividerView: NSView {
    weak var drawerDelegate: AnnotationTableDrawerDelegate?
    private var dragStartY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Annotation table drawer resize handle")
        setAccessibilityIdentifier("annotation-table-drawer-divider")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        // Subtle grip indicator
        let cx = bounds.midX
        let cy = bounds.midY
        NSColor.tertiaryLabelColor.setFill()
        for offset: CGFloat in [-2, 0, 2] {
            NSBezierPath.fill(NSRect(x: cx - 10, y: cy + offset, width: 20, height: 0.5))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = NSEvent.mouseLocation.y
    }

    override func mouseDragged(with event: NSEvent) {
        let currentY = NSEvent.mouseLocation.y
        let delta = currentY - dragStartY
        dragStartY = currentY
        if let drawer = superview as? AnnotationTableDrawerView {
            drawer.delegate?.annotationDrawerDidDragDivider(drawer, deltaY: delta)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let drawer = superview as? AnnotationTableDrawerView {
            drawer.delegate?.annotationDrawerDidFinishDraggingDivider(drawer)
        }
    }
}

// MARK: - AnnotationTableDrawerDelegate

struct AnnotationTableDrawerSelectionRegion: Equatable, Sendable {
    let chromosome: String
    let start: Int
    let end: Int
}

struct AnnotationTrackDisplayState: Equatable, Sendable {
    let order: [String]
    let hiddenTrackIDs: Set<String>
    let displayNames: [String: String]

    init(order: [String], hiddenTrackIDs: Set<String> = [], displayNames: [String: String] = [:]) {
        self.order = order
        self.hiddenTrackIDs = hiddenTrackIDs
        self.displayNames = displayNames
    }
}

enum AnnotationTrackMoveDirection {
    case up
    case down
}

/// Delegate protocol for annotation table selection events.
@MainActor
protocol AnnotationTableDrawerDelegate: AnyObject {
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestExtract annotations: [SequenceAnnotation])
    func annotationDrawerSelectedSequenceRegion(_ drawer: AnnotationTableDrawerView) -> AnnotationTableDrawerSelectionRegion?
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didResolveGeneRegions regions: [GeneRegion])
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleVariantRenderKeys keys: Set<String>?)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleAnnotationRenderKeys keys: Set<String>?)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateAnnotationTrackDisplayState state: AnnotationTrackDisplayState)
    func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat)
    func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView)
    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        fallbackConsequenceFor result: AnnotationSearchIndex.SearchResult
    ) -> (consequence: String?, aaChange: String?)
}

extension AnnotationTableDrawerDelegate {
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestExtract annotations: [SequenceAnnotation]) {}

    func annotationDrawerSelectedSequenceRegion(_ drawer: AnnotationTableDrawerView) -> AnnotationTableDrawerSelectionRegion? {
        nil
    }

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleAnnotationRenderKeys keys: Set<String>?) {}

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateAnnotationTrackDisplayState state: AnnotationTrackDisplayState) {}

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        fallbackConsequenceFor result: AnnotationSearchIndex.SearchResult
    ) -> (consequence: String?, aaChange: String?) {
        (nil, nil)
    }
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

    private static func defaultSampleDisplayState() -> SampleDisplayState {
        var state = SampleDisplayState()
        state.colorThemeName = AppSettings.shared.variantColorThemeName
        return state
    }

    // MARK: - Types

    enum VariantToolbarDensity: Equatable {
        case full
        case compact
        case minimal
    }

    static func variantToolbarDensity(forWidth width: CGFloat) -> VariantToolbarDensity {
        if width < 560 { return .minimal }
        if width < 760 { return .compact }
        return .full
    }

    /// The active tab in the drawer.
    enum DrawerTab: Int {
        case annotations = 0
        case variants = 1
        case samples = 2

        /// Persistence key for column preferences.
        var prefsKey: String {
            switch self {
            case .annotations: return "annotations"
            case .variants: return "variantCalls"
            case .samples: return "samples"
            }
        }
    }

    /// A single row in the samples tab display.
    struct SampleDisplayRow {
        let rowKey: String
        let name: String
        let sourceFile: String
        var isVisible: Bool
        var metadata: [String: String]
        var displayName: String?
    }

    // MARK: - Properties

    weak var delegate: AnnotationTableDrawerDelegate?

    /// Reference to the search index for direct SQL queries.
    private(set) var searchIndex: AnnotationSearchIndex?
    private var appliedVariantToolbarDensity: VariantToolbarDensity?

    /// The currently active tab.
    private(set) var activeTab: DrawerTab = .annotations

    /// Active subtab within the Variants tab (Calls vs Genotypes).
    var activeVariantSubtab: VariantSubtab = .calls

    /// Displayed genotype rows (genotype subtab).
    var displayedGenotypes: [GenotypeDisplayRow] = []
    /// Base genotype rows before local column filters.
    var baseDisplayedGenotypes: [GenotypeDisplayRow] = []

    /// Generation counter for stale genotype fetch prevention.
    var genotypeFetchGeneration: Int = 0

    /// Total annotation count in the database (annotation tab only).
    private var totalAnnotationCount: Int = 0

    /// Total variant count in the database (variant tab only).
    private var totalVariantCount: Int = 0

    /// Filtered and displayed annotations/variants.
    var displayedAnnotations: [AnnotationSearchIndex.SearchResult] = []

    /// Per-tab filter text so each tab preserves its own search state.
    private var annotationFilterText: String = ""
    var variantFilterText: String = ""
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
    var infoColumnKeys: [(key: String, type: String, description: String)] = []
    /// Annotation attribute keys discovered from loaded annotation rows.
    var annotationAttributeColumnKeys: [String] = []
    /// Preset INFO values used to render variant filter chips (key -> values).
    private var variantInfoPresetValues: [(key: String, values: [String])] = []
    private enum VariantPresetLoadState {
        case idle
        case loading
        case loaded
    }
    private var variantPresetLoadState: VariantPresetLoadState = .idle
    private var variantTrackDatabaseURLs: [URL] = []
    /// Maps reference chromosome names to variant DB chromosome names (from contig length matching).
    var variantChromosomeAliasMap: [String: String] = [:]
    /// Pre-computed SmartToken counts from cache warming.
    private var smartTokenCounts: [String: Int] = [:]
    /// Active preset-chip selections (single selected value per INFO key).
    private var selectedVariantPresetByKey: [String: String] = [:]
    /// Whether preset chips are expanded in the variants tab.
    private var showVariantPresetChips: Bool = false

    /// True if the variant data comes from a haploid organism (virus/bacteria).
    /// Enables within-sample frequency smart tokens and related UI.
    var isHaploidOrganism: Bool = false

    /// Whether to auto-sync variant table with viewport (when variants tab is active).
    private(set) var viewportSyncEnabled: Bool = true

    private enum HaploidModeSelection: String {
        case auto
        case haploid
        case diploid
    }

    /// User-selected haploid-mode behavior (defaults to automatic detection).
    private var haploidModeSelection: HaploidModeSelection = .auto

    /// Current viewport region for auto-sync (set by viewer notification).
    private var viewportRegion: (chromosome: String, start: Int, end: Int)?

    /// Debounce work item for viewport sync to avoid thrashing during rapid panning.
    private var viewportSyncWorkItem: DispatchWorkItem?

    /// Debounce work item for variant queries to collapse rapid filter/scope changes.
    private var variantQueryWorkItem: DispatchWorkItem?

    /// Cooperative cancellation token for currently running background variant query.
    private var activeVariantQueryCancelToken: VariantQueryCancellationToken?

    /// Optional source object to scope viewport sync notifications to a single viewer.
    private weak var viewportSyncSourceObject: AnyObject?

    /// Stable source identifier for viewport sync scoping (survives weak-reference timing races).
    private var viewportSyncSourceIdentifier: ObjectIdentifier?

    // MARK: - Annotation→Variant Cross-Reference

    /// Bounding region from current annotation search results (union of all annotation regions on the same chromosome).
    private var annotationSearchRegion: (chromosome: String, start: Int, end: Int)?

    /// Specific annotation region selected by the user (e.g., via "Show Overlapping Variants").
    private var selectedAnnotationRegion: (chromosome: String, start: Int, end: Int)?

    /// When enabled, the sequence viewport renders only annotation rows visible in this table.
    private var annotationViewportFilterEnabled = false
    private var annotationTrackOrder: [String] = []
    private var hiddenAnnotationTrackIDs: Set<String> = []
    private var annotationTrackDisplayNames: [String: String] = [:]
    private var lastEmittedAnnotationTrackDisplayState: AnnotationTrackDisplayState?

    // MARK: - Sample Tab State

    /// All sample names from variant databases.
    private var allSampleNames: [String] = []
    /// Compound sample row keys (sample + source) used for samples-tab display.
    private var allSampleRowKeys: [String] = []
    /// Resolves a compound row key to the canonical sample name.
    private var sampleNameByRowKey: [String: String] = [:]

    /// Per-sample metadata dictionaries.
    private var sampleMetadata: [String: [String: String]] = [:]

    /// Source file/track per sample.
    private var sampleSourceFiles: [String: String] = [:]

    /// Display name overrides per sample (keyed by row key).
    private var sampleDisplayNamesCache: [String: String] = [:]

    /// Available metadata field names (union of all sample metadata keys).
    private var sampleMetadataFields: [String] = []

    /// Filtered and displayed samples for the samples tab.
    var displayedSamples: [SampleDisplayRow] = []

    /// Active quick-filter tokens for the samples tab.
    private var activeSampleTokens: Set<SampleSmartToken> = []
    /// Optional currently-selected sample-group preset.
    private var selectedSampleGroupId: UUID?
    /// Snapshot of manual hidden-sample state before query-driven show-only filtering.
    private var sampleFilterBaselineHiddenSamples: Set<String>?

    /// Local copy of sample display state for driving visibility toggles.
    var currentSampleDisplayState: SampleDisplayState = {
        AnnotationTableDrawerView.defaultSampleDisplayState()
    }()

    /// Whether we have received an authoritative sample display state from viewer/inspector.
    private var hasSampleDisplayStateSeed = false

    /// Scope of the last variant query, for status label display.
    private enum VariantQueryScope {
        case global
        case chromosome
        case viewport
        case annotations
        case annotation
        case placeholder
    }

    /// Database size threshold (1 GB) above which filtered queries are automatically
    /// scoped to the current chromosome for performance.
    private static let chromosomeScopeThreshold: UInt64 = 1_000_000_000
    /// Database size threshold (25 GB) above which only pre-materialized token paths
    /// are allowed for variant filtering to keep interactions responsive.
    private static let materializedOnlyThreshold: UInt64 = 25_000_000_000

    /// Last variant query match count used for status labeling (especially capped result sets).
    private var lastVariantQueryMatchCount: Int?

    /// Last variant query scope for status labeling.
    private var lastVariantQueryScope: VariantQueryScope = .global

    /// Generation counter for variant queries (prevents stale results from overwriting newer ones).
    private var variantQueryGeneration: Int = 0

    /// Whether a variant query is currently in progress on a background thread.
    private(set) var isVariantQuerying: Bool = false

    /// Cached global results for the last filter-driven variant query.
    /// Used to make viewport exploration fast without re-running genome-wide SQL.
    private var cachedGlobalFilteredVariantRows: [AnnotationSearchIndex.SearchResult] = []
    private var cachedGlobalFilteredVariantKey: VariantQueryCacheKey?
    /// Controls whether viewport narrowing is applied on top of cached global filtered results.
    /// This remains false right after query/token changes (show global hits first), and flips
    /// to true during pan/zoom exploration.
    private var allowViewportPostFilterDuringExploration: Bool = false
    /// Viewport snapshot captured when filter/query state last changed.
    /// Viewport narrowing is armed only after the viewport moves away from this snapshot.
    private var viewportRegionAtLastFilterMutation: (chromosome: String, start: Int, end: Int)?

    #if DEBUG
    private var debugVariantQueryExecutionCount: Int = 0
    #endif

    // MARK: - UI Components

    private let scrollView = NSScrollView()
    let tableView = NSTableView()
    private let annotationFilterField = NSSearchField()
    private let variantFilterField = NSSearchField()
    private let sampleFilterField = NSSearchField()
    private let sampleQueryBuilderButton = NSButton()
    private let clearSampleFilterButton = NSButton()
    private let sampleGroupPresetButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let addSampleFieldButton = NSButton()
    private let sampleGroupsButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let headerBar = NSView()
    private let searchBar = NSView()
    private let searchHintLabel = NSTextField(labelWithString: "")
    private let chipBar = NSView()
    private let chipSummaryLabel = NSTextField(labelWithString: "")
    private let chipScrollView = NSScrollView()
    private let chipStackView = NSStackView()
    private let dragHandle = DrawerDividerView()
    private let tabControl = NSSegmentedControl()
    private let loadingIndicator = NSProgressIndicator()
    private let tooManyLabel = NSTextField(wrappingLabelWithString: "")
    private let allTypesButton = NSButton()
    private let noneTypesButton = NSButton()
    private let annotationViewportFilterButton = NSButton()
    private let annotationTracksButton = NSButton()
    private let presetFiltersToggleButton = NSButton()
    private let searchBuilderButton = NSButton()
    private let localVariantFilterBadgeLabel = NSTextField(labelWithString: "Local: Visible Rows")
    private let clearFilterButton = NSButton()
    private let downloadTemplateButton = NSButton()
    private let importMetadataButton = NSButton()
    let exportButton = NSButton()
    let autoSizeColumnsButton = NSButton()
    let columnConfigButton = NSButton()
    let profileButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let variantSubtabControl = NSSegmentedControl()
    private let scopeControl = NSSegmentedControl()
    private let haploidModeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let queryProgressBar = NSProgressIndicator()
    private let queryProgressLabel = NSTextField(labelWithString: "")

    /// Maximum number of annotations to display in the table.
    /// Beyond this, user must filter to narrow down results.
    private static var maxDisplayCount: Int { AppSettings.shared.maxTableDisplayCount }
    /// Maximum rows sampled when estimating content width for auto-size.
    private static let autoSizeRowSampleLimit: Int = 500
    /// Above this visible-row count, per-row fallback consequence inference is deferred.
    private static let consequenceComputationRowLimit: Int = 4_000
    private static let deferredConsequenceText = "Too many variants to compute (zoom in)"
    private static let deferredAAChangeText = "Zoom in to compute"
    private static let variantQueryDebounceInterval: TimeInterval = 0.12

    private enum SampleSmartToken: String, CaseIterable {
        case visibleOnly
        case hiddenOnly
        case hasSource
        case missingSource

        var label: String {
            switch self {
            case .visibleOnly: return "Visible"
            case .hiddenOnly: return "Hidden"
            case .hasSource: return "Has Source"
            case .missingSource: return "Missing Source"
            }
        }

        var exclusivityGroupKey: String? {
            switch self {
            case .visibleOnly, .hiddenOnly:
                return "visibility"
            case .hasSource, .missingSource:
                return "source"
            }
        }
    }

    private struct VariantQueryCacheKey: Equatable {
        let filterText: String
        let tokens: [String]
        let presets: [String]
        let typeFilter: [String]
        let explicitTypeFilter: [String]
        let infoFilters: [String]
        let filterValue: String?
        let minQuality: Double?
        let minQualityInclusive: Bool
        let maxQuality: Double?
        let maxQualityInclusive: Bool
        let minSampleCount: Int?
        let minSampleCountInclusive: Bool
        let maxSampleCount: Int?
        let maxSampleCountInclusive: Bool
        let nameFilter: String
        let geneList: [String]
        let selectedSamples: [String]
    }

    /// Chip buttons keyed by type name.
    private var chipButtons: [String: NSButton] = [:]
    /// Chip buttons keyed by `INFO_KEY\tINFO_VALUE` for variant preset filters.
    private var variantPresetChipButtons: [String: NSButton] = [:]
    /// Payload lookup for preset chip buttons (button identity -> key/value).
    private var variantPresetChipPayloads: [ObjectIdentifier: (key: String, value: String)] = [:]
    /// Payload lookup for "More..." preset buttons (button identity -> INFO key).
    private var variantPresetMorePayloads: [ObjectIdentifier: String] = [:]
    /// Active smart filter tokens for the variant tab.
    private var activeSmartTokens: Set<SmartToken> = []
    /// Smart token raw values that are materialized and ready across all variant tracks.
    private var materializedTokenNamesAcrossTracks: Set<String> = []
    /// Smart token chip buttons keyed by token case.
    private var smartTokenButtons: [SmartToken: NSButton] = [:]
    /// Reverse lookup: button identity -> SmartToken.
    private var smartTokenPayloads: [ObjectIdentifier: SmartToken] = [:]
    /// Smart token chip buttons keyed by sample token case.
    private var sampleTokenButtons: [SampleSmartToken: NSButton] = [:]
    /// Reverse lookup: button identity -> SampleSmartToken.
    private var sampleTokenPayloads: [ObjectIdentifier: SampleSmartToken] = [:]
    /// Bookmarked variant keys (`trackId:variantRowId`) for star column display.
    var bookmarkedVariantKeys: Set<String> = []
    /// Base annotation result set before local column filters.
    var baseDisplayedAnnotationRows: [AnnotationSearchIndex.SearchResult] = []
    /// Header-driven filters applied to annotation rows.
    private var annotationColumnFilterClauses: [ColumnFilterClause] = []
    /// Base result set from the last variant SQL query before local column filters.
    var baseDisplayedVariantAnnotations: [AnnotationSearchIndex.SearchResult] = []
    /// Header-driven local filters applied only to currently loaded variant rows.
    private var variantColumnFilterClauses: [VariantColumnFilterClause] = []
    /// Header-driven local filters applied only to currently loaded genotype rows.
    var genotypeColumnFilterClauses: [VariantColumnFilterClause] = []
    /// Cache for delegate-provided fallback consequence/AA strings per variant row key.
    private var fallbackConsequenceCache: [String: (consequence: String?, aaChange: String?)] = [:]
    /// Last local variant key set emitted to the viewer for viewport render syncing.
    private var lastEmittedVisibleVariantRenderKeys: Set<String>?
    /// Last local annotation key set emitted to the viewer for viewport render syncing.
    private var lastEmittedVisibleAnnotationRenderKeys: Set<String>?
    /// Column configuration popover (gear menu).
    var columnConfigPopover: NSPopover?

    // Annotation column identifiers (internal for extension access)
    static let nameColumn = NSUserInterfaceItemIdentifier("NameColumn")
    static let typeColumn = NSUserInterfaceItemIdentifier("TypeColumn")
    static let chromosomeColumn = NSUserInterfaceItemIdentifier("ChromosomeColumn")
    static let startColumn = NSUserInterfaceItemIdentifier("StartColumn")
    static let endColumn = NSUserInterfaceItemIdentifier("EndColumn")
    static let sizeColumn = NSUserInterfaceItemIdentifier("SizeColumn")
    static let strandColumn = NSUserInterfaceItemIdentifier("StrandColumn")

    // Variant column identifiers (internal for extension access)
    static let variantIdColumn = NSUserInterfaceItemIdentifier("VariantIdColumn")
    static let variantTypeColumn = NSUserInterfaceItemIdentifier("VariantTypeColumn")
    static let variantChromColumn = NSUserInterfaceItemIdentifier("VariantChromColumn")
    static let positionColumn = NSUserInterfaceItemIdentifier("PositionColumn")
    static let refColumn = NSUserInterfaceItemIdentifier("RefColumn")
    static let altColumn = NSUserInterfaceItemIdentifier("AltColumn")
    static let qualityColumn = NSUserInterfaceItemIdentifier("QualityColumn")
    static let filterColumn = NSUserInterfaceItemIdentifier("FilterColumn")
    static let samplesColumn = NSUserInterfaceItemIdentifier("SamplesColumn")
    static let sourceColumn = NSUserInterfaceItemIdentifier("SourceColumn")
    static let consequenceColumn = NSUserInterfaceItemIdentifier("ConsequenceColumn")
    static let aaChangeColumn = NSUserInterfaceItemIdentifier("AAChangeColumn")

    // Sample column identifiers (internal for extension access)
    static let sampleVisibleColumn = NSUserInterfaceItemIdentifier("SampleVisibleColumn")
    static let sampleNameColumn = NSUserInterfaceItemIdentifier("SampleNameColumn")
    static let sampleDisplayNameColumn = NSUserInterfaceItemIdentifier("SampleDisplayNameColumn")
    static let sampleSourceColumn = NSUserInterfaceItemIdentifier("SampleSourceColumn")

    /// Number formatter for genomic coordinates.
    let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    /// Whether the drawer should expose mutating annotation actions in its context menu.
    ///
    /// Native reference bundles use the database-backed editing path. Other callers can
    /// provide read-only, in-memory annotation rows while retaining search, filters,
    /// sorting, selection, copy, and extraction behaviors.
    var allowsAnnotationEditing = true

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    public override func layout() {
        super.layout()
        updateVariantToolbarDensity()
    }

    // MARK: - Setup

    private func setupView() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Drag handle bar at top (resizable divider)
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragHandle)

        // Header bar with tab controls (row 1)
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        // Search bar with tab-specific filter + advanced hint (row 2)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchBar)

        // Filter search fields (tab-specific, only one visible at a time)
        configureSearchField(
            annotationFilterField,
            placeholder: "Annotations: text=geneX; type=gene; chr=NC_...; region=NC_...:start-end",
            accessibilityLabel: "Filter annotations"
        )
        configureSearchField(
            variantFilterField,
            placeholder: "Variants: text=rs; type=SNV; chr=NC_...; pos=100-200; qual>=30; samples>=2; DP>=20",
            accessibilityLabel: "Filter variants"
        )
        configureSearchField(
            sampleFilterField,
            placeholder: "text~foo; visible=true; source~track; meta.Country=USA",
            accessibilityLabel: "Filter samples"
        )
        searchBar.addSubview(annotationFilterField)
        searchBar.addSubview(variantFilterField)
        searchBar.addSubview(sampleFilterField)

        // Variant subtab control (Calls | Genotypes) — lives in header bar, visible only on Variants tab
        variantSubtabControl.segmentCount = 2
        variantSubtabControl.setLabel("Calls", forSegment: 0)
        variantSubtabControl.setLabel("Genotypes", forSegment: 1)
        variantSubtabControl.setWidth(55, forSegment: 0)
        variantSubtabControl.setWidth(75, forSegment: 1)
        variantSubtabControl.selectedSegment = 0
        variantSubtabControl.segmentStyle = .capsule
        variantSubtabControl.controlSize = .small
        variantSubtabControl.font = .systemFont(ofSize: 10)
        variantSubtabControl.target = self
        variantSubtabControl.action = #selector(variantSubtabChanged(_:))
        variantSubtabControl.translatesAutoresizingMaskIntoConstraints = false
        variantSubtabControl.isHidden = true
        variantSubtabControl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        searchBar.addSubview(variantSubtabControl)

        // Scope segmented control (Region | Genome) — visible only on Variants tab
        scopeControl.segmentCount = 2
        scopeControl.setLabel("Region", forSegment: 0)
        scopeControl.setLabel("Genome", forSegment: 1)
        scopeControl.setWidth(62, forSegment: 0)
        scopeControl.setWidth(66, forSegment: 1)
        scopeControl.selectedSegment = 0
        scopeControl.segmentStyle = .rounded
        scopeControl.controlSize = .small
        scopeControl.font = .systemFont(ofSize: 10, weight: .medium)
        scopeControl.target = self
        scopeControl.action = #selector(scopeSegmentChanged(_:))
        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        scopeControl.toolTip = "Choose whether variants follow the visible region or query the whole genome"
        scopeControl.setAccessibilityLabel("Variant query scope")
        scopeControl.isHidden = true
        searchBar.addSubview(scopeControl)

        // Haploid mode control (Auto/Haploid/Diploid) — visible only on Variants tab
        haploidModeButton.controlSize = .small
        haploidModeButton.font = .systemFont(ofSize: 10, weight: .medium)
        haploidModeButton.translatesAutoresizingMaskIntoConstraints = false
        haploidModeButton.target = self
        haploidModeButton.action = #selector(haploidModeChanged(_:))
        haploidModeButton.toolTip = "Within-sample AF token mode: Auto from reference size, or force haploid/diploid"
        haploidModeButton.isHidden = true
        searchBar.addSubview(haploidModeButton)

        // "All"/"None" convenience buttons for annotation/variant type chips
        allTypesButton.title = "All"
        allTypesButton.font = .systemFont(ofSize: 10, weight: .medium)
        allTypesButton.controlSize = .small
        allTypesButton.bezelStyle = .recessed
        allTypesButton.target = self
        allTypesButton.action = #selector(selectAllTypes(_:))
        allTypesButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(allTypesButton)

        annotationViewportFilterButton.title = "Viewport"
        annotationViewportFilterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter viewport")
        annotationViewportFilterButton.imagePosition = .imageLeading
        annotationViewportFilterButton.font = .systemFont(ofSize: 10, weight: .medium)
        annotationViewportFilterButton.controlSize = .small
        annotationViewportFilterButton.bezelStyle = .recessed
        annotationViewportFilterButton.setButtonType(.toggle)
        annotationViewportFilterButton.target = self
        annotationViewportFilterButton.action = #selector(annotationViewportFilterToggled(_:))
        annotationViewportFilterButton.translatesAutoresizingMaskIntoConstraints = false
        annotationViewportFilterButton.toolTip = "When enabled, the viewport shows only the annotations currently visible in this table."
        annotationViewportFilterButton.setAccessibilityLabel("Filter viewport to visible annotation rows")
        searchBar.addSubview(annotationViewportFilterButton)

        annotationTracksButton.title = "Tracks"
        annotationTracksButton.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Annotation tracks")
        annotationTracksButton.imagePosition = .imageLeading
        annotationTracksButton.font = .systemFont(ofSize: 10, weight: .medium)
        annotationTracksButton.controlSize = .small
        annotationTracksButton.bezelStyle = .recessed
        annotationTracksButton.target = self
        annotationTracksButton.action = #selector(showAnnotationTracksMenu(_:))
        annotationTracksButton.translatesAutoresizingMaskIntoConstraints = false
        annotationTracksButton.toolTip = "Show, hide, and reorder annotation tracks in the viewport."
        annotationTracksButton.setAccessibilityLabel("Annotation track display options")
        searchBar.addSubview(annotationTracksButton)

        noneTypesButton.title = "None"
        noneTypesButton.font = .systemFont(ofSize: 10, weight: .medium)
        noneTypesButton.controlSize = .small
        noneTypesButton.bezelStyle = .recessed
        noneTypesButton.target = self
        noneTypesButton.action = #selector(selectNoTypes(_:))
        noneTypesButton.translatesAutoresizingMaskIntoConstraints = false
        searchBar.addSubview(noneTypesButton)

        presetFiltersToggleButton.title = "Presets ▸"
        presetFiltersToggleButton.font = .systemFont(ofSize: 10, weight: .medium)
        presetFiltersToggleButton.controlSize = .small
        presetFiltersToggleButton.bezelStyle = .recessed
        presetFiltersToggleButton.target = self
        presetFiltersToggleButton.action = #selector(toggleVariantPresetChips(_:))
        presetFiltersToggleButton.translatesAutoresizingMaskIntoConstraints = false
        presetFiltersToggleButton.isHidden = true
        searchBar.addSubview(presetFiltersToggleButton)

        searchBuilderButton.title = "Search Builder..."
        searchBuilderButton.font = .systemFont(ofSize: 10, weight: .medium)
        searchBuilderButton.controlSize = .small
        searchBuilderButton.bezelStyle = .rounded
        searchBuilderButton.target = self
        searchBuilderButton.action = #selector(openVariantSearchBuilder(_:))
        searchBuilderButton.translatesAutoresizingMaskIntoConstraints = false
        searchBuilderButton.isHidden = true
        searchBar.addSubview(searchBuilderButton)

        localVariantFilterBadgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        localVariantFilterBadgeLabel.textColor = .systemBlue
        localVariantFilterBadgeLabel.alignment = .center
        localVariantFilterBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        localVariantFilterBadgeLabel.isHidden = true
        localVariantFilterBadgeLabel.layer?.cornerRadius = 7
        localVariantFilterBadgeLabel.layer?.borderWidth = 1
        localVariantFilterBadgeLabel.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.35).cgColor
        localVariantFilterBadgeLabel.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08).cgColor
        localVariantFilterBadgeLabel.toolTip = "Column header filters apply only to currently loaded rows in the visible/table scope."
        searchBar.addSubview(localVariantFilterBadgeLabel)

        clearFilterButton.title = "Clear"
        clearFilterButton.font = .systemFont(ofSize: 10, weight: .medium)
        clearFilterButton.controlSize = .small
        clearFilterButton.bezelStyle = .recessed
        clearFilterButton.target = self
        clearFilterButton.action = #selector(clearVariantFilter(_:))
        clearFilterButton.translatesAutoresizingMaskIntoConstraints = false
        clearFilterButton.toolTip = "Clear variant filter"
        clearFilterButton.isHidden = true
        searchBar.addSubview(clearFilterButton)

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

        sampleGroupsButton.title = "Groups"
        sampleGroupsButton.controlSize = .small
        sampleGroupsButton.bezelStyle = .rounded
        sampleGroupsButton.font = .systemFont(ofSize: 10, weight: .medium)
        sampleGroupsButton.translatesAutoresizingMaskIntoConstraints = false
        sampleGroupsButton.target = self
        sampleGroupsButton.action = #selector(showSampleGroupsSheet(_:))
        sampleGroupsButton.isHidden = true
        searchBar.addSubview(sampleGroupsButton)

        sampleGroupPresetButton.controlSize = .small
        sampleGroupPresetButton.font = .systemFont(ofSize: 10, weight: .medium)
        sampleGroupPresetButton.translatesAutoresizingMaskIntoConstraints = false
        sampleGroupPresetButton.toolTip = "Show only a saved sample group"
        sampleGroupPresetButton.isHidden = true
        searchBar.addSubview(sampleGroupPresetButton)

        sampleQueryBuilderButton.title = "Sample Query..."
        sampleQueryBuilderButton.controlSize = .small
        sampleQueryBuilderButton.bezelStyle = .rounded
        sampleQueryBuilderButton.font = .systemFont(ofSize: 10, weight: .medium)
        sampleQueryBuilderButton.translatesAutoresizingMaskIntoConstraints = false
        sampleQueryBuilderButton.target = self
        sampleQueryBuilderButton.action = #selector(openSampleSearchBuilder(_:))
        sampleQueryBuilderButton.isHidden = true
        searchBar.addSubview(sampleQueryBuilderButton)

        clearSampleFilterButton.title = "Clear"
        clearSampleFilterButton.font = .systemFont(ofSize: 10, weight: .medium)
        clearSampleFilterButton.controlSize = .small
        clearSampleFilterButton.bezelStyle = .recessed
        clearSampleFilterButton.target = self
        clearSampleFilterButton.action = #selector(clearSampleFilter(_:))
        clearSampleFilterButton.translatesAutoresizingMaskIntoConstraints = false
        clearSampleFilterButton.isHidden = true
        searchBar.addSubview(clearSampleFilterButton)

        downloadTemplateButton.title = "Template TSV/CSV"
        downloadTemplateButton.controlSize = .small
        downloadTemplateButton.bezelStyle = .rounded
        downloadTemplateButton.font = .systemFont(ofSize: 10, weight: .medium)
        downloadTemplateButton.translatesAutoresizingMaskIntoConstraints = false
        downloadTemplateButton.target = self
        downloadTemplateButton.action = #selector(downloadSampleTemplateAction(_:))
        downloadTemplateButton.isHidden = true
        searchBar.addSubview(downloadTemplateButton)

        importMetadataButton.title = "Import Metadata..."
        importMetadataButton.controlSize = .small
        importMetadataButton.bezelStyle = .rounded
        importMetadataButton.font = .systemFont(ofSize: 10, weight: .medium)
        importMetadataButton.translatesAutoresizingMaskIntoConstraints = false
        importMetadataButton.target = self
        importMetadataButton.action = #selector(importMetadataAction(_:))
        importMetadataButton.isHidden = true
        searchBar.addSubview(importMetadataButton)

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

        // Export button (header bar)
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export table")
        exportButton.bezelStyle = .recessed
        exportButton.isBordered = false
        exportButton.controlSize = .small
        exportButton.imageScaling = .scaleProportionallyDown
        exportButton.target = self
        exportButton.action = #selector(showExportMenu(_:))
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.toolTip = "Export table data"
        headerBar.addSubview(exportButton)

        // Filter profile popup (header bar) — only shown on variants tab
        profileButton.controlSize = .small
        profileButton.font = .systemFont(ofSize: 10, weight: .medium)
        profileButton.translatesAutoresizingMaskIntoConstraints = false
        profileButton.toolTip = "Filter profiles"
        profileButton.isHidden = true  // shown only on variants tab
        rebuildProfileMenu()
        searchBar.addSubview(profileButton)

        // Column config gear button (header bar)
        columnConfigButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Configure columns")
        columnConfigButton.bezelStyle = .recessed
        columnConfigButton.isBordered = false
        columnConfigButton.controlSize = .small
        columnConfigButton.imageScaling = .scaleProportionallyDown
        columnConfigButton.target = self
        columnConfigButton.action = #selector(showColumnConfig(_:))
        columnConfigButton.translatesAutoresizingMaskIntoConstraints = false
        columnConfigButton.toolTip = "Column visibility and order"
        headerBar.addSubview(columnConfigButton)

        // Auto-size columns button
        autoSizeColumnsButton.image = NSImage(
            systemSymbolName: "arrow.left.and.right.text.vertical",
            accessibilityDescription: "Size columns to fit"
        )
        autoSizeColumnsButton.bezelStyle = .recessed
        autoSizeColumnsButton.isBordered = false
        autoSizeColumnsButton.controlSize = .small
        autoSizeColumnsButton.imageScaling = .scaleProportionallyDown
        autoSizeColumnsButton.target = self
        autoSizeColumnsButton.action = #selector(autoSizeVisibleTableColumns(_:))
        autoSizeColumnsButton.translatesAutoresizingMaskIntoConstraints = false
        autoSizeColumnsButton.toolTip = "Size visible columns to fit content"
        headerBar.addSubview(autoSizeColumnsButton)

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
        searchHintLabel.isHidden = true  // Redundant with search field placeholder text
        searchBar.addSubview(searchHintLabel)

        // Chip bar (row 2) — horizontal scrolling row of type toggle chips
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipBar)

        chipScrollView.translatesAutoresizingMaskIntoConstraints = false
        chipScrollView.hasHorizontalScroller = false
        chipScrollView.hasVerticalScroller = false
        chipScrollView.drawsBackground = false
        chipBar.addSubview(chipScrollView)

        chipSummaryLabel.font = .systemFont(ofSize: 10, weight: .medium)
        chipSummaryLabel.textColor = .secondaryLabelColor
        chipSummaryLabel.lineBreakMode = .byTruncatingTail
        chipSummaryLabel.translatesAutoresizingMaskIntoConstraints = false
        chipSummaryLabel.isHidden = true
        chipBar.addSubview(chipSummaryLabel)

        chipStackView.orientation = .horizontal
        chipStackView.spacing = 4
        chipStackView.alignment = .centerY
        chipStackView.translatesAutoresizingMaskIntoConstraints = false
        chipScrollView.documentView = chipStackView

        // Configure initial table columns (annotation mode)
        configureColumnsForTab(.annotations)

        tableView.headerView = WideColumnDividerHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
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

        // Variant query progress overlay (shown during background queries)
        queryProgressBar.style = .bar
        queryProgressBar.isIndeterminate = true
        queryProgressBar.controlSize = .small
        queryProgressBar.translatesAutoresizingMaskIntoConstraints = false
        queryProgressBar.isHidden = true
        addSubview(queryProgressBar)

        queryProgressLabel.font = .systemFont(ofSize: 11)
        queryProgressLabel.textColor = .secondaryLabelColor
        queryProgressLabel.alignment = .center
        queryProgressLabel.translatesAutoresizingMaskIntoConstraints = false
        queryProgressLabel.isHidden = true
        addSubview(queryProgressLabel)

        // Layout
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: topAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),

            headerBar.topAnchor.constraint(equalTo: dragHandle.bottomAnchor),
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 28),

            loadingIndicator.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            loadingIndicator.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 8),

            tabControl.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            tabControl.leadingAnchor.constraint(equalTo: loadingIndicator.trailingAnchor, constant: 4),
            tabControl.trailingAnchor.constraint(lessThanOrEqualTo: exportButton.leadingAnchor, constant: -6),

            exportButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            exportButton.widthAnchor.constraint(equalToConstant: 20),
            exportButton.heightAnchor.constraint(equalToConstant: 20),
            exportButton.trailingAnchor.constraint(equalTo: autoSizeColumnsButton.leadingAnchor, constant: -2),

            autoSizeColumnsButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            autoSizeColumnsButton.widthAnchor.constraint(equalToConstant: 20),
            autoSizeColumnsButton.heightAnchor.constraint(equalToConstant: 20),
            autoSizeColumnsButton.trailingAnchor.constraint(equalTo: columnConfigButton.leadingAnchor, constant: -2),

            columnConfigButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            columnConfigButton.widthAnchor.constraint(equalToConstant: 20),
            columnConfigButton.heightAnchor.constraint(equalToConstant: 20),
            columnConfigButton.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),

            countLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),

            searchBar.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 32),

            annotationFilterField.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            annotationFilterField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),
            annotationFilterField.heightAnchor.constraint(equalToConstant: 24),
            annotationFilterField.trailingAnchor.constraint(lessThanOrEqualTo: annotationViewportFilterButton.leadingAnchor, constant: -8),

            scopeControl.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            scopeControl.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 8),

            haploidModeButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            haploidModeButton.leadingAnchor.constraint(equalTo: scopeControl.trailingAnchor, constant: 6),

            variantSubtabControl.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            variantSubtabControl.leadingAnchor.constraint(equalTo: haploidModeButton.trailingAnchor, constant: 10),

            profileButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            profileButton.leadingAnchor.constraint(equalTo: variantSubtabControl.trailingAnchor, constant: 6),
            profileButton.widthAnchor.constraint(lessThanOrEqualToConstant: 120),

            clearFilterButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            clearFilterButton.trailingAnchor.constraint(equalTo: localVariantFilterBadgeLabel.leadingAnchor, constant: -6),

            localVariantFilterBadgeLabel.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            localVariantFilterBadgeLabel.trailingAnchor.constraint(equalTo: searchBuilderButton.leadingAnchor, constant: -6),

            sampleFilterField.widthAnchor.constraint(equalToConstant: 0),
            sampleFilterField.heightAnchor.constraint(equalToConstant: 0),
            sampleFilterField.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor),
            sampleFilterField.topAnchor.constraint(equalTo: searchBar.topAnchor),

            clearSampleFilterButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            clearSampleFilterButton.trailingAnchor.constraint(equalTo: sampleQueryBuilderButton.leadingAnchor, constant: -4),

            sampleQueryBuilderButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            sampleQueryBuilderButton.leadingAnchor.constraint(greaterThanOrEqualTo: searchBar.leadingAnchor, constant: 8),
            sampleQueryBuilderButton.trailingAnchor.constraint(equalTo: sampleGroupPresetButton.leadingAnchor, constant: -6),

            sampleGroupPresetButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            sampleGroupPresetButton.trailingAnchor.constraint(equalTo: addSampleFieldButton.leadingAnchor, constant: -6),
            sampleGroupPresetButton.widthAnchor.constraint(lessThanOrEqualToConstant: 170),

            allTypesButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            allTypesButton.trailingAnchor.constraint(equalTo: noneTypesButton.leadingAnchor, constant: -4),

            noneTypesButton.centerYAnchor.constraint(equalTo: allTypesButton.centerYAnchor),
            noneTypesButton.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),

            annotationViewportFilterButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            annotationViewportFilterButton.trailingAnchor.constraint(equalTo: annotationTracksButton.leadingAnchor, constant: -6),

            annotationTracksButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            annotationTracksButton.trailingAnchor.constraint(equalTo: allTypesButton.leadingAnchor, constant: -8),

            presetFiltersToggleButton.centerYAnchor.constraint(equalTo: allTypesButton.centerYAnchor),
            presetFiltersToggleButton.trailingAnchor.constraint(equalTo: allTypesButton.leadingAnchor, constant: -8),

            searchBuilderButton.centerYAnchor.constraint(equalTo: allTypesButton.centerYAnchor),
            searchBuilderButton.trailingAnchor.constraint(equalTo: presetFiltersToggleButton.leadingAnchor, constant: -8),

            addSampleFieldButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            addSampleFieldButton.trailingAnchor.constraint(equalTo: sampleGroupsButton.leadingAnchor, constant: -6),

            sampleGroupsButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            sampleGroupsButton.trailingAnchor.constraint(equalTo: importMetadataButton.leadingAnchor, constant: -6),

            importMetadataButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            importMetadataButton.trailingAnchor.constraint(equalTo: downloadTemplateButton.leadingAnchor, constant: -6),

            downloadTemplateButton.centerYAnchor.constraint(equalTo: searchBar.centerYAnchor),
            downloadTemplateButton.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -8),

            chipBar.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            chipBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: 48),

            chipSummaryLabel.topAnchor.constraint(equalTo: chipBar.topAnchor, constant: 2),
            chipSummaryLabel.leadingAnchor.constraint(equalTo: chipBar.leadingAnchor, constant: 8),
            chipSummaryLabel.trailingAnchor.constraint(equalTo: chipBar.trailingAnchor, constant: -8),

            chipScrollView.topAnchor.constraint(equalTo: chipSummaryLabel.bottomAnchor, constant: 2),
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

            queryProgressBar.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            queryProgressBar.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -10),
            queryProgressBar.widthAnchor.constraint(equalToConstant: 200),

            queryProgressLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            queryProgressLabel.topAnchor.constraint(equalTo: queryProgressBar.bottomAnchor, constant: 6),
            queryProgressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 20),
            queryProgressLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -20),
        ])

        rebuildHaploidModeMenu()

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

        // Observe variant color theme changes from Settings
        NotificationCenter.default.addObserver(
            self, selector: #selector(variantColorThemeDidChange(_:)),
            name: .variantColorThemeDidChange, object: nil
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

        let requestedMode = (notification.userInfo?[NotificationUserInfoKey.variantSelectionMode] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // Switch to variants tab if not already there
        if activeTab != .variants {
            switchToTab(.variants)
        }

        if requestedMode == "genotypes", activeVariantSubtab != .genotypes {
            variantSubtabControl.selectedSegment = VariantSubtab.genotypes.rawValue
            variantSubtabChanged(variantSubtabControl)
        } else if requestedMode == "calls", activeVariantSubtab != .calls {
            variantSubtabControl.selectedSegment = VariantSubtab.calls.rawValue
            variantSubtabChanged(variantSubtabControl)
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
        defer { isSuppressingDelegateCallbacks = false }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
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
        guard let expectedSource = viewportSyncSourceIdentifier,
              let sender = notification.object as AnyObject?,
              ObjectIdentifier(sender) == expectedSource else { return }
        guard let userInfo = notification.userInfo,
              let chromosome = userInfo[NotificationUserInfoKey.chromosome] as? String,
              let start = userInfo[NotificationUserInfoKey.start] as? Int,
              let end = userInfo[NotificationUserInfoKey.end] as? Int else { return }

        let nextRegion = (chromosome: chromosome, start: start, end: end)
        viewportRegion = nextRegion
        if hasActiveSearchFilters && viewportSyncEnabled && shouldArmViewportExploration(for: nextRegion) {
            allowViewportPostFilterDuringExploration = true
        }
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
        guard let expectedSource = viewportSyncSourceIdentifier,
              let sender = notification.object as AnyObject?,
              ObjectIdentifier(sender) == expectedSource else { return }
        guard let userInfo = notification.userInfo,
              let refChromosome = userInfo[NotificationUserInfoKey.chromosome] as? String,
              let start = userInfo[NotificationUserInfoKey.start] as? Int,
              let end = userInfo[NotificationUserInfoKey.end] as? Int else { return }
        let queryChromosome = refChromosome
        let nextRegion = (chromosome: queryChromosome, start: start, end: end)
        viewportRegion = nextRegion
        if hasActiveSearchFilters && viewportSyncEnabled && shouldArmViewportExploration(for: nextRegion) {
            allowViewportPostFilterDuringExploration = true
        }
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

    private func markVariantFilterStateMutated() {
        allowViewportPostFilterDuringExploration = false
        viewportRegionAtLastFilterMutation = viewportRegion
    }

    private func shouldArmViewportExploration(for newRegion: (chromosome: String, start: Int, end: Int)) -> Bool {
        guard let baseline = viewportRegionAtLastFilterMutation else { return true }
        return baseline.chromosome.caseInsensitiveCompare(newRegion.chromosome) != .orderedSame
            || baseline.start != newRegion.start
            || baseline.end != newRegion.end
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

    private func updateVariantToolbarDensity() {
        let density = Self.variantToolbarDensity(forWidth: bounds.width)
        let densityChanged = appliedVariantToolbarDensity != density
        appliedVariantToolbarDensity = density

        if densityChanged {
            switch density {
            case .full:
                scopeControl.setLabel("Region", forSegment: 0)
                scopeControl.setLabel("Genome", forSegment: 1)
                scopeControl.setWidth(62, forSegment: 0)
                scopeControl.setWidth(66, forSegment: 1)
                variantSubtabControl.setLabel("Calls", forSegment: 0)
                variantSubtabControl.setLabel("Genotypes", forSegment: 1)
                variantSubtabControl.setWidth(55, forSegment: 0)
                variantSubtabControl.setWidth(75, forSegment: 1)
                searchBuilderButton.title = "Search Builder..."
                clearFilterButton.title = "Clear"
            case .compact:
                scopeControl.setLabel("Region", forSegment: 0)
                scopeControl.setLabel("Genome", forSegment: 1)
                scopeControl.setWidth(56, forSegment: 0)
                scopeControl.setWidth(60, forSegment: 1)
                variantSubtabControl.setLabel("Calls", forSegment: 0)
                variantSubtabControl.setLabel("GT", forSegment: 1)
                variantSubtabControl.setWidth(50, forSegment: 0)
                variantSubtabControl.setWidth(36, forSegment: 1)
                searchBuilderButton.title = "Query"
                clearFilterButton.title = "Clear"
            case .minimal:
                scopeControl.setLabel("Reg", forSegment: 0)
                scopeControl.setLabel("Gen", forSegment: 1)
                scopeControl.setWidth(42, forSegment: 0)
                scopeControl.setWidth(42, forSegment: 1)
                variantSubtabControl.setLabel("Calls", forSegment: 0)
                variantSubtabControl.setLabel("GT", forSegment: 1)
                variantSubtabControl.setWidth(46, forSegment: 0)
                variantSubtabControl.setWidth(34, forSegment: 1)
                searchBuilderButton.title = "Query"
                clearFilterButton.title = "Clear"
            }
        }

        presetFiltersToggleButton.title = showVariantPresetChips ? "Presets ▾" : (density == .full ? "Presets ▸" : "Presets")
        let hasFilter = !variantFilterText.isEmpty || !activeSmartTokens.isEmpty || !selectedVariantPresetByKey.isEmpty
        searchBuilderButton.title = density == .full
            ? (hasFilter ? "Edit Query..." : "Query Builder...")
            : (hasFilter ? "Edit" : "Query")
    }

    private func updateSearchFieldVisibility() {
        let showVariants = activeTab == .variants
        let showSamples = activeTab == .samples
        let totalVariantDBSize = totalVariantDatabaseSizeBytes()
        let isLargeDatabase = totalVariantDBSize >= Self.chromosomeScopeThreshold
        let isMaterializedOnlyDatabase = totalVariantDBSize >= Self.materializedOnlyThreshold
        let toolbarDensity = Self.variantToolbarDensity(forWidth: bounds.width)
        if showVariants {
            enforceMaterializedOnlyRestrictionsIfNeeded()
        }
        updateVariantToolbarDensity()
        annotationFilterField.isHidden = activeTab != .annotations
        annotationViewportFilterButton.isHidden = activeTab != .annotations
        annotationViewportFilterButton.state = annotationViewportFilterEnabled ? .on : .off
        annotationTracksButton.isHidden = activeTab != .annotations || annotationTrackOrder.count <= 1
        variantFilterField.isHidden = true  // Always hidden; Query Builder writes to variantFilterText directly
        sampleFilterField.isHidden = true  // Samples use Query Builder; free-text field hidden to reduce toolbar density
        addSampleFieldButton.isHidden = !showSamples
        sampleGroupsButton.isHidden = !showSamples
        importMetadataButton.isHidden = !showSamples
        downloadTemplateButton.isHidden = !showSamples
        sampleQueryBuilderButton.isHidden = !showSamples
        sampleGroupPresetButton.isHidden = !showSamples
        clearSampleFilterButton.isHidden = !showSamples || (!hasActiveSampleFilters && sampleFilterText.isEmpty)
        variantSubtabControl.isHidden = !showVariants
        profileButton.isHidden = !showVariants || toolbarDensity != .full
        scopeControl.isHidden = !showVariants
        haploidModeButton.isHidden = !showVariants || toolbarDensity == .minimal
        presetFiltersToggleButton.isHidden = !showVariants || toolbarDensity == .minimal || infoColumnKeys.isEmpty || isMaterializedOnlyDatabase
        presetFiltersToggleButton.isEnabled = variantPresetLoadState != .loading
        // Gate Query Builder on database size.
        let queryBuilderVisible: Bool = {
            guard showVariants else { return false }
            if isMaterializedOnlyDatabase {
                return false
            }
            if isLargeDatabase {
                // Large database: only show if viewport is < 10 Mb
                if let vp = viewportRegion {
                    return (vp.end - vp.start) < 10_000_000
                }
                return false
            }
            return true
        }()
        // Show button whenever variants tab is active; disable when query would be too slow
        searchBuilderButton.isHidden = !showVariants
        searchBuilderButton.isEnabled = queryBuilderVisible
        localVariantFilterBadgeLabel.isHidden = !showVariants || toolbarDensity == .minimal
        if !queryBuilderVisible && showVariants {
            let dbSizeMB = totalVariantDBSize / 1_000_000
            if isMaterializedOnlyDatabase {
                searchBuilderButton.toolTip = "Database is very large (\(dbSizeMB) MB). Query Builder is disabled; use Smart Token filters only."
            } else {
                searchBuilderButton.toolTip = "Database is large (\(dbSizeMB) MB). Zoom in to a region < 10 Mb to enable Query Builder."
            }
        } else {
            searchBuilderButton.toolTip = nil
        }
        let showTypeControls = activeTab != .samples && !availableTypes.isEmpty
        allTypesButton.isHidden = !showTypeControls || toolbarDensity == .minimal
        noneTypesButton.isHidden = !showTypeControls || toolbarDensity == .minimal
        updateVariantFilterIndicator()
        rebuildSampleGroupPresetMenu()
        updateScopeControlSelection()
    }

    private func totalVariantDatabaseSizeBytes() -> UInt64 {
        var total: UInt64 = 0
        for url in variantTrackDatabaseURLs {
            total += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        }
        return total
    }

    private func isMaterializedOnlyModeEnabled() -> Bool {
        totalVariantDatabaseSizeBytes() >= Self.materializedOnlyThreshold
    }

    private func isMaterializedTokenAllowedInStrictMode(_ token: SmartToken) -> Bool {
        guard isMaterializedOnlyModeEnabled() else { return true }
        return materializedTokenNamesAcrossTracks.contains(token.rawValue)
    }

    private func enforceMaterializedOnlyRestrictionsIfNeeded() {
        guard isMaterializedOnlyModeEnabled() else { return }

        var changed = false
        if !variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            variantFilterText = ""
            changed = true
        }
        if !selectedVariantPresetByKey.isEmpty {
            selectedVariantPresetByKey.removeAll()
            changed = true
        }

        let unsupportedTokens = activeSmartTokens.filter { !isMaterializedTokenAllowedInStrictMode($0) }
        if !unsupportedTokens.isEmpty {
            activeSmartTokens.subtract(unsupportedTokens)
            changed = true
        }

        if changed {
            markVariantFilterStateMutated()
            updateChipStates()
        }
    }

    private func updateScopeControlSelection() {
        scopeControl.selectedSegment = viewportSyncEnabled ? 0 : 1
    }

    /// Updates the Search Builder button title and Clear button visibility
    /// based on whether a variant filter is active.
    private func updateVariantFilterIndicator() {
        let hasFilter = !variantFilterText.isEmpty || !activeSmartTokens.isEmpty || !selectedVariantPresetByKey.isEmpty
        let toolbarDensity = Self.variantToolbarDensity(forWidth: bounds.width)
        clearFilterButton.isHidden = !(activeTab == .variants && hasFilter)
        if toolbarDensity == .full {
            searchBuilderButton.title = hasFilter ? "Edit Query..." : "Query Builder..."
        } else {
            searchBuilderButton.title = hasFilter ? "Edit" : "Query"
        }
        updateVariantLogicSummary()
    }

    @objc private func clearVariantFilter(_ sender: Any) {
        variantFilterText = ""
        activeSmartTokens.removeAll()
        selectedVariantPresetByKey.removeAll()
        selectedAnnotationRegion = nil
        markVariantFilterStateMutated()
        updateVariantFilterIndicator()
        updateChipStates()
        updateDisplayedAnnotations()
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

    private func makeSmartTokenChipButton(token: SmartToken) -> NSButton {
        var label = token.label
        if let count = smartTokenCounts[token.rawValue], count > 0 {
            label += " (\(Self.formatCompactCount(count)))"
        }
        let button = NSButton(title: label, target: self, action: #selector(smartTokenToggled(_:)))
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.controlSize = .small
        button.bezelStyle = token.exclusivityGroupKey == nil ? .recessed : .rounded
        button.isBordered = true
        button.setButtonType(.pushOnPushOff)
        button.state = activeSmartTokens.contains(token) ? .on : .off
        button.translatesAutoresizingMaskIntoConstraints = false
        var toolTip = "\(token.uiSection.title): \(token.label)"
        if let count = smartTokenCounts[token.rawValue] {
            toolTip += " — \(Self.formatCompactCount(count)) variants"
        }
        if token.exclusivityGroupKey != nil {
            toolTip += " (mutually exclusive)"
        }
        button.toolTip = toolTip
        return button
    }

    /// Formats a count into a compact human-readable string (e.g., 1234567 → "1.2M").
    private static func formatCompactCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return millions >= 10 ? String(format: "%.0fM", millions) : String(format: "%.1fM", millions)
        } else if count >= 1_000 {
            let thousands = Double(count) / 1_000
            return thousands >= 10 ? String(format: "%.0fK", thousands) : String(format: "%.1fK", thousands)
        }
        return "\(count)"
    }

    private func updateVariantLogicSummary() {
        guard activeTab == .variants else {
            chipSummaryLabel.isHidden = true
            return
        }

        var parts: [String] = []
        parts.append(viewportSyncEnabled ? "region follow enabled" : "genome scope")
        if !activeSmartTokens.isEmpty {
            parts.append("tokens: \(activeSmartTokens.map(\.label).sorted().joined(separator: ", "))")
        }
        if !selectedVariantPresetByKey.isEmpty {
            let values = selectedVariantPresetByKey.keys.sorted().compactMap { key in
                selectedVariantPresetByKey[key].map { "\(key)=\($0)" }
            }.joined(separator: ", ")
            if !values.isEmpty {
                parts.append("preset filters: \(values)")
            }
        }
        if !variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("query builder rules active")
        }
        if !availableVariantTypes.isEmpty && visibleVariantTypes.count < availableVariantTypes.count {
            parts.append("types: \(visibleVariantTypes.count)/\(availableVariantTypes.count)")
        }

        chipSummaryLabel.stringValue = parts.isEmpty
            ? "Current logic: no filters (all variants)"
            : "Current logic: " + parts.joined(separator: "  •  ")
        chipSummaryLabel.isHidden = false
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
        (variantIdColumn, "ID", 130, 70, "variant_id"),
        (variantTypeColumn, "Type", 60, 40, "variant_type"),
        (variantChromColumn, "Chrom", 80, 50, "chromosome"),
        (positionColumn, "Position", 90, 60, "position"),
        (refColumn, "Ref", 60, 30, "ref"),
        (altColumn, "Alt", 60, 30, "alt"),
        (qualityColumn, "Quality", 70, 40, "quality"),
        (filterColumn, "Filter", 70, 40, "filter"),
        (samplesColumn, "Samples", 60, 40, "samples"),
        (sourceColumn, "Source", 100, 60, "source"),
        (consequenceColumn, "Consequence", 170, 90, "consequence"),
        (aaChangeColumn, "AA Change", 120, 80, "aa_change"),
    ]

    /// Column definitions for the samples tab (fixed columns — metadata columns are dynamic).
    private static let sampleColumnDefs: [(NSUserInterfaceItemIdentifier, String, CGFloat, CGFloat, String)] = [
        (sampleVisibleColumn, "", 30, 30, "visible"),
        (sampleNameColumn, "Sample", 180, 80, "sample_name"),
        (sampleDisplayNameColumn, "Display Name", 150, 80, "display_name"),
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
            col.resizingMask = [.autoresizingMask, .userResizingMask]
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: sortKey, ascending: true,
                selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
            )
            tableView.addTableColumn(col)
        }

        if tab == .annotations {
            for key in annotationAttributeColumnKeys {
                addAnnotationAttributeColumn(key)
            }
        }

        // Add dynamic INFO columns for variants tab.
        // Promoted keys (AF, Gene, Impact) are inserted right after fixed columns
        // so they appear in a biologically useful default order. Remaining INFO
        // columns follow in their original discovery order.
        if tab == .variants {
            let promotedKeys = Self.promotedInfoKeys(from: infoColumnKeys)
            let promotedKeySet = Set(promotedKeys.map(\.key))

            // Phase 1: promoted keys in expert-recommended order
            for info in promotedKeys {
                addInfoColumn(info)
            }

            // Phase 2: remaining keys in discovery order
            for info in infoColumnKeys where !promotedKeySet.contains(info.key) {
                addInfoColumn(info)
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
                col.resizingMask = [.autoresizingMask, .userResizingMask]
                col.sortDescriptorPrototype = NSSortDescriptor(
                    key: "meta_\(field)", ascending: true,
                    selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
                )
                tableView.addTableColumn(col)
            }
        }

        // Add bookmark column for variants tab (before saved prefs so it persists across reconfigs)
        if tab == .variants {
            addBookmarkColumnIfNeeded()
        }

        // Apply saved column preferences (visibility + ordering)
        if let saved = ColumnPrefsKey.load(tab: tab.prefsKey) {
            let hiddenIds = Set(saved.columns.filter { !$0.isVisible }.map(\.id))
            for col in tableView.tableColumns.reversed() {
                if hiddenIds.contains(col.identifier.rawValue) {
                    tableView.removeTableColumn(col)
                }
            }
            // Reorder visible columns to match saved order
            let orderedIds = saved.visibleColumns.map(\.id)
            for (targetIndex, colId) in orderedIds.enumerated() {
                if let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == colId }),
                   currentIndex != targetIndex, targetIndex < tableView.tableColumns.count {
                    tableView.moveColumn(currentIndex, toColumn: targetIndex)
                }
            }
        } else if tab == .samples {
            // Default behavior: keep only metadata columns with at least one non-empty value.
            let fieldsWithValues = metadataFieldsWithValues()
            for col in tableView.tableColumns.reversed() where col.identifier.rawValue.hasPrefix("meta_") {
                let field = String(col.identifier.rawValue.dropFirst(5))
                if !fieldsWithValues.contains(field) {
                    tableView.removeTableColumn(col)
                }
            }
        }
    }

    private static let promotedAnnotationAttributeKeys = [
        "source_coordinates",
        "alignment_columns",
        "consensus_columns",
        "alignment_row",
        "source_sequence",
        "source_track",
        "origin",
        "read_name",
        "mapq",
        "cigar",
        "flag",
        "tag_NM",
        "tag_AS",
        "read_group",
        "source_alignment_track_name",
    ]

    static func orderedAnnotationAttributeKeys(
        from results: [AnnotationSearchIndex.SearchResult]
    ) -> [String] {
        let discovered = Set(
            results
                .filter { !$0.isVariant }
                .flatMap { result in
                    result.attributes?.compactMap { key, value in
                        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : key
                    } ?? []
                }
        )
        let promoted = promotedAnnotationAttributeKeys.filter { discovered.contains($0) }
        let remaining = discovered.subtracting(promoted).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return promoted + remaining
    }

    private func addAnnotationAttributeColumn(_ key: String) {
        let identifier = NSUserInterfaceItemIdentifier("attr_\(key)")
        let col = NSTableColumn(identifier: identifier)
        let title = Self.annotationAttributeDisplayTitle(for: key)
        col.title = title
        col.headerToolTip = "Annotation attribute: \(title)"
        col.width = max(70, CGFloat(title.count + 2) * 7)
        col.minWidth = 40
        col.resizingMask = [.autoresizingMask, .userResizingMask]
        col.sortDescriptorPrototype = NSSortDescriptor(
            key: "attr_\(key)", ascending: true,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
        )
        tableView.addTableColumn(col)
    }

    private static func annotationAttributeDisplayTitle(for key: String) -> String {
        switch key {
        case "source_coordinates": return "Source Coordinates"
        case "alignment_columns": return "Alignment Columns"
        case "consensus_columns": return "Consensus Columns"
        case "alignment_row": return "Alignment Row"
        case "source_sequence": return "Source Sequence"
        case "source_track": return "Source Track"
        case "source_file": return "Source File"
        case "row_id": return "Row ID"
        default:
            return key
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { word in
                    word.count <= 3 ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
                }
                .joined(separator: " ")
        }
    }

    private func metadataFieldsWithValues() -> Set<String> {
        var fields = Set<String>()
        for metadata in sampleMetadata.values {
            for (key, value) in metadata {
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fields.insert(key)
                }
            }
        }
        return fields
    }

    /// INFO keys that should be promoted to default-visible positions when present.
    /// Order matches the expert-recommended column layout:
    /// ... fixed columns ... | AF | Gene | Impact | ... remaining INFO ...
    private static let promotedInfoKeyPatterns: [(displayTitle: String, keys: [String])] = [
        ("AF", ["AF", "af", "gnomAD_AF", "ExAC_AF", "1000G_AF"]),
        ("Gene", ["GENE", "Gene", "gene", "GENEINFO", "ANN_Gene", "CSQ_SYMBOL"]),
        ("Impact", ["IMPACT", "impact", "ANN_IMPACT", "CSQ_IMPACT"]),
    ]

    /// Returns the subset of `infoColumnKeys` that match promoted patterns, in display order.
    static func promotedInfoKeys(
        from infoColumnKeys: [(key: String, type: String, description: String)]
    ) -> [(key: String, type: String, description: String)] {
        let keySet = Set(infoColumnKeys.map(\.key))
        var result: [(key: String, type: String, description: String)] = []
        for pattern in promotedInfoKeyPatterns {
            // Take the first matching key variant that exists in this VCF
            if let matchingKey = pattern.keys.first(where: { keySet.contains($0) }),
               let info = infoColumnKeys.first(where: { $0.key == matchingKey }) {
                result.append(info)
            }
        }
        return result
    }

    /// Adds a single INFO column to the table view.
    private func addInfoColumn(_ info: (key: String, type: String, description: String)) {
        let identifier = NSUserInterfaceItemIdentifier("info_\(info.key)")
        let col = NSTableColumn(identifier: identifier)
        col.title = info.key
        let fullName = info.description.isEmpty ? info.key : "\(info.description) (\(info.key))"
        col.headerToolTip = fullName
        col.width = max(80, CGFloat(info.key.count + 2) * 7)
        col.minWidth = 40
        col.resizingMask = [.autoresizingMask, .userResizingMask]
        col.sortDescriptorPrototype = NSSortDescriptor(
            key: "info_\(info.key)", ascending: true,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
        )
        tableView.addTableColumn(col)
    }

    // MARK: - Tab Switching

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = DrawerTab(rawValue: sender.selectedSegment) else { return }
        switchToTab(tab)
    }

    @objc func variantSubtabChanged(_ sender: NSSegmentedControl) {
        guard let subtab = VariantSubtab(rawValue: sender.selectedSegment) else { return }
        activeVariantSubtab = subtab
        if subtab == .genotypes {
            configureColumnsForGenotypes()
            buildGenotypeRows()
        } else {
            configureColumnsForTab(.variants)
            tableView.reloadData()
            updateCountLabel()
        }
    }

    @objc private func scopeSegmentChanged(_ sender: NSSegmentedControl) {
        viewportSyncEnabled = (sender.selectedSegment == 0)
        markVariantFilterStateMutated()
        updateScopeControlSelection()
        updateVariantLogicSummary()
        // Re-query with new scope
        updateDisplayedAnnotations()
    }

    @objc private func haploidModeChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0 else { return }
        let selected = sender.selectedTag()
        switch selected {
        case 1:
            haploidModeSelection = .haploid
        case 2:
            haploidModeSelection = .diploid
        default:
            haploidModeSelection = .auto
        }
        applyHaploidModeSelectionToIndex()
        saveHaploidModeSelection(haploidModeSelection, bundleIdentifier: searchIndex?.bundleIdentifier)
        isHaploidOrganism = searchIndex?.isLikelyHaploidOrganism ?? false
        currentSampleDisplayState.useHaploidAFShading = isHaploidOrganism
        postSampleDisplayStateChange()
        rebuildHaploidModeMenu()
        rebuildChipButtons()
        if activeTab == .variants, activeVariantSubtab == .genotypes {
            configureColumnsForGenotypes()
            tableView.reloadData()
        }
        if activeTab == .variants {
            updateDisplayedAnnotations()
        }
    }

    private func haploidModeDefaultsKey(bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        return "VariantHaploidMode.\(bundleIdentifier)"
    }

    private func loadHaploidModeSelection(bundleIdentifier: String?) -> HaploidModeSelection {
        guard let key = haploidModeDefaultsKey(bundleIdentifier: bundleIdentifier),
              let raw = UserDefaults.standard.string(forKey: key),
              let value = HaploidModeSelection(rawValue: raw) else {
            return .auto
        }
        return value
    }

    private func saveHaploidModeSelection(_ selection: HaploidModeSelection, bundleIdentifier: String?) {
        guard let key = haploidModeDefaultsKey(bundleIdentifier: bundleIdentifier) else { return }
        UserDefaults.standard.set(selection.rawValue, forKey: key)
    }

    private func applyHaploidModeSelectionToIndex() {
        guard let index = searchIndex else { return }
        switch haploidModeSelection {
        case .auto:
            index.setHaploidOverride(nil)
        case .haploid:
            index.setHaploidOverride(true)
        case .diploid:
            index.setHaploidOverride(false)
        }
        currentSampleDisplayState.useHaploidAFShading = index.isLikelyHaploidOrganism
    }

    private func rebuildHaploidModeMenu() {
        haploidModeButton.removeAllItems()
        haploidModeButton.addItems(withTitles: ["Auto", "Haploid", "Diploid"])
        haploidModeButton.lastItem?.isEnabled = true
        haploidModeButton.item(at: 0)?.tag = 0
        haploidModeButton.item(at: 1)?.tag = 1
        haploidModeButton.item(at: 2)?.tag = 2
        switch haploidModeSelection {
        case .auto:
            haploidModeButton.selectItem(at: 0)
        case .haploid:
            haploidModeButton.selectItem(at: 1)
        case .diploid:
            haploidModeButton.selectItem(at: 2)
        }
    }

    /// Switches to the specified tab, reconfiguring columns, chip bar, and data.
    func switchToTab(_ tab: DrawerTab) {
        guard tab != activeTab || (tab == .samples ? displayedSamples.isEmpty : displayedAnnotations.isEmpty) else { return }
        viewportSyncWorkItem?.cancel()
        viewportSyncWorkItem = nil
        if tab != .variants {
            invalidateInFlightVariantQueries()
            hideVariantQueryProgress()
        }
        activeTab = tab
        tabControl.selectedSegment = tab.rawValue
        updateSearchFieldVisibility()

        // Multi-select for annotations, variants, and samples tabs.
        tableView.allowsMultipleSelection = true

        switch tab {
        case .annotations:
            annotationFilterField.stringValue = annotationFilterText
        case .variants:
            break  // Query Builder manages variantFilterText directly
        case .samples:
            sampleFilterField.stringValue = sampleFilterText
        }

        // Reset variant subtab when switching to variants
        if tab == .variants {
            activeVariantSubtab = .calls
            variantSubtabControl.selectedSegment = 0
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
            markVariantFilterStateMutated()
            handleCoordinateSyncFromViewer()
        }
    }

    // MARK: - Data Loading

    /// Connects the drawer to a search index for direct SQL queries.
    /// Does NOT load all annotations into memory — queries the database on demand.
    func setSearchIndex(_ index: AnnotationSearchIndex) {
        searchIndex = index
        isLoading = false
        cachedGlobalFilteredVariantRows = []
        cachedGlobalFilteredVariantKey = nil
        markVariantFilterStateMutated()
        viewportRegionAtLastFilterMutation = nil

        // Get metadata from the index — track annotation and variant counts separately
        totalAnnotationCount = index.entryCount
        totalVariantCount = index.variantCount
        availableAnnotationTypes = index.annotationTypes
        availableVariantTypes = index.variantTypes

        // Discover INFO field definitions for dynamic variant columns
        infoColumnKeys = index.variantInfoKeys.map { (key: $0.key, type: $0.type, description: $0.description) }
        annotationAttributeColumnKeys = Self.orderedAnnotationAttributeKeys(
            from: index.queryAnnotationsOnly(limit: Self.maxDisplayCount)
        )
        syncAnnotationTracks(from: index.annotationDatabaseHandles.map(\.trackId))
        variantTrackDatabaseURLs = index.variantDatabaseHandles.map(\.db.databaseURL)
        variantInfoPresetValues = []
        variantPresetLoadState = .idle
        selectedVariantPresetByKey.removeAll()

        // Apply persisted haploid-mode override (if present), then compute availability.
        haploidModeSelection = loadHaploidModeSelection(bundleIdentifier: index.bundleIdentifier)
        applyHaploidModeSelectionToIndex()
        isHaploidOrganism = index.isLikelyHaploidOrganism
        rebuildHaploidModeMenu()

        // All types visible by default for both tabs
        visibleAnnotationTypes = Set(availableAnnotationTypes)
        visibleVariantTypes = Set(availableVariantTypes)

        // Populate sample data from variant databases
        populateSampleData(from: index)

        // Load bookmarked variant IDs for star column display
        loadBookmarkedVariantIds()

        // Enable/disable variant tab based on whether variants exist
        tabControl.setEnabled(totalVariantCount > 0, forSegment: 1)
        // Enable/disable samples tab based on whether samples exist
        tabControl.setEnabled(!allSampleNames.isEmpty, forSegment: 2)
        // Show the tab control only when we have at least one type of data
        tabControl.isHidden = totalVariantCount == 0 && allSampleNames.isEmpty

        // Reconfigure columns if we're already on the variants tab so INFO columns appear
        if activeTab == .annotations {
            configureColumnsForTab(.annotations)
        } else if activeTab == .variants {
            configureColumnsForTab(.variants)
        } else if activeTab == .samples {
            configureColumnsForTab(.samples)
        }

        // Load pre-built SmartToken cache state (counts from persistent tables, instant).
        loadSmartTokenCounts(from: index)
        enforceMaterializedOnlyRestrictionsIfNeeded()

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

    /// Reads pre-built token cache counts from variant databases (instant — no table scans).
    ///
    /// Token tables are built during import and persisted in the database file.
    /// This just reads their row counts to populate chip labels.
    private func loadSmartTokenCounts(from index: AnnotationSearchIndex) {
        let handles = index.variantDatabaseHandles
        guard !handles.isEmpty else {
            smartTokenCounts = [:]
            materializedTokenNamesAcrossTracks = []
            return
        }

        var aggregatedCounts: [String: Int] = [:]
        var intersection: Set<String>?
        for handle in handles {
            let state = handle.db.tokenCacheState
            let readyNames = Set(state.compactMap { key, value in value.ready ? key : nil })
            if let existing = intersection {
                intersection = existing.intersection(readyNames)
            } else {
                intersection = readyNames
            }
            for (key, value) in state where value.ready {
                aggregatedCounts[key, default: 0] += value.count
            }
        }
        smartTokenCounts = aggregatedCounts
        materializedTokenNamesAcrossTracks = intersection ?? []
        rebuildChipButtons()
    }

    /// Legacy entry point for when no search index is available (fallback).
    func setAnnotations(_ results: [AnnotationSearchIndex.SearchResult]) {
        searchIndex = nil
        isLoading = false
        totalAnnotationCount = results.count

        let typeSet = Set(results.map { $0.type })
        availableAnnotationTypes = typeSet.sorted()
        visibleAnnotationTypes = typeSet
        annotationAttributeColumnKeys = Self.orderedAnnotationAttributeKeys(from: results)
        syncAnnotationTracks(from: results.map(\.trackId))
        configureColumnsForTab(.annotations)

        rebuildChipButtons()

        // For legacy mode, set results directly (capped at maxDisplayCount)
        if results.count > Self.maxDisplayCount {
            setAnnotationBaseResults([])
            tableView.reloadData()
            scrollView.isHidden = false
            let total = numberFormatter.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
            let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
            tooManyLabel.stringValue = "\(total) annotations match — use the search field or type filters to narrow to \(max) or fewer"
            tooManyLabel.isHidden = false
        } else {
            setAnnotationBaseResults(results)
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
        variantPresetChipButtons.removeAll()
        variantPresetChipPayloads.removeAll()
        variantPresetMorePayloads.removeAll()
        smartTokenButtons.removeAll()
        smartTokenPayloads.removeAll()
        sampleTokenButtons.removeAll()
        sampleTokenPayloads.removeAll()

        var hasSmartTokens = false
        let isMaterializedOnlyDatabase = isMaterializedOnlyModeEnabled()
        // Smart tokens for the variants tab (grouped by semantic section).
        if activeTab == .variants {
            let infoKeySet = Set(infoColumnKeys.map(\.key))
            let variantTypeSet = Set(availableVariantTypes)
            let hasGT = !allSampleNames.isEmpty
            for section in SmartToken.UISection.allCases {
                let sectionTokens = SmartToken.allCases.filter { $0.uiSection == section }
                // Only show section if at least one token is available
                let anyAvailable = sectionTokens.contains {
                    $0.isAvailable(infoKeys: infoKeySet, variantTypes: variantTypeSet, hasGenotypes: hasGT, hasBookmarks: hasBookmarks, isHaploidOrganism: isHaploidOrganism)
                }
                guard anyAvailable else { continue }
                if hasSmartTokens {
                    let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 1))
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    spacer.widthAnchor.constraint(equalToConstant: 10).isActive = true
                    chipStackView.addArrangedSubview(spacer)
                }
                let label = NSTextField(labelWithString: section.title)
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .tertiaryLabelColor
                chipStackView.addArrangedSubview(label)
                for token in sectionTokens {
                    let isTokenAvailable = token.isAvailable(infoKeys: infoKeySet, variantTypes: variantTypeSet, hasGenotypes: hasGT, hasBookmarks: hasBookmarks, isHaploidOrganism: isHaploidOrganism)
                    let isTokenMaterialized = isMaterializedTokenAllowedInStrictMode(token)
                    let chip = makeSmartTokenChipButton(token: token)
                    if !isTokenAvailable || !isTokenMaterialized {
                        chip.isEnabled = false
                        chip.alphaValue = 0.4
                        if !isTokenMaterialized, isMaterializedOnlyDatabase {
                            chip.toolTip = "Disabled for very large variant databases (token is not pre-materialized)."
                        } else {
                            chip.toolTip = token.unavailabilityReason(infoKeys: infoKeySet, variantTypes: variantTypeSet, hasGenotypes: hasGT, hasBookmarks: hasBookmarks, isHaploidOrganism: isHaploidOrganism)
                        }
                    }
                    chipStackView.addArrangedSubview(chip)
                    smartTokenButtons[token] = chip
                    smartTokenPayloads[ObjectIdentifier(chip)] = token
                }
                hasSmartTokens = true
            }
            if hasSmartTokens && !availableTypes.isEmpty {
                let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 1))
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.widthAnchor.constraint(equalToConstant: 8).isActive = true
                chipStackView.addArrangedSubview(spacer)
            }
        }

        if activeTab == .samples {
            let sampleTokens = SampleSmartToken.allCases
            let label = NSTextField(labelWithString: "Sample Filters")
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            chipStackView.addArrangedSubview(label)
            for token in sampleTokens {
                let chip = NSButton(title: token.label, target: self, action: #selector(sampleTokenToggled(_:)))
                chip.font = NSFont.systemFont(ofSize: 10, weight: .medium)
                chip.controlSize = NSControl.ControlSize.small
                chip.bezelStyle = token.exclusivityGroupKey == nil ? NSButton.BezelStyle.recessed : NSButton.BezelStyle.rounded
                chip.isBordered = true
                chip.setButtonType(NSButton.ButtonType.pushOnPushOff)
                chip.state = activeSampleTokens.contains(token) ? NSControl.StateValue.on : NSControl.StateValue.off
                chip.translatesAutoresizingMaskIntoConstraints = false
                chipStackView.addArrangedSubview(chip)
                sampleTokenButtons[token] = chip
                sampleTokenPayloads[ObjectIdentifier(chip)] = token
            }
            hasSmartTokens = !sampleTokenButtons.isEmpty
        }

        // Create a chip for each type
        for type in availableTypes {
            let chip = makeTypeChipButton(type: type)
            chip.state = visibleTypes.contains(type) ? .on : .off
            chipStackView.addArrangedSubview(chip)
            chipButtons[type] = chip
        }

        if activeTab == .variants, showVariantPresetChips, !variantInfoPresetValues.isEmpty, !isMaterializedOnlyDatabase {
            let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 1))
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(equalToConstant: 12).isActive = true
            chipStackView.addArrangedSubview(spacer)

            for preset in variantInfoPresetValues {
                if preset.values.isEmpty { continue }
                let label = NSTextField(labelWithString: "\(preset.key):")
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .secondaryLabelColor
                chipStackView.addArrangedSubview(label)

                let shownValues = Array(preset.values.prefix(8))
                for value in shownValues {
                    let token = "\(preset.key)\t\(value)"
                    let chip = NSButton(title: value, target: self, action: #selector(variantPresetChipToggled(_:)))
                    chip.font = .systemFont(ofSize: 10, weight: .medium)
                    chip.controlSize = .small
                    chip.bezelStyle = .recessed
                    chip.isBordered = true
                    chip.setButtonType(.pushOnPushOff)
                    chip.state = (selectedVariantPresetByKey[preset.key] == value) ? .on : .off
                    chip.translatesAutoresizingMaskIntoConstraints = false
                    chipStackView.addArrangedSubview(chip)
                    variantPresetChipButtons[token] = chip
                    variantPresetChipPayloads[ObjectIdentifier(chip)] = (key: preset.key, value: value)
                }
                if preset.values.count > shownValues.count {
                    let moreButton = NSButton(title: "More...", target: self, action: #selector(showVariantPresetMoreValues(_:)))
                    moreButton.font = .systemFont(ofSize: 10, weight: .regular)
                    moreButton.controlSize = .small
                    moreButton.bezelStyle = .recessed
                    moreButton.translatesAutoresizingMaskIntoConstraints = false
                    chipStackView.addArrangedSubview(moreButton)
                    variantPresetMorePayloads[ObjectIdentifier(moreButton)] = preset.key
                }
            }
        }

        // Show chip bar if we have types or smart tokens (never for samples tab)
        let hasPresetUI = activeTab == .variants && showVariantPresetChips && (!variantPresetChipButtons.isEmpty || !variantPresetMorePayloads.isEmpty)
        if activeTab == .samples {
            chipBar.isHidden = !hasSmartTokens
            updateSampleFilterIndicator()
        } else {
            chipBar.isHidden = availableTypes.isEmpty && !hasPresetUI && !hasSmartTokens
        }
        updateVariantLogicSummary()
    }

    private func updateChipStates() {
        for (type, button) in chipButtons {
            button.state = visibleTypes.contains(type) ? .on : .off
        }
        for (token, button) in variantPresetChipButtons {
            let parts = token.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            button.state = selectedVariantPresetByKey[parts[0]] == parts[1] ? .on : .off
        }
        for (token, button) in smartTokenButtons {
            button.state = activeSmartTokens.contains(token) ? .on : .off
        }
        for (token, button) in sampleTokenButtons {
            button.state = activeSampleTokens.contains(token) ? .on : .off
        }
        updateVariantLogicSummary()
        updateSampleFilterIndicator()
    }

    @objc private func smartTokenToggled(_ sender: NSButton) {
        guard let token = smartTokenPayloads[ObjectIdentifier(sender)] else { return }
        guard isMaterializedTokenAllowedInStrictMode(token) else {
            sender.state = .off
            return
        }
        if sender.state == .on {
            if let group = token.exclusivityGroupKey {
                for existing in activeSmartTokens where existing != token && existing.exclusivityGroupKey == group {
                    activeSmartTokens.remove(existing)
                }
            }
            activeSmartTokens.insert(token)
        } else {
            activeSmartTokens.remove(token)
        }
        markVariantFilterStateMutated()
        updateChipStates()
        updateVariantFilterIndicator()
        updateDisplayedAnnotations()
    }

    @objc private func variantPresetChipToggled(_ sender: NSButton) {
        guard let payload = variantPresetChipPayloads[ObjectIdentifier(sender)] else { return }
        let key = payload.key
        let value = payload.value
        if sender.state == .on {
            selectedVariantPresetByKey[key] = value
        } else {
            selectedVariantPresetByKey.removeValue(forKey: key)
        }
        markVariantFilterStateMutated()
        updateChipStates()
        updateVariantFilterIndicator()
        updateDisplayedAnnotations()
    }

    @objc private func toggleVariantPresetChips(_ sender: NSButton) {
        loadVariantPresetValuesIfNeeded()
        showVariantPresetChips.toggle()
        presetFiltersToggleButton.title = showVariantPresetChips ? "Presets ▾" : "Presets ▸"
        rebuildChipButtons()
    }

    @objc private func showVariantPresetMoreValues(_ sender: NSButton) {
        guard let key = variantPresetMorePayloads[ObjectIdentifier(sender)],
              let preset = variantInfoPresetValues.first(where: { $0.key == key }) else { return }
        let menu = NSMenu(title: "\(key) values")
        let clearItem = NSMenuItem(title: "(Any)", action: #selector(selectVariantPresetValue(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.representedObject = ["key": key, "value": ""]
        menu.addItem(clearItem)
        menu.addItem(.separator())
        for value in preset.values {
            let item = NSMenuItem(title: value, action: #selector(selectVariantPresetValue(_:)), keyEquivalent: "")
            item.target = self
            item.state = (selectedVariantPresetByKey[key] == value) ? .on : .off
            item.representedObject = ["key": key, "value": value]
            menu.addItem(item)
        }
        let point = NSPoint(x: 0, y: sender.bounds.height)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func selectVariantPresetValue(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let value = payload["value"] else { return }
        if value.isEmpty {
            selectedVariantPresetByKey.removeValue(forKey: key)
        } else {
            selectedVariantPresetByKey[key] = value
        }
        markVariantFilterStateMutated()
        updateChipStates()
        updateDisplayedAnnotations()
    }

    // MARK: - Filtering

    private func updateDisplayedAnnotations() {
        if activeTab == .variants {
            enforceMaterializedOnlyRestrictionsIfNeeded()
        }

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
                // Count label is updated by the async completion callback.
                return
            }

            // Annotations tab: global query
            let mergedTypeFilter: Set<String> = {
                guard let explicitType = annotationQuery.typeFilter, !explicitType.isEmpty else { return typeFilter }
                if typeFilter.isEmpty { return explicitType }
                return typeFilter.intersection(explicitType)
            }()
            let databaseColumnFilters = annotationDatabaseColumnFilters()
            let matchingCount = index.queryAnnotationCount(
                nameFilter: nameFilter,
                types: mergedTypeFilter,
                chromosome: annotationQuery.chromosome,
                regionStart: annotationQuery.start,
                regionEnd: annotationQuery.end,
                strand: annotationQuery.strand,
                columnFilters: databaseColumnFilters
            )

            if matchingCount > Self.maxDisplayCount {
                setAnnotationBaseResults([])
                tableView.reloadData()
                scrollView.isHidden = false
                let total = numberFormatter.string(from: NSNumber(value: matchingCount)) ?? "\(matchingCount)"
                let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                tooManyLabel.stringValue = "\(total) \(entityName) match — use the search field or type filters to narrow to \(max) or fewer"
                tooManyLabel.isHidden = false
                annotationSearchRegion = nil
            } else {
                let results = index.queryAnnotationsOnly(
                    nameFilter: nameFilter,
                    types: mergedTypeFilter,
                    chromosome: annotationQuery.chromosome,
                    regionStart: annotationQuery.start,
                    regionEnd: annotationQuery.end,
                    strand: annotationQuery.strand,
                    columnFilters: databaseColumnFilters,
                    limit: Self.maxDisplayCount * 3
                )
                let filtered = applyAnnotationColumnFilters(
                    to: applyAnnotationAdvancedFilters(results, query: annotationQuery)
                ).prefix(Self.maxDisplayCount).map { $0 }
                setAnnotationBaseResults(filtered)
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
                setAnnotationBaseResults([])
                tableView.reloadData()
                scrollView.isHidden = false
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
                    setAnnotationBaseResults([])
                    tableView.reloadData()
                    scrollView.isHidden = false
                    let total = numberFormatter.string(from: NSNumber(value: results.count)) ?? "\(results.count)"
                    let max = numberFormatter.string(from: NSNumber(value: Self.maxDisplayCount)) ?? "\(Self.maxDisplayCount)"
                    tooManyLabel.stringValue = "\(total) \(entityName) match — use the search field or type filters to narrow to \(max) or fewer"
                    tooManyLabel.isHidden = false
                } else {
                    setAnnotationBaseResults(results)
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

    private func annotationDatabaseColumnFilters() -> [AnnotationDatabase.ColumnFilterClause] {
        annotationColumnFilterClauses.map {
            AnnotationDatabase.ColumnFilterClause(key: $0.key, op: $0.op, value: $0.value)
        }
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

    /// Whether the current query has user-entered filters/tokens.
    private var hasActiveSearchFilters: Bool {
        if !activeSmartTokens.isEmpty { return true }
        if !variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !selectedVariantPresetByKey.isEmpty { return true }
        return false
    }

    /// Returns a narrowed sample set for variant queries when the user has hidden samples.
    /// Empty set means "no sample restriction".
    private func selectedSamplesForVariantQuery() -> Set<String> {
        guard !allSampleNames.isEmpty else { return [] }
        let visible = Set(allSampleNames.filter { !currentSampleDisplayState.hiddenSamples.contains($0) })
        guard !visible.isEmpty, visible.count < allSampleNames.count else { return [] }
        return visible
    }

    private func updateDisplayedVariants(
        index: AnnotationSearchIndex,
        typeFilter: Set<String>,
        query: VariantFilterQuery
    ) {
        let isLargeDatabase = totalVariantDatabaseSizeBytes() >= Self.chromosomeScopeThreshold
        let isMaterializedOnlyDatabase = isMaterializedOnlyModeEnabled()

        let chipInfoFilters: [VariantDatabase.InfoFilter] = isMaterializedOnlyDatabase ? [] : selectedVariantPresetByKey.map { key, value in
            VariantDatabase.InfoFilter(key: key, op: .eq, value: value)
        }

        // Compose smart token filters
        let infoKeySet = Set(infoColumnKeys.map(\.key))
        let smartComposed = activeSmartTokens.composeFilters(infoKeys: infoKeySet)
        let filterBookmarkedOnly = smartComposed.postFilters.contains(where: {
            if case .bookmarkedOnly = $0 { return true }; return false
        })
        let filterModerateOrHigher = smartComposed.postFilters.contains(where: {
            if case .moderateOrHigherImpact = $0 { return true }; return false
        })
        // Extract within-sample AF range filter (for viral/bacterial smart tokens)
        let withinSampleAFRange: (min: Double, max: Double)? = smartComposed.postFilters.compactMap {
            if case .withinSampleAFRange(let lo, let hi) = $0 { return (min: lo, max: hi) }
            return nil
        }.first
        let hasSmartPostFilter = filterBookmarkedOnly || filterModerateOrHigher || withinSampleAFRange != nil

        // Merge type restrictions from smart tokens with existing type filter
        var effectiveTypeFilter = typeFilter
        if let explicitTypeFilter = query.explicitTypeFilter, !explicitTypeFilter.isEmpty {
            if effectiveTypeFilter.isEmpty {
                effectiveTypeFilter = explicitTypeFilter
            } else {
                effectiveTypeFilter = effectiveTypeFilter.intersection(explicitTypeFilter)
            }
        }
        if !smartComposed.typeRestrictions.isEmpty {
            if effectiveTypeFilter.isEmpty {
                effectiveTypeFilter = smartComposed.typeRestrictions
            } else {
                effectiveTypeFilter = effectiveTypeFilter.intersection(smartComposed.typeRestrictions)
            }
        }

        let mergedInfoFilters = query.infoFilters + chipInfoFilters + smartComposed.infoFilters
        let selectedSamples = selectedSamplesForVariantQuery()
        // Capture active SmartToken raw values for pre-materialized cache JOINs.
        let frozenActiveTokens = Set(activeSmartTokens.map(\.rawValue))

        // Build effective query with smart token overlays.
        // For very large databases, force materialized-token-only mode by dropping
        // user-authored query-builder clauses that are not backed by token caches.
        var effectiveQuery = query
        if isMaterializedOnlyDatabase {
            effectiveQuery = VariantFilterQuery()
        }
        effectiveQuery.infoFilters = mergedInfoFilters
        if let smartMinQ = smartComposed.minQuality, effectiveQuery.minQuality == nil {
            effectiveQuery.minQuality = smartMinQ
            effectiveQuery.minQualityInclusive = true
        }
        if let smartFilter = smartComposed.filterValue, effectiveQuery.filterValue == nil {
            effectiveQuery.filterValue = smartFilter
        }
        // Scope control is authoritative:
        // When the user has active text/token/preset filters and no explicit region clause,
        // queries run globally regardless of the scope control setting.  This ensures the
        // first filtered result set is genome-wide; viewport post-filtering narrows it
        // during exploration (see `allowViewportPostFilterDuringExploration`).
        let hasGlobalOverrideFilters = hasActiveSearchFilters
            && effectiveQuery.region == nil
        let viewportPostFilterRegion: (chromosome: String, start: Int, end: Int)? = {
            guard hasGlobalOverrideFilters,
                  viewportSyncEnabled,
                  allowViewportPostFilterDuringExploration,
                  let viewportRegion else { return nil }
            return viewportRegion
        }()
        let usePostFiltering = hasSmartPostFilter || effectiveQuery.hasPostFilters || viewportPostFilterRegion != nil

        // Freeze mutable vars as `let` for safe capture in the @Sendable dispatch closure.
        let frozenQuery = effectiveQuery
        let frozenTypeFilter = effectiveTypeFilter

        // Snapshot bookmark keys for background use (value copy).
        let bookmarkSnapshot = bookmarkedVariantKeys

        // Gene list query always runs globally, independent of viewport/annotation scope.
        let inferredGeneList = query.geneList == nil ? detectGeneListPattern(query.nameFilter) : nil
        let activeGeneList = query.geneList ?? inferredGeneList
        let cacheKey = VariantQueryCacheKey(
            filterText: variantFilterText.trimmingCharacters(in: .whitespacesAndNewlines),
            tokens: activeSmartTokens.map(\.rawValue).sorted(),
            presets: selectedVariantPresetByKey.keys.sorted().map { "\($0)=\(selectedVariantPresetByKey[$0] ?? "")" },
            typeFilter: typeFilter.sorted(),
            explicitTypeFilter: (query.explicitTypeFilter ?? []).sorted(),
            infoFilters: mergedInfoFilters.map { "\($0.key)|\($0.op.rawValue)|\($0.value)" }.sorted(),
            filterValue: effectiveQuery.filterValue,
            minQuality: effectiveQuery.minQuality,
            minQualityInclusive: effectiveQuery.minQualityInclusive,
            maxQuality: effectiveQuery.maxQuality,
            maxQualityInclusive: effectiveQuery.maxQualityInclusive,
            minSampleCount: effectiveQuery.minSampleCount,
            minSampleCountInclusive: effectiveQuery.minSampleCountInclusive,
            maxSampleCount: effectiveQuery.maxSampleCount,
            maxSampleCountInclusive: effectiveQuery.maxSampleCountInclusive,
            nameFilter: effectiveQuery.nameFilter,
            geneList: activeGeneList ?? [],
            selectedSamples: selectedSamples.sorted()
        )

        // Determine the effective region for the query (fast — no database queries).
        let effectiveRegion: (chromosome: String, start: Int, end: Int)?
        var regionScope: VariantQueryScope = .global

        // For large databases (>1 GB), scope filtered queries to the current chromosome
        // instead of scanning genome-wide, which would be prohibitively slow.
        var filterChromosome: String?
        if activeGeneList != nil {
            // Gene list path — region is not used
            effectiveRegion = nil
            regionScope = .global
        } else if hasGlobalOverrideFilters {
            effectiveRegion = nil
            if isLargeDatabase, let vp = viewportRegion, viewportSyncEnabled {
                // Large database — scope to chromosome for performance
                filterChromosome = vp.chromosome
                regionScope = .chromosome
            } else {
                regionScope = viewportPostFilterRegion != nil ? .viewport : .global
            }
        } else if let selected = selectedAnnotationRegion {
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
                baseDisplayedVariantAnnotations = []
                displayedAnnotations = []
                tableView.reloadData()
                scrollView.isHidden = true
                tooManyLabel.stringValue = "Navigate to a region to view variants"
                tooManyLabel.isHidden = false
                updateCountLabel()
                return
            }
        } else if viewportSyncEnabled, let annotationRegion = annotationSearchRegion {
            effectiveRegion = annotationRegion
            regionScope = .annotations
        } else {
            effectiveRegion = nil
        }

        // Freeze filterChromosome for safe capture in the @Sendable dispatch closure.
        let frozenFilterChromosome = filterChromosome

        // In Region scope, queries stay region-bound (viewport/annotation/query region).
        // In Genome scope, filtered queries can run globally.
        let requestedRegion = hasGlobalOverrideFilters ? nil : (frozenQuery.region ?? effectiveRegion)
        let frozenRegionScope = regionScope

        // No gene list active — dismiss tab bar immediately
        if activeGeneList == nil {
            delegate?.annotationDrawer(self, didResolveGeneRegions: [])
        }

        // Build the background query context from the index snapshot.
        var trackNameSnapshot: [String: String] = [:]
        for handle in index.variantDatabaseHandles {
            if let name = index.variantTrackName(for: handle.trackId) {
                trackNameSnapshot[handle.trackId] = name
            }
        }
        let ctx = VariantQueryContext(
            databases: index.variantDatabaseHandles,
            trackNames: trackNameSnapshot,
            trackChromosomes: index.variantTrackChromosomeMap,
            annotationDatabases: index.annotationDatabaseHandles,
            infoKeys: infoKeySet,
            variantAliasMap: variantChromosomeAliasMap
        )
        let maxDisplay = Self.maxDisplayCount

        if hasGlobalOverrideFilters, let viewportPostFilterRegion,
           cachedGlobalFilteredVariantKey == cacheKey, !cachedGlobalFilteredVariantRows.isEmpty {
            let filtered = filterVariantsToRegionOffMain(
                cachedGlobalFilteredVariantRows,
                chromosome: viewportPostFilterRegion.chromosome,
                start: viewportPostFilterRegion.start,
                end: viewportPostFilterRegion.end
            )
            setVariantBaseResults(Array(filtered.prefix(maxDisplay)))
            lastVariantQueryMatchCount = displayedAnnotations.count
            lastVariantQueryScope = .viewport
            tableView.reloadData()
            scrollView.isHidden = false
            tooManyLabel.isHidden = true
            hideVariantQueryProgress()
            updateCountLabel()
            return
        }

        variantQueryWorkItem?.cancel()
        variantQueryWorkItem = nil
        activeVariantQueryCancelToken?.cancel()

        // Increment generation counter — any in-flight queries with older generations are stale.
        variantQueryGeneration += 1
        let thisGeneration = variantQueryGeneration
        let cancelToken = VariantQueryCancellationToken()
        activeVariantQueryCancelToken = cancelToken

        // Show progress indicator.
        showVariantQueryProgress("Searching variants\u{2026}")
        #if DEBUG
        debugVariantQueryExecutionCount += 1
        #endif

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.variantQueryWorkItem = nil
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let shouldCancel = { cancelToken.isCancelled }
                if shouldCancel() { return }

                // Capture all query parameters as value types (already done above).
                let results: [AnnotationSearchIndex.SearchResult]
                let matchCount: Int?
                let queryScope: VariantQueryScope
                var tooManyMessage: String?
                var resolvedGeneRegions: [GeneRegion] = []
                var globalRowsForCache: [AnnotationSearchIndex.SearchResult]?

                // Build post-filter closure that operates only on captured value types.
                let applyAllPostFilters: ([AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] = { rows in
                    var filtered = applyVariantAdvancedFiltersOffMain(rows, query: frozenQuery)
                    if filterModerateOrHigher {
                        filtered = filterModerateOrHigherImpactOffMain(filtered)
                    }
                    if filterBookmarkedOnly {
                        filtered = filtered.filter { result in
                            guard let rowId = result.variantRowId else { return false }
                            let key = "\(result.trackId):\(rowId)"
                            return bookmarkSnapshot.contains(key)
                        }
                    }
                    if let afRange = withinSampleAFRange {
                        filtered = filterByWithinSampleAFOffMain(filtered, min: afRange.min, max: afRange.max)
                    }
                    return filtered
                }

                if let activeGeneList, !activeGeneList.isEmpty {
                    // Gene list path — query variants overlapping gene regions + INFO gene keys.
                    var geneQuery = frozenQuery
                    if inferredGeneList != nil {
                        geneQuery.nameFilter = ""
                    }
                    let needsGenePostFiltering = usePostFiltering || !geneQuery.nameFilter.isEmpty
                    let initialLimit = needsGenePostFiltering ? max(maxDisplay * 3, maxDisplay) : maxDisplay
                    let geneQueryResult = ctx.queryVariantsForGenes(
                        activeGeneList,
                        types: frozenTypeFilter,
                        infoFilters: mergedInfoFilters,
                        sampleNames: selectedSamples,
                        activeTokens: frozenActiveTokens,
                        limit: max(initialLimit, maxDisplay),
                        shouldCancel: shouldCancel
                    )
                    if shouldCancel() { return }
                    resolvedGeneRegions = geneQueryResult.resolvedRegions
                    let filtered = fetchVariantsAdaptive(
                        maxDisplayCount: maxDisplay,
                        initialFetchLimit: initialLimit,
                        totalSQLMatchCount: nil,
                        applyPostFiltering: needsGenePostFiltering,
                        fetch: { limit in
                            if limit <= geneQueryResult.results.count {
                                return Array(geneQueryResult.results.prefix(limit))
                            }
                            return ctx.queryVariantsForGenes(
                                activeGeneList,
                                types: frozenTypeFilter,
                                infoFilters: mergedInfoFilters,
                                sampleNames: selectedSamples,
                                activeTokens: frozenActiveTokens,
                                limit: max(limit, maxDisplay),
                                shouldCancel: shouldCancel
                            ).results
                        },
                        postFilter: { rows in
                            var filteredRows = applyAllPostFilters(rows)
                            if !geneQuery.nameFilter.isEmpty {
                                let needle = geneQuery.nameFilter.lowercased()
                                filteredRows = filteredRows.filter { $0.name.lowercased().contains(needle) }
                            }
                            return filteredRows
                        },
                        shouldCancel: shouldCancel
                    )
                    if shouldCancel() { return }
                    globalRowsForCache = filtered
                    if let viewportPostFilterRegion {
                        results = Array(
                            filterVariantsToRegionOffMain(
                                filtered,
                                chromosome: viewportPostFilterRegion.chromosome,
                                start: viewportPostFilterRegion.start,
                                end: viewportPostFilterRegion.end
                            ).prefix(maxDisplay)
                        )
                    } else {
                        results = filtered
                    }
                    matchCount = results.count
                    queryScope = viewportPostFilterRegion != nil ? .viewport : .global
                    tooManyMessage = nil

                } else if let region = requestedRegion {
                    // Region-scoped query — probe fetch pattern (no separate COUNT).
                    let probeLimit = usePostFiltering ? max(maxDisplay * 3, maxDisplay) : maxDisplay + 1
                    let filtered = fetchVariantsAdaptive(
                        maxDisplayCount: maxDisplay,
                        initialFetchLimit: probeLimit,
                        totalSQLMatchCount: nil,
                        applyPostFiltering: usePostFiltering,
                        fetch: { limit in
                            ctx.queryVariantsInRegion(
                                chromosome: region.chromosome, start: region.start, end: region.end,
                                nameFilter: frozenQuery.nameFilter, types: frozenTypeFilter,
                                infoFilters: mergedInfoFilters,
                                sampleNames: selectedSamples,
                                activeTokens: frozenActiveTokens,
                                limit: limit,
                                shouldCancel: shouldCancel
                            )
                        },
                        postFilter: applyAllPostFilters,
                        shouldCancel: shouldCancel
                    )
                    if shouldCancel() { return }
                    if let viewportPostFilterRegion {
                        results = Array(
                            filterVariantsToRegionOffMain(
                                filtered,
                                chromosome: viewportPostFilterRegion.chromosome,
                                start: viewportPostFilterRegion.start,
                                end: viewportPostFilterRegion.end
                            ).prefix(maxDisplay)
                        )
                        matchCount = results.count
                    } else if filtered.count > maxDisplay {
                        // Probe returned more than maxDisplay — show first maxDisplay with "N+" count
                        results = Array(filtered.prefix(maxDisplay))
                        matchCount = nil  // signals "more than displayed" for N+ label
                    } else {
                        results = filtered
                        matchCount = filtered.count
                    }
                    queryScope = frozenRegionScope
                    tooManyMessage = nil

                } else {
                    // Global query — probe fetch pattern (no separate COUNT).
                    let probeLimit = usePostFiltering ? max(maxDisplay * 3, maxDisplay) : maxDisplay + 1
                    let filtered = fetchVariantsAdaptive(
                        maxDisplayCount: maxDisplay,
                        initialFetchLimit: probeLimit,
                        totalSQLMatchCount: nil,
                        applyPostFiltering: usePostFiltering,
                        fetch: { limit in
                            ctx.queryVariantsOnly(
                                chromosome: frozenFilterChromosome,
                                nameFilter: frozenQuery.nameFilter, types: frozenTypeFilter,
                                infoFilters: mergedInfoFilters,
                                sampleNames: selectedSamples,
                                activeTokens: frozenActiveTokens,
                                limit: limit,
                                shouldCancel: shouldCancel
                            )
                        },
                        postFilter: applyAllPostFilters,
                        shouldCancel: shouldCancel
                    )
                    if shouldCancel() { return }
                    globalRowsForCache = filtered
                    if let viewportPostFilterRegion {
                        results = Array(
                            filterVariantsToRegionOffMain(
                                filtered,
                                chromosome: viewportPostFilterRegion.chromosome,
                                start: viewportPostFilterRegion.start,
                                end: viewportPostFilterRegion.end
                            ).prefix(maxDisplay)
                        )
                        matchCount = results.count
                    } else if filtered.count > maxDisplay {
                        // Probe returned more than maxDisplay — show first maxDisplay with "N+" count
                        results = Array(filtered.prefix(maxDisplay))
                        matchCount = nil  // signals "more than displayed" for N+ label
                    } else {
                        results = filtered
                        matchCount = filtered.count
                    }
                    if frozenFilterChromosome != nil {
                        queryScope = .chromosome
                    } else {
                        queryScope = viewportPostFilterRegion != nil ? .viewport : .global
                    }
                    tooManyMessage = nil
                }

                // Deliver results on main thread.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              self.variantQueryGeneration == thisGeneration,
                              self.activeTab == .variants else { return }
                        self.hideVariantQueryProgress()
                        self.setVariantBaseResults(results)
                        self.lastVariantQueryMatchCount = matchCount
                        self.lastVariantQueryScope = queryScope
                        self.activeVariantQueryCancelToken = nil
                        if hasGlobalOverrideFilters, let rows = globalRowsForCache {
                            self.cachedGlobalFilteredVariantRows = rows
                            self.cachedGlobalFilteredVariantKey = cacheKey
                        } else if !hasGlobalOverrideFilters {
                            self.cachedGlobalFilteredVariantRows = []
                            self.cachedGlobalFilteredVariantKey = nil
                        }

                        if let tooManyMessage {
                            self.tableView.reloadData()
                            self.scrollView.isHidden = true
                            self.tooManyLabel.stringValue = tooManyMessage
                            self.tooManyLabel.isHidden = false
                        } else {
                            self.tableView.reloadData()
                            self.scrollView.isHidden = false
                            self.tooManyLabel.isHidden = true
                        }

                        if activeGeneList != nil {
                            self.delegate?.annotationDrawer(self, didResolveGeneRegions: resolvedGeneRegions)
                        }

                        self.updateCountLabel()

                        // Rebuild genotypes if the genotype subtab is active.
                        if self.activeVariantSubtab == .genotypes {
                            self.buildGenotypeRows()
                        }
                    }
                }
            }
        }
        variantQueryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.variantQueryDebounceInterval, execute: workItem)
    }

    private func filterByWithinSampleAF(
        _ results: [AnnotationSearchIndex.SearchResult],
        min: Double,
        max: Double
    ) -> [AnnotationSearchIndex.SearchResult] {
        // Use only the plain "AF" key for within-sample frequency (not population keys
        // like gnomAD_AF). For haploid organisms, INFO AF is within-sample frequency.
        return results.filter { result in
            guard let info = result.infoDict,
                  let raw = info["AF"] ?? info["af"],
                  !raw.isEmpty else { return false }
            // Handle multi-allelic: "0.05,0.12" — use the max AF across alts
            let values = raw.split(separator: ",").compactMap { Double($0) }
            guard let af = values.max() else { return false }
            return af >= min && af <= max
        }
    }

    private func filterModerateOrHigherImpact(_ results: [AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] {
        let impactKeys = SmartToken.impactKeys
        return results.filter { result in
            guard let info = result.infoDict else { return false }
            for key in impactKeys {
                guard let raw = info[key], !raw.isEmpty else { continue }
                let value = raw.uppercased()
                if value.contains("HIGH") || value.contains("MODERATE") {
                    return true
                }
            }
            return false
        }
    }

    func updateCountLabel() {
        defer {
            emitVisibleVariantRenderKeyUpdateIfNeeded()
            emitVisibleAnnotationRenderKeyUpdateIfNeeded()
        }
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            let count = displayedGenotypes.count
            countLabel.stringValue = "\(count) genotype\(count == 1 ? "" : "s")"
            return
        }
        if activeTab == .samples {
            let total = allSampleRowKeys.count
            let shown = displayedSamples.count
            let hidden = allSampleRowKeys.reduce(into: 0) { count, rowKey in
                guard let sampleName = sampleNameByRowKey[rowKey] else { return }
                if currentSampleDisplayState.hiddenSamples.contains(sampleName) {
                    count += 1
                }
            }
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
        } else if activeTab == .annotations && !annotationColumnFilterClauses.isEmpty {
            let shown = numberFormatter.string(from: NSNumber(value: displayedAnnotations.count)) ?? "\(displayedAnnotations.count)"
            let base = numberFormatter.string(from: NSNumber(value: baseDisplayedAnnotationRows.count)) ?? "\(baseDisplayedAnnotationRows.count)"
            let filterDesc = annotationColumnFilterClauses.map { clause in
                let displayKey = clause.key.hasPrefix("attr_") ? String(clause.key.dropFirst(5)) : clause.key
                if clause.value.isEmpty {
                    return clause.op == "=" ? "\(displayKey) is empty" : "\(displayKey) is not empty"
                }
                return "\(displayKey)\(clause.op)\(clause.value)"
            }.joined(separator: ", ")
            countLabel.stringValue = "\(shown) of \(base) shown (\(filterDesc))"
        } else if activeTab == .variants {
            // Unified variant count label using tracked scope and match count.
            // matchCount == nil signals "more than displayed" (probe fetch overflow) → show "N+" format.
            if !variantColumnFilterClauses.isEmpty {
                let shown = numberFormatter.string(from: NSNumber(value: displayedAnnotations.count)) ?? "\(displayedAnnotations.count)"
                let base = numberFormatter.string(from: NSNumber(value: baseDisplayedVariantAnnotations.count)) ?? "\(baseDisplayedVariantAnnotations.count)"
                let filterDesc = variantColumnFilterClauses.map { clause in
                    let displayKey = clause.key.hasPrefix("info_") ? String(clause.key.dropFirst(5)) : clause.key
                    if clause.value.isEmpty {
                        return clause.op == "=" ? "\(displayKey) is empty" : "\(displayKey) is not empty"
                    }
                    return "\(displayKey)\(clause.op)\(clause.value)"
                }.joined(separator: ", ")
                countLabel.stringValue = "\(shown) of \(base) shown (\(filterDesc))"
                return
            }
            let total = numberFormatter.string(from: NSNumber(value: totalVariantCount)) ?? "\(totalVariantCount)"
            let displayCount = displayedAnnotations.count
            let displayCountStr = numberFormatter.string(from: NSNumber(value: displayCount)) ?? "\(displayCount)"
            switch lastVariantQueryScope {
            case .placeholder:
                countLabel.stringValue = "\(total) variants total"
            case .annotation:
                if let count = lastVariantQueryMatchCount {
                    let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                    countLabel.stringValue = "\(shown) overlapping (\(total) total)"
                } else {
                    countLabel.stringValue = "\(displayCountStr)+ overlapping (\(total) total)"
                }
            case .chromosome:
                if let count = lastVariantQueryMatchCount {
                    let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                    countLabel.stringValue = "\(shown) on chromosome (\(total) total)"
                } else {
                    countLabel.stringValue = "\(displayCountStr)+ on chromosome (\(total) total)"
                }
            case .viewport:
                if let count = lastVariantQueryMatchCount {
                    let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                    countLabel.stringValue = "\(shown) in viewport (\(total) total)"
                } else {
                    countLabel.stringValue = "\(displayCountStr)+ in viewport (\(total) total)"
                }
            case .annotations:
                if let count = lastVariantQueryMatchCount {
                    let shown = numberFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
                    countLabel.stringValue = "\(shown) near annotations (\(total) total)"
                } else {
                    countLabel.stringValue = "\(displayCountStr)+ near annotations (\(total) total)"
                }
            case .global:
                if !tooManyLabel.isHidden {
                    countLabel.stringValue = "\(total) total — filter to browse"
                } else if let count = lastVariantQueryMatchCount, count == totalVariantCount {
                    countLabel.stringValue = "\(total) variants"
                } else if lastVariantQueryMatchCount == nil {
                    countLabel.stringValue = "\(displayCountStr)+ of \(total)"
                } else {
                    let shown = numberFormatter.string(from: NSNumber(value: displayCount)) ?? "\(displayCount)"
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
            markVariantFilterStateMutated()
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

    @objc private func annotationViewportFilterToggled(_ sender: NSButton) {
        setAnnotationViewportFilterEnabled(sender.state == .on)
    }

    func setAnnotationViewportFilterEnabled(_ enabled: Bool) {
        guard annotationViewportFilterEnabled != enabled else { return }
        annotationViewportFilterEnabled = enabled
        annotationViewportFilterButton.state = enabled ? .on : .off
        emitVisibleAnnotationRenderKeyUpdateIfNeeded()
    }

    var isAnnotationViewportFilterControlVisible: Bool {
        !annotationViewportFilterButton.isHidden
    }

    private var annotationTrackDisplayState: AnnotationTrackDisplayState {
        AnnotationTrackDisplayState(
            order: annotationTrackOrder,
            hiddenTrackIDs: hiddenAnnotationTrackIDs,
            displayNames: annotationTrackDisplayNames
        )
    }

    private func syncAnnotationTracks(from trackIDs: [String]) {
        var seen: Set<String> = []
        let discovered = trackIDs.filter { trackID in
            guard !trackID.isEmpty, !seen.contains(trackID) else { return false }
            seen.insert(trackID)
            return true
        }
        guard !discovered.isEmpty else { return }

        let discoveredSet = Set(discovered)
        var nextOrder = annotationTrackOrder.filter { discoveredSet.contains($0) }
        let orderedSet = Set(nextOrder)
        nextOrder.append(contentsOf: discovered.filter { !orderedSet.contains($0) })

        let changed = nextOrder != annotationTrackOrder
            || !hiddenAnnotationTrackIDs.isSubset(of: discoveredSet)
        annotationTrackOrder = nextOrder
        hiddenAnnotationTrackIDs = hiddenAnnotationTrackIDs.intersection(discoveredSet)
        for trackID in discovered where annotationTrackDisplayNames[trackID] == nil {
            annotationTrackDisplayNames[trackID] = trackID
        }

        updateSearchFieldVisibility()
        if changed {
            emitAnnotationTrackDisplayStateIfNeeded()
        }
    }

    private func emitAnnotationTrackDisplayStateIfNeeded() {
        let state = annotationTrackDisplayState
        guard state != lastEmittedAnnotationTrackDisplayState else { return }
        lastEmittedAnnotationTrackDisplayState = state
        delegate?.annotationDrawer(self, didUpdateAnnotationTrackDisplayState: state)
    }

    private func setAnnotationTrackVisible(trackId: String, visible: Bool) {
        guard annotationTrackOrder.contains(trackId) else { return }
        if visible {
            hiddenAnnotationTrackIDs.remove(trackId)
        } else {
            hiddenAnnotationTrackIDs.insert(trackId)
        }
        emitAnnotationTrackDisplayStateIfNeeded()
    }

    private func moveAnnotationTrack(trackId: String, direction: AnnotationTrackMoveDirection) {
        guard let index = annotationTrackOrder.firstIndex(of: trackId) else { return }
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = max(0, index - 1)
        case .down:
            targetIndex = min(annotationTrackOrder.count - 1, index + 1)
        }
        guard targetIndex != index else { return }
        annotationTrackOrder.swapAt(index, targetIndex)
        emitAnnotationTrackDisplayStateIfNeeded()
    }

    @objc private func showAnnotationTracksMenu(_ sender: NSButton) {
        let menu = NSMenu()
        if annotationTrackOrder.isEmpty {
            let item = NSMenuItem(title: "No Annotation Tracks", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for trackID in annotationTrackOrder {
                let item = NSMenuItem(title: annotationTrackDisplayNames[trackID] ?? trackID, action: nil, keyEquivalent: "")
                let submenu = NSMenu()

                let visibleItem = NSMenuItem(
                    title: "Visible",
                    action: #selector(toggleAnnotationTrackVisibility(_:)),
                    keyEquivalent: ""
                )
                visibleItem.target = self
                visibleItem.representedObject = trackID
                visibleItem.state = hiddenAnnotationTrackIDs.contains(trackID) ? .off : .on
                submenu.addItem(visibleItem)

                submenu.addItem(.separator())

                let moveUpItem = NSMenuItem(
                    title: "Move Up",
                    action: #selector(moveAnnotationTrackUp(_:)),
                    keyEquivalent: ""
                )
                moveUpItem.target = self
                moveUpItem.representedObject = trackID
                moveUpItem.isEnabled = annotationTrackOrder.first != trackID
                submenu.addItem(moveUpItem)

                let moveDownItem = NSMenuItem(
                    title: "Move Down",
                    action: #selector(moveAnnotationTrackDown(_:)),
                    keyEquivalent: ""
                )
                moveDownItem.target = self
                moveDownItem.representedObject = trackID
                moveDownItem.isEnabled = annotationTrackOrder.last != trackID
                submenu.addItem(moveDownItem)

                item.submenu = submenu
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func toggleAnnotationTrackVisibility(_ sender: NSMenuItem) {
        guard let trackID = sender.representedObject as? String else { return }
        setAnnotationTrackVisible(trackId: trackID, visible: hiddenAnnotationTrackIDs.contains(trackID))
    }

    @objc private func moveAnnotationTrackUp(_ sender: NSMenuItem) {
        guard let trackID = sender.representedObject as? String else { return }
        moveAnnotationTrack(trackId: trackID, direction: .up)
    }

    @objc private func moveAnnotationTrackDown(_ sender: NSMenuItem) {
        guard let trackID = sender.representedObject as? String else { return }
        moveAnnotationTrack(trackId: trackID, direction: .down)
    }

    private struct AnnotationFilterQuery {
        var nameFilter: String = ""
        var typeFilter: Set<String>?
        var chromosome: String?
        var strand: String?
        var start: Int?
        var end: Int?
    }

    fileprivate struct VariantFilterQuery {
        var nameFilter: String = ""
        var explicitTypeFilter: Set<String>?
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
        /// If set, only show variants where FILTER column matches (e.g. "PASS").
        var filterValue: String?
        /// If set, restrict results to variants overlapping these gene names.
        var geneList: [String]?

        var hasPostFilters: Bool {
            minQuality != nil || maxQuality != nil || minSampleCount != nil || maxSampleCount != nil || filterValue != nil
        }
    }

    private struct SampleFilterQuery {
        var textFilter: String = ""
        var nameFilter: (op: String, value: String)?
        var sourceFilter: (op: String, value: String)?
        var visibility: Bool?
        var metadataFilters: [(field: String, op: String, value: String)] = []
    }

    struct ColumnFilterClause {
        var key: String
        var op: String
        var value: String
    }
    typealias VariantColumnFilterClause = ColumnFilterClause

    private struct ParsedSearchClause {
        var key: String?
        var op: String
        var value: String
    }

    /// Semicolon-delimited parser used for explicit advanced search, e.g.:
    /// `chr=NC_041760.1;pos=100-200;qual>=30;DP>=20`.
    private func parseSearchClauses(_ text: String) -> [ParsedSearchClause] {
        let operators = ["!~", "^=", "$=", ">=", "<=", "!=", "~", ">", "<", "="]
        return text.split(separator: ";").compactMap { segment in
            let token = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            for op in operators {
                if let range = token.range(of: op) {
                    let key = String(token[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(token[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if key.isEmpty {
                        return ParsedSearchClause(key: nil, op: op, value: String(value))
                    }
                    return ParsedSearchClause(key: String(key), op: op, value: String(value))
                }
            }
            return ParsedSearchClause(key: nil, op: "", value: token)
        }
    }

    private func infoComparisonOp(from op: String) -> VariantDatabase.InfoFilter.ComparisonOp {
        switch op {
        case ">": return .gt
        case ">=": return .gte
        case "<": return .lt
        case "<=": return .lte
        case "!=": return .neq
        case "~": return .like
        default: return .eq
        }
    }

    private func parseVariantTypesList(_ raw: String) -> Set<String> {
        Set(
            raw.split(whereSeparator: { $0 == "," || $0 == "|" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Parses advanced annotation search syntax:
    /// `type:gene chr:NC_045512 strand:+ region:NC_045512:100-900 myName`
    private func parseAnnotationFilterText(_ text: String) -> AnnotationFilterQuery {
        if text.contains(";") {
            var query = AnnotationFilterQuery()
            var freeTokens: [String] = []
            for clause in parseSearchClauses(text) {
                guard let rawKey = clause.key?.lowercased() else {
                    freeTokens.append(clause.value)
                    continue
                }
                switch rawKey {
                case "text", "name", "id":
                    freeTokens.append(clause.value)
                case "type":
                    let values = clause.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    if !values.isEmpty {
                        query.typeFilter = Set(values)
                    }
                case "chr", "chrom", "chromosome":
                    query.chromosome = clause.value
                case "strand":
                    query.strand = clause.value
                case "start":
                    query.start = Int(clause.value)
                case "end":
                    query.end = Int(clause.value)
                case "region":
                    if let parsed = parseRegion(clause.value) {
                        query.chromosome = parsed.chromosome
                        query.start = parsed.start
                        query.end = parsed.end
                    }
                default:
                    freeTokens.append(clause.value)
                }
            }
            query.nameFilter = freeTokens.joined(separator: " ")
            return query
        }

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
        if text.contains(";") {
            var query = VariantFilterQuery()
            var nameTokens: [String] = []
            for clause in parseSearchClauses(text) {
                guard let rawKeyText = clause.key?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKeyText.isEmpty else {
                    if let parsed = VariantDatabase.InfoFilter.parse(clause.value) {
                        query.infoFilters.append(resolveVariantInfoFilter(parsed))
                    } else {
                        nameTokens.append(clause.value)
                    }
                    continue
                }
                let rawKey = rawKeyText.lowercased()
                switch rawKey {
                case "text", "name", "id":
                    nameTokens.append(clause.value)
                case "chr", "chrom", "chromosome":
                    let value = clause.value
                    if let region = query.region {
                        query.region = (value, region.start, region.end)
                    } else {
                        query.region = (value, 0, Int.max)
                    }
                case "pos", "range":
                    if let range = parseRange(clause.value) {
                        let chr = query.region?.chromosome ?? viewportRegion?.chromosome ?? ""
                        if !chr.isEmpty {
                            query.region = (chr, range.start, range.end)
                        }
                    }
                case "region":
                    if let parsed = parseRegion(clause.value) {
                        query.region = parsed
                    }
                case "qual", "quality":
                    if let value = Double(clause.value) {
                        switch clause.op {
                        case ">", ">=":
                            query.minQuality = value
                            query.minQualityInclusive = clause.op == ">="
                        case "<", "<=":
                            query.maxQuality = value
                            query.maxQualityInclusive = clause.op == "<="
                        default:
                            query.minQuality = value
                            query.maxQuality = value
                            query.minQualityInclusive = true
                            query.maxQualityInclusive = true
                        }
                    }
                case "sc", "samples", "samplecount":
                    if let value = Double(clause.value) {
                        let count = Int(value.rounded())
                        switch clause.op {
                        case ">", ">=":
                            query.minSampleCount = count
                            query.minSampleCountInclusive = clause.op == ">="
                        case "<", "<=":
                            query.maxSampleCount = count
                            query.maxSampleCountInclusive = clause.op == "<="
                        default:
                            query.minSampleCount = count
                            query.maxSampleCount = count
                            query.minSampleCountInclusive = true
                            query.maxSampleCountInclusive = true
                        }
                    }
                case "filter":
                    query.filterValue = clause.value
                case "genes", "genelist", "gene_list":
                    let genes = clause.value
                        .replacingOccurrences(of: "\n", with: ",")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !genes.isEmpty {
                        query.geneList = (query.geneList ?? []) + genes
                    }
                case "type", "variant_type":
                    let parsedTypes = parseVariantTypesList(clause.value)
                    if !parsedTypes.isEmpty {
                        if let existing = query.explicitTypeFilter {
                            query.explicitTypeFilter = existing.intersection(parsedTypes)
                        } else {
                            query.explicitTypeFilter = parsedTypes
                        }
                    }
                default:
                    guard !clause.value.isEmpty else { continue }
                    query.infoFilters.append(
                        VariantDatabase.InfoFilter(
                            key: resolveVariantInfoKey(rawKeyText),
                            op: infoComparisonOp(from: clause.op),
                            value: clause.value
                        )
                    )
                }
            }
            query.nameFilter = nameTokens.joined(separator: " ")
            if let region = query.region, region.chromosome.isEmpty {
                query.region = nil
            }
            return query
        }

        var query = VariantFilterQuery()
        var nameTokens: [String] = []

        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let knownClausePrefixes = [
            "chr:", "chrom:", "pos:", "range:",
            "type:", "type=", "variant_type:", "variant_type=",
            "genes=", "genes:", "genelist=", "genelist:", "gene_list=", "gene_list:",
            "filter=", "filter:"
        ]

        var idx = 0
        while idx < tokens.count {
            let token = tokens[idx]
            if let value = token.value(after: "chr:") ?? token.value(after: "chrom:") {
                if let region = query.region {
                    query.region = (value, region.start, region.end)
                } else {
                    query.region = (value, 0, Int.max)
                }
                idx += 1
                continue
            }
            if let value = token.value(after: "pos:") ?? token.value(after: "range:"),
               let range = parseRange(value) {
                let chr = query.region?.chromosome ?? viewportRegion?.chromosome ?? ""
                if !chr.isEmpty {
                    query.region = (chr, range.start, range.end)
                }
                idx += 1
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
                idx += 1
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
                idx += 1
                continue
            }
            if let value = token.value(after: "type:") ?? token.value(after: "type=") ?? token.value(after: "variant_type:") {
                let parsedTypes = parseVariantTypesList(value)
                if !parsedTypes.isEmpty {
                    if let existing = query.explicitTypeFilter {
                        query.explicitTypeFilter = existing.intersection(parsedTypes)
                    } else {
                        query.explicitTypeFilter = parsedTypes
                    }
                }
                idx += 1
                continue
            }
            if let value = token.value(after: "genes=") ?? token.value(after: "genelist=") ?? token.value(after: "gene_list=")
                            ?? token.value(after: "genes:") ?? token.value(after: "genelist:") ?? token.value(after: "gene_list:") {
                var geneValue = value
                while geneValue.hasSuffix(",") && idx + 1 < tokens.count {
                    let next = tokens[idx + 1]
                    let nextLower = next.lowercased()
                    let nextStartsClause = knownClausePrefixes.contains { nextLower.hasPrefix($0) }
                        || VariantDatabase.InfoFilter.parse(next) != nil
                        || parseComparisonToken(next, keys: ["qual", "quality", "sc", "samples", "samplecount"]) != nil
                    if nextStartsClause {
                        break
                    }
                    geneValue += next
                    idx += 1
                }

                let genes = geneValue
                    .replacingOccurrences(of: "\n", with: ",")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !genes.isEmpty {
                    query.geneList = (query.geneList ?? []) + genes
                }
                idx += 1
                continue
            }
            if let value = token.value(after: "filter=") ?? token.value(after: "filter:") {
                query.filterValue = value
                idx += 1
                continue
            }
            if let parsed = VariantDatabase.InfoFilter.parse(token) {
                query.infoFilters.append(resolveVariantInfoFilter(parsed))
                idx += 1
                continue
            }
            nameTokens.append(token)
            idx += 1
        }
        query.nameFilter = nameTokens.joined(separator: " ")
        // Discard placeholder region if no valid chromosome was specified.
        if let region = query.region, region.chromosome.isEmpty {
            query.region = nil
        }
        return query
    }

    /// Resolves a user-facing or logical INFO key (e.g. "IMPACT", "GENE") to a concrete
    /// INFO key present in the loaded VCF, preferring exact/real keys when available.
    private func resolveVariantInfoKey(_ requestedKey: String) -> String {
        let trimmed = requestedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return requestedKey }

        let availableKeys = infoColumnKeys.map(\.key)
        let availableSet = Set(availableKeys)
        if availableSet.contains(trimmed) {
            return trimmed
        }
        if let caseInsensitiveMatch = availableKeys.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return caseInsensitiveMatch
        }

        let normalized = trimmed.lowercased()
        let aliases: [String]
        switch normalized {
        case "impact":
            aliases = ["CSQ_IMPACT", "ANN_IMPACT", "IMPACT", "impact"]
        case "gene":
            aliases = ["CSQ_SYMBOL", "ANN_Gene", "GENE", "Gene", "gene", "GENEINFO"]
        case "clnsig", "clinvar", "clinvar_sig":
            aliases = ["CLNSIG", "ClinVar_SIG", "clinvar_sig", "CLNDN"]
        case "af":
            aliases = ["AF", "af", "gnomAD_AF", "gnomADe_AF", "gnomADg_AF", "ExAC_AF", "1000G_AF", "MAX_AF"]
        default:
            aliases = []
        }

        for alias in aliases where availableSet.contains(alias) {
            return alias
        }
        return trimmed
    }

    private func resolveVariantInfoFilter(_ filter: VariantDatabase.InfoFilter) -> VariantDatabase.InfoFilter {
        VariantDatabase.InfoFilter(
            key: resolveVariantInfoKey(filter.key),
            op: filter.op,
            value: filter.value
        )
    }

    #if DEBUG
    func debugParseVariantFilterText(_ text: String) -> (nameFilter: String, geneList: [String], filterValue: String?) {
        let query = parseVariantFilterText(text)
        return (query.nameFilter, query.geneList ?? [], query.filterValue)
    }

    func debugParseVariantInfoFilterKeys(_ text: String) -> [String] {
        parseVariantFilterText(text).infoFilters.map(\.key)
    }

    func debugSetVariantScopeRegionEnabled(_ enabled: Bool) {
        viewportSyncEnabled = enabled
        updateScopeControlSelection()
    }

    func debugSetViewportRegion(chromosome: String, start: Int, end: Int) {
        viewportRegion = (chromosome: chromosome, start: start, end: end)
    }

    func debugSetVariantFilterText(_ text: String) {
        variantFilterText = text
        updateVariantFilterIndicator()
    }

    func debugSetAnnotationFilterText(_ text: String) {
        annotationFilterText = text
        annotationFilterField.stringValue = text
    }

    var debugAnnotationTrackDisplayState: AnnotationTrackDisplayState {
        annotationTrackDisplayState
    }

    func debugSetAnnotationTrackVisible(trackId: String, visible: Bool) {
        setAnnotationTrackVisible(trackId: trackId, visible: visible)
    }

    func debugMoveAnnotationTrack(trackId: String, direction: AnnotationTrackMoveDirection) {
        moveAnnotationTrack(trackId: trackId, direction: direction)
    }

    func debugSetSelectedAnnotationRegion(chromosome: String, start: Int, end: Int) {
        selectedAnnotationRegion = (chromosome: chromosome, start: start, end: end)
    }

    func debugRefreshDisplayedAnnotations() {
        updateDisplayedAnnotations()
    }

    func debugMarkViewportExploration() {
        allowViewportPostFilterDuringExploration = true
    }

    func debugGetVariantQueryExecutionCount() -> Int {
        debugVariantQueryExecutionCount
    }
    #endif

    /// Parses advanced sample syntax:
    /// `name:S1 source:run42 visible:true meta.Country:USA`
    private func parseSampleFilterText(_ text: String) -> SampleFilterQuery {
        let normalizedInput = text.replacingOccurrences(
            of: #"^\s*samples:\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        let explicitClauseOperators = ["!~", "^=", "$=", "!=", "~", "="]
        let hasExplicitClauseSyntax = explicitClauseOperators.contains { normalizedInput.contains($0) }
        if normalizedInput.contains(";") || hasExplicitClauseSyntax {
            var query = SampleFilterQuery()
            var freeTokens: [String] = []
            for clause in parseSearchClauses(normalizedInput) {
                guard let rawKey = clause.key?.trimmingCharacters(in: .whitespacesAndNewlines), !rawKey.isEmpty else {
                    freeTokens.append(clause.value)
                    continue
                }
                let key = rawKey.lowercased()
                switch key {
                case "text":
                    freeTokens.append(clause.value)
                case "name":
                    query.nameFilter = (op: clause.op, value: clause.value)
                case "source":
                    query.sourceFilter = (op: clause.op, value: clause.value)
                case "visible":
                    let lower = clause.value.lowercased()
                    if ["1", "true", "yes", "on"].contains(lower) {
                        query.visibility = clause.op == "!=" ? false : true
                    }
                    if ["0", "false", "no", "off"].contains(lower) {
                        query.visibility = clause.op == "!=" ? true : false
                    }
                default:
                    if key.hasPrefix("meta.") {
                        let field = String(rawKey.dropFirst(5))
                        if !field.isEmpty {
                            query.metadataFilters.append((field: field, op: clause.op, value: clause.value))
                        }
                    } else {
                        // Treat unknown keys as metadata fields for convenience.
                        query.metadataFilters.append((field: rawKey, op: clause.op, value: clause.value))
                    }
                }
            }
            query.textFilter = freeTokens.joined(separator: " ")
            return query
        }

        var query = SampleFilterQuery()
        var freeTokens: [String] = []
        for tokenSub in normalizedInput.split(whereSeparator: \.isWhitespace) {
            let token = String(tokenSub)
            if let value = token.value(after: "name:") {
                query.nameFilter = (op: "~", value: value)
            } else if let value = token.value(after: "source:") {
                query.sourceFilter = (op: "~", value: value)
            } else if let value = token.value(after: "visible:") {
                let lower = value.lowercased()
                if ["1", "true", "yes", "on"].contains(lower) { query.visibility = true }
                if ["0", "false", "no", "off"].contains(lower) { query.visibility = false }
            } else if token.lowercased().hasPrefix("meta."),
                      let sep = token.firstIndex(of: ":") {
                let key = String(token[token.index(token.startIndex, offsetBy: 5)..<sep])
                let value = String(token[token.index(after: sep)...])
                if !key.isEmpty, !value.isEmpty {
                    query.metadataFilters.append((field: key, op: "~", value: value))
                }
            } else {
                freeTokens.append(token)
            }
        }
        query.textFilter = freeTokens.joined(separator: " ")
        return query
    }

    private var hasActiveSampleFilters: Bool {
        if !sampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if !activeSampleTokens.isEmpty { return true }
        if selectedSampleGroupId != nil { return true }
        return false
    }

    private func updateSampleFilterIndicator() {
        let isSamplesTab = activeTab == .samples
        clearSampleFilterButton.isHidden = !isSamplesTab || !hasActiveSampleFilters
        sampleQueryBuilderButton.title = hasActiveSampleFilters ? "Edit Sample Query..." : "Sample Query..."
    }

    @objc private func clearSampleFilter(_ sender: Any) {
        sampleFilterText = ""
        activeSampleTokens.removeAll()
        selectedSampleGroupId = nil
        updateChipStates()
        updateDisplayedSamples()
    }

    @objc private func sampleTokenToggled(_ sender: NSButton) {
        guard let token = sampleTokenPayloads[ObjectIdentifier(sender)] else { return }
        if sender.state == .on {
            if let group = token.exclusivityGroupKey {
                for existing in activeSampleTokens where existing != token && existing.exclusivityGroupKey == group {
                    activeSampleTokens.remove(existing)
                }
            }
            activeSampleTokens.insert(token)
        } else {
            activeSampleTokens.remove(token)
        }
        updateChipStates()
        updateDisplayedSamples()
    }

    @objc private func openSampleSearchBuilder(_ sender: Any) {
        guard activeTab == .samples, let hostWindow = self.window else { return }
        let builderView = SampleQueryBuilderView(
            initialFilterText: sampleFilterText,
            metadataFields: sampleMetadataFields,
            onApply: { [weak self] filterText in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.sampleFilterText = filterText
                        self.updateChipStates()
                        self.updateDisplayedSamples()
                        hostWindow.endSheet(hostWindow.sheets.last ?? NSPanel())
                    }
                }
            },
            onCancel: {
                hostWindow.endSheet(hostWindow.sheets.last ?? NSPanel())
            }
        )

        let hostingController = NSHostingController(rootView: builderView)
        let sheetWindow = NSPanel(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.title = "Sample Query Builder"
        hostWindow.beginSheet(sheetWindow)
    }

    private func rebuildSampleGroupPresetMenu() {
        sampleGroupPresetButton.removeAllItems()
        sampleGroupPresetButton.addItem(withTitle: "Group Presets")
        sampleGroupPresetButton.item(at: 0)?.isEnabled = false

        let groups = currentSampleDisplayState.sampleGroups.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        guard !groups.isEmpty else {
            sampleGroupPresetButton.isEnabled = false
            return
        }

        sampleGroupPresetButton.menu?.addItem(.separator())
        for group in groups {
            let item = NSMenuItem(title: group.name, action: #selector(selectSampleGroupPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group.id.uuidString
            sampleGroupPresetButton.menu?.addItem(item)
        }
        sampleGroupPresetButton.menu?.addItem(.separator())
        let clearItem = NSMenuItem(title: "Show All Samples", action: #selector(clearSampleGroupPreset(_:)), keyEquivalent: "")
        clearItem.target = self
        sampleGroupPresetButton.menu?.addItem(clearItem)
        sampleGroupPresetButton.isEnabled = true
    }

    @objc private func selectSampleGroupPreset(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let group = currentSampleDisplayState.sampleGroups.first(where: { $0.id == id }) else { return }
        selectedSampleGroupId = id
        let shown = group.sampleNames
        currentSampleDisplayState.hiddenSamples = Set(allSampleNames.filter { !shown.contains($0) })
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc private func clearSampleGroupPreset(_ sender: NSMenuItem) {
        selectedSampleGroupId = nil
        currentSampleDisplayState.hiddenSamples.removeAll()
        postSampleDisplayStateChange()
        updateDisplayedSamples()
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
            if let explicitTypeFilter = query.explicitTypeFilter, !explicitTypeFilter.isEmpty {
                let matchesType = explicitTypeFilter.contains { candidate in
                    row.type.caseInsensitiveCompare(candidate) == .orderedSame
                }
                if !matchesType { return false }
            }
            if let filterVal = query.filterValue {
                let rowFilter = row.filter ?? "."
                if rowFilter.caseInsensitiveCompare(filterVal) != .orderedSame { return false }
            }
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

    /// Detects if the given text looks like a gene list (comma or newline-separated gene names).
    /// Returns the gene list if detected, nil otherwise.
    ///
    /// A gene list is detected when:
    /// - Text contains commas or newlines
    /// - All tokens are alphanumeric gene-like names (no operators like >, <, =, ;)
    /// - At least 2 tokens
    private func detectGeneListPattern(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Must contain commas or newlines to be a gene list
        guard trimmed.contains(",") || trimmed.contains("\n") else { return nil }
        // Must not contain operators (filter syntax)
        guard !trimmed.contains(";"), !trimmed.contains(">"), !trimmed.contains("<"),
              !trimmed.contains("="), !trimmed.contains(":") else { return nil }

        let genes = trimmed
            .replacingOccurrences(of: "\n", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard genes.count >= 2 else { return nil }
        return genes
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
        if activeTab == .variants {
            markVariantFilterStateMutated()
        }
        updateDisplayedAnnotations()
    }

    @objc private func selectAllTypes(_ sender: Any) {
        visibleTypes = Set(availableTypes)
        updateChipStates()
        if activeTab == .variants {
            markVariantFilterStateMutated()
        }
        updateDisplayedAnnotations()
    }

    @objc private func selectNoTypes(_ sender: Any) {
        visibleTypes.removeAll()
        updateChipStates()
        if activeTab == .variants {
            markVariantFilterStateMutated()
        }
        updateDisplayedAnnotations()
    }

    @objc private func openVariantSearchBuilder(_ sender: Any) {
        guard activeTab == .variants, let hostWindow = self.window else { return }
        guard !isMaterializedOnlyModeEnabled() else {
            NSSound.beep()
            return
        }

        let infoKeySet = Set(infoColumnKeys.map(\.key))
        let infoDefs = infoColumnKeys.map { InfoKeyDefinition(key: $0.key, type: $0.type, description: $0.description) }
        let executionScopeLabel = viewportSyncEnabled
            ? "Execution Scope: Region (current viewport/region)"
            : "Execution Scope: Genome-wide"
        let builderView = VariantQueryBuilderView(
            initialFilterText: variantFilterText,
            availableInfoKeys: infoKeySet,
            infoKeyDefinitions: infoDefs,
            availableVariantTypes: availableVariantTypes,
            sampleNames: allSampleNames,
            savedPresets: savedQueryPresets,
            executionScopeLabel: executionScopeLabel,
            onApply: { [weak self] filterText in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.variantFilterText = filterText
                        self.markVariantFilterStateMutated()
                        self.updateVariantFilterIndicator()
                        self.updateChipStates()
                        self.updateDisplayedAnnotations()
                        hostWindow.endSheet(hostWindow.sheets.last ?? NSPanel())
                    }
                }
            },
            onSavePreset: { [weak self] preset in
                guard let self else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.savedQueryPresets.append(preset)
                    }
                }
            },
            onCancel: {
                hostWindow.endSheet(hostWindow.sheets.last ?? NSPanel())
            }
        )

        let hostingController = NSHostingController(rootView: builderView)
        let sheetWindow = NSPanel(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.title = "Query Builder"
        hostWindow.beginSheet(sheetWindow)
    }

    /// Saved user query presets (not persisted across sessions yet — Phase 3 adds BundleViewState support).
    var savedQueryPresets: [QueryPreset] = []

    // MARK: - Filter Profiles

    /// Rebuilds the filter profile popup menu.
    func rebuildProfileMenu() {
        profileButton.removeAllItems()
        // Title item (pullsDown mode uses the first item as title)
        profileButton.addItem(withTitle: "Profiles")
        profileButton.item(at: 0)?.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)

        // "None" option to clear profile
        let noneItem = NSMenuItem(title: "No Profile", action: #selector(clearFilterProfile(_:)), keyEquivalent: "")
        noneItem.target = self
        profileButton.menu?.addItem(noneItem)

        profileButton.menu?.addItem(NSMenuItem.separator())

        // Built-in profiles
        let infoKeySet = Set(infoColumnKeys.map(\.key))
        let variantTypeSet = Set(availableVariantTypes)
        let hasGT = !allSampleNames.isEmpty
        for profile in FilterProfile.builtInProfiles {
            // Only show profiles whose tokens are available
            let tokens = profile.smartTokens
            let available = tokens.allSatisfy { $0.isAvailable(infoKeys: infoKeySet, variantTypes: variantTypeSet, hasGenotypes: hasGT, hasBookmarks: hasBookmarks, isHaploidOrganism: isHaploidOrganism) }
            guard available || tokens.isEmpty else { continue }
            let item = NSMenuItem(title: profile.name, action: #selector(selectFilterProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile
            profileButton.menu?.addItem(item)
        }

        // Custom profiles
        let customProfiles = FilterProfileStore.loadCustomProfiles(bundleIdentifier: searchIndex?.bundleIdentifier)
        if !customProfiles.isEmpty {
            profileButton.menu?.addItem(NSMenuItem.separator())
            for profile in customProfiles {
                let item = NSMenuItem(title: profile.name, action: #selector(selectFilterProfile(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = profile
                profileButton.menu?.addItem(item)
            }
        }

        // Save current as profile
        profileButton.menu?.addItem(NSMenuItem.separator())
        let saveItem = NSMenuItem(title: "Save Current as Profile\u{2026}", action: #selector(saveCurrentAsProfile(_:)), keyEquivalent: "")
        saveItem.target = self
        profileButton.menu?.addItem(saveItem)
    }

    @objc private func selectFilterProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? FilterProfile else { return }
        applyFilterProfile(profile)
    }

    @objc private func clearFilterProfile(_ sender: Any?) {
        activeSmartTokens.removeAll()
        selectedVariantPresetByKey.removeAll()
        variantFilterText = ""
        markVariantFilterStateMutated()
        updateVariantFilterIndicator()
        updateChipStates()
        updateDisplayedAnnotations()
    }

    private func applyFilterProfile(_ profile: FilterProfile) {
        // Apply smart tokens
        activeSmartTokens = profile.smartTokens.filter { isMaterializedTokenAllowedInStrictMode($0) }

        // Apply filter text
        variantFilterText = isMaterializedOnlyModeEnabled() ? "" : profile.filterText
        if isMaterializedOnlyModeEnabled() {
            selectedVariantPresetByKey.removeAll()
        }
        markVariantFilterStateMutated()

        // Update UI
        updateVariantFilterIndicator()
        updateChipStates()
        updateDisplayedAnnotations()
    }

    @objc private func saveCurrentAsProfile(_ sender: Any?) {
        guard let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Filter Profile"
        alert.informativeText = "Enter a name for this filter profile."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        nameField.placeholderString = "Profile name"
        alert.accessoryView = nameField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }

            let tokens = self.activeSmartTokens.map(\.rawValue)
            let profile = FilterProfile(name: name, activeTokens: tokens, filterText: self.variantFilterText)
            var customs = FilterProfileStore.loadCustomProfiles(bundleIdentifier: self.searchIndex?.bundleIdentifier)
            customs.append(profile)
            FilterProfileStore.saveCustomProfiles(customs, bundleIdentifier: self.searchIndex?.bundleIdentifier)
            self.rebuildProfileMenu()
        }
    }

    private func applySampleBuilderSettings(showSamplesText: String, orderText: String) {
        let shownSamples = showSamplesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !shownSamples.isEmpty {
            let shownSet = Set(shownSamples)
            currentSampleDisplayState.hiddenSamples = Set(allSampleNames.filter { !shownSet.contains($0) })
            hasSampleDisplayStateSeed = true
            postSampleDisplayStateChange()
        }

        let orderSamples = orderText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !orderSamples.isEmpty {
            let unique = Array(NSOrderedSet(array: orderSamples)) as? [String] ?? orderSamples
            let existing = Set(allSampleNames)
            var order = unique.filter { existing.contains($0) }
            order.append(contentsOf: allSampleNames.filter { !Set(order).contains($0) })
            currentSampleDisplayState.sampleOrder = order
            hasSampleDisplayStateSeed = true
            postSampleDisplayStateChange()
        }
    }

    private func normalizedRegionString(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = parseRegion(trimmed) {
            return "\(parsed.chromosome):\(parsed.start)-\(parsed.end)"
        }
        return nil
    }

    private func loadVariantPresetValuesIfNeeded() {
        guard variantPresetLoadState == .idle else { return }
        guard !isMaterializedOnlyModeEnabled() else {
            variantInfoPresetValues = []
            selectedVariantPresetByKey.removeAll()
            variantPresetLoadState = .loaded
            return
        }
        guard !infoColumnKeys.isEmpty, !variantTrackDatabaseURLs.isEmpty else {
            variantPresetLoadState = .loaded
            return
        }

        variantPresetLoadState = .loading
        presetFiltersToggleButton.isEnabled = false
        presetFiltersToggleButton.title = "Presets (loading...)"

        let keys = infoColumnKeys.map(\.key)
        let dbURLs = variantTrackDatabaseURLs

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let maxDistinctValues = 20
            let maxKeys = 4
            var presets: [(key: String, values: [String])] = []
            let databases = dbURLs.compactMap { try? VariantDatabase(url: $0) }

            for key in keys {
                var valueSet = Set<String>()
                var exceeded = false
                for db in databases {
                    let values = db.distinctInfoValues(forKey: key, limit: maxDistinctValues + 1)
                    for value in values {
                        valueSet.insert(value)
                        if valueSet.count > maxDistinctValues {
                            exceeded = true
                            break
                        }
                    }
                    if exceeded { break }
                }
                if exceeded || valueSet.isEmpty { continue }
                let sortedValues = valueSet.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                presets.append((key: key, values: sortedValues))
                if presets.count >= maxKeys { break }
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.variantInfoPresetValues = presets
                    self.selectedVariantPresetByKey = self.selectedVariantPresetByKey.filter { key, value in
                        presets.contains { $0.key == key && $0.values.contains(value) }
                    }
                    self.variantPresetLoadState = .loaded
                    self.presetFiltersToggleButton.isEnabled = true
                    self.presetFiltersToggleButton.title = self.showVariantPresetChips ? "Presets ▾" : "Presets ▸"
                    if self.activeTab == .variants && self.showVariantPresetChips {
                        self.rebuildChipButtons()
                    }
                    self.updateSearchFieldVisibility()
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func tableViewDoubleClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        // Samples and genotype subtab don't navigate on double-click
        guard activeTab != .samples else { return }
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            // Navigate to the variant's position for the genotype row
            guard row < displayedGenotypes.count else { return }
            let gt = displayedGenotypes[row]
            // Find the corresponding variant in displayedAnnotations to navigate
            if let variant = displayedAnnotations.first(where: { $0.variantRowId == gt.variantRowId }) {
                delegate?.annotationDrawer(self, didSelectAnnotation: variant)
            }
            return
        }
        guard row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        drawerLogger.info("AnnotationTableDrawerView: Double-clicked '\(annotation.name, privacy: .public)' on \(annotation.chromosome, privacy: .public)")
        delegate?.annotationDrawer(self, didSelectAnnotation: annotation)
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if activeTab == .samples { return displayedSamples.count }
        if activeTab == .variants && activeVariantSubtab == .genotypes { return displayedGenotypes.count }
        return displayedAnnotations.count
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

        if activeTab == .variants && activeVariantSubtab == .genotypes {
            displayedGenotypes.sort { a, b in
                let result: ComparisonResult
                switch key {
                case "sample": result = a.sampleName.localizedCaseInsensitiveCompare(b.sampleName)
                case "variant": result = a.variantID.localizedCaseInsensitiveCompare(b.variantID)
                case "chromosome": result = a.chromosome.localizedCaseInsensitiveCompare(b.chromosome)
                case "position":
                    result = a.position < b.position ? .orderedAscending : (a.position > b.position ? .orderedDescending : .orderedSame)
                case "genotype": result = a.genotype.localizedCaseInsensitiveCompare(b.genotype)
                case "zygosity": result = a.zygosity.localizedCaseInsensitiveCompare(b.zygosity)
                case "ad": result = a.alleleDepths.localizedCaseInsensitiveCompare(b.alleleDepths)
                case "dp":
                    let aVal = a.depth ?? -1
                    let bVal = b.depth ?? -1
                    result = aVal < bVal ? .orderedAscending : (aVal > bVal ? .orderedDescending : .orderedSame)
                case "gq":
                    let aVal = a.genotypeQuality ?? -1
                    let bVal = b.genotypeQuality ?? -1
                    result = aVal < bVal ? .orderedAscending : (aVal > bVal ? .orderedDescending : .orderedSame)
                case "ab":
                    let aVal = a.alleleBalance ?? -1.0
                    let bVal = b.alleleBalance ?? -1.0
                    result = aVal < bVal ? .orderedAscending : (aVal > bVal ? .orderedDescending : .orderedSame)
                default:
                    if key.hasPrefix("gtinfo_") {
                        let infoKey = String(key.dropFirst(7))
                        let aVal = a.infoDict[infoKey] ?? ""
                        let bVal = b.infoDict[infoKey] ?? ""
                        // Try numeric comparison first
                        if let aNum = Double(aVal), let bNum = Double(bVal) {
                            result = aNum < bNum ? .orderedAscending : (aNum > bNum ? .orderedDescending : .orderedSame)
                        } else {
                            result = aVal.localizedCaseInsensitiveCompare(bVal)
                        }
                    } else {
                        result = .orderedSame
                    }
                }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
            tableView.reloadData()
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
            case "consequence":
                result = variantConsequenceText(for: a).localizedCaseInsensitiveCompare(variantConsequenceText(for: b))
            case "aa_change":
                result = variantAAChangeText(for: a).localizedCaseInsensitiveCompare(variantAAChangeText(for: b))
            default:
                if key.hasPrefix("attr_") {
                    let attributeKey = String(key.dropFirst(5))
                    let valA = a.attributes?[attributeKey] ?? ""
                    let valB = b.attributes?[attributeKey] ?? ""
                    if isNumericAnnotationAttributeKey(attributeKey),
                       let numA = Double(valA),
                       let numB = Double(valB) {
                        result = numA < numB ? .orderedAscending : (numA > numB ? .orderedDescending : .orderedSame)
                    } else {
                        result = valA.localizedCaseInsensitiveCompare(valB)
                    }
                } else if key.hasPrefix("info_") {
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

        // Bookmark column (star icon) — custom button, not a text cell
        if identifier == Self.bookmarkColumn {
            return bookmarkView(for: row)
        }

        // Samples tab uses its own data source
        if activeTab == .samples {
            return sampleCellView(for: identifier, row: row)
        }

        // Genotype subtab uses its own data source
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            return genotypeView(for: column, row: row)
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
            tf.font = .systemFont(ofSize: 11)
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
        tf.font = .systemFont(ofSize: 11)  // Reset default font

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
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.endColumn:
            tf.stringValue = numberFormatter.string(from: NSNumber(value: annotation.end)) ?? "\(annotation.end)"
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.sizeColumn:
            let size = annotation.end - annotation.start
            tf.stringValue = formatSize(size)
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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
            tf.textColor = variantTypeColor(annotation.type)
        case Self.variantChromColumn:
            tf.stringValue = annotation.chromosome
        case Self.positionColumn:
            // Display as 1-based (VCF convention) — internal storage is 0-based
            let displayPos = annotation.start + 1
            tf.stringValue = numberFormatter.string(from: NSNumber(value: displayPos)) ?? "\(displayPos)"
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.filterColumn:
            tf.stringValue = annotation.filter ?? "."
        case Self.samplesColumn:
            tf.stringValue = "\(annotation.sampleCount ?? 0)"
            tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            tf.alignment = .right
        case Self.sourceColumn:
            tf.stringValue = annotation.sourceFile ?? ""
            tf.font = .systemFont(ofSize: 11)
        case Self.consequenceColumn:
            tf.stringValue = variantConsequenceText(for: annotation)
        case Self.aaChangeColumn:
            tf.stringValue = variantAAChangeText(for: annotation)

        default:
            if identifier.rawValue.hasPrefix("attr_") {
                let attributeKey = String(identifier.rawValue.dropFirst(5))
                tf.stringValue = annotation.attributes?[attributeKey] ?? ""
                tf.alignment = isNumericAnnotationAttributeKey(attributeKey) ? .right : .left
            } else if identifier.rawValue.hasPrefix("info_") {
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
        guard selectedRows.count == 1, let row = selectedRows.first else { return }
        // Genotype subtab: navigate to the parent variant
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            guard row < displayedGenotypes.count else { return }
            let gt = displayedGenotypes[row]
            if let variant = displayedAnnotations.first(where: { $0.variantRowId == gt.variantRowId }) {
                delegate?.annotationDrawer(self, didSelectAnnotation: variant)
            }
            return
        }
        guard row < displayedAnnotations.count else { return }
        let annotation = displayedAnnotations[row]
        drawerLogger.debug("AnnotationTableDrawerView: Selected '\(annotation.name, privacy: .public)' at row \(row)")
        delegate?.annotationDrawer(self, didSelectAnnotation: annotation)
    }

    // MARK: - Formatting

    func formatSize(_ bp: Int) -> String {
        switch bp {
        case 0..<1_000:
            return "\(bp) bp"
        case 1_000..<1_000_000:
            return String(format: "%.1f kb", Double(bp) / 1_000.0)
        default:
            return String(format: "%.1f Mb", Double(bp) / 1_000_000.0)
        }
    }

    private func variantConsequenceText(for row: AnnotationSearchIndex.SearchResult) -> String {
        if let info = row.infoDict {
            let candidates = [
                "CSQ_Consequence", "ANN_Consequence", "Consequence", "consequence",
                "ANN_Annotation", "EFFECT", "effect",
            ]
            for key in candidates {
                if let value = normalizedVariantInfoValue(info[key]) {
                    return value
                }
            }
        }
        let fallback = fallbackConsequenceForRow(row).consequence?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        if shouldShowDeferredConsequencePlaceholder(for: row) {
            return Self.deferredConsequenceText
        }
        return ""
    }

    private func variantAAChangeText(for row: AnnotationSearchIndex.SearchResult) -> String {
        if let info = row.infoDict {
            let candidates = [
                "CSQ_HGVSp", "HGVSp", "ANN_HGVS_p", "AA_CHANGE",
                "CSQ_Amino_acids", "Amino_acids", "ANN_AA_pos_len",
            ]
            for key in candidates {
                if let value = normalizedVariantInfoValue(info[key]) {
                    return value
                }
            }
        }
        let fallback = fallbackConsequenceForRow(row).aaChange?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        if shouldShowDeferredConsequencePlaceholder(for: row) {
            return Self.deferredAAChangeText
        }
        return ""
    }

    private func fallbackConsequenceForRow(
        _ row: AnnotationSearchIndex.SearchResult
    ) -> (consequence: String?, aaChange: String?) {
        let key = variantFallbackKey(for: row)
        if let cached = fallbackConsequenceCache[key] {
            return cached
        }
        let resolved = delegate?.annotationDrawer(self, fallbackConsequenceFor: row) ?? (nil, nil)
        let consequence = resolved.0?.trimmingCharacters(in: .whitespacesAndNewlines)
        let aaChange = resolved.1?.trimmingCharacters(in: .whitespacesAndNewlines)
        if (consequence?.isEmpty == false) || (aaChange?.isEmpty == false) {
            fallbackConsequenceCache[key] = (consequence, aaChange)
            return (consequence, aaChange)
        }
        return resolved
    }

    private func normalizedVariantInfoValue(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        switch trimmed.lowercased() {
        case ".", "na", "n/a", "null", "none":
            return nil
        default:
            return trimmed
        }
    }

    private func shouldShowDeferredConsequencePlaceholder(for row: AnnotationSearchIndex.SearchResult) -> Bool {
        guard row.isVariant, activeTab == .variants else { return false }
        let visibleCount = max(displayedAnnotations.count, lastVariantQueryMatchCount ?? 0)
        return visibleCount > Self.consequenceComputationRowLimit
    }

    private func variantFallbackKey(for row: AnnotationSearchIndex.SearchResult) -> String {
        if let rowId = row.variantRowId {
            return "\(row.trackId):\(rowId)"
        }
        let ref = row.ref ?? ""
        let alt = row.alt ?? ""
        return "\(row.trackId):\(row.chromosome):\(row.start):\(ref):\(alt)"
    }

    // MARK: - Column Sizing

    @objc func autoSizeVisibleTableColumns(_ sender: Any?) {
        let columns = tableView.tableColumns
        guard !columns.isEmpty else { return }

        let rowCount = rowCountForAutoSizing()
        let sampledRows = min(rowCount, Self.autoSizeRowSampleLimit)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

        for column in columns {
            autoSize(column: column, sampledRows: sampledRows, bodyFont: bodyFont, headerFont: headerFont)
        }
    }

    @objc func autoSizeSingleColumnFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == identifier }) else { return }

        let rowCount = rowCountForAutoSizing()
        let sampledRows = min(rowCount, Self.autoSizeRowSampleLimit)
        autoSize(
            column: column,
            sampledRows: sampledRows,
            bodyFont: NSFont.systemFont(ofSize: 11),
            headerFont: NSFont.systemFont(ofSize: 11, weight: .semibold)
        )
    }

    func addColumnSizingMenuItems(_ menu: NSMenu, tableColumn: NSTableColumn?) {
        if let tableColumn {
            let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title
            let sizeColumnItem = NSMenuItem(
                title: "Size \(displayName) to Fit",
                action: #selector(autoSizeSingleColumnFromMenu(_:)),
                keyEquivalent: ""
            )
            sizeColumnItem.target = self
            sizeColumnItem.representedObject = tableColumn.identifier.rawValue
            menu.addItem(sizeColumnItem)
        }

        let sizeAllItem = NSMenuItem(
            title: "Size All Columns to Fit",
            action: #selector(autoSizeVisibleTableColumns(_:)),
            keyEquivalent: ""
        )
        sizeAllItem.target = self
        menu.addItem(sizeAllItem)
    }

    private func rowCountForAutoSizing() -> Int {
        if activeTab == .samples { return displayedSamples.count }
        if activeTab == .variants && activeVariantSubtab == .genotypes { return displayedGenotypes.count }
        return displayedAnnotations.count
    }

    private func autoSize(
        column: NSTableColumn,
        sampledRows: Int,
        bodyFont: NSFont,
        headerFont: NSFont
    ) {
        if column.identifier == Self.bookmarkColumn {
            column.width = 28
            return
        }
        if column.identifier == Self.sampleVisibleColumn {
            column.width = 30
            return
        }

        let headerTitle = column.title.isEmpty ? " " : column.title
        var targetWidth = (headerTitle as NSString).size(withAttributes: [.font: headerFont]).width + 16

        if sampledRows > 0 {
            for row in 0..<sampledRows {
                let text = autoSizeCellValueString(for: column.identifier, row: row)
                guard !text.isEmpty else { continue }
                let width = (text as NSString).size(withAttributes: [.font: bodyFont]).width + 12
                if width > targetWidth { targetWidth = width }
            }
        }

        let clamped = min(max(targetWidth, column.minWidth), 700)
        column.width = ceil(clamped)
    }

    private func autoSizeCellValueString(for identifier: NSUserInterfaceItemIdentifier, row: Int) -> String {
        if activeTab == .samples {
            guard row < displayedSamples.count else { return "" }
            let sample = displayedSamples[row]
            if identifier == Self.sampleDisplayNameColumn {
                let displayName = sample.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (displayName?.isEmpty == false) ? displayName! : sample.name
            }
            return sampleFilterValue(sample: sample, columnIdentifier: identifier.rawValue)
        }

        if activeTab == .variants && activeVariantSubtab == .genotypes {
            return genotypeCellValueString(for: identifier, row: row)
        }

        guard row < displayedAnnotations.count else { return "" }
        let annotation = displayedAnnotations[row]
        switch identifier {
        case Self.nameColumn, Self.variantIdColumn:
            return annotation.name
        case Self.typeColumn, Self.variantTypeColumn:
            return annotation.type
        case Self.chromosomeColumn, Self.variantChromColumn:
            return annotation.chromosome
        case Self.startColumn:
            return numberFormatter.string(from: NSNumber(value: annotation.start)) ?? "\(annotation.start)"
        case Self.endColumn:
            return numberFormatter.string(from: NSNumber(value: annotation.end)) ?? "\(annotation.end)"
        case Self.sizeColumn:
            return formatSize(annotation.end - annotation.start)
        case Self.strandColumn:
            return annotation.strand
        case Self.positionColumn:
            let displayPos = annotation.start + 1
            return numberFormatter.string(from: NSNumber(value: displayPos)) ?? "\(displayPos)"
        case Self.refColumn:
            return annotation.ref ?? ""
        case Self.altColumn:
            return annotation.alt ?? ""
        case Self.qualityColumn:
            if let q = annotation.quality {
                return q < 0 ? "." : String(format: "%.1f", q)
            }
            return "."
        case Self.filterColumn:
            return annotation.filter ?? "."
        case Self.samplesColumn:
            return "\(annotation.sampleCount ?? 0)"
        case Self.sourceColumn:
            return annotation.sourceFile ?? ""
        case Self.consequenceColumn:
            return variantConsequenceText(for: annotation)
        case Self.aaChangeColumn:
            return variantAAChangeText(for: annotation)
        default:
            if identifier.rawValue.hasPrefix("attr_") {
                let attributeKey = String(identifier.rawValue.dropFirst(5))
                return annotation.attributes?[attributeKey] ?? ""
            }
            if identifier.rawValue.hasPrefix("info_") {
                let infoKey = String(identifier.rawValue.dropFirst(5))
                return annotation.infoDict?[infoKey] ?? ""
            }
            return ""
        }
    }

    /// Returns the theme-aware NSColor for a variant type string (SNP, INS, DEL, etc.).
    private func variantTypeColor(_ type: String) -> NSColor {
        let theme = VariantColorTheme.named(AppSettings.shared.variantColorThemeName)
        switch type {
        case "SNP": return theme.snp.nsColor
        case "INS": return theme.ins.nsColor
        case "DEL": return theme.del.nsColor
        case "MNP": return theme.mnp.nsColor
        default:    return theme.complex.nsColor
        }
    }

    /// Whether an INFO key represents a numeric type (Integer or Float) for sorting.
    func isNumericInfoKey(_ key: String) -> Bool {
        infoColumnKeys.first(where: { $0.key == key }).map { $0.type == "Integer" || $0.type == "Float" } ?? false
    }

    func isNumericAnnotationAttributeKey(_ key: String) -> Bool {
        switch key {
        case "flag", "mapq", "pos_1_based", "alignment_start", "alignment_end",
             "reference_length", "query_length", "mate_position_1_based", "template_length",
             "tag_NM", "tag_AS":
            return true
        default:
            return false
        }
    }

    // MARK: - Public API

    /// Selects and scrolls to an annotation by name.
    @discardableResult
    func selectAnnotation(named name: String) -> Bool {
        guard let index = displayedAnnotations.firstIndex(where: { $0.name == name }) else {
            return false
        }
        isSuppressingDelegateCallbacks = true
        defer { isSuppressingDelegateCallbacks = false }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        return true
    }

    @discardableResult
    func selectAnnotations(named names: [String]) -> Int {
        let wanted = Set(names)
        let indexes = displayedAnnotations.enumerated().reduce(into: IndexSet()) { partial, pair in
            if wanted.contains(pair.element.name) {
                partial.insert(pair.offset)
            }
        }
        guard !indexes.isEmpty else { return 0 }
        isSuppressingDelegateCallbacks = true
        defer { isSuppressingDelegateCallbacks = false }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        tableView.scrollRowToVisible(indexes.first!)
        return indexes.count
    }

    // MARK: - AI Snapshot API

    /// Returns the currently shown variant rows in the Calls subtab.
    ///
    /// - Parameters:
    ///   - limit: Maximum rows to return.
    ///   - selectedOnly: Whether to return only selected rows.
    ///   - fallbackToVisibleIfSelectionEmpty: When `selectedOnly` is true and no rows are
    ///     selected, return visible rows instead.
    func aiVariantRows(
        limit: Int = 50,
        selectedOnly: Bool = false,
        fallbackToVisibleIfSelectionEmpty: Bool = true
    ) -> [AnnotationSearchIndex.SearchResult] {
        guard activeTab == .variants, activeVariantSubtab == .calls else { return [] }

        let rowsToUse: [AnnotationSearchIndex.SearchResult]
        if selectedOnly {
            let selected = tableView.selectedRowIndexes.compactMap { idx -> AnnotationSearchIndex.SearchResult? in
                guard idx >= 0, idx < displayedAnnotations.count else { return nil }
                return displayedAnnotations[idx]
            }
            if selected.isEmpty && fallbackToVisibleIfSelectionEmpty {
                rowsToUse = displayedAnnotations
            } else {
                rowsToUse = selected
            }
        } else {
            rowsToUse = displayedAnnotations
        }

        return Array(rowsToUse.prefix(max(1, limit)))
    }

    /// Returns the currently shown sample rows in the Samples tab.
    ///
    /// - Parameters:
    ///   - limit: Maximum rows to return.
    ///   - selectedOnly: Whether to return only selected rows.
    ///   - visibleOnly: Whether to include only visible samples.
    ///   - fallbackToVisibleIfSelectionEmpty: When `selectedOnly` is true and no rows are
    ///     selected, return visible rows instead.
    func aiSampleRows(
        limit: Int = 100,
        selectedOnly: Bool = false,
        visibleOnly: Bool = true,
        fallbackToVisibleIfSelectionEmpty: Bool = true
    ) -> [SampleDisplayRow] {
        guard activeTab == .samples else { return [] }

        let baseRows: [SampleDisplayRow]
        if selectedOnly {
            let selected = tableView.selectedRowIndexes.compactMap { idx -> SampleDisplayRow? in
                guard idx >= 0, idx < displayedSamples.count else { return nil }
                return displayedSamples[idx]
            }
            if selected.isEmpty && fallbackToVisibleIfSelectionEmpty {
                baseRows = displayedSamples
            } else {
                baseRows = selected
            }
        } else {
            baseRows = displayedSamples
        }

        let filtered = visibleOnly ? baseRows.filter(\.isVisible) : baseRows
        return Array(filtered.prefix(max(1, limit)))
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

    private func selectedAnnotationResults(fallback result: AnnotationSearchIndex.SearchResult? = nil) -> [AnnotationSearchIndex.SearchResult] {
        var indexes = tableView.selectedRowIndexes
        if indexes.isEmpty, let result, let index = displayedAnnotations.firstIndex(where: { $0.id == result.id }) {
            indexes.insert(index)
        }
        let selected = indexes.compactMap { index -> AnnotationSearchIndex.SearchResult? in
            guard index >= 0, index < displayedAnnotations.count else { return nil }
            let row = displayedAnnotations[index]
            return row.isVariant ? nil : row
        }
        if selected.isEmpty, let result, !result.isVariant {
            return [result]
        }
        return selected
    }

    private func selectedSequenceAnnotations(fallback result: AnnotationSearchIndex.SearchResult? = nil) -> [SequenceAnnotation] {
        selectedAnnotationResults(fallback: result).map(makeAnnotation(from:))
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
        let annotations = selectedSequenceAnnotations(fallback: result)
        guard !annotations.isEmpty else { return }
        delegate?.annotationDrawer(self, didRequestExtract: annotations)
    }

    @objc private func addAnnotationAction(_ sender: NSMenuItem) {
        let form = makeAnnotationCreateAccessoryView(defaultRegion: defaultAnnotationCreationRegion())
        let alert = NSAlert()
        alert.messageText = "Add Annotation"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = form.view

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard performAnnotationCreation(
            name: form.nameField.stringValue,
            type: form.typeField.stringValue,
            chromosome: form.chromosomeField.stringValue,
            startValue: form.startField.stringValue,
            endValue: form.endField.stringValue,
            strand: form.strandField.stringValue,
            attributes: form.attributesField.stringValue
        ) else {
            NSSound.beep()
            return
        }
    }

    @objc private func editAnnotationAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult,
              let rowID = result.annotationRowId,
              let searchIndex else {
            NSSound.beep()
            return
        }
        let currentRecord = searchIndex.lookupAnnotation(for: result)
        let alert = NSAlert()
        alert.messageText = "Edit Annotation"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let form = makeAnnotationEditForm(for: result, currentRecord: currentRecord)
        alert.accessoryView = form.view

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = form.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = form.typeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let chromosome = form.chromosomeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !type.isEmpty, !chromosome.isEmpty,
              let start = Int(form.startField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int(form.endField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              end >= start else {
            NSSound.beep()
            return
        }
        let attributes = form.attributesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedAttrs = attributes.isEmpty ? [:] : AnnotationDatabase.parseAttributes(attributes)
        let geneName = parsedAttrs["gene"] ?? parsedAttrs["gene_name"] ?? parsedAttrs["gene_id"]
        guard searchIndex.updateAnnotation(
            trackId: result.trackId,
            rowID: rowID,
            name: name,
            type: type,
            chromosome: chromosome,
            start: start,
            end: end,
            strand: form.strandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : form.strandField.stringValue,
            attributes: attributes.isEmpty ? nil : attributes,
            geneName: geneName
        ) else {
            NSSound.beep()
            return
        }
        updateDisplayedAnnotations()
    }

    func makeAnnotationEditAccessoryView(
        for result: AnnotationSearchIndex.SearchResult,
        currentRecord: AnnotationDatabaseRecord?
    ) -> NSView {
        makeAnnotationEditForm(for: result, currentRecord: currentRecord).view
    }

    struct AnnotationEditForm {
        let view: NSView
        let nameField: NSTextField
        let typeField: NSTextField
        let chromosomeField: NSTextField
        let startField: NSTextField
        let endField: NSTextField
        let strandField: NSTextField
        let attributesField: NSTextField
    }

    func makeAnnotationCreateAccessoryView(defaultRegion: AnnotationTableDrawerSelectionRegion?) -> AnnotationEditForm {
        let region = defaultRegion ?? AnnotationTableDrawerSelectionRegion(
            chromosome: displayedAnnotations.first?.chromosome ?? "",
            start: 0,
            end: 1
        )
        let result = AnnotationSearchIndex.SearchResult(
            name: "",
            chromosome: region.chromosome,
            start: region.start,
            end: region.end,
            trackId: searchIndex?.annotationDatabaseHandles.first?.trackId ?? "",
            type: "gene",
            strand: "."
        )
        return makeAnnotationForm(
            for: result,
            currentRecord: nil,
            subtitle: "Create an annotation in this bundle. Use a selected sequence region or enter coordinates."
        )
    }

    private func makeAnnotationEditForm(
        for result: AnnotationSearchIndex.SearchResult,
        currentRecord: AnnotationDatabaseRecord?
    ) -> AnnotationEditForm {
        makeAnnotationForm(
            for: result,
            currentRecord: currentRecord,
            subtitle: "Update the annotation fields stored in this bundle."
        )
    }

    private func makeAnnotationForm(
        for result: AnnotationSearchIndex.SearchResult,
        currentRecord: AnnotationDatabaseRecord?,
        subtitle subtitleText: String
    ) -> AnnotationEditForm {
        let formWidth: CGFloat = 520
        let formHeight: CGFloat = 292
        let container = NSView(frame: NSRect(x: 0, y: 0, width: formWidth, height: formHeight))

        let subtitle = NSTextField(wrappingLabelWithString: subtitleText)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)

        func label(_ value: String) -> NSTextField {
            let field = NSTextField(labelWithString: value)
            field.alignment = .right
            field.font = .systemFont(ofSize: 13, weight: .medium)
            return field
        }

        func textField(_ value: String, placeholder: String) -> NSTextField {
            let field = NSTextField(string: value)
            field.placeholderString = placeholder
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
            return field
        }

        let nameField = textField(result.name, placeholder: "Name")
        let typeField = textField(result.type, placeholder: "Type")
        let chromosomeField = textField(result.chromosome, placeholder: "Chromosome")
        let startField = textField("\(result.start)", placeholder: "Start")
        let endField = textField("\(result.end)", placeholder: "End")
        let strandField = textField(result.strand, placeholder: "Strand")
        let attributesValue = currentRecord?.attributes
            ?? result.attributes?.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ";")
            ?? ""
        let attributesField = textField(attributesValue, placeholder: "Attributes")

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Type"), typeField],
            [label("Chromosome"), chromosomeField],
            [label("Start"), startField],
            [label("End"), endField],
            [label("Strand"), strandField],
            [label("Attributes"), attributesField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).width = 110
        grid.column(at: 1).xPlacement = .fill
        container.addSubview(grid)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: formWidth),
            container.heightAnchor.constraint(equalToConstant: formHeight),
            subtitle.topAnchor.constraint(equalTo: container.topAnchor),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return AnnotationEditForm(
            view: container,
            nameField: nameField,
            typeField: typeField,
            chromosomeField: chromosomeField,
            startField: startField,
            endField: endField,
            strandField: strandField,
            attributesField: attributesField
        )
    }

    private func defaultAnnotationCreationRegion() -> AnnotationTableDrawerSelectionRegion? {
        delegate?.annotationDrawerSelectedSequenceRegion(self)
    }

    @discardableResult
    func performAnnotationCreation(
        name: String,
        type: String,
        chromosome: String,
        start: Int,
        end: Int,
        strand: String,
        attributes: String
    ) -> Bool {
        performAnnotationCreation(
            name: name,
            type: type,
            chromosome: chromosome,
            startValue: "\(start)",
            endValue: "\(end)",
            strand: strand,
            attributes: attributes
        )
    }

    @discardableResult
    private func performAnnotationCreation(
        name rawName: String,
        type rawType: String,
        chromosome rawChromosome: String,
        startValue rawStart: String,
        endValue rawEnd: String,
        strand rawStrand: String,
        attributes rawAttributes: String
    ) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        let chromosome = rawChromosome.trimmingCharacters(in: .whitespacesAndNewlines)
        let strandValue = rawStrand.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributes = rawAttributes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !type.isEmpty, !chromosome.isEmpty,
              let start = Int(rawStart.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int(rawEnd.trimmingCharacters(in: .whitespacesAndNewlines)),
              end >= start else {
            return false
        }
        let parsedAttrs = attributes.isEmpty ? [:] : AnnotationDatabase.parseAttributes(attributes)
        let geneName = parsedAttrs["gene"] ?? parsedAttrs["gene_name"] ?? parsedAttrs["gene_id"]
        let strand = strandValue.isEmpty ? "." : strandValue

        if let searchIndex {
            guard searchIndex.insertAnnotation(
                name: name,
                type: type,
                chromosome: chromosome,
                start: start,
                end: end,
                strand: strand,
                attributes: attributes.isEmpty ? nil : attributes,
                geneName: geneName
            ) != nil else {
                return false
            }
            totalAnnotationCount = searchIndex.entryCount
            if !availableAnnotationTypes.contains(type) {
                availableAnnotationTypes.append(type)
                availableAnnotationTypes.sort()
                visibleAnnotationTypes.insert(type)
                rebuildChipButtons()
            }
            annotationAttributeColumnKeys = Self.orderedAnnotationAttributeKeys(
                from: searchIndex.queryAnnotationsOnly(limit: Self.maxDisplayCount)
            )
            configureColumnsForTab(.annotations)
            updateDisplayedAnnotations()
            return selectAnnotation(named: name)
        }

        let result = AnnotationSearchIndex.SearchResult(
            name: name,
            chromosome: chromosome,
            start: start,
            end: end,
            trackId: "manual",
            type: type,
            strand: strand,
            attributes: parsedAttrs.isEmpty ? nil : parsedAttrs
        )
        var rows = baseDisplayedAnnotationRows
        rows.append(result)
        totalAnnotationCount = rows.count
        if !availableAnnotationTypes.contains(type) {
            availableAnnotationTypes.append(type)
            availableAnnotationTypes.sort()
            visibleAnnotationTypes.insert(type)
            rebuildChipButtons()
        }
        setAnnotationBaseResults(rows)
        tableView.reloadData()
        updateCountLabel()
        return selectAnnotation(named: name)
    }

    @objc private func deleteSelectedAnnotationsAction(_ sender: NSMenuItem) {
        let fallback = sender.representedObject as? AnnotationSearchIndex.SearchResult
        let selected = selectedAnnotationResults(fallback: fallback)
        guard !selected.isEmpty else { return }
        let rowIDsByTrack = Dictionary(grouping: selected, by: \.trackId).mapValues { rows in
            rows.compactMap(\.annotationRowId)
        }.filter { !$0.value.isEmpty }

        let deleted: Int
        if let searchIndex, !rowIDsByTrack.isEmpty {
            deleted = searchIndex.deleteAnnotations(rowIDsByTrack: rowIDsByTrack)
        } else {
            let ids = Set(selected.map(\.id))
            let before = displayedAnnotations.count
            displayedAnnotations.removeAll { ids.contains($0.id) }
            deleted = before - displayedAnnotations.count
        }
        guard deleted > 0 else {
            NSSound.beep()
            return
        }
        updateDisplayedAnnotations()
    }

    @objc private func selectRelatedGeneFeaturesAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let related = relatedGeneFeatures(for: result)
        guard !related.isEmpty else { return }
        let rowIDs = Set(related.compactMap(\.annotationRowId))
        let names = Set(related.map(\.name))
        let indexes = displayedAnnotations.enumerated().reduce(into: IndexSet()) { partial, pair in
            if let rowID = pair.element.annotationRowId, rowIDs.contains(rowID) {
                partial.insert(pair.offset)
            } else if names.contains(pair.element.name) {
                partial.insert(pair.offset)
            }
        }
        guard !indexes.isEmpty else { return }
        isSuppressingDelegateCallbacks = true
        defer { isSuppressingDelegateCallbacks = false }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        tableView.scrollRowToVisible(indexes.first!)
    }

    private func relatedGeneFeatures(for result: AnnotationSearchIndex.SearchResult) -> [AnnotationSearchIndex.SearchResult] {
        let types = Set(["gene", "mRNA", "transcript", "exon", "CDS"])
        let immediateRows = searchIndex?.queryAnnotationsInRegion(
            chromosome: result.chromosome,
            start: result.start,
            end: result.end,
            types: types,
            limit: 1000
        ) ?? displayedAnnotations.filter {
            $0.chromosome == result.chromosome && $0.end > result.start && $0.start < result.end && types.contains($0.type)
        }
        let immediateSameStrand = immediateRows.filter { result.strand == "." || $0.strand == "." || $0.strand == result.strand }
        let containingGene = (result.type == "gene" ? result : immediateSameStrand
            .filter { $0.type == "gene" && result.start >= $0.start && result.end <= $0.end }
            .sorted { ($0.end - $0.start) < ($1.end - $1.start) }
            .first)
        let relationStart = containingGene?.start ?? result.start
        let relationEnd = containingGene?.end ?? result.end
        let regionRows = searchIndex?.queryAnnotationsInRegion(
            chromosome: result.chromosome,
            start: relationStart,
            end: relationEnd,
            types: types,
            limit: 5000
        ) ?? displayedAnnotations.filter {
            $0.chromosome == result.chromosome && $0.end > relationStart && $0.start < relationEnd && types.contains($0.type)
        }
        let sameStrand = regionRows.filter { result.strand == "." || $0.strand == "." || $0.strand == result.strand }
        let resultAttrs = result.attributes ?? [:]
        let parentTokens = Set((resultAttrs["Parent"] ?? "").split(separator: ",").map(String.init))
        let resultID = resultAttrs["ID"]
        let geneName = resultAttrs["gene"] ?? resultAttrs["gene_name"] ?? resultAttrs["gene_id"] ?? result.name
        return sameStrand.filter { row in
            let attrs = row.attributes ?? [:]
            if row.name == result.name || row.annotationRowId == result.annotationRowId { return true }
            if let id = attrs["ID"], parentTokens.contains(id) { return true }
            if let resultID, (attrs["Parent"] ?? "").split(separator: ",").map(String.init).contains(resultID) { return true }
            let rowGene = attrs["gene"] ?? attrs["gene_name"] ?? attrs["gene_id"] ?? row.name
            if rowGene == geneName { return true }
            if row.type == "gene" {
                return result.start >= row.start && result.end <= row.end
            }
            if let containingGene {
                return row.start >= containingGene.start && row.end <= containingGene.end
            }
            return false
        }
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

    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn) else { return }
        if activeTab == .samples {
            showSampleColumnHeaderFilterMenu(column: columnIndex)
            return
        }
        if activeTab == .annotations {
            showAnnotationColumnHeaderFilterMenu(column: columnIndex)
            return
        }
        if activeTab == .variants && activeVariantSubtab == .calls {
            showVariantColumnHeaderFilterMenu(column: columnIndex)
            return
        }
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            showGenotypeColumnHeaderFilterMenu(column: columnIndex)
        }
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
            let targetColumn = tableView.clickedColumn
            guard targetRow >= 0, targetRow < displayedSamples.count else {
                if targetColumn >= 0 {
                    buildSampleColumnHeaderContextMenu(menu, column: targetColumn)
                    return
                }
                buildSampleGlobalContextMenu(menu)
                return
            }
            buildSampleContextMenu(menu, row: targetRow, clickedColumn: targetColumn)
            return
        }

        // Genotype subtab: show column header context menu on header right-click
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            if tableView.clickedColumn >= 0 && tableView.clickedRow < 0 {
                buildGenotypeColumnHeaderContextMenu(menu, column: tableView.clickedColumn)
            }
            return
        }

        if activeTab == .variants && tableView.clickedColumn >= 0 && tableView.clickedRow < 0 {
            buildVariantColumnHeaderContextMenu(menu, column: tableView.clickedColumn)
            return
        }

        if activeTab == .annotations && tableView.clickedColumn >= 0 && tableView.clickedRow < 0 {
            buildAnnotationColumnHeaderContextMenu(menu, column: tableView.clickedColumn)
            return
        }

        guard targetRow >= 0, targetRow < displayedAnnotations.count else {
            if activeTab == .annotations {
                buildAnnotationGlobalContextMenu(menu)
            }
            return
        }

        let annotation = displayedAnnotations[targetRow]

        if annotation.isVariant {
            buildVariantContextMenu(menu, annotation: annotation)
        } else {
            buildAnnotationContextMenu(menu, annotation: annotation)
        }
    }

    private func buildAnnotationGlobalContextMenu(_ menu: NSMenu) {
        let addItem = NSMenuItem(title: "Add Annotation\u{2026}", action: #selector(addAnnotationAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = searchIndex?.hasDatabaseBackend ?? true
        menu.addItem(addItem)
    }

    private func buildAnnotationContextMenu(_ menu: NSMenu, annotation: AnnotationSearchIndex.SearchResult) {
        let isCDS = Self.supportsTranslationMenu(for: annotation.type)
        let selectedAnnotations = selectedAnnotationResults(fallback: annotation)
        let selectedCount = max(1, selectedAnnotations.count)

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
        let extractTitle = selectedCount > 1 ? "Extract \(selectedCount) Sequences\u{2026}" : "Extract Sequence\u{2026}"
        let extractItem = NSMenuItem(title: extractTitle, action: #selector(extractSequenceAction(_:)), keyEquivalent: "")
        extractItem.target = self
        extractItem.representedObject = annotation
        menu.addItem(extractItem)

        menu.addItem(NSMenuItem.separator())

        // --- Editing ---
        let addItem = NSMenuItem(title: "Add Annotation\u{2026}", action: #selector(addAnnotationAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = allowsAnnotationEditing && (searchIndex?.hasDatabaseBackend ?? true)
        menu.addItem(addItem)

        let editItem = NSMenuItem(title: "Edit Annotation\u{2026}", action: #selector(editAnnotationAction(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = annotation
        editItem.isEnabled = allowsAnnotationEditing && selectedCount == 1 && annotation.annotationRowId != nil
        menu.addItem(editItem)

        let deleteTitle = selectedCount > 1 ? "Delete \(selectedCount) Selected Annotations" : "Delete Annotation"
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteSelectedAnnotationsAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        deleteItem.isEnabled = allowsAnnotationEditing
        menu.addItem(deleteItem)

        let relatedItem = NSMenuItem(title: "Select Related Gene Features", action: #selector(selectRelatedGeneFeaturesAction(_:)), keyEquivalent: "")
        relatedItem.target = self
        relatedItem.representedObject = annotation
        relatedItem.isEnabled = ["gene", "mRNA", "transcript", "exon", "CDS"].contains(annotation.type)
        menu.addItem(relatedItem)

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

        // --- Bookmark ---
        if let variantRowId = annotation.variantRowId {
            let isBookmarked = bookmarkedVariantKeys.contains(bookmarkKey(trackId: annotation.trackId, variantRowId: variantRowId))
            let bookmarkTitle = isBookmarked ? "Remove Bookmark" : "Bookmark Variant"
            let bookmarkItem = NSMenuItem(title: bookmarkTitle, action: #selector(contextBookmarkToggle(_:)), keyEquivalent: "")
            bookmarkItem.target = self
            bookmarkItem.representedObject = annotation
            menu.addItem(bookmarkItem)
        }

        if hasBookmarks {
            let exportBookmarksItem = NSMenuItem(title: "Export Bookmarked Variants\u{2026}", action: #selector(exportBookmarkedVariants(_:)), keyEquivalent: "")
            exportBookmarksItem.target = self
            menu.addItem(exportBookmarksItem)
        }

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

    private func annotationFilterKey(forColumnIdentifier columnId: String) -> String? {
        switch columnId {
        case Self.nameColumn.rawValue: return "name"
        case Self.typeColumn.rawValue: return "type"
        case Self.chromosomeColumn.rawValue: return "chromosome"
        case Self.startColumn.rawValue: return "start"
        case Self.endColumn.rawValue: return "end"
        case Self.sizeColumn.rawValue: return "size"
        case Self.strandColumn.rawValue: return "strand"
        default:
            if columnId.hasPrefix("attr_") { return columnId }
            return nil
        }
    }

    private func addAnnotationColumnFilterItem(
        to menu: NSMenu,
        title: String,
        key: String,
        op: String,
        value: String
    ) {
        let item = NSMenuItem(title: title, action: #selector(applyAnnotationColumnFilterAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["key": key, "op": op, "value": value]
        menu.addItem(item)
    }

    @objc private func applyAnnotationColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        annotationColumnFilterClauses.append(ColumnFilterClause(key: key, op: op, value: value))
        refreshAnnotationColumnFilters()
    }

    @objc private func promptAnnotationColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Annotation Column Filter"
        alert.informativeText = "Enter a value for \(key)."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Filter value"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !value.isEmpty else { return }
            self.annotationColumnFilterClauses.append(ColumnFilterClause(key: key, op: op, value: value))
            self.refreshAnnotationColumnFilters()
        }
    }

    @objc private func clearAnnotationColumnFilters(_ sender: Any?) {
        annotationColumnFilterClauses.removeAll()
        refreshAnnotationColumnFilters()
    }

    private func refreshAnnotationColumnFilters() {
        if activeTab == .annotations, searchIndex?.hasDatabaseBackend == true {
            updateDisplayedAnnotations()
        } else {
            applyAnnotationColumnFiltersFromBase()
        }
    }

    private func buildAnnotationColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        let tableColumn = tableView.tableColumns[column]
        guard let key = annotationFilterKey(forColumnIdentifier: tableColumn.identifier.rawValue) else { return }
        let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title

        let addItem = NSMenuItem(title: "Add Annotation\u{2026}", action: #selector(addAnnotationAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = searchIndex?.hasDatabaseBackend ?? true
        menu.addItem(addItem)
        menu.addItem(NSMenuItem.separator())

        addColumnSizingMenuItems(menu, tableColumn: tableColumn)
        menu.addItem(NSMenuItem.separator())

        if isAnnotationFilterNumericKey(key) {
            for (title, op) in [
                ("Filter \(displayName) Equals...", "="),
                ("Filter \(displayName) >=...", ">="),
                ("Filter \(displayName) >...", ">"),
                ("Filter \(displayName) <=...", "<="),
                ("Filter \(displayName) <...", "<"),
            ] {
                let item = NSMenuItem(title: title, action: #selector(promptAnnotationColumnFilterAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["key": key, "op": op]
                menu.addItem(item)
            }
        } else {
            for (title, op) in [
                ("Filter \(displayName) Contains...", "~"),
                ("Filter \(displayName) Equals...", "="),
                ("Filter \(displayName) Begins With...", "^="),
                ("Filter \(displayName) Ends With...", "$="),
            ] {
                let item = NSMenuItem(title: title, action: #selector(promptAnnotationColumnFilterAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["key": key, "op": op]
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        addAnnotationColumnFilterItem(to: menu, title: "Filter \(displayName) Is Empty", key: key, op: "=", value: "")
        addAnnotationColumnFilterItem(to: menu, title: "Filter \(displayName) Is Not Empty", key: key, op: "!=", value: "")
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Annotation Column Filters", action: #selector(clearAnnotationColumnFilters(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
    }

    private func variantFilterKey(forColumnIdentifier columnId: String) -> String? {
        switch columnId {
        case Self.variantIdColumn.rawValue: return "variant_id"
        case Self.variantTypeColumn.rawValue: return "variant_type"
        case Self.variantChromColumn.rawValue: return "chromosome"
        case Self.positionColumn.rawValue: return "position"
        case Self.refColumn.rawValue: return "ref"
        case Self.altColumn.rawValue: return "alt"
        case Self.qualityColumn.rawValue: return "quality"
        case Self.filterColumn.rawValue: return "filter"
        case Self.samplesColumn.rawValue: return "samples"
        case Self.sourceColumn.rawValue: return "source"
        case Self.consequenceColumn.rawValue: return "consequence"
        case Self.aaChangeColumn.rawValue: return "aa_change"
        default:
            if columnId.hasPrefix("info_") { return columnId }
            return nil
        }
    }

    private func isVariantFilterNumericKey(_ key: String) -> Bool {
        switch key {
        case "position", "quality", "samples":
            return true
        default:
            if key.hasPrefix("info_") {
                let infoKey = String(key.dropFirst(5))
                return isNumericInfoKey(infoKey)
            }
            return false
        }
    }

    private func addVariantColumnFilterItem(
        to menu: NSMenu,
        title: String,
        key: String,
        op: String,
        value: String
    ) {
        let item = NSMenuItem(title: title, action: #selector(applyVariantColumnFilterAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["key": key, "op": op, "value": value]
        menu.addItem(item)
    }

    @objc private func applyVariantColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        variantColumnFilterClauses.append(VariantColumnFilterClause(key: key, op: op, value: value))
        applyVariantColumnFiltersFromBase()
    }

    @objc private func promptVariantColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Variant Column Filter"
        alert.informativeText = "Enter a value for \(key)."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Filter value"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !value.isEmpty else { return }
            self.variantColumnFilterClauses.append(VariantColumnFilterClause(key: key, op: op, value: value))
            self.applyVariantColumnFiltersFromBase()
        }
    }

    @objc private func clearVariantColumnFilters(_ sender: Any?) {
        variantColumnFilterClauses.removeAll()
        applyVariantColumnFiltersFromBase()
    }

    private func buildVariantColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        let tableColumn = tableView.tableColumns[column]
        guard let key = variantFilterKey(forColumnIdentifier: tableColumn.identifier.rawValue) else { return }
        let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title

        addColumnSizingMenuItems(menu, tableColumn: tableColumn)
        menu.addItem(NSMenuItem.separator())

        if isVariantFilterNumericKey(key) {
            let equalsItem = NSMenuItem(
                title: "Filter \(displayName) Equals\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            equalsItem.target = self
            equalsItem.representedObject = ["key": key, "op": "="]
            menu.addItem(equalsItem)

            let gteItem = NSMenuItem(
                title: "Filter \(displayName) \u{2265}\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            gteItem.target = self
            gteItem.representedObject = ["key": key, "op": ">="]
            menu.addItem(gteItem)

            let gtItem = NSMenuItem(
                title: "Filter \(displayName) >\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            gtItem.target = self
            gtItem.representedObject = ["key": key, "op": ">"]
            menu.addItem(gtItem)

            let lteItem = NSMenuItem(
                title: "Filter \(displayName) \u{2264}\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            lteItem.target = self
            lteItem.representedObject = ["key": key, "op": "<="]
            menu.addItem(lteItem)

            let ltItem = NSMenuItem(
                title: "Filter \(displayName) <\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            ltItem.target = self
            ltItem.representedObject = ["key": key, "op": "<"]
            menu.addItem(ltItem)
        } else {
            let containsItem = NSMenuItem(
                title: "Filter \(displayName) Contains\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            containsItem.target = self
            containsItem.representedObject = ["key": key, "op": "~"]
            menu.addItem(containsItem)

            let equalsItem = NSMenuItem(
                title: "Filter \(displayName) Equals\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            equalsItem.target = self
            equalsItem.representedObject = ["key": key, "op": "="]
            menu.addItem(equalsItem)

            let beginsWithItem = NSMenuItem(
                title: "Filter \(displayName) Begins With\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            beginsWithItem.target = self
            beginsWithItem.representedObject = ["key": key, "op": "^="]
            menu.addItem(beginsWithItem)

            let endsWithItem = NSMenuItem(
                title: "Filter \(displayName) Ends With\u{2026}",
                action: #selector(promptVariantColumnFilterAction(_:)),
                keyEquivalent: ""
            )
            endsWithItem.target = self
            endsWithItem.representedObject = ["key": key, "op": "$="]
            menu.addItem(endsWithItem)
        }

        menu.addItem(NSMenuItem.separator())
        addVariantColumnFilterItem(to: menu, title: "Filter \(displayName) Is Empty", key: key, op: "=", value: "")
        addVariantColumnFilterItem(to: menu, title: "Filter \(displayName) Is Not Empty", key: key, op: "!=", value: "")
        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Local Variant Column Filters", action: #selector(clearVariantColumnFilters(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
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

    private func sampleRowKey(name: String, sourceFile: String) -> String {
        "\(name)|\(sourceFile)"
    }

    nonisolated private static func sourceFileMatches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// Populates sample data from all variant database handles in the search index.
    private func populateSampleData(from index: AnnotationSearchIndex) {
        allSampleNames = []
        allSampleRowKeys = []
        sampleNameByRowKey = [:]
        sampleMetadata = [:]
        sampleSourceFiles = [:]
        sampleDisplayNamesCache = [:]
        var metadataKeySet = Set<String>()
        var seenSampleNames = Set<String>()
        var seenRowKeys = Set<String>()

        for handle in index.variantDatabaseHandles {
            let db = handle.db
            let sourceBySample = db.allSourceFiles()
            let displayNames = db.allDisplayNames()

            let samples = db.allSampleMetadata()
            for (name, metadata) in samples {
                if seenSampleNames.insert(name).inserted {
                    allSampleNames.append(name)
                }
                let sourceFile = sourceBySample[name] ?? ""
                let rowKey = sampleRowKey(name: name, sourceFile: sourceFile)
                guard seenRowKeys.insert(rowKey).inserted else { continue }
                allSampleRowKeys.append(rowKey)
                sampleNameByRowKey[rowKey] = name
                sampleSourceFiles[rowKey] = sourceFile
                if let dn = displayNames[name] { sampleDisplayNamesCache[rowKey] = dn }
                if !metadata.isEmpty {
                    sampleMetadata[rowKey] = metadata
                    for key in metadata.keys {
                        metadataKeySet.insert(key)
                    }
                }
            }

            // If allSampleMetadata() returned empty, fall back to sampleNames()
            if samples.isEmpty {
                for name in db.sampleNames() {
                    if seenSampleNames.insert(name).inserted {
                        allSampleNames.append(name)
                    }
                    let sourceFile = sourceBySample[name] ?? ""
                    let rowKey = sampleRowKey(name: name, sourceFile: sourceFile)
                    guard seenRowKeys.insert(rowKey).inserted else { continue }
                    allSampleRowKeys.append(rowKey)
                    sampleNameByRowKey[rowKey] = name
                    sampleSourceFiles[rowKey] = sourceFile
                }
            }
        }

        sampleMetadataFields = metadataKeySet.sorted()
        if !hasSampleDisplayStateSeed {
            currentSampleDisplayState = Self.defaultSampleDisplayState()
        }
    }

    /// Updates the displayed samples list based on the current filter text and sample order.
    private func updateDisplayedSamples() {
        let query = parseSampleFilterText(sampleFilterText)
        let freeText = query.textFilter.lowercased()

        displayedSamples = resolvedSampleOrder().compactMap { rowKey in
            guard let name = sampleNameByRowKey[rowKey] else { return nil }
            let sourceFile = sampleSourceFiles[rowKey] ?? ""
            let metadata = sampleMetadata[rowKey] ?? [:]
            let displayName = sampleDisplayNamesCache[rowKey]
            let isVisible = !currentSampleDisplayState.hiddenSamples.contains(name)

            // Apply text filter across name, source, and metadata values
            if !freeText.isEmpty {
                let searchText = ([name, displayName ?? "", sourceFile] + metadata.values).joined(separator: " ").lowercased()
                guard searchText.contains(freeText) else { return nil }
            }
            if let nameFilter = query.nameFilter,
               !sampleStringMatches(actual: name, op: nameFilter.op, expected: nameFilter.value) { return nil }
            if let sourceFilter = query.sourceFilter,
               !sampleStringMatches(actual: sourceFile, op: sourceFilter.op, expected: sourceFilter.value) { return nil }
            if let expectedVisibility = query.visibility, expectedVisibility != isVisible { return nil }
            for filter in query.metadataFilters {
                let actual = metadata[filter.field]
                    ?? metadata.first(where: { $0.key.caseInsensitiveCompare(filter.field) == .orderedSame })?.value
                    ?? ""
                if !sampleStringMatches(actual: actual, op: filter.op, expected: filter.value) { return nil }
            }

            // Token-based filters
            if activeSampleTokens.contains(.visibleOnly) && !isVisible { return nil }
            if activeSampleTokens.contains(.hiddenOnly) && isVisible { return nil }
            let hasSource = !sourceFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if activeSampleTokens.contains(.hasSource) && !hasSource { return nil }
            if activeSampleTokens.contains(.missingSource) && hasSource { return nil }

            if let selectedGroup = selectedSampleGroupId,
               let group = currentSampleDisplayState.sampleGroups.first(where: { $0.id == selectedGroup }),
               !group.sampleNames.contains(name) {
                return nil
            }

            return SampleDisplayRow(rowKey: rowKey, name: name, sourceFile: sourceFile, isVisible: isVisible, metadata: metadata, displayName: displayName)
        }

        // Propagate query-filtered sample subset to viewer genotype row visibility.
        syncSampleFilterVisibilityToViewer(query: query)

        tableView.reloadData()
        scrollView.isHidden = false
        tooManyLabel.isHidden = true
        updateSampleFilterIndicator()
        updateCountLabel()
    }

    private func syncSampleFilterVisibilityToViewer(query: SampleFilterQuery) {
        let hasVisibilityConstraint =
            query.visibility != nil ||
            activeSampleTokens.contains(.visibleOnly) ||
            activeSampleTokens.contains(.hiddenOnly)
        let shouldSyncByQuery = hasActiveSampleFilters && !hasVisibilityConstraint

        if shouldSyncByQuery {
            if sampleFilterBaselineHiddenSamples == nil {
                sampleFilterBaselineHiddenSamples = currentSampleDisplayState.hiddenSamples
            }
            let shownNames = Set(displayedSamples.map(\.name))
            let desiredHidden = Set(allSampleNames.filter { !shownNames.contains($0) })
            if desiredHidden != currentSampleDisplayState.hiddenSamples {
                currentSampleDisplayState.hiddenSamples = desiredHidden
                postSampleDisplayStateChange()
            }
            return
        }

        if !hasActiveSampleFilters, let baseline = sampleFilterBaselineHiddenSamples {
            sampleFilterBaselineHiddenSamples = nil
            if baseline != currentSampleDisplayState.hiddenSamples {
                currentSampleDisplayState.hiddenSamples = baseline
                postSampleDisplayStateChange()
            }
        }
    }

    func sampleStringMatches(actual: String, op: String, expected: String) -> Bool {
        let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)

        switch op {
        case "=":
            if normalizedExpected.isEmpty { return normalizedActual.isEmpty }  // "is empty"
            return normalizedActual.caseInsensitiveCompare(normalizedExpected) == .orderedSame
        case "!=":
            if normalizedExpected.isEmpty { return !normalizedActual.isEmpty } // "is not empty"
            return normalizedActual.caseInsensitiveCompare(normalizedExpected) != .orderedSame
        case "~", ":":
            if normalizedExpected.isEmpty { return true }
            return normalizedActual.localizedCaseInsensitiveContains(normalizedExpected)
        case "!~":
            if normalizedExpected.isEmpty { return true }
            return !normalizedActual.localizedCaseInsensitiveContains(normalizedExpected)
        case "^=":
            if normalizedExpected.isEmpty { return true }
            return normalizedActual.lowercased().hasPrefix(normalizedExpected.lowercased())
        case "$=":
            if normalizedExpected.isEmpty { return true }
            return normalizedActual.lowercased().hasSuffix(normalizedExpected.lowercased())
        default:
            if normalizedExpected.isEmpty { return true }
            return normalizedActual.localizedCaseInsensitiveContains(normalizedExpected)
        }
    }

    private func annotationColumnValue(_ row: AnnotationSearchIndex.SearchResult, key: String) -> String {
        switch key {
        case "name":
            return row.name
        case "type":
            return row.type
        case "chromosome":
            return row.chromosome
        case "start":
            return String(row.start)
        case "end":
            return String(row.end)
        case "size":
            return String(row.end - row.start)
        case "strand":
            return row.strand
        default:
            if key.hasPrefix("attr_") {
                let attributeKey = String(key.dropFirst(5))
                return row.attributes?[attributeKey] ?? ""
            }
            return ""
        }
    }

    private func isAnnotationFilterNumericKey(_ key: String) -> Bool {
        switch key {
        case "start", "end", "size":
            return true
        default:
            if key.hasPrefix("attr_") {
                let attributeKey = String(key.dropFirst(5))
                return isNumericAnnotationAttributeKey(attributeKey)
            }
            return false
        }
    }

    private func annotationColumnMatches(actual: String, op: String, expected: String, key: String) -> Bool {
        let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAnnotationFilterNumericKey(key),
           let lhs = Double(normalizedActual),
           let rhs = Double(normalizedExpected) {
            switch op {
            case ">": return lhs > rhs
            case ">=": return lhs >= rhs
            case "<": return lhs < rhs
            case "<=": return lhs <= rhs
            case "=": return lhs == rhs
            case "!=": return lhs != rhs
            default: break
            }
        }
        return sampleStringMatches(actual: normalizedActual, op: op, expected: normalizedExpected)
    }

    func applyAnnotationColumnFilters(
        to rows: [AnnotationSearchIndex.SearchResult],
        clauses: [ColumnFilterClause]
    ) -> [AnnotationSearchIndex.SearchResult] {
        guard !clauses.isEmpty else { return rows }
        return rows.filter { row in
            clauses.allSatisfy { clause in
                let actual = annotationColumnValue(row, key: clause.key)
                return annotationColumnMatches(actual: actual, op: clause.op, expected: clause.value, key: clause.key)
            }
        }
    }

    private func applyAnnotationColumnFilters(to rows: [AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] {
        applyAnnotationColumnFilters(to: rows, clauses: annotationColumnFilterClauses)
    }

    private func setAnnotationBaseResults(_ rows: [AnnotationSearchIndex.SearchResult]) {
        baseDisplayedAnnotationRows = rows
        displayedAnnotations = applyAnnotationColumnFilters(to: rows)
        let availableTrackIDs = searchIndex?.annotationDatabaseHandles.map(\.trackId) ?? []
        syncAnnotationTracks(from: availableTrackIDs.isEmpty ? rows.map(\.trackId) : availableTrackIDs)
    }

    private func applyAnnotationColumnFiltersFromBase() {
        displayedAnnotations = applyAnnotationColumnFilters(to: baseDisplayedAnnotationRows)
        tableView.reloadData()
        scrollView.isHidden = false
        tooManyLabel.isHidden = true
        updateAnnotationSearchRegion()
        updateCountLabel()
    }

    private func variantColumnValue(_ row: AnnotationSearchIndex.SearchResult, key: String) -> String {
        switch key {
        case "variant_id":
            return row.name
        case "variant_type":
            return row.type
        case "chromosome":
            return row.chromosome
        case "position":
            return String(row.start + 1)
        case "ref":
            return row.ref ?? ""
        case "alt":
            return row.alt ?? ""
        case "quality":
            return row.quality.map { String($0) } ?? ""
        case "filter":
            return row.filter ?? ""
        case "samples":
            return row.sampleCount.map { String($0) } ?? ""
        case "source":
            return row.sourceFile ?? ""
        case "consequence":
            return variantConsequenceText(for: row)
        case "aa_change":
            return variantAAChangeText(for: row)
        default:
            if key.hasPrefix("info_") {
                let infoKey = String(key.dropFirst(5))
                return row.infoDict?[infoKey] ?? ""
            }
            return ""
        }
    }

    private func variantColumnMatches(actual: String, op: String, expected: String, key: String) -> Bool {
        let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        // Numeric comparison for known numeric keys and info_* columns with numeric operators
        let isNumericOp = op == ">" || op == ">=" || op == "<" || op == "<="
        let isKnownNumeric = key == "position" || key == "quality" || key == "samples"
        if (isKnownNumeric || (isNumericOp && key.hasPrefix("info_"))),
           let lhs = Double(normalizedActual), let rhs = Double(normalizedExpected) {
            switch op {
            case ">": return lhs > rhs
            case ">=": return lhs >= rhs
            case "<": return lhs < rhs
            case "<=": return lhs <= rhs
            case "=": return lhs == rhs
            case "!=": return lhs != rhs
            default: break
            }
        }
        return sampleStringMatches(actual: normalizedActual, op: op, expected: normalizedExpected)
    }

    func applyVariantColumnFilters(to rows: [AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] {
        guard !variantColumnFilterClauses.isEmpty else { return rows }
        return rows.filter { row in
            variantColumnFilterClauses.allSatisfy { clause in
                let actual = variantColumnValue(row, key: clause.key)
                return variantColumnMatches(actual: actual, op: clause.op, expected: clause.value, key: clause.key)
            }
        }
    }

    private func setVariantBaseResults(_ rows: [AnnotationSearchIndex.SearchResult]) {
        baseDisplayedVariantAnnotations = rows
        fallbackConsequenceCache = [:]
        displayedAnnotations = applyVariantColumnFilters(to: rows)
    }

    private func applyVariantColumnFiltersFromBase() {
        displayedAnnotations = applyVariantColumnFilters(to: baseDisplayedVariantAnnotations)
        tableView.reloadData()
        scrollView.isHidden = false
        tooManyLabel.isHidden = true
        updateCountLabel()
        if activeVariantSubtab == .genotypes {
            buildGenotypeRows()
        }
    }

    func emitVisibleVariantRenderKeyUpdateIfNeeded() {
        // During async query churn, keep the last stable viewport sync set only
        // while there are no stable rows to mirror yet.
        if activeTab == .variants && isVariantQuerying && (scrollView.isHidden || displayedAnnotations.isEmpty) {
            return
        }
        if activeTab == .variants && isVariantQuerying && !scrollView.isHidden && !displayedAnnotations.isEmpty {
            // Safety: if rows are visible, query progress should no longer block sync.
            hideVariantQueryProgress()
        }

        let keysToEmit: Set<String>?
        if activeTab == .variants {
            if scrollView.isHidden {
                // Placeholder / too-many state: no stable table rows to mirror.
                // Clear sync filter so zooming back in can recover naturally.
                keysToEmit = nil
            } else {
                keysToEmit = Set(displayedAnnotations.compactMap { result in
                    guard let rowId = result.variantRowId, !result.trackId.isEmpty else { return nil }
                    return "\(result.trackId):\(rowId)"
                })
            }
        } else {
            keysToEmit = nil
        }
        localVariantFilterBadgeLabel.stringValue = variantColumnFilterClauses.isEmpty
            ? "Table Sync: Visible Rows"
            : "Local: Visible Rows"
        guard keysToEmit != lastEmittedVisibleVariantRenderKeys else { return }
        lastEmittedVisibleVariantRenderKeys = keysToEmit
        delegate?.annotationDrawer(self, didUpdateVisibleVariantRenderKeys: keysToEmit)
    }

    func emitVisibleAnnotationRenderKeyUpdateIfNeeded() {
        let keysToEmit: Set<String>?
        if activeTab == .annotations && annotationViewportFilterEnabled && !scrollView.isHidden {
            keysToEmit = Set(displayedAnnotations.compactMap { result in
                guard !result.trackId.isEmpty, let rowID = result.annotationRowId else { return nil }
                return "\(result.trackId):\(rowID)"
            })
        } else {
            keysToEmit = nil
        }
        guard keysToEmit != lastEmittedVisibleAnnotationRenderKeys else { return }
        lastEmittedVisibleAnnotationRenderKeys = keysToEmit
        delegate?.annotationDrawer(self, didUpdateVisibleAnnotationRenderKeys: keysToEmit)
    }

    /// Returns sample row keys in effective display order (persisted order + any new rows).
    private func resolvedSampleOrder() -> [String] {
        guard let order = currentSampleDisplayState.sampleOrder else { return allSampleRowKeys }
        let allSet = Set(allSampleRowKeys)
        var ordered = order.filter { allSet.contains($0) }
        let orderedSet = Set(ordered)
        ordered.append(contentsOf: allSampleRowKeys.filter { !orderedSet.contains($0) })
        return ordered
    }

    /// Sorts sample row keys by samples-tab column key.
    private func sortedSampleNames(key: String, ascending: Bool, names: [String]) -> [String] {
        names.sorted { rowKeyA, rowKeyB in
            let nameA = sampleNameByRowKey[rowKeyA] ?? ""
            let nameB = sampleNameByRowKey[rowKeyB] ?? ""
            let metaA = sampleMetadata[rowKeyA] ?? [:]
            let metaB = sampleMetadata[rowKeyB] ?? [:]
            let sourceA = sampleSourceFiles[rowKeyA] ?? ""
            let sourceB = sampleSourceFiles[rowKeyB] ?? ""
            let visibleA = !currentSampleDisplayState.hiddenSamples.contains(nameA)
            let visibleB = !currentSampleDisplayState.hiddenSamples.contains(nameB)
            let result: ComparisonResult
            switch key {
            case "visible":
                result = visibleA == visibleB ? .orderedSame : (visibleA ? .orderedAscending : .orderedDescending)
            case "sample_name":
                result = nameA.localizedCaseInsensitiveCompare(nameB)
            case "display_name":
                let displayA = (sampleDisplayNamesCache[rowKeyA] ?? nameA).trimmingCharacters(in: .whitespacesAndNewlines)
                let displayB = (sampleDisplayNamesCache[rowKeyB] ?? nameB).trimmingCharacters(in: .whitespacesAndNewlines)
                result = displayA.localizedCaseInsensitiveCompare(displayB)
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
                if nameA.caseInsensitiveCompare(nameB) == .orderedSame {
                    return rowKeyA.localizedCaseInsensitiveCompare(rowKeyB) == .orderedAscending
                }
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
        let isEditableColumn = isMetaColumn || identifier == Self.sampleDisplayNameColumn

        // Text cell for all other columns
        let cellView: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let tf: NSTextField
            if isEditableColumn {
                // Editable text field for metadata and display name columns
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
        case Self.sampleDisplayNameColumn:
            tf.stringValue = sample.displayName ?? ""
            tf.placeholderString = sample.name
            tf.textColor = sample.isVisible ? .labelColor : .tertiaryLabelColor
            tf.tag = row
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
        } else if activeTab == .variants {
            markVariantFilterStateMutated()
            updateDisplayedAnnotations()
        }
    }

    @objc private func variantColorThemeDidChange(_ note: Notification) {
        if activeTab == .variants { tableView.reloadData() }
    }

    // MARK: - Variant Query Progress

    private func invalidateInFlightVariantQueries() {
        variantQueryWorkItem?.cancel()
        variantQueryWorkItem = nil
        activeVariantQueryCancelToken?.cancel()
        activeVariantQueryCancelToken = nil
        variantQueryGeneration += 1
    }

    private func showVariantQueryProgress(_ message: String) {
        isVariantQuerying = true
        displayedAnnotations = []
        queryProgressLabel.stringValue = message
        queryProgressLabel.isHidden = false
        queryProgressBar.isHidden = false
        queryProgressBar.startAnimation(nil)
        scrollView.isHidden = true
        tooManyLabel.isHidden = true
        countLabel.stringValue = "Querying\u{2026}"
    }

    private func hideVariantQueryProgress() {
        isVariantQuerying = false
        queryProgressLabel.isHidden = true
        queryProgressBar.isHidden = true
        queryProgressBar.stopAnimation(nil)
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

    private func buildSampleContextMenu(_ menu: NSMenu, row: Int, clickedColumn: Int) {
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

        if clickedColumn >= 0, clickedColumn < tableView.tableColumns.count {
            let column = tableView.tableColumns[clickedColumn]
            let columnId = column.identifier.rawValue
            if let filterKey = sampleFilterKey(forColumnIdentifier: columnId) {
                let value = sampleFilterValue(sample: sample, columnIdentifier: columnId)
                menu.addItem(NSMenuItem.separator())

                let applyMenu = NSMenu(title: "Filter Column")
                let applyMenuItem = NSMenuItem(title: "Filter Column", action: nil, keyEquivalent: "")
                applyMenuItem.submenu = applyMenu
                menu.addItem(applyMenuItem)

                addSampleColumnFilterItem(
                    to: applyMenu,
                    title: "Equals",
                    key: filterKey,
                    op: "=",
                    value: value
                )
                addSampleColumnFilterItem(
                    to: applyMenu,
                    title: "Not Equals",
                    key: filterKey,
                    op: "!=",
                    value: value
                )
                if !value.isEmpty {
                    addSampleColumnFilterItem(
                        to: applyMenu,
                        title: "Contains",
                        key: filterKey,
                        op: "~",
                        value: value
                    )
                    addSampleColumnFilterItem(
                        to: applyMenu,
                        title: "Begins With",
                        key: filterKey,
                        op: "^=",
                        value: value
                    )
                    addSampleColumnFilterItem(
                        to: applyMenu,
                        title: "Ends With",
                        key: filterKey,
                        op: "$=",
                        value: value
                    )
                }
                addSampleColumnFilterItem(
                    to: applyMenu,
                    title: "Is Empty",
                    key: filterKey,
                    op: "=",
                    value: ""
                )
                addSampleColumnFilterItem(
                    to: applyMenu,
                    title: "Is Not Empty",
                    key: filterKey,
                    op: "!=",
                    value: ""
                )
            }
        }

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

        menu.addItem(NSMenuItem.separator())
        let groupFromShown = NSMenuItem(title: "Create Group from Shown Results\u{2026}", action: #selector(createSampleGroupFromShownResults(_:)), keyEquivalent: "")
        groupFromShown.target = self
        menu.addItem(groupFromShown)
    }

    private func sampleFilterKey(forColumnIdentifier columnId: String) -> String? {
        switch columnId {
        case Self.sampleNameColumn.rawValue:
            return "name"
        case Self.sampleDisplayNameColumn.rawValue:
            return "display_name"
        case Self.sampleSourceColumn.rawValue:
            return "source"
        case Self.sampleVisibleColumn.rawValue:
            return "visible"
        default:
            if columnId.hasPrefix("meta_") {
                return "meta.\(String(columnId.dropFirst(5)))"
            }
            return nil
        }
    }

    private func sampleFilterValue(sample: SampleDisplayRow, columnIdentifier columnId: String) -> String {
        switch columnId {
        case Self.sampleNameColumn.rawValue:
            return sample.name
        case Self.sampleDisplayNameColumn.rawValue:
            return sample.displayName ?? ""
        case Self.sampleSourceColumn.rawValue:
            return sample.sourceFile
        case Self.sampleVisibleColumn.rawValue:
            return sample.isVisible ? "true" : "false"
        default:
            if columnId.hasPrefix("meta_") {
                let key = String(columnId.dropFirst(5))
                return sample.metadata[key] ?? ""
            }
            return ""
        }
    }

    private func addSampleColumnFilterItem(
        to menu: NSMenu,
        title: String,
        key: String,
        op: String,
        value: String
    ) {
        let item = NSMenuItem(title: title, action: #selector(applySampleColumnFilterAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["key": key, "op": op, "value": value]
        menu.addItem(item)
    }

    @objc private func applySampleColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        let clause = value.isEmpty ? "\(key)\(op)" : "\(key)\(op)\(value)"
        let current = sampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        sampleFilterText = current.isEmpty ? clause : "\(current); \(clause)"
        updateDisplayedSamples()
    }

    @objc private func promptSampleColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Sample Filter"
        alert.informativeText = "Enter a value for \(key)."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Filter value"
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let self else { return }
            let clause = "\(key)\(op)\(value)"
            let current = self.sampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sampleFilterText = current.isEmpty ? clause : "\(current); \(clause)"
            self.updateDisplayedSamples()
        }
    }

    private func buildSampleGlobalContextMenu(_ menu: NSMenu) {
        addColumnSizingMenuItems(menu, tableColumn: nil)
        menu.addItem(NSMenuItem.separator())

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

        menu.addItem(NSMenuItem.separator())
        let groupFromShown = NSMenuItem(title: "Create Group from Shown Results\u{2026}", action: #selector(createSampleGroupFromShownResults(_:)), keyEquivalent: "")
        groupFromShown.target = self
        menu.addItem(groupFromShown)
    }

    private func buildSampleColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else {
            buildSampleGlobalContextMenu(menu)
            return
        }
        let tableColumn = tableView.tableColumns[column]
        guard let key = sampleFilterKey(forColumnIdentifier: tableColumn.identifier.rawValue) else {
            buildSampleGlobalContextMenu(menu)
            return
        }
        let displayName = tableColumn.title.isEmpty ? "Visible" : tableColumn.title

        addColumnSizingMenuItems(menu, tableColumn: tableColumn)
        menu.addItem(NSMenuItem.separator())

        let containsItem = NSMenuItem(
            title: "Filter \(displayName) Contains\u{2026}",
            action: #selector(promptSampleColumnFilterAction(_:)),
            keyEquivalent: ""
        )
        containsItem.target = self
        containsItem.representedObject = ["key": key, "op": "~"]
        menu.addItem(containsItem)

        let equalsItem = NSMenuItem(
            title: "Filter \(displayName) Equals\u{2026}",
            action: #selector(promptSampleColumnFilterAction(_:)),
            keyEquivalent: ""
        )
        equalsItem.target = self
        equalsItem.representedObject = ["key": key, "op": "="]
        menu.addItem(equalsItem)

        let beginsWithItem = NSMenuItem(
            title: "Filter \(displayName) Begins With\u{2026}",
            action: #selector(promptSampleColumnFilterAction(_:)),
            keyEquivalent: ""
        )
        beginsWithItem.target = self
        beginsWithItem.representedObject = ["key": key, "op": "^="]
        menu.addItem(beginsWithItem)

        let endsWithItem = NSMenuItem(
            title: "Filter \(displayName) Ends With\u{2026}",
            action: #selector(promptSampleColumnFilterAction(_:)),
            keyEquivalent: ""
        )
        endsWithItem.target = self
        endsWithItem.representedObject = ["key": key, "op": "$="]
        menu.addItem(endsWithItem)

        menu.addItem(NSMenuItem.separator())
        addSampleColumnFilterItem(to: menu, title: "Filter \(displayName) Is Empty", key: key, op: "=", value: "")
        addSampleColumnFilterItem(to: menu, title: "Filter \(displayName) Is Not Empty", key: key, op: "!=", value: "")
        menu.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Sample Filters", action: #selector(clearSampleFilter(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        if tableColumn.identifier.rawValue.hasPrefix("meta_") {
            let metaKey = String(tableColumn.identifier.rawValue.dropFirst(5))
            menu.addItem(NSMenuItem.separator())
            let removeItem = NSMenuItem(title: "Delete Column\u{2026}", action: #selector(deleteSampleMetadataFieldAction(_:)), keyEquivalent: "")
            removeItem.target = self
            removeItem.representedObject = metaKey
            menu.addItem(removeItem)
        }
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

    @objc private func createSampleGroupFromShownResults(_ sender: NSMenuItem) {
        guard !displayedSamples.isEmpty, let window = self.window else { return }
        let alert = NSAlert()
        alert.messageText = "Create Sample Group"
        alert.informativeText = "Create a group from the currently shown \(displayedSamples.count) samples."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "Group name"
        alert.accessoryView = nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let sampleNames = Set(self.displayedSamples.map(\.name))
            guard !sampleNames.isEmpty else { return }
            if let idx = self.currentSampleDisplayState.sampleGroups.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                self.currentSampleDisplayState.sampleGroups[idx].sampleNames = sampleNames
            } else {
                self.currentSampleDisplayState.sampleGroups.append(
                    SampleGroup(name: name, sampleNames: sampleNames)
                )
            }
            self.postSampleDisplayStateChange()
            self.rebuildSampleGroupPresetMenu()
        }
    }

    private func showSampleColumnHeaderFilterMenu(column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        guard let headerView = tableView.headerView else { return }
        let menu = NSMenu()
        buildSampleColumnHeaderContextMenu(menu, column: column)
        let rect = headerView.headerRect(ofColumn: column)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    private func showAnnotationColumnHeaderFilterMenu(column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        guard let headerView = tableView.headerView else { return }
        let menu = NSMenu()
        buildAnnotationColumnHeaderContextMenu(menu, column: column)
        let rect = headerView.headerRect(ofColumn: column)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    private func showVariantColumnHeaderFilterMenu(column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        guard let headerView = tableView.headerView else { return }
        let menu = NSMenu()
        buildVariantColumnHeaderContextMenu(menu, column: column)
        let rect = headerView.headerRect(ofColumn: column)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    @objc private func deleteSampleMetadataFieldAction(_ sender: NSMenuItem) {
        guard let fieldName = sender.representedObject as? String,
              !fieldName.isEmpty,
              sampleMetadataFields.contains(fieldName),
              let window = self.window else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Metadata Column?"
        alert.informativeText = "Delete '\(fieldName)' from all samples and variant databases? This cannot be undone."
        alert.addButton(withTitle: "Delete Column")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard let searchIndex = self.searchIndex else { return }

            let fieldToRemove = fieldName
            let sampleRows = self.allSampleRowKeys.compactMap { rowKey -> (name: String, sourceFile: String, metadata: [String: String])? in
                guard let sampleName = self.sampleNameByRowKey[rowKey] else { return nil }
                return (sampleName, self.sampleSourceFiles[rowKey] ?? "", self.sampleMetadata[rowKey] ?? [:])
            }
            let dbURLs = searchIndex.variantDatabaseHandles.map(\.db.databaseURL)

            DispatchQueue.global(qos: .userInitiated).async {
                var firstError: Error?
                for dbURL in dbURLs {
                    do {
                        let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
                        let dbSourceBySample = rwDB.allSourceFiles()
                        for sample in sampleRows {
                            guard let dbSource = dbSourceBySample[sample.name] else {
                                continue
                            }
                            if !Self.sourceFileMatches(dbSource, sample.sourceFile) {
                                continue
                            }
                            var updated = sample.metadata
                            updated.removeValue(forKey: fieldToRemove)
                            try rwDB.updateSampleMetadata(name: sample.name, metadata: updated)
                        }
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let error = firstError {
                            let errorAlert = NSAlert()
                            errorAlert.alertStyle = .warning
                            errorAlert.messageText = "Could Not Delete Column"
                            errorAlert.informativeText = error.localizedDescription
                            errorAlert.beginSheetModal(for: window)
                            return
                        }

                        self.sampleMetadataFields.removeAll { $0 == fieldToRemove }
                        self.populateSampleData(from: searchIndex)
                        self.configureColumnsForTab(.samples)
                        self.updateDisplayedSamples()
                        drawerLogger.info("deleteSampleMetadataFieldAction: Removed metadata field '\(fieldToRemove, privacy: .public)'")
                    }
                }
            }
        }
    }

    // MARK: - Import Metadata

    @objc private func downloadSampleTemplateAction(_ sender: Any?) {
        guard let searchIndex else { return }

        let uniqueSourceFiles = Set(
            searchIndex.variantDatabaseHandles
                .flatMap { Array($0.db.allSourceFiles().values) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let defaultTemplateStem: String
        if uniqueSourceFiles.count == 1, let onlySource = uniqueSourceFiles.first {
            let sourceBase = URL(fileURLWithPath: onlySource).deletingPathExtension().lastPathComponent
            let safeSource = sourceBase
                .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
            if safeSource.isEmpty {
                defaultTemplateStem = "sample-metadata-source-template"
            } else {
                defaultTemplateStem = "sample-metadata-\(safeSource)-template"
            }
        } else if uniqueSourceFiles.count > 1 {
            defaultTemplateStem = "sample-metadata-multi-source-template"
        } else {
            defaultTemplateStem = "sample-metadata-template"
        }

        let panel = NSSavePanel()
        panel.title = "Save Sample Metadata Template"
        panel.prompt = "Save Template"
        panel.nameFieldStringValue = "\(defaultTemplateStem).tsv"
        panel.allowedContentTypes = [
            .init(filenameExtension: "tsv")!,
            .init(filenameExtension: "csv")!,
        ]

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let isCSV = url.pathExtension.lowercased() == "csv"
            let delimiter = isCSV ? "," : "\t"

            var sampleRows: [(name: String, sourceFile: String)] = []
            var seenRows = Set<String>()
            for handle in searchIndex.variantDatabaseHandles {
                let db = handle.db
                let dbSourceFiles = db.allSourceFiles()
                for sampleName in db.sampleNames() {
                    let sourceFile = dbSourceFiles[sampleName] ?? ""
                    let normalizedKey = "\(sampleName.lowercased())|\(sourceFile.lowercased())"
                    if seenRows.insert(normalizedKey).inserted {
                        sampleRows.append((name: sampleName, sourceFile: sourceFile))
                    }
                }
            }
            guard !sampleRows.isEmpty else { return }

            var columns = ["sample_name", "source_file"]
            columns.append(contentsOf: self.sampleMetadataFields)
            let header = columns.joined(separator: delimiter)
            let rows = sampleRows.map { row -> String in
                var values = [row.name, row.sourceFile]
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

    @objc private func importMetadataAction(_ sender: Any?) {
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

    // MARK: - Sample Groups

    @objc private func showSampleGroupsSheet(_ sender: Any?) {
        guard let hostWindow = self.window else { return }

        let sheetView = SampleGroupSheet(
            groups: currentSampleDisplayState.sampleGroups,
            allSampleNames: allSampleNames,
            onApply: { [weak self] groups in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        hostWindow.endSheet(hostWindow.sheets.last ?? hostWindow)
                        self.currentSampleDisplayState.sampleGroups = groups
                        if let selected = self.selectedSampleGroupId,
                           !groups.contains(where: { $0.id == selected }) {
                            self.selectedSampleGroupId = nil
                        }
                        self.postSampleDisplayStateChange()
                        self.rebuildSampleGroupPresetMenu()
                        self.updateDisplayedSamples()
                    }
                }
            },
            onCancel: {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        hostWindow.endSheet(hostWindow.sheets.last ?? hostWindow)
                    }
                }
            }
        )

        let hostingController = NSHostingController(rootView: sheetView)
        let sheetWindow = NSPanel(contentViewController: hostingController)
        sheetWindow.styleMask = [.titled, .closable, .resizable]
        sheetWindow.title = "Sample Groups"
        hostWindow.beginSheet(sheetWindow)
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

        let columnId = tableView.tableColumns[column].identifier
        let newValue = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sampleName = displayedSamples[row].name
        let sampleSourceFile = displayedSamples[row].sourceFile
        let sampleRowKey = displayedSamples[row].rowKey

        // Handle Display Name column edits
        if columnId == Self.sampleDisplayNameColumn {
            let displayName = newValue.isEmpty ? nil : newValue
            displayedSamples[row].displayName = displayName
            if let displayName {
                sampleDisplayNamesCache[sampleRowKey] = displayName
            } else {
                sampleDisplayNamesCache.removeValue(forKey: sampleRowKey)
            }
            // Persist to DB
            if let searchIndex {
                for handle in searchIndex.variantDatabaseHandles {
                    do {
                        let rwDB = try VariantDatabase(url: handle.db.databaseURL, readWrite: true)
                        let dbSourceBySample = rwDB.allSourceFiles()
                        guard let dbSource = dbSourceBySample[sampleName],
                              Self.sourceFileMatches(dbSource, sampleSourceFile) else { continue }
                        rwDB.setDisplayName(forSample: sampleName, displayName: displayName)
                    } catch {
                        drawerLogger.warning("Display name edit failed: \(error.localizedDescription)")
                    }
                }
            }
            // Update state and notify viewport
            if let displayName {
                currentSampleDisplayState.sampleDisplayNameOverrides[sampleName] = displayName
            } else {
                currentSampleDisplayState.sampleDisplayNameOverrides.removeValue(forKey: sampleName)
            }
            postSampleDisplayStateChange()
            return
        }

        // Handle metadata column edits
        guard columnId.rawValue.hasPrefix("meta_") else { return }

        let metaKey = String(columnId.rawValue.dropFirst(5))

        // Update local model
        if newValue.isEmpty {
            displayedSamples[row].metadata.removeValue(forKey: metaKey)
        } else {
            displayedSamples[row].metadata[metaKey] = newValue
        }
        // Keep backing metadata cache in sync so refresh/sort/filter preserves edits.
        sampleMetadata[sampleRowKey] = displayedSamples[row].metadata

        // Persist to database
        guard let searchIndex else { return }
        let fullMetadata = displayedSamples[row].metadata

        for handle in searchIndex.variantDatabaseHandles {
            do {
                let rwDB = try VariantDatabase(url: handle.db.databaseURL, readWrite: true)
                let dbSourceBySample = rwDB.allSourceFiles()
                guard let dbSource = dbSourceBySample[sampleName],
                      Self.sourceFileMatches(dbSource, sampleSourceFile) else { continue }
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
        let draggedKeys = draggedItems.map(\.rowKey)
        let draggedKeySet = Set(draggedKeys)

        let fullOrder = resolvedSampleOrder()
        var reordered = fullOrder.filter { !draggedKeySet.contains($0) }

        // Insert relative to visible rows, but apply to full ordering.
        let insertionIndex: Int
        if row >= displayedSamples.count {
            insertionIndex = reordered.count
        } else {
            let anchorKey = displayedSamples[row].rowKey
            insertionIndex = reordered.firstIndex(of: anchorKey) ?? reordered.count
        }
        reordered.insert(contentsOf: draggedKeys, at: insertionIndex)

        // Update display state with new order
        currentSampleDisplayState.sampleOrder = reordered
        postSampleDisplayStateChange()
        updateDisplayedSamples()
        return true
    }
}

// MARK: - Background Variant Query Helpers

private final class VariantQueryCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

/// Snapshot of variant database state needed for background queries.
/// All fields are `Sendable` (VariantDatabase/AnnotationDatabase are @unchecked Sendable).
private struct VariantQueryContext: @unchecked Sendable {
    let databases: [(trackId: String, db: VariantDatabase)]
    let trackNames: [String: String]
    let trackChromosomes: [String: Set<String>]
    let annotationDatabases: [(trackId: String, db: AnnotationDatabase)]
    let infoKeys: Set<String>
    /// Maps reference chromosome names → VCF chromosome names (from contig length matching).
    let variantAliasMap: [String: String]

    func resolvedChromosomeCandidates(for chromosome: String, trackId: String) -> [String] {
        let available = trackChromosomes[trackId] ?? []
        return resolveVariantChromosomeCandidates(
            requestedChromosome: chromosome,
            availableChromosomes: available,
            aliasMap: variantAliasMap
        )
    }

    func variantRecordsToSearchResults(
        _ records: [VariantDatabaseRecord],
        db: VariantDatabase,
        trackId: String
    ) -> [AnnotationSearchIndex.SearchResult] {
        guard !records.isEmpty else { return [] }
        let variantIds = records.compactMap(\.id)
        let infoDicts = db.batchInfoValues(variantIds: variantIds)
        let sourceName = trackNames[trackId]
        return records.map { record in
            let infoDict = record.id.flatMap { infoDicts[$0] }
            return record.toSearchResult(trackId: trackId, infoDict: infoDict, sourceFile: sourceName)
        }
    }

    func queryVariantsInRegion(
        chromosome: String, start: Int, end: Int,
        nameFilter: String = "", types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        activeTokens: Set<String> = [],
        limit: Int = 5000,
        shouldCancel: (() -> Bool)? = nil
    ) -> [AnnotationSearchIndex.SearchResult] {
        var results: [AnnotationSearchIndex.SearchResult] = []
        for handle in databases {
            if shouldCancel?() == true { break }
            let remaining = limit - results.count
            guard remaining > 0 else { break }
            handle.db.installQueryTimeout(seconds: 5.0, cancelCheck: shouldCancel)
            defer { handle.db.removeQueryTimeout() }
            for queryChrom in resolvedChromosomeCandidates(for: chromosome, trackId: handle.trackId) {
                if shouldCancel?() == true { break }
                let chunkLimit = limit - results.count
                guard chunkLimit > 0 else { break }
                let records = handle.db.queryForTableInRegion(
                    chromosome: queryChrom, start: start, end: end,
                    nameFilter: nameFilter, types: types,
                    infoFilters: infoFilters, sampleNames: sampleNames,
                    activeTokens: activeTokens, limit: chunkLimit
                )
                if !records.isEmpty {
                    results.append(contentsOf: variantRecordsToSearchResults(records, db: handle.db, trackId: handle.trackId))
                }
            }
        }
        return results
    }

    func queryVariantCountInRegion(
        chromosome: String, start: Int, end: Int,
        nameFilter: String = "", types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        shouldCancel: (() -> Bool)? = nil
    ) -> Int {
        var count = 0
        for handle in databases {
            if shouldCancel?() == true { break }
            handle.db.installQueryTimeout(seconds: 5.0, cancelCheck: shouldCancel)
            defer { handle.db.removeQueryTimeout() }
            for queryChrom in resolvedChromosomeCandidates(for: chromosome, trackId: handle.trackId) {
                if shouldCancel?() == true { break }
                count += handle.db.queryCountInRegion(
                    chromosome: queryChrom, start: start, end: end,
                    nameFilter: nameFilter, types: types,
                    infoFilters: infoFilters, sampleNames: sampleNames
                )
            }
        }
        return count
    }

    func queryVariantsOnly(
        chromosome: String? = nil,
        nameFilter: String = "", types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        activeTokens: Set<String> = [],
        limit: Int = 5000,
        shouldCancel: (() -> Bool)? = nil
    ) -> [AnnotationSearchIndex.SearchResult] {
        var results: [AnnotationSearchIndex.SearchResult] = []
        for handle in databases {
            if shouldCancel?() == true { break }
            let remaining = limit - results.count
            guard remaining > 0 else { break }
            let variantTypes = Set(handle.db.allTypes())
            let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
            guard !requestedVariantTypes.isEmpty || types.isEmpty else { continue }
            // Resolve the chromosome name for this track's database
            let dbChromosome: String? = chromosome.flatMap { chrom in
                let candidates = resolvedChromosomeCandidates(for: chrom, trackId: handle.trackId)
                return candidates.first
            }
            handle.db.installQueryTimeout(seconds: 5.0, cancelCheck: shouldCancel)
            defer { handle.db.removeQueryTimeout() }
            let records = handle.db.queryForTable(
                chromosome: dbChromosome,
                nameFilter: nameFilter,
                types: types.isEmpty ? [] : requestedVariantTypes,
                infoFilters: infoFilters, sampleNames: sampleNames,
                activeTokens: activeTokens, limit: remaining
            )
            results.append(contentsOf: variantRecordsToSearchResults(records, db: handle.db, trackId: handle.trackId))
        }
        return results
    }

    func queryVariantCount(
        chromosome: String? = nil,
        nameFilter: String = "", types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        shouldCancel: (() -> Bool)? = nil
    ) -> Int {
        var count = 0
        for handle in databases {
            if shouldCancel?() == true { break }
            let variantTypes = Set(handle.db.allTypes())
            let requestedVariantTypes = types.isEmpty ? variantTypes : types.intersection(variantTypes)
            if !requestedVariantTypes.isEmpty || types.isEmpty {
                let dbChromosome: String? = chromosome.flatMap { chrom in
                    let candidates = resolvedChromosomeCandidates(for: chrom, trackId: handle.trackId)
                    return candidates.first
                }
                handle.db.installQueryTimeout(seconds: 5.0, cancelCheck: shouldCancel)
                defer { handle.db.removeQueryTimeout() }
                count += handle.db.queryCountForTable(
                    chromosome: dbChromosome,
                    nameFilter: nameFilter,
                    types: requestedVariantTypes,
                    infoFilters: infoFilters,
                    sampleNames: sampleNames
                )
            }
        }
        return count
    }

    func queryVariantsForGenes(
        _ geneNames: [String],
        types: Set<String> = [],
        infoFilters: [VariantDatabase.InfoFilter] = [],
        sampleNames: Set<String> = [],
        activeTokens: Set<String> = [],
        limit: Int = 5000,
        shouldCancel: (() -> Bool)? = nil
    ) -> (results: [AnnotationSearchIndex.SearchResult], resolvedRegions: [GeneRegion]) {
        guard !geneNames.isEmpty else { return ([], []) }
        var seenRowIds = Set<Int64>()
        var results: [AnnotationSearchIndex.SearchResult] = []
        let resolvedRegions = resolveGeneRegions(geneNames)
        let annotationRegions = resolvedRegions.map { (chromosome: $0.chromosome, start: $0.start, end: $0.end, gene: $0.name) }

        // Query variants overlapping pre-resolved annotation regions.
        for region in annotationRegions {
            if shouldCancel?() == true { break }
            guard results.count < limit else { break }
            let regionVariants = queryVariantsInRegion(
                chromosome: region.chromosome, start: region.start, end: region.end,
                types: types,
                infoFilters: infoFilters,
                sampleNames: sampleNames,
                activeTokens: activeTokens,
                limit: limit - results.count,
                shouldCancel: shouldCancel
            )
            for v in regionVariants {
                if seenRowIds.insert(v.variantRowId ?? -1).inserted || v.variantRowId == nil {
                    results.append(v)
                }
            }
        }

        // Also search by INFO GENE/SYMBOL fields.
        let geneInfoKeyNames = ["GENE", "Gene", "gene", "GENEINFO", "SYMBOL", "ANN_Gene", "CSQ_SYMBOL"]
        for gene in geneNames {
            if shouldCancel?() == true { break }
            let trimmed = gene.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, results.count < limit else { continue }
            for geneKey in geneInfoKeyNames {
                if shouldCancel?() == true { break }
                guard infoKeys.contains(geneKey), results.count < limit else { continue }
                var mergedFilters = infoFilters
                mergedFilters.append(VariantDatabase.InfoFilter(key: geneKey, op: .like, value: trimmed))
                let infoResults = queryVariantsOnly(
                    types: types,
                    infoFilters: mergedFilters,
                    sampleNames: sampleNames,
                    activeTokens: activeTokens,
                    limit: limit - results.count,
                    shouldCancel: shouldCancel
                )
                for v in infoResults {
                    if seenRowIds.insert(v.variantRowId ?? -1).inserted || v.variantRowId == nil {
                        results.append(v)
                    }
                }
            }
        }

        return (Array(results.prefix(limit)), resolvedRegions)
    }

    private func resolveGeneRegions(_ geneNames: [String]) -> [GeneRegion] {
        let preferredTypes = ["gene", "mrna", "transcript", "cds", "exon"]
        var resolved: [GeneRegion] = []
        var seen = Set<String>()

        for rawName in geneNames {
            let queryName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !queryName.isEmpty else { continue }
            let normalized = queryName.lowercased()
            guard seen.insert(normalized).inserted else { continue }

            var candidates: [AnnotationDatabaseRecord] = []
            for handle in annotationDatabases {
                let rows = handle.db.query(nameFilter: queryName, limit: 64)
                if !rows.isEmpty { candidates.append(contentsOf: rows) }
            }
            guard !candidates.isEmpty else { continue }

            func score(_ row: AnnotationDatabaseRecord) -> (Int, Int, Int, String, Int) {
                let nameLower = row.name.lowercased()
                let nameScore: Int
                if nameLower == normalized {
                    nameScore = 0
                } else if nameLower.hasPrefix(normalized) {
                    nameScore = 1
                } else if nameLower.contains(normalized) {
                    nameScore = 2
                } else {
                    nameScore = 3
                }
                let typeScore = preferredTypes.firstIndex(of: row.type.lowercased()) ?? (preferredTypes.count + 1)
                let span = max(0, row.end - row.start)
                return (nameScore, typeScore, span, row.chromosome, row.start)
            }

            guard let best = candidates.min(by: { score($0) < score($1) }) else { continue }
            resolved.append(GeneRegion(name: queryName, chromosome: best.chromosome, start: best.start, end: best.end))
        }

        return resolved
    }
}

/// Adaptive post-filtering loop (free function, safe to call from any thread).
private func fetchVariantsAdaptive(
    maxDisplayCount: Int,
    initialFetchLimit: Int,
    totalSQLMatchCount: Int?,
    applyPostFiltering: Bool,
    fetch: (Int) -> [AnnotationSearchIndex.SearchResult],
    postFilter: ([AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult],
    shouldCancel: (() -> Bool)? = nil
) -> [AnnotationSearchIndex.SearchResult] {
    let minimumLimit = max(maxDisplayCount, initialFetchLimit)
    if !applyPostFiltering {
        if shouldCancel?() == true { return [] }
        return Array(fetch(minimumLimit).prefix(maxDisplayCount))
    }

    var fetchLimit = minimumLimit
    var previousRawCount = -1
    var filtered: [AnnotationSearchIndex.SearchResult] = []

    while true {
        if shouldCancel?() == true { break }
        let raw = fetch(fetchLimit)
        if shouldCancel?() == true { break }
        filtered = postFilter(raw)
        if filtered.count >= maxDisplayCount { break }
        if raw.count < fetchLimit { break }
        if let totalSQLMatchCount, fetchLimit >= totalSQLMatchCount { break }
        if raw.count == previousRawCount { break }
        previousRawCount = raw.count

        let nextCandidate = max(fetchLimit * 2, fetchLimit + maxDisplayCount * 2)
        if let totalSQLMatchCount {
            let next = min(totalSQLMatchCount, nextCandidate)
            if next <= fetchLimit { break }
            fetchLimit = next
        } else {
            let next = min(maxDisplayCount * 40, nextCandidate)
            if next <= fetchLimit { break }
            fetchLimit = next
        }
    }

    return Array(filtered.prefix(maxDisplayCount))
}

/// Pure variant advanced filters (free function, safe to call from any thread).
private func applyVariantAdvancedFiltersOffMain(
    _ results: [AnnotationSearchIndex.SearchResult],
    query: AnnotationTableDrawerView.VariantFilterQuery  // fileprivate access
) -> [AnnotationSearchIndex.SearchResult] {
    results.filter { row in
        if let explicitTypeFilter = query.explicitTypeFilter, !explicitTypeFilter.isEmpty {
            let matchesType = explicitTypeFilter.contains { candidate in
                row.type.caseInsensitiveCompare(candidate) == .orderedSame
            }
            if !matchesType { return false }
        }
        if let filterVal = query.filterValue {
            let rowFilter = row.filter ?? "."
            if rowFilter.caseInsensitiveCompare(filterVal) != .orderedSame { return false }
        }
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

/// Pure moderate-or-higher impact filter (free function, safe to call from any thread).
private func filterModerateOrHigherImpactOffMain(
    _ results: [AnnotationSearchIndex.SearchResult]
) -> [AnnotationSearchIndex.SearchResult] {
    let impactKeys = SmartToken.impactKeys
    return results.filter { result in
        guard let info = result.infoDict else { return false }
        for key in impactKeys {
            guard let raw = info[key], !raw.isEmpty else { continue }
            let value = raw.uppercased()
            if value.contains("HIGH") || value.contains("MODERATE") { return true }
        }
        return false
    }
}

/// Pure within-sample AF filter (free function, safe to call from any thread).
private func filterByWithinSampleAFOffMain(
    _ results: [AnnotationSearchIndex.SearchResult],
    min: Double, max: Double
) -> [AnnotationSearchIndex.SearchResult] {
    results.filter { result in
        guard let info = result.infoDict,
              let raw = info["AF"] ?? info["af"],
              !raw.isEmpty else { return false }
        let values = raw.split(separator: ",").compactMap { Double($0) }
        guard let af = values.max() else { return false }
        return af >= min && af <= max
    }
}

/// Pure viewport-region filter used after genome-wide queries.
private func filterVariantsToRegionOffMain(
    _ results: [AnnotationSearchIndex.SearchResult],
    chromosome: String,
    start: Int,
    end: Int
) -> [AnnotationSearchIndex.SearchResult] {
    let canonicalTargetChromosome = canonicalChromosomeForFiltering(chromosome)
    return results.filter { row in
        guard canonicalChromosomeForFiltering(row.chromosome) == canonicalTargetChromosome else { return false }
        return row.start <= end && row.end >= start
    }
}

private func canonicalChromosomeForFiltering(_ raw: String) -> String {
    var value = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("chr") {
        value = String(value.dropFirst(3))
    }
    if let dot = value.firstIndex(of: ".") {
        value = String(value[..<dot])
    }
    return value
}
