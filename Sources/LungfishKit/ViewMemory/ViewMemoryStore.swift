// ViewMemoryStore.swift - The one place on this Mac that keeps each item's last view
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import Synchronization

/// What the store holds for one item at a restore, as one view type reads it.
public enum ViewMemoryRestorable<State: ViewMemoryState>: Sendable {
    /// No entry, a retire mark, a record of another kind or schema, or a file that would not read. No line shows.
    case nothing
    /// The record was kept for another folder at the item's path, so the store removed it (word 3).
    case folderChanged
    /// The kept view, the data key it was kept with, and whether its selection passed the cap (word 4).
    case view(State, dataKey: String?, selectionDropped: Bool)
}

/// The one store of the last view of each item, on this Mac and outside every project (VS A1, A4, S1, A9).
///
/// It keeps one map behind a `Mutex`, and memory is the truth within a run, so a switch writes nothing. One serial
/// queue writes each changed item about a second after the last capture, as one whole file through
/// ``DurableReplace``, after it has copied the changed items under the lock and released it. A project's entries are
/// read once, off the main actor, inside the project open, or on the writer queue at the first key request of a
/// project no open read, and until then a capture for the project changes nothing, so "not read" is never taken for
/// "no entry". A restore reads only memory, and the time it marks is written with
/// the item's next write or at the quit. ``flushSynchronously()`` is the quit's one write on the main thread.
///
/// The layout under ``root`` is one folder a project, named by the SHA-256 of `v1|<root identity>`, holding one file
/// an item, named by its ``ViewMemoryKey``, and one `loose` folder for items outside any project.
public final class ViewMemoryStore: Sendable {
    /// The bounds of the store (VS A9). A test injects smaller ones.
    public struct Caps: Sendable, Equatable {
        /// Items across every project, the least recently restored going first.
        public var maxItems: Int
        /// Bytes of every item file together.
        public var maxTotalBytes: Int
        /// Bytes of one item file. Past it the selection goes first, then the record.
        public var maxRecordBytes: Int
        /// Identities of one selection, past which it is dropped whole (VS B3).
        public var maxSelectionIdentities: Int
        /// Encoded bytes of one selection, past which it is dropped whole.
        public var maxSelectionBytes: Int
        /// How long an item may go unrestored before the launch sweep removes it.
        public var unusedLifetime: TimeInterval

        public init(maxItems: Int = 2_000, maxTotalBytes: Int = 16 << 20, maxRecordBytes: Int = 64 << 10,
                    maxSelectionIdentities: Int = 1_000, maxSelectionBytes: Int = 32 << 10,
                    unusedLifetime: TimeInterval = 180 * 86_400) {
            self.maxItems = maxItems
            self.maxTotalBytes = maxTotalBytes
            self.maxRecordBytes = maxRecordBytes
            self.maxSelectionIdentities = maxSelectionIdentities
            self.maxSelectionBytes = maxSelectionBytes
            self.unusedLifetime = unusedLifetime
        }

        /// The bounds the app runs with.
        public static let standard = Caps()
    }

    struct Entry: Sendable {
        var record: ViewMemoryRecord
        /// The latest capture, which the writer encodes into the record's state. Nil for an entry read from disk.
        var view: (any ViewMemoryState)?
    }

    struct Root: Sendable {
        let rootText: String
        let folder: String
    }

    struct Contents: Sendable {
        /// Each project root read so far, by its canonical path.
        var roots: [String: Root] = [:]
        /// The roots a key request found not read and sent to the writer queue, each once a run.
        var requestedRoots: Set<String> = []
        /// The folders whose files are read.
        var loaded: Set<String> = []
        var entries: [ViewMemoryKey: Entry] = [:]
        /// Items to write at the next write.
        var dirty: Set<ViewMemoryKey> = []
        /// Items whose only change is the time of a restore, written with their next write or at the quit.
        var touched: Set<ViewMemoryKey> = []
        /// Items whose file goes at the next write.
        var removed: Set<ViewMemoryKey> = []
        var writeGeneration: UInt64 = 0
        var launchWorkDone = false
    }

    /// The folder that holds every item file.
    public let root: URL
    let caps: Caps
    let debounce: TimeInterval
    let clock: @Sendable () -> Date
    let contents = Mutex(Contents())
    let writer = DispatchQueue(label: "com.lungfish.view-memory.writer", qos: .utility)

    /// A store under `root`. The app uses ``shared``, and a test injects its own root, caps, debounce and clock.
    public init(root: URL, caps: Caps = .standard, debounce: TimeInterval = 1,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.caps = caps
        self.debounce = debounce
        self.clock = clock
    }

