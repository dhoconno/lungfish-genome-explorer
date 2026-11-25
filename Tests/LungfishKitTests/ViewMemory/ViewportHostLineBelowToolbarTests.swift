// ViewportHostLineBelowToolbarTests.swift - Every line the host draws shows below the window's toolbar (VS-HOST-LINE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishKit
import LungfishTestSupport

/// A toolbar with one item, so that the window's content layout starts below a toolbar as in the main window.
@MainActor
private final class OneItemToolbar: NSObject, NSToolbarDelegate {
    static let item = NSToolbarItem.Identifier("view-memory-line-item")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.item] }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.item] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Item"
        item.view = NSButton(title: "Item", target: nil, action: nil)
        return item
    }
}

private final class BandStandInController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    }
}

/// A surface whose first row is a bar pinned to its own safe-area top, as the summary bars of Kraken2, EsViritu,
/// TaxTriage, NAO-MGS and NVD are. It answers `pinsTopToSafeArea` as it is made.
@MainActor
private final class BandStandInSurface: ViewMemoryAdopting {
    struct Input {
        let url: URL
        var dataKey: String? = "data-1"
        var pending = false
    }

    static let kind = SurfaceKind.view(SurfaceViewID(rawValue: "band-stand-in"))

    let viewController: NSViewController = BandStandInController()
    let surfaceKind = BandStandInSurface.kind
    let pinsTopToSafeArea: Bool
    let bar = NSView()
    var viewMemoryItem: ViewMemoryItem?
    var viewMemoryDataKey: String?
    var viewMemoryLoadIsPending = false
    var viewMemoryHandle: ViewMemoryHandle<ViewMemoryTestView>?
    var filter = ""
    var selection: [String] = []

    init(pinsTopToSafeArea: Bool) {
        self.pinsTopToSafeArea = pinsTopToSafeArea
        let view = viewController.view
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let input = try expectInput(input, as: Input.self)
        viewMemoryItem = ViewMemoryItem.read(at: input.url)
        viewMemoryDataKey = input.dataKey
        viewMemoryLoadIsPending = input.pending
    }

    func captureViewMemory() -> ViewMemoryTestView {
        ViewMemoryTestView(filter: filter, selection: selection)
    }

    /// Restores the filter and the selection only on an equal data key, and names what a changed key dropped.
    func restoreViewMemory(_ state: ViewMemoryTestView, dataChanged: Bool) -> ViewMemoryLoss {
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

    func announceViewMemory() {}
}

/// The 2026.11.17 walk (row F1 C1b, build 14643) found the reset line of a 12S result in the AX tree at screen y 74, in
/// the window's 52 pt title bar and toolbar band, where no person saw it. A surface that keeps the default
/// `pinsTopToSafeArea == false` is pinned to the container's edge, and the host pinned each line it draws to that
/// same edge. These cases run in a window that draws its content under a toolbar, as the main window does.
@MainActor
final class ViewportHostLineBelowToolbarTests: XCTestCase {
    private var fixture: ViewMemoryFixture!
    private var other: URL!
    private var window: NSWindow!
    /// The host holds its parent controller weakly, as the viewer that owns both does.
    private var parent: NSViewController!
    private var toolbarDelegate: OneItemToolbar!

