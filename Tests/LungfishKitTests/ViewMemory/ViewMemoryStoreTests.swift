// ViewMemoryStoreTests.swift - The view memory store's bounds, its not-loaded state and its files (VS A9, S1, S3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import Synchronization
import XCTest
@testable import LungfishKit

/// A view with a filter and a selection, as an adopter's state holds them.
struct ViewMemoryTestView: ViewMemoryState {
    static let kind = "test:view"
    static let schemaVersion = 1
    var filter = ""
    var selection: [String] = []

    var selectionCount: Int { selection.count }

    func withoutSelection() -> ViewMemoryTestView {
        var copy = self
        copy.selection = []
        return copy
    }
}

/// A clock a test moves by hand.
final class ViewMemoryTestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))

    func now() -> Date { value.withLock { $0 } }

    func advance(days: Double) {
        value.withLock { $0 = $0.addingTimeInterval(days * 86_400) }
    }
}

/// A project folder with one bundle in it, and a store root, under one temporary folder.
struct ViewMemoryFixture {
    let base: URL
    let project: URL
    let bundle: URL
    let storeRoot: URL

    init(bundleName: String = "run.lungfish12s") throws {
        base = try TestTempDirectory.make(prefix: "view-memory")
        project = base.appendingPathComponent("Walk.lungfish", isDirectory: true)
        bundle = project.appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
        storeRoot = base.appendingPathComponent("ViewMemory", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }

    func store(caps: ViewMemoryStore.Caps = .standard, clock: ViewMemoryTestClock = ViewMemoryTestClock()) -> ViewMemoryStore {
        ViewMemoryStore(root: storeRoot, caps: caps, debounce: 3_600, clock: { clock.now() })
    }

    /// A store that has read the project, with the bundle's item and key.
    func loaded(_ store: ViewMemoryStore, bundle url: URL? = nil) throws -> (ViewMemoryItem, ViewMemoryKey) {
        store.loadProject(at: project)
        let item = ViewMemoryItem.read(at: url ?? bundle)
        let key = try XCTUnwrap(store.key(for: item))
        return (item, key)
    }

    /// Every item file under the store root.
    func itemFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: storeRoot, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "json" }
    }

    func cleanup() {
        TestTempDirectory.cleanup(base)
    }
}

final class ViewMemoryStoreTests: XCTestCase {
    private let start = ViewMemoryTestView()
    private let changed = ViewMemoryTestView(filter: "Salmo", selection: ["sample-1|target-3"])

    func testAKeptViewComesBackInANewStoreOnTheSameRoot() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let first = fixture.store()
        let (item, key) = try fixture.loaded(first)
        first.keep(changed, startingView: start, for: key, dataKey: "data-1", folder: item.folder)
        first.flushSynchronously()

