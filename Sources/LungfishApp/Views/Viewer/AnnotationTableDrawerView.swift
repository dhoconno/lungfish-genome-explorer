// AnnotationTableDrawerView.swift - Geneious-style bottom annotation drawer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os.log
import LungfishKit

/// Logger for annotation drawer operations
let annotationDrawerLogger = Logger(subsystem: LogSubsystem.app, category: "AnnotationDrawer")

// MARK: - WideColumnDividerHeaderView

/// Custom header view that expands the column-resize grab zone from ~3px to 8px each side.
///
/// It also serves the per-column Sort/Filter/Size menu on a context click
/// (right-click or Control-click) so a plain left click only sorts.
private final class WideColumnDividerHeaderView: NSTableHeaderView {
    let expandedHitZone: CGFloat = 8
    var columnMenuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let column = column(at: convert(event.locationInWindow, from: nil))
        if column >= 0, let menu = columnMenuProvider?(column) {
            return menu
        }
        return super.menu(for: event)
    }

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
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didHighlightVariant result: AnnotationSearchIndex.SearchResult)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didHighlightVariants entries: [VariantSelectionEntry])
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestExtract annotations: [SequenceAnnotation])
    func annotationDrawerSelectedSequenceRegion(_ drawer: AnnotationTableDrawerView) -> AnnotationTableDrawerSelectionRegion?
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didResolveGeneRegions regions: [GeneRegion])
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleVariantRenderKeys keys: Set<String>?)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleAnnotationRenderKeys keys: Set<String>?)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateAnnotationTrackDisplayState state: AnnotationTrackDisplayState)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestDeleteAnnotations annotations: [AnnotationSearchIndex.SearchResult])
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didRequestDeleteAnnotationTrack trackID: String, trackName: String)
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, codingFeatureFor result: AnnotationSearchIndex.SearchResult) -> String?
    func annotationDrawerAdditionalExportSources(_ drawer: AnnotationTableDrawerView) throws -> [URL]
    func annotationDrawerVariantExportResolverSnapshot(_ drawer: AnnotationTableDrawerView) -> VariantTableExportResolverSnapshot
    func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat)
    func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView)
    func annotationDrawer(
        _ drawer: AnnotationTableDrawerView,
        fallbackConsequenceFor result: AnnotationSearchIndex.SearchResult
    ) -> (consequence: String?, aaChange: String?)
}

