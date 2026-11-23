// ViewMemoryStore+Files.swift - The store's writer queue, its reads of a folder and its launch sweep
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os

private let viewMemoryLogger = Logger(subsystem: LogSubsystem.app, category: "ViewMemory")

extension ViewMemoryStore {
    // MARK: - Writes

    /// Writes every changed item now and joins the writer queue, so a write in flight ends first and an older view
    /// never lands after a newer one, and a project read the queue holds ends first too. It reads nothing itself and
    /// writes only changed items, with the restore times. The quit calls it on the main thread, its one write there
    /// (VS S1), and a test calls it to see the files.
    public func flushSynchronously() {
        writer.sync { writePending(includingRestoreTimes: true) }
    }

    /// Writes the changed items about one debounce after the last capture. A newer capture moves the write on.
    func scheduleWrite() {
        let generation = contents.withLock { contents -> UInt64 in
            contents.writeGeneration &+= 1
            return contents.writeGeneration
        }
        writer.asyncAfter(deadline: .now() + debounce) { [self] in
            guard contents.withLock({ $0.writeGeneration == generation }) else { return }
            writePending(includingRestoreTimes: false)
        }
    }

    /// Runs on the writer queue. It copies the changed items under the lock and releases it, then encodes and writes
    /// each one, so a capture never waits on a sync.
    func writePending(includingRestoreTimes: Bool) {
        let (writes, removals) = contents.withLock { contents -> ([(ViewMemoryKey, Entry)], [ViewMemoryKey]) in
            var keys = contents.dirty
            if includingRestoreTimes { keys.formUnion(contents.touched) }
            contents.touched.subtract(keys)
            let writes = keys.compactMap { key in contents.entries[key].map { (key, $0) } }
            let removals = Array(contents.removed)
            contents.dirty.removeAll()
            contents.removed.removeAll()
            return (writes, removals)
        }
        for key in removals {
            removeFile(for: key)
        }
        for (key, entry) in writes {
            write(entry, for: key)
        }
    }

    /// Writes one item as one whole file through ``DurableReplace``. Past the record cap the selection goes first,
    /// then the record. A failed write is logged and shows no words (VS U4).
    func write(_ entry: Entry, for key: ViewMemoryKey) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var record = entry.record
        if let view = entry.view {
            guard let encoded = encodedState(view, encoder: encoder) else { return removeFile(for: key) }
            record.state = encoded.data
            if encoded.selectionDropped { record.selectionDropped = true }
        }
        guard let file = try? encoder.encode(record), file.count <= caps.maxRecordBytes else {
            return removeFile(for: key)
        }
        let folderURL = root.appendingPathComponent(key.folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            try DurableReplace.replace(file, named: key.fileName, in: folderURL)
        } catch {
            viewMemoryLogger.error(
                "View memory did not keep \(key.description, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The view's bytes, with its selection dropped whole when the selection passes its byte cap or the view passes
    /// the record cap. Nil when the view does not encode.
    func encodedState<State: ViewMemoryState>(_ view: State, encoder: JSONEncoder) -> (data: Data, selectionDropped: Bool)? {
        guard let data = try? encoder.encode(view) else { return nil }
        guard view.selectionCount > 0, let bare = try? encoder.encode(view.withoutSelection()),
              data.count - bare.count > caps.maxSelectionBytes || data.count > caps.maxRecordBytes else {
            return (data, false)
        }
        return (bare, true)
    }

    func fileURL(for key: ViewMemoryKey) -> URL {
        root.appendingPathComponent(key.folder, isDirectory: true).appendingPathComponent(key.fileName)
    }

    func removeFile(for key: ViewMemoryKey) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    // MARK: - Reads

    /// The records of one folder. A file that does not decode, or is of another format, is read as no entry.
    func readRecords(inFolder folder: String) -> [(ViewMemoryKey, ViewMemoryRecord)] {
        let folderURL = root.appendingPathComponent(folder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) else { return [] }
        let decoder = JSONDecoder()
        return names.compactMap { name -> (ViewMemoryKey, ViewMemoryRecord)? in
            guard name.hasSuffix(".json"), !name.hasPrefix("."),
                  let data = try? Data(contentsOf: folderURL.appendingPathComponent(name)),
                  let record = try? decoder.decode(ViewMemoryRecord.self, from: data),
                  record.format == ViewMemoryRecord.currentFormat else { return nil }
            return (ViewMemoryKey(rawValue: String(name.dropLast(5)), folder: folder), record)
        }
    }

    // MARK: - The launch sweep

    func runLaunchWorkOnce() {
        let first = contents.withLock { contents -> Bool in
            guard !contents.launchWorkDone else { return false }
            contents.launchWorkDone = true
            return true
        }
        if first { sweep() }
    }

    /// Removes the items not restored within the lifetime, then the least recently restored past the item and byte
    /// bounds (VS A9). An item whose bundle was deleted ages out here. A file that does not decode counts by its
    /// modification date. It reads and removes files, so it runs off the main actor, once a launch at the first read.
    public func sweep() {
        let fileManager = FileManager.default
        let decoder = JSONDecoder()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var items: [(url: URL, lastRestored: Date, bytes: Int)] = []
        let folders = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
            for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
                let values = try? file.resourceValues(forKeys: Set(keys))
                let data = try? Data(contentsOf: file)
                let record = data.flatMap { try? decoder.decode(ViewMemoryRecord.self, from: $0) }
                let restored = record?.lastRestored ?? values?.contentModificationDate ?? .distantPast
                items.append((file, restored, values?.fileSize ?? data?.count ?? 0))
            }
        }
        let cutoff = clock().addingTimeInterval(-caps.unusedLifetime)
        var kept: [(url: URL, lastRestored: Date, bytes: Int)] = []
        for item in items {
            if item.lastRestored < cutoff {
                try? fileManager.removeItem(at: item.url)
            } else {
                kept.append(item)
            }
        }
        kept.sort { $0.lastRestored < $1.lastRestored }
        var count = kept.count
        var bytes = kept.reduce(0) { $0 + $1.bytes }
        for item in kept where count > caps.maxItems || bytes > caps.maxTotalBytes {
            try? fileManager.removeItem(at: item.url)
            count -= 1
            bytes -= item.bytes
        }
    }
}
