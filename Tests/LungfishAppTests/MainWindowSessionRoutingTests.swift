import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class MainWindowSessionRoutingTests: XCTestCase {
    func testMainWindowControllerKeepsAssignedProjectSession() {
        let session = ProjectSession()
        let controller = MainWindowController(projectSession: session)

        XCTAssertTrue(controller.projectSession === session)
        XCTAssertTrue(controller.mainSplitViewController.projectSession === session)
    }

    func testOpeningSameProjectInTwoControllersDoesNotShareActiveDocument() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SameProjectWindows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("Shared.lungfish", isDirectory: true)
        let project = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")
        _ = try project.addSequence(try Sequence(name: "left", alphabet: .dna, bases: "AAAA"))
        _ = try project.addSequence(try Sequence(name: "right", alphabet: .dna, bases: "CCCC"))
        try project.save()

        let first = MainWindowController(projectSession: ProjectSession())
        let second = MainWindowController(projectSession: ProjectSession())

        try first.projectSession.openProject(at: projectURL)
        try second.projectSession.openProject(at: projectURL)
        first.projectSession.setActiveDocument(first.projectSession.documents[0])
        second.projectSession.setActiveDocument(second.projectSession.documents[1])

        XCTAssertEqual(first.projectSession.activeDocument?.name, "left")
        XCTAssertEqual(second.projectSession.activeDocument?.name, "right")
    }

    func testReadOnlyProjectSessionShowsProjectLockBanner() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadOnlyBanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("Locked.lungfish", isDirectory: true)
        let project = try DocumentManager.shared.createProject(at: projectURL, name: "Locked")
        _ = try project.addSequence(try Sequence(name: "locked_seq", alphabet: .dna, bases: "GATTACA"))
        try project.save()

        try ProjectLockManager().writeLock(
            ProjectLockRecord(
                schemaVersion: 1,
                toolName: "lungfish project lock",
                appVersion: "lungfish-cli test",
                projectPath: projectURL.standardizedFileURL.path,
                mode: "exclusive",
                user: "dho",
                host: ProcessInfo.processInfo.hostName,
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                processStartTime: "",
                cwd: temp.path,
                createdAt: "2026-05-14T01:03:00Z"
            ),
            to: ProjectLockManager.lockURL(for: projectURL)
        )

        let session = ProjectSession()
        try session.openProject(at: projectURL)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }

        _ = controller.window?.contentViewController?.view
        controller.mainSplitViewController.applyProjectSessionState()

        let root = try XCTUnwrap(controller.window?.contentView)
        let banner = try XCTUnwrap(root.descendant(matching: MainWindowAccessibilityID.projectLockBanner))
        let title = try XCTUnwrap(root.descendant(matching: MainWindowAccessibilityID.projectLockBannerTitle) as? NSTextField)
        let detail = try XCTUnwrap(root.descendant(matching: MainWindowAccessibilityID.projectLockBannerDetail) as? NSTextField)

        XCTAssertFalse(banner.isHidden)
        XCTAssertEqual(title.stringValue, "Project opened read-only")
        XCTAssertTrue(detail.stringValue.contains("exclusive"))
        XCTAssertTrue(detail.stringValue.contains("active"))
        XCTAssertTrue(detail.stringValue.contains("dho@\(ProcessInfo.processInfo.hostName)"))
        XCTAssertTrue(detail.stringValue.contains("pid \(ProcessInfo.processInfo.processIdentifier)"))
    }

    func testUnlockedProjectSessionHidesProjectLockBanner() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnlockedBanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("Unlocked.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: projectURL, name: "Unlocked")

        let session = ProjectSession()
        try session.openProject(at: projectURL)
        let controller = MainWindowController(projectSession: session)
        defer { controller.close() }

        _ = controller.window?.contentViewController?.view
        controller.mainSplitViewController.applyProjectSessionState()

        let root = try XCTUnwrap(controller.window?.contentView)
        XCTAssertNil(root.descendant(matching: MainWindowAccessibilityID.projectLockBanner))
    }

    func testRestoreCreatesTwoControllersForSameProjectSnapshots() throws {
        let delegate = AppDelegate()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreSameProject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let projectURL = temp.appendingPathComponent("Shared.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")

        let snapshots = [
            ProjectWindowSnapshot(
                id: UUID(),
                projectURL: projectURL,
                windowOrdinal: 1,
                windowOrder: 0,
                windowTitleSuffix: "[1]",
                frame: nil,
                isFullScreen: false,
                selectedSidebarURL: nil,
                expandedSidebarURLs: [],
                sidebarSearchText: nil,
                activeContent: nil,
                inspectorTab: nil,
                sidebarCollapsed: false,
                inspectorCollapsed: false,
                sidebarWidth: nil,
                inspectorWidth: nil,
                operationsPanelFilter: nil,
                operationsPanelVisible: false
            ),
            ProjectWindowSnapshot(
                id: UUID(),
                projectURL: projectURL,
                windowOrdinal: 2,
                windowOrder: 1,
                windowTitleSuffix: "[2]",
                frame: nil,
                isFullScreen: false,
                selectedSidebarURL: nil,
                expandedSidebarURLs: [],
                sidebarSearchText: nil,
                activeContent: nil,
                inspectorTab: nil,
                sidebarCollapsed: false,
                inspectorCollapsed: false,
                sidebarWidth: nil,
                inspectorWidth: nil,
                operationsPanelFilter: nil,
                operationsPanelVisible: false
            )
        ]

        try delegate.testingRestoreProjectWindows(from: ProjectWindowStateEnvelope(windows: snapshots))

        XCTAssertEqual(delegate.testingMainWindowControllers.count, 2)
        XCTAssertEqual(
            Set(delegate.testingMainWindowControllers.compactMap { $0.projectSession.projectURL?.standardizedFileURL }),
            [projectURL.standardizedFileURL]
        )
    }

    func testRestoreDoesNotDeleteProjectTempDirectory() throws {
        let delegate = AppDelegate()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestorePreservesProjectTemp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("Shared.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")
        let pendingTempFile = projectURL
            .appendingPathComponent(".tmp", isDirectory: true)
            .appendingPathComponent("running-workflow", isDirectory: true)
            .appendingPathComponent("checkpoint.txt")
        try FileManager.default.createDirectory(
            at: pendingTempFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "pending".write(to: pendingTempFile, atomically: true, encoding: .utf8)

        let snapshot = ProjectWindowSnapshot(
            id: UUID(),
            projectURL: projectURL,
            windowOrdinal: 1,
            windowOrder: 0,
            windowTitleSuffix: "[1]",
            frame: nil,
            isFullScreen: false,
            selectedSidebarURL: nil,
            expandedSidebarURLs: [],
            sidebarSearchText: nil,
            activeContent: nil,
            inspectorTab: nil,
            sidebarCollapsed: false,
            inspectorCollapsed: false,
            sidebarWidth: nil,
            inspectorWidth: nil,
            operationsPanelFilter: nil,
            operationsPanelVisible: false
        )

        XCTAssertTrue(try delegate.testingRestoreProjectWindows(from: ProjectWindowStateEnvelope(windows: [snapshot])))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pendingTempFile.path),
            "Persistent window restore must not delete project-scoped workflow temp state"
        )
    }

    func testOpeningDuplicateProjectWindowDoesNotDeleteProjectTempDirectory() throws {
        let delegate = AppDelegate()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateOpenPreservesProjectTemp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("Shared.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")

        let first = MainWindowController(projectSession: ProjectSession())
        let second = MainWindowController(projectSession: ProjectSession())
        defer {
            first.close()
            second.close()
        }

        delegate.testingOpenProject(projectURL, in: first)

        let pendingTempFile = projectURL
            .appendingPathComponent(".tmp", isDirectory: true)
            .appendingPathComponent("running-workflow", isDirectory: true)
            .appendingPathComponent("checkpoint.txt")
        try FileManager.default.createDirectory(
            at: pendingTempFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "pending".write(to: pendingTempFile, atomically: true, encoding: .utf8)

        delegate.testingOpenProject(projectURL, in: second)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pendingTempFile.path),
            "Opening a duplicate same-project window must not purge active project temp state"
        )
    }

    func testClosingDuplicateWindowRetitlesRemainingSameProjectWindows() throws {
        let delegate = AppDelegate()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetitleSameProjectWindows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let projectURL = temp.appendingPathComponent("Shared.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")

        let snapshots = (0..<3).map { index in
            ProjectWindowSnapshot(
                id: UUID(),
                projectURL: projectURL,
                windowOrdinal: index + 1,
                windowOrder: index,
                windowTitleSuffix: "[\(index + 1)]",
                frame: nil,
                isFullScreen: false,
                selectedSidebarURL: nil,
                expandedSidebarURLs: [],
                sidebarSearchText: nil,
                activeContent: nil,
                inspectorTab: nil,
                sidebarCollapsed: false,
                inspectorCollapsed: false,
                sidebarWidth: nil,
                inspectorWidth: nil,
                operationsPanelFilter: nil,
                operationsPanelVisible: false
            )
        }
        XCTAssertTrue(try delegate.testingRestoreProjectWindows(from: ProjectWindowStateEnvelope(windows: snapshots)))

        let secondWindow = try XCTUnwrap(delegate.testingMainWindowControllers.dropFirst().first?.window)
        let notification = Notification(name: NSWindow.willCloseNotification, object: secondWindow)
        _ = delegate.perform(NSSelectorFromString("windowWillClose:"), with: notification)

        let titles = delegate.testingMainWindowControllers.compactMap(\.window?.title)
        XCTAssertEqual(titles.count, 2)
        XCTAssertTrue(titles.contains("Shared [1] - Lungfish Genome Explorer"))
        XCTAssertTrue(titles.contains("Shared [2] - Lungfish Genome Explorer"))
        XCTAssertFalse(titles.contains("Shared [3] - Lungfish Genome Explorer"))
    }

    func testApplicationActivationDoesNotForceTrackedMainWindowKey() throws {
        let appDelegateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
        let source = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public func applicationDidBecomeActive"))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: "// MARK: - File Handling"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(
            body.contains("makeKeyAndOrderFront"),
            "Activation should let AppKit preserve the clicked/key window in same-project multi-window sessions"
        )
    }

    func testRestoreSkipsCorruptSavedProjectAndKeepsRestoringOtherWindows() throws {
        let delegate = AppDelegate()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreCorruptProject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let goodProjectURL = temp.appendingPathComponent("Good.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: goodProjectURL, name: "Good")
        let corruptProjectURL = temp.appendingPathComponent("Corrupt.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptProjectURL, withIntermediateDirectories: true)

        let snapshots = [
            ProjectWindowSnapshot(
                id: UUID(),
                projectURL: corruptProjectURL,
                windowOrdinal: 1,
                windowOrder: 0,
                windowTitleSuffix: "[1]",
                frame: nil,
                isFullScreen: false,
                selectedSidebarURL: nil,
                expandedSidebarURLs: [],
                sidebarSearchText: nil,
                activeContent: nil,
                inspectorTab: nil,
                sidebarCollapsed: false,
                inspectorCollapsed: false,
                sidebarWidth: nil,
                inspectorWidth: nil,
                operationsPanelFilter: nil,
                operationsPanelVisible: false
            ),
            ProjectWindowSnapshot(
                id: UUID(),
                projectURL: goodProjectURL,
                windowOrdinal: 2,
                windowOrder: 1,
                windowTitleSuffix: "[2]",
                frame: nil,
                isFullScreen: false,
                selectedSidebarURL: nil,
                expandedSidebarURLs: [],
                sidebarSearchText: nil,
                activeContent: nil,
                inspectorTab: nil,
                sidebarCollapsed: false,
                inspectorCollapsed: false,
                sidebarWidth: nil,
                inspectorWidth: nil,
                operationsPanelFilter: nil,
                operationsPanelVisible: false
            ),
        ]

        XCTAssertTrue(try delegate.testingRestoreProjectWindows(from: ProjectWindowStateEnvelope(windows: snapshots)))
        XCTAssertEqual(delegate.testingMainWindowControllers.count, 1)
        XCTAssertEqual(
            delegate.testingMainWindowControllers.first?.projectSession.projectURL?.standardizedFileURL,
            goodProjectURL.standardizedFileURL
        )
    }

    func testProjectSessionStateRestoreAppliesSavedPaneWidths() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestorePaneWidths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("PaneWidths.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: projectURL, name: "PaneWidths")
        let session = ProjectSession()
        try session.openProject(at: projectURL)
        let controller = MainSplitViewController(projectSession: session)
        _ = controller.view

        let snapshot = ProjectWindowSnapshot(
            id: UUID(),
            projectURL: projectURL,
            windowOrdinal: 1,
            windowOrder: 0,
            windowTitleSuffix: "[1]",
            frame: nil,
            isFullScreen: false,
            selectedSidebarURL: nil,
            expandedSidebarURLs: [],
            sidebarSearchText: nil,
            activeContent: nil,
            inspectorTab: nil,
            sidebarCollapsed: false,
            inspectorCollapsed: false,
            sidebarWidth: 320,
            inspectorWidth: 420,
            operationsPanelFilter: nil,
            operationsPanelVisible: false
        )

        controller.applyProjectSessionState(restoring: snapshot)

        XCTAssertEqual(controller.testingSidebarConstraintWidth, 320, accuracy: 0.5)
        XCTAssertEqual(controller.testingInspectorConstraintWidth, 420, accuracy: 0.5)
    }

    func testProjectSessionStateRestoreAppliesSavedDocumentContent() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreSavedDocument-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("SavedDocument.lungfish", isDirectory: true)
        let project = try DocumentManager.shared.createProject(at: projectURL, name: "SavedDocument")
        _ = try project.addSequence(try Sequence(name: "first", alphabet: .dna, bases: "AAAA"))
        _ = try project.addSequence(try Sequence(name: "second", alphabet: .dna, bases: "CCCC"))
        try project.save()

        let session = ProjectSession()
        try session.openProject(at: projectURL)
        let savedDocument = try XCTUnwrap(session.documents.first { $0.name == "second" })
        let controller = MainSplitViewController(projectSession: session)
        _ = controller.view

        let snapshot = ProjectWindowSnapshot(
            id: UUID(),
            projectURL: projectURL,
            windowOrdinal: 1,
            windowOrder: 0,
            windowTitleSuffix: "[1]",
            frame: nil,
            isFullScreen: false,
            selectedSidebarURL: savedDocument.url,
            expandedSidebarURLs: [],
            sidebarSearchText: nil,
            activeContent: RestorableContentState(kind: "document", url: savedDocument.url),
            inspectorTab: nil,
            sidebarCollapsed: false,
            inspectorCollapsed: false,
            sidebarWidth: nil,
            inspectorWidth: nil,
            operationsPanelFilter: nil,
            operationsPanelVisible: false
        )

        controller.applyProjectSessionState(restoring: snapshot)

        XCTAssertEqual(session.activeDocument?.url.standardizedFileURL, savedDocument.url.standardizedFileURL)
        XCTAssertEqual(session.activeDocument?.name, "second")
    }
}

private extension NSView {
    func descendant(matching identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.descendant(matching: identifier) {
                return match
            }
        }
        return nil
    }
}