        let relaunched = fixture.store()
        let (again, sameKey) = try fixture.loaded(relaunched)
        XCTAssertEqual(sameKey, key)
        guard case .view(let view, let dataKey, let dropped) = relaunched.restorable(
            ViewMemoryTestView.self, for: sameKey, folder: again.folder) else { return XCTFail("no kept view") }
        XCTAssertEqual(view, changed)
        XCTAssertEqual(dataKey, "data-1")
        XCTAssertFalse(dropped)
    }

    func testAViewEqualToItsStartIsNotKeptAndAKeptOneTurnsIntoARetireMark() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        let (item, key) = try fixture.loaded(store)
        store.keep(start, startingView: start, for: key, dataKey: nil, folder: item.folder)
        XCTAssertFalse(store.hasRecord(for: key))

        store.keep(changed, startingView: start, for: key, dataKey: nil, folder: item.folder)
        store.keep(start, startingView: start, for: key, dataKey: nil, folder: item.folder)
        XCTAssertTrue(store.hasRecord(for: key), "the retire mark stays")
        guard case .nothing = store.restorable(ViewMemoryTestView.self, for: key, folder: item.folder) else {
            return XCTFail("a retire mark holds no view")
        }
    }

    func testACaptureBeforeTheProjectIsReadNeverReplacesTheEntry() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let first = fixture.store()
        let (item, key) = try fixture.loaded(first)
        first.keep(changed, startingView: start, for: key, dataKey: nil, folder: item.folder)
        first.flushSynchronously()

        let late = fixture.store()
        XCTAssertNil(late.key(for: ViewMemoryItem.read(at: fixture.bundle)), "not read is not no entry")
        late.keep(ViewMemoryTestView(filter: "other"), startingView: start, for: key, dataKey: nil, folder: item.folder)
        late.keep(start, startingView: start, for: key, dataKey: nil, folder: item.folder)
        late.flushSynchronously()

        _ = try fixture.loaded(late)
        guard case .view(let view, _, _) = late.restorable(ViewMemoryTestView.self, for: key, folder: item.folder) else {
            return XCTFail("the entry was lost")
        }
        XCTAssertEqual(view, changed)
    }

    func testACorruptOrOlderFileReadsAsNoEntry() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let first = fixture.store()
        let (item, key) = try fixture.loaded(first)
        first.keep(changed, startingView: start, for: key, dataKey: nil, folder: item.folder)
        first.flushSynchronously()
        let file = first.fileURL(for: key)
        try Data("{not json".utf8).write(to: file)

        let corrupt = fixture.store()
        _ = try fixture.loaded(corrupt)
        guard case .nothing = corrupt.restorable(ViewMemoryTestView.self, for: key, folder: item.folder) else {
            return XCTFail("a corrupt file read as a view")
        }

        var older = ViewMemoryRecord(kind: ViewMemoryTestView.kind, schemaVersion: 1, dataKey: nil,
                                     folder: item.folder, lastRestored: Date())
        older.format = 0
        try JSONEncoder().encode(older).write(to: file)
        let reader = fixture.store()
        _ = try fixture.loaded(reader)
        XCTAssertFalse(reader.hasRecord(for: key))
    }

    func testANewFolderAtTheBundlePathIsRefusedByItsIdentity() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let first = fixture.store()
        let (item, key) = try fixture.loaded(first)
        first.keep(changed, startingView: start, for: key, dataKey: nil, folder: item.folder)
        first.flushSynchronously()
        try FileManager.default.removeItem(at: fixture.bundle)
        try FileManager.default.createDirectory(at: fixture.bundle, withIntermediateDirectories: true)

        let later = fixture.store()
        let (newItem, sameKey) = try fixture.loaded(later)
        XCTAssertEqual(sameKey, key)
        XCTAssertNotEqual(newItem.folder, item.folder)
        guard case .folderChanged = later.restorable(ViewMemoryTestView.self, for: key, folder: newItem.folder) else {
            return XCTFail("a new folder at the path got the old view")
        }
        XCTAssertFalse(later.hasRecord(for: key))
    }

    func testTheItemBoundEvictsTheLeastRecentlyRestoredUnderTheInjectedClock() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let clock = ViewMemoryTestClock()
        let store = fixture.store(caps: ViewMemoryStore.Caps(maxItems: 2), clock: clock)
        store.loadProject(at: fixture.project)
        var keys: [ViewMemoryKey] = []
        for name in ["a", "b", "c"] {
            let bundle = fixture.project.appendingPathComponent("\(name).lungfish12s", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let item = ViewMemoryItem.read(at: bundle)
            let key = try XCTUnwrap(store.key(for: item))
            store.keep(changed, startingView: start, for: key, dataKey: nil, folder: item.folder)
            keys.append(key)
            clock.advance(days: 1)
        }
        XCTAssertFalse(store.hasRecord(for: keys[0]))
        XCTAssertTrue(store.hasRecord(for: keys[1]))
        XCTAssertTrue(store.hasRecord(for: keys[2]))
    }

    func testTheLaunchSweepAgesOutAnUnusedItemAndKeepsTheBounds() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let clock = ViewMemoryTestClock()
        let first = fixture.store(clock: clock)
        let (item, key) = try fixture.loaded(first)
        first.keep(changed, startingView: start, for: key, dataKey: nil, folder: item.folder)
        let other = fixture.project.appendingPathComponent("other.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherItem = ViewMemoryItem.read(at: other)
        let otherKey = try XCTUnwrap(first.key(for: otherItem))
        clock.advance(days: 10)
        first.keep(changed, startingView: start, for: otherKey, dataKey: nil, folder: otherItem.folder)
        first.flushSynchronously()
        XCTAssertEqual(fixture.itemFiles().count, 2)

        let bounded = fixture.store(caps: ViewMemoryStore.Caps(maxItems: 1), clock: clock)
        bounded.sweep()
        XCTAssertEqual(fixture.itemFiles().map(\.lastPathComponent), [otherKey.fileName], "the older item goes first")

        clock.advance(days: 181)
        let aged = fixture.store(clock: clock)
        aged.loadProject(at: fixture.project)
        XCTAssertTrue(fixture.itemFiles().isEmpty, "an item unused for 180 days goes at launch")
    }

    func testASelectionPastItsCapIsDroppedWholeAndSaysSo() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let store = fixture.store(caps: ViewMemoryStore.Caps(maxSelectionIdentities: 2))
        let (item, key) = try fixture.loaded(store)
        let large = ViewMemoryTestView(filter: "Salmo", selection: ["1", "2", "3"])
        store.keep(large, startingView: start, for: key, dataKey: nil, folder: item.folder)
        store.flushSynchronously()

        let reader = fixture.store()
        _ = try fixture.loaded(reader)
        guard case .view(let view, _, let dropped) = reader.restorable(
            ViewMemoryTestView.self, for: key, folder: item.folder) else { return XCTFail("no kept view") }
        XCTAssertEqual(view, ViewMemoryTestView(filter: "Salmo"))
        XCTAssertTrue(dropped)
    }

    func testTwoStoresOnOneRootLeaveFilesThatAllDecodeAndTheLastWriteWins() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let one = fixture.store()
        let two = fixture.store()
        let (item, key) = try fixture.loaded(one)
        _ = try fixture.loaded(two)
        one.keep(ViewMemoryTestView(filter: "one"), startingView: start, for: key, dataKey: nil, folder: item.folder)
        two.keep(ViewMemoryTestView(filter: "two"), startingView: start, for: key, dataKey: nil, folder: item.folder)
        one.flushSynchronously()
        two.flushSynchronously()

        for file in fixture.itemFiles() {
            XCTAssertNoThrow(try JSONDecoder().decode(ViewMemoryRecord.self, from: Data(contentsOf: file)))
        }
        let reader = fixture.store()
        _ = try fixture.loaded(reader)
        guard case .view(let view, _, _) = reader.restorable(ViewMemoryTestView.self, for: key, folder: item.folder) else {
            return XCTFail("no kept view")
        }
        XCTAssertEqual(view.filter, "two")
    }

    func testARestoreAloneWritesNothing() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let clock = ViewMemoryTestClock()
        let first = fixture.store(clock: clock)
        let (item, key) = try fixture.loaded(first)
        first.keep(changed, startingView: start, for: key, dataKey: nil, folder: item.folder)
        first.flushSynchronously()
        let file = first.fileURL(for: key)
        let before = try Data(contentsOf: file)

        clock.advance(days: 1)
        let reader = fixture.store(clock: clock)
        _ = try fixture.loaded(reader)
        _ = reader.restorable(ViewMemoryTestView.self, for: key, folder: item.folder)
        XCTAssertEqual(try Data(contentsOf: file), before, "the restore time waits for the next write or the quit")
        reader.flushSynchronously()
        XCTAssertNotEqual(try Data(contentsOf: file), before, "the quit flush writes the restore time")
    }
}
