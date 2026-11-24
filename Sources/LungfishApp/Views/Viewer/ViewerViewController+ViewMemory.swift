// ViewerViewController+ViewMemory.swift - The reference viewer keeps its display settings and locus on this Mac
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log

private let viewMemoryLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewMemory")

// MARK: - The kept view

/// The reference viewer's kept view for one item: its display settings and its locus (VS-REF).
///
/// Each field's class. The colours, the heights, the show switches and the translation settings are presentation and
/// restore on any data key. The locus is VS B2: it restores only to a sequence of the same name and length, clamped,
/// and is dropped otherwise with "your place". The count filters (the annotation and variant filter texts, the visible
/// types, the hidden variant tracks and the sample display) are VS B6 and are not kept, since the viewer shows them only
/// in the Inspector. The explicit region (VS B3) is not kept yet. The viewport's list and mode ride in `viewport`
/// (VS-MAP), so the item keeps one record with one writer, the viewer's visit.
struct ReferenceViewerMemory: ViewMemoryState {
    static let kind = SurfaceKind.bundle(.reference).description
    static let schemaVersion = 1

    var display: ReferenceViewerDisplay
    var locus: ViewMemoryLocus?
    /// The list and mode of the viewport that shows the viewer, nil for a record an older build kept.
    var viewport: ReferenceViewportMemory? = nil
    /// The drawer's tab and row (VS-MAP-2 item 1), nil at the drawer's default or for an older record.
    var drawer: ReferenceDrawerMemory? = nil

    var selectionCount: Int {
        guard let table = viewport?.table else { return 0 }
        return table.selectionTooLarge ? Int.max : table.selectedIdentities.count
    }

    func withoutSelection() -> ReferenceViewerMemory {
        var view = self
        view.viewport?.table.selectedIdentities = []
        view.viewport?.table.selectionTooLarge = false
        return view
    }

    /// The view as the store holds it for a visit that started at `start`. A selection equal to the start's is the
    /// row the list opened on, not a person's pick, so none is held and a renamed or gone first row costs only
    /// "your place" (VS B4).
    func held(from start: ReferenceViewerMemory) -> ReferenceViewerMemory {
        viewport?.table.selectedIdentities == start.viewport?.table.selectedIdentities ? withoutSelection() : self
    }

    /// Whether a person changed nothing between the two views. The mapping list's own row refresh gives its rows new
    /// identities and moves its scroll, so the list compares by what a person picks there (VS A2). The drawer is not
    /// compared: the viewer keeps one drawer for its life, so the open's drawer is the last bundle's and its own reload
    /// changes it with no person acting. The restore keeps a person's drawer row by itself: it waits until the drawer
    /// shows rows and selects the kept row only while none is selected (`restorePendingDrawerMemory`).
    func sameChoices(as other: ReferenceViewerMemory) -> Bool {
        display == other.display && locus == other.locus && viewport?.choices == other.viewport?.choices
    }
}

/// The viewport's own view (VS-MAP): list or focused mode, which is presentation and restores on any data key, and the
/// list through the table part, whose sort always restores, whose column filters and search text restore only on an
/// equal data key (VS B6), and whose selection restores by row identity only (VS B4). The list is the sequence table
/// of a reference (k08) or the contig table of a mapping result (k22), whose row identity holds the sample and track.
struct ReferenceViewportMemory: Codable, Sendable, Equatable {
    var focused: Bool
    var table: BatchTableMemory
    /// The read filters the viewer shows, VS B6, restored on an equal data key only (VS-MAP-2). Nil for a record
    /// an older build kept.
    var reads: ReferenceReadFilters? = nil

    /// What a person picks: the mode, the sort, the filters and the selected sequences by name.
    struct Choices: Equatable {
        let focused: Bool
        let sort: BatchTableMemory.Sort?
        let columnFilters: ColumnFilterSet
        let filterText: String
        let sequences: [String]
    }

    var choices: Choices {
        Choices(
            focused: focused, sort: table.sort, columnFilters: table.columnFilters, filterText: table.filterText,
            sequences: table.selectedIdentities.map { $0.split(separator: "\u{1F}").last.map(String.init) ?? $0 })
    }
}

