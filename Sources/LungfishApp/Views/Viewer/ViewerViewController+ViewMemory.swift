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

/// What the off-main read of an open found (SWIFT 2): where the item lives, its store key and data key, the kept view,
/// and an older bundle's own file while the item has no entry and no retire mark.
struct ReferenceViewerMemoryRead: Sendable {
    let item: ViewMemoryItem
    let key: ViewMemoryKey?
    let dataKey: String?
    let kept: ViewMemoryRestorable<ReferenceViewerMemory>
    let olderFile: ReferenceViewerDisplay?

    /// Reads the disk and the store, so it runs off the main actor.
    static func read(_ request: ReferenceViewerMemoryRequest, bundleURL: URL, store: ViewMemoryStore) -> Self {
        let item = ViewMemoryItem.read(at: request.itemURL)
        if item.projectRoot == nil { store.loadLoose() }
        let key = store.key(for: item)
        let manifest = request.manifest ?? (try? BundleManifest.load(from: bundleURL))
        let dataKey = manifest.flatMap { manifest in
            text(request.isMapping
                ? ViewMemoryDataKey.mapping(manifest: manifest, bundleURL: bundleURL)
                : ViewMemoryDataKey.reference(manifest: manifest, bundleURL: bundleURL))
        }
        let kept = key.map { store.restorable(ReferenceViewerMemory.self, for: $0, folder: item.folder) } ?? .nothing
        // An older bundle's own file is a starting view only while the item has no entry and no retire mark (Revisits).
        let olderFile = key.flatMap { store.hasRecord(for: $0) ? nil : ReferenceViewerDisplay.readOlderFile(in: bundleURL) }
        return ReferenceViewerMemoryRead(item: item, key: key, dataKey: dataKey, kept: kept, olderFile: olderFile)
    }

