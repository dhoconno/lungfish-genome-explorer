// GenotypeResultViewController+ViewMemory.swift - The genotype result viewer keeps its view in the view memory store
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The genotype route configures the viewer after the host installs it (`ViewerViewController+Genotype.swift`), so the
// surface's load never knows the result and the viewer keeps its own view, as the reference viewer does
// (`ViewerViewController+ViewMemory.swift`). Each open reads the item, the store and an older bundle's own file off the
// main actor, a late restore applies only while the view is as the open showed it, and the visit's end keeps the view
// in the store. Nothing here writes into the bundle or the project, and nothing starts a tool, a write or a search
// (VS S4).

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow
import ObjectiveC

@MainActor private var genotypeViewMemoryStoreKey: UInt8 = 0
@MainActor private var genotypeViewMemorySessionKey: UInt8 = 0

/// The view the genotype result viewer keeps for one result.
///
/// Each field and its class (VS B2 to B9):
/// - `summaryViewMode`, Haplotype Calls or Genotype Matrix, and `layout`, the panel layout, are presentation and come
///   back on any data key. The result's presentation policy still normalizes them, so a result that cannot show the
///   kept mode shows its own, as at the base.
///
/// The older in-bundle file also holds `viewMode`, `panelLayout`, `cardDensity` and `cardDensityThreshold`, which no
/// control of the viewer reads, so only its `preferredSummaryViewMode` is taken. It holds no count filter.
struct GenotypeViewMemory: ViewMemoryState {
    static var kind: String { SurfaceKind.bundle(.genotypeResult).description }
    static var schemaVersion: Int { 1 }

    var summaryViewMode: String
    var layout: String
}

/// What an open reads off the main actor: where the result lives, its data key, the kept view, and an older bundle's
/// own file while the item has no entry and no retire mark (the revisit of plan decision S11).
struct GenotypeViewMemoryRead: Sendable {
    var item: ViewMemoryItem?
    var key: ViewMemoryKey?
    var dataKey: String?
    var kept: ViewMemoryRestorable<GenotypeViewMemory> = .nothing
    var olderFile: GenotypeResultViewState?

    /// Reads the disk and the store, so it runs off the main actor (SWIFT 2).
    static func read(bundleURL: URL, store: ViewMemoryStore) -> GenotypeViewMemoryRead {
        let item = ViewMemoryItem.read(at: bundleURL)
        if item.projectRoot == nil { store.loadLoose() }
        let key = store.key(for: item)
        let kept = key.map { store.restorable(GenotypeViewMemory.self, for: $0, folder: item.folder) } ?? .nothing
        // An older bundle's own file is a starting view only while the item has no entry and no retire mark.
        let olderFile = key.flatMap {
            store.hasRecord(for: $0) ? nil : GenotypeAnnotationStore.olderViewState(inBundleAt: bundleURL)
        }
        return GenotypeViewMemoryRead(
            item: item, key: key, dataKey: dataKey(ofBundleAt: bundleURL), kept: kept, olderFile: olderFile)
    }

    /// The data key of VS B1: the name, size and modification time of each file directly in the bundle other than the
    /// annotation sidecar and its record, which an edit rewrites while the data stays. A rerun changes it. Nil when
    /// the bundle cannot be listed, so it never compares equal. No field of item 1 depends on it.
    static func dataKey(ofBundleAt bundleURL: URL) -> String? {
        let skipped: Set<String> = [
            GenotypeAnnotationSidecar.filename,
            ProvenanceRecorder.fileSidecarURL(for: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
                .lastPathComponent,
        ]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: bundleURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var parts = ["genotype v1"]
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where !skipped.contains(url.lastPathComponent) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.isRegularFile == true else { continue }
            let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? -1
            parts.append("\(url.lastPathComponent) \(values.fileSize ?? -1) \(stamp)")
        }
        return parts.joined(separator: "\n")
    }
}

