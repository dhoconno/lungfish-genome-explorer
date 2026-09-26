import AppKit
import Foundation
import XCTest
import LungfishKit
@testable import LungfishApp

@MainActor
final class OperationResultNavigationTests: XCTestCase {
    private func resultButton(
        operationID: UUID,
        in table: NSTableView
    ) -> NSButton? {
        guard let actionColumn = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "action" }) else {
            return nil
        }
        let identifier = "operations-results-\(operationID)"
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: actionColumn, row: row, makeIfNecessary: true) else { continue }
            if let button = cell.subviews.compactMap({ $0 as? NSButton }).first(where: {
                $0.accessibilityIdentifier() == identifier
            }) {
                return button
            }
        }
        return nil
    }

    func testResultURLChoosesFirstExistingCompletedBundle() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let missing = temporaryDirectory.appendingPathComponent("missing.lungfishref", isDirectory: true)
        let existing = temporaryDirectory.appendingPathComponent("result.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let item = OperationCenter.Item(
            title: "Build reference",
            detail: "Done",
            progress: 1,
            state: .completed,
            bundleURLs: [missing, existing]
        )

        XCTAssertEqual(OperationResultNavigation.resultURL(for: item), existing.standardizedFileURL)
    }

    func testResultURLDoesNotTreatLooseOutputOrTargetAsViewerResult() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = temporaryDirectory.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        let report = temporaryDirectory.appendingPathComponent("report.tsv")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try Data().write(to: report)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let item = OperationCenter.Item(
            title: "Export report",
            detail: "Done",
            progress: 1,
            state: .completed,
            outputURLs: [report],
            targetBundleURL: target
        )

        XCTAssertNil(OperationResultNavigation.resultURL(for: item))
    }

    func testResultURLAcceptsNativePrimerAnalysisPublishedAsOutput() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primerAnalysis = temporaryDirectory
            .appendingPathComponent("primer-design.lungfishprimeranalysis", isDirectory: true)
        try FileManager.default.createDirectory(at: primerAnalysis, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let item = OperationCenter.Item(
            title: "Design primers",
            detail: "Done",
            progress: 1,
            state: .completed,
            outputURLs: [primerAnalysis]
        )

        XCTAssertEqual(OperationResultNavigation.resultURL(for: item), primerAnalysis.standardizedFileURL)
    }

    func testResultURLRequiresCompletedOperation() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = temporaryDirectory.appendingPathComponent("partial.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let item = OperationCenter.Item(
            title: "Build reference",
            detail: "Working",
            progress: 0.5,
            state: .running,
            bundleURLs: [bundle]
        )

        XCTAssertNil(OperationResultNavigation.resultURL(for: item))
    }

    func testResultURLRejectsBundleOutsideOriginatingProject() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = temporaryDirectory.appendingPathComponent("Project", isDirectory: true)
        let outsideBundle = temporaryDirectory.appendingPathComponent("other.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideBundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let item = OperationCenter.Item(
            title: "Build reference",
            detail: "Done",
            progress: 1,
            state: .completed,
            bundleURLs: [outsideBundle],
            routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: nil)
        )

        XCTAssertNil(OperationResultNavigation.resultURL(for: item))
    }

    func testPanelEnablesResultsOnlyForCompletedViewableOutput() throws {
        _ = NSApplication.shared
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primerAnalysis = temporaryDirectory
            .appendingPathComponent("primer-design.lungfishprimeranalysis", isDirectory: true)
        try FileManager.default.createDirectory(at: primerAnalysis, withIntermediateDirectories: true)

        let completedID = OperationCenter.shared.start(
            title: "Completed primer design fixture",
            detail: "Finishing",
            operationType: .workflow
        )
        XCTAssertTrue(OperationCenter.shared.complete(
            id: completedID,
            detail: "Done",
            outputURLs: [primerAnalysis]
        ))
        let runningID = OperationCenter.shared.start(
            title: "Running primer design fixture",
            detail: "Working",
            operationType: .workflow
        )
        defer {
            _ = OperationCenter.shared.complete(id: runningID, detail: "Test cleanup")
            OperationCenter.shared.clearItem(id: runningID)
            OperationCenter.shared.clearItem(id: completedID)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let panel = OperationsPanelController()
        defer { panel.close() }
        let view = try XCTUnwrap(panel.window?.contentViewController?.view)
        view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(view.findDescendant(ofType: NSTableView.self) {
            $0.accessibilityIdentifier() == "operations-table"
        })

        let completedButton = try XCTUnwrap(resultButton(operationID: completedID, in: table))
        XCTAssertEqual(completedButton.accessibilityIdentifier(), "operations-results-\(completedID)")
        XCTAssertTrue(completedButton.isEnabled)

        let runningButton = try XCTUnwrap(resultButton(operationID: runningID, in: table))
        XCTAssertEqual(runningButton.accessibilityIdentifier(), "operations-results-\(runningID)")
        XCTAssertFalse(runningButton.isEnabled)
    }

    func testStaleWindowRouteFallsBackOnlyToOpenWindowForSameProject() {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        let projectURL = URL(fileURLWithPath: "/tmp/results-route-project.lungfish", isDirectory: true)
        let projectSession = ProjectSession()
        projectSession.openReadOnlyFilesystemFallback(at: projectURL)
        let projectController = MainWindowController(window: nil, projectSession: projectSession)
        delegate.mainWindowController = projectController
        delegate.testingSetMainWindowControllers([projectController])

        let item = OperationCenter.Item(
            title: "Persisted result",
            detail: "Done",
            progress: 1,
            state: .completed,
            routeContext: OperationRouteContext(
                projectURL: projectURL,
                windowStateScope: WindowStateScope()
            )
        )

        XCTAssertTrue(OperationResultNavigation.targetController(for: item, appDelegate: delegate) === projectController)

        let unrelatedItem = OperationCenter.Item(
            title: "Other result",
            detail: "Done",
            progress: 1,
            state: .completed,
            routeContext: OperationRouteContext(
                projectURL: URL(fileURLWithPath: "/tmp/unrelated-project.lungfish", isDirectory: true),
                windowStateScope: WindowStateScope()
            )
        )
        XCTAssertNil(OperationResultNavigation.targetController(for: unrelatedItem, appDelegate: delegate))
    }
}

private extension NSView {
    func findDescendant<T: NSView>(
        ofType type: T.Type,
        where predicate: (T) -> Bool
    ) -> T? {
        if let match = self as? T, predicate(match) { return match }
        for subview in subviews {
            if let match = subview.findDescendant(ofType: type, where: predicate) { return match }
        }
        return nil
    }
}
