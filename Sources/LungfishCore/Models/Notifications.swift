// Notifications.swift - Application-wide notification names
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Annotation Notifications

extension Notification.Name {
    /// Posted when an annotation is selected in the viewer.
    ///
    /// The notification's `object` should be the `SequenceAnnotation` that was selected,
    /// or `nil` if the selection was cleared.
    public static let annotationSelected = Notification.Name("annotationSelected")

    /// Posted when an annotation's properties have been updated.
    ///
    /// The notification's `object` should be the updated `SequenceAnnotation`.
    /// The `userInfo` dictionary may contain the key `"previousAnnotation"` with
    /// the annotation's state before the update.
    public static let annotationUpdated = Notification.Name("annotationUpdated")

    /// Posted when an annotation has been deleted.
    ///
    /// The notification's `object` should be the `SequenceAnnotation` that was deleted.
    public static let annotationDeleted = Notification.Name("annotationDeleted")

    /// Posted when a color should be applied to all annotations of a specific type.
    ///
    /// The notification's `userInfo` dictionary contains:
    /// - `annotationType`: The `AnnotationType` to update
    /// - `annotationColor`: The `AnnotationColor` to apply
    /// - `changeSource`: The source of the change (e.g., "inspector")
    public static let annotationColorAppliedToType = Notification.Name("annotationColorAppliedToType")
}

// MARK: - Appearance Notifications

extension Notification.Name {
    /// Posted when the application appearance settings have changed.
    ///
    /// This notification is posted when theme, color scheme, or other visual
    /// appearance settings are modified. Views should observe this notification
    /// to update their rendering accordingly.
    public static let appearanceChanged = Notification.Name("appearanceChanged")

    /// Posted when any application-level setting has changed (via AppSettings.save()).
    ///
    /// Observers should re-read relevant values from `AppSettings.shared` and
    /// invalidate caches as needed (e.g., offscreen tile, type color cache).
    public static let appSettingsChanged = Notification.Name("appSettingsChanged")

    /// Posted when annotation display settings have changed.
    ///
    /// Contains userInfo keys: "showAnnotations", "annotationHeight", "annotationSpacing"
    public static let annotationSettingsChanged = Notification.Name("annotationSettingsChanged")

    /// Posted when annotation filter settings have changed.
    ///
    /// Contains userInfo keys: "visibleTypes" (Set<AnnotationType>), "filterText" (String)
    public static let annotationFilterChanged = Notification.Name("annotationFilterChanged")

    /// Posted when variant filter settings have changed.
    ///
    /// Contains userInfo keys: "showVariants" (Bool), "visibleVariantTypes" (Set<String>),
    /// "variantFilterText" (String)
    public static let variantFilterChanged = Notification.Name("variantFilterChanged")

    /// Posted when sample display state has changed (row visibility, height mode, sort/filter).
    ///
    /// Contains userInfo key: "sampleDisplayState" (SampleDisplayState)
    public static let sampleDisplayStateChanged = Notification.Name("sampleDisplayStateChanged")

    /// Posted when the variant color theme changes.
    ///
    /// Observers should refresh variant/call renderers that derive colors from
    /// `SampleDisplayState.colorThemeName` or app-level appearance defaults.
    public static let variantColorThemeDidChange = Notification.Name("com.lungfish.variantColorThemeDidChange")
}

// MARK: - Viewer Navigation Notifications

extension Notification.Name {
    /// Posted when the viewer's coordinate position changes (scroll, zoom, chromosome switch).
    ///
    /// Contains userInfo keys: "chromosome" (String), "start" (Int), "end" (Int)
    public static let viewerCoordinatesChanged = Notification.Name("viewerCoordinatesChanged")

    /// Posted when a reference bundle is loaded into the viewer.
    ///
    /// Contains userInfo keys: "bundleURL" (URL), "chromosomes" ([ChromosomeInfo]),
    /// "manifest" (BundleManifest)
    public static let bundleDidLoad = Notification.Name("bundleDidLoad")

    /// Posted when variants in the viewer viewport have been updated.
    ///
    /// Contains userInfo keys: "chromosome" (String), "start" (Int), "end" (Int),
    /// "variantCount" (Int)
    public static let viewportVariantsUpdated = Notification.Name("viewportVariantsUpdated")

