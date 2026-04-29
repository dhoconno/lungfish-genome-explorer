import XCTest
import SwiftUI
@testable import LungfishApp

final class DatasetOperationsDialogTests: XCTestCase {
    func testSharedSectionOrderMatchesApprovedDialogContract() {
        XCTAssertEqual(DatasetOperationSection.allCases.map(\.title), [
            "Overview",
            "Inputs",
            "Primary Settings",
            "Advanced Settings",
            "Output",
            "Readiness",
        ])
    }

    func testToolAvailabilityStatePreservesComingSoonAndDisabledReason() {
        XCTAssertEqual(DatasetOperationAvailability.comingSoon.badgeText, "Coming Soon")
        XCTAssertEqual(
            DatasetOperationAvailability.disabled(reason: "Requires Alignment Pack").badgeText,
            "Requires Alignment Pack"
        )
    }

    @MainActor
    func testPrimaryActionTitleDefaultsToRun() {
        let dialog = DatasetOperationsDialog(
            title: "Operations",
            subtitle: "Configure a tool",
            datasetLabel: "sample.fastq",
            tools: [],
            selectedToolID: "tool",
            statusText: "Ready",
            isRunEnabled: true,
            onSelectTool: { _ in },
            onCancel: {},
            onRun: {}
        ) {
            EmptyView()
        }

        XCTAssertEqual(dialog.primaryActionTitle, "Run")
    }

    @MainActor
    func testPrimaryActionTitleCanBeCustomized() {
        let dialog = DatasetOperationsDialog(
            title: "Operations",
            subtitle: "Configure a tool",
            datasetLabel: "sample.fastq",
            tools: [],
            selectedToolID: "tool",
            statusText: "Ready",
            isRunEnabled: true,
            primaryActionTitle: "Search",
            onSelectTool: { _ in },
            onCancel: {},
            onRun: {}
        ) {
            EmptyView()
        }

        XCTAssertEqual(dialog.primaryActionTitle, "Search")
    }

    func testSharedDialogDeclaresStandardKeyboardActions() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".keyboardShortcut(.cancelAction)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.defaultAction)"))
    }

    @MainActor
    func testSelectingUnavailableToolDoesNotCallSelectionHandler() {
        var selectedToolIDs: [String] = []
        let availableTool = DatasetOperationToolSidebarItem(
            id: "available",
            title: "Available",
            subtitle: "Runs now",
            availability: .available
        )
        let disabledTool = DatasetOperationToolSidebarItem(
            id: "disabled",
            title: "Disabled",
            subtitle: "Needs a pack",
            availability: .disabled(reason: "Requires Alignment Pack")
        )
        let dialog = DatasetOperationsDialog(
            title: "Operations",
            subtitle: "Configure a tool",
            datasetLabel: "sample.fastq",
            tools: [availableTool, disabledTool],
            selectedToolID: availableTool.id,
            statusText: "Ready",
            isRunEnabled: false,
            onSelectTool: { selectedToolIDs.append($0) },
            onCancel: {},
            onRun: {}
        ) {
            EmptyView()
        }

        dialog.selectToolIfAvailable(availableTool)
        dialog.selectToolIfAvailable(disabledTool)

        XCTAssertEqual(selectedToolIDs, ["available"])
    }

    @MainActor
    func testRunActionHonorsIsRunEnabled() {
        var blockedRunCount = 0
        let blockedDialog = DatasetOperationsDialog(
            title: "Operations",
            subtitle: "Configure a tool",
            datasetLabel: "sample.fastq",
            tools: [],
            selectedToolID: "tool",
            statusText: "Blocked",
            isRunEnabled: false,
            onSelectTool: { _ in },
            onCancel: {},
            onRun: { blockedRunCount += 1 }
        ) {
            EmptyView()
        }

        blockedDialog.runIfEnabled()
        XCTAssertEqual(blockedRunCount, 0)

        var allowedRunCount = 0
        let allowedDialog = DatasetOperationsDialog(
            title: "Operations",
            subtitle: "Configure a tool",
            datasetLabel: "sample.fastq",
            tools: [],
            selectedToolID: "tool",
            statusText: "Ready",
            isRunEnabled: true,
            onSelectTool: { _ in },
            onCancel: {},
            onRun: { allowedRunCount += 1 }
        ) {
            EmptyView()
        }

        allowedDialog.runIfEnabled()
        XCTAssertEqual(allowedRunCount, 1)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
