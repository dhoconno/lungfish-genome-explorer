import AppKit
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// Matrix rows publish their review and visibility commands to AX clients,
/// and the review chords travel through the menu bar rather than the view.
@MainActor
final class GenotypeMatrixRowAccessibilityTests: GenotypeResultViewportTestCase {
    private func subviewTree(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + subviewTree(of: $0) }
    }

    private func pinnedTable(in matrix: NSView) throws -> NSTableView {
        try XCTUnwrap(
            subviewTree(of: matrix).compactMap { $0 as? NSTableView }.first {
                $0.tableColumns.contains { $0.identifier.rawValue == "rowSelector" }
            }
        )
    }

    private struct Fixture {
        let controller: GenotypeResultViewController
        let matrix: GenotypeComparisonMatrixView
        let bundleURL: URL
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "MatrixRowAX")
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let controller = makeMatrixAnnotationGuardedController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "01_Mafa_A1", reads: 8),
                makeCall(sample: "AnimalA", genotype: "02_Mafa_B", reads: 7),
            ]
        ))
        let matrix = controller.testingComparisonMatrix
        matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        matrix.layoutSubtreeIfNeeded()
        return Fixture(controller: controller, matrix: matrix, bundleURL: bundleURL, root: root)
    }

    func testRowOffersOnlyVisibilityActionsUntilAReviewableCellIsSelected() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let table = try pinnedTable(in: fixture.matrix)
        table.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(AccessibilityRowProbe.rowProxies(of: table).first, "the matrix has no AX rows")
        XCTAssertEqual(AccessibilityRowProbe.firstCellActionNames(row), ["Hide Row", "Show Only Row"])

        fixture.controller.testingSelectMatrixCell(genotype: "01_Mafa_A1", sample: "AnimalA")
        let names = AccessibilityRowProbe.firstCellActionNames(row)
        for expected in ["Mark False Positive", "Edit Comment", "Hide Row", "Show Only Row"] {
            XCTAssertTrue(names.contains(expected), "\(expected) missing from \(names)")
        }
        let served = AccessibilityRowProbe.servedCellActionNames(row).first ?? []
        XCTAssertEqual(
            served.filter { names.contains($0) }.sorted(), names.sorted(),
            "each action is served exactly once"
        )
    }

    func testMarkFalsePositiveActionAppliesToTheSelectedCellOfTheRow() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let table = try pinnedTable(in: fixture.matrix)
        table.layoutSubtreeIfNeeded()
        fixture.controller.testingSelectMatrixCell(genotype: "01_Mafa_A1", sample: "AnimalA")
        let row = try XCTUnwrap(AccessibilityRowProbe.rowProxies(of: table).first)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Mark False Positive", in: row))
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: fixture.bundleURL)
        XCTAssertEqual(sidecar.matrixReviews.map(\.disposition), [.falsePositive])
        XCTAssertEqual(
            sidecar.matrixReviews.first?.target,
            .cell(locus: "MHC-A", genotype: "01_Mafa_A1", sample: "AnimalA")
        )
    }

    func testHideRowActionSelectsTheRowItIsOnAndHidesIt() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let table = try pinnedTable(in: fixture.matrix)
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(Set(fixture.controller.testingVisibleMatrixGenotypes), ["01_Mafa_A1", "02_Mafa_B"])
        let rows = AccessibilityRowProbe.rowProxies(of: table)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(AccessibilityRowProbe.performCellAction(named: "Hide Row", in: rows[1]))
        XCTAssertEqual(fixture.controller.testingVisibleMatrixGenotypes, ["01_Mafa_A1"])
    }

    func testChordIsLeftToTheMenuAndTheMenuItemReachesTheFocusedMatrix() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = fixture.matrix
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        fixture.controller.testingSelectMatrixCell(genotype: "01_Mafa_A1", sample: "AnimalA")
        // The table inside the matrix has the focus, so the action must travel
        // up the responder chain to reach the matrix.
        let table = try pinnedTable(in: fixture.matrix)
        XCTAssertTrue(window.makeFirstResponder(table))

        // The matrix no longer claims the chord, so the key reaches the menu bar.
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "p", charactersIgnoringModifiers: "p",
            isARepeat: false, keyCode: 0
        ))
        XCTAssertFalse(fixture.matrix.performKeyEquivalent(with: event))

        // The Tools menu item is a nil-target item, so the responder chain
        // finds the focused matrix, validates it and runs the command.
        let item = NSMenuItem(
            title: "Mark False Positive",
            action: #selector(GenotypeMatrixReviewMenuActions.markSelectionFalsePositive(_:)),
            keyEquivalent: "p"
        )
        XCTAssertTrue(fixture.matrix.validateMenuItem(item))
        XCTAssertTrue(table.tryToPerform(item.action!, with: item))
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: fixture.bundleURL)
        XCTAssertEqual(sidecar.matrixReviews.map(\.disposition), [.falsePositive])
    }

    func testReviewMenuItemsAreDisabledWhileAnotherViewHasFocus() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 540))
        let field = NSTextField(frame: NSRect(x: 0, y: 500, width: 200, height: 24))
        fixture.matrix.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        container.addSubview(fixture.matrix)
        container.addSubview(field)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        fixture.controller.testingShowMatrixTargetSelection([
            .cell(locus: "MHC-A", genotype: "01_Mafa_A1", sample: "AnimalA"),
        ])
        XCTAssertTrue(window.makeFirstResponder(field))
        let item = NSMenuItem(
            title: "Mark False Positive",
            action: #selector(GenotypeMatrixReviewMenuActions.markSelectionFalsePositive(_:)),
            keyEquivalent: "p"
        )
        XCTAssertFalse(fixture.matrix.validateMenuItem(item))
    }

    func testColumnsPullDownListsItsItemsAsAccessibilityActions() throws {
        let fixture = try makeFixture()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let button = try XCTUnwrap(
            subviewTree(of: fixture.matrix).first { $0.accessibilityIdentifier() == "genotype-matrix-columns" }
        )
        let names = (button.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertTrue(names.contains("Locus"), "\(names)")
        XCTAssertTrue(names.contains("Total Reads"), "\(names)")
        XCTAssertEqual(names.count, Set(names).count, "each column listed once")
    }
}
