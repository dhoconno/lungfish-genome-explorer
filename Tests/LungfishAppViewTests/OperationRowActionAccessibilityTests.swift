import AppKit
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import XCTest
@testable import LungfishApp

/// The Operations panel's row commands must be reachable without a mouse:
/// from the menu bar (Operations > Selected Operation), from each row's
/// accessibility custom actions, and from the log drawer's Actions menu.
/// All four surfaces share ``OperationRowAction`` and
/// ``OperationsPanelViewController/perform(_:on:)``.
@MainActor
final class OperationRowActionAccessibilityTests: XCTestCase {
    /// A pasteboard of this test's own. The general pasteboard is one per
    /// machine, so a copy made by a test running in another process at the
    /// same time would show up here.
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
        _ = NSApplication.shared
        OperationCenter.useTemporaryFailureReportsForTesting()
        OperationCenter.shared.cancelAll()
        OperationCenter.shared.clearCompleted()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - Shared availability model

    func testAvailableActionsFollowItemState() {
        let running = OperationCenter.Item(
            title: "Map reads",
            detail: "Running",
            progress: 0.2,
            state: .running,
            operationType: .assembly,
            onCancel: {},
            cliCommand: "lungfish map reads.fastq"
        )
        XCTAssertEqual(
            OperationRowAction.available(for: running),
            [.copyCLICommand, .cancel]
        )

        var completed = OperationCenter.Item(
            title: "Map reads",
            detail: "Done",
            progress: 1,
            state: .completed,
            operationType: .assembly,
            outputURLs: [URL(fileURLWithPath: "/tmp/out.bam")],
            cliCommand: "lungfish map reads.fastq"
        )
        completed.logEntries = [OperationLogEntry(timestamp: Date(), level: .info, message: "done")]
        XCTAssertEqual(
            OperationRowAction.available(for: completed),
            [.revealOutputs, .copyCLICommand, .copyLog, .viewLog, .revealLog, .clear]
        )

        let failed = OperationCenter.Item(
            title: "Map reads",
            detail: "Failed",
            progress: 0,
            state: .failed,
            operationType: .assembly,
            cliCommand: nil,
            errorMessage: "boom"
        )
        XCTAssertEqual(
            OperationRowAction.available(for: failed),
            [.copyFailureReport, .openGitHubIssue, .clear]
        )
    }