    // MARK: - The process default

    private static let defaultRootOverride = Mutex<URL?>(nil)

    /// Points the process default at `root`. The test bootstrap calls it when a test bundle loads, before any host
    /// makes the default, so a window built with no AppDelegate keeps its views in a per-process folder (VS A6, Q2).
    /// It changes nothing once the default exists.
    public static func redirectDefaultRoot(to root: URL) {
        defaultRootOverride.withLock { $0 = root }
    }

    /// The one store of the process, under Application Support (VS A1, A4).
    public static let shared = ViewMemoryStore(root: defaultRoot())

    /// `~/Library/Application Support/<applicationSupportDirectoryName>/ViewMemory/`, which Preview and Stable share
    /// and Debug keeps apart, unless the test bootstrap redirected it. It is never in a project and never in
    /// `UserDefaults.standard`.
    static func defaultRoot(appIdentity: LungfishAppIdentity = .current, fileManager: FileManager = .default) -> URL {
        if let redirected = defaultRootOverride.withLock({ $0 }) { return redirected }
        if let uiTestPath = AppUITestConfiguration.current.viewStatePath { return uiTestPath }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support",
                                                                             isDirectory: true)
        return support
            .appendingPathComponent(appIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("ViewMemory", isDirectory: true)
    }

    // MARK: - Reading a project's entries

    /// Reads the entries of the project at `projectURL` once, so a restore reads only memory (VS S1, A9). It reads
    /// the disk, so the project open calls it off the main actor and awaits it before the window's first content
    /// show. The first read of a launch also runs ``sweep()``.
    public func loadProject(at projectURL: URL) {
        runLaunchWorkOnce()
        let canonical = ViewMemoryItem.canonical(projectURL)
        guard let identity = try? ProjectRoot.rootIdentity(at: canonical) else { return }
        let rootText = ViewMemoryKey.rootText(identity: identity, canonicalRoot: canonical)
        let root = Root(rootText: rootText, folder: ViewMemoryKey.projectFolder(rootText: rootText))
        contents.withLock { $0.roots[canonical.path] = root }
        load(folder: root.folder)
    }

    /// Reads the entries of the items outside any project once. It reads the disk, so it runs off the main actor.
    public func loadLoose() {
        runLaunchWorkOnce()
        load(folder: ViewMemoryKey.looseFolder)
    }

    func load(folder: String) {
        guard !contents.withLock({ $0.loaded.contains(folder) }) else { return }
        let records = readRecords(inFolder: folder)
        contents.withLock { contents in
            guard !contents.loaded.contains(folder) else { return }
            for (key, record) in records where contents.entries[key] == nil {
                contents.entries[key] = Entry(record: record, view: nil)
            }
            contents.loaded.insert(folder)
        }
    }

    // MARK: - Keys and restores, which read only memory

    /// The key of `item`, or nil while the entries of its project, or of the items outside any project, are not
    /// read, so nothing is restored or kept for it. The first request for a project that no open read starts its
    /// read on the writer queue (``readInBackground(_:)``), so a later visit has a key.
    public func key(for item: ViewMemoryItem) -> ViewMemoryKey? {
        guard let projectRoot = item.projectRoot else {
            let loaded = contents.withLock { $0.loaded.contains(ViewMemoryKey.looseFolder) }
            return loaded ? .loose(path: item.path) : nil
        }
        let found: (rootText: String?, readNow: Bool) = contents.withLock { contents in
            guard let root = contents.roots[projectRoot.path] else {
                return (nil, contents.requestedRoots.insert(projectRoot.path).inserted)
            }
            return (contents.loaded.contains(root.folder) ? root.rootText : nil, false)
        }
        if found.readNow { readInBackground(projectRoot) }
        return found.rootText.map { ViewMemoryKey.project(rootText: $0, path: item.path) }
    }

    /// Reads the entries of a project that no open read, such as one made with File > New Project in this run or one
    /// moved while open, on the writer queue and never on the main actor (SWIFT 2). It runs once a root a run, so
    /// a root whose identity cannot be read is tried once, and ``flushSynchronously()`` joins it.
    func readInBackground(_ projectRoot: URL) {
        writer.async { [self] in loadProject(at: projectRoot) }
    }

    /// Whether the item holds a kept view or a retire mark, so an older bundle's own view file is not read for it.
    public func hasRecord(for key: ViewMemoryKey) -> Bool {
        contents.withLock { $0.entries[key] != nil }
    }