/// The viewport that shows the viewer, which the viewer's visit asks for its list and mode (VS-MAP).
@MainActor
protocol ReferenceViewportMemoryOwner: AnyObject {
    /// Whether the viewport's rows are those of `bundleURL`, so a list filled for another document is never kept.
    func viewportShows(_ bundleURL: URL) -> Bool
    func captureViewportMemory() -> ReferenceViewportMemory?
    /// Applies the kept list and mode as a person's picks would, and starts nothing (VS S4).
    func restoreViewportMemory(_ memory: ReferenceViewportMemory, dataChanged: Bool) -> ViewMemoryLoss
    /// Whether the viewport's own row refresh still runs, after which the list restores.
    var viewMemoryRowsArePending: Bool { get }
    /// The selection the list makes by itself, which is never a person's change: its first displayed row, or none
    /// while it shows none or shows All Alignments.
    var viewMemoryOwnSelection: [String] { get }
    func viewMemoryRowsSettled() async
    /// A row is selected with no alignment action context and none being built (VS-MAP-2 item 6).
    var selectedRowAwaitsItsContext: Bool { get }
    /// Shows word 5a while the filters the restore or the block's carry left hide reads (VS B6).
    func showReadFilterLineIfKept()
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
    /// A person changed the view, or reset it, before the restore ran. The restore must neither lose nor undo that.
    var changedBeforeApply = false
    var resetBeforeApply = false
    /// A person picked a row of the viewport's list before the restore ran, even the row the list selects by itself, so
    /// the restore must not undo the pick (VS-MAP-RACE).
    var pickedBeforeApply = false
    /// The viewport's list and mode as last read while it showed this bundle (VS-MAP).
    var viewport: ReferenceViewportMemory?
    /// The restore withheld the selected row's alignment action context, so the row shows the cue until the
    /// person's click starts its context task (VS-MAP-2 item 6).
    var contextWithheld = false
    /// The read filters the filter line speaks of, so a person's change of them ends it (VS B6).
    var restoredReads: ReferenceReadFilters?
    /// The kept drawer view, waiting for the drawer's rows to load (VS-MAP-2 item 1, BIO R1).
    var pendingDrawer: ReferenceDrawerMemory?
    var restoringDrawer = false
    var drawerKeyChanged = false
    var restoredLoss: ViewMemoryLoss = []
    /// The restore waits for, or has waited for, the viewport's own row refresh.
    var awaitingRows = false
    var rowsSettled = false
    /// The restore is applying the viewport's list now, so a restored row installs no action context.
    var restoringViewport = false
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
        session.viewport = session.opening.viewport
        viewMemory = session
        observeViewMemoryEnds()
        let store = viewMemoryStore
        Task.detached(priority: .userInitiated) { [weak self] in
            let read = ReferenceViewerMemoryRead.read(request, bundleURL: url, store: store)
            await self?.viewMemoryDidRead(read, for: session)
        }
    }

    /// The store that keeps the reference view of each item on this Mac: the one a test injects, else the store of
    /// the surface host of the viewer that shows this one, so a window keeps every view in one store. In the app
    /// both are `.shared`.
    var viewMemoryStore: ViewMemoryStore {
        get {
            if let injectedViewMemoryStore { return injectedViewMemoryStore }
            var next = parent
            while let controller = next {
                if let host = controller as? ViewerViewController { return host.surfaceHost.viewMemoryStore }
                next = controller.parent
            }
            return .shared
        }
        set { injectedViewMemoryStore = newValue }
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

    /// The viewport that shows this viewer, nil for a viewer of its own (VS-MAP).
    var viewMemoryViewport: (any ReferenceViewportMemoryOwner)? {
        var next = parent
        while let controller = next {
            if let owner = controller as? any ReferenceViewportMemoryOwner { return owner }
            next = controller.parent
        }
        return nil
    }

    /// Whether the restore is applying the viewport's list now, so a restored row installs no alignment action context
    /// until the person picks it (SWIFT-EVIDENCE-HASH).
    var isRestoringViewportMemory: Bool { viewMemory?.restoringViewport ?? false }

    private func applyViewMemoryIfReady(_ session: ReferenceViewerMemorySession) {
        guard session.settled, !session.applied, let read = session.read else { return }
        // The mapping list's own row refresh replaces its rows, so the list restores when it ends (VS S4). It waits for
        // the refresh that runs and starts none.
        if !session.rowsSettled, let owner = viewMemoryViewport, owner.viewMemoryRowsArePending {
            guard !session.awaitingRows else { return }
            session.awaitingRows = true
            Task { @MainActor [weak self, weak owner] in
                await owner?.viewMemoryRowsSettled()
                session.rowsSettled = true
                guard let self, self.viewMemory === session else { return }
                self.applyViewMemoryIfReady(session)
            }
            return
        }
        session.applied = true
        // A late restore applies only while the view is as the open left it, so a change made before it stays (VS A2).
        if session.resetBeforeApply {
            // Reset View ran before the read landed, so the reset stands and the retire mark is left now.
            if let key = read.key { session.store.reset(key, kind: ReferenceViewerMemory.kind, folder: read.item.folder) }
            if session.changedBeforeApply { keepViewMemory() }
            return
        }
        let settledView = captureViewerMemory()
        var opening = session.opening
        // The list's own row refresh replaces its rows and selects its first row again, or none while it shows none
        // or shows All Alignments (`refreshSelection`, `clearMappingSelectionAfterAllRebuild`), so that selection is
        // the list's own and not a person's pick (VS A2). Any other selection, and the mode, the sort, the filters and
        // the place, still compare with the open's. A person's pick of a row, that first row too, is a change, so the
        // exception does not apply to it and the restore is refused (VS-MAP-RACE).
        if !session.pickedBeforeApply, let own = viewMemoryViewport?.viewMemoryOwnSelection,
           settledView.viewport?.table.selectedIdentities == own {
            opening.viewport?.table.selectedIdentities = own
        }
        guard !session.pickedBeforeApply, settledView.sameChoices(as: opening) else {
            // A person changed the view first. It stays, and the change the debounce could not keep is kept now.
            if session.changedBeforeApply { keepViewMemory() }
            return
        }
        // The view the visit starts from, with the list's rows as its own refresh left them (VS S3).
        session.start = settledView
        var words: String?
        if case .view(let kept, let keptDataKey, let selectionDropped) = read.kept {
            var loss: ViewMemoryLoss = []
            if let viewport = kept.viewport, let owner = viewMemoryViewport {
                // The list first, so the kept place finds its sequence on show.
                let changed = keptDataKey == nil || read.dataKey == nil || keptDataKey != read.dataKey
                session.restoringViewport = true
                loss.formUnion(owner.restoreViewportMemory(viewport, dataChanged: changed))
                session.restoringViewport = false
            }
            loss.formUnion(restoreViewerMemory(kept))
            words = ViewMemoryWords.dataChanged(loss) ?? (selectionDropped ? ViewMemoryWords.selectionTooLarge : nil)
            session.restoredLoss = loss
            session.drawerKeyChanged = keptDataKey == nil || read.dataKey == nil || keptDataKey != read.dataKey
            session.pendingDrawer = kept.drawer
            announceViewMemory()
        } else if let olderFile = read.olderFile {
            // An older bundle's look is a starting view, never a person's choice (VS S3).
            applyViewerDisplay(olderFile)
            session.start = captureViewerMemory()
            announceViewMemory()
        }
        if case .folderChanged = read.kept { words = ViewMemoryWords.viewReset }
        viewMemoryViewport?.showReadFilterLineIfKept()
        if let words { showViewMemoryLine(words, in: session) }
        if let drawer = annotationDrawerView { restorePendingDrawerMemory(in: drawer) }
    }

    /// The view as it stands: the display settings, the locus with its sequence's length, and the viewport's list and
    /// mode while the viewport shows this visit's bundle, else as it last showed it, so a route that fills the
    /// viewport with another document first never keeps that document's rows for this one.
    func captureViewerMemory() -> ReferenceViewerMemory {
        var viewport = viewMemory?.viewport
        if let bundleURL = viewMemory?.bundleURL ?? currentBundleURL, let owner = viewMemoryViewport,
           owner.viewportShows(bundleURL), let shown = owner.captureViewportMemory() {
            viewport = shown
            viewMemory?.viewport = shown
        }
        return ReferenceViewerMemory(
            display: ReferenceViewerDisplay(capturedViewState()),
            locus: referenceFrame.map {
                ViewMemoryLocus(sequenceName: $0.chromosome, sequenceLength: $0.sequenceLength, start: $0.start, end: $0.end)
            },
            viewport: viewport, drawer: viewMemory?.pendingDrawer ?? annotationDrawerView?.keptViewMemory)
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

    /// Tells the Inspector the view the viewer shows now, as a person's change in it would: the show switches, the row
    /// height and the spacing. The route wires the Inspector before a restore, which lands after the settle, so without
    /// this the Inspector keeps its own values and sends them back over the restored ones at its next change. It runs
    /// after a restore, an older bundle's starting view and a reset, and starts nothing (VS S4). A surface adopter of
    /// the reference kind (VS-MAP) calls it from its own `announceViewMemory()`.
    func announceViewMemory() {
        var next = parent
        while let controller = next, !(controller is MainSplitViewController) { next = controller.parent }
        guard let annotations = (next as? MainSplitViewController)?.inspectorController.annotationSectionViewModel else {
            return
        }
        annotations.showAnnotations = showAnnotations
        annotations.annotationHeight = Double(annotationDisplayHeight)
        annotations.annotationSpacing = Double(annotationDisplaySpacing)
        annotations.showVariants = viewerView.showVariants
    }

    /// Keeps the view as it stands for the item on show, in the store and never in the bundle (VS S1, S3).
    func keepViewMemory() {
        guard let session = viewMemory, session.bundleURL == currentBundleURL else { return }
        guard session.applied else {
            session.changedBeforeApply = true
            return
        }
        guard let read = session.read, let key = read.key else { return }
        session.store.keep(
            captureViewerMemory().held(from: session.start), startingView: session.start.withoutSelection(), for: key,
            dataKey: read.dataKey, folder: read.item.folder)
    }

    /// Keeps the view as it stands now, a pending change and a change to the viewport's list alike. The viewport calls
    /// it before the surface host removes it (VS-REF SWIFT SF-1), and the window close and the quit call it. The store
    /// keeps nothing equal to the starting view (VS S3), and the visit stays, so a later change is still kept.
    func keepViewMemoryNow() {
        saveCurrentViewState()
        keepViewMemory()
    }

    /// A person's pick of a row of the viewport's list: a click, a keyboard move or a selection change the list did not
    /// make itself. Before the restore runs it is a change under VS A2, even on the row the list selects by itself, so
    /// the restore keeps it and keeps it at once (LESSONS 1, VS-MAP-RACE). After the restore it changes nothing.
    func noteViewMemoryPick() {
        guard let session = viewMemory, !session.applied else { return }
        session.pickedBeforeApply = true
        session.changedBeforeApply = true
    }

    /// Ends the visit: keeps what stands, then removes the line (VS U2). A change to the viewport's list sets no
    /// pending save, so the visit keeps the view as it ends, and the store keeps nothing equal to the starting view.
    func leaveViewMemory() {
        saveCurrentViewState()
        keepViewMemory()
        viewMemory?.line?.removeFromSuperview()
        viewMemory = nil
    }

    func showViewMemoryLine(_ words: String, in session: ReferenceViewerMemorySession) {
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
        keepViewMemoryNow()
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
        announceViewMemory()

        guard let session = viewMemory else { return }
        viewStateSaveWorkItem?.cancel()
        viewStateSaveWorkItem = nil
        session.start = captureViewerMemory()
        session.line?.removeFromSuperview()
        session.line = nil
        guard session.applied else {
            session.resetBeforeApply = true
            return
        }
        guard let read = session.read, let key = read.key else { return }
        session.store.reset(key, kind: ReferenceViewerMemory.kind, folder: read.item.folder)
        viewMemoryLogger.info("resetBundleViewToDefaults: left the item's retire mark in the view memory store")
    }

    /// While the restore applies the viewport's list, a restored row's alignment action context is withheld until
    /// the person picks or clicks it (SWIFT-EVIDENCE-HASH). The visit notes it, and the viewer and the Inspector
    /// redraw, so they can say how to load it (VS-MAP-2 item 6).
    func withholdsAlignmentActionContext() -> Bool {
        guard let session = viewMemory, session.restoringViewport else { return false }
        session.contextWithheld = true
        viewerView?.needsDisplay = true
        onAlignmentConsensusActionStateChanged?()
        return true
    }

    /// The cue a restored row shows until the person clicks it, nil otherwise (VS-MAP-2 item 6): the restore withheld
    /// the row's context, and the row is still selected with no context and no context task. It starts nothing.
    var alignmentEvidenceCue: String? {
        guard viewMemory?.contextWithheld == true, alignmentActionContext == nil,
              viewMemoryViewport?.selectedRowAwaitsItsContext == true else { return nil }
        return ViewMemoryWords.alignmentEvidenceCue
    }
}

extension SequenceViewerView {
    /// The words drawn beside the consensus row's label (VS-MAP-2 item 6).
    var consensusRowCue: String? { viewController?.alignmentEvidenceCue }
}