    func testEveryActionHasAMenuBarSelectorThatMapsBack() {
        for action in OperationRowAction.allCases {
            XCTAssertEqual(OperationRowAction.action(for: action.menuSelector), action)
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.identifierSlug.isEmpty)
        }
        XCTAssertNil(OperationRowAction.action(for: nil))
        XCTAssertNil(OperationRowAction.action(for: #selector(OperationsMenuActions.showOperationsPanel(_:))))
    }

    // MARK: - Menu bar

    func testSelectedOperationSubmenuRoutesEveryRowActionThroughTheResponderChain() throws {
        let mainMenu = MainMenu.createMainMenu()
        let operationsMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Operations" }?.submenu)
        let selectedItem = try XCTUnwrap(
            operationsMenu.items.first { $0.identifier?.rawValue == MainMenuAccessibilityID.selectedOperation }
        )
        XCTAssertEqual(selectedItem.title, "Selected Operation")
        let submenu = try XCTUnwrap(selectedItem.submenu)

        for action in OperationRowAction.allCases {
            let identifier = MainMenuAccessibilityID.selectedOperationAction(action)
            let item = try XCTUnwrap(
                submenu.items.first { $0.identifier?.rawValue == identifier },
                "Missing menu bar item for \(action)"
            )
            XCTAssertEqual(item.title, action.menuBarTitle)
            XCTAssertEqual(item.action, action.menuSelector)
            XCTAssertNil(item.target, "Row commands must go to the first responder")
            if let keyEquivalent = action.keyEquivalent {
                XCTAssertEqual(item.keyEquivalent, keyEquivalent.key)
                XCTAssertEqual(item.keyEquivalentModifierMask, keyEquivalent.modifiers)
            } else {
                XCTAssertEqual(item.keyEquivalent, "")
            }
        }
    }

    func testNewShortcutsDoNotCollideWithExistingMenuBarBindings() throws {
        let mainMenu = MainMenu.createMainMenu()
        var bindings: [String: [String]] = [:]
        func collect(_ menu: NSMenu, path: String) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let key = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
                    bindings[key, default: []].append("\(path) > \(item.title)")
                }
                if let submenu = item.submenu { collect(submenu, path: "\(path) > \(item.title)") }
            }
        }
        collect(mainMenu, path: "Main")

        let newShortcuts: [(String, NSEvent.ModifierFlags)] = [
            ("c", [.command, .option]),
            ("l", [.command, .option]),
            ("o", [.command, .option]),
            ("v", [.command, .option]),
        ]
        for (key, modifiers) in newShortcuts {
            let owners = bindings["\(modifiers.rawValue):\(key)"] ?? []
            XCTAssertEqual(owners.count, 1, "Cmd-Opt-\(key.uppercased()) is bound by \(owners)")
        }
    }

    func testProvenanceInspectorMenuItemShowsTheInspectorOnItsProvenanceTab() throws {
        let mainMenu = MainMenu.createMainMenu()
        let viewMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "View" }?.submenu)
        let item = try XCTUnwrap(
            viewMenu.items.first { $0.identifier?.rawValue == MainMenuAccessibilityID.provenanceInspector }
        )
        XCTAssertEqual(item.title, "Provenance Inspector")
        XCTAssertEqual(item.action, #selector(ViewMenuActions.showProvenanceInspector(_:)))
        XCTAssertEqual(item.keyEquivalent, "v")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
    }

    // MARK: - Panel validation and row accessibility

    func testMenuBarItemsValidateAgainstTheSelectedRow() throws {
        let operationID = OperationCenter.shared.begin(
            title: "Call variants",
            detail: "Running bcftools",
            operationType: .assembly,
            cliCommand: "lungfish call-variants sample.bam",
            onCancel: {}
        ).rowID
        defer {
            _ = OperationCenter.shared.fail(id: operationID, detail: "cleanup")
            OperationCenter.shared.clearCompleted()
        }

        let (controller, viewController, table) = try makePanel()
        defer { controller.close() }
        let row = try XCTUnwrap(OperationCenter.shared.items.firstIndex { $0.id == operationID })
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let copyItem = NSMenuItem(title: "", action: OperationRowAction.copyCLICommand.menuSelector, keyEquivalent: "")
        let viewLogItem = NSMenuItem(title: "", action: OperationRowAction.viewLog.menuSelector, keyEquivalent: "")
        let cancelItem = NSMenuItem(title: "", action: OperationRowAction.cancel.menuSelector, keyEquivalent: "")
        let unrelatedItem = NSMenuItem(title: "", action: #selector(OperationsMenuActions.showOperationsPanel(_:)), keyEquivalent: "")

        XCTAssertTrue(viewController.validateMenuItem(copyItem))
        XCTAssertFalse(viewController.validateMenuItem(viewLogItem), "No log entries yet, so View Log stays disabled")
        XCTAssertTrue(viewController.validateMenuItem(cancelItem))
        XCTAssertTrue(viewController.validateMenuItem(unrelatedItem), "Non-row items keep their default state")

        table.deselectAll(nil)
        XCTAssertFalse(viewController.validateMenuItem(copyItem))
        XCTAssertFalse(viewController.validateMenuItem(cancelItem))
    }

    func testRowExposesCustomAccessibilityActionsThatShareTheMenuImplementation() throws {
        let command = "lungfish call-variants --reference chr20.fa sample.bam"
        let operationID = OperationCenter.shared.begin(
            title: "Call variants",
            detail: "Running bcftools",
            operationType: .assembly,
            cliCommand: command
        ).rowID
        OperationCenter.shared.log(id: operationID, level: .info, message: "bcftools mpileup started")
        defer {
            _ = OperationCenter.shared.fail(id: operationID, detail: "cleanup")
            OperationCenter.shared.clearCompleted()
        }

        let (controller, viewController, table) = try makePanel()
        defer { controller.close() }
        let row = try XCTUnwrap(OperationCenter.shared.items.firstIndex { $0.id == operationID })
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        let expected = OperationRowAction.available(for: OperationCenter.shared.items[row]).map(\.title)
        XCTAssertTrue(expected.contains("Copy CLI Command"))
        XCTAssertTrue(expected.contains("View Log"))

        // The AX row proxy's cell children carry the actions, which is the
        // path VoiceOver and AX automation read.
        let rowProxy = try XCTUnwrap(AccessibilityRowProbe.rowProxies(of: table)[row])
        let cellNames = AccessibilityRowProbe.cellActionNames(rowProxy)
        XCTAssertFalse(cellNames.isEmpty)
        for names in cellNames { XCTAssertEqual(names, expected) }

        // The log drawer's Actions pull-down lists the same commands, in the same order.
        let logButton = try XCTUnwrap(
            table.view(atColumn: 0, row: row, makeIfNecessary: true)?.viewWithTag(102) as? NSButton
        )
        logButton.performClick(nil)
        let popup = try XCTUnwrap(
            viewController.view.firstSubview(withAccessibilityIdentifier: "operations-inspector-actions") as? NSPopUpButton
        )
        let popupTitles = (popup.menu?.items ?? []).dropFirst().filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(Array(popupTitles), expected)

        // Performing the AX action runs the shared implementation.
        pasteboard.clearContents()
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Copy CLI Command", in: rowProxy))
        XCTAssertEqual(pasteboard.string(forType: .string), command)

        // The menu bar path lands on the same code for the selected row.
        pasteboard.clearContents()
        viewController.copySelectedOperationCLICommand(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), command)
    }

    // MARK: - Helpers

    private func makePanel() throws -> (OperationsPanelController, OperationsPanelViewController, NSTableView) {
        let controller = OperationsPanelController()
        let window = try XCTUnwrap(controller.window)
        let viewController = try XCTUnwrap(window.contentViewController as? OperationsPanelViewController)
        viewController.pasteboard = pasteboard
        let view = viewController.view
        view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(view.firstSubview(withAccessibilityIdentifier: "operations-table") as? NSTableView)
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        return (controller, viewController, table)
    }
}