    /// Posted when the bundle view state should be reset to defaults.
    ///
    /// Listeners should clear type color overrides, delete the `.viewstate.json`
    /// file, and reset the in-memory `BundleViewState` to defaults.
    public static let bundleViewStateResetRequested = Notification.Name("bundleViewStateResetRequested")

    /// Posted when variant tracks have been deleted from a bundle.
    ///
    /// Contains userInfo keys: `bundleURL` (URL)
    public static let bundleVariantTracksDeleted = Notification.Name("bundleVariantTracksDeleted")

    /// Posted when a mapped read is selected or deselected in the viewer.
    ///
    /// Contains userInfo key: "alignedRead" (AlignedRead) or nil for deselection
    public static let readSelected = Notification.Name("readSelected")

    /// Posted when alignment/read display settings change in the inspector.
    ///
    /// Contains userInfo keys: "showReads" (Bool), "maxReadRows" (Int),
    /// "minMapQ" (Int), "showMismatches" (Bool), "showSoftClips" (Bool),
    /// "showIndels" (Bool), "consensusMaskingEnabled" (Bool),
    /// "consensusGapThresholdPercent" (Int), "consensusMinDepth" (Int),
    /// "consensusMinMapQ" (Int), "consensusMinBaseQ" (Int),
    /// "limitReadRows" (Bool), "verticalCompressContig" (Bool),
    /// "showConsensusTrack" (Bool), "consensusMode" (String),
    /// "consensusUseAmbiguity" (Bool)
    public static let readDisplaySettingsChanged = Notification.Name("readDisplaySettingsChanged")

}

// MARK: - Viewport Content Mode

/// Describes the kind of content currently displayed in the main viewport.
///
/// Used by the inspector and toolbar to adapt their UI to the active content type.
/// For example, annotation and translation tools are only relevant in `.genomics` mode,
/// while FASTQ metadata editing only applies in `.fastq` mode.
public enum ViewportContentMode: String, Sendable {
    /// Genomic sequence viewer (FASTA, VCF, genome bundles).
    case genomics
    /// FASTQ dataset dashboard.
    case fastq
    /// Metagenomics results (TaxTriage, EsViritu, Kraken2 taxonomy).
    case metagenomics
    /// Nothing displayed.
    case empty
}

extension Notification.Name {
    /// Posted when the viewport content mode changes.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"contentMode"`: The new `ViewportContentMode` raw value (`String`).
    public static let viewportContentModeDidChange = Notification.Name("viewportContentModeDidChange")
}

// MARK: - Inspector Notifications

extension Notification.Name {
    /// Posted to request showing and focusing the inspector panel.
    ///
    /// The `userInfo` dictionary may contain:
    /// - `"tab"`: A `String` indicating which inspector tab to switch to
    ///   (e.g., `"selection"`, `"document"`).
    public static let showInspectorRequested = Notification.Name("showInspectorRequested")

    /// Posted to request showing a chromosome's details in the inspector.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"chromosome"`: The `ChromosomeInfo` to display in the inspector.
    public static let chromosomeInspectorRequested = Notification.Name("chromosomeInspectorRequested")

    /// Posted to request showing or hiding the CDS translation track in the viewer.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"annotation"`: The `SequenceAnnotation` (CDS) to translate.
    /// - `"visible"`: `Bool` indicating whether to show or hide.
    public static let showCDSTranslationRequested = Notification.Name("showCDSTranslationRequested")

    /// Posted to request extracting sequence from an annotation (shows extraction sheet).
    ///
    /// The `userInfo` dictionary contains:
    /// - `"annotation"`: The `SequenceAnnotation` to extract from.
    public static let extractSequenceRequested = Notification.Name("extractSequenceRequested")

    /// Posted to request copying an annotation's sequence as FASTA to clipboard.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"annotation"`: The `SequenceAnnotation` to copy.
    public static let copyAnnotationAsFASTARequested = Notification.Name("copyAnnotationAsFASTARequested")

