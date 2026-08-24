// SequenceViewerView.swift - Main sequence/track viewer view
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import UniformTypeIdentifiers
import Quartz
import PDFKit
import os.log
import LungfishKit
import CryptoKit
import Darwin

/// Logger for SequenceViewerView operations
let sequenceViewerLogger = Logger(subsystem: LogSubsystem.app, category: "SequenceViewerView")

// MARK: - SequenceViewerView

struct AlignmentFileMenuEntry: Equatable {
    let trackId: String
    let title: String
    let url: URL
}

struct ViewerAlignmentFetchIdentity: Hashable, Sendable {
    let bundlePath: String?
    let trackID: String?
    let chromosome: String
    let start: Int
    let end: Int
    let settingsSignature: String
}

private struct DetachedEvidenceSnapshotCheck: Sendable {
    let url: URL
    let expected: ClassifierAlignmentEvidenceFileSnapshot
}

/// Reproducible identity for one returned SAM record.  UUIDs belong to a
/// parser invocation, so an occurrence ordinal distinguishes otherwise
/// byte-identical records across detached-evidence re-fetches.
private struct DetachedAlignmentSelectionIdentity: Hashable {
    let signature: String
    let occurrence: Int
}

/// The main view for rendering sequence and track data.
/// Note: Uses @MainActor for thread safety as it contains mutable UI state.
@MainActor
public class SequenceViewerView: NSView {

    /// A read-only alignment source that uses the full renderer without requiring
    /// a reference-bundle directory. The optional sequence exists only after FASTA
    /// validation; callers must never derive it from reads.
    struct DetachedAlignmentSource {
        struct Contig: Equatable {
            let name: String
            let length: Int
        }

        let identityURL: URL
        let contig: Contig
        let provider: AlignmentDataProvider
        let referenceSequence: String?
        let bamSnapshot: ClassifierAlignmentEvidenceFileSnapshot?
        let indexSnapshot: ClassifierAlignmentEvidenceFileSnapshot?
        let referenceURL: URL?
        let referenceSnapshot: ClassifierAlignmentEvidenceFileSnapshot?

        init(identityURL: URL, contig: Contig, provider: AlignmentDataProvider, referenceSequence: String?, bamSnapshot: ClassifierAlignmentEvidenceFileSnapshot? = nil, indexSnapshot: ClassifierAlignmentEvidenceFileSnapshot? = nil, referenceURL: URL? = nil, referenceSnapshot: ClassifierAlignmentEvidenceFileSnapshot? = nil) {
            self.identityURL = identityURL; self.contig = contig; self.provider = provider; self.referenceSequence = referenceSequence
            self.bamSnapshot = bamSnapshot; self.indexSnapshot = indexSnapshot; self.referenceURL = referenceURL; self.referenceSnapshot = referenceSnapshot
        }
    }

#if DEBUG
    private(set) var testDisplayInvalidationCount = 0
#endif

    /// Reference to the parent controller
    weak var viewController: ViewerViewController?

    /// Window scope included with viewer-originated notifications.
    var windowStateScope: WindowStateScope?

    /// When true, the placeholder text ("Select a file…") is not drawn.
    /// Set by the progress overlay to avoid text overlap.
    var suppressPlaceholder = false

    /// The sequence being displayed
    var sequence: Sequence?

    /// Annotations to overlay
    var annotations: [SequenceAnnotation] = []
    
    /// The reference bundle being displayed (for .lungfishref bundles)
    private(set) var currentReferenceBundle: ReferenceBundle?

    /// Detached classifier BAM evidence, mutually exclusive with a reference bundle.
    private(set) var detachedAlignmentSource: DetachedAlignmentSource?

    var isDisplayingDetachedAlignment: Bool { detachedAlignmentSource != nil }
    var detachedEvidenceStaleReason: String?
    var detachedResourceSignatures: [URL: (Int, Date?)] = [:]
    var onDetachedEvidenceStale: ((String) -> Void)?
    var detachedEvidenceFetchMessage: String?
    private var detachedEvidenceMonitorSources: [DispatchSourceFileSystemObject] = []
    private var detachedEvidenceMonitorGeneration = 0
    private var detachedEvidenceHashInFlight = false
#if DEBUG
    private(set) var detachedEvidenceMonitorEventCount = 0
#endif
    
    /// Cached sequence data for the current visible region (for bundle mode)
    var cachedBundleSequence: String?

    /// The region for which we have cached sequence data
    var cachedSequenceRegion: GenomicRegion?

    /// Error message from the last failed bundle fetch, if any
    var bundleFetchError: String?

    /// Region of the last failed fetch (to prevent infinite retry for the same region)
    var failedFetchRegion: GenomicRegion?

    /// Cached annotations for the current visible region (for bundle mode)
    var cachedBundleAnnotations: [SequenceAnnotation] = []

    /// The region for which we have cached annotation data
    var cachedAnnotationRegion: GenomicRegion?

    /// Whether we're currently fetching bundle data (sequence)
    var isFetchingBundleData: Bool = false

    /// Timestamp when the current sequence fetch started (for stuck-state detection)
    var sequenceFetchStartTime: Date?

    /// Generation counter for sequence fetches — prevents stale results from overwriting newer ones
    var sequenceFetchGeneration: Int = 0

    /// Whether we're currently fetching annotation data
    var isFetchingAnnotations: Bool = false

    /// Timestamp when the current annotation fetch started (for stuck-state detection)
    var annotationFetchStartTime: Date?

    /// Generation counter for annotation fetches — prevents stale results from overwriting newer ones
    var annotationFetchGeneration: Int = 0

    /// Cached variant annotations for the current visible region (rendered alongside gene annotations)
    var cachedVariantAnnotations: [SequenceAnnotation] = []

    /// The region for which we have cached variant data
    var cachedVariantRegion: GenomicRegion?

    /// Whether we're currently fetching variant data
    var isFetchingVariants: Bool = false

    /// Generation counter for variant fetches — prevents stale results from overwriting newer ones
    var variantFetchGeneration: Int = 0

    /// Generation counter for interaction-triggered bundle-sequence fetches (annotation
    /// copy/complement/reverse-complement, FASTA operation dialog input). Prevents a stale
    /// async fetch started by an earlier menu action from applying its result (clipboard
    /// write / dialog presentation) after a newer request has superseded it.
    var fastaOperationFetchGeneration: Int = 0

    // MARK: - Read Alignment State

    /// Cached aligned reads for the current visible region
    var cachedAlignedReads: [AlignedRead] = [] {
        didSet {
            // Any new read set invalidates both the packed layout and the
            // per-read mismatch cache. The generation bump is what the pack
            // cache key keys on, so this is the only place read identity
            // changes need to be tracked.
            cachedReadSetGeneration += 1
            cachedPackKey = nil
            if cachedAlignedReads.isEmpty {
                cachedReadMismatchCache = ReadMismatchCache()
            } else if let pending = pendingReadMismatchCache {
                // Precomputed on the fetch's background thread.
                cachedReadMismatchCache = pending
                pendingReadMismatchCache = nil
            } else {
                cachedReadMismatchCache = ReadMismatchCache.build(for: cachedAlignedReads)
            }
        }
    }

    /// Mismatch cache computed off the main thread by a read fetch, consumed by
    /// the `cachedAlignedReads` `didSet` on commit so the expensive MD parse
    /// never runs on the main actor for fetched batches.
    var pendingReadMismatchCache: ReadMismatchCache?

    /// Packed layout computed off the main thread by a read fetch or background
    /// pack, consumed by `commitReadFetch`/`commitPackedLayout` in the same
    /// handoff as `pendingReadMismatchCache`. The draw path never packs, so a
    /// fresh read set arrives already laid out.
    var pendingPackedLayout: (key: ReadPackCacheKey, packed: [(row: Int, read: AlignedRead)], overflow: Int)?

    /// How much of the current fetch window is actually on screen. Drives the
    /// sampling banner; `.none` while nothing is sampled.
    var readBudgetState: ReadBudgetState { readBudgetStateStorage }

    /// Backing store for `readBudgetState`, written only via
    /// `setReadBudgetState(_:)` so the redraw is never forgotten.
    var readBudgetStateStorage: ReadBudgetState = .none

    /// Read budget for one fetch window. Overridable from the Inspector's read
    /// display settings; defaults to `ReadViewportPolicy.defaultVisibleReadBudget`.
    var visibleReadBudgetSetting: Int = ReadViewportPolicy.defaultVisibleReadBudget

    /// Set by the banner's "Load all" action: suppresses the budget for the
    /// *current* window only, and is cleared whenever the window changes.
    var loadAllReadsRequested: Bool = false

    /// Region the "Load all" override was granted for, so moving to a different
    /// window drops back to the budget instead of inheriting the escape hatch.
    var loadAllReadsRegion: GenomicRegion?

    /// Screen rect of the banner's "Load all" hit target, recorded during draw
    /// so `mouseDown` can test against it. `.null` when no banner is drawn.
    var loadAllButtonRect: CGRect = .null

    /// Phase of the in-flight read load, shown in the loading badge.
    var readLoadPhase: ReadLoadPhase?

    /// Background pack task for a fresh read set, cancelled when zoom, sort, or
    /// the row limit changes while it is in flight.
    var backgroundPackTask: Task<Void, Never>?

    /// Generation gate for background packs, mirroring the fetch gate: a pack
    /// whose generation is stale on completion never installs its layout.
    var packRequestGeneration: Int { packRequestGenerationStorage }

    /// Backing store for `packRequestGeneration`.
    var packRequestGenerationStorage: Int = 0

    /// Key of the pack currently in flight, so the draw path does not queue the
    /// same pack again on every frame while it runs.
    var inFlightPackKey: ReadPackCacheKey?

    /// The region for which we have cached read data
    var cachedReadRegion: GenomicRegion?

    /// Cached sparse depth points for the current visible region (coverage tier).
    var cachedDepthPoints: [ReadTrackRenderer.CoveragePoint] = []

    /// The region for which we have cached depth data.
    var cachedDepthRegion: GenomicRegion?

    /// Cached consensus sequence for the current region.
    var cachedConsensusSequence: String?

    /// The region for which we have cached consensus sequence.
    var cachedConsensusRegion: GenomicRegion?

    /// Option signature used to compute `cachedConsensusSequence`.
    var cachedConsensusOptionsSignature: String = ""

    /// Shared command-key zoom handler for the sequence viewer.
    lazy var zoomShortcutHandler = ZoomShortcutHandler(
        zoomIn: { [weak self] in self?.viewController?.zoomIn() },
        zoomOut: { [weak self] in self?.viewController?.zoomOut() },
        zoomToFit: { [weak self] in self?.viewController?.zoomToFit() }
    )

    /// Whether we're currently fetching read data
    var isFetchingReads: Bool = false {
        didSet { updateTrackLoadingAnimationState() }
    }

    /// Timestamp when the current read fetch started.
    var readFetchStartTime: Date?

    /// Whether we're currently fetching depth data.
    var isFetchingDepth: Bool = false {
        didSet { updateTrackLoadingAnimationState() }
    }

    /// Timestamp when the current depth fetch started.
    var depthFetchStartTime: Date?

    /// Timer driving the in-track loading badge spinner.
    private nonisolated(unsafe) var trackLoadingAnimationTimer: Timer?

    /// Current spinner phase in radians.
    var trackLoadingAnimationPhase: CGFloat = 0

    /// Whether we're currently fetching consensus sequence data.
    var isFetchingConsensus: Bool = false

    var horizontalScrollDirectionOverride: ScrollDirectionPreference? {
        didSet {
            guard oldValue != horizontalScrollDirectionOverride else { return }
            needsDisplay = true
        }
    }

    static func scrollDirectionSign(
        for preference: ScrollDirectionPreference,
        isDirectionInvertedFromDevice: Bool
    ) -> CGFloat {
        switch preference {
        case .system:
            return isDirectionInvertedFromDevice ? -1 : 1
        case .natural:
            return -1
        case .traditional:
            return 1
        }
    }

    static func horizontalPanAmount(
        deltaX: CGFloat,
        scale: Double,
        hasPreciseScrollingDeltas: Bool,
        preference: ScrollDirectionPreference,
        isDirectionInvertedFromDevice: Bool
    ) -> Double {
        let sign = scrollDirectionSign(
            for: preference,
            isDirectionInvertedFromDevice: isDirectionInvertedFromDevice
        )
        let panScale: CGFloat = hasPreciseScrollingDeltas ? 1.0 : 2.0
        return Double(sign * deltaX) * scale * panScale
    }

    static func pinchZoomFactor(magnification: CGFloat) -> Double {
        let proposed = 1.0 + Double(magnification)
        return min(8.0, max(0.125, proposed))
    }