// MARK: - Rows follow state changes

extension OperationRowActionAccessibilityTests {
    func testOperationsCellActionsFollowTheOperationStateThroughTheAXBridge() throws {
        let operationID = OperationCenter.shared.begin(
            title: "Call variants",
            detail: "Running bcftools",
            operationType: .assembly,
            cliCommand: "lungfish call-variants sample.bam",
            onCancel: {}
        ).rowID
        defer { OperationCenter.shared.clearCompleted() }

        let (controller, _, table) = try makePanel()
        defer { controller.close() }
        let row = try XCTUnwrap(OperationCenter.shared.items.firstIndex { $0.id == operationID })
        func firstCellNames() -> [String]? {
            guard let proxy = AccessibilityRowProbe.rowProxies(of: table)[safe: row] else { return nil }
            return AccessibilityRowProbe.cellActionNames(proxy).first
        }
        XCTAssertEqual(firstCellNames(), ["Copy CLI Command", "Cancel"])

        // Completing the operation reloads its row; the cell actions follow.
        _ = OperationCenter.shared.complete(id: operationID, detail: "Done")
        try awaitMainActor(timeout: 2) { firstCellNames() == ["Copy CLI Command", "Clear"] }
    }

    private func awaitMainActor(timeout: TimeInterval, until predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline { return XCTFail("Timed out waiting for condition") }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