    /// Posted to request copying a CDS annotation's translation as FASTA to clipboard.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"annotation"`: The `SequenceAnnotation` (CDS) to translate and copy.
    public static let copyTranslationAsFASTARequested = Notification.Name("copyTranslationAsFASTARequested")

    /// Posted to request zooming the viewer to an annotation's coordinates.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"annotation"`: The `SequenceAnnotation` to zoom to.
    public static let zoomToAnnotationRequested = Notification.Name("zoomToAnnotationRequested")

    /// Posted when a variant is selected in the viewer or drawer.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"searchResult"`: `AnnotationSearchIndex.SearchResult` for the selected variant.
    public static let variantSelected = Notification.Name("variantSelected")

    /// Posted to request copying an annotation's raw sequence to the clipboard.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"annotation"`: The `SequenceAnnotation` whose sequence to copy.
    public static let copyAnnotationSequenceRequested = Notification.Name("copyAnnotationSequenceRequested")

    /// Posted to request copying an annotation's reverse complement to the clipboard.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"annotation"`: The `SequenceAnnotation` whose reverse complement to copy.
    public static let copyAnnotationReverseComplementRequested = Notification.Name("copyAnnotationReverseComplementRequested")

    /// Posted when an operation starts, completes, fails, or is cancelled.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"operationID"`: The `UUID` of the affected operation.
    /// - `"operationState"`: The state as a raw `String` ("running", "completed", "failed").
    public static let operationStateChanged = Notification.Name("operationStateChanged")

    /// Posted when a FASTQ dataset has been loaded and its statistics dashboard is displayed.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"statistics"`: The `FASTQDatasetStatistics` object.
    public static let fastqDatasetLoaded = Notification.Name("fastqDatasetLoaded")

    /// Posted when a standalone VCF dataset has been loaded and its dashboard is displayed.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"summary"`: The `VCFSummary` object.
    public static let vcfDatasetLoaded = Notification.Name("vcfDatasetLoaded")

    /// Posted when the user requests orienting FASTQ reads against a reference.
    ///
    /// The `userInfo` dictionary contains:
    /// - `"fastqURL"`: The FASTQ file URL.
    /// - `"referenceURL"`: The reference FASTA URL.
    /// - `"wordLength"`: `Int` word length for k-mer matching.
    /// - `"dbMask"`: `String` masking mode ("dust" or "none").
    /// - `"saveUnoriented"`: `Bool` whether to save unoriented reads.
    public static let fastqOrientRequested = Notification.Name("fastqOrientRequested")

    /// Posted when the user changes the database storage location in Settings
    /// or the Plugin Manager.
    ///
    /// Observers (e.g. ``MetagenomicsDatabaseRegistry``) should re-read the
    /// storage path from UserDefaults and update their base directory accordingly.
    public static let databaseStorageLocationChanged = Notification.Name("databaseStorageLocationChanged")

    /// Posted when managed tools or databases change availability.
    ///
    /// Observers should re-read any tool/database readiness state they cache,
    /// including setup surfaces and open metagenomics configuration sheets.
    public static let managedResourcesDidChange = Notification.Name("managedResourcesDidChange")
}

// MARK: - Notification UserInfo Keys

/// Keys used in notification userInfo dictionaries.
public enum NotificationUserInfoKey {
    /// Key for the annotation that was selected or modified.
    public static let annotation = "annotation"

    /// Key for the previous state of an annotation before an update.
    public static let previousAnnotation = "previousAnnotation"

    /// Key for the source of a change (e.g., "inspector", "viewer", "undo").
    public static let changeSource = "changeSource"

    /// Key for the chromosome or sequence name associated with a notification.
    public static let chromosome = "chromosome"

    /// Key for variant-database chromosome name (may differ from reference chromosome label).
    public static let variantChromosome = "variantChromosome"

    /// Key for the selection state associated with a notification.
    public static let selectionState = "selectionState"

    /// Key for the annotation type when applying changes to all of a type.
    public static let annotationType = "annotationType"

    /// Key for the annotation color when applying color changes.
    public static let annotationColor = "annotationColor"

    /// Key for the active sequence index in multi-sequence views.
    public static let activeSequenceIndex = "activeSequenceIndex"

