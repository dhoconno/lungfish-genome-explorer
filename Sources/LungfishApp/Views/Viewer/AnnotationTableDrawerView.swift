// AnnotationTableDrawerView.swift - Geneious-style bottom annotation drawer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit

/// Logger for annotation drawer operations
let annotationDrawerLogger = Logger(subsystem: LogSubsystem.app, category: "AnnotationDrawer")

// MARK: - WideColumnDividerHeaderView

/// Custom header view that expands the column-resize grab zone from ~3px to 8px each side.
private final class WideColumnDividerHeaderView: NSTableHeaderView {
    let expandedHitZone: CGFloat = 8

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

    func nearestColumnDivider(at x: CGFloat) -> CGFloat? {
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
    var dragStartY: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }

    func configureAccessibility() {
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
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestDeleteAnnotations annotations: [AnnotationSearchIndex.SearchResult])
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestDeleteAnnotationTrack trackID: String, trackName: String)
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

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestDeleteAnnotations annotations: [AnnotationSearchIndex.SearchResult]) {}

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestDeleteAnnotationTrack trackID: String, trackName: String) {}

    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        fallbackConsequenceFor result: AnnotationSearchIndex.SearchResult
    ) -> (consequence: String?, aaChange: String?) {
        (nil, nil)
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

    static func defaultSampleDisplayState() -> SampleDisplayState {
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
    var windowStateScope: WindowStateScope?

    /// Reference to the search index for direct SQL queries.
    var searchIndex: AnnotationSearchIndex?
    var variantStorageMutationTask: Task<Void, Never>?
    private var variantStorageOperationID: UUID?
    var appliedVariantToolbarDensity: VariantToolbarDensity?

    /// The currently active tab.
    var activeTab: DrawerTab = .annotations

    /// Active subtab within the Variants tab (Calls vs Genotypes).
    var activeVariantSubtab: VariantSubtab = .calls

    /// Displayed genotype rows (genotype subtab).
    var displayedGenotypes: [GenotypeDisplayRow] = []
    /// Base genotype rows before local column filters.
    var baseDisplayedGenotypes: [GenotypeDisplayRow] = []

    /// Generation counter for stale genotype fetch prevention.
    var genotypeFetchGeneration: Int = 0
    /// Generation counter for stale annotation filter refreshes.
    var annotationQueryGeneration: Int = 0
    var activeAnnotationQueryCancelToken: VariantQueryCancellationToken?
    /// Independent lifecycle for record-scope count/type/column metadata.
    var annotationScopeMetadataQueryGeneration: Int = 0
    var activeAnnotationScopeMetadataQueryCancelToken: VariantQueryCancellationToken?

    /// Optional record scope for annotation-table database queries. `nil` means all
    /// records; an empty set deliberately means no records.
    var allowedAnnotationChromosomes: Set<String>?
    #if DEBUG
    var debugAnnotationScopeMetadataQueryGate: AnnotationScopeMetadataQueryGate?
    #endif

    /// Total annotation count in the database (annotation tab only).
    var totalAnnotationCount: Int = 0

    /// Total variant count in the database (variant tab only).
    var totalVariantCount: Int = 0

    /// Filtered and displayed annotations/variants.
    var displayedAnnotations: [AnnotationSearchIndex.SearchResult] = []

    /// Per-tab filter text so each tab preserves its own search state.
    var annotationFilterText: String = ""
    var variantFilterText: String = ""
    var sampleFilterText: String = ""

    /// Visible types for the annotation tab (empty means show all).
    var visibleAnnotationTypes: Set<String> = []

    /// Visible types for the variant tab (empty means show all).
    var visibleVariantTypes: Set<String> = []

    /// Convenience accessor for the active tab's visible types.
    var visibleTypes: Set<String> {
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
    var availableAnnotationTypes: [String] = []

    /// All distinct variant types found in the data.
    var availableVariantTypes: [String] = []

    /// Convenience accessor for the active tab's available types.
    var availableTypes: [String] {
        switch activeTab {
        case .annotations: return availableAnnotationTypes
        case .variants: return availableVariantTypes
        case .samples: return []
        }
    }

    /// Whether the index is currently loading.
    var isLoading: Bool = true {
        didSet { updateLoadingState() }
    }

    /// Guard flag to prevent notification re-entry when programmatically selecting rows.
    var isSuppressingDelegateCallbacks = false

    /// INFO field definitions for dynamic variant columns (key + type for sort awareness).
    var infoColumnKeys: [(key: String, type: String, description: String)] = []
    /// Annotation attribute keys discovered from loaded annotation rows.
    var annotationAttributeColumnKeys: [String] = []
    /// Preset INFO values used to render variant filter chips (key -> values).
    var variantInfoPresetValues: [(key: String, values: [String])] = []
    enum VariantPresetLoadState {
        case idle
        case loading
        case loaded
    }
    var variantPresetLoadState: VariantPresetLoadState = .idle
    var variantTrackDatabaseURLs: [URL] = []
    /// Maps reference chromosome names to variant DB chromosome names (from contig length matching).
    var variantChromosomeAliasMap: [String: String] = [:]
    /// Pre-computed SmartToken counts from cache warming.
    var smartTokenCounts: [String: Int] = [:]
    /// Active preset-chip selections (single selected value per INFO key).
    var selectedVariantPresetByKey: [String: String] = [:]
    /// Whether preset chips are expanded in the variants tab.
    var showVariantPresetChips: Bool = false

    /// True if the variant data comes from a haploid organism (virus/bacteria).
    /// Enables within-sample frequency smart tokens and related UI.
    var isHaploidOrganism: Bool = false

    /// Whether to auto-sync variant table with viewport (when variants tab is active).
    var viewportSyncEnabled: Bool = true

    enum HaploidModeSelection: String {
        case auto
        case haploid
        case diploid
    }

    /// User-selected haploid-mode behavior (defaults to automatic detection).
    var haploidModeSelection: HaploidModeSelection = .auto

    /// Current viewport region for auto-sync (set by viewer notification).
    var viewportRegion: (chromosome: String, start: Int, end: Int)?

    /// Debounce work item for viewport sync to avoid thrashing during rapid panning.
    var viewportSyncWorkItem: DispatchWorkItem?

    /// Debounce work item for annotation-tab text filtering.
    var annotationQueryWorkItem: DispatchWorkItem?

    /// Debounce work item for variant queries to collapse rapid filter/scope changes.
    var variantQueryWorkItem: DispatchWorkItem?

    /// Cooperative cancellation token for currently running background variant query.
    var activeVariantQueryCancelToken: VariantQueryCancellationToken?

    /// Optional source object to scope viewport sync notifications to a single viewer.
    weak var viewportSyncSourceObject: AnyObject?

    /// Stable source identifier for viewport sync scoping (survives weak-reference timing races).
    var viewportSyncSourceIdentifier: ObjectIdentifier?

    // MARK: - Annotation→Variant Cross-Reference

    /// Bounding region from current annotation search results (union of all annotation regions on the same chromosome).
    var annotationSearchRegion: (chromosome: String, start: Int, end: Int)?

    /// Specific annotation region selected by the user (e.g., via "Show Overlapping Variants").
    var selectedAnnotationRegion: (chromosome: String, start: Int, end: Int)?

    /// When enabled, the sequence viewport renders only annotation rows visible in this table.
    var annotationViewportFilterEnabled = false
    var annotationTrackOrder: [String] = []
    var hiddenAnnotationTrackIDs: Set<String> = []
    var annotationTrackDisplayNames: [String: String] = [:]
    var lastEmittedAnnotationTrackDisplayState: AnnotationTrackDisplayState?

    // MARK: - Sample Tab State

    /// All sample names from variant databases.
    var allSampleNames: [String] = []
    /// Compound sample row keys (sample + source) used for samples-tab display.
    var allSampleRowKeys: [String] = []
    /// Resolves a compound row key to the canonical sample name.
    var sampleNameByRowKey: [String: String] = [:]

    /// Per-sample metadata dictionaries.
    var sampleMetadata: [String: [String: String]] = [:]

    /// Source file/track per sample.
    var sampleSourceFiles: [String: String] = [:]

    /// Display name overrides per sample (keyed by row key).
    var sampleDisplayNamesCache: [String: String] = [:]

    /// Available metadata field names (union of all sample metadata keys).
    var sampleMetadataFields: [String] = []

    /// Filtered and displayed samples for the samples tab.
    var displayedSamples: [SampleDisplayRow] = []

    /// Active quick-filter tokens for the samples tab.
    var activeSampleTokens: Set<SampleSmartToken> = []
    /// Optional currently-selected sample-group preset.
    var selectedSampleGroupId: UUID?
    /// Snapshot of manual hidden-sample state before query-driven show-only filtering.
    var sampleFilterBaselineHiddenSamples: Set<String>?

    /// Local copy of sample display state for driving visibility toggles.
    var currentSampleDisplayState: SampleDisplayState = {
        AnnotationTableDrawerView.defaultSampleDisplayState()
    }()

    /// Whether we have received an authoritative sample display state from viewer/inspector.
    var hasSampleDisplayStateSeed = false

    /// Scope of the last variant query, for status label display.
    enum VariantQueryScope {
        case global
        case chromosome
        case viewport
        case annotations
        case annotation
        case placeholder
    }

    /// Database size threshold (1 GB) above which filtered queries are automatically
    /// scoped to the current chromosome for performance.
    static let chromosomeScopeThreshold: UInt64 = 1_000_000_000
    /// Database size threshold (25 GB) above which only pre-materialized token paths
    /// are allowed for variant filtering to keep interactions responsive.
    static let materializedOnlyThreshold: UInt64 = 25_000_000_000

    /// Last variant query match count used for status labeling (especially capped result sets).
    var lastVariantQueryMatchCount: Int?

    /// Last variant query scope for status labeling.
    var lastVariantQueryScope: VariantQueryScope = .global

    /// Generation counter for variant queries (prevents stale results from overwriting newer ones).
    var variantQueryGeneration: Int = 0

    /// Whether a variant query is currently in progress on a background thread.
    private(set) var isVariantQuerying: Bool = false

    /// Cached global results for the last filter-driven variant query.
    /// Used to make viewport exploration fast without re-running genome-wide SQL.
    var cachedGlobalFilteredVariantRows: [AnnotationSearchIndex.SearchResult] = []
    var cachedGlobalFilteredVariantKey: VariantQueryCacheKey?
    /// Controls whether viewport narrowing is applied on top of cached global filtered results.
    /// This remains false right after query/token changes (show global hits first), and flips
    /// to true during pan/zoom exploration.
    var allowViewportPostFilterDuringExploration: Bool = false
    /// Viewport snapshot captured when filter/query state last changed.
    /// Viewport narrowing is armed only after the viewport moves away from this snapshot.
    var viewportRegionAtLastFilterMutation: (chromosome: String, start: Int, end: Int)?

    #if DEBUG
    var debugAnnotationQueryExecutionCount: Int = 0
    var debugVariantQueryExecutionCount: Int = 0
    #endif

    // MARK: - UI Components

    let scrollView = NSScrollView()
    let tableView = NSTableView()
    let annotationFilterField = NSSearchField()
    let variantFilterField = NSSearchField()
    let sampleFilterField = NSSearchField()
    let sampleQueryBuilderButton = NSButton()
    let clearSampleFilterButton = NSButton()
    let sampleGroupPresetButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let addSampleFieldButton = NSButton()
    let sampleGroupsButton = NSButton()
    let countLabel = NSTextField(labelWithString: "")
    let headerBar = NSView()
    let searchBar = NSView()
    let searchHintLabel = NSTextField(labelWithString: "")
    let chipBar = NSView()
    let chipSummaryLabel = NSTextField(labelWithString: "")
    let chipScrollView = NSScrollView()
    let chipStackView = NSStackView()
    let dragHandle = DrawerDividerView()
    let tabControl = NSSegmentedControl()
    let loadingIndicator = NSProgressIndicator()
    let tooManyLabel = NSTextField(wrappingLabelWithString: "")
    let allTypesButton = NSButton()
    let noneTypesButton = NSButton()
    let annotationViewportFilterButton = NSButton()
    let annotationTracksButton = NSButton()
    let presetFiltersToggleButton = NSButton()
    let searchBuilderButton = NSButton()
    let localVariantFilterBadgeLabel = NSTextField(labelWithString: "Local: Visible Rows")
    let clearFilterButton = NSButton()
    let downloadTemplateButton = NSButton()
    let importMetadataButton = NSButton()
    let exportButton = NSButton()
    let autoSizeColumnsButton = NSButton()
    let columnConfigButton = NSButton()
    let profileButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let variantSubtabControl = NSSegmentedControl()
    let scopeControl = NSSegmentedControl()
    let haploidModeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let queryProgressBar = NSProgressIndicator()
    let queryProgressLabel = NSTextField(labelWithString: "")

    /// Maximum number of annotations to display in the table.
    /// Beyond this, user must filter to narrow down results.
    static var maxDisplayCount: Int { AppSettings.shared.maxTableDisplayCount }
    /// Maximum rows sampled when estimating content width for auto-size.
    static let autoSizeRowSampleLimit: Int = 500
    /// Above this visible-row count, per-row fallback consequence inference is deferred.
    static let consequenceComputationRowLimit: Int = 4_000
    static let deferredConsequenceText = "Too many variants to compute (zoom in)"
    static let deferredAAChangeText = "Zoom in to compute"
    static let annotationQueryDebounceInterval: TimeInterval = 0.16
    static let variantQueryDebounceInterval: TimeInterval = 0.12

    enum SampleSmartToken: String, CaseIterable {
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

    struct VariantQueryCacheKey: Equatable {
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
        let smartFilter: [String]
        let selectedSamples: [String]
    }

    /// Chip buttons keyed by type name.
    var chipButtons: [String: NSButton] = [:]
    /// Chip buttons keyed by `INFO_KEY\tINFO_VALUE` for variant preset filters.
    var variantPresetChipButtons: [String: NSButton] = [:]
    /// Payload lookup for preset chip buttons (button identity -> key/value).
    var variantPresetChipPayloads: [ObjectIdentifier: (key: String, value: String)] = [:]
    /// Payload lookup for "More..." preset buttons (button identity -> INFO key).
    var variantPresetMorePayloads: [ObjectIdentifier: String] = [:]
    /// Active smart filter tokens for the variant tab.
    var activeSmartTokens: Set<SmartToken> = []
    /// Smart token raw values that are materialized and ready across all variant tracks.
    var materializedTokenNamesAcrossTracks: Set<String> = []
    /// Smart token chip buttons keyed by token case.
    var smartTokenButtons: [SmartToken: NSButton] = [:]
    /// Reverse lookup: button identity -> SmartToken.
    var smartTokenPayloads: [ObjectIdentifier: SmartToken] = [:]
    /// Smart token chip buttons keyed by sample token case.
    var sampleTokenButtons: [SampleSmartToken: NSButton] = [:]
    /// Reverse lookup: button identity -> SampleSmartToken.
    var sampleTokenPayloads: [ObjectIdentifier: SampleSmartToken] = [:]
    /// Bookmarked variant keys (`trackId:variantRowId`) for star column display.
    var bookmarkedVariantKeys: Set<String> = []
    /// Base annotation result set before local column filters.
    var baseDisplayedAnnotationRows: [AnnotationSearchIndex.SearchResult] = []
    /// Header-driven filters applied to annotation rows.
    var annotationColumnFilterClauses: [ColumnFilterClause] = []
    /// Base result set from the last variant SQL query before local column filters.
    var baseDisplayedVariantAnnotations: [AnnotationSearchIndex.SearchResult] = []
    /// Header-driven local filters applied only to currently loaded variant rows.
    var variantColumnFilterClauses: [VariantColumnFilterClause] = []
    /// Header-driven local filters applied only to currently loaded genotype rows.
    var genotypeColumnFilterClauses: [VariantColumnFilterClause] = []
    /// Cache for delegate-provided fallback consequence/AA strings per variant row key.
    var fallbackConsequenceCache: [String: (consequence: String?, aaChange: String?)] = [:]
    /// Last local variant key set emitted to the viewer for viewport render syncing.
    var lastEmittedVisibleVariantRenderKeys: Set<String>?
    /// Last local annotation key set emitted to the viewer for viewport render syncing.
    var lastEmittedVisibleAnnotationRenderKeys: Set<String>?
    /// Column configuration popover (gear menu).
    var columnConfigPopover: NSPopover?

    // Annotation column identifiers (internal for extension access)
    static let nameColumn = NSUserInterfaceItemIdentifier("NameColumn")
    static let trackIdColumn = NSUserInterfaceItemIdentifier("TrackIdColumn")
    static let trackNameColumn = NSUserInterfaceItemIdentifier("TrackNameColumn")
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

    func setupView() {
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
        tabControl.segmentStyle = .rounded
        tabControl.controlSize = .small
        tabControl.font = .systemFont(ofSize: 10, weight: .medium)
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.setAccessibilityLabel("Switch between annotations, variants, and samples")
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

        annotationDrawerLogger.info("AnnotationTableDrawerView: Setup complete")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]? = nil) -> [AnyHashable: Any]? {
        guard let windowStateScope else { return userInfo }
        var scopedUserInfo = userInfo ?? [:]
        scopedUserInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        return scopedUserInfo
    }

    func shouldAcceptScopedNotification(_ notification: Notification) -> Bool {
        guard let notificationScope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope else {
            return true
        }
        guard let windowStateScope else { return true }
        return notificationScope == windowStateScope
    }

    private func canWriteVariantDatabaseOutputs(workflowName: String) -> Bool {
        let projectURL = searchIndex?.variantDatabaseHandles
            .compactMap { ProjectTempDirectory.findProjectRoot($0.db.databaseURL) }
            .first
        return AppDelegate.shared?.canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: windowStateScope,
            workflowName: workflowName,
            presentingWindow: window
        ) ?? true
    }

    private func variantDatabaseBundleURL(from searchIndex: AnnotationSearchIndex) -> URL? {
        searchIndex.variantDatabaseHandles
            .compactMap { Self.enclosingLungfishBundleURL(for: $0.db.databaseURL) }
            .first
    }

    private nonisolated static func enclosingLungfishBundleURL(for url: URL) -> URL? {
        var candidate = url.standardizedFileURL.deletingLastPathComponent()
        while candidate.path != "/" {
            if ProvenanceWriter.isBundleDirectory(candidate) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { break }
            candidate = parent
        }
        return nil
    }

    // MARK: - Variant Selection Sync

    /// Handles `.variantSelected` notification from the viewer to sync the drawer's selection.
    @objc func handleVariantSelected(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
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
    @objc func handleViewportVariantsUpdated(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
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
    @objc func handleViewerCoordinatesChanged(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
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

    func handleCoordinateSyncFromViewer() {
        viewportSyncWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.updateDisplayedAnnotations()
        }
        viewportSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    func markVariantFilterStateMutated() {
        allowViewportPostFilterDuringExploration = false
        viewportRegionAtLastFilterMutation = viewportRegion
    }

    func shouldArmViewportExploration(for newRegion: (chromosome: String, start: Int, end: Int)) -> Bool {
        guard let baseline = viewportRegionAtLastFilterMutation else { return true }
        return baseline.chromosome.caseInsensitiveCompare(newRegion.chromosome) != .orderedSame
            || baseline.start != newRegion.start
            || baseline.end != newRegion.end
    }

    /// Saved user query presets for the current drawer session. Bundle-level
    /// persistence should be added here before callers treat presets as durable.
    var savedQueryPresets: [QueryPreset] = []

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

    /// Selects and scrolls to the row that represents a viewport annotation.
    @discardableResult
    func selectAnnotation(matching annotation: SequenceAnnotation) -> Bool {
        if activeTab != .annotations {
            switchToTab(.annotations)
        }
        guard let index = displayedAnnotations.firstIndex(where: { Self.matches(annotation: annotation, result: $0) }) else {
            return false
        }
        isSuppressingDelegateCallbacks = true
        defer { isSuppressingDelegateCallbacks = false }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        return true
    }

    func clearAnnotationSelection() {
        guard activeTab == .annotations else { return }
        isSuppressingDelegateCallbacks = true
        defer { isSuppressingDelegateCallbacks = false }
        tableView.deselectAll(nil)
    }

    static func matches(annotation: SequenceAnnotation, result: AnnotationSearchIndex.SearchResult) -> Bool {
        guard annotation.name == result.name,
              annotation.start == result.start,
              annotation.end == result.end,
              chromosomeMatches(annotation.chromosome, result.chromosome),
              annotationTypeMatches(annotation.type, result.type) else {
            return false
        }
        if let trackID = annotation.qualifier("annotation_db_track_id") ?? annotation.qualifier("variant_track_id"),
           !trackID.isEmpty {
            return trackID == result.trackId
        }
        return true
    }

    static func annotationTypeMatches(_ annotationType: AnnotationType, _ resultType: String) -> Bool {
        if annotationType.rawValue.caseInsensitiveCompare(resultType) == .orderedSame {
            return true
        }
        return AnnotationType.from(rawString: resultType) == annotationType
    }

    static func chromosomeMatches(_ annotationChromosome: String?, _ resultChromosome: String) -> Bool {
        guard let annotationChromosome, !annotationChromosome.isEmpty else {
            return true
        }
        if annotationChromosome == resultChromosome {
            return true
        }
        return canonicalChromosomeToken(annotationChromosome) == canonicalChromosomeToken(resultChromosome)
    }

    static func canonicalChromosomeToken(_ value: String) -> String {
        let lowered = value.lowercased()
        guard let dotIndex = lowered.firstIndex(of: ".") else {
            return lowered
        }
        return String(lowered[..<dotIndex])
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

    @objc func copyTranslationAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        guard let translation = lookupTranslation(for: annotation) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(translation, forType: .string)
        annotationDrawerLogger.info("AnnotationTableDrawerView: Copied translation for '\(annotation.name, privacy: .public)' (\(translation.count) amino acids)")
    }

    @objc func copyNameAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(annotation.name, forType: .string)
    }

    @objc func copyCoordinatesAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        // Variants use 1-based coordinates (VCF convention); annotations use 0-based (BED convention)
        let start = activeTab == .variants ? annotation.start + 1 : annotation.start
        let coords = "\(annotation.chromosome):\(start)-\(annotation.end)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(coords, forType: .string)
    }

    // MARK: - Extraction Actions

    func makeAnnotation(from result: AnnotationSearchIndex.SearchResult) -> SequenceAnnotation {
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

    func selectedAnnotationResults(fallback result: AnnotationSearchIndex.SearchResult? = nil) -> [AnnotationSearchIndex.SearchResult] {
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

    func selectedSequenceAnnotations(fallback result: AnnotationSearchIndex.SearchResult? = nil) -> [SequenceAnnotation] {
        selectedAnnotationResults(fallback: result).map(makeAnnotation(from:))
    }

    @objc func copyAsFASTAAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationAsFASTARequested,
            object: nil,
            userInfo: windowScopedUserInfo(["annotation": annotation])
        )
    }

    @objc func copyTranslationAsFASTAAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyTranslationAsFASTARequested,
            object: nil,
            userInfo: windowScopedUserInfo(["annotation": annotation])
        )
    }

    @objc func extractSequenceAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotations = selectedSequenceAnnotations(fallback: result)
        guard !annotations.isEmpty else { return }
        delegate?.annotationDrawer(self, didRequestExtract: annotations)
    }

    @objc func addAnnotationAction(_ sender: NSMenuItem) {
        let form = makeAnnotationCreateAccessoryView(defaultRegion: defaultAnnotationCreationRegion())
        let alert = NSAlert()
        alert.messageText = "Add Annotation"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = form.view

        guard let window = self.window else {
            NSSound.beep()
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            guard self?.performAnnotationCreation(
                name: form.nameField.stringValue,
                type: form.typeField.stringValue,
                chromosome: form.chromosomeField.stringValue,
                startValue: form.startField.stringValue,
                endValue: form.endField.stringValue,
                strand: form.strandField.stringValue,
                attributes: form.attributesField.stringValue
            ) == true else {
                NSSound.beep()
                return
            }
        }
    }

    @objc func editAnnotationAction(_ sender: NSMenuItem) {
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

        guard let window = self.window else {
            NSSound.beep()
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performAnnotationEdit(result: result, rowID: rowID, form: form)
        }
    }

    func performAnnotationEdit(
        result: AnnotationSearchIndex.SearchResult,
        rowID: Int64,
        form: AnnotationEditForm
    ) {
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
        guard let searchIndex else {
            NSSound.beep()
            return
        }
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

    func makeAnnotationEditForm(
        for result: AnnotationSearchIndex.SearchResult,
        currentRecord: AnnotationDatabaseRecord?
    ) -> AnnotationEditForm {
        makeAnnotationForm(
            for: result,
            currentRecord: currentRecord,
            subtitle: "Update the annotation fields stored in this bundle."
        )
    }

    func makeAnnotationForm(
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

    func defaultAnnotationCreationRegion() -> AnnotationTableDrawerSelectionRegion? {
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
    func performAnnotationCreation(
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

    @objc func deleteSelectedAnnotationsAction(_ sender: NSMenuItem) {
        let fallback = sender.representedObject as? AnnotationSearchIndex.SearchResult
        let selected = selectedAnnotationResults(fallback: fallback)
        guard !selected.isEmpty else { return }
        delegate?.annotationDrawer(self, didRequestDeleteAnnotations: selected)
    }

    @objc func selectRelatedGeneFeaturesAction(_ sender: NSMenuItem) {
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

    func relatedGeneFeatures(for result: AnnotationSearchIndex.SearchResult) -> [AnnotationSearchIndex.SearchResult] {
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

    @objc func copySequenceAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationSequenceRequested,
            object: nil,
            userInfo: windowScopedUserInfo(["annotation": annotation])
        )
    }

    @objc func copyReverseComplementAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .copyAnnotationReverseComplementRequested,
            object: nil,
            userInfo: windowScopedUserInfo(["annotation": annotation])
        )
    }

    @objc func zoomToAnnotationAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let annotation = makeAnnotation(from: result)
        NotificationCenter.default.post(
            name: .zoomToAnnotationRequested,
            object: nil,
            userInfo: windowScopedUserInfo(["annotation": annotation])
        )
    }

    @objc func showInInspectorAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        if result.isVariant {
            NotificationCenter.default.post(
                name: .variantSelected,
                object: self,
                userInfo: windowScopedUserInfo([NotificationUserInfoKey.searchResult: result])
            )
        } else {
            let annotation = makeAnnotation(from: result)
            NotificationCenter.default.post(
                name: .annotationSelected,
                object: nil,
                userInfo: windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }
        // Then show inspector
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.inspectorTab: "selection"])
        )
    }

    // MARK: - Variant Context Menu Actions

    @objc func copyRefAltAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let refAlt = "\(result.ref ?? "") > \(result.alt ?? "")"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(refAlt, forType: .string)
    }

    @objc func copyAsVCFLineAction(_ sender: NSMenuItem) {
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

    @objc func filterToTypeAction(_ sender: NSMenuItem) {
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

    static func supportsTranslationMenu(for type: String) -> Bool {
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

    func buildAnnotationGlobalContextMenu(_ menu: NSMenu) {
        let addItem = NSMenuItem(title: "Add Annotation\u{2026}", action: #selector(addAnnotationAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = searchIndex?.hasDatabaseBackend ?? true
        menu.addItem(addItem)
    }

    func buildAnnotationContextMenu(_ menu: NSMenu, annotation: AnnotationSearchIndex.SearchResult) {
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

        let editableAnnotations = selectedAnnotations.filter { $0.annotationRowId != nil }
        let editableTrackIDs = Set(editableAnnotations.map(\.trackId))
        let deleteCount = editableAnnotations.count
        let deleteTitle = deleteCount > 1 ? "Delete \(deleteCount) Selected Annotations\u{2026}" : "Delete Annotation\u{2026}"
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(deleteSelectedAnnotationsAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = annotation
        deleteItem.isEnabled = allowsAnnotationEditing && deleteCount > 0 && editableTrackIDs.count == 1
        if deleteCount == 0 {
            deleteItem.toolTip = "Only SQLite-backed annotation rows can be deleted."
        } else if editableTrackIDs.count > 1 {
            deleteItem.toolTip = "Delete annotations from one annotation track at a time."
        }
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

    func buildVariantContextMenu(_ menu: NSMenu, annotation: AnnotationSearchIndex.SearchResult) {
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

    func annotationFilterKey(forColumnIdentifier columnId: String) -> String? {
        switch columnId {
        case Self.nameColumn.rawValue: return "name"
        case Self.trackIdColumn.rawValue: return "track_id"
        case Self.trackNameColumn.rawValue: return "track_name"
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

    func addAnnotationColumnFilterItem(
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

    @objc func applyAnnotationColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        annotationColumnFilterClauses.append(ColumnFilterClause(key: key, op: op, value: value))
        refreshAnnotationColumnFilters()
    }

    @objc func promptAnnotationColumnFilterAction(_ sender: NSMenuItem) {
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

    @objc func clearAnnotationColumnFilters(_ sender: Any?) {
        annotationColumnFilterClauses.removeAll()
        refreshAnnotationColumnFilters()
    }

    func refreshAnnotationColumnFilters() {
        if activeTab == .annotations, searchIndex?.hasDatabaseBackend == true {
            updateDisplayedAnnotations()
        } else {
            applyAnnotationColumnFiltersFromBase()
        }
    }

    func buildAnnotationColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
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

    func variantFilterKey(forColumnIdentifier columnId: String) -> String? {
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

    func isVariantFilterNumericKey(_ key: String) -> Bool {
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

    func addVariantColumnFilterItem(
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

    @objc func applyVariantColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        variantColumnFilterClauses.append(VariantColumnFilterClause(key: key, op: op, value: value))
        applyVariantColumnFiltersFromBase()
    }

    @objc func promptVariantColumnFilterAction(_ sender: NSMenuItem) {
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

    @objc func clearVariantColumnFilters(_ sender: Any?) {
        variantColumnFilterClauses.removeAll()
        applyVariantColumnFiltersFromBase()
    }

    func buildVariantColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
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

    /// The operation center owns bundle exclusion until the synchronous durable
    /// worker has committed or rolled back. Only immutable inputs enter the worker.
    @discardableResult
    func runVariantStorageMutation<Value: Sendable>(
        title: String, bundleURL: URL, center: OperationCenter = .shared,
        work: @escaping @Sendable () throws -> Value,
        publish: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never>? {
        guard let source = searchIndex else { return nil }
        let owner = window?.windowController as? MainWindowController
        let session = owner?.projectSession
        let generation = session?.documentGeneration
        let sourceWindow = window
        let scope = windowStateScope
        let route = OperationRouteContext(
            projectURL: session?.projectURL ?? owner?.mainSplitViewController?.sidebarController?.currentProjectURL
                ?? ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: scope)
        let operationID = center.start(title: title, detail: "Updating stored data and provenance", operationType: .workflow,
            targetBundleURL: bundleURL, routeContext: route)
        guard center.items.first(where: { $0.id == operationID })?.state == .running else { return nil }
        variantStorageOperationID = operationID
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.variantStorageOperationID == operationID {
                    self?.variantStorageOperationID = nil
                    self?.variantStorageMutationTask = nil
                }
            }
            do {
                let result = try await Task.detached(priority: .userInitiated, operation: work).value
                center.complete(id: operationID, detail: "Data and provenance updated")
                guard let self, self.searchIndex === source, self.window === sourceWindow,
                      self.windowStateScope == scope, session?.documentGeneration == generation else { return }
                publish(result)
            } catch {
                center.fail(id: operationID, detail: "Stored data update failed", errorMessage: error.localizedDescription)
                annotationDrawerLogger.error("Stored data update failed: \(error.localizedDescription)")
            }
        }
        variantStorageMutationTask = task
        return task
    }

    // MARK: - Delete Actions

    @objc private func deleteSelectedVariantsAction(_ sender: NSMenuItem) {
        guard let source = searchIndex else { return }
        let selectedRows = tableView.selectedRowIndexes
        let selectedVariants = selectedRows.compactMap { idx -> AnnotationSearchIndex.SearchResult? in
            guard idx < displayedAnnotations.count else { return nil }
            return displayedAnnotations[idx]
        }
        let scopedIDs = variantIDsByTrack(from: selectedVariants)
        let count = scopedIDs.values.reduce(0) { $0 + $1.count }
        guard count > 0 else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Variant deletion") else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \(count) Variant\(count == 1 ? "" : "s")?"
        alert.informativeText = "This will permanently remove the selected variant\(count == 1 ? "" : "s") from the database."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()
        alert.alertStyle = .warning

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.searchIndex === source else { return }
            self.performVariantDeletion(scopedIDs)
        }
    }

    @objc private func deleteAllVariantsAction(_ sender: NSMenuItem) {
        guard let source = searchIndex else { return }
        let count = totalVariantCount
        guard canWriteVariantDatabaseOutputs(workflowName: "Variant deletion") else { return }
        let alert = NSAlert()
        alert.messageText = "Delete All \(count) Variants?"
        alert.informativeText = "This will permanently remove all variants from the database. This cannot be undone."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()
        alert.alertStyle = .critical

        guard let window = window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.searchIndex === source else { return }
            self.performDeleteAllVariants()
        }
    }

    private func performVariantDeletion(_ idsByTrack: [String: [Int64]]) {
        guard let searchIndex else { return }
        guard !idsByTrack.isEmpty else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Variant deletion") else { return }
        guard let bundleURL = variantDatabaseBundleURL(from: searchIndex) else {
            annotationDrawerLogger.error("performVariantDeletion: Could not resolve enclosing variant bundle for provenance")
            return
        }

        let targets = searchIndex.variantDatabaseHandles.map {
            VariantDeletionMutationTarget(
                trackId: $0.trackId,
                databaseURL: $0.db.databaseURL,
                trackName: searchIndex.variantTrackName(for: $0.trackId)
            )
        }
        runVariantStorageMutation(title: "Variant deletion", bundleURL: bundleURL, work: {
            try VariantDeletionMutationService().deleteVariants(idsByTrack: idsByTrack, bundleURL: bundleURL, targets: targets)
        }, publish: { [weak self] result in
            guard let self, result.totalDeleted > 0 else { return }
            self.totalVariantCount = max(0, self.totalVariantCount - result.totalDeleted)
            self.updateDisplayedAnnotations()
            self.updateCountLabel()
            self.delegate?.annotationDrawer(self, didDeleteVariants: result.totalDeleted)
        })
    }

    private func performDeleteAllVariants() {
        guard let searchIndex else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Variant deletion") else { return }
        guard let bundleURL = variantDatabaseBundleURL(from: searchIndex) else {
            annotationDrawerLogger.error("performDeleteAllVariants: Could not resolve enclosing variant bundle for provenance")
            return
        }

        let targets = searchIndex.variantDatabaseHandles.map {
            VariantDeletionMutationTarget(
                trackId: $0.trackId,
                databaseURL: $0.db.databaseURL,
                trackName: searchIndex.variantTrackName(for: $0.trackId)
            )
        }
        runVariantStorageMutation(title: "Delete all variants", bundleURL: bundleURL, work: {
            try VariantDeletionMutationService().deleteAllVariants(bundleURL: bundleURL, targets: targets)
        }, publish: { [weak self] result in
            guard let self, result.totalDeleted > 0 else { return }
            self.totalVariantCount = 0
            self.updateDisplayedAnnotations()
            self.updateCountLabel()
            self.delegate?.annotationDrawer(self, didDeleteVariants: result.totalDeleted)
        })
    }

    /// Groups selected variant row IDs by their owning track ID.
    func variantIDsByTrack(from variants: [AnnotationSearchIndex.SearchResult]) -> [String: [Int64]] {
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
    func updateAnnotationSearchRegion() {
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

    @objc func showOverlappingVariantsAction(_ sender: NSMenuItem) {
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

    func sampleRowKey(name: String, sourceFile: String) -> String {
        "\(name)|\(sourceFile)"
    }

    nonisolated static func sourceFileMatches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// Populates sample data from all variant database handles in the search index.
    func populateSampleData(from index: AnnotationSearchIndex) {
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
    func updateDisplayedSamples() {
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

    func syncSampleFilterVisibilityToViewer(query: SampleFilterQuery) {
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

    func annotationColumnValue(_ row: AnnotationSearchIndex.SearchResult, key: String) -> String {
        switch key {
        case "name":
            return row.name
        case "track_id":
            return row.trackId
        case "track_name":
            return annotationTrackName(for: row)
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

    func isAnnotationFilterNumericKey(_ key: String) -> Bool {
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

    func annotationTrackName(for row: AnnotationSearchIndex.SearchResult) -> String {
        row.trackName ?? annotationTrackDisplayNames[row.trackId] ?? row.trackId
    }

    func annotationColumnMatches(actual: String, op: String, expected: String, key: String) -> Bool {
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

    func applyAnnotationColumnFilters(to rows: [AnnotationSearchIndex.SearchResult]) -> [AnnotationSearchIndex.SearchResult] {
        applyAnnotationColumnFilters(to: rows, clauses: annotationColumnFilterClauses)
    }

    func setAnnotationBaseResults(_ rows: [AnnotationSearchIndex.SearchResult]) {
        baseDisplayedAnnotationRows = rows
        displayedAnnotations = applyAnnotationColumnFilters(to: rows)
        for row in rows {
            if let trackName = row.trackName, !trackName.isEmpty {
                annotationTrackDisplayNames[row.trackId] = trackName
            }
        }
        let availableTrackIDs = searchIndex?.annotationDatabaseHandles.map(\.trackId) ?? []
        syncAnnotationTracks(from: availableTrackIDs.isEmpty ? rows.map(\.trackId) : availableTrackIDs)
    }

    func applyAnnotationColumnFiltersFromBase() {
        displayedAnnotations = applyAnnotationColumnFilters(to: baseDisplayedAnnotationRows)
        tableView.reloadData()
        scrollView.isHidden = false
        tooManyLabel.isHidden = true
        updateAnnotationSearchRegion()
        updateCountLabel()
    }

    func variantColumnValue(_ row: AnnotationSearchIndex.SearchResult, key: String) -> String {
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

    func variantColumnMatches(actual: String, op: String, expected: String, key: String) -> Bool {
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

    func setVariantBaseResults(_ rows: [AnnotationSearchIndex.SearchResult]) {
        baseDisplayedVariantAnnotations = rows
        fallbackConsequenceCache = [:]
        displayedAnnotations = applyVariantColumnFilters(to: rows)
    }

    func applyVariantColumnFiltersFromBase() {
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
    func resolvedSampleOrder() -> [String] {
        guard let order = currentSampleDisplayState.sampleOrder else { return allSampleRowKeys }
        let allSet = Set(allSampleRowKeys)
        var ordered = order.filter { allSet.contains($0) }
        let orderedSet = Set(ordered)
        ordered.append(contentsOf: allSampleRowKeys.filter { !orderedSet.contains($0) })
        return ordered
    }

    /// Sorts sample row keys by samples-tab column key.
    func sortedSampleNames(key: String, ascending: Bool, names: [String]) -> [String] {
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
    func sampleCellView(for identifier: NSUserInterfaceItemIdentifier, row: Int) -> NSView? {
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

    @objc func sampleVisibilityToggled(_ sender: NSButton) {
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

    func postSampleDisplayStateChange() {
        hasSampleDisplayStateSeed = true
        NotificationCenter.default.post(
            name: .sampleDisplayStateChanged,
            object: self,
            userInfo: windowScopedUserInfo([NotificationUserInfoKey.sampleDisplayState: currentSampleDisplayState])
        )
    }

    @objc func handleSampleDisplayStateChanged(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
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

    @objc func variantColorThemeDidChange(_ note: Notification) {
        if activeTab == .variants { tableView.reloadData() }
    }

    // MARK: - Variant Query Progress

    func invalidateInFlightVariantQueries() {
        variantQueryWorkItem?.cancel()
        variantQueryWorkItem = nil
        activeVariantQueryCancelToken?.cancel()
        activeVariantQueryCancelToken = nil
        variantQueryGeneration += 1
    }

    func showVariantQueryProgress(_ message: String) {
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

    func hideVariantQueryProgress() {
        isVariantQuerying = false
        queryProgressLabel.isHidden = true
        queryProgressBar.isHidden = true
        queryProgressBar.stopAnimation(nil)
    }

    // MARK: - Sample Context Menu Actions

    @objc func showAllSamplesAction(_ sender: NSMenuItem) {
        currentSampleDisplayState.hiddenSamples.removeAll()
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func hideAllSamplesAction(_ sender: NSMenuItem) {
        currentSampleDisplayState.hiddenSamples = Set(allSampleNames)
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func toggleSampleVisibilityAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if currentSampleDisplayState.hiddenSamples.contains(name) {
            currentSampleDisplayState.hiddenSamples.remove(name)
        } else {
            currentSampleDisplayState.hiddenSamples.insert(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func copySampleNameAction(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(name, forType: .string)
    }

    func buildSampleContextMenu(_ menu: NSMenu, row: Int, clickedColumn: Int) {
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

    func sampleFilterKey(forColumnIdentifier columnId: String) -> String? {
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

    func sampleFilterValue(sample: SampleDisplayRow, columnIdentifier columnId: String) -> String {
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

    func addSampleColumnFilterItem(
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

    @objc func applySampleColumnFilterAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let key = payload["key"],
              let op = payload["op"],
              let value = payload["value"] else { return }
        let clause = value.isEmpty ? "\(key)\(op)" : "\(key)\(op)\(value)"
        let current = sampleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        sampleFilterText = current.isEmpty ? clause : "\(current); \(clause)"
        updateDisplayedSamples()
    }

    @objc func promptSampleColumnFilterAction(_ sender: NSMenuItem) {
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

    func buildSampleGlobalContextMenu(_ menu: NSMenu) {
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

    func buildSampleColumnHeaderContextMenu(_ menu: NSMenu, column: Int) {
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

    @objc func hideSelectedSamplesAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        for row in selectedRows {
            guard row < displayedSamples.count else { continue }
            let name = displayedSamples[row].name
            currentSampleDisplayState.hiddenSamples.insert(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func showSelectedSamplesAction(_ sender: NSMenuItem) {
        let selectedRows = tableView.selectedRowIndexes
        for row in selectedRows {
            guard row < displayedSamples.count else { continue }
            let name = displayedSamples[row].name
            currentSampleDisplayState.hiddenSamples.remove(name)
        }
        postSampleDisplayStateChange()
        updateDisplayedSamples()
    }

    @objc func showOnlySelectedSamplesAction(_ sender: NSMenuItem) {
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

    @objc func createSampleGroupFromShownResults(_ sender: NSMenuItem) {
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

    func showSampleColumnHeaderFilterMenu(column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        guard let headerView = tableView.headerView else { return }
        let menu = NSMenu()
        buildSampleColumnHeaderContextMenu(menu, column: column)
        let rect = headerView.headerRect(ofColumn: column)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    func showAnnotationColumnHeaderFilterMenu(column: Int) {
        guard column >= 0, column < tableView.tableColumns.count else { return }
        guard let headerView = tableView.headerView else { return }
        let menu = NSMenu()
        buildAnnotationColumnHeaderContextMenu(menu, column: column)
        let rect = headerView.headerRect(ofColumn: column)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    func showVariantColumnHeaderFilterMenu(column: Int) {
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
        guard canWriteVariantDatabaseOutputs(workflowName: "Sample metadata column deletion") else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Metadata Column?"
        alert.informativeText = "Delete '\(fieldName)' from all samples and variant databases? This cannot be undone."
        alert.addButton(withTitle: "Delete Column")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            guard self.canWriteVariantDatabaseOutputs(workflowName: "Sample metadata column deletion") else { return }
            guard let searchIndex = self.searchIndex else { return }

            let fieldToRemove = fieldName
            let sampleRows = self.allSampleRowKeys.compactMap { rowKey -> (name: String, sourceFile: String, metadata: [String: String])? in
                guard let sampleName = self.sampleNameByRowKey[rowKey] else { return nil }
                return (sampleName, self.sampleSourceFiles[rowKey] ?? "", self.sampleMetadata[rowKey] ?? [:])
            }
            guard let bundleURL = self.variantDatabaseBundleURL(from: searchIndex) else {
                annotationDrawerLogger.warning("deleteSampleMetadataFieldAction: Could not resolve enclosing bundle for variant databases")
                return
            }
            let targets = searchIndex.variantDatabaseHandles.map {
                VariantSampleMetadataImportTarget(databaseURL: $0.db.databaseURL, trackName: $0.trackId)
            }
            let mutationRows = sampleRows.map {
                VariantSampleMetadataMutationRow(name: $0.name, sourceFile: $0.sourceFile, metadata: $0.metadata)
            }

            DispatchQueue.global(qos: .userInitiated).async {
                var firstError: Error?
                do {
                    _ = try VariantSampleMetadataMutationService().deleteMetadataField(
                        fieldName: fieldToRemove,
                        sampleRows: mutationRows,
                        bundleURL: bundleURL,
                        targets: targets
                    )
                } catch {
                    firstError = error
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
                        annotationDrawerLogger.info("deleteSampleMetadataFieldAction: Removed metadata field '\(fieldToRemove, privacy: .public)'")
                    }
                }
            }
        }
    }

    // MARK: - Import Metadata

    @objc func downloadSampleTemplateAction(_ sender: Any?) {
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

        let panel = ViewerFilePanelFactory.sampleMetadataTemplatePanel(
            suggestedName: "\(defaultTemplateStem).tsv"
        )

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
                annotationDrawerLogger.error("downloadSampleTemplateAction: \(error.localizedDescription)")
            }
        }
    }

    @objc private func importMetadataAction(_ sender: Any?) {
        guard let searchIndex else { return }
        guard canWriteVariantDatabaseOutputs(workflowName: "Sample metadata import") else { return }
        let panel = ViewerFilePanelFactory.variantSampleMetadataImportPanel()

        guard let window = self.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let fileURL = panel.url, self.searchIndex === searchIndex else { return }
            guard self.canWriteVariantDatabaseOutputs(workflowName: "Sample metadata import") else { return }
            let ext = fileURL.pathExtension.lowercased()
            let format: MetadataFormat = ext == "csv" ? .csv : .tsv

            guard let bundleURL = self.variantDatabaseBundleURL(from: searchIndex) else {
                annotationDrawerLogger.warning("importSampleMetadata: Could not resolve enclosing bundle for variant databases")
                return
            }
            let targets = searchIndex.variantDatabaseHandles.map {
                VariantSampleMetadataImportTarget(databaseURL: $0.db.databaseURL, trackName: $0.trackId)
            }
            self.runVariantStorageMutation(title: "Sample metadata import", bundleURL: bundleURL, work: {
                try VariantSampleMetadataImportService().importMetadata(from: fileURL, format: format, bundleURL: bundleURL, targets: targets)
            }, publish: { [weak self] result in
                guard let self else { return }
                annotationDrawerLogger.info("importSampleMetadata: Updated \(result.totalUpdated) samples from \(fileURL.lastPathComponent)")
                self.populateSampleData(from: searchIndex)
                self.configureColumnsForTab(.samples)
                self.updateDisplayedSamples()
            })
        }
    }

    // MARK: - Sample Groups

    @objc func showSampleGroupsSheet(_ sender: Any?) {
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

    @objc func addCustomFieldAction(_ sender: Any) {
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
            guard canWriteVariantDatabaseOutputs(workflowName: "Sample display name edit") else {
                tableView.reloadData()
                return
            }
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
                        annotationDrawerLogger.warning("Display name edit failed: \(error.localizedDescription)")
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
        guard canWriteVariantDatabaseOutputs(workflowName: "Sample metadata edit") else {
            tableView.reloadData()
            return
        }

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

        guard let bundleURL = variantDatabaseBundleURL(from: searchIndex) else {
            annotationDrawerLogger.warning("Inline metadata edit failed: could not resolve enclosing bundle")
            return
        }
        do {
            let targets = searchIndex.variantDatabaseHandles.map {
                VariantSampleMetadataImportTarget(databaseURL: $0.db.databaseURL, trackName: $0.trackId)
            }
            _ = try VariantSampleMetadataMutationService().updateSampleMetadata(
                sampleName: sampleName,
                sourceFile: sampleSourceFile,
                metadata: fullMetadata,
                bundleURL: bundleURL,
                targets: targets
            )
        } catch {
            annotationDrawerLogger.warning("Inline metadata edit failed: \(error.localizedDescription)")
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

final class VariantQueryCancellationToken: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false

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

#if DEBUG
final class AnnotationScopeMetadataQueryGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func pause() {
        entered.signal()
        release.wait()
    }

    func waitUntilPaused(timeout: DispatchTime = .now() + 2) -> Bool {
        entered.wait(timeout: timeout) == .success
    }

    func resume() {
        release.signal()
    }
}
#endif

/// Snapshot of annotation database state needed for background annotation-table queries.
/// Stores database URLs, not live handles, so each background query uses its own
/// read-only SQLite connection instead of sharing the main actor's NOMUTEX handle.
struct AnnotationQueryContext: @unchecked Sendable {
    let databases: [(trackId: String, databaseURL: URL)]
    let trackNames: [String: String]
    let allowedChromosomes: Set<String>?

    init(
        databases: [(trackId: String, databaseURL: URL)],
        trackNames: [String: String],
        allowedChromosomes: Set<String>? = nil
    ) {
        self.databases = databases
        self.trackNames = trackNames
        self.allowedChromosomes = allowedChromosomes
    }

    func totalCount(shouldCancel: (() -> Bool)? = nil) -> Int {
        guard allowedChromosomes?.isEmpty != true else { return 0 }
        var count = 0
        for handle in databases {
            if shouldCancel?() == true { break }
            guard let database = try? AnnotationDatabase(url: handle.databaseURL) else { continue }
            count += database.totalCount(allowedChromosomes: allowedChromosomes)
        }
        return count
    }

    func allTypes(shouldCancel: (() -> Bool)? = nil) -> [String] {
        guard allowedChromosomes?.isEmpty != true else { return [] }
        var types = Set<String>()
        for handle in databases {
            if shouldCancel?() == true { break }
            guard let database = try? AnnotationDatabase(url: handle.databaseURL) else { continue }
            types.formUnion(database.allTypes(allowedChromosomes: allowedChromosomes))
        }
        return types.sorted()
    }

    func queryAnnotationsOnly(
        nameFilter: String = "",
        types: Set<String> = [],
        chromosome: String? = nil,
        regionStart: Int? = nil,
        regionEnd: Int? = nil,
        strand: String? = nil,
        columnFilters: [AnnotationDatabase.ColumnFilterClause] = [],
        limit: Int = 5000,
        shouldCancel: (() -> Bool)? = nil
    ) -> [AnnotationSearchIndex.SearchResult] {
        let databaseColumnFilters = columnFilters.filter { !Self.isTrackColumnFilter($0.key) }
        var results: [AnnotationSearchIndex.SearchResult] = []
        for handle in databases {
            if shouldCancel?() == true { break }
            guard Self.annotationTrackMatchesFilters(
                trackId: handle.trackId,
                trackName: trackNames[handle.trackId],
                filters: columnFilters
            ) else { continue }
            let remaining = limit - results.count
            guard remaining > 0 else { break }
            guard let database = try? AnnotationDatabase(url: handle.databaseURL) else {
                continue
            }
            if shouldCancel?() == true { break }
            let records = database.queryForTable(
                nameFilter: nameFilter,
                types: types,
                chromosome: chromosome,
                regionStart: regionStart,
                regionEnd: regionEnd,
                strand: strand,
                columnFilters: databaseColumnFilters,
                allowedChromosomes: allowedChromosomes,
                limit: remaining
            )
            if shouldCancel?() == true { break }
            results.append(contentsOf: records.map { record in
                Self.searchResult(from: record, trackId: handle.trackId, trackName: trackNames[handle.trackId])
            })
        }
        return results
    }

    private static func searchResult(
        from record: AnnotationDatabaseRecord,
        trackId: String,
        trackName: String?
    ) -> AnnotationSearchIndex.SearchResult {
        let parsedAttributes = record.attributes.map(AnnotationDatabase.parseAttributes).flatMap { attributes in
            attributes.isEmpty ? nil : attributes
        }
        return AnnotationSearchIndex.SearchResult(
            name: record.name,
            chromosome: record.chromosome,
            start: record.start,
            end: record.end,
            trackId: trackId,
            trackName: trackName,
            type: record.type,
            strand: record.strand,
            attributes: parsedAttributes,
            annotationRowId: record.rowID
        )
    }

    private static func isTrackColumnFilter(_ key: String) -> Bool {
        key == "track_id" || key == "track_name"
    }

    private static func annotationTrackMatchesFilters(
        trackId: String,
        trackName: String?,
        filters: [AnnotationDatabase.ColumnFilterClause]
    ) -> Bool {
        filters.allSatisfy { filter in
            switch filter.key {
            case "track_id":
                return trackColumnMatches(actual: trackId, op: filter.op, expected: filter.value)
            case "track_name":
                return trackColumnMatches(actual: trackName ?? trackId, op: filter.op, expected: filter.value)
            default:
                return true
            }
        }
    }

    private static func trackColumnMatches(actual: String, op: String, expected: String) -> Bool {
        let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        switch op {
        case "=":
            if normalizedExpected.isEmpty { return normalizedActual.isEmpty }
            return normalizedActual.caseInsensitiveCompare(normalizedExpected) == .orderedSame
        case "!=":
            if normalizedExpected.isEmpty { return !normalizedActual.isEmpty }
            return normalizedActual.caseInsensitiveCompare(normalizedExpected) != .orderedSame
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
}

/// Snapshot of variant database state needed for background queries.
/// All fields are `Sendable` (VariantDatabase/AnnotationDatabase are @unchecked Sendable).
struct AnnotationVariantQueryContext: @unchecked Sendable {
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
        smartFilter: VariantSmartFilter? = nil,
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
                    smartFilter: smartFilter,
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
        smartFilter: VariantSmartFilter? = nil,
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
                    infoFilters: infoFilters, sampleNames: sampleNames,
                    smartFilter: smartFilter
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
        smartFilter: VariantSmartFilter? = nil,
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
                smartFilter: smartFilter,
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
        smartFilter: VariantSmartFilter? = nil,
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
                    sampleNames: sampleNames,
                    smartFilter: smartFilter
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
        smartFilter: VariantSmartFilter? = nil,
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
                smartFilter: smartFilter,
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
                    smartFilter: smartFilter,
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

    func resolveGeneRegions(_ geneNames: [String]) -> [GeneRegion] {
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
func fetchVariantsAdaptive(
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

/// Annotation-table fetch loop for background database queries.
func fetchAnnotationRowsForDisplayOffMain(
    context: AnnotationQueryContext,
    nameFilter: String,
    typeFilter: Set<String>,
    query annotationQuery: AnnotationTableDrawerView.AnnotationFilterQuery,
    databaseColumnFilters: [AnnotationDatabase.ColumnFilterClause],
    allColumnFilters: [AnnotationTableDrawerView.ColumnFilterClause],
    requiresPostOnlyColumnFiltering: Bool,
    maxDisplayCount: Int,
    shouldCancel: (() -> Bool)? = nil
) -> [AnnotationSearchIndex.SearchResult] {
    let targetCount = maxDisplayCount + 1
    var fetchLimit = targetCount

    while true {
        if shouldCancel?() == true { return [] }
        let results = context.queryAnnotationsOnly(
            nameFilter: nameFilter,
            types: typeFilter,
            chromosome: annotationQuery.chromosome,
            regionStart: annotationQuery.start,
            regionEnd: annotationQuery.end,
            strand: annotationQuery.strand,
            columnFilters: databaseColumnFilters,
            limit: fetchLimit,
            shouldCancel: shouldCancel
        )
        if shouldCancel?() == true { return [] }
        let filtered = applyAnnotationColumnFiltersOffMain(
            to: applyAnnotationAdvancedFiltersOffMain(results, query: annotationQuery),
            clauses: allColumnFilters
        )
        if shouldCancel?() == true { return [] }

        if !requiresPostOnlyColumnFiltering
            || filtered.count >= targetCount
            || results.count < fetchLimit {
            return Array(filtered.prefix(targetCount))
        }

        fetchLimit = max(fetchLimit * 2, fetchLimit + targetCount)
    }
}

func applyAnnotationAdvancedFiltersOffMain(
    _ results: [AnnotationSearchIndex.SearchResult],
    query: AnnotationTableDrawerView.AnnotationFilterQuery
) -> [AnnotationSearchIndex.SearchResult] {
    results.filter { row in
        if let chr = query.chromosome, row.chromosome.caseInsensitiveCompare(chr) != .orderedSame { return false }
        if let strand = query.strand, row.strand.caseInsensitiveCompare(strand) != .orderedSame { return false }
        if let start = query.start, row.end <= start { return false }
        if let end = query.end, row.start >= end { return false }
        return true
    }
}

func applyAnnotationColumnFiltersOffMain(
    to rows: [AnnotationSearchIndex.SearchResult],
    clauses: [AnnotationTableDrawerView.ColumnFilterClause]
) -> [AnnotationSearchIndex.SearchResult] {
    guard !clauses.isEmpty else { return rows }
    return rows.filter { row in
        clauses.allSatisfy { clause in
            let actual = annotationColumnValueOffMain(row, key: clause.key)
            return annotationColumnMatchesOffMain(
                actual: actual,
                op: clause.op,
                expected: clause.value,
                key: clause.key
            )
        }
    }
}

func annotationColumnValueOffMain(_ row: AnnotationSearchIndex.SearchResult, key: String) -> String {
    switch key {
    case "name":
        return row.name
    case "track_id":
        return row.trackId
    case "track_name":
        return row.trackName ?? row.trackId
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

func annotationColumnMatchesOffMain(actual: String, op: String, expected: String, key: String) -> Bool {
    let normalizedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
    if isAnnotationFilterNumericKeyOffMain(key),
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
    return textColumnMatchesOffMain(actual: normalizedActual, op: op, expected: normalizedExpected)
}

func isAnnotationFilterNumericKeyOffMain(_ key: String) -> Bool {
    switch key {
    case "start", "end", "size":
        return true
    default:
        if key.hasPrefix("attr_") {
            let attributeKey = String(key.dropFirst(5))
            return isNumericAnnotationAttributeKeyOffMain(attributeKey)
        }
        return false
    }
}

func isNumericAnnotationAttributeKeyOffMain(_ key: String) -> Bool {
    switch key {
    case "flag", "mapq", "pos_1_based", "alignment_start", "alignment_end",
         "reference_length", "query_length", "mate_position_1_based", "template_length",
         "tag_NM", "tag_AS":
        return true
    default:
        return false
    }
}

func textColumnMatchesOffMain(actual: String, op: String, expected: String) -> Bool {
    switch op {
    case "=":
        if expected.isEmpty { return actual.isEmpty }
        return actual.caseInsensitiveCompare(expected) == .orderedSame
    case "!=":
        if expected.isEmpty { return !actual.isEmpty }
        return actual.caseInsensitiveCompare(expected) != .orderedSame
    case "~", ":":
        if expected.isEmpty { return true }
        return actual.localizedCaseInsensitiveContains(expected)
    case "!~":
        if expected.isEmpty { return true }
        return !actual.localizedCaseInsensitiveContains(expected)
    case "^=":
        if expected.isEmpty { return true }
        return actual.lowercased().hasPrefix(expected.lowercased())
    case "$=":
        if expected.isEmpty { return true }
        return actual.lowercased().hasSuffix(expected.lowercased())
    default:
        if expected.isEmpty { return true }
        return actual.localizedCaseInsensitiveContains(expected)
    }
}

/// Pure variant advanced filters (free function, safe to call from any thread).
func applyVariantAdvancedFiltersOffMain(
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
func filterModerateOrHigherImpactOffMain(
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
func filterByWithinSampleAFOffMain(
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
func filterVariantsToRegionOffMain(
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