    static func effectiveHorizontalScrollDirection(
        bundleOverride: ScrollDirectionPreference?,
        globalPreference: ScrollDirectionPreference
    ) -> ScrollDirectionPreference {
        guard let bundleOverride else { return globalPreference }
        return ReferenceBundleScrollDirectionPreference.viewportDirection(for: bundleOverride)
    }

    /// Generation counter for read fetches — prevents stale results from overwriting newer ones
    var readFetchGeneration: Int = 0

    /// Generation counter for depth fetches — prevents stale results from overwriting newer ones.
    var depthFetchGeneration: Int = 0

    /// Generation counter for consensus fetches — prevents stale results from overwriting newer ones.
    var consensusFetchGeneration: Int = 0

    var readFetchGate = AsyncRequestGate<ViewerAlignmentFetchIdentity>()
    var depthFetchGate = AsyncRequestGate<ViewerAlignmentFetchIdentity>()
    var consensusFetchGate = AsyncRequestGate<ViewerAlignmentFetchIdentity>()
    var activeAlignmentFetchIdentity: ViewerAlignmentFetchIdentity?
    var detachedReadFetchTask: Task<Void, Never>?
    var detachedDepthFetchTask: Task<Void, Never>?

    /// Coverage stats from the currently cached depth points.
    var cachedCoverageStats: ReadTrackRenderer.CoverageStats?

    /// Whether to show the read alignment track
    var showReads: Bool = true

    /// Maximum read rows (configurable from Inspector)
    var maxReadRowsSetting: Int = 75

    /// Whether read row count is capped by `maxReadRowsSetting`.
    var limitReadRowsSetting: Bool = false

    /// Whether read rows use compact vertical heights.
    var verticallyCompressContigSetting: Bool = true

    /// Minimum MAPQ filter (configurable from Inspector)
    var minMapQSetting: Int = 0

    /// Whether to show mismatches (configurable from Inspector)
    var showMismatchesSetting: Bool = true

    /// Whether to show soft clips (configurable from Inspector)
    var showSoftClipsSetting: Bool = true

    /// Whether to show insertions/deletions (configurable from Inspector)
    var showIndelsSetting: Bool = true

    /// Whether to tint read backgrounds by strand direction.
    var showStrandColorsSetting: Bool = true

    /// Whether to mask columns that are mostly gaps (consensus-style filtering).
    var consensusMaskingEnabledSetting: Bool = false

    /// Gap masking threshold in percent (e.g., 90 = hide columns with >=90% gaps).
    var consensusGapThresholdPercentSetting: Int = 90

    /// Minimum depth required before a consensus base is emitted.
    var consensusMinDepthSetting: Int = 8

    /// Minimum spanning depth required before high-gap masking is applied.
    var consensusMaskingMinDepthSetting: Int = 8

    /// Minimum mapping quality used for consensus/depth calculations.
    var consensusMinMapQSetting: Int = 0

    /// Minimum base quality used for consensus/depth calculations.
    var consensusMinBaseQSetting: Int = 0

    /// Whether the consensus row is shown under depth when zoomed in enough to render bases.
    var showConsensusTrackSetting: Bool = true

    /// Consensus caller mode.
    var consensusModeSetting: AlignmentConsensusMode = .bayesian

    /// Whether to emit IUPAC ambiguity codes in consensus output.
    var consensusUseAmbiguitySetting: Bool = false

    /// Exclude flags bitmask for samtools view (configurable from Inspector)
    /// Default: unmapped(0x4) + secondary(0x100) + dup(0x400) + supplementary(0x800) = 0xD04
    var excludeFlagsSetting: UInt16 = 0xD04

    /// Selected read group IDs to display (empty = show all)
    var selectedReadGroupsSetting: Set<String> = []

    /// Currently isolated alignment track ID. `nil` means aggregate all loaded alignments.
    var visibleAlignmentTrackIDSetting: String? = nil

    /// Alignment data providers for each imported alignment track
    var alignmentDataProviders: [(trackId: String, provider: AlignmentDataProvider)] = []

    /// Currently hovered read (for tooltip caching)
    var hoveredRead: AlignedRead?

    /// Set of read UUIDs currently selected (for multi-read selection).
    var selectedReadIDs: Set<UUID> = []
    private var preservedDetachedSelectionKeys: Set<DetachedAlignmentSelectionIdentity> = []

    /// Currently selected read (for inspector display — first selected read).
    var selectedRead: AlignedRead? {
        guard let firstID = selectedReadIDs.first else { return nil }
        return cachedPackedReads.first(where: { $0.read.id == firstID })?.read
    }

    /// All currently selected reads (for multi-read actions like "Copy as
    /// FASTA" / "Extract Reads…"). A single QNAME can map to more than one
    /// record here when both mates of a pair are selected.
    var selectedReads: [AlignedRead] {
        guard !selectedReadIDs.isEmpty else { return [] }
        return cachedPackedReads
            .map(\.read)
            .filter { selectedReadIDs.contains($0.id) }
    }

    /// Cached packed reads for hit-testing (updated during draw).
    ///
    /// Whenever this is reassigned, `cachedPackedReadsByRow` is rebuilt to bucket
    /// entries by row so hit-testing (`readAtPoint`) can index directly into a row's
    /// reads instead of linearly scanning the full array (F1).
    var cachedPackedReads: [(row: Int, read: AlignedRead)] = [] {
        didSet {
            cachedPackedReadsByRow = SequenceViewerView.bucketPackedReadsByRow(cachedPackedReads)
            cachedPackedReadLayout = PackedReadLayout(packedReads: cachedPackedReads)
            if !preservedDetachedSelectionKeys.isEmpty,
               (!cachedPackedReads.isEmpty || !cachedAlignedReads.isEmpty) {
                let identities = Self.detachedSelectionIdentities(for: cachedPackedReads.map(\.read))
                let restored = Set<UUID>(cachedPackedReads.compactMap { row in
                    guard let identity = identities[row.read.id], preservedDetachedSelectionKeys.contains(identity) else { return nil }
                    return row.read.id
                })
                preservedDetachedSelectionKeys = []
                updateDetachedSelection(restored)
            }
        }
    }

    /// Reads bucketed by row, kept in sync with `cachedPackedReads` via `didSet`.
    /// Used by `readAtPoint` for O(row bucket) hit-testing instead of an O(N) linear scan.
    private(set) var cachedPackedReadsByRow: [Int: [AlignedRead]] = [:]

    /// Buckets packed reads by row index. Pure function, exposed for testing hit-test parity.
    static func bucketPackedReadsByRow(_ packedReads: [(row: Int, read: AlignedRead)]) -> [Int: [AlignedRead]] {
        var buckets: [Int: [AlignedRead]] = [:]
        buckets.reserveCapacity(packedReads.count)
        for (row, read) in packedReads {
            buckets[row, default: []].append(read)
        }
        return buckets
    }

    /// Row-bucketed view of `cachedPackedReads`, rebuilt alongside it so drawing
    /// can cull to the visible row range and binary-search within a row.
    private(set) var cachedPackedReadLayout: PackedReadLayout?

    /// Identity of the layout currently in `cachedPackedReads`. When a draw's
    /// recomputed key equals this, packing is skipped entirely.
    var cachedPackKey: ReadPackCacheKey?

    /// Per-read MD-tag mismatch positions, precomputed off the main thread when
    /// a read batch is committed. Rebuilt only when `cachedAlignedReads` changes.
    private(set) var cachedReadMismatchCache: ReadMismatchCache?

    /// Bumped on every assignment to `cachedAlignedReads`, forming the data
    /// half of `ReadPackCacheKey`. Distinct from `readFetchGeneration`, which
    /// also advances for in-flight fetches that never commit.
    private(set) var cachedReadSetGeneration: Int = 0

    /// Number of times the read layout was packed **on the main thread**. Test
    /// seam for asserting that `draw(_:)` never packs a fresh read set; a
    /// background pack deliberately leaves this alone.
    private(set) var packInvocationCount: Int = 0

    /// Number of background packs started. Test seam for the cache contract:
    /// unchanged inputs must not queue another pack, changed inputs must.
    var backgroundPackInvocationCount: Int = 0

    /// Invalidates the packed-layout cache so the next draw repacks.
    func invalidatePackedReadLayoutCache() {
        cachedPackKey = nil
    }

    /// Packs `reads` only when `key` differs from the cached layout's key,
    /// otherwise returns the cached layout untouched.
    ///
    /// This is the single choke point for read packing: both the bundle-backed
    /// and detached-evidence draw paths route through it, so neither can
    /// re-sort and re-pack the full read set on every pan, hover, or selection
    /// redraw.
    @discardableResult
    func packedReadLayout(
        key: ReadPackCacheKey,
        pack: () -> (packed: [(row: Int, read: AlignedRead)], overflow: Int)
    ) -> (packed: [(row: Int, read: AlignedRead)], overflow: Int) {
        if let cachedPackKey, cachedPackKey == key, cachedPackedReadLayout != nil {
            return (cachedPackedReads, cachedPackOverflow)
        }
        let result = pack()
        packInvocationCount += 1
        cachedPackedReads = result.packed
        cachedPackOverflow = result.overflow
        cachedPackKey = key
        return result
    }

    /// Installs an already-computed layout without running the packer.
    ///
    /// This is the only way a layout enters the cache from a background pack,
    /// and it deliberately does **not** bump `packInvocationCount`: that counter
    /// exists to catch packing on the main thread, so a background result must
    /// leave it alone for the off-main test to mean anything.
    func installPackedLayout(
        key: ReadPackCacheKey,
        packed: [(row: Int, read: AlignedRead)],
        overflow: Int
    ) {
        cachedPackedReads = packed
        cachedPackOverflow = overflow
        cachedPackKey = key
    }

    /// Cached packed layout overflow count (from last pack operation)
    var cachedPackOverflow: Int = 0

    /// Scale at which the pack layout was computed (recompute if scale changes)
    var cachedPackScale: Double = 0

    /// Read data generation when pack layout was computed (recompute if data changes)
    var cachedPackDataGeneration: Int = -1

    /// Max rows setting when pack layout was computed
    var cachedPackMaxRows: Int = 0

    /// Viewport region when pack layout was computed (repack when panned significantly)
    var cachedPackViewportStart: Int = 0
    var cachedPackViewportEnd: Int = 0

    /// The Y offset at which reads were last rendered (for hit-testing)
    var lastRenderedReadY: CGFloat = 0

    /// The Y offset at which coverage was last rendered (for hover).
    var lastRenderedCoverageY: CGFloat = 0

    /// The zoom tier at which reads were last rendered
    var lastRenderedReadTier: ReadTrackRenderer.ZoomTier = .coverage

    /// Vertical scroll offset for the read track (when rows exceed available space)
    var readScrollOffset: CGFloat = 0

    /// Maximum height allocated for the read track before requiring scrolling
    let maxReadTrackHeight: CGFloat = 300

    /// Total content height of the packed reads (set during draw)
    var readContentHeight: CGFloat = 0

    /// Coverage strip height rendered for alignments.
    let coverageStripHeight: CGFloat = ReadTrackRenderer.coverageTrackHeight

    /// Consensus strip height rendered below coverage.
    /// Must match the sequence track height so reference/consensus cells are visually identical.
    var consensusStripHeight: CGFloat { trackHeight }

    /// Spacing between coverage and consensus rows.
    let coverageToConsensusGap: CGFloat = 2

    /// Spacing between consensus row and read rows.
    let consensusToReadGap: CGFloat = 4

    /// Whether drag is active (for highlighting)
    var isDragActive = false

    /// Current appearance settings for sequence visualization
    var sequenceAppearance: SequenceAppearance = AppSettings.shared.sequenceAppearance

    // MARK: - Selection State

    /// Current selection range in base coordinates (nil if no selection)
    public var selectionRange: Range<Int>?

    /// Mouse drag start position for selection
    var selectionStartBase: Int?

    /// Whether we're currently dragging to select.
    var isSelecting = false

    /// Last logged selection render signature (used to suppress per-frame log spam).
    var lastSelectionRenderSignature: String?

    /// Whether the current selectionRange was set by user click/drag.
    /// When true, ensureVisibleViewportSelection() will not overwrite it.
    var isUserColumnSelection = false

    /// Genomic position where the user started a column-selection drag.
    var columnDragStartBase: Int?

    /// Currently selected annotation (nil if no annotation selected).
    /// Internal so the AnnotationDrawer extension can set it from table selection.
    var selectedAnnotation: SequenceAnnotation?

    /// Genomic position under the latest context-menu click.
    var contextMenuGenomicPosition: Int?

    /// Popover for annotation details on double-click
    var annotationPopover: NSPopover?

    /// Track positioning (shared with header)
    var trackY: CGFloat = 20
    var trackHeight: CGFloat = 40

    /// Whether to show complement strand
    var showComplementStrand: Bool = false

    /// Whether to display as RNA (U instead of T)
    var isRNAMode: Bool = false {
        didSet {
            needsDisplay = true
        }
    }

