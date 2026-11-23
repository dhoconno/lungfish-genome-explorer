// ViewportHostViewMemoryTests.swift - The host keeps each view through a switch, a quit and two windows (VS S1, S2, A2, U2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishKit

private final class MemoryStandInController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    }
}

/// A surface whose view is a filter and a selection, read and set as its own controls.
@MainActor
private final class MemoryStandInSurface: ViewMemoryAdopting {
    struct Input {
        let url: URL
        var dataKey: String? = "data-1"
        var pending = false
    }

    static let kind = SurfaceKind.view(SurfaceViewID(rawValue: "memory-stand-in"))

    let viewController: NSViewController = MemoryStandInController()
    let surfaceKind = MemoryStandInSurface.kind
    var viewMemoryItem: ViewMemoryItem?
    var viewMemoryDataKey: String?
    var viewMemoryLoadIsPending = false
    var viewMemoryHandle: ViewMemoryHandle<ViewMemoryTestView>?
    var filter = ""
    var selection: [String] = []
    var restoredWithChangedData: Bool?

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let input = try expectInput(input, as: Input.self)
        viewMemoryItem = ViewMemoryItem.read(at: input.url)
        viewMemoryDataKey = input.dataKey
        viewMemoryLoadIsPending = input.pending
    }

    func captureViewMemory() -> ViewMemoryTestView {
        ViewMemoryTestView(filter: filter, selection: selection)
    }

    func restoreViewMemory(_ state: ViewMemoryTestView, dataChanged: Bool) -> ViewMemoryLoss {
        restoredWithChangedData = dataChanged
        filter = state.filter
        guard dataChanged else {
            selection = state.selection
            return []
        }
        selection = []
        return state.selection.isEmpty ? [] : .selection
    }
}

@MainActor
final class ViewportHostViewMemoryTests: XCTestCase {
    private var fixture: ViewMemoryFixture!
    private var other: URL!

    override func setUp() async throws {
        fixture = try ViewMemoryFixture()
        other = fixture.project.appendingPathComponent("other.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        fixture.cleanup()
    }

    private func makeHost(store: ViewMemoryStore) -> (ViewportHost, NSViewController) {
        let registry = SurfaceRegistry()
        registry.register(MemoryStandInSurface.kind) { MemoryStandInSurface() }
        let parent = MemoryStandInController()
        _ = parent.view
        return (ViewportHost(registry: registry, containerView: parent.view, parentController: parent,
                             viewMemoryStore: store), parent)
    }

    private func loadedStore() -> ViewMemoryStore {
        let store = fixture.store()
        store.loadProject(at: fixture.project)
        return store
    }

    @discardableResult
    private func show(_ host: ViewportHost, _ input: MemoryStandInSurface.Input) throws -> MemoryStandInSurface {
        host.show(kind: MemoryStandInSurface.kind, input: input)
        return try XCTUnwrap(host.activeViewport as? MemoryStandInSurface)
    }

    func testASwitchAwayAndBackBringsTheViewBack() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        first.selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        let back = try show(host, .init(url: fixture.bundle))
        XCTAssertEqual(back.filter, "Salmo")
        XCTAssertEqual(back.selection, ["sample-1|target-3"])
        XCTAssertEqual(back.restoredWithChangedData, false)
        XCTAssertNil(host.resetLine)
    }

    func testAChangeThenAQuitWithNoSwitchComesBackAfterARelaunch() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        let surface = try show(host, .init(url: fixture.bundle))
        surface.filter = "after the last switch"
        ViewMemoryQuit.captureEveryHostAndFlush()
        XCTAssertTrue(host.activeViewport === surface, "the quit capture removes nothing")

