import XCTest
import AppKit
import LungfishCore
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

@MainActor
final class ChromosomeNavigatorSelectionTests: XCTestCase {
    private func chromosome(_ name: String, _ length: Int64) -> ChromosomeInfo {
        ChromosomeInfo(name: name, length: length, offset: 0, lineBases: 60, lineWidth: 61)
    }

    private func makeNavigator() -> ChromosomeNavigatorView {
        let navigator = ChromosomeNavigatorView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        navigator.chromosomes = [
            chromosome("seg1", 1741),
            chromosome("seg2", 1497),
            chromosome("seg3", 982),
        ]
        return navigator
    }

    func testMultipleRowsCanBeSelected() {
        let navigator = makeNavigator()
        navigator.testingSelectRows([0, 2])
        XCTAssertEqual(navigator.testingSelectedChromosomeNames, ["seg1", "seg3"])
    }

    func testExtractItemIsFirstAndSeparatedFromTheCopyItems() {
        let navigator = makeNavigator()
        navigator.onExtractSelectedSequencesRequested = { _ in }
        navigator.testingSelectRows([0, 1])
        let titles = navigator.testingContextMenuTitles(clickedRow: 0)
        XCTAssertEqual(titles.first, "Extract to New Bundle…")
        XCTAssertEqual(titles.dropFirst().first, "")
        XCTAssertTrue(titles.contains("Copy Name"))
    }

    func testExtractItemIsAbsentWhenNoHandlerIsWired() {
        let navigator = makeNavigator()
        navigator.testingSelectRows([0])
        XCTAssertFalse(navigator.testingContextMenuTitles(clickedRow: 0).contains("Extract to New Bundle…"))
    }

    func testRightClickOutsideTheSelectionTargetsTheClickedRowAlone() {
        let navigator = makeNavigator()
        navigator.onExtractSelectedSequencesRequested = { _ in }
        navigator.testingSelectRows([0, 1])
        _ = navigator.testingContextMenuTitles(clickedRow: 2)
        XCTAssertEqual(navigator.testingSelectedChromosomeNames, ["seg3"])
    }

    func testHandlerReceivesEverySelectedChromosome() {
        let navigator = makeNavigator()
        var received: [String] = []
        navigator.onExtractSelectedSequencesRequested = { received = $0.map(\.name) }
        navigator.testingSelectRows([0, 2])
        navigator.testingInvokeContextMenuItem(titled: "Extract to New Bundle…", clickedRow: 0)
        XCTAssertEqual(received, ["seg1", "seg3"])
    }

    // MARK: - Keyboard and accessibility

    private final class NavigatorDelegateSpy: ChromosomeNavigatorDelegate {
        var selected: [String] = []
        func chromosomeNavigator(_ navigator: ChromosomeNavigatorView, didSelectChromosome chromosome: ChromosomeInfo) {
            selected.append(chromosome.name)
        }
    }

    private func makeNavigatorInWindow() -> (ChromosomeNavigatorView, NSWindow) {
        _ = NSApplication.shared
        let navigator = makeNavigator()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = navigator
        navigator.layoutSubtreeIfNeeded()
        navigator.testingTableView.layoutSubtreeIfNeeded()
        return (navigator, window)
    }