    // MARK: - Translation Track State

    /// Whether the translation track is visible below the sequence track.
    var showTranslationTrack: Bool = false

    /// Pre-computed CDS translation result (set when user clicks "Translate" on a CDS annotation).
    var activeTranslationResult: TranslationResult?

    /// Cached per-annotation translations for expanded annotation rows.
    /// Keyed by annotation UUID. Invalidated on chromosome/sequence change.
    var cachedCDSTranslations: [UUID: TranslationResult] = [:]

    /// Cached CDS coding contexts used for codon-level consequence fallback in hover text.
    /// Keyed by annotation UUID. Invalidated on chromosome/sequence change.
    var cachedCDSCodingContexts: [UUID: CDSCodingContext] = [:]

    /// Color scheme for amino acid rendering.
    var translationColorScheme: AminoAcidColorScheme = .zappo

    /// Reading frames to display in frame-translation mode (empty = CDS mode).
    var frameTranslationFrames: [ReadingFrame] = []

    /// Codon table for frame translations.
    var frameTranslationTable: CodonTable = .standard

    /// Whether to render stop codon cells in translation tracks.
    var translationShowStopCodons: Bool = true

    /// Precomputed CDS coordinate/codon mapping for local consequence prediction.
    struct CDSCodingContext {
        let annotation: SequenceAnnotation
        let codingBases: [Character]
        let codingGenomePositions: [Int]
        let phaseOffset: Int
        let codonTable: CodonTable
    }

    // MARK: - Annotation Track Layout Constants

    /// Y offset where annotation track starts (below sequence + optional translation track).
    ///
    /// Only reserves space for the translation track when it is actually rendering
    /// at the current zoom level (scale < showLettersThreshold). At zoom levels where
    /// translation doesn't render, annotations are placed directly below the sequence.
    var annotationTrackY: CGFloat {
        var y = trackY + trackHeight + 4
        if showTranslationTrack {
            let currentScale = viewController?.referenceFrame?.scale ?? Double.greatestFiniteMagnitude
            if currentScale < showLettersThreshold {
                y += translationTrackTotalHeight + 4
            }
        }
        return y
    }

    /// Y position where the variant track starts (below annotations).
    /// Updated after annotation rendering to reflect actual annotation height.
    var lastAnnotationBottomY: CGFloat = 0

    /// Extra spacing to prevent annotation labels from colliding with variant labels/rows.
    let annotationToVariantPadding: CGFloat = 10
    /// Reserve text descender space below annotation rows (overflow/hint labels).
    let annotationLabelClearance: CGFloat = 14

    /// Y offset where variant summary bar starts (below annotations).
    var variantTrackY: CGFloat {
        max(lastAnnotationBottomY + annotationToVariantPadding, annotationTrackY + annotationToVariantPadding)
    }

    /// Y position where the variant track ends (updated during variant rendering).
    var lastVariantBottomY: CGFloat = 0

    /// Spacing between variant and read tracks.
    let variantToReadPadding: CGFloat = 10

    /// Y offset where the read alignment track starts (below variants).
    var readTrackY: CGFloat {
        if showVariants && !filteredVisibleVariantAnnotations.isEmpty {
            return max(lastVariantBottomY + variantToReadPadding, variantTrackY + variantToReadPadding)
        }
        // No variants visible → reads go where variants would
        return variantTrackY
    }

    /// Cached filtered variant annotations. Invalidated by `invalidateFilteredVariantCache()`.
    var _cachedFilteredVariants: [SequenceAnnotation]?
    /// Viewport signature used to validate `_cachedFilteredVariants`.
    var filteredVariantCacheViewportSignature: (chromosome: String, start: Int, end: Int)?

    /// Optional row-level variant render filter from the drawer (`trackId:variantRowId`).
    /// `nil` means render all variants that pass inspector filters.
    var localVariantRenderFilterKeys: Set<String>?
    /// Optional row-level annotation render filter from the drawer (`trackId:annotationRowId`).
    /// `nil` means render all annotations that pass inspector filters.
    var localAnnotationRenderFilterKeys: Set<String>?
    var annotationTrackDisplayState = AnnotationTrackDisplayState(order: [])
    /// Cached genotype dataset after applying table-synced row filtering.
    var _cachedFilteredGenotypeData: GenotypeDisplayData?

    /// Variant annotations after applying current type/text filters.
    /// Caches the result to avoid re-filtering on every access during a draw cycle.
    var filteredVisibleVariantAnnotations: [SequenceAnnotation] {
        let currentViewportSignature: (chromosome: String, start: Int, end: Int)?
        if let frame = viewController?.referenceFrame {
            currentViewportSignature = (
                chromosome: frame.chromosome,
                start: Int(frame.start),
                end: Int(ceil(frame.end))
            )
        } else {
            currentViewportSignature = nil
        }

        if filteredVariantCacheViewportSignature?.chromosome != currentViewportSignature?.chromosome
            || filteredVariantCacheViewportSignature?.start != currentViewportSignature?.start
            || filteredVariantCacheViewportSignature?.end != currentViewportSignature?.end {
            _cachedFilteredVariants = nil
            filteredVariantCacheViewportSignature = currentViewportSignature
        }

        if let cached = _cachedFilteredVariants { return cached }
        guard showVariants else {
            _cachedFilteredVariants = []
            return []
        }
        var variants = cachedVariantAnnotations
        if let typeFilter = visibleVariantTypes, !typeFilter.isEmpty {
            variants = variants.filter { ann in
                let vtypeStr = ann.qualifiers["variant_type"]?.values.first ?? ""
                return typeFilter.contains(vtypeStr)
            }
        }
        if !variantFilterText.isEmpty {
            let lower = variantFilterText.lowercased()
            variants = variants.filter { $0.name.lowercased().contains(lower) }
        }
        if let localKeys = localVariantRenderFilterKeys {
            variants = variants.filter { annotation in
                guard let trackId = annotation.qualifiers["variant_track_id"]?.values.first,
                      let rowId = annotation.qualifiers["variant_row_id"]?.values.first else { return false }
                return localKeys.contains("\(trackId):\(rowId)")
            }
        }
        if let frame = viewController?.referenceFrame {
            let visibleStart = Int(frame.start)
            let visibleEnd = Int(frame.end)
            let visibleChromosome = frame.chromosome
            variants = variants.filter { annotation in
                annotation.chromosome == visibleChromosome
                    && annotation.end > visibleStart
                    && annotation.start < visibleEnd
            }
        }
        _cachedFilteredVariants = variants
        return variants
    }

    /// Genotype data after applying the optional drawer-local render filter (`trackId:rowId`).
    func filteredVisibleGenotypeData() -> GenotypeDisplayData? {
        guard let genotypeData = cachedGenotypeData else { return nil }
        guard let localKeys = localVariantRenderFilterKeys else { return genotypeData }
        if let cached = _cachedFilteredGenotypeData { return cached }
        let filteredSites = genotypeData.sites.filter { site in
            guard let trackId = site.sourceTrackId, let rowId = site.databaseRowId else { return false }
            return localKeys.contains("\(trackId):\(rowId)")
        }
        let filtered = GenotypeDisplayData(sampleNames: genotypeData.sampleNames, sites: filteredSites, region: genotypeData.region)
        _cachedFilteredGenotypeData = filtered
        return filtered
    }

    /// Invalidates the filtered variant cache so it's recomputed on next access.
    func invalidateFilteredVariantCache() {
        _cachedFilteredVariants = nil
        filteredVariantCacheViewportSignature = nil
    }

    /// Updates the optional drawer-local variant render filter and invalidates cached filtering.
    func setLocalVariantRenderFilterKeys(_ keys: Set<String>?) {
        guard localVariantRenderFilterKeys != keys else { return }
        localVariantRenderFilterKeys = keys
        _cachedFilteredGenotypeData = nil

        // If the current genotype cache does not contain any of the newly-selected
        // table-synced variant keys, force a genotype refetch on next draw. This
        // recovers from zoom churn where a broad cached genotype window "covers"
        // the region but was limited/truncated and misses current visible rows.
        if let keys, !keys.isEmpty, let genotypeData = cachedGenotypeData {
            let hasOverlap = genotypeData.sites.contains { site in
                guard let trackId = site.sourceTrackId, let rowId = site.databaseRowId else { return false }
                return keys.contains("\(trackId):\(rowId)")
            }
            if !hasOverlap {
                cachedGenotypeRegion = nil
                sequenceViewerLogger.info("setLocalVariantRenderFilterKeys: No overlap with cached genotype sites; scheduling refetch")
            }
        }

        lastHoveredGenotypeCell = nil
        lastHoveredGenotypeTooltipText = nil
        lastHoveredGenotypeStatusText = nil
        invalidateFilteredVariantCache()
    }

    /// Updates the optional drawer-local annotation render filter and invalidates cached annotation drawing.
    func setLocalAnnotationRenderFilterKeys(_ keys: Set<String>?) {
        guard localAnnotationRenderFilterKeys != keys else { return }
        localAnnotationRenderFilterKeys = keys
        hoveredAnnotation = nil
        invalidateAnnotationTile()
    }

    func setAnnotationTrackDisplayState(_ state: AnnotationTrackDisplayState) {
        guard annotationTrackDisplayState != state else { return }
        annotationTrackDisplayState = state
        hoveredAnnotation = nil
        invalidateAnnotationTile()
    }

    /// Total height of the translation track area.
    var translationTrackTotalHeight: CGFloat {
        if !frameTranslationFrames.isEmpty {
            return TranslationTrackRenderer.totalHeight(for: frameTranslationFrames)
        } else {
            return TranslationTrackRenderer.cdsTrackHeight()
        }
    }

    /// Whether to show annotations (controlled by inspector)
    var showAnnotations: Bool = true

    /// Height of each annotation box (configurable via inspector)
    var annotationHeight: CGFloat = CGFloat(AppSettings.shared.defaultAnnotationHeight)

    /// Vertical spacing between annotation rows (configurable via inspector)
    var annotationRowSpacing: CGFloat = CGFloat(AppSettings.shared.defaultAnnotationSpacing)

    /// Set of annotation types to display (nil means show all)
    var visibleAnnotationTypes: Set<AnnotationType>?

    /// Text filter for annotations (empty string means no filter)
    var annotationFilterText: String = ""

    /// Whether to show variant annotations (controlled by inspector)
    var showVariants: Bool = true

    /// Set of variant types to display (nil means show all). Values are VariantType rawValues: "SNP", "INS", "DEL", etc.
    var visibleVariantTypes: Set<String>?

    /// Text filter for variants (searches variant IDs)
    var variantFilterText: String = ""

    // MARK: - Genotype Track State

    /// Effective summary bar height based on display state. Returns 0 when summary bar is hidden.
    var effectiveSummaryBarHeight: CGFloat {
        sampleDisplayState.showSummaryBar ? sampleDisplayState.summaryBarHeight : 0
    }

    /// Effective gap between summary bar and genotype rows.
    var effectiveSummaryToRowGap: CGFloat {
        sampleDisplayState.showSummaryBar ? VariantTrackRenderer.summaryToRowGap : 0
    }

    /// Cached genotype display data for the visible region.
    var cachedGenotypeData: GenotypeDisplayData? {
        didSet { _cachedFilteredGenotypeData = nil }
    }

    /// Optional display labels per sample for genotype row rendering.
    var cachedGenotypeSampleDisplayNames: [String: String] = [:]

    /// Region for which genotype data is cached.
    var cachedGenotypeRegion: GenomicRegion?

    /// Whether we're currently fetching genotype data.
    var isFetchingGenotypes: Bool = false

    /// Generation counter for genotype fetches.
    var genotypeFetchGeneration: Int = 0

    /// Display state controlling sample sort, filter, and visibility.
    var sampleDisplayState: SampleDisplayState = {
        var state = SampleDisplayState()
        state.colorThemeName = AppSettings.shared.variantColorThemeName
        return state
    }() {
        didSet { invalidateGutterWidth() }
    }

    /// Whether the user is dragging the sample gutter edge.
    var isDraggingGutterEdge: Bool = false

    /// Number of samples in the current variant database (cached for layout).
    var cachedSampleCount: Int = 0

    /// Horizontal inset used by genotype labels before data cells begin.
    /// Adds a 10px safety pad beyond `variantDataStartX` to keep navigation targets
    /// away from the label column edge.
    var navigationLeadingInsetPixels: CGFloat {
        let base = variantDataStartX
        return base > 0 ? base + 10 : 0
    }

    /// Cached value of the gutter width. Updated by `invalidateGutterWidth()`.
    var _cachedVariantDataStartX: CGFloat?

    /// The X pixel where variant data begins (after sample gutter + margin).
    /// Returns 0 when genotype rows are hidden or no samples exist.
    /// Cached to avoid per-frame text measurement in draw().
    var variantDataStartX: CGFloat {
        if let cached = _cachedVariantDataStartX { return cached }
        let value = computeVariantDataStartX()
        _cachedVariantDataStartX = value
        return value
    }

