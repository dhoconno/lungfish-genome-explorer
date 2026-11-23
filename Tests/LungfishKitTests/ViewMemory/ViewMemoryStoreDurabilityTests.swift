// ViewMemoryStoreDurabilityTests.swift - The view memory writer through DurableReplace, also under simulated ExFAT
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `bash scripts/testing/exfat-tests.sh --simulate ViewMemoryStoreDurability` runs this suite with every flagged
// rename taking its ExFAT fallback, since a suite whose name holds "Durability" runs there.

import Foundation
import XCTest
@testable import LungfishKit

final class ViewMemoryStoreDurabilityTests: XCTestCase {
    private let start = ViewMemoryTestView()

    /// The names in the store's folders other than whole item files: stage files, swap tombstones and the rest.
    private func leftovers(under root: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        let urls = enumerator?.allObjects as? [URL] ?? []
        return urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true && url.pathExtension != "json"
                || url.lastPathComponent.hasPrefix(".")
        }.map(\.lastPathComponent)
    }

    func testRewritingOneItemLeavesOneWholeFileWithTheLatestView() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        let (item, key) = try fixture.loaded(store)
        for round in 1...20 {
            store.keep(ViewMemoryTestView(filter: "round \(round)"), startingView: start, for: key, dataKey: nil,
                       folder: item.folder)
            store.flushSynchronously()
        }
        XCTAssertEqual(fixture.itemFiles().map(\.lastPathComponent), [key.fileName])
        XCTAssertEqual(leftovers(under: fixture.storeRoot), [])

        let reader = fixture.store()
        _ = try fixture.loaded(reader)
        guard case .view(let view, _, _) = reader.restorable(ViewMemoryTestView.self, for: key, folder: item.folder) else {
            return XCTFail("no kept view")
        }
        XCTAssertEqual(view.filter, "round 20")
    }

    func testTheQuitFlushJoinsAWriteInFlightSoTheNewestViewLandsLast() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let store = ViewMemoryStore(root: fixture.storeRoot, debounce: 0)
        let (item, key) = try fixture.loaded(store)
        store.keep(ViewMemoryTestView(filter: "older"), startingView: start, for: key, dataKey: nil, folder: item.folder)
        store.keep(ViewMemoryTestView(filter: "newer"), startingView: start, for: key, dataKey: nil, folder: item.folder)
        store.flushSynchronously()

        let record = try JSONDecoder().decode(ViewMemoryRecord.self, from: Data(contentsOf: store.fileURL(for: key)))
        let view = try JSONDecoder().decode(ViewMemoryTestView.self, from: XCTUnwrap(record.state))
        XCTAssertEqual(view.filter, "newer")
        XCTAssertEqual(leftovers(under: fixture.storeRoot), [])
    }

    func testAResetLeavesARetireMarkFileWithNoViewField() throws {
        let fixture = try ViewMemoryFixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        let (item, key) = try fixture.loaded(store)
        store.keep(ViewMemoryTestView(filter: "kept"), startingView: start, for: key, dataKey: "k", folder: item.folder)
        store.reset(key, kind: ViewMemoryTestView.kind, folder: item.folder)
        store.flushSynchronously()

        let record = try JSONDecoder().decode(ViewMemoryRecord.self, from: Data(contentsOf: store.fileURL(for: key)))
        XCTAssertTrue(record.retired)
        XCTAssertNil(record.state)
        XCTAssertNil(record.dataKey)
    }
}
