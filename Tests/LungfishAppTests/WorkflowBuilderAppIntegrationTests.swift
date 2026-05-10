import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class WorkflowBuilderAppIntegrationTests: XCTestCase {

    func testWorkflowBuilderMenuActionOpensReusableWindow() throws {
        let _ = NSApplication.shared
        closeWorkflowBuilderWindows()
        addTeardownBlock { @MainActor in
            self.closeWorkflowBuilderWindows()
        }

        let delegate = AppDelegate()

        delegate.showWorkflowBuilder(nil)
        let firstWindow = try XCTUnwrap(workflowBuilderWindow())
        XCTAssertEqual(firstWindow.accessibilityIdentifier(), "WorkflowBuilderWindow")
        XCTAssertEqual(firstWindow.frame.width, 1024, accuracy: 1)
        XCTAssertEqual(firstWindow.frame.height, 720, accuracy: 1)

        firstWindow.performClose(nil)
        delegate.showWorkflowBuilder(nil)

        let reopenedWindow = try XCTUnwrap(workflowBuilderWindow())
        XCTAssertTrue(reopenedWindow === firstWindow)
        XCTAssertTrue(reopenedWindow.isVisible)

        reopenedWindow.close()
    }

    func testWorkflowBuilderToolbarIncludesRunButton() throws {
        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        let toolbar = NSToolbar(identifier: "WorkflowBuilderToolbar")

        XCTAssertTrue(controller.toolbarDefaultItemIdentifiers(toolbar).contains(.workflowRun))

        let item = try XCTUnwrap(
            controller.toolbar(toolbar, itemForItemIdentifier: .workflowRun, willBeInsertedIntoToolbar: true)
        )
        XCTAssertEqual(item.label, "Run")
        XCTAssertEqual(item.action, #selector(WorkflowBuilderViewController.runWorkflow(_:)))
        XCTAssertNotNil(item.image)
    }

    func testWorkflowBundleSaveWritesGraphAndProvenanceDirectory() throws {
        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        let tempDirectory = try makeTemporaryDirectory()
        let requestedURL = tempDirectory.appendingPathComponent("workflow.json", isDirectory: false)

        let savedURL = try controller.saveWorkflowBundleForTesting(to: requestedURL)

        XCTAssertEqual(savedURL.pathExtension, "lungfishflow")
        XCTAssertEqual(controller.workflowURL, savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestedURL.path))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.appendingPathComponent("graph.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.appendingPathComponent("provenance.json").path))
    }

    private func workflowBuilderWindow() -> NSWindow? {
        NSApp.windows.first { $0.accessibilityIdentifier() == "WorkflowBuilderWindow" }
    }

    private func closeWorkflowBuilderWindows() {
        for window in NSApp.windows where window.accessibilityIdentifier() == "WorkflowBuilderWindow" {
            window.close()
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-workflow-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