    /// Recomputes the gutter width from current state. Call when sample names,
    /// display names, row height, or gutter override change.
    func computeVariantDataStartX() -> CGFloat {
        guard sampleDisplayState.showGenotypeRows, sampleDisplayState.rowHeight >= 8 else { return 0 }
        let sampleNames = cachedGenotypeData?.sampleNames ?? []
        guard !sampleNames.isEmpty else { return 0 }
        let gutterW = VariantTrackRenderer.sampleLabelGutterWidth(
            samples: sampleNames,
            sampleDisplayNames: cachedGenotypeSampleDisplayNames,
            rowHeight: sampleDisplayState.rowHeight,
            override: sampleDisplayState.sampleGutterWidthOverride
        )
        return gutterW + VariantTrackRenderer.sampleLabelToDataMargin
    }

    /// Invalidates the cached gutter width, forcing recomputation on next access.
    func invalidateGutterWidth() {
        _cachedVariantDataStartX = nil
    }

    /// Vertical scroll offset for genotype rows (in pixels).
    /// Zero = first sample row at top. Positive = scrolled down.
    var genotypeScrollOffset: CGFloat = 0

    /// Maximum vertical scroll offset for genotype rows at the current frame/layout.
    func maxGenotypeScrollOffset(frame: ReferenceFrame) -> CGFloat {
        let sampleCount = cachedGenotypeData?.sampleNames.count ?? cachedSampleCount
        guard sampleCount > 0 else { return 0 }
        let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
        let rowH = sampleDisplayState.rowHeight
        guard rowH > 0 else { return 0 }
        let availableHeight = max(0, bounds.height - genotypeTopY)
        return max(0, CGFloat(sampleCount) * rowH - availableHeight)
    }

    /// Clamps genotype scroll offset to the valid range for current content/layout.
    func clampGenotypeScrollOffset(frame: ReferenceFrame? = nil) {
        let activeFrame = frame ?? viewController?.referenceFrame
        guard let activeFrame else {
            genotypeScrollOffset = 0
            return
        }
        let maxOffset = maxGenotypeScrollOffset(frame: activeFrame)
        genotypeScrollOffset = max(0, min(genotypeScrollOffset, maxOffset))
    }

    /// Maps reference chromosome names to variant DB chromosome names.
    /// Built at bundle load time by matching chromosome lengths when names differ.
    /// Empty if all names match or no variant tracks are loaded.
    var variantChromosomeAliasMap: [String: String] = [:]
    /// Cached per-track chromosome name sets from variant databases.
    var variantTrackChromosomeMap: [String: Set<String>] = [:]

    /// Maps reference chromosome names to BAM/CRAM chromosome names.
    /// Built at bundle load time from AlignmentMetadataDatabase chromosome_stats.
    /// Empty if all names match or no alignment tracks are loaded.
    var alignmentChromosomeAliasMap: [String: String] = [:]

    // MARK: - Annotation Color Cache

    /// Cached CGColors keyed by AnnotationType to avoid NSColor allocation per-draw.
    /// Cleared on appearance change (dark mode toggle). Also stores per-type color overrides
    /// loaded from BundleViewState.
    var typeColorCache: [AnnotationType: (fill: CGColor, stroke: CGColor)] = [:]

    /// Returns cached (fill, stroke) CGColor pair for an annotation.
    /// Uses the annotation's custom color if set, otherwise caches by type.
    func cachedColors(for annot: SequenceAnnotation) -> (fill: CGColor, stroke: CGColor) {
        // Fast path: no custom color → use type-based cache
        if annot.color == nil, let cached = typeColorCache[annot.type] {
            return cached
        }
        let annotColor = annot.color ?? annot.type.defaultColor
        let nsColor = NSColor(
            calibratedRed: CGFloat(annotColor.red),
            green: CGFloat(annotColor.green),
            blue: CGFloat(annotColor.blue),
            alpha: 1.0
        )
        let fill = nsColor.withAlphaComponent(0.7).cgColor
        let stroke = nsColor.cgColor
        if annot.color == nil {
            typeColorCache[annot.type] = (fill, stroke)
        }
        return (fill, stroke)
    }

    /// Cached CGColors for density histogram bars keyed by AnnotationType.
    var typeDensityColorCache: [AnnotationType: CGColor] = [:]

    /// Returns a cached density-bar CGColor (0.6 alpha) for a given annotation type.
    func cachedDensityColor(for type: AnnotationType) -> CGColor {
        if let cached = typeDensityColorCache[type] { return cached }
        let typeColor = type.defaultColor
        let nsColor = NSColor(
            calibratedRed: CGFloat(typeColor.red),
            green: CGFloat(typeColor.green),
            blue: CGFloat(typeColor.blue),
            alpha: 0.6
        )
        let color = nsColor.cgColor
        typeDensityColorCache[type] = color
        return color
    }

    // MARK: - Offscreen Annotation Tile

    /// Pre-rendered annotation tile image for fast pan blitting.
    var annotationTile: CGImage?

    /// Genomic start position of the rendered tile.
    var tileGenomicStart: Double = 0

    /// Genomic end position of the rendered tile.
    var tileGenomicEnd: Double = 0

    /// The bp/pixel scale at which the tile was rendered.
    var tileScale: Double = 0

    /// Pixel width of the tile image.
    var tileWidth: Int = 0

    /// Pixel height of the tile image.
    var tileHeight: Int = 0

    /// The chromosome the tile was rendered for.
    var tileChromosome: String = ""

    /// Invalidates the annotation tile, forcing re-render on next draw.
    func invalidateAnnotationTile() {
        annotationTile = nil
    }

    // MARK: - Multi-Sequence State (moved from associated objects)

    /// State manager for multi-sequence display.
    ///
    /// When set, enables multi-sequence stacking mode. When nil, the viewer
    /// operates in single-sequence mode (default behavior).
    internal var multiSequenceState: MultiSequenceState?

    /// Whether multi-sequence mode is active.
    public var isMultiSequenceMode: Bool = false


    // MARK: - Scroll Coalescing

    /// Timer for coalescing scroll-triggered redraws at 60fps.
    var scrollRedrawTimer: Timer?

    // MARK: - Zoom Thresholds (bp/pixel)
    //
    // Rendering modes based on zoom level:
    // - BASE_MODE: < 10 bp/pixel - Individual colored bases with letters
    // - BLOCK_MODE: 10-500 bp/pixel - Colored blocks showing dominant base
    // - LINE_MODE: > 500 bp/pixel - Simple gray horizontal line

    /// Below this threshold: show individual base letters with colors
    /// At this zoom level, bases are large enough to read
    var showLettersThreshold: Double { AppSettings.shared.showLettersThresholdBpPerPixel }

    /// Above this threshold: switch from colored blocks to simple line
    /// Beyond this zoom level, colored blocks become uninformative visual noise
    let showLineThreshold: Double = 500.0

    // MARK: - Quality Score Colors

    /// Quality score color thresholds for overlay rendering.
    /// Maps Phred quality scores to colors indicating confidence levels.
    enum QualityColors {
        /// Q < 10: Dark red - very low quality (>10% error rate)
        static let veryLow = NSColor(calibratedRed: 0.8, green: 0.0, blue: 0.0, alpha: 0.5)

        /// Q 10-19: Red - low quality (1-10% error rate)
        static let low = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: 0.5)

        /// Q 20-29: Orange - medium quality (0.1-1% error rate)
        static let medium = NSColor(calibratedRed: 1.0, green: 0.65, blue: 0.0, alpha: 0.5)

        /// Q 30-39: Light green - good quality (0.01-0.1% error rate)
        static let good = NSColor(calibratedRed: 0.56, green: 0.93, blue: 0.56, alpha: 0.5)

        /// Q >= 40: Green - high quality (<0.01% error rate)
        static let high = NSColor(calibratedRed: 0.0, green: 0.67, blue: 0.0, alpha: 0.5)