    /// The view kept for `key` as `type` reads it, for an item whose folder identity is now `folder`. A record kept
    /// for another folder at the path is removed (VS A3). A kept view or a retire mark marks the time of its visit in
    /// memory.
    public func restorable<State: ViewMemoryState>(
        _ type: State.Type, for key: ViewMemoryKey, folder: ViewMemoryFolderIdentity?
    ) -> ViewMemoryRestorable<State> {
        let now = clock()
        let found: (entry: Entry?, folderChanged: Bool) = contents.withLock { contents in
            guard contents.loaded.contains(key.folder), var entry = contents.entries[key] else { return (nil, false) }
            guard entry.record.folder == folder else {
                contents.entries[key] = nil
                contents.dirty.remove(key)
                contents.touched.remove(key)
                contents.removed.insert(key)
                return (nil, true)
            }
            // A visit marks the time of a retire mark too, so a mark in use never ages out and an older bundle's own
            // view file is never read again for the item.
            entry.record.lastRestored = now
            contents.entries[key] = entry
            contents.touched.insert(key)
            guard !entry.record.retired, entry.record.kind == State.kind,
                  entry.record.schemaVersion == State.schemaVersion else { return (nil, false) }
            return (entry, false)
        }
        guard let entry = found.entry else { return found.folderChanged ? .folderChanged : .nothing }
        let record = entry.record
        if let view = entry.view as? State {
            return .view(view, dataKey: record.dataKey, selectionDropped: record.selectionDropped)
        }
        guard let data = record.state, let view = try? JSONDecoder().decode(State.self, from: data) else { return .nothing }
        return .view(view, dataKey: record.dataKey, selectionDropped: record.selectionDropped)
    }

    // MARK: - Captures

    /// Keeps `view` for the item, written about a second after the last capture (VS S1). A view equal to
    /// `startingView` is not kept (VS S3): a kept view turns into a retire mark and no entry stays none. A selection
    /// past its cap is dropped whole (VS A9, B3). A capture for an item whose entries are not read changes nothing.
    public func keep<State: ViewMemoryState>(
        _ view: State, startingView: State, for key: ViewMemoryKey, dataKey: String?,
        folder: ViewMemoryFolderIdentity?
    ) {
        let now = clock()
        let isStart = view == startingView
        let overCap = view.selectionCount > caps.maxSelectionIdentities
        let kept = overCap ? view.withoutSelection() : view
        let changed: Bool = contents.withLock { contents in
            guard contents.loaded.contains(key.folder) else { return false }
            let old = contents.entries[key]
            if isStart {
                guard let old, !old.record.retired else { return false }
                contents.entries[key] = Entry(
                    record: .retireMark(after: old.record, kind: State.kind, folder: folder, at: now), view: nil)
            } else {
                if let old, !old.record.retired, let same = old.view as? State, same == kept,
                   old.record.dataKey == dataKey, old.record.folder == folder,
                   old.record.selectionDropped == overCap { return false }
                let record = ViewMemoryRecord(
                    kind: State.kind, schemaVersion: State.schemaVersion, dataKey: dataKey, folder: folder,
                    lastRestored: old?.record.lastRestored ?? now, selectionDropped: overCap)
                contents.entries[key] = Entry(record: record, view: kept)
            }
            contents.removed.remove(key)
            contents.dirty.insert(key)
            evictPastBound(&contents, keeping: key)
            return true
        }
        if changed { scheduleWrite() }
    }

    /// Removes the item's kept view and leaves its retire mark, for Reset View (VS U3).
    public func reset(_ key: ViewMemoryKey, kind: String, folder: ViewMemoryFolderIdentity?) {
        let now = clock()
        let changed: Bool = contents.withLock { contents in
            guard contents.loaded.contains(key.folder) else { return false }
            contents.entries[key] = Entry(
                record: .retireMark(after: contents.entries[key]?.record, kind: kind, folder: folder, at: now),
                view: nil)
            contents.removed.remove(key)
            contents.dirty.insert(key)
            return true
        }
        if changed { scheduleWrite() }
    }

    /// Past the item bound, removes the least recently restored items other than `key`.
    func evictPastBound(_ contents: inout Contents, keeping key: ViewMemoryKey) {
        let excess = contents.entries.count - caps.maxItems
        guard excess > 0 else { return }
        let victims = contents.entries.filter { $0.key != key }
            .sorted { $0.value.record.lastRestored < $1.value.record.lastRestored }
            .prefix(excess)
        for (victim, _) in victims {
            contents.entries[victim] = nil
            contents.dirty.remove(victim)
            contents.touched.remove(victim)
            contents.removed.insert(victim)
        }
    }
}
