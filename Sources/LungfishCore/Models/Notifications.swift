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

    /// Key for variant track ID.
    public static let variantTrackId = "variantTrackId"

    /// Key for variant database row ID.
    public static let variantRowId = "variantRowId"
}
