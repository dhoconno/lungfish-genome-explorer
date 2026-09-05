import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class ProjectWriteLeaseGateTests: XCTestCase {
    func testActualWritableOpenDoesNotTreatItsExactWriterLeaseAsForeign() async throws {
        let root = try temporaryRoot()
        let app = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        defer { controller.projectSession.closeProject(); controller.mainSplitViewController?.sidebarController.closeProject(); controller.close(); try? FileManager.default.removeItem(at: root) }
        let url = try project(in: root)
        app.testingSetMainWindowControllers([controller])
        app.openProject(url, in: controller)
        await app.testingWaitForProjectOpen(in: controller)
        XCTAssertTrue(ProjectStore.ownsWriterLease(at: url))
        XCTAssertFalse(controller.projectSession.isReadOnlyRecommended)
        XCTAssertFalse(ProjectOpenWarningState.evaluate(projectURL: url).isReadOnlyRecommended)
        XCTAssertFalse(app.isProjectWriteBlocked(projectURL: url, windowStateScope: controller.projectSession.windowStateScope))
    }

    func testReadOnlyPeerKeepsItsOverrideWithoutBlockingExplicitWritableOwner() async throws {
        let root = try temporaryRoot()
        let app = makeAppDelegateWithTemporaryState()
        let writer = MainWindowController()
        let reader = MainWindowController()
        defer {
            for controller in [reader, writer] { controller.projectSession.closeProject(); controller.mainSplitViewController?.sidebarController.closeProject(); controller.close() }
            try? FileManager.default.removeItem(at: root)
        }
        let url = try project(in: root)
        app.testingSetMainWindowControllers([writer, reader])
        app.openProject(url, in: writer)
        await app.testingWaitForProjectOpen(in: writer)
        _ = try await reader.projectSession.openProjectAsync(at: url, access: .readOnly)
        app.mainWindowController = reader
        XCTAssertTrue(reader.projectSession.isReadOnlyRecommended)
        XCTAssertTrue(app.isProjectWriteBlocked(projectURL: url, windowStateScope: reader.projectSession.windowStateScope))
        XCTAssertFalse(app.isProjectWriteBlocked(projectURL: url, windowStateScope: writer.projectSession.windowStateScope),
            "Another read-only window must not override the explicitly scoped writable owner")
    }

    func testReplacedLeaseFromSameProcessStillBlocksWrites() async throws {
        let root = try temporaryRoot()
        let app = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        defer { controller.projectSession.closeProject(); controller.mainSplitViewController?.sidebarController.closeProject(); controller.close(); try? FileManager.default.removeItem(at: root) }
        let url = try project(in: root)
        app.testingSetMainWindowControllers([controller])
        app.openProject(url, in: controller)
        await app.testingWaitForProjectOpen(in: controller)
        let lockURL = ProjectLockManager.lockURL(for: url)
        let original = try Data(contentsOf: lockURL)
        defer { try? original.write(to: lockURL, options: .atomic) }
        let otherRecord = ProjectLockRecord.current(projectURL: url, mode: "write", toolName: "invented other writer", appVersion: "test")
        try JSONEncoder().encode(otherRecord).write(to: lockURL, options: .atomic)
        XCTAssertFalse(ProjectStore.ownsWriterLease(at: url), "Ownership requires the exact held record, not merely our PID")
        XCTAssertTrue(ProjectOpenWarningState.evaluate(projectURL: url).isReadOnlyRecommended)
        XCTAssertTrue(app.isProjectWriteBlocked(projectURL: url, windowStateScope: controller.projectSession.windowStateScope))
    }

    private func temporaryRoot() throws -> URL {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WriteLeaseGate-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func project(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("invented.lungfish")
        _ = try ProjectFile.create(at: url, name: "invented")
        return url
    }
}