    /// The data key as the store keeps it, nil while a part was not read, so it never compares equal (VS B1).
    private static func text(_ key: ViewMemoryDataKey) -> String? {
        guard key.isComplete else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(key)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// One visit of the viewer to a bundle that a route opened with view memory.
@MainActor
final class ReferenceViewerMemorySession {
    let store: ViewMemoryStore
    let bundleURL: URL
    /// The view the open showed, which a late restore must still find, so a change made before it stays (VS A2).
    let opening: ReferenceViewerMemory
    /// The view a capture compares with, so a view equal to it is not kept (VS S3).
    var start: ReferenceViewerMemory
    var read: ReferenceViewerMemoryRead?
    var settled = false
    /// Whether the restore ran. Until it has, a capture keeps nothing.
    var applied = false
    /// The line that says what was not kept (VS U2), removed when the visit ends.
    var line: ViewMemoryResetLineView?

    init(store: ViewMemoryStore, bundleURL: URL, opening: ReferenceViewerMemory) {
        self.store = store
        self.bundleURL = bundleURL
        self.opening = opening
        start = opening
    }
}

// MARK: - The viewer

extension ViewerViewController {
    /// Shows a bundle for the reference and mapping routes and restores the view kept for the item. The store and the
    /// disk are read off the main actor, and the restore applies after the display's settle.
    func displayRememberedBundle(
        at url: URL, sequenceName: String, memory request: ReferenceViewerMemoryRequest, bundle: ReferenceBundle?
    ) throws {
        try displayBundle(
            at: url, mode: .sequence(name: sequenceName, restoreViewState: true), manifest: request.manifest,
            bundle: bundle)
        let session = ReferenceViewerMemorySession(store: viewMemoryStore, bundleURL: url, opening: captureViewerMemory())
        viewMemory = session
        observeViewMemoryEnds()
        let store = viewMemoryStore
        Task.detached(priority: .userInitiated) { [weak self] in
            let read = ReferenceViewerMemoryRead.read(request, bundleURL: url, store: store)
            await self?.viewMemoryDidRead(read, for: session)
        }
    }

    /// Whether the open's restore has run, for a test to wait on.
    var viewMemoryIsSettled: Bool { viewMemory?.applied ?? true }

    private func viewMemoryDidRead(_ read: ReferenceViewerMemoryRead, for session: ReferenceViewerMemorySession) {
        guard viewMemory === session else { return }
        session.read = read
        applyViewMemoryIfReady(session)
    }

    /// The settle of a display calls this (`ViewerViewController+BundleDisplay.swift`), and a restore applies after it.
    func viewMemorySettled(at bundleURL: URL) {
        guard let session = viewMemory, session.bundleURL == bundleURL else { return }
        session.settled = true
        applyViewMemoryIfReady(session)
    }

    private func applyViewMemoryIfReady(_ session: ReferenceViewerMemorySession) {
        guard session.settled, !session.applied, let read = session.read else { return }
        session.applied = true
        // A late restore applies only while the view is as the open left it, so a change made before it stays (VS A2).
        guard captureViewerMemory() == session.opening else { return }
        var words: String?
        if case .view(let kept, _, _) = read.kept {
            words = ViewMemoryWords.dataChanged(restoreViewerMemory(kept))
        } else if let olderFile = read.olderFile {
            // An older bundle's look is a starting view, never a person's choice (VS S3).
            applyViewerDisplay(olderFile)
            session.start = captureViewerMemory()
        }
        if case .folderChanged = read.kept { words = ViewMemoryWords.viewReset }
        if let words { showViewMemoryLine(words, in: session) }
    }

    /// The view as it stands: the display settings, and the locus with its sequence's length.
    func captureViewerMemory() -> ReferenceViewerMemory {
        ReferenceViewerMemory(
            display: ReferenceViewerDisplay(capturedViewState()),
            locus: referenceFrame.map {
                ViewMemoryLocus(sequenceName: $0.chromosome, sequenceLength: $0.sequenceLength, start: $0.start, end: $0.end)
            })
    }

    /// Applies a kept view. The display settings restore on any data key. The locus restores, clamped, on the sequence
    /// on show, and only when that sequence has the kept name and length (VS B2). A kept sequence that is gone or has
    /// another length is "your place" not kept. One that still exists but is not on show is left for the viewport's
    /// selected record to bring back (VS-MAP), with no line.
    func restoreViewerMemory(_ kept: ReferenceViewerMemory) -> ViewMemoryLoss {
        applyViewerDisplay(kept.display)
        guard let locus = kept.locus else { return [] }
        let sequences = (currentBundleDataProvider?.chromosomes ?? []).map {
            ViewMemorySequence(name: $0.name, length: Int($0.length))
        }
        guard case .restored(let place, _) = ViewMemoryRules.resolveLocus(locus, in: sequences) else { return .place }
        guard let frame = referenceFrame, frame.chromosome == place.sequenceName else { return [] }
        let restored = ReferenceFrame(
            chromosome: frame.chromosome, start: place.start, end: place.end, pixelWidth: frame.pixelWidth,
            sequenceLength: frame.sequenceLength)
        restored.leadingInset = frame.leadingInset
        referenceFrame = restored
        enhancedRulerView.referenceFrame = restored
        enhancedRulerView.needsDisplay = true
        updateStatusBar()
        return []
    }

    /// Shows the presentation fields of a kept view or of an older bundle's file.
    func applyViewerDisplay(_ display: ReferenceViewerDisplay) {
        var state = currentBundleViewState ?? .default
        display.write(into: &state)
        currentBundleViewState = state
        showAnnotations = display.showAnnotations
        annotationDisplayHeight = CGFloat(display.annotationHeight)
        annotationDisplaySpacing = CGFloat(display.annotationSpacing)
        isRNAMode = display.isRNAMode
        viewerView.showAnnotations = display.showAnnotations
        viewerView.annotationHeight = annotationDisplayHeight
        viewerView.annotationRowSpacing = annotationDisplaySpacing
        viewerView.translationColorScheme = display.translationColorScheme
        viewerView.showVariants = display.showVariants
        viewerView.resetTypeColorCaches()
        if !display.typeColorOverrides.isEmpty {
            viewerView.applyTypeColorOverrides(display.typeColorOverrides)
        }
        viewerView.needsDisplay = true
    }

    /// Keeps the view as it stands for the item on show, in the store and never in the bundle (VS S1, S3).
    func keepViewMemory() {
        guard let session = viewMemory, session.applied, session.bundleURL == currentBundleURL,
              let read = session.read, let key = read.key else { return }
        session.store.keep(
            captureViewerMemory(), startingView: session.start, for: key, dataKey: read.dataKey, folder: read.item.folder)
    }

    /// Ends the visit: keeps a pending change, then removes the line (VS U2).
    func leaveViewMemory() {
        saveCurrentViewState()
        viewMemory?.line?.removeFromSuperview()
        viewMemory = nil
    }

    private func showViewMemoryLine(_ words: String, in session: ReferenceViewerMemorySession) {
        session.line?.removeFromSuperview()
        let line = ViewMemoryResetLineView(words: words)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: viewerView.topAnchor),
            line.leadingAnchor.constraint(equalTo: viewerView.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: viewerView.trailingAnchor),
        ])
        session.line = line
        NSAccessibility.post(element: line.label, notification: .announcementRequested, userInfo: [
            .announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Keeps a pending change when the window closes or the app quits, since nothing leaves the bundle on those ways
    /// out, and at the quit writes it before the app ends (VS S1).
    private func observeViewMemoryEnds() {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSApplication.willTerminateNotification] {
            center.removeObserver(self, name: name, object: nil)
            center.addObserver(self, selector: #selector(viewMemoryWillEnd(_:)), name: name, object: nil)
        }
    }

    @objc private func viewMemoryWillEnd(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window !== view.window { return }
        saveCurrentViewState()
        if notification.name == NSApplication.willTerminateNotification {
            viewMemory?.store.flushSynchronously()
        }
    }

    /// Reset View for the bundle on show. It writes nothing into the bundle. It leaves the item's retire mark in the
    /// store, so an older bundle's own file is not read again and the reset is not undone at the next open (Revisits).
    func resetBundleViewToDefaults() {
        // Clear type color caches and per-annotation colors (reverts to defaults)
        viewerView.resetTypeColorCaches()
        viewerView.clearAnnotationColorOverrides()

        let settings = AppSettings.shared

        // Reset in-memory state using current app defaults for annotation dimensions.
        currentBundleViewState = BundleViewState(
            annotationHeight: settings.defaultAnnotationHeight, annotationSpacing: settings.defaultAnnotationSpacing)

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

        guard let session = viewMemory, let read = session.read, let key = read.key else { return }
        viewStateSaveWorkItem?.cancel()
        viewStateSaveWorkItem = nil
        session.store.reset(key, kind: ReferenceViewerMemory.kind, folder: read.item.folder)
        session.start = captureViewerMemory()
        session.line?.removeFromSuperview()
        session.line = nil
        viewMemoryLogger.info("resetBundleViewToDefaults: left the item's retire mark in the view memory store")
    }
}

