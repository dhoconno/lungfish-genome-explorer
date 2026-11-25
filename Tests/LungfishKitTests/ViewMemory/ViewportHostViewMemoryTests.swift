// ViewportHostViewMemoryTests.swift - The host keeps each view through a switch, a quit and two windows (VS S1, S2, A2, U2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishKit
import LungfishTestSupport

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
        var clearsOnDeactivate = false
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
    var clearsOnDeactivate = false
    /// What the surface announced to its listeners, one filter a call, as an Inspector would hear it.
    var announced: [String] = []

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let input = try expectInput(input, as: Input.self)
        viewMemoryItem = ViewMemoryItem.read(at: input.url)
        viewMemoryDataKey = input.dataKey
        viewMemoryLoadIsPending = input.pending
        clearsOnDeactivate = input.clearsOnDeactivate
    }

    func captureViewMemory() -> ViewMemoryTestView {
        ViewMemoryTestView(filter: filter, selection: selection)
    }

    /// Restores the filter and the selection only on an equal data key, as VS B6 restores a count filter or a search
    /// text, and drops both on a changed or unread key, saying so.
    func restoreViewMemory(_ state: ViewMemoryTestView, dataChanged: Bool) -> ViewMemoryLoss {
        restoredWithChangedData = dataChanged
        guard !dataChanged else {
            filter = ""
            selection = []
            var lost: ViewMemoryLoss = []
            if !state.filter.isEmpty { lost.insert(.filters) }
            if !state.selection.isEmpty { lost.insert(.selection) }
            return lost
        }
        filter = state.filter
        selection = state.selection
        return []
    }

    func announceViewMemory() {
        announced.append(filter)
    }

    /// A surface that tears its view down as it goes, so only a capture before this call sees the view.
    func willDeactivate(replacedBy next: SurfaceKind?) {
        guard clearsOnDeactivate else { return }
        filter = ""
        selection = []
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
        XCTAssertEqual(back.filter, "", "a filter restores only on an equal data key (VS B6)")
        XCTAssertEqual(back.selection, [])
        XCTAssertEqual(host.resetLine?.words,
                       "The data changed since your last visit, so your selection and filters were not restored.")

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

    func testALeaveBeforeTheLateRestoreKeepsTheSavedView() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).filter = "kept"
        try show(host, .init(url: other))

        try show(host, .init(url: fixture.bundle, pending: true))
        host.captureActive()
        try show(host, .init(url: other))

        XCTAssertEqual(try show(host, .init(url: fixture.bundle)).filter, "kept",
                       "a visit that ends before the adopter's own load commits keeps the saved view")
    }

    func testAResetBeforeTheLateRestoreIsNotUndoneWhenItLands() throws {
        let store = loadedStore()
        let (host, parent) = makeHost(store: store)
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).filter = "kept"
        try show(host, .init(url: other))

        let loading = try show(host, .init(url: fixture.bundle, pending: true))
        host.resetViewMemory()
        loading.viewMemoryHandle?.applyPending()
        XCTAssertEqual(loading.filter, "", "a Reset View made before the load commits is not undone when it does")
        try show(host, .init(url: other))
        let key = try XCTUnwrap(store.key(for: ViewMemoryItem.read(at: fixture.bundle)))
        guard case .nothing = store.restorable(ViewMemoryTestView.self, for: key, folder: loading.viewMemoryItem?.folder) else {
            return XCTFail("the reset left a view")
        }
        XCTAssertEqual(try show(host, .init(url: fixture.bundle)).filter, "", "the reset stays after a leave and a return")
    }

    func testAPendingAdopterWithNoKeptViewMovesItsStartAtApply() throws {
        let store = loadedStore()
        let (host, parent) = makeHost(store: store)
        defer { _ = parent }
        let key = try XCTUnwrap(store.key(for: ViewMemoryItem.read(at: fixture.bundle)))
        let loading = try show(host, .init(url: fixture.bundle, pending: true))
        loading.filter = "app default"
        loading.viewMemoryHandle?.applyPending(startingView: ViewMemoryTestView(filter: "app default"))
        try show(host, .init(url: other))
        XCTAssertFalse(store.hasRecord(for: key), "the app's own default is never kept as a person's choice (VS S3)")

        let again = try show(host, .init(url: fixture.bundle, pending: true))
        again.filter = "app default"
        again.viewMemoryHandle?.applyPending(startingView: ViewMemoryTestView(filter: "app default"))
        again.filter = "Salmo"
        try show(host, .init(url: other))
        XCTAssertEqual(try show(host, .init(url: fixture.bundle)).filter, "Salmo", "a change after the apply is kept")
    }

    func testALateApplyAfterTheSurfaceWasRemovedDrawsNoLine() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "kept"
        first.selection = ["x"]
        try show(host, .init(url: other))

        let removed = try show(host, .init(url: fixture.bundle, dataKey: "data-2", pending: true))
        let handle = try XCTUnwrap(removed.viewMemoryHandle)
        let installed = try show(host, .init(url: other))
        handle.applyPending()

        XCTAssertNil(host.resetLine, "a late restore draws nothing over the surface that took its place")
        XCTAssertNil(removed.restoredWithChangedData, "a removed surface takes no late restore")
        XCTAssertTrue(host.activeViewport === installed)
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

    // MARK: - Where the line sits (VS-HOST-LINE, UX-F1-R17)

    /// A host whose 400x300 container has a 40 pt safe area at its top, as a window's title bar and toolbar give the
    /// viewer. The stand-in keeps the default pin, the container's edge, as 12S and nine more adopters do.
    private func makeInsetHost(store: ViewMemoryStore) -> (ViewportHost, NSViewController) {
        let (host, parent) = makeHost(store: store)
        parent.view.additionalSafeAreaInsets = NSEdgeInsets(top: 40, left: 0, bottom: 0, right: 0)
        return (host, parent)
    }

    /// Reads the line's frame, never its words: its top sits at the safe-area top, 260 pt, not at the container's
    /// edge, 300 pt, where a window's toolbar covers it, and the surface starts at or below its bottom.
    private func assertLineStartsAtTheSafeAreaTop(
        _ host: ViewportHost, in parent: NSViewController, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        parent.view.layoutSubtreeIfNeeded()
        let resetLine = try XCTUnwrap(host.resetLine, file: file, line: line)
        let surface = try XCTUnwrap(host.activeViewport?.viewController.view, file: file, line: line)
        XCTAssertFalse(resetLine.isHiddenOrHasHiddenAncestor, file: file, line: line)
        XCTAssertGreaterThan(resetLine.frame.height, 0, file: file, line: line)
        XCTAssertEqual(resetLine.frame.maxY, 260, accuracy: 0.5,
                       "the line's top is at the safe-area top, found \(resetLine.frame.maxY) pt", file: file, line: line)
        XCTAssertLessThanOrEqual(surface.frame.maxY, resetLine.frame.minY + 0.5,
                                 "the surface starts below the line", file: file, line: line)
    }

    func testANewFolderAtThePathDrawsItsLineAtTheSafeAreaTop() throws {
        let (host, parent) = makeInsetHost(store: loadedStore())
        try show(host, .init(url: fixture.bundle)).filter = "Salmo"
        try show(host, .init(url: other))
        try FileManager.default.removeItem(at: fixture.bundle)
        try FileManager.default.createDirectory(at: fixture.bundle, withIntermediateDirectories: true)

        try show(host, .init(url: fixture.bundle))
        try assertLineStartsAtTheSafeAreaTop(host, in: parent)
    }

    func testAChangedDataKeyDrawsItsLineAtTheSafeAreaTop() throws {
        let (host, parent) = makeInsetHost(store: loadedStore())
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        first.selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        try show(host, .init(url: fixture.bundle, dataKey: "data-2"))
        try assertLineStartsAtTheSafeAreaTop(host, in: parent)
    }

    func testASelectionPastItsCapDrawsItsLineAtTheSafeAreaTop() throws {
        var caps = ViewMemoryStore.Caps.standard
        caps.maxSelectionIdentities = 1
        let store = fixture.store(caps: caps)
        store.loadProject(at: fixture.project)
        let (host, parent) = makeInsetHost(store: store)
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        first.selection = ["sample-1|target-3", "sample-2|target-3"]
        try show(host, .init(url: other))

        try show(host, .init(url: fixture.bundle))
        try assertLineStartsAtTheSafeAreaTop(host, in: parent)
    }

    func testALateApplyDrawsItsLineAtTheSafeAreaTop() throws {
        let (host, parent) = makeInsetHost(store: loadedStore())
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        first.selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        let late = try show(host, .init(url: fixture.bundle, dataKey: "data-2", pending: true))
        late.viewMemoryHandle?.applyPending()
        try assertLineStartsAtTheSafeAreaTop(host, in: parent)
    }

    // MARK: - The view reaches the surface's listeners (SWIFT SF-1)

    /// The host restores inside `show` and a route wires the surface's callbacks after `show` returns, in the same
    /// turn, so the host has the surface announce its restored view on the main actor's next turn, once.
    func testTheRestoredViewIsAnnouncedAfterTheRouteThatShowedIt() async throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).filter = "Salmo"
        try show(host, .init(url: other))
        let back = try show(host, .init(url: fixture.bundle))
        XCTAssertEqual(back.announced, [], "the route that showed it has not wired its listeners yet")

        let told = await waitUntil(budget: .standard) { !back.announced.isEmpty }
        XCTAssertTrue(told, "the restored view is announced once the route's turn ends")
        XCTAssertEqual(back.announced, ["Salmo"])
    }

    /// A surface that another show replaced before its turn announces nothing, and its successor announces once.
    func testASurfaceReplacedBeforeItsTurnAnnouncesNothing() async throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        let replaced = try show(host, .init(url: fixture.bundle))
        let installed = try show(host, .init(url: other))

        let told = await waitUntil(budget: .standard) { !installed.announced.isEmpty }
        XCTAssertTrue(told, "the installed surface announces its view")
        XCTAssertEqual(installed.announced, [""])
        XCTAssertEqual(replaced.announced, [], "a surface removed before its turn tells nobody")
    }

    /// A reset and a late apply run after the route wired the listeners, so each announces at once.
    func testAResetAndALateApplyAnnounceAtOnce() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).filter = "kept"
        try show(host, .init(url: other))

        let late = try show(host, .init(url: fixture.bundle, pending: true))
        late.viewMemoryHandle?.applyPending()
        XCTAssertEqual(late.announced, ["kept"], "the late apply announces the restored view")
        host.resetViewMemory()
        XCTAssertEqual(late.announced, ["kept", ""], "Reset View announces the starting view")
    }

    // MARK: - A data key not read (VS B1)

    func testAKeyNotReadNowNeverComparesEqual() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        let back = try show(host, .init(url: fixture.bundle, dataKey: nil))
        XCTAssertEqual(back.restoredWithChangedData, true)
        XCTAssertEqual(back.selection, [])
    }

    func testAKeyNotReadWhenTheViewWasKeptNeverComparesEqual() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle, dataKey: nil)).selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        let back = try show(host, .init(url: fixture.bundle))
        XCTAssertEqual(back.restoredWithChangedData, true)
        XCTAssertEqual(back.selection, [])
    }

    func testAPendingRestoreComparesTheKeysWhenItApplies() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        let changed = try show(host, .init(url: fixture.bundle, dataKey: "data-2", pending: true))
        XCTAssertNil(changed.restoredWithChangedData, "nothing restores before the adopter's own load commits")
        changed.viewMemoryHandle?.applyPending()
        XCTAssertEqual(changed.restoredWithChangedData, true)
        XCTAssertEqual(changed.selection, [])
        changed.selection = ["sample-1|target-3"]

        try show(host, .init(url: other))
        let readLate = try show(host, .init(url: fixture.bundle, dataKey: nil, pending: true))
        readLate.viewMemoryDataKey = "data-2"
        readLate.viewMemoryHandle?.applyPending()
        XCTAssertEqual(readLate.restoredWithChangedData, false, "the key the adopter's own load read is the one compared")
        XCTAssertEqual(readLate.selection, ["sample-1|target-3"])
    }

    // MARK: - The three triggers of a capture

    func testTheViewIsKeptBeforeTheSurfaceTearsItDown() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle, clearsOnDeactivate: true)).filter = "Salmo"
        try show(host, .init(url: other))

        XCTAssertEqual(try show(host, .init(url: fixture.bundle)).filter, "Salmo",
                       "the host captures before willDeactivate (VS A2)")
    }

    func testThePostedQuitNotificationKeepsTheViewAndWritesItBeforeTheDebounce() throws {
        let (host, parent) = makeHost(store: loadedStore())
        defer { _ = parent }
        try show(host, .init(url: fixture.bundle)).filter = "at the quit"
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(fixture.itemFiles().count, 1, "the quit keeps the view with no switch and writes it at once")

        let (relaunched, relaunchedParent) = makeHost(store: loadedStore())
        defer { _ = relaunchedParent }
        XCTAssertEqual(try show(relaunched, .init(url: fixture.bundle)).filter, "at the quit")
    }

    func testClosingTheHostsWindowKeepsTheViewWithNoSwitch() throws {
        let store = loadedStore()
        let (host, parent) = makeHost(store: store)
        defer { _ = parent }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = parent.view
        let key = try XCTUnwrap(store.key(for: ViewMemoryItem.read(at: fixture.bundle)))
        try show(host, .init(url: fixture.bundle)).filter = "Salmo"
        XCTAssertFalse(store.hasRecord(for: key))

        window.close()
        XCTAssertTrue(store.hasRecord(for: key), "the window's close keeps the installed view")
    }

    func testTheWordsNameWhatWasNotKeptInOrder() {
        XCTAssertNil(ViewMemoryWords.dataChanged([]))
        XCTAssertEqual(ViewMemoryWords.dataChanged(.place),
                       "The data changed since your last visit, so your place was not restored.")
        XCTAssertEqual(ViewMemoryWords.dataChanged(.filters),
                       "The data changed since your last visit, so your filters were not restored.")
        XCTAssertEqual(ViewMemoryWords.dataChanged([.filters, .place]),
                       "The data changed since your last visit, so your place and filters were not restored.")
        let all = try? XCTUnwrap(ViewMemoryWords.dataChanged([.place, .selection, .filters, .sampleChoice]))
        XCTAssertEqual(all, "The data changed since your last visit, so your place, selection, filters and sample choice were not restored.")
        XCTAssertEqual(all?.split(separator: " ").count, 18)
        for words in [ViewMemoryWords.viewReset, ViewMemoryWords.selectionTooLarge, all ?? ""] {
            XCTAssertLessThanOrEqual(words.split(separator: " ").count, 20)
            XCTAssertFalse(words.contains(";") || words.contains(":") || words.contains("\u{2014}"))
        }
    }
}