        /// Returns the appropriate color for a given quality score.
        ///
        /// - Parameter score: Phred quality score (0-93)
        /// - Returns: Color indicating the quality level
        static func color(forScore score: UInt8) -> NSColor {
            switch score {
            case 0..<10:
                return veryLow
            case 10..<20:
                return low
            case 20..<30:
                return medium
            case 30..<40:
                return good
            default:
                return high
            }
        }
    }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
        setupDragAndDrop()
        setupAppearanceObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
        setupDragAndDrop()
        setupAppearanceObserver()
    }

    public override func setNeedsDisplay(_ invalidRect: NSRect) {
#if DEBUG
        testDisplayInvalidationCount += 1
#endif
        super.setNeedsDisplay(invalidRect)
    }

    func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sequence viewer")
        setAccessibilityIdentifier("sequence-viewer")
    }

    isolated deinit {
        stopDetachedEvidenceMonitors()
        trackLoadingAnimationTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func setupDragAndDrop() {
        // Register for file drops
        sequenceViewerLogger.info("SequenceViewerView.setupDragAndDrop: Registering for file URL drag type")
        registerForDraggedTypes([.fileURL])
        sequenceViewerLogger.info("SequenceViewerView.setupDragAndDrop: Registration complete")
    }

    /// Sets up observer for appearance change notifications.
    func setupAppearanceObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppearanceChanged(_:)),
            name: .appearanceChanged,
            object: nil
        )
        sequenceViewerLogger.debug("SequenceViewerView: Appearance change observer registered")
    }

    /// Handles appearance change notifications by reloading settings and redrawing.
    @objc func handleAppearanceChanged(_ notification: Notification) {
        // Reload appearance from centralized settings
        sequenceAppearance = AppSettings.shared.sequenceAppearance

        // Update track height from appearance settings
        trackHeight = sequenceAppearance.trackHeight
        sequenceViewerLogger.info("SequenceViewerView: Track height updated to \(self.trackHeight)")

        // Also update the header view track height
        viewController?.updateTrackHeights(sequenceAppearance.trackHeight)

        // Invalidate tile cache so annotation colors/dimensions are re-rendered
        invalidateAnnotationTile()

        needsDisplay = true
        sequenceViewerLogger.info("SequenceViewerView: Appearance changed, triggering redraw")
    }

    /// Starts/stops the loading-badge animation timer based on fetch state.
    func updateTrackLoadingAnimationState() {
        let shouldAnimate = isFetchingReads || isFetchingDepth
        if shouldAnimate {
            guard trackLoadingAnimationTimer == nil else { return }
            trackLoadingAnimationPhase = 0
            let timer = Timer(timeInterval: 1.0 / 18.0, repeats: true) { [weak self] _ in
                // Timer fires on RunLoop.main in .common modes — guaranteed main thread.
                // Use MainActor.assumeIsolated instead of Task { @MainActor in } to avoid
                // cooperative executor scheduling delays during AppKit layout-draw cycles.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.trackLoadingAnimationPhase += 0.34
                    if self.trackLoadingAnimationPhase > .pi * 2 {
                        self.trackLoadingAnimationPhase -= .pi * 2
                    }
                    self.setNeedsDisplay(self.bounds)
                }
            }
            trackLoadingAnimationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
            return
        }

        if let timer = trackLoadingAnimationTimer {
            timer.invalidate()
            trackLoadingAnimationTimer = nil
            trackLoadingAnimationPhase = 0
        }
    }

    @discardableResult
    func applyReadViewportPolicy(scale: Double) -> ReadTrackRenderer.ZoomTier {
        let tier = ReadViewportPolicy.zoomTier(scale: scale)
        _ = applyConsensusViewportPolicy(scale: scale)
        let enteringCoverage = tier == .coverage && lastRenderedReadTier != .coverage
        lastRenderedReadTier = tier

        guard enteringCoverage else { return tier }

        invalidateAlignmentFetchState(invalidateDepth: false, invalidateConsensus: false)
        return tier
    }

    /// Clears cached consensus state whenever the viewport is too wide to render bases.
    ///
    /// Consensus generation is proportional to genomic span, not read count. Keeping it
    /// enabled at whole-contig overview scales causes very large samtools outputs and
    /// expensive main-thread normalization work for data the UI cannot meaningfully show.
    @discardableResult
    func applyConsensusViewportPolicy(scale: Double) -> Bool {
        let allowsConsensus = showReads
            && showConsensusTrackSetting
            && scale < showLettersThreshold

        guard !allowsConsensus else { return true }

        guard cachedConsensusSequence != nil
            || cachedConsensusRegion != nil
            || !cachedConsensusOptionsSignature.isEmpty
            || isFetchingConsensus else {
            return false
        }

        consensusFetchGeneration += 1
        consensusFetchGate.invalidate()
        cachedConsensusSequence = nil
        cachedConsensusRegion = nil
        cachedConsensusOptionsSignature = ""
        isFetchingConsensus = false
        return false
    }

    func invalidateAlignmentFetchState() {
        invalidateAlignmentFetchState(invalidateDepth: true, invalidateConsensus: true)
    }

    func invalidateConsensusScientificRequest() {
        consensusFetchGeneration += 1
        consensusFetchGate.invalidate()
        cachedConsensusSequence = nil
        cachedConsensusRegion = nil
        cachedConsensusOptionsSignature = ""
        isFetchingConsensus = false
        needsDisplay = true
    }

    func resolvedConsensusScientificRegion() -> GenomicRegion? {
        guard let controller = viewController,
              let context = controller.alignmentActionContext,
              let resolved = try? controller.alignmentConsensusScope.resolve(
                in: context,
                selection: controller.explicitAlignmentSelection
              ) else { return nil }
        return .init(chromosome: resolved.contig, start: resolved.start, end: resolved.end)
    }

    func invalidateAlignmentFetchState(
        invalidateDepth: Bool,
        invalidateConsensus: Bool,
        preserveReadSelection: Bool = false
    ) {
        detachedReadFetchTask?.cancel()
        detachedReadFetchTask = nil
        detachedDepthFetchTask?.cancel()
        detachedDepthFetchTask = nil
        readFetchGeneration += 1
        readFetchGate.invalidate()
        cachedAlignedReads = []
        cachedReadRegion = nil
        cachedPackedReads = []
        cachedPackOverflow = 0
        cachedPackScale = 0
        cachedPackDataGeneration = -1
        cachedPackViewportStart = 0
        cachedPackViewportEnd = 0
        readContentHeight = 0
        readScrollOffset = 0
        isFetchingReads = false
        readFetchStartTime = nil
        hoveredRead = nil
        hoverTooltip.hide()

        if invalidateDepth {
            depthFetchGeneration += 1
            depthFetchGate.invalidate()
            cachedDepthPoints = []
            cachedDepthRegion = nil
            cachedCoverageStats = nil
            isFetchingDepth = false
            depthFetchStartTime = nil
        }

        if invalidateConsensus {
            consensusFetchGeneration += 1
            consensusFetchGate.invalidate()
            cachedConsensusSequence = nil
            cachedConsensusRegion = nil
            cachedConsensusOptionsSignature = ""
            isFetchingConsensus = false
        }

        activeAlignmentFetchIdentity = nil
        if !preserveReadSelection, !selectedReadIDs.isEmpty {
            selectedReadIDs.removeAll()
            NotificationCenter.default.post(name: .readSelected, object: self, userInfo: windowScopedUserInfo())
        }
        updateSelectionStatus()
    }

    func invalidateDetachedAlignmentFiltersPreservingSelection() {
        if preservedDetachedSelectionKeys.isEmpty {
            let identities = Self.detachedSelectionIdentities(for: cachedPackedReads.map(\.read))
            preservedDetachedSelectionKeys = Set(selectedReadIDs.compactMap { identities[$0] })
        }
        invalidateAlignmentFetchState(invalidateDepth: true, invalidateConsensus: true, preserveReadSelection: true)
    }

    private static func detachedSelectionIdentities(
        for reads: [AlignedRead]
    ) -> [UUID: DetachedAlignmentSelectionIdentity] {
        var occurrenceBySignature: [String: Int] = [:]
        var identities: [UUID: DetachedAlignmentSelectionIdentity] = [:]
        identities.reserveCapacity(reads.count)
        for read in reads {
            let signature = detachedSelectionSignature(read)
            let occurrence = occurrenceBySignature[signature, default: 0]
            occurrenceBySignature[signature] = occurrence + 1
            identities[read.id] = .init(signature: signature, occurrence: occurrence)
        }
        return identities
    }

    private static func detachedSelectionSignature(_ read: AlignedRead) -> String {
        let fields: [String] = [
            read.name, String(read.flag), read.chromosome, String(read.position), String(read.mapq),
            read.cigarString, read.sequence, read.qualities.map(String.init).joined(separator: ","),
            read.mateChromosome ?? "", read.matePosition.map(String.init) ?? "", String(read.insertSize),
            read.readGroup ?? "", read.mdTag ?? "", read.editDistance.map(String.init) ?? "",
            read.supplementaryAlignments ?? "", read.numHits.map(String.init) ?? "", read.strandTag ?? "",
        ]
        return fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private func updateDetachedSelection(_ ids: Set<UUID>) {
        guard selectedReadIDs != ids else { return }
        selectedReadIDs = ids
        NotificationCenter.default.post(
            name: .readSelected,
            object: self,
            userInfo: selectedRead.map { windowScopedUserInfo([NotificationUserInfoKey.alignedRead: $0]) ?? [:] }
        )
    }

    func readSettingsSignature() -> String {
        [
            showReads ? "reads=1" : "reads=0",
            "minMapQ=\(minMapQSetting)",
            "consensusMinMapQ=\(consensusMinMapQSetting)",
            "consensusMinBaseQ=\(consensusMinBaseQSetting)",
            "consensusMinDepth=\(consensusMinDepthSetting)",
            showConsensusTrackSetting ? "consensus=1" : "consensus=0",
            "consensusMode=\(consensusModeSetting.rawValue)",
            consensusUseAmbiguitySetting ? "ambiguity=1" : "ambiguity=0",
            "excludeFlags=\(excludeFlagsSetting)",
            limitReadRowsSetting ? "limitRows=1" : "limitRows=0",
            "readGroups=\(selectedReadGroupsSetting.sorted().joined(separator: ","))",
        ].joined(separator: "|")
    }

    func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]? = nil) -> [AnyHashable: Any]? {
        guard let windowStateScope else { return userInfo }
        var scopedUserInfo = userInfo ?? [:]
        scopedUserInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        return scopedUserInfo
    }

    func alignmentFetchIdentity(
        bundleURL: URL?,
        trackID: String?,
        region: GenomicRegion
    ) -> ViewerAlignmentFetchIdentity {
        ViewerAlignmentFetchIdentity(
            bundlePath: bundleURL?.standardizedFileURL.path,
            trackID: trackID,
            chromosome: region.chromosome,
            start: region.start,
            end: region.end,
            settingsSignature: readSettingsSignature()
        )
    }

    func beginReadFetch(
        bundleURL: URL?,
        trackID: String?,
        region: GenomicRegion
    ) -> AsyncRequestToken<ViewerAlignmentFetchIdentity> {
        let identity = alignmentFetchIdentity(bundleURL: bundleURL, trackID: trackID, region: region)
        activeAlignmentFetchIdentity = identity
        readFetchGeneration += 1
        isFetchingReads = true
        readFetchStartTime = Date()
        return readFetchGate.begin(identity: identity)
    }

    func beginDepthFetch(
        bundleURL: URL?,
        trackID: String?,
        region: GenomicRegion
    ) -> AsyncRequestToken<ViewerAlignmentFetchIdentity> {
        let identity = alignmentFetchIdentity(bundleURL: bundleURL, trackID: trackID, region: region)
        activeAlignmentFetchIdentity = identity
        depthFetchGeneration += 1
        isFetchingDepth = true
        depthFetchStartTime = Date()
        return depthFetchGate.begin(identity: identity)
    }

    func beginConsensusFetch(
        bundleURL: URL?,
        trackID: String?,
        region: GenomicRegion
    ) -> AsyncRequestToken<ViewerAlignmentFetchIdentity> {
        let identity = alignmentFetchIdentity(bundleURL: bundleURL, trackID: trackID, region: region)
        activeAlignmentFetchIdentity = identity
        consensusFetchGeneration += 1
        isFetchingConsensus = true
        return consensusFetchGate.begin(identity: identity)
    }

    @discardableResult
    func commitReadFetch(
        _ token: AsyncRequestToken<ViewerAlignmentFetchIdentity>,
        reads: [AlignedRead],
        region: GenomicRegion
    ) -> Bool {
        guard readFetchGate.isCurrent(token) else { return false }
        cachedAlignedReads = reads
        cachedReadRegion = region
        if reads.isEmpty, !preservedDetachedSelectionKeys.isEmpty {
            preservedDetachedSelectionKeys = []
            updateDetachedSelection([])
        }
        isFetchingReads = false
        readFetchStartTime = nil
        return true
    }

    @discardableResult
    func commitDepthFetch(
        _ token: AsyncRequestToken<ViewerAlignmentFetchIdentity>,
        points: [ReadTrackRenderer.CoveragePoint],
        region: GenomicRegion
    ) -> Bool {
        guard depthFetchGate.isCurrent(token) else { return false }
        cachedDepthPoints = points
        cachedDepthRegion = region
        cachedCoverageStats = ReadTrackRenderer.summarizeCoverage(
            depthPoints: points,
            regionStart: region.start,
            regionEnd: region.end
        )
        isFetchingDepth = false
        depthFetchStartTime = nil
        return true
    }

    @discardableResult
    func commitConsensusFetch(
        _ token: AsyncRequestToken<ViewerAlignmentFetchIdentity>,
        sequence: String?,
        region: GenomicRegion,
        optionsSignature: String
    ) -> Bool {
        guard consensusFetchGate.isCurrent(token) else { return false }
        cachedConsensusSequence = sequence
        cachedConsensusRegion = region
        cachedConsensusOptionsSignature = optionsSignature
        isFetchingConsensus = false
        return true
    }