    private func returnKeyEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
    }

    func testReturnActivatesTheSelectedChromosomeLikeADoubleClick() throws {
        let (navigator, window) = makeNavigatorInWindow()
        defer { window.close() }
        let spy = NavigatorDelegateSpy()
        navigator.delegate = spy
        navigator.testingSelectRows([1])
        spy.selected.removeAll()

        navigator.testingTableView.keyDown(with: try returnKeyEvent())
        XCTAssertEqual(spy.selected, ["seg2"], "Return recentres on the selected chromosome")

        navigator.testingTableView.deselectAll(nil)
        navigator.testingTableView.keyDown(with: try returnKeyEvent())
        XCTAssertEqual(spy.selected, ["seg2"], "Return with no selection must not activate a stale row")
    }

    func testEveryRowPublishesTheContextMenuCommandsAsCellActionsOnce() throws {
        let (navigator, window) = makeNavigatorInWindow()
        defer { window.close() }
        navigator.onExtractSelectedSequencesRequested = { _ in }
        navigator.testingSelectRows([0])

        let rows = AccessibilityRowProbe.rowProxies(of: navigator.testingTableView)
        XCTAssertEqual(rows.count, 3)
        let expected = ["Navigate to Chromosome", "Extract to New Bundle\u{2026}", "Copy Name", "Copy Length", "Show in Inspector"]
        for row in rows {
            XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(row), expected)
            for served in AccessibilityRowProbe.servedCellActionNames(row) {
                XCTAssertEqual(served, expected, "the AX server lists each action once")
            }
        }

        let contextMenu = NSMenu()
        navigator.testingBuildContextMenu(contextMenu, clickedRow: 0)
        ContextMenuParityAssert.assertParity(
            contextMenu: contextMenu,
            cellActionNames: expected,
            mainMenu: MainMenu.createMainMenu()
        )
    }

    func testCellActionsActOnTheRowTheCellShowsNow() throws {
        let (navigator, window) = makeNavigatorInWindow()
        defer { window.close() }
        let spy = NavigatorDelegateSpy()
        navigator.delegate = spy
        var extracted: [[String]] = []
        navigator.onExtractSelectedSequencesRequested = { extracted.append($0.map(\.name)) }

        let rows = AccessibilityRowProbe.rowProxies(of: navigator.testingTableView)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: rows[2]))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "seg3")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Length", in: rows[1]))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "1497")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Navigate to Chromosome", in: rows[2]))
        XCTAssertEqual(spy.selected.last, "seg3")

        // Extract on an unselected row targets that row alone, like a
        // right-click outside the selection.
        navigator.testingSelectRows([0, 1])
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract to New Bundle\u{2026}", in: rows[2]))
        XCTAssertEqual(extracted.last, ["seg3"])
        navigator.testingSelectRows([0, 1])
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Extract to New Bundle\u{2026}", in: rows[0]))
        XCTAssertEqual(extracted.last, ["seg1", "seg2"])

        // Re-sort so the cell views are reused for other chromosomes: the
        // handler must follow the row the cell shows now.
        navigator.sortMode = .bySize
        navigator.testingTableView.layoutSubtreeIfNeeded()
        let sorted = AccessibilityRowProbe.rowProxies(of: navigator.testingTableView)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: sorted[0]))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "seg1")
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy Name", in: sorted[2]))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "seg3")
    }

    func testMenuBarRowCommandsFollowTheSelection() throws {
        let (navigator, window) = makeNavigatorInWindow()
        defer { window.close() }
        let spy = NavigatorDelegateSpy()
        navigator.delegate = spy
        var extracted: [String] = []
        navigator.onExtractSelectedSequencesRequested = { extracted = $0.map(\.name) }

        let copyName = NSMenuItem(title: "Copy Name", action: #selector(ResultRowMenuActions.copySelectedRowName(_:)), keyEquivalent: "")
        let inspector = NSMenuItem(title: "Show in Inspector", action: #selector(ResultRowMenuActions.showSelectedRowInInspector(_:)), keyEquivalent: "")
        let extract = NSMenuItem(title: "Extract", action: #selector(ResultRowMenuActions.extractSelectedRowsToNewBundle(_:)), keyEquivalent: "")
        let activate = NSMenuItem(title: "Open Row", action: #selector(ResultRowMenuActions.activateSelectedRow(_:)), keyEquivalent: "")
        let copyTaxon = NSMenuItem(title: "Copy Taxon ID", action: #selector(ResultRowMenuActions.copySelectedRowTaxonID(_:)), keyEquivalent: "")

        navigator.testingTableView.deselectAll(nil)
        XCTAssertFalse(navigator.validateMenuItem(copyName), "nothing selected")

        navigator.testingSelectRows([1])
        XCTAssertTrue(navigator.validateMenuItem(copyName))
        XCTAssertTrue(navigator.validateMenuItem(inspector))
        XCTAssertTrue(navigator.validateMenuItem(extract))
        XCTAssertTrue(navigator.validateMenuItem(activate))
        XCTAssertFalse(navigator.responds(to: copyTaxon.action!), "a chromosome has no taxon ID")

        navigator.copySelectedRowName(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "seg2")
        spy.selected.removeAll()
        navigator.activateSelectedRow(nil)
        XCTAssertEqual(spy.selected, ["seg2"])
        navigator.extractSelectedRowsToNewBundle(nil)
        XCTAssertEqual(extracted, ["seg2"])

        navigator.testingSelectRows([0, 2])
        XCTAssertFalse(navigator.validateMenuItem(inspector), "Show in Inspector inspects one chromosome")
        XCTAssertTrue(navigator.validateMenuItem(extract))

        navigator.onExtractSelectedSequencesRequested = nil
        XCTAssertFalse(navigator.validateMenuItem(extract), "no extract handler wired")
    }

    func testSortPopUpMirrorsItsItemsAsActionsThatResort() throws {
        let navigator = makeNavigator()
        let actions = try XCTUnwrap(navigator.testingSortPopUp.accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Natural", "A-Z", "Size"])
        XCTAssertEqual(actions[2].handler?(), true)
        XCTAssertEqual(navigator.sortMode, .bySize)
        XCTAssertEqual(navigator.displayedChromosomes.map(\.name), ["seg1", "seg2", "seg3"])
        navigator.chromosomes = [
            chromosome("b", 10), chromosome("a", 20),
        ]
        XCTAssertEqual(actions[1].handler?(), true)
        XCTAssertEqual(navigator.sortMode, .alphabetical)
        XCTAssertEqual(navigator.displayedChromosomes.map(\.name), ["a", "b"])
    }
}