extension AnnotationTableDrawerDelegate {
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didHighlightVariant result: AnnotationSearchIndex.SearchResult) {}
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didHighlightVariants entries: [VariantSelectionEntry]) {}

    func annotationDrawerAdditionalExportSources(_ drawer: AnnotationTableDrawerView) throws -> [URL] { [] }
    func annotationDrawerVariantExportResolverSnapshot(_ drawer: AnnotationTableDrawerView) -> VariantTableExportResolverSnapshot { .empty }
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, codingFeatureFor result: AnnotationSearchIndex.SearchResult) -> String? { nil }

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

    /// The pasteboard the copy commands write. Tests substitute a private one.
    var copyPasteboard: NSPasteboard = .general

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
        // The compact row (Region/Genome, ploidy, Calls/GT, Query, Presets,
        // All, None) needs about 575 pt; below that the minimal row fits.
        if width < 580 { return .minimal }
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

    /// A single row in the samples tab display (``AnnotationTableSampleRow``).
    typealias SampleDisplayRow = AnnotationTableSampleRow

    // MARK: - Properties

    weak var delegate: AnnotationTableDrawerDelegate?
    var windowStateScope: WindowStateScope?

    /// Reference to the search index for direct SQL queries.
    var searchIndex: AnnotationSearchIndex?
    var variantStorageMutationTask: Task<Void, Never>?
    var variantStorageOperationID: UUID?
    var appliedVariantToolbarDensity: VariantToolbarDensity?

    /// Whether the variant toolbar wants the Profiles pop-up at the current
    /// density. It is shown only when the row also leaves it enough room.
    var profileButtonWanted = false

    /// The narrowest Profiles pop-up that still reads as a control. Below
    /// this it is hidden rather than drawn squeezed over its neighbours.
    static let minimumProfileButtonWidth: CGFloat = 44

    /// Zero-width constraints that collapse hidden variant-toolbar controls.
    /// A hidden view keeps its constraints, so without these a hidden Clear
    /// or Haploid control still reserved its width and the row overflowed.
    var collapsedVariantToolbarWidths: [ObjectIdentifier: NSLayoutConstraint] = [:]

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
    #if DEBUG
    var debugGenotypeFetchBeforeApply: (@Sendable () -> Void)?
    #endif
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

    /// Bundle-owned track visibility, keyed only by stable track ID.
    var hiddenVariantTrackIDs: Set<String> = []

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
    /// Short, user-facing notes for every ``variantChromosomeAliasMap``
    /// entry the resolver could only make by contig length, e.g. "Matched VCF
    /// contig NC_045512.2 to MN908947.3 by length". Empty when every VCF
    /// contig was matched by name/alias/version/synonym instead. Surfaced as
    /// a tooltip on the Variants tab so it's visible in the GUI, not only logged.
    var variantChromosomeLengthMatchNotes: [String] = [] {
        didSet {
            updateVariantsTabLengthMatchTooltip()
        }
    }

    /// Sets (or clears) the tooltip on the Variants tab segment to reflect
    /// whether any variant contig on this bundle was matched to the reference
    /// by length alone rather than by name.
    func updateVariantsTabLengthMatchTooltip() {
        guard tabControl.segmentCount > DrawerTab.variants.rawValue else { return }
        let tooltip = variantChromosomeLengthMatchNotes.isEmpty
            ? nil
            : variantChromosomeLengthMatchNotes.joined(separator: "\n")
        tabControl.setToolTip(tooltip, forSegment: DrawerTab.variants.rawValue)
    }
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
    /// Arms `annotationQueryWorkItem` after the debounce delay. Tests replace it so they run the query without waiting on the clock.
    var annotationQueryDebounceScheduler: @MainActor (TimeInterval, DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }

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

    /// Database size threshold (1 GB) above which filtered queries are automatically scoped to the current chromosome for performance.
    static let chromosomeScopeThreshold: UInt64 = 1_000_000_000
    /// Database size threshold (25 GB) above which only pre-materialized token paths are allowed for variant filtering to keep interactions responsive.
    static let materializedOnlyThreshold: UInt64 = 25_000_000_000

    /// Last variant query match count used for status labeling (especially capped result sets).
    var lastVariantQueryMatchCount: Int?

    /// Last variant query scope for status labeling.
    var lastVariantQueryScope: VariantQueryScope = .global

    /// Generation counter for variant queries (prevents stale results from overwriting newer ones).
    var variantQueryGeneration: Int = 0

    /// Whether a variant query is currently in progress on a background thread.
    var isVariantQuerying: Bool = false

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
    let tableView = AnnotationDrawerTableView()
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
    let exportButton = MenuMirroringButton()
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
        let hiddenTrackIDs: [String]
        let overlayGeneration: Int
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
    /// The row commands derived for the row whose cells were built last, so
    /// one context menu build serves every cell of the row.
    var accessibilityRowCommandCache: AnnotationDrawerRowCommandCache?
    /// The row whose commands are being listed while it is outside the
    /// selection. Invoking such a command selects the row first, so its
    /// menu is built as if the row alone were selected.
    var unselectedCommandRow: Int?
    /// The indexes the row commands act on right now.
    var commandSelectionIndexes: IndexSet {
        unselectedCommandRow.map { IndexSet(integer: $0) } ?? tableView.selectedRowIndexes
    }
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
    static let callerSettingsColumn = NSUserInterfaceItemIdentifier("CallerSettingsColumn")
    static let sourceColumn = NSUserInterfaceItemIdentifier("SourceColumn")
    static let consequenceColumn = NSUserInterfaceItemIdentifier("ConsequenceColumn")
    static let codingFeatureColumn = NSUserInterfaceItemIdentifier("CodingFeatureColumn")
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
        let previousDensity = appliedVariantToolbarDensity
        updateVariantToolbarDensity()
        if previousDensity != nil, previousDensity != appliedVariantToolbarDensity {
            // Resizing across a density threshold changes which controls
            // the row shows; without this a Profiles pop-up shown at full
            // density stayed on screen after the drawer narrowed.
            updateSearchFieldVisibility()
        }
        applyProfileButtonFit()
    }

    // MARK: - Setup

    func setupView() {
        wantsLayer = true
        layer?.masksToBounds = true
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
        localVariantFilterBadgeLabel.lineBreakMode = .byTruncatingTail
        localVariantFilterBadgeLabel.cell?.truncatesLastVisibleLine = true
        localVariantFilterBadgeLabel.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 245), for: .horizontal)
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
        exportButton.setAccessibilityLabel("Export table")
        exportButton.setAccessibilityHelp("Export all matching or selected rows as Excel, CSV, TSV, or JSON.")
        exportButton.menuProvider = { [weak self] in self?.makeScientificTableExportMenu() }
        headerBar.addSubview(exportButton)

        // Filter profile popup (header bar) — only shown on variants tab
        profileButton.controlSize = .small
        profileButton.font = .systemFont(ofSize: 10, weight: .medium)
        profileButton.translatesAutoresizingMaskIntoConstraints = false
        profileButton.toolTip = "Filter profiles"
        profileButton.isHidden = true  // shown only on variants tab
        // Truncate the pop-up first, then the Table Sync badge, before any
        // fixed-width control is squeezed.
        profileButton.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(rawValue: 240), for: .horizontal)
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

        let headerView = WideColumnDividerHeaderView()
        headerView.columnMenuProvider = { [weak self] column in
            self?.columnHeaderMenu(forColumn: column)
        }
        tableView.headerView = headerView
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
        // Return and Enter do what a double-click does, so the keyboard can
        // recentre the viewport on the selected annotation or variant.
        tableView.onActivateSelectedRow = { [weak self] in
            guard let self else { return }
            self.activateRow(at: self.tableView.selectedRow)
        }
        tableView.registerForDraggedTypes([.string])

        // Context menu (built dynamically via NSMenuDelegate)
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        // menuNeedsUpdate decides every item's enabled state (Edit and Delete
        // need a database row, Show in Inspector one row). Auto-enabling
        // would re-enable them for any target that answers the selector.
        contextMenu.autoenablesItems = false
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

        // The chrome keeps its normal metrics while the drawer is useful. When
        // collapsed, this trailing edge may yield so the clipped content cannot
        // impose its full fixed-row height on the drawer itself.
        let scrollBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        scrollBottomConstraint.priority = .defaultHigh

        // Layout
        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: topAnchor),
            dragHandle.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragHandle.heightAnchor.constraint(equalToConstant: AnnotationDrawerSizing.dividerHeight),

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
            // The right-hand controls are laid out from the trailing edge; without
            // this the Profiles pop-up slides under them at narrow drawer widths.
            profileButton.trailingAnchor.constraint(lessThanOrEqualTo: clearFilterButton.leadingAnchor, constant: -6),

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
            scrollBottomConstraint,

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

    /// The scope this drawer posts window events with and filters them by.
    /// A drawer that a container embeds without a scope, such as the one in
    /// the alignment viewport, uses the scope of the window that shows it.
    var windowEventScope: WindowStateScope? {
        windowStateScope ?? ScopedEventFilter.hostingWindowScope(of: self)
    }

    func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]? = nil) -> [AnyHashable: Any]? {
        ScopedEventFilter.scopedUserInfo(userInfo, scope: windowEventScope)
    }

    func canWriteVariantDatabaseOutputs(workflowName: String) -> Bool {
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

    func variantDatabaseBundleURL(from searchIndex: AnnotationSearchIndex) -> URL? {
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
        guard ScopedEventFilter.accept(notification, for: windowEventScope) else { return }
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
        let index: Int?
        if activeTab == .variants && activeVariantSubtab == .genotypes {
            index = displayedGenotypes.firstIndex {
                $0.trackId == result.trackId && $0.variantRowId == result.variantRowId
            }
        } else {
            index = displayedAnnotations.firstIndex {
                guard $0.trackId == result.trackId else { return false }
                if let rowId = result.variantRowId, let myRowId = $0.variantRowId {
                    return rowId == myRowId
                }
                return $0.chromosome == result.chromosome && $0.start == result.start
                    && $0.ref == result.ref && $0.alt == result.alt
            }
        }
        guard let index else { return }

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
        guard ScopedEventFilter.accept(notification, for: windowEventScope) else { return }
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
        guard ScopedEventFilter.accept(notification, for: windowEventScope) else { return }
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
        let pasteboard = copyPasteboard
        pasteboard.clearContents()
        pasteboard.setString(translation, forType: .string)
        annotationDrawerLogger.info("AnnotationTableDrawerView: Copied translation for '\(annotation.name, privacy: .public)' (\(translation.count) amino acids)")
    }

    @objc func copyNameAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        let pasteboard = copyPasteboard
        pasteboard.clearContents()
        pasteboard.setString(annotation.name, forType: .string)
    }

    @objc func copyCoordinatesAction(_ sender: NSMenuItem) {
        guard let annotation = sender.representedObject as? AnnotationSearchIndex.SearchResult else { return }
        // Both variants and annotations are stored 0-based half-open
        // internally; `GenomicRegion.displayString` is the one place that
        // converts to the 1-based closed convention the app shows and copies
        // everywhere else, so a copied coordinate string always matches what
        // Go to Location and the ruler accept.
        let region = GenomicRegion(chromosome: annotation.chromosome, start: annotation.start, end: annotation.end)
        let pasteboard = copyPasteboard
        pasteboard.clearContents()
        pasteboard.setString(region.displayString, forType: .string)
    }

    // MARK: - Extraction Actions

    func makeAnnotation(from result: AnnotationSearchIndex.SearchResult) -> SequenceAnnotation {
        if let annotation = searchIndex?.lookupSequenceAnnotation(for: result) {
            return annotation
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
        var indexes = commandSelectionIndexes
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
                self?.presentAnnotationFormRefusal(form, step: "Add the annotation", command: "Add Annotation")
                return
            }
        }
    }

    @objc func editAnnotationAction(_ sender: NSMenuItem) {
        guard let result = sender.representedObject as? AnnotationSearchIndex.SearchResult,
              let rowID = result.annotationRowId,
              let searchIndex else {
            presentAnnotationRefusal(ViewerRefusalReports.annotationNotEditable(step: "Edit the annotation"))
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
              let displayStart = Int(form.startField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let displayEnd = Int(form.endField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              displayStart >= 1, displayEnd >= displayStart else {
            presentAnnotationFormRefusal(form, step: "Save the annotation", command: "Edit Annotation")
            return
        }
        let start = GenomicCoordinateDisplay.storedStart(fromDisplay: displayStart)
        let end = GenomicCoordinateDisplay.storedEnd(fromDisplay: displayEnd)
        let attributes = form.attributesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedAttrs = attributes.isEmpty ? [:] : AnnotationDatabase.parseAttributes(attributes)
        let geneName = parsedAttrs["gene"] ?? parsedAttrs["gene_name"] ?? parsedAttrs["gene_id"]
        guard let searchIndex else {
            presentAnnotationRefusal(ViewerRefusalReports.annotationNotEditable(step: "Save the annotation"))
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
            presentAnnotationRefusal(ViewerRefusalReports.annotationNotWritten(step: "Save the annotation", name: name))
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
        // The form shows and accepts 1-based closed coordinates, matching the
        // table; performAnnotationEdit/Creation convert back to stored values.
        let startField = textField("\(GenomicCoordinateDisplay.displayStart(result.start))", placeholder: "Start")
        let endField = textField("\(GenomicCoordinateDisplay.displayEnd(result.end))", placeholder: "End")
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
        // `start`/`end` are stored 0-based half-open; the string overload takes
        // the 1-based closed values a user types into the form.
        performAnnotationCreation(
            name: name,
            type: type,
            chromosome: chromosome,
            startValue: "\(GenomicCoordinateDisplay.displayStart(start))",
            endValue: "\(GenomicCoordinateDisplay.displayEnd(end))",
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
        // Form values are 1-based closed (what the table shows); store 0-based half-open.
        guard !name.isEmpty, !type.isEmpty, !chromosome.isEmpty,
              let displayStart = Int(rawStart.trimmingCharacters(in: .whitespacesAndNewlines)),
              let displayEnd = Int(rawEnd.trimmingCharacters(in: .whitespacesAndNewlines)),
              displayStart >= 1, displayEnd >= displayStart else {
            return false
        }
        let start = GenomicCoordinateDisplay.storedStart(fromDisplay: displayStart)
        let end = GenomicCoordinateDisplay.storedEnd(fromDisplay: displayEnd)
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
        showInInspector(result)
    }

    /// Shows `result` in the Inspector's Selection tab. Shared by the context
    /// menu and the row's accessibility custom action.
    func showInInspector(_ result: AnnotationSearchIndex.SearchResult) {
        if result.isVariant {
            let selectedEntries = variantSelectionEntriesForSelectedRows()
            let contextRowIsSelected = selectedEntries.contains {
                $0.result.trackId == result.trackId
                    && $0.result.variantRowId == result.variantRowId
                    && $0.result.chromosome == result.chromosome
                    && $0.result.start == result.start
            }
            if contextRowIsSelected, selectedEntries.count > 1 {
                NotificationCenter.default.post(
                    name: .variantSelectionChanged,
                    object: self,
                    userInfo: windowScopedUserInfo([
                        NotificationUserInfoKey.variantSelectionEntries: selectedEntries,
                    ])
                )
            } else {
                NotificationCenter.default.post(
                    name: .variantSelected,
                    object: self,
                    userInfo: windowScopedUserInfo([
                        NotificationUserInfoKey.searchResult: result,
                        NotificationUserInfoKey.variantInspectorFields: variantInspectorFields(for: result),
                    ])
                )
            }
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
        let pasteboard = copyPasteboard
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
        let pasteboard = copyPasteboard
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

    /// The Sort/Filter/Size menu for a header context click on `column`.
    ///
    /// A plain left click on a header only sorts (through the column's sort
    /// descriptor prototype); it no longer also pops this menu up.
    func columnHeaderMenu(forColumn column: Int) -> NSMenu? {
        guard column >= 0, column < tableView.tableColumns.count else { return nil }
        let menu = NSMenu()
        switch activeTab {
        case .samples:
            buildSampleColumnHeaderContextMenu(menu, column: column)
        case .annotations:
            buildAnnotationColumnHeaderContextMenu(menu, column: column)
        case .variants where activeVariantSubtab == .calls:
            buildVariantColumnHeaderContextMenu(menu, column: column)
        case .variants:
            buildGenotypeColumnHeaderContextMenu(menu, column: column)
        }
        return menu.items.isEmpty ? nil : menu
    }
}

// MARK: - Keyboard activation

/// The drawer's table. Return and Enter activate the selected row the way a
/// double-click does, so keyboard users and AX-driven automation can recentre
/// the viewport on a variant without a mouse. Everything else is standard
/// `NSTableView` behaviour, including arrow-key selection.
@MainActor
public final class AnnotationDrawerTableView: RowActivatingTableView {}