        let (relaunched, relaunchedParent) = makeHost(store: loadedStore())
        defer { _ = relaunchedParent }
        XCTAssertEqual(try show(relaunched, .init(url: fixture.bundle)).filter, "after the last switch")
    }

    func testChangedDataDropsTheSelectionAndSaysSoInOneLine() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        first.selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        let back = try show(host, .init(url: fixture.bundle, dataKey: "data-2"))
        XCTAssertEqual(back.restoredWithChangedData, true)
        XCTAssertEqual(back.filter, "Salmo")
        XCTAssertEqual(back.selection, [])
        XCTAssertEqual(host.resetLine?.words, "The data changed since your last visit, so your selection was not kept.")

        try show(host, .init(url: other))
        XCTAssertNil(host.resetLine, "the next show removes the line")
    }

    func testANewFolderAtThePathOpensAtTheStartWithTheResetWords() throws {
        let store = loadedStore()
        let (host, parent) = makeHost(store: store)
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).filter = "Salmo"
        try show(host, .init(url: other))
        try FileManager.default.removeItem(at: fixture.bundle)
        try FileManager.default.createDirectory(at: fixture.bundle, withIntermediateDirectories: true)

        let back = try show(host, .init(url: fixture.bundle))
        XCTAssertEqual(back.filter, "")
        XCTAssertEqual(host.resetLine?.words, ViewMemoryWords.viewReset)
    }

    func testCaptureActiveKeepsTheViewAndResetReturnsToTheStart() throws {
        let store = loadedStore()
        let (host, parent) = makeHost(store: store)
        defer { _ = parent }
        let surface = try show(host, .init(url: fixture.bundle))
        surface.filter = "Salmo"
        host.captureActive()
        let key = try XCTUnwrap(store.key(for: ViewMemoryItem.read(at: fixture.bundle)))
        XCTAssertTrue(store.hasRecord(for: key))
        XCTAssertTrue(host.activeViewport === surface)

        host.resetViewMemory()
        XCTAssertEqual(surface.filter, "")
        XCTAssertTrue(store.hasRecord(for: key), "the retire mark stays")
        guard case .nothing = store.restorable(ViewMemoryTestView.self, for: key, folder: surface.viewMemoryItem?.folder) else {
            return XCTFail("Reset View left a view")
        }
    }

    func testALateRestoreAppliesOnlyWhileTheViewEqualsItsStart() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).filter = "kept"
        try show(host, .init(url: other))

        let untouched = try show(host, .init(url: fixture.bundle, pending: true))
        XCTAssertEqual(untouched.filter, "", "nothing applies before the adopter's own load commits")
        untouched.viewMemoryHandle?.applyPending()
        XCTAssertEqual(untouched.filter, "kept")

        try show(host, .init(url: other))
        let typed = try show(host, .init(url: fixture.bundle, pending: true))
        typed.filter = "typed while loading"
        typed.viewMemoryHandle?.applyPending()
        XCTAssertEqual(typed.filter, "typed while loading", "a late restore never overwrites a person's change")
    }

    func testTwoWindowsOnOneBundleShareOneEntryAndTheLastChangeWins() throws {
        let store = loadedStore()
        let (one, oneParent) = makeHost(store: store)
        let (two, twoParent) = makeHost(store: store)
        defer { _ = (oneParent, twoParent) }
        try show(one, .init(url: fixture.bundle)).filter = "one"
        try show(two, .init(url: fixture.bundle)).filter = "two"
        one.captureActive()
        two.captureActive()

        let (third, thirdParent) = makeHost(store: store)
        defer { _ = thirdParent }
        XCTAssertEqual(try show(third, .init(url: fixture.bundle)).filter, "two")
    }

    func testAProjectWhoseEntriesAreNotReadKeepsNothing() throws {
        let store = fixture.store()
        let (host, parent) = makeHost(store: store)
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).filter = "Salmo"
        try show(host, .init(url: other))
        store.flushSynchronously()
        XCTAssertTrue(fixture.itemFiles().isEmpty)
    }

    func testTheWordsNameWhatWasNotKeptInOrder() {
        XCTAssertNil(ViewMemoryWords.dataChanged([]))
        XCTAssertEqual(ViewMemoryWords.dataChanged(.place),
                       "The data changed since your last visit, so your place was not kept.")
        XCTAssertEqual(ViewMemoryWords.dataChanged(.filters),
                       "The data changed since your last visit, so your filters were not kept.")
        XCTAssertEqual(ViewMemoryWords.dataChanged([.filters, .place]),
                       "The data changed since your last visit, so your place and filters were not kept.")
        let all = try? XCTUnwrap(ViewMemoryWords.dataChanged([.place, .selection, .filters, .sampleChoice]))
        XCTAssertEqual(all, "The data changed since your last visit, so your place, selection, filters and sample choice were not kept.")
        XCTAssertEqual(all?.split(separator: " ").count, 18)
        for words in [ViewMemoryWords.viewReset, ViewMemoryWords.selectionTooLarge, all ?? ""] {
            XCTAssertLessThanOrEqual(words.split(separator: " ").count, 20)
            XCTAssertFalse(words.contains(";") || words.contains(":") || words.contains("\u{2014}"))
        }
    }
}