#if DEBUG
    var testReadFetchGeneration: Int { readFetchGeneration }
    var testConsensusFetchGeneration: Int { consensusFetchGeneration }
    var testCachedAlignedReads: [AlignedRead] { cachedAlignedReads }
    var testCachedDepthPoints: [ReadTrackRenderer.CoveragePoint] { cachedDepthPoints }
    var testCachedConsensusSequence: String? { cachedConsensusSequence }
    var testCachedPackedReads: [(Int, AlignedRead)] { cachedPackedReads }
    var testCachedReadMismatchCache: ReadMismatchCache? { cachedReadMismatchCache }
    var testCachedPackedReadLayout: PackedReadLayout? { cachedPackedReadLayout }
    var testPackInvocationCount: Int { packInvocationCount }
    var testCachedReadSetGeneration: Int { cachedReadSetGeneration }
    var testHoveredRead: AlignedRead? { hoveredRead }
    var testSelectedReadIDs: Set<UUID> { selectedReadIDs }
    var testIsHoverTooltipHidden: Bool { hoverTooltip.isHidden }
    var testHoverTooltipText: String { hoverTooltip.currentText }
    var testSelectionStatusText: String? { currentSelectionStatusText() }
    var testVisibleAlignmentTrackIDSetting: String? { visibleAlignmentTrackIDSetting }
    var testIsFetchingReads: Bool { isFetchingReads }
    var testIsFetchingDepth: Bool { isFetchingDepth }
    var testIsFetchingConsensus: Bool { isFetchingConsensus }
    var testDetachedAlignmentSource: DetachedAlignmentSource? { detachedAlignmentSource }
    var testDetachedEvidenceMonitorEventCount: Int { detachedEvidenceMonitorEventCount }
    var testDetachedEvidenceFetchMessage: String? { detachedEvidenceFetchMessage }

    func testInstallDetachedAlignmentFetchTasks(read: Task<Void, Never>?, depth: Task<Void, Never>?) {
        detachedReadFetchTask = read
        detachedDepthFetchTask = depth
    }

    func testSetUserSelectionRange(_ range: Range<Int>) {
        selectionRange = range
        selectionStartBase = range.lowerBound
        isSelecting = false
        isUserColumnSelection = true
        setNeedsDisplay(bounds)
        updateSelectionStatus()
    }

    static func horizontalPanAmountForTesting(
        deltaX: CGFloat,
        scale: Double,
        hasPreciseScrollingDeltas: Bool,
        preference: ScrollDirectionPreference,
        isDirectionInvertedFromDevice: Bool
    ) -> Double {
        horizontalPanAmount(
            deltaX: deltaX,
            scale: scale,
            hasPreciseScrollingDeltas: hasPreciseScrollingDeltas,
            preference: preference,
            isDirectionInvertedFromDevice: isDirectionInvertedFromDevice
        )
    }

    static func effectiveHorizontalScrollDirectionForTesting(
        bundleOverride: ScrollDirectionPreference?,
        globalPreference: ScrollDirectionPreference
    ) -> ScrollDirectionPreference {
        effectiveHorizontalScrollDirection(
            bundleOverride: bundleOverride,
            globalPreference: globalPreference
        )
    }

    static func pinchZoomFactorForTesting(magnification: CGFloat) -> Double {
        pinchZoomFactor(magnification: magnification)
    }

    func testSetCachedAlignedReads(_ reads: [AlignedRead]) {
        cachedAlignedReads = reads
    }

    var testReadContentHeight: CGFloat { readContentHeight }

    var testLastRenderedReadY: CGFloat { lastRenderedReadY }

    func testReadAtPoint(_ point: NSPoint) -> AlignedRead? {
        readAtPoint(point)
    }

    func testSetCachedPackedReads(_ rows: [(Int, AlignedRead)]) {
        cachedPackedReads = rows
    }

    func testSetLastRenderedReadTier(_ tier: ReadTrackRenderer.ZoomTier) {
        lastRenderedReadTier = tier
    }

    func testSetHoveredRead(_ read: AlignedRead?) {
        hoveredRead = read
    }

    func testSetSelectedReadIDs(_ ids: Set<UUID>) {
        selectedReadIDs = ids
    }

    var testSelectedReads: [AlignedRead] { selectedReads }

    /// Test seam for the read-track right-click context menu, bypassing
    /// `NSEvent`/pixel hit-testing. Pass the `AlignedRead` the test wants to
    /// simulate a right-click landing on (or `nil` to simulate a miss).
    /// Mirrors the selection-update + menu-build logic in
    /// `buildReadContextMenu(for:)`.
    func testBuildReadContextMenu(forRead read: AlignedRead?) -> NSMenu? {
        buildReadContextMenu(for: read)
    }

    func testBuildContextMenu(
        for target: SequenceViewerContextTarget,
        genomicPosition: Int,
        clickedTrackIndex: Int? = nil
    ) -> NSMenu {
        contextMenuGenomicPosition = genomicPosition
        return buildContextMenu(for: target, clickedTrackIndex: clickedTrackIndex)
    }

    /// Test seam for "Copy as FASTA (aligned orientation)" without going
    /// through the real `NSPasteboard.general` (which is process-global and
    /// would make tests order-dependent). Writes to the pasteboard argument.
    func testCopySelectedReadsAsFASTA(to pasteboard: NSPasteboard) {
        copySelectedReadsAsFASTA(to: pasteboard)
    }

    func testShowHoverTooltip(text: String) {
        hoverTooltip.show(text: text, near: NSPoint(x: 20, y: 20), in: self)
    }

    func testApplyReadViewportPolicy(scale: Double) -> ReadTrackRenderer.ZoomTier {
        applyReadViewportPolicy(scale: scale)
    }

    func testInvalidateAlignmentFetchState(bundleURL: URL?, trackID: String?, region: GenomicRegion) {
        activeAlignmentFetchIdentity = alignmentFetchIdentity(bundleURL: bundleURL, trackID: trackID, region: region)
        invalidateAlignmentFetchState()
    }

    func testBeginReadFetch(bundleURL: URL?, trackID: String?, region: GenomicRegion) -> AsyncRequestToken<ViewerAlignmentFetchIdentity> {
        beginReadFetch(bundleURL: bundleURL, trackID: trackID, region: region)
    }

    func testBeginDepthFetch(bundleURL: URL?, trackID: String?, region: GenomicRegion) -> AsyncRequestToken<ViewerAlignmentFetchIdentity> {
        beginDepthFetch(bundleURL: bundleURL, trackID: trackID, region: region)
    }

    func testBeginConsensusFetch(bundleURL: URL?, trackID: String?, region: GenomicRegion) -> AsyncRequestToken<ViewerAlignmentFetchIdentity> {
        beginConsensusFetch(bundleURL: bundleURL, trackID: trackID, region: region)
    }

    @discardableResult
    func testCommitReadFetch(
        _ token: AsyncRequestToken<ViewerAlignmentFetchIdentity>,
        reads: [AlignedRead],
        region: GenomicRegion
    ) -> Bool {
        commitReadFetch(token, reads: reads, region: region)
    }

    @discardableResult
    func testCommitDepthFetch(
        _ token: AsyncRequestToken<ViewerAlignmentFetchIdentity>,
        points: [ReadTrackRenderer.CoveragePoint],
        region: GenomicRegion
    ) -> Bool {
        commitDepthFetch(token, points: points, region: region)
    }

    @discardableResult
    func testCommitConsensusFetch(
        _ token: AsyncRequestToken<ViewerAlignmentFetchIdentity>,
        sequence: String,
        region: GenomicRegion
    ) -> Bool {
        commitConsensusFetch(
            token,
            sequence: sequence,
            region: region,
            optionsSignature: currentConsensusOptionsSignature()
        )
    }
