// ViewerViewController+ViewMemory.swift - The reference viewer keeps its display settings and locus on this Mac
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import os.log

private let viewMemoryLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewMemory")

// MARK: - The kept view

/// The reference viewer's kept view for one item: its display settings and its locus (VS-REF).
///
/// Each field's class. The colours, the heights, the show switches and the translation settings are presentation and
/// restore on any data key. The locus is VS B2: it restores only to a sequence of the same name and length, clamped,
/// and is dropped otherwise with "your place". The count filters (the annotation and variant filter texts, the visible
/// types, the hidden variant tracks and the sample display) are VS B6 and are not kept, since the viewer shows them only
/// in the Inspector. The explicit region (VS B3) and the selected record (VS B4) are the viewport's (VS-MAP).
struct ReferenceViewerMemory: ViewMemoryState {
    static let kind = SurfaceKind.bundle(.reference).description
    static let schemaVersion = 1

    var display: ReferenceViewerDisplay
    var locus: ViewMemoryLocus?
}

/// The presentation fields of a reference view, the only fields an older bundle's `.viewstate.json` gives as a starting
/// view (Revisits, 2.6 S11). None needs a data key.
struct ReferenceViewerDisplay: Codable, Sendable, Equatable {
    var typeColorOverrides: [AnnotationType: AnnotationColor]
    var annotationHeight: Double
    var annotationSpacing: Double
    var showAnnotations: Bool
    var showVariants: Bool
    var translationColorScheme: AminoAcidColorScheme
    var isRNAMode: Bool

    init(_ state: BundleViewState) {
        typeColorOverrides = state.typeColorOverrides
        annotationHeight = state.annotationHeight
        annotationSpacing = state.annotationSpacing
        showAnnotations = state.showAnnotations
        showVariants = state.showVariants
        translationColorScheme = state.translationColorScheme
        isRNAMode = state.isRNAMode
    }

    /// Writes the presentation fields into `state` and leaves every other field as it is.
    func write(into state: inout BundleViewState) {
        state.typeColorOverrides = typeColorOverrides
        state.annotationHeight = annotationHeight
        state.annotationSpacing = annotationSpacing
        state.showAnnotations = showAnnotations
        state.showVariants = showVariants
        state.translationColorScheme = translationColorScheme
        state.isRNAMode = isRNAMode
    }

    /// An older bundle's own `.viewstate.json`, read for its presentation fields only: never its locus, which has a
    /// name and no length, and never a count filter or a field that needs a data key. It reads the disk, so it runs off
    /// the main actor, and nothing writes or deletes the file.
    static func readOlderFile(in bundleURL: URL) -> ReferenceViewerDisplay? {
        let fileURL = bundleURL.appendingPathComponent(BundleViewState.filename)
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(BundleViewState.self, from: data) else { return nil }
        return ReferenceViewerDisplay(state)
    }
}

/// What the reference and mapping routes name for the view memory of an open (`ReferenceBundleViewportController`).
struct ReferenceViewerMemoryRequest: Sendable {
    /// The item the sidebar names: the reference bundle, or the mapping result's folder.
    let itemURL: URL
    /// The manifest the open decoded off the main actor, nil when it named another bundle.
    let manifest: BundleManifest?
    /// Whether the item is a mapping result, whose data key adds the alignment tracks (VS B1).
    let isMapping: Bool

    init(input: ReferenceBundleViewportInput?, bundleURL: URL) {
        let namesBundle = input?.renderedBundleURL == bundleURL
        itemURL = input?.mappingResultDirectoryURL ?? bundleURL
        manifest = namesBundle ? (input?.manifest ?? input?.viewerBundleManifest) : nil
        isMapping = input?.kind == .mappingResult
    }
}

// MARK: - The viewer

extension ViewerViewController {
    /// Shows a bundle for the reference and mapping routes.
    func displayRememberedBundle(
        at url: URL, sequenceName: String, memory request: ReferenceViewerMemoryRequest, bundle: ReferenceBundle?
    ) throws {
        try displayBundle(
            at: url, mode: .sequence(name: sequenceName, restoreViewState: false), manifest: request.manifest,
            bundle: bundle)
    }

    /// Whether the open's restore has run, for a test to wait on.
    var viewMemoryIsSettled: Bool { true }

    /// Reset View for the bundle on show.
    func resetBundleViewToDefaults() {
        // Clear type color caches and per-annotation colors (reverts to defaults)
        viewerView.resetTypeColorCaches()
        viewerView.clearAnnotationColorOverrides()

        let settings = AppSettings.shared

        // Reset in-memory state using current app defaults for annotation dimensions.
        currentBundleViewState = BundleViewState(
            typeColorOverrides: [:],
            annotationColorOverrides: [:],
            annotationHeight: settings.defaultAnnotationHeight,
            annotationSpacing: settings.defaultAnnotationSpacing,
            showAnnotations: true,
            visibleAnnotationTypes: nil,
            showVariants: true,
            visibleVariantTypes: nil,
            translationColorScheme: .zappo,
            isRNAMode: false,
            lastChromosome: nil,
            lastOrigin: nil,
            lastScale: nil
        )

        // Delete persisted file
        if let url = currentBundleURL {
            BundleViewState.delete(from: url)
            viewMemoryLogger.info("handleBundleViewStateResetRequested: Deleted .viewstate.json from bundle")
        }

        // Reset annotation display settings to defaults
        showAnnotations = true
        annotationDisplayHeight = CGFloat(settings.defaultAnnotationHeight)
        annotationDisplaySpacing = CGFloat(settings.defaultAnnotationSpacing)
        visibleAnnotationTypes = nil
        isRNAMode = false
        viewerView.translationColorScheme = .zappo
        viewerView.showVariants = true
        viewerView.visibleVariantTypes = nil
        viewerView.setHiddenVariantTrackIDs([])
        annotationDrawerView?.setHiddenVariantTrackIDs([])
        viewerView.annotationHeight = annotationDisplayHeight
        viewerView.annotationRowSpacing = annotationDisplaySpacing
        viewerView.invalidateFilteredVariantCache()
    }
}
