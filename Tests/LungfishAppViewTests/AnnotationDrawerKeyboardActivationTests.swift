import AppKit
import XCTest
@testable import LungfishApp

/// The annotation table drawer must let the keyboard and AX clients do what a
/// double-click does: recentre the viewport on the selected variant or
/// annotation.
@MainActor
final class AnnotationDrawerKeyboardActivationTests: XCTestCase {

    private final class OneRowDataSource: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 1 }
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

    func testAccessibilityActionRowViewReportsProviderActionsOnDemand() throws {
        let rowView = AccessibilityActionRowView()
        XCTAssertNil(rowView.accessibilityCustomActions(), "No provider means no actions")

        var performed: [String] = []
        var names = ["Zoom to Variant", "Show in Inspector"]
        rowView.actionProvider = {
            names.map { name in
                AccessibilityActionRowView.makeAction(name: name) { performed.append(name) }
            }
        }
        XCTAssertEqual(rowView.accessibilityCustomActions()?.map(\.name), names)

        let zoom = try XCTUnwrap(rowView.accessibilityCustomActions()?.first)
        XCTAssertTrue(zoom.handler?() ?? false)
        XCTAssertEqual(performed, ["Zoom to Variant"])

        names = ["Zoom to Annotation"]
        XCTAssertEqual(rowView.accessibilityCustomActions()?.map(\.name), names, "Actions reflect the current state at each request")
    }
}