#endif

    // MARK: - Data Setters

    func setSequence(_ seq: Sequence) {
        sequenceViewerLogger.info("SequenceViewerView.setSequence: Setting sequence '\(seq.name, privacy: .public)' length=\(seq.length)")
        if sequence?.id != seq.id {
            // Translation overlays are tied to a specific sequence context.
            hideTranslation()
        }
        self.sequence = seq
        sequenceViewerLogger.info("SequenceViewerView.setSequence: self.sequence is now \(self.sequence == nil ? "nil" : "SET", privacy: .public)")

        // Request immediate display refresh
        needsDisplay = true

        // If bounds are not valid yet, schedule a redraw after layout
        if bounds.width <= 0 || bounds.height <= 0 {
            sequenceViewerLogger.info("SequenceViewerView.setSequence: bounds not ready (\(self.bounds.width)x\(self.bounds.height)), scheduling delayed redraw")
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.needsDisplay = true
                    sequenceViewerLogger.info("SequenceViewerView.setSequence: Delayed redraw triggered, bounds=\(self.bounds.width)x\(self.bounds.height)")
                }
            }
        }

        sequenceViewerLogger.info("SequenceViewerView.setSequence: Requested display refresh, bounds=\(self.bounds.width, privacy: .public)x\(self.bounds.height, privacy: .public)")
    }

    func setAnnotations(_ annots: [SequenceAnnotation]) {
        sequenceViewerLogger.info("SequenceViewerView.setAnnotations: Setting \(annots.count) annotations")
        self.annotations = annots

        // Update multi-sequence state with annotations if in multi-sequence mode
        if isMultiSequenceMode {
            updateMultiSequenceAnnotations(annots)
            sequenceViewerLogger.debug("SequenceViewerView.setAnnotations: Updated multi-sequence annotations")
        }

        // Clear selection if the selected annotation is no longer in the list
        if let selected = selectedAnnotation,
           !annots.contains(where: { $0.id == selected.id }) {
            selectedAnnotation = nil
        }
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        sequenceViewerLogger.debug("SequenceViewerView.setAnnotations: Requested display refresh")
    }

    /// Updates a single annotation in-place (both document and bundle caches).
    ///
    /// Used when the inspector changes an annotation's color, name, or other properties.
    /// Handles both document mode (`annotations`) and bundle mode (`cachedBundleAnnotations`).
    func updateAnnotation(_ annotation: SequenceAnnotation) {
        var updated = false

        // Update in document-mode annotations
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
            annotations[index] = annotation
            updated = true
        }

        // Update in bundle-mode cached annotations
        if let index = cachedBundleAnnotations.firstIndex(where: { $0.id == annotation.id }) {
            cachedBundleAnnotations[index] = annotation
            updated = true
        }

        // Update in variant annotations
        if let index = cachedVariantAnnotations.firstIndex(where: { $0.id == annotation.id }) {
            cachedVariantAnnotations[index] = annotation
            updated = true
        }

        if updated {
            // Persist per-annotation color override to BundleViewState
            if let color = annotation.color, let vc = viewController {
                let key = annotation.colorOverrideKey
                var state = vc.currentBundleViewState ?? .default
                state.annotationColorOverrides[key] = color
                vc.currentBundleViewState = state
                vc.scheduleViewStateSave()
            }

            invalidateAnnotationTile()
            setNeedsDisplay(bounds)
        }
    }

    /// Applies a color to all annotations of a given type (both document and bundle caches).
    ///
    /// Used when the inspector applies a color to all annotations of a specific type.
    func applyColorToType(_ type: AnnotationType, color: AnnotationColor) {
        var updatedCount = 0

        // Update in document-mode annotations
        for (index, annotation) in annotations.enumerated() where annotation.type == type {
            var updated = annotation
            updated.color = color
            annotations[index] = updated
            updatedCount += 1
        }

        // Update in bundle-mode cached annotations
        for (index, annotation) in cachedBundleAnnotations.enumerated() where annotation.type == type {
            var updated = annotation
            updated.color = color
            cachedBundleAnnotations[index] = updated
            updatedCount += 1
        }

        if updatedCount > 0 {
            // Clear CGColor caches since type colors changed
            typeColorCache.removeAll()
            typeDensityColorCache.removeAll()
            invalidateAnnotationTile()
            setNeedsDisplay(bounds)
            sequenceViewerLogger.info("applyColorToType: Updated \(updatedCount) \(type.rawValue) annotations")
        }

        // Propagate to bundle view state for persistence
        if let vc = viewController {
            var state = vc.currentBundleViewState ?? .default
            state.typeColorOverrides[type] = color
            vc.currentBundleViewState = state
            vc.scheduleViewStateSave()
        }
    }

    /// Applies per-type color overrides from a saved view state.
    ///
    /// Pre-populates the type color caches so that annotations of the given types
    /// render with the override color instead of the default. The color resolution
    /// order remains: per-annotation color > per-type override > default type color.
    func applyTypeColorOverrides(_ overrides: [AnnotationType: AnnotationColor]) {
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()

        for (type, color) in overrides {
            let nsColor = NSColor(
                calibratedRed: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: 1.0
            )
            let fill = nsColor.withAlphaComponent(0.7).cgColor
            let stroke = nsColor.cgColor
            typeColorCache[type] = (fill, stroke)

            let density = nsColor.withAlphaComponent(0.6).cgColor
            typeDensityColorCache[type] = density
        }

        invalidateAnnotationTile()
    }

    /// Resets all type color caches to empty (causes rebuild from defaults on next draw).
    func resetTypeColorCaches() {
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()
        invalidateAnnotationTile()
        needsDisplay = true
    }

    /// Strips per-annotation custom colors from all cached annotations (used on reset).
    func clearAnnotationColorOverrides() {
        for i in cachedBundleAnnotations.indices {
            cachedBundleAnnotations[i].color = nil
        }
        for i in annotations.indices {
            annotations[i].color = nil
        }
        invalidateAnnotationTile()
        needsDisplay = true
    }

    // MARK: - Translation Track Control

    static func storedAnnotationTranslationResult(for annotation: SequenceAnnotation) -> TranslationResult? {
        guard annotation.type == .orf || annotation.type == .translation,
              let rawProtein = annotation.qualifier("translation")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawProtein.isEmpty else {
            return nil
        }

        let tableID = annotation.qualifier("genetic_code_table").flatMap(Int.init)
        let codonTable = tableID.flatMap(CodonTable.table(id:)) ?? .standard
        let codingCoordinates = codingCoordinateOrder(for: annotation)
        let protein = rawProtein
        var aminoAcidPositions: [AminoAcidPosition] = []

        for (aaIndex, aminoAcid) in protein.enumerated() {
            let codonCoordinates = Array(codingCoordinates.dropFirst(aaIndex * 3).prefix(3))
            guard !codonCoordinates.isEmpty else { break }
            aminoAcidPositions.append(
                AminoAcidPosition(
                    index: aaIndex,
                    aminoAcid: aminoAcid,
                    codon: String(repeating: "N", count: codonCoordinates.count),
                    genomicRanges: genomicRanges(forCodingCoordinates: codonCoordinates),
                    isStart: aaIndex == 0 && aminoAcid == "M",
                    isStop: aminoAcid == "*"
                )
            )
        }

        guard !aminoAcidPositions.isEmpty else { return nil }
        return TranslationResult(
            protein: protein,
            codingSequence: String(repeating: "N", count: min(codingCoordinates.count, protein.count * 3)),
            aminoAcidPositions: aminoAcidPositions,
            codonTable: codonTable,
            phaseOffset: annotation.intervals.first?.phase ?? 0
        )
    }

    static func codingCoordinateOrder(for annotation: SequenceAnnotation) -> [Int] {
        if annotation.strand == .reverse {
            return annotation.intervals
                .sorted { $0.start > $1.start }
                .flatMap { interval in Array((interval.start..<interval.end).reversed()) }
        }

        return annotation.intervals
            .sorted { $0.start < $1.start }
            .flatMap { interval in Array(interval.start..<interval.end) }
    }

    static func genomicRanges(forCodingCoordinates coordinates: [Int]) -> [GenomicRange] {
        let sorted = coordinates.sorted()
        guard var rangeStart = sorted.first else { return [] }
        var previous = rangeStart
        var ranges: [GenomicRange] = []

        for coordinate in sorted.dropFirst() {
            if coordinate == previous + 1 {
                previous = coordinate
            } else {
                ranges.append(GenomicRange(start: rangeStart, end: previous + 1))
                rangeStart = coordinate
                previous = coordinate
            }
        }
        ranges.append(GenomicRange(start: rangeStart, end: previous + 1))
        return ranges
    }

    /// Shows a CDS translation track for the given annotation.
    ///
    /// Computes the translation using `TranslationEngine.translateCDS()` with the
    /// sequence data from the current bundle or loaded sequence. The translation result
    /// is cached in `activeTranslationResult` and the track is made visible.
    ///
    /// - Parameter annotation: The CDS/mRNA annotation to translate.
    func showCDSTranslation(for annotation: SequenceAnnotation) {
        // Build a sequence provider from the available data source
        let sequenceProvider: (Int, Int) -> String?
        if let bundle = currentReferenceBundle {
            // Bundle mode: use sync sequence fetch
            sequenceProvider = { start, end in
                let region = GenomicRegion(
                    chromosome: annotation.chromosome ?? bundle.chromosomeNames.first ?? "",
                    start: start, end: end
                )
                return try? bundle.fetchSequenceSync(region: region)
            }
        } else if let seq = sequence {
            // Single-sequence mode: extract from loaded sequence
            sequenceProvider = { start, end in
                let clampedStart = max(0, start)
                let clampedEnd = min(seq.length, end)
                guard clampedStart < clampedEnd else { return nil }
                return seq[clampedStart..<clampedEnd]
            }
        } else {
            sequenceViewerLogger.warning("showCDSTranslation: No sequence data available")
            return
        }

        guard let result = TranslationEngine.translateCDS(
            annotation: annotation,
            sequenceProvider: sequenceProvider
        ) else {
            sequenceViewerLogger.warning("showCDSTranslation: translateCDS returned nil for '\(annotation.name, privacy: .public)'")
            return
        }

        activeTranslationResult = result
        frameTranslationFrames = []
        showTranslationTrack = true
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        sequenceViewerLogger.info("showCDSTranslation: Showing translation for '\(annotation.name, privacy: .public)' (\(result.protein.count) aa)")
    }

    /// Hides the translation track and clears all translation state.
    func hideTranslation() {
        guard showTranslationTrack else { return }
        showTranslationTrack = false
        activeTranslationResult = nil
        frameTranslationFrames = []
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        sequenceViewerLogger.info("hideTranslation: Translation track hidden")
    }

    /// Hides only the CDS translation, preserving any active frame translation.
    ///
    /// Use this when the user explicitly hides a CDS translation from the inspector.
    /// If frame translation is also active, the translation track remains visible.
    func hideCDSTranslation() {
        guard activeTranslationResult != nil else { return }
        activeTranslationResult = nil
        if frameTranslationFrames.isEmpty {
            showTranslationTrack = false
        }
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        sequenceViewerLogger.info("hideCDSTranslation: CDS translation cleared")
    }

    /// Clears cached genotype rendering data so the next draw refetches using current display state.
    func clearGenotypeCache() {
        genotypeFetchGeneration += 1
        cachedGenotypeData = nil
        cachedGenotypeSampleDisplayNames = [:]
        cachedGenotypeRegion = nil
        isFetchingGenotypes = false
        invalidateGutterWidth()
    }

    /// Enables multi-frame translation mode for the specified reading frames.
    ///
    /// Translates the visible nucleotide sequence on-the-fly in each specified frame.
    /// This replaces any active CDS translation.
    ///
    /// - Parameters:
    ///   - frames: The reading frames to display (e.g., `ReadingFrame.forwardFrames`).
    ///   - table: The codon table to use.
    func applyFrameTranslation(frames: [ReadingFrame], table: CodonTable = .standard) {
        activeTranslationResult = nil
        frameTranslationFrames = frames
        frameTranslationTable = table
        showTranslationTrack = !frames.isEmpty
        invalidateAnnotationTile()
        setNeedsDisplay(bounds)
        sequenceViewerLogger.info("applyFrameTranslation: \(frames.count) frames, table=\(table.shortName, privacy: .public)")
    }

    /// Sets a reference bundle for display.
    ///
    /// When a reference bundle is set, the viewer fetches sequence and annotation
    /// data on-demand using the bundle's indexed readers for efficient random access.
    ///
    /// - Parameter bundle: The ReferenceBundle to display
    func setReferenceBundle(_ bundle: ReferenceBundle) {
        sequenceViewerLogger.info("SequenceViewerView.setReferenceBundle: Setting bundle '\(bundle.name, privacy: .public)'")

        let previousBundleURL = currentReferenceBundle?.url.standardizedFileURL
        let nextBundleURL = bundle.url.standardizedFileURL
        let shouldPreserveLocalRenderFilters = previousBundleURL == nextBundleURL
        let previousLocalAnnotationRenderFilterKeys = localAnnotationRenderFilterKeys
        let previousLocalVariantRenderFilterKeys = localVariantRenderFilterKeys

        annotationFetchGeneration += 1
        variantFetchGeneration += 1

        // Store the bundle reference
        self.detachedAlignmentSource = nil
        self.currentReferenceBundle = bundle

        // Clear any existing sequence/annotations since we'll fetch on-demand
        self.sequence = nil
        self.annotations = []

        // Clear cached bundle data
        self.cachedBundleSequence = nil
        self.cachedSequenceRegion = nil
        self.cachedBundleAnnotations = []
        self.cachedAnnotationRegion = nil
        self.cachedVariantAnnotations = []
        self.cachedVariantRegion = nil
        self.cachedCDSTranslations = [:]
        self.cachedCDSCodingContexts = [:]
        self.localAnnotationRenderFilterKeys = shouldPreserveLocalRenderFilters ? previousLocalAnnotationRenderFilterKeys : nil
        self.localVariantRenderFilterKeys = shouldPreserveLocalRenderFilters ? previousLocalVariantRenderFilterKeys : nil
        self.invalidateFilteredVariantCache()
        self.isFetchingBundleData = false
        self.isFetchingAnnotations = false
        self.isFetchingVariants = false
        self.sequenceFetchStartTime = nil
        self.annotationFetchStartTime = nil
        self.bundleFetchError = nil
        self.failedFetchRegion = nil

        // Clear genotype track state
        self.cachedGenotypeData = nil
        self.cachedGenotypeSampleDisplayNames = [:]
        self.cachedGenotypeRegion = nil
        self.isFetchingGenotypes = false
        self.genotypeScrollOffset = 0
        self.invalidateGutterWidth()

        // Clear read alignment state
        self.cachedAlignedReads = []
        self.cachedReadRegion = nil
        self.cachedDepthPoints = []
        self.cachedDepthRegion = nil
        self.cachedConsensusSequence = nil
        self.cachedConsensusRegion = nil
        self.cachedConsensusOptionsSignature = ""
        self.cachedCoverageStats = nil
        self.isFetchingReads = false
        self.isFetchingDepth = false
        self.isFetchingConsensus = false
        self.readFetchStartTime = nil
        self.depthFetchStartTime = nil
        self.readFetchGeneration = 0
        self.depthFetchGeneration = 0
        self.consensusFetchGeneration = 0
        self.readFetchGate.invalidate()
        self.depthFetchGate.invalidate()
        self.consensusFetchGate.invalidate()
        self.activeAlignmentFetchIdentity = nil
        self.lastVariantBottomY = 0
        self.alignmentChromosomeAliasMap = [:]
        self.cachedPackedReads = []
        self.cachedPackOverflow = 0
        self.cachedPackScale = 0
        self.cachedPackDataGeneration = -1
        self.cachedPackViewportStart = 0
        self.cachedPackViewportEnd = 0
        self.readScrollOffset = 0
        self.readContentHeight = 0

        // Cache sample count and build a fast chromosome alias map from variant databases.
        // Skip expensive MAX(position) scans on the main thread; those are warmed asynchronously.
        self.cachedSampleCount = 0
        self.variantChromosomeAliasMap = [:]
        self.variantTrackChromosomeMap = [:]
        for trackId in bundle.variantTrackIds {
            if let trackInfo = bundle.variantTrack(id: trackId),
               let dbPath = trackInfo.databasePath,
               let dbURL = try? bundle.memberURL(
                   for: dbPath,
                   field: "variants[\(trackId)].databasePath"
               ) {
                if let db = try? VariantDatabase(url: dbURL) {
                    let count = db.sampleCount()
                    if count > 0 {
                        self.cachedSampleCount = max(self.cachedSampleCount, count)
                        sequenceViewerLogger.info("SequenceViewerView.setReferenceBundle: Found \(count) samples in variant track '\(trackId, privacy: .public)'")
                    }

                    let trackChromosomes = Set(db.allChromosomes())
                    self.variantTrackChromosomeMap[trackId] = trackChromosomes

                    // Fast path: name/alias/contig-length matching only.
                    let aliasMap = Self.buildVariantChromosomeAliasMap(
                        bundleChromosomes: bundle.manifest.genome?.chromosomes ?? [],
                        variantDB: db,
                        sequenceViewerLogger: sequenceViewerLogger,
                        includeMaxPositionFallback: false
                    )
                    if !aliasMap.isEmpty {
                        for (refChrom, dbChrom) in aliasMap where self.variantChromosomeAliasMap[refChrom] == nil {
                            self.variantChromosomeAliasMap[refChrom] = dbChrom
                        }
                    }
                }
            }
        }
        if let vc = self.viewController {
            vc.annotationDrawerView?.variantChromosomeAliasMap = self.variantChromosomeAliasMap
        }

        // Warm expensive length-from-positions alias inference in the background so bundle
        // selection returns immediately even for very large variant databases.
        Self.warmVariantChromosomeAliasesAsync(
            bundle: bundle,
            initialAliasMap: self.variantChromosomeAliasMap
        ) { [weak self] mergedAliasMap in
            guard let self else { return }
            guard self.currentReferenceBundle?.url.standardizedFileURL == bundle.url.standardizedFileURL else { return }
            self.variantChromosomeAliasMap = mergedAliasMap
            if let vc = self.viewController {
                vc.annotationDrawerView?.variantChromosomeAliasMap = mergedAliasMap
            }
        }

        // Initialize alignment data providers from bundle manifest
        self.alignmentDataProviders = []
        for trackId in bundle.alignmentTrackIds {
            if let trackInfo = bundle.alignmentTrack(id: trackId),
               let resolvedPath = try? bundle.resolveAlignmentPath(trackInfo),
               let resolvedIndexPath = try? bundle.resolveAlignmentIndexPath(trackInfo) {
                let provider = AlignmentDataProvider(
                    alignmentPath: resolvedPath,
                    indexPath: resolvedIndexPath,
                    format: trackInfo.format,
                    referenceFastaPath: bundle.referenceFASTAPath()
                )
                self.alignmentDataProviders.append((trackId, provider))
                sequenceViewerLogger.info("SequenceViewerView.setReferenceBundle: Initialized alignment provider for '\(trackInfo.name, privacy: .public)'")
            }
        }

        // Build alignment chromosome alias map from metadata databases
        if !alignmentDataProviders.isEmpty {
            self.alignmentChromosomeAliasMap = Self.buildAlignmentChromosomeAliasMap(
                bundleChromosomes: bundle.manifest.genome?.chromosomes ?? [],
                alignmentTracks: bundle.manifest.alignments,
                bundleURL: bundle.url,
                sequenceViewerLogger: sequenceViewerLogger
            )
        }

        // Clear rendering caches
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()
        invalidateAnnotationTile()

        // Clear translation track state
        showTranslationTrack = false
        activeTranslationResult = nil
        frameTranslationFrames = []

        // Clear multi-sequence state if active
        if isMultiSequenceMode {
            clearSequences()
        }

        // Request display refresh - drawing will fetch data based on visible region
        needsDisplay = true

        sequenceViewerLogger.info("SequenceViewerView.setReferenceBundle: Bundle set, ready for on-demand fetching")
    }

    /// Keeps extraction selection synchronized to the currently visible viewport.
    ///
    /// Dynamic freehand region selection is intentionally disabled; extraction always operates
    /// on the visible region (or a selected annotation via annotation menus).
    func ensureVisibleViewportSelection(frame: ReferenceFrame) {
        // Do not overwrite a user-initiated column selection
        guard !isUserColumnSelection else { return }

        let lower = max(0, Int(frame.start))
        let upper = max(lower + 1, Int(ceil(frame.end)))
        let viewportRange = lower..<upper
        guard selectionRange != viewportRange else { return }
        selectionRange = viewportRange
        selectionStartBase = lower
        isSelecting = false
    }

    /// Clears the current reference bundle.
    func clearReferenceBundle() {
        sequenceViewerLogger.info("SequenceViewerView.clearReferenceBundle: Clearing bundle")
        cancelDetachedAlignmentFetches()
        stopDetachedEvidenceMonitors()
        // Semantic selection keys are valid only for the source whose filter
        // update captured them. A source replacement or explicit clear must
        // never restore a coincidentally identical read from later evidence.
        preservedDetachedSelectionKeys = []
        updateDetachedSelection([])
        self.currentReferenceBundle = nil
        self.detachedAlignmentSource = nil
        self.detachedEvidenceStaleReason = nil
        self.detachedResourceSignatures = [:]
        self.detachedEvidenceFetchMessage = nil
        self.cachedBundleSequence = nil
        self.cachedSequenceRegion = nil
        self.cachedBundleAnnotations = []
        self.cachedAnnotationRegion = nil
        self.cachedVariantAnnotations = []
        self.cachedVariantRegion = nil
        self.cachedCDSTranslations = [:]
        self.cachedCDSCodingContexts = [:]
        self.localAnnotationRenderFilterKeys = nil
        self.localVariantRenderFilterKeys = nil
        self.invalidateFilteredVariantCache()
        self.cachedGenotypeData = nil
        self.cachedGenotypeSampleDisplayNames = [:]
        self.cachedGenotypeRegion = nil
        self.invalidateGutterWidth()
        self.cachedAlignedReads = []
        self.cachedReadRegion = nil
        self.cachedDepthPoints = []
        self.cachedDepthRegion = nil
        self.cachedConsensusSequence = nil
        self.cachedConsensusRegion = nil
        self.cachedConsensusOptionsSignature = ""
        self.cachedCoverageStats = nil
        self.isFetchingBundleData = false
        self.isFetchingAnnotations = false
        self.isFetchingVariants = false
        self.isFetchingGenotypes = false
        self.isFetchingReads = false
        self.isFetchingDepth = false
        self.isFetchingConsensus = false
        self.readFetchStartTime = nil
        self.depthFetchStartTime = nil
        self.readFetchGeneration = 0
        self.depthFetchGeneration = 0
        self.consensusFetchGeneration = 0
        self.readFetchGate.invalidate()
        self.depthFetchGate.invalidate()
        self.consensusFetchGate.invalidate()
        self.activeAlignmentFetchIdentity = nil
        self.cachedSampleCount = 0
        self.variantChromosomeAliasMap = [:]
        self.variantTrackChromosomeMap = [:]
        self.alignmentChromosomeAliasMap = [:]
        self.alignmentDataProviders = []
        self.visibleAlignmentTrackIDSetting = nil
        self.sequenceFetchStartTime = nil
        self.annotationFetchStartTime = nil

        // Clear rendering caches
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()
        invalidateAnnotationTile()

        needsDisplay = true
    }

    func cancelDetachedAlignmentFetches() {
        detachedReadFetchTask?.cancel()
        detachedReadFetchTask = nil
        detachedDepthFetchTask?.cancel()
        detachedDepthFetchTask = nil
    }

    /// Configures the existing alignment renderer for an externally-owned final BAM.
    /// This creates no bundle, writes no data, and intentionally leaves annotations
    /// and reference-dependent data absent when no validated FASTA was supplied.
    @discardableResult
    func setDetachedAlignmentSource(_ source: DetachedAlignmentSource) -> Bool {
        clearReferenceBundle()
        // The App-owned validator has already compared full checksums on a
        // background executor. Do not repeat that O(file size) work on the
        // main actor here: a large BAM would freeze the entire window. Vnode
        // monitors take ownership before the source is exposed and validate
        // subsequent changes off-main.
        guard startDetachedEvidenceMonitors(for: source) else {
            markDetachedEvidenceStale("Classifier alignment evidence is unavailable for monitoring.")
            return false
        }
        currentReferenceBundle = nil
        detachedAlignmentSource = source
        detachedEvidenceStaleReason = nil
        detachedEvidenceFetchMessage = nil
        alignmentDataProviders = [(trackId: "detached", provider: source.provider)]
        visibleAlignmentTrackIDSetting = "detached"
        // Establish the initial cheap signatures off the main actor as well.
        // Until it completes, fetch paths conservatively treat the evidence as
        // pending instead of trusting a source that could have changed during
        // the handoff from validation to monitor activation.
        scheduleDetachedEvidenceMonitorCheck(generation: detachedEvidenceMonitorGeneration)
        alignmentChromosomeAliasMap = [:]
        if let reference = source.referenceSequence {
            cachedBundleSequence = reference
            cachedSequenceRegion = GenomicRegion(chromosome: source.contig.name, start: 0, end: source.contig.length)
        }
        invalidateAlignmentFetchState()
        needsDisplay = true
        return true
    }

    func detachedEvidenceIsCurrent(_ source: DetachedAlignmentSource) -> Bool {
        guard detachedEvidenceStaleReason == nil else { return false }
        let expectedSnapshots = expectedSnapshots(for: source)
        // An unchanged size/mtime is only a cheap fallback signal. Identity is
        // established by the installation hash and maintained by vnode events.
        guard expectedSnapshots.isEmpty || detachedEvidenceMonitorSources.count == expectedSnapshots.count else {
            markDetachedEvidenceStale("Classifier alignment evidence monitor stopped unexpectedly.")
            return false
        }
        for (url, _) in expectedSnapshots {
            let fast = resourceSignature(for: url)
            guard let prior = detachedResourceSignatures[url], prior.0 == fast.0 && prior.1 == fast.1 else {
                // Hashing a multi-gigabyte evidence BAM is intentionally never
                // performed from an AppKit draw/fetch path. Keep this request
                // pending while the monitor verifies the change off-main.
                scheduleDetachedEvidenceMonitorCheck(generation: detachedEvidenceMonitorGeneration)
                return false
            }
        }
        return true
    }

    func markDetachedEvidenceStale(_ reason: String) {
        detachedEvidenceStaleReason = reason
        stopDetachedEvidenceMonitors()
        cancelDetachedAlignmentFetches()
        invalidateAlignmentFetchState()
        onDetachedEvidenceStale?(reason)
        needsDisplay = true
    }

    private func startDetachedEvidenceMonitors(for source: DetachedAlignmentSource) -> Bool {
        stopDetachedEvidenceMonitors()
        let snapshots = expectedSnapshots(for: source)
        guard !snapshots.isEmpty else { return true }
        detachedEvidenceMonitorGeneration += 1
        let generation = detachedEvidenceMonitorGeneration
        for (url, _) in snapshots {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else {
                stopDetachedEvidenceMonitors()
                return false
            }
            let monitor = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke],
                queue: .main
            )
            monitor.setEventHandler { [weak self] in
                self?.scheduleDetachedEvidenceMonitorCheck(generation: generation)
            }
            monitor.setCancelHandler { close(descriptor) }
            detachedEvidenceMonitorSources.append(monitor)
            monitor.resume()
        }
        return true
    }

    private func stopDetachedEvidenceMonitors() {
        detachedEvidenceMonitorGeneration += 1
        detachedEvidenceHashInFlight = false
        detachedEvidenceMonitorSources.forEach { $0.cancel() }
        detachedEvidenceMonitorSources.removeAll()
    }

    private func scheduleDetachedEvidenceMonitorCheck(generation: Int) {
        guard generation == detachedEvidenceMonitorGeneration,
              let source = detachedAlignmentSource else { return }
#if DEBUG
        detachedEvidenceMonitorEventCount += 1
#endif
        guard !detachedEvidenceHashInFlight else { return }
        detachedEvidenceHashInFlight = true
        let identityURL = source.identityURL
        let checks = expectedSnapshots(for: source).map { DetachedEvidenceSnapshotCheck(url: $0.0, expected: $0.1) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let mismatch = checks.first { check in
                return (try? Self.checksumSnapshot(check.url)) != check.expected
            }
            DispatchQueue.main.async {
                self?.applyDetachedEvidenceMonitorCheck(
                    generation: generation,
                    identityURL: identityURL,
                    checks: checks,
                    mismatchURL: mismatch?.url
                )
            }
        }
    }

    private func applyDetachedEvidenceMonitorCheck(
        generation: Int,
        identityURL: URL,
        checks: [DetachedEvidenceSnapshotCheck],
        mismatchURL: URL?
    ) {
        guard generation == detachedEvidenceMonitorGeneration,
              detachedAlignmentSource?.identityURL == identityURL else { return }
        detachedEvidenceHashInFlight = false
        if let mismatchURL {
            markDetachedEvidenceStale("Classifier alignment evidence changed on disk: \(mismatchURL.lastPathComponent).")
            return
        }
        for check in checks { detachedResourceSignatures[check.url] = resourceSignature(for: check.url) }
        // The draw path treated the evidence as pending while this check ran
        // (and drew the "unavailable" badge). Redraw now that the signatures
        // are established — without this the badge sticks until an unrelated
        // redraw (observed with the 240MB EsViritu reference, whose first
        // checksum outlives the initial draw). Only a redraw: cancelling or
        // invalidating fetch state here would tear down fetches that started
        // legitimately while the checksum was still running.
        needsDisplay = true
    }

    private func expectedSnapshots(for source: DetachedAlignmentSource) -> [(URL, ClassifierAlignmentEvidenceFileSnapshot)] {
        var snapshots: [(URL, ClassifierAlignmentEvidenceFileSnapshot)] = []
        if let snapshot = source.bamSnapshot {
            snapshots.append((source.identityURL, snapshot))
        }
        if let snapshot = source.indexSnapshot {
            snapshots.append((URL(fileURLWithPath: source.provider.indexPath), snapshot))
        }
        if let url = source.referenceURL, let snapshot = source.referenceSnapshot {
            snapshots.append((url, snapshot))
        }
        return snapshots
    }
    private func resourceSignatures(for source: DetachedAlignmentSource) -> [URL: (Int, Date?)] {
        Dictionary(uniqueKeysWithValues: expectedSnapshots(for: source).map { ($0.0, resourceSignature(for: $0.0)) })
    }
    private func resourceSignature(for url: URL) -> (Int, Date?) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
        let modificationDate = attributes?[.modificationDate] as? Date
        return (size, modificationDate)
    }
    nonisolated private static func checksumSnapshot(_ url: URL) throws -> ClassifierAlignmentEvidenceFileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var hash = SHA256()
        while true { let data = try handle.read(upToCount: 1 << 20) ?? Data(); if data.isEmpty { break }; hash.update(data: data) }
        return .init(size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Clears sequence fetch error state, allowing retry for a new region.
    func clearSequenceFetchError() {
        if bundleFetchError != nil {
            sequenceViewerLogger.info("clearSequenceFetchError: Clearing error '\(self.bundleFetchError ?? "nil", privacy: .public)' for region \(self.failedFetchRegion?.description ?? "nil")")
        }
        bundleFetchError = nil
        failedFetchRegion = nil
    }

    /// Clears cached variant data so the viewer re-fetches from the database on next draw.
    func clearCachedVariants() {
        cachedVariantAnnotations = []
        cachedVariantRegion = nil
        invalidateFilteredVariantCache()
        isFetchingVariants = false
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Dark mode toggle invalidates all cached CGColors
        typeColorCache.removeAll()
        typeDensityColorCache.removeAll()
        invalidateAnnotationTile()
        needsDisplay = true
    }

    // MARK: - Annotation Rendering Thresholds (inspired by IGV)
    //
    // Three rendering tiers based on zoom level:
    // - DENSITY MODE:  > 50,000 bp/pixel — feature density histogram
    // - SQUISHED MODE: 500–50,000 bp/pixel — packed thin rectangles, no labels
    // - EXPANDED MODE: < 500 bp/pixel — full boxes with labels, strand arrows

    /// Above this threshold (bp/pixel): draw density histogram instead of features
    var annotationDensityThreshold: Double { AppSettings.shared.densityThresholdBpPerPixel }

    /// Above this threshold (bp/pixel): draw squished (thin, no labels) features
    var annotationSquishedThreshold: Double { AppSettings.shared.squishedThresholdBpPerPixel }

    /// Maximum annotation rows before showing "+N more" indicator
    var maxAnnotationRows: Int { AppSettings.shared.maxAnnotationRows }

    /// Minimum feature width for expanded labels to avoid visual clutter.
    let minExpandedLabelWidth: CGFloat = 72

    /// Do not draw per-feature labels when packed rows exceed this count.
    let maxLabeledRows: Int = 12

    /// Minimum pixel gap between features in the same row during packing
    let minPixelGap: CGFloat = 2

    // MARK: - Hover Tooltip (Bundle Mode)

    /// Tracking area for mouse hover detection
    var viewerTrackingArea: NSTrackingArea?

    /// Custom hover tooltip for fast-appearing tooltips.
    lazy var hoverTooltip: HoverTooltipView = {
        let tip = HoverTooltipView()
        addSubview(tip)
        return tip
    }()

    /// Currently hovered annotation (to avoid redundant tooltip updates)
    var hoveredAnnotation: SequenceAnnotation?

    /// Last hovered genotype cell (sampleIndex, siteIndex) for tooltip caching.
    var lastHoveredGenotypeCell: (sampleIdx: Int, siteIdx: Int)?
    /// Last tooltip text used for hovered genotype cell.
    var lastHoveredGenotypeTooltipText: String?
    /// Last status text used for hovered genotype cell.
    var lastHoveredGenotypeStatusText: String?
}