    /// Key for annotation visibility state (Bool).
    public static let annotationVisible = "annotationVisible"

    /// Key for start position (Int).
    public static let start = "start"

    /// Key for end position (Int).
    public static let end = "end"

    /// Key for bundle URL.
    public static let bundleURL = "bundleURL"

    /// Key for chromosomes array.
    public static let chromosomes = "chromosomes"

    /// Key for the bundle manifest (BundleManifest).
    public static let manifest = "manifest"

    /// Key for the inspector tab to switch to (String).
    public static let inspectorTab = "tab"

    /// Key indicating whether chromosome inspector requests should switch to Document tab (Bool).
    public static let switchInspectorTab = "switchTab"

    /// Key for the reference bundle (ReferenceBundle).
    public static let referenceBundle = "referenceBundle"

    /// Key for variant visibility (Bool).
    public static let showVariants = "showVariants"

    /// Key for the set of visible variant types (Set<String>).
    public static let visibleVariantTypes = "visibleVariantTypes"

    /// Key for variant text filter (String).
    public static let variantFilterText = "variantFilterText"

    /// Key for sample display state (SampleDisplayState).
    public static let sampleDisplayState = "sampleDisplayState"

    /// Key for selected variant search result.
    public static let searchResult = "searchResult"

    /// Key indicating preferred table focus behavior for a variant selection event.
    /// Expected values include "calls" and "genotypes".
    public static let variantSelectionMode = "variantSelectionMode"

    /// Key for variant track ID.
    public static let variantTrackId = "variantTrackId"

    /// Key for variant database row ID.
    public static let variantRowId = "variantRowId"

    /// Key for read visibility (Bool).
    public static let showReads = "showReads"

    /// Key for maximum read rows to render (Int).
    public static let maxReadRows = "maxReadRows"

    /// Key for minimum MAPQ filter (Int).
    public static let minMapQ = "minMapQ"

    /// Key for mismatch display toggle (Bool).
    public static let showMismatches = "showMismatches"

    /// Key for soft clip display toggle (Bool).
    public static let showSoftClips = "showSoftClips"

    /// Key for insertion/deletion display toggle (Bool).
    public static let showIndels = "showIndels"

    /// Key for enabling consensus-style high-gap masking (Bool).
    public static let consensusMaskingEnabled = "consensusMaskingEnabled"

    /// Key for high-gap mask threshold as a percent integer (0-100).
    public static let consensusGapThresholdPercent = "consensusGapThresholdPercent"

    /// Key for minimum depth required before a consensus/gap decision is applied.
    public static let consensusMinDepth = "consensusMinDepth"

    /// Key for consensus/depth minimum mapping quality (Int).
    public static let consensusMinMapQ = "consensusMinMapQ"

    /// Key for consensus/depth minimum base quality (Int).
    public static let consensusMinBaseQ = "consensusMinBaseQ"

    /// Key for whether read rows should be capped by maxReadRows (Bool).
    public static let limitReadRows = "limitReadRows"

    /// Key for compact vertical read rendering mode (Bool).
    public static let verticalCompressContig = "verticalCompressContig"

    /// Key for showing/hiding the consensus row beneath coverage (Bool).
    public static let showConsensusTrack = "showConsensusTrack"

    /// Key for consensus caller mode ("bayesian" or "simple").
    public static let consensusMode = "consensusMode"

    /// Key for enabling IUPAC ambiguity codes in consensus output (Bool).
    public static let consensusUseAmbiguity = "consensusUseAmbiguity"

    /// Key for the aligned read in read selection notifications.
    public static let alignedRead = "alignedRead"

    /// Key for the samtools exclude flags bitmask (UInt16).
    public static let excludeFlags = "excludeFlags"

    /// Key for the set of selected read group IDs to display (Set<String>, empty = all).
    public static let selectedReadGroups = "selectedReadGroups"

    /// Key for strand-colored read backgrounds toggle (Bool).
    public static let showStrandColors = "showStrandColors"

    /// Key for the viewport content mode (ViewportContentMode raw value String).
    public static let contentMode = "contentMode"
}