/// One visit of the viewer to a result.
@MainActor
final class GenotypeViewMemorySession {
    let store: ViewMemoryStore
    let bundleURL: URL
    /// The view the open showed, which a late restore must still find, so a change made before it stays (VS A2).
    let opening: GenotypeViewMemory
    /// The view a capture compares with, so a view equal to it is not kept (VS S3).
    var start: GenotypeViewMemory
    var read: GenotypeViewMemoryRead?
    var applied = false
    var resetBeforeApply = false
    var line: ViewMemoryResetLineView?
    var task: Task<Void, Never>?

    init(store: ViewMemoryStore, bundleURL: URL, opening: GenotypeViewMemory) {
        self.store = store
        self.bundleURL = bundleURL
        self.opening = opening
        start = opening
    }
}

extension GenotypeResultViewController {
    /// The store the route hands the viewer, the window's surface host's store in the app and a test's own store in a
    /// test. Nil keeps nothing.
    public var viewMemoryStore: ViewMemoryStore? {
        get { objc_getAssociatedObject(self, &genotypeViewMemoryStoreKey) as? ViewMemoryStore }
        set { objc_setAssociatedObject(self, &genotypeViewMemoryStoreKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// The visit on show, nil when the viewer keeps nothing.
    var viewMemory: GenotypeViewMemorySession? {
        get { objc_getAssociatedObject(self, &genotypeViewMemorySessionKey) as? GenotypeViewMemorySession }
        set { objc_setAssociatedObject(self, &genotypeViewMemorySessionKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Whether the open's restore has run, for a test to wait on.
    var viewMemoryIsSettled: Bool { viewMemory?.applied ?? true }

    /// The view the open shows before the store's view lands: the sidecar's choice, else the result's default. It
    /// reads no file, since the older in-bundle file is read off the main actor.
    func initialSummaryViewMode(for result: ONTGenotypeResultBundleData) -> GenotypeSummaryViewMode {
        if let rawValue = annotationStore?.startingViewState.preferredSummaryViewMode,
           let mode = GenotypeSummaryViewMode(rawValue: rawValue) {
            return normalizedDisplayState(GenotypeResultDisplayState(viewportLens: .summary, summaryViewMode: mode))
                .summaryViewMode
        }
        return defaultSummaryViewMode(for: result)
    }

    /// The mode a refresh of the same result keeps, the one on show, so an AI haplotype revision does not drop the
    /// visit's choice. Nil for another result or no visit.
    func visitSummaryViewMode(for result: ONTGenotypeResultBundleData) -> GenotypeSummaryViewMode? {
        guard let session = viewMemory, session.bundleURL == result.bundleURL else { return nil }
        return GenotypeSummaryViewMode(rawValue: captureViewMemory().summaryViewMode)
    }

    /// The view as the viewer holds it now. A fallback the policy shows in place of a kept choice is never taken as a
    /// person's choice, as at the base.
    func captureViewMemory() -> GenotypeViewMemory {
        var mode = displayState.summaryViewMode.rawValue
        if presentationPolicy?.persistencePolicy == .preserveStoredPreference, let start = viewMemory?.start {
            mode = start.summaryViewMode
        }
        return GenotypeViewMemory(summaryViewMode: mode, layout: displayState.layout.rawValue)
    }

    /// Starts a visit after the configure, and reads off the main actor.
    func beginViewMemoryVisit(for result: ONTGenotypeResultBundleData) {
        guard let store = viewMemoryStore else { return }
        let bundleURL = result.bundleURL
        let session = GenotypeViewMemorySession(store: store, bundleURL: bundleURL, opening: captureViewMemory())
        viewMemory = session
        observeViewMemoryEnds()
        session.task = Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) {
                GenotypeViewMemoryRead.read(bundleURL: bundleURL, store: store)
            }.value
            guard let self, self.viewMemory === session, !Task.isCancelled else { return }
            session.read = read
            self.applyViewMemory(session)
        }
    }

    private func applyViewMemory(_ session: GenotypeViewMemorySession) {
        guard !session.applied, let read = session.read else { return }
        session.applied = true
        if session.resetBeforeApply {
            // Reset View ran before the read landed, so the reset stands and the retire mark is left now.
            if let key = read.key { session.store.reset(key, kind: GenotypeViewMemory.kind, folder: read.item?.folder) }
            return
        }
        // A late restore applies only while the view is as the open showed it, so a change made before it stays.
        guard captureViewMemory() == session.opening else { return }
        switch read.kept {
        case .view(let kept, _, _):
            restoreViewMemory(kept)
        case .folderChanged:
            showViewMemoryLine(ViewMemoryWords.viewReset, in: session)
            fallthrough
        case .nothing:
            guard let older = read.olderFile?.preferredSummaryViewMode else { return }
            // An older bundle's look is a starting view, never a person's choice (VS S3).
            restoreViewMemory(GenotypeViewMemory(summaryViewMode: older, layout: session.opening.layout))
            session.start = captureViewMemory()
        }
    }

    /// Applies a kept view through the programmatic path, which writes nothing, and tells the Inspector.
    private func restoreViewMemory(_ kept: GenotypeViewMemory) {
        var state = displayState
        if let mode = GenotypeSummaryViewMode(rawValue: kept.summaryViewMode) { state.summaryViewMode = mode }
        if let layout = GenotypeResultPanelLayout(rawValue: kept.layout) { state.layout = layout }
        guard state != displayState else { return }
        applyDisplayStateImmediately(state)
        onDisplayStateChanged?(displayState)
    }

    /// Keeps the view as it stands for the result on show, in the store and never in the bundle (VS S1, S3).
    func keepViewMemory() {
        guard let session = viewMemory, session.applied, let read = session.read, let key = read.key else { return }
        session.store.keep(
            captureViewMemory(), startingView: session.start, for: key, dataKey: read.dataKey, folder: read.item?.folder)
    }

    /// Ends the visit: keeps the view, then removes the line. Every removal and every reconfigure calls it.
    func leaveViewMemory() {
        guard let session = viewMemory else { return }
        keepViewMemory()
        session.task?.cancel()
        session.line?.removeFromSuperview()
        viewMemory = nil
    }

    /// Reset View for the result on show. It writes and deletes nothing in the bundle. It shows the view the open
    /// showed and leaves the item's retire mark, so an older bundle's own file is not read again and the reset is not
    /// undone at the next open (the revisit of plan decision S11).
    func resetViewMemory() {
        guard let session = viewMemory else { return }
        restoreViewMemory(session.opening)
        session.start = captureViewMemory()
        session.line?.removeFromSuperview()
        session.line = nil
        guard session.applied else {
            session.resetBeforeApply = true
            return
        }
        guard let read = session.read, let key = read.key else { return }
        session.store.reset(key, kind: GenotypeViewMemory.kind, folder: read.item?.folder)
    }

    private func showViewMemoryLine(_ words: String, in session: GenotypeViewMemorySession) {
        session.line?.removeFromSuperview()
        let line = ViewMemoryResetLineView(words: words)
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: view.topAnchor),
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        session.line = line
        NSAccessibility.post(element: line.label, notification: .announcementRequested, userInfo: [
            .announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Keeps the view when the window closes or the app quits, since nothing removes the viewer on those ways out, and
    /// at the quit writes the store before the app ends (VS S1).
    private func observeViewMemoryEnds() {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSApplication.willTerminateNotification] {
            center.removeObserver(self, name: name, object: nil)
            center.addObserver(self, selector: #selector(viewMemoryWillEnd(_:)), name: name, object: nil)
        }
    }

    @objc private func viewMemoryWillEnd(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window !== view.window { return }
        keepViewMemory()
        if notification.name == NSApplication.willTerminateNotification {
            viewMemory?.store.flushSynchronously()
        }
    }
}