    override func setUp() async throws {
        fixture = try ViewMemoryFixture()
        other = fixture.project.appendingPathComponent("other.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
        parent = nil
        toolbarDelegate = nil
        fixture.cleanup()
    }

    /// A host whose container is the content view of a window with `.fullSizeContentView` and a one-item toolbar.
    private func makeHost(store: ViewMemoryStore, pinsTopToSafeArea: Bool = false) -> (ViewportHost, NSView) {
        let registry = SurfaceRegistry()
        registry.register(BandStandInSurface.kind) { BandStandInSurface(pinsTopToSafeArea: pinsTopToSafeArea) }
        let parent = BandStandInController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let delegate = OneItemToolbar()
        let toolbar = NSToolbar(identifier: "view-memory-line-toolbar")
        toolbar.delegate = delegate
        window.toolbar = toolbar
        window.contentView = parent.view
        self.window = window
        self.parent = parent
        toolbarDelegate = delegate
        return (ViewportHost(registry: registry, containerView: parent.view, parentController: parent,
                             viewMemoryStore: store), parent.view)
    }

    private func loadedStore(caps: ViewMemoryStore.Caps = .standard) -> ViewMemoryStore {
        let store = fixture.store(caps: caps)
        store.loadProject(at: fixture.project)
        return store
    }

    @discardableResult
    private func show(_ host: ViewportHost, _ input: BandStandInSurface.Input) throws -> BandStandInSurface {
        host.show(kind: BandStandInSurface.kind, input: input)
        return try XCTUnwrap(host.activeViewport as? BandStandInSurface)
    }

    private func layOut(_ container: NSView) {
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
    }

    /// The frame of `view` in the window's coordinates.
    private func inWindow(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    /// The line shows: not hidden, a non-empty frame, and its full height inside the window's content layout, below
    /// the toolbar.
    private func assertLineShowsBelowTheToolbar(
        _ host: ViewportHost, in container: NSView, words: String?, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        layOut(container)
        let band = container.safeAreaInsets.top
        XCTAssertGreaterThan(band, 0, "the container runs under the title bar and toolbar", file: file, line: line)
        let resetLine = try XCTUnwrap(host.resetLine, "the host draws a line", file: file, line: line)
        XCTAssertEqual(resetLine.words, words, file: file, line: line)
        XCTAssertFalse(resetLine.isHiddenOrHasHiddenAncestor, file: file, line: line)
        let frame = inWindow(resetLine)
        XCTAssertFalse(frame.isEmpty, "the line has a frame, found \(frame)", file: file, line: line)
        let visible = window.contentLayoutRect
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY + 0.5,
                                 "the line starts below the toolbar, found its top at \(frame.maxY) pt against the content layout's top at \(visible.maxY) pt (band \(band) pt)",
                                 file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY - 0.5, file: file, line: line)
    }

    // MARK: - Every host line on a default surface

    func testTheFolderChangedLineShowsBelowTheToolbarOnADefaultSurface() throws {
        let (host, container) = makeHost(store: loadedStore())
        try show(host, .init(url: fixture.bundle)).filter = "Salmo"
        try show(host, .init(url: other))
        try FileManager.default.removeItem(at: fixture.bundle)
        try FileManager.default.createDirectory(at: fixture.bundle, withIntermediateDirectories: true)

        try show(host, .init(url: fixture.bundle))
        try assertLineShowsBelowTheToolbar(host, in: container, words: ViewMemoryWords.viewReset)
    }

    func testTheDataKeyLossLineShowsBelowTheToolbarOnADefaultSurface() throws {
        let (host, container) = makeHost(store: loadedStore())
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        first.selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        try show(host, .init(url: fixture.bundle, dataKey: "data-2"))
        try assertLineShowsBelowTheToolbar(host, in: container,
                                           words: ViewMemoryWords.dataChanged([.selection, .filters]))
    }

    func testTheSelectionLineShowsBelowTheToolbarOnADefaultSurface() throws {
        var caps = ViewMemoryStore.Caps.standard
        caps.maxSelectionIdentities = 1
        let (host, container) = makeHost(store: loadedStore(caps: caps))
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        first.selection = ["sample-1|target-3", "sample-2|target-3"]
        try show(host, .init(url: other))

        try show(host, .init(url: fixture.bundle))
        try assertLineShowsBelowTheToolbar(host, in: container, words: ViewMemoryWords.selectionTooLarge)
    }

    func testTheLateApplyLineShowsBelowTheToolbarOnADefaultSurface() throws {
        let (host, container) = makeHost(store: loadedStore())
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        first.selection = ["sample-1|target-3"]
        try show(host, .init(url: other))

        let late = try show(host, .init(url: fixture.bundle, dataKey: "data-2", pending: true))
        XCTAssertNil(host.resetLine, "nothing applies before the adopter's own load commits")
        late.viewMemoryHandle?.applyPending()
        try assertLineShowsBelowTheToolbar(host, in: container,
                                           words: ViewMemoryWords.dataChanged([.selection, .filters]))
    }

    // MARK: - No doubled band and no gap

    /// A surface that asks for the safe area already starts below the toolbar, so the line takes that place and the
    /// surface starts at the line's bottom, with no gap of a toolbar's height between them.
    func testOnASurfaceThatAsksForTheSafeAreaTheLineTakesItsPlaceWithNoGap() throws {
        let (host, container) = makeHost(store: loadedStore(), pinsTopToSafeArea: true)
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        try show(host, .init(url: other))

        let back = try show(host, .init(url: fixture.bundle, dataKey: "data-2"))
        try assertLineShowsBelowTheToolbar(host, in: container, words: ViewMemoryWords.dataChanged(.filters))
        let line = inWindow(try XCTUnwrap(host.resetLine))
        XCTAssertEqual(line.maxY, window.contentLayoutRect.maxY, accuracy: 0.5, "the line sits at the safe-area top")
        let surface = inWindow(back.viewController.view)
        XCTAssertEqual(surface.maxY, line.minY, accuracy: 0.5, "the surface starts at the line's bottom")
        XCTAssertEqual(inWindow(back.bar).maxY, line.minY, accuracy: 0.5, "no band of a toolbar's height opens below the line")
    }

    /// A default surface pads its own first row for the band with its own safe-area constraint. Below the line it has
    /// no band left to pad, so its first row starts at the line's bottom: no doubled band and no gap.
    func testOnADefaultSurfaceThatPadsItsOwnTopTheFirstRowStartsAtTheLinesBottom() throws {
        let (host, container) = makeHost(store: loadedStore())
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        try show(host, .init(url: other))

        let back = try show(host, .init(url: fixture.bundle, dataKey: "data-2"))
        try assertLineShowsBelowTheToolbar(host, in: container, words: ViewMemoryWords.dataChanged(.filters))
        let line = inWindow(try XCTUnwrap(host.resetLine))
        XCTAssertEqual(inWindow(back.viewController.view).maxY, line.minY, accuracy: 0.5,
                       "the surface's top follows the line's bottom")
        XCTAssertEqual(inWindow(back.bar).maxY, line.minY, accuracy: 0.5,
                       "the surface's first row starts at the line's bottom, with no band of a toolbar's height above it")
    }

    // MARK: - Removal

    /// After the line goes, a default surface is back on its own pin at the container's edge and pads its own band.
    func testRemovingTheLinePutsADefaultSurfaceBackOnItsOwnPin() throws {
        let (host, container) = makeHost(store: loadedStore())
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        try show(host, .init(url: other))
        let back = try show(host, .init(url: fixture.bundle, dataKey: "data-2"))
        layOut(container)
        let line = try XCTUnwrap(host.resetLine)

        host.removeResetLine()
        layOut(container)
        XCTAssertNil(host.resetLine)
        XCTAssertNil(line.superview, "the line is gone from the view tree")
        XCTAssertFalse(container.subviews.contains { $0 is ViewMemoryResetLineView })
        let pin = try XCTUnwrap(host.installedTop)
        XCTAssertTrue(pin.constraint.isActive, "the surface's own top pin is back")
        XCTAssertTrue(pin.constraint.secondItem === container && pin.constraint.secondAttribute == .top,
                      "a default surface pins to the container's edge")
        XCTAssertEqual(inWindow(back.viewController.view).maxY, inWindow(container).maxY, accuracy: 0.5,
                       "the surface's top is back at the container's edge")
        XCTAssertEqual(inWindow(back.bar).maxY, window.contentLayoutRect.maxY, accuracy: 0.5,
                       "the surface pads its own band again")
    }

    /// Reset View takes the line away in the same way.
    func testResetViewPutsADefaultSurfaceBackOnItsOwnPin() throws {
        let (host, container) = makeHost(store: loadedStore())
        let first = try show(host, .init(url: fixture.bundle))
        first.filter = "Salmo"
        try show(host, .init(url: other))
        let back = try show(host, .init(url: fixture.bundle, dataKey: "data-2"))
        layOut(container)
        XCTAssertNotNil(host.resetLine)

        host.resetViewMemory()
        layOut(container)
        XCTAssertNil(host.resetLine)
        XCTAssertFalse(container.subviews.contains { $0 is ViewMemoryResetLineView })
        XCTAssertEqual(inWindow(back.viewController.view).maxY, inWindow(container).maxY, accuracy: 0.5)
    }
}
