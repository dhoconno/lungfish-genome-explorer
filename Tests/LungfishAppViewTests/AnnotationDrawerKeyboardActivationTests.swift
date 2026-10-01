import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp

/// The annotation table drawer must let the keyboard and AX clients do what a
/// double-click does: recentre the viewport on the selected variant or
/// annotation.
@MainActor
final class AnnotationDrawerKeyboardActivationTests: XCTestCase {

    private final class OneRowDataSource: NSObject, NSTableViewDataSource {
        let rows: Int
        init(rows: Int = 1) { self.rows = rows }
        func numberOfRows(in tableView: NSTableView) -> Int { rows }
    }

    func testReturnAndEnterActivateWithoutModifiers() {
        XCTAssertTrue(AnnotationDrawerTableView.activatesSelectedRow(keyCode: 36, modifierFlags: []))
        XCTAssertTrue(AnnotationDrawerTableView.activatesSelectedRow(keyCode: 76, modifierFlags: [.numericPad]))
        XCTAssertFalse(AnnotationDrawerTableView.activatesSelectedRow(keyCode: 36, modifierFlags: [.command]))
        XCTAssertFalse(AnnotationDrawerTableView.activatesSelectedRow(keyCode: 49, modifierFlags: []), "Space is not activation")
        XCTAssertFalse(AnnotationDrawerTableView.activatesSelectedRow(keyCode: 125, modifierFlags: []), "Down Arrow keeps its NSTableView meaning")
    }

    func testReturnKeyDownInvokesActivationForTheSelectedRow() throws {
        _ = NSApplication.shared
        let table = AnnotationDrawerTableView()
        let dataSource = OneRowDataSource()
        table.dataSource = dataSource
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        var activations = 0
        table.onActivateSelectedRow = { activations += 1 }

        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        table.keyDown(with: returnEvent)
        XCTAssertEqual(activations, 1)

        table.deselectAll(nil)
        table.keyDown(with: returnEvent)
        XCTAssertEqual(activations, 1, "Return with no selection must not activate a stale row")
    }

    func testReturnWithSeveralRowsSelectedBeepsAndActivatesNothing() throws {
        _ = NSApplication.shared
        let table = AnnotationDrawerTableView()
        table.allowsMultipleSelection = true
        let dataSource = OneRowDataSource(rows: 3)
        table.dataSource = dataSource
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.reloadData()
        var activations = 0
        var beeps = 0
        table.onActivateSelectedRow = { activations += 1 }
        table.rejectActivation = { beeps += 1 }
        let returnEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))

        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        table.keyDown(with: returnEvent)
        XCTAssertEqual(activations, 0, "Return must not guess which of several rows to activate")
        XCTAssertEqual(beeps, 1)

        table.deselectAll(nil)
        table.keyDown(with: returnEvent)
        XCTAssertEqual(beeps, 2, "Return with nothing selected also reports it cannot act")

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.keyDown(with: returnEvent)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(beeps, 2)
    }

    // MARK: - Rows through AppKit's accessibility bridge

    private func makeDrawerInWindow() -> (AnnotationTableDrawerView, NSWindow) {
        _ = NSApplication.shared
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = drawer
        return (drawer, window)
    }

    private func result(_ name: String, start: Int) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: name, chromosome: "chr1", start: start, end: start + 50,
            trackId: "genes", type: "gene", strand: "+"
        )
    }

    private final class DrawerDelegateSpy: AnnotationTableDrawerDelegate {
        var selected: [String] = []
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult) {
            selected.append(result.name)
        }
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didResolveGeneRegions regions: [GeneRegion]) {}
        func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleVariantRenderKeys keys: Set<String>?) {}
        func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {}
        func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView) {}
        func annotationDrawer(
            _ drawer: AnnotationTableDrawerView,
            fallbackConsequenceFor result: AnnotationSearchIndex.SearchResult
        ) -> (consequence: String?, aaChange: String?) { (nil, nil) }
    }

    func testDrawerRowsPublishZoomAndInspectorActionsToAXClients() throws {
        let (drawer, window) = makeDrawerInWindow()
        defer { window.close() }
        let spy = DrawerDelegateSpy()
        drawer.delegate = spy
        drawer.setAnnotations([result("A", start: 10), result("B", start: 120)])
        drawer.layoutSubtreeIfNeeded()
        let table = drawer.tableView
        table.layoutSubtreeIfNeeded()

        let rows = AccessibilityRowProbe.rowProxies(of: table)
        XCTAssertEqual(rows.count, 2)
        let secondRow = try XCTUnwrap(rows.last)
        let cellNames = AccessibilityRowProbe.cellActionNames(secondRow)
        XCTAssertFalse(cellNames.isEmpty, "The AX row must expose cell children")
        // The row's enabled context menu commands, Copy submenu flattened,
        // in menu order. Edit and Delete are disabled without a database row.
        let expected = [
            "Copy: Copy Name", "Copy: Copy Coordinates", "Copy: Copy Sequence", "Copy: Copy Reverse Complement", "Copy: Copy as FASTA",
            "Extract Sequence\u{2026}", "Add Annotation\u{2026}", "Select Related Gene Features",
            "Zoom to Annotation", "Show in Inspector",
        ]
        for names in cellNames {
            XCTAssertEqual(names, expected, "Every cell of the row carries the actions")
        }
        for served in AccessibilityRowProbe.servedCellActionNames(secondRow) {
            XCTAssertEqual(served, expected, "The AX server lists each action once")
        }

        // Performing the action through the AX element zooms to that row.
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Zoom to Annotation", in: secondRow))
        XCTAssertEqual(spy.selected, ["B"])
    }

    func testDrawerCellActionsFollowTheRowAReusedCellShows() throws {
        let (drawer, window) = makeDrawerInWindow()
        defer { window.close() }
        let spy = DrawerDelegateSpy()
        drawer.delegate = spy
        drawer.setAnnotations([result("A", start: 10), result("B", start: 120)])
        drawer.layoutSubtreeIfNeeded()
        let table = drawer.tableView
        table.layoutSubtreeIfNeeded()

        // Reorder the rows. Whatever cell view the table recycles, the action
        // must act on the annotation the cell shows at the time it runs.
        drawer.setAnnotations([result("B", start: 120), result("A", start: 10)])
        table.layoutSubtreeIfNeeded()
        let rows = AccessibilityRowProbe.rowProxies(of: table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Zoom to Annotation", in: rows[0]))
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Zoom to Annotation", in: rows[1]))
        XCTAssertEqual(spy.selected, ["B", "A"])
    }
}
