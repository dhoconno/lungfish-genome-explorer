import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class ProjectFilesystemWindowOwnershipTests: XCTestCase {
    func testRootLossMakesBothActualWindowsUnavailableAndInvalidatesUsableProjectScope() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnavailableWindows-\(UUID())")
        defer { ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invented.lungfish")
        do {
            let project = try ProjectFile.create(at: url, name: "Invented")
            _ = try project.addSequence(Sequence(name: "invented", alphabet: .dna, bases: "ACGT"))
            try project.save()
        }
        let app = makeAppDelegateWithTemporaryState()
        let first = MainWindowController()
        let second = MainWindowController()
        for window in [first, second] {
            app.openProject(url, in: window)
            await app.testingWaitForProjectOpen(in: window)
            await window.mainSplitViewController?.externalDocumentLoadTask?.value
        }
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        let generations = [first, second].map { $0.projectSession.documentGeneration }
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        for (index, window) in [first, second].enumerated() {
            XCTAssertTrue(window.projectSession.isReadOnlyRecommended,
                "An unavailable root cannot retain a writable operation destination")
            XCTAssertNil(window.projectSession.project,
                "Direct project writers must not retain the old filesystem handle")
            XCTAssertGreaterThan(window.projectSession.documentGeneration, generations[index])
            let sidebar = try XCTUnwrap(window.mainSplitViewController?.sidebarController)
            XCTAssertTrue(hasVisibleStatus(in: sidebar.view), "The disconnected sidebar must expose a visible recovery status")
            window.close()
        }
    }

    private func hasVisibleStatus(in view: NSView) -> Bool {
        if view.accessibilityIdentifier() == "sidebar-project-unavailable-status", !view.isHidden { return true }
        return view.subviews.contains { hasVisibleStatus(in: $0) }
    }

    func testRetryReopensBothWindowsThroughProjectValidationAndClearsUnavailableState() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryWindows-\(UUID())")
        defer {
            NSApp.delegate = previousDelegate
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let first = MainWindowController()
        let second = MainWindowController()
        for window in [first, second] {
            app.openProject(url, in: window)
            await app.testingWaitForProjectOpen(in: window)
            await window.mainSplitViewController?.externalDocumentLoadTask?.value
        }
        let firstSplit = try XCTUnwrap(first.mainSplitViewController)
        firstSplit.loadProjectDocument(try XCTUnwrap(first.projectSession.documents.last))
        await firstSplit.externalDocumentLoadTask?.value
        let selectedIDs = [first, second].map { $0.mainSplitViewController?.viewerController.currentDocument?.projectSequenceID }
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        let sidebar = try XCTUnwrap(first.mainSplitViewController?.sidebarController)
        let rebound = await sidebar.retryProjectFilesystem()
        XCTAssertTrue(rebound)
        for (index, window) in [first, second].enumerated() {
            await app.testingWaitForProjectOpen(in: window)
            await window.mainSplitViewController?.externalDocumentLoadTask?.value
            XCTAssertFalse(window.projectSession.isFilesystemUnavailable)
            XCTAssertNotNil(window.projectSession.project)
            XCTAssertEqual(window.projectSession.projectURL?.path, url.path)
            let split = try XCTUnwrap(window.mainSplitViewController)
            XCTAssertNil(split.sidebarController.projectFilesystemUnavailableReason)
            XCTAssertEqual(split.viewerController.currentDocument?.projectSequenceID, selectedIDs[index],
                "Each window must retain its selected stored sequence when reconnecting")
            window.projectSession.closeProject()
            window.close()
        }
    }

    func testOldRootLossCannotCancelAnotherProjectAlreadyOpeningInSameWindow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchRecovery-\(UUID())")
        defer { ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: root) }
        let first = try fixture(in: root, name: "first")
        let second = try fixture(in: root, name: "second")
        let app = makeAppDelegateWithTemporaryState()
        let window = MainWindowController()
        app.openProject(first, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        await split.externalDocumentLoadTask?.value
        let prepared = try ProjectSession.prepareProject(at: second, deferCleanup: true)
        let started = expectation(description: "next project suspended")
        let gate = FilesystemProjectPreparationGate(started: started)
        split.projectPreparation = { _ in await gate.wait() }
        app.openProject(second, in: window)
        let open = try XCTUnwrap(split.projectOpenTask)
        await fulfillment(of: [started], timeout: 3)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: first)
        XCTAssertTrue(window.projectSession.isFilesystemUnavailable)
        await gate.finish(.success(prepared))
        await open.value
        await split.externalDocumentLoadTask?.value
        XCTAssertEqual(window.projectSession.projectURL?.path, second.path)
        XCTAssertFalse(window.projectSession.isFilesystemUnavailable)
        let generation = window.projectSession.documentGeneration
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: first)
        XCTAssertEqual(window.projectSession.documentGeneration, generation)
        XCTAssertNil(split.sidebarController.projectFilesystemUnavailableReason)
        window.projectSession.closeProject()
        window.close()
    }

    func testRecoveryRejectsDirectoryReplacementWhileProjectPreparationIsSuspended() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryReplacement-\(UUID())")
        defer {
            NSApp.delegate = previousDelegate
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let window = MainWindowController()
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        await split.externalDocumentLoadTask?.value
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        let prepared = try ProjectSession.prepareProject(at: url, deferCleanup: true)
        let started = expectation(description: "recovery preparation suspended")
        let gate = FilesystemProjectPreparationGate(started: started)
        split.projectPreparation = { _ in await gate.wait() }
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        let rebound = await split.sidebarController.retryProjectFilesystem()
        XCTAssertTrue(rebound)
        let open = try XCTUnwrap(split.projectOpenTask)
        await fulfillment(of: [started], timeout: 3)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("moved.lungfish"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await gate.finish(.success(prepared))
        await open.value
        XCTAssertTrue(window.projectSession.isFilesystemUnavailable)
        XCTAssertNil(window.projectSession.project)
        XCTAssertNotNil(split.sidebarController.projectFilesystemUnavailableReason)
        window.projectSession.closeProject()
        window.close()
    }

    func testRootLossDuringNativeHydrationRecoversPendingSelectedUUIDInsteadOfPreviousViewport() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PendingRecovery-\(UUID())")
        defer { NSApp.delegate = previousDelegate; ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: root) }
        let url = try fixture(in: root, name: "original")
        let window = MainWindowController()
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        await split.externalDocumentLoadTask?.value
        let selected = try XCTUnwrap(window.projectSession.documents.last)
        let selectedID = try XCTUnwrap(selected.projectSequenceID)
        XCTAssertNotEqual(split.viewerController.currentDocument?.projectSequenceID, selectedID)
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        let started = expectation(description: "selected native hydration suspended")
        let gate = FilesystemSelectedHydrationGate(started: started)
        window.projectSession.hydrationLoader = { _, _ in await gate.wait() }
        split.loadProjectDocument(selected)
        let pending = try XCTUnwrap(split.externalDocumentLoadTask)
        await fulfillment(of: [started], timeout: 3)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        window.projectSession.hydrationLoader = nil
        await gate.finish(ProjectHydrationSnapshot(sequence: try Sequence(id: selectedID, name: "other", alphabet: .dna, bases: "TTTT"), annotations: []))
        await pending.value
        _ = await split.sidebarController.retryProjectFilesystem()
        await app.testingWaitForProjectOpen(in: window)
        await split.externalDocumentLoadTask?.value
        XCTAssertEqual(split.viewerController.currentDocument?.projectSequenceID, selectedID)
        XCTAssertEqual(split.viewerController.currentDocument?.sequences.first?.asString(), "TTTT")
        window.projectSession.closeProject()
        window.close()
    }

    private func fixture(in root: URL, name: String) throws -> URL {
        let url = root.appendingPathComponent(name + ".lungfish")
        let project = try ProjectFile.create(at: url, name: name)
        _ = try project.addSequence(Sequence(name: "invented", alphabet: .dna, bases: "ACGT"))
        _ = try project.addSequence(Sequence(name: "other", alphabet: .dna, bases: "TTTT"))
        try project.save()
        return url
    }

    func testClosedWindowReleasesSubscriptionAndCannotReopenFromRetry() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClosedRecovery-\(UUID())")
        defer { NSApp.delegate = previousDelegate; ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: root) }
        let url = try fixture(in: root, name: "original")
        let window = MainWindowController()
        app.testingSetMainWindowControllers([window])
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        await window.mainSplitViewController?.externalDocumentLoadTask?.value
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        let sidebar = try XCTUnwrap(window.mainSplitViewController?.sidebarController)
        _ = app.perform(NSSelectorFromString("windowWillClose:"), with: NSNotification(name: NSWindow.willCloseNotification, object: window.window))
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingSubscriberCount(for: url), 0)
        let retried = await sidebar.retryProjectFilesystem()
        await app.testingWaitForProjectOpen(in: window)
        XCTAssertFalse(retried)
        XCTAssertNil(window.projectSession.project)
        window.close()
    }

    func testLocatedRootRebasesSelectedExternalFileInsideOriginalRoot() async throws {
        try await exerciseExternalRecovery(insideProject: true)
    }

    func testLocatedRootPreservesSelectedExternalFileOutsideOriginalRoot() async throws {
        try await exerciseExternalRecovery(insideProject: false)
    }

    func testLocatedOrdinaryFolderRestoresExternalSelectionThroughSharedSnapshotAuthority() async throws {
        try await exerciseExternalRecovery(insideProject: true, ordinaryFolder: true)
    }

    func testRejectedStartupRestoreFinishesAccountingAndAllowsLaterStateSave() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RejectedRestore-\(UUID())")
        defer {
            for controller in app.testingMainWindowControllers {
                if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet); sheet.orderOut(nil) }
                controller.mainSplitViewController?.sidebarController.closeProject()
                controller.projectSession.closeProject()
                controller.close()
            }
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let original = MainWindowController()
        app.testingSetMainWindowControllers([original])
        app.openProject(url, in: original)
        await app.testingWaitForProjectOpen(in: original)
        await original.mainSplitViewController?.externalDocumentLoadTask?.value
        let snapshot = try XCTUnwrap(original.captureProjectWindowSnapshot(windowOrdinal: 1, windowOrder: 0))
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        try app.projectWindowStateStore.save(ProjectWindowStateEnvelope(windows: []))
        XCTAssertTrue(try app.restoreProjectWindows(from: ProjectWindowStateEnvelope(windows: [snapshot])))
        await app.testingWaitForProjectRestoration()
        app.saveApplicationState()
        XCTAssertFalse(try app.projectWindowStateStore.load().windows.isEmpty,
            "A rejected restore must release its startup accounting so subsequent state saves can run")
    }

    func testOrdinaryOpenIsRejectedUntilOldUnavailableWindowsAreClosed() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UnavailableReopen-\(UUID())")
        defer { ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: root) }
        let url = try fixture(in: root, name: "original")
        let old = MainWindowController()
        app.openProject(url, in: old)
        await app.testingWaitForProjectOpen(in: old)
        await old.mainSplitViewController?.externalDocumentLoadTask?.value
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        let next = MainWindowController()
        app.openProject(url, in: next)
        await app.testingWaitForProjectOpen(in: next)
        XCTAssertNil(next.projectSession.projectURL, "Do not accept a new session into an old unavailable identity")
        XCTAssertEqual(ProjectFilesystemRefreshCoordinator.shared.testingSubscriberCount(for: url), 1)
        XCTAssertNotNil(next.window?.attachedSheet, "Explain that old project windows must close before an ordinary open")
        if let sheet = next.window?.attachedSheet { next.window?.endSheet(sheet); sheet.orderOut(nil) }
        old.mainSplitViewController?.sidebarController.closeProject()
        old.projectSession.closeProject()
        old.close()
        app.openProject(url, in: next)
        await app.testingWaitForProjectOpen(in: next)
        await next.mainSplitViewController?.externalDocumentLoadTask?.value
        XCTAssertNotNil(next.projectSession.project)
        XCTAssertFalse(next.projectSession.isFilesystemUnavailable)
        next.projectSession.closeProject()
        next.close()
    }

    func testDraftCancelKeepsRecoveryBlockedAndSecondRetryCanComplete() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DraftRecovery-\(UUID())")
        defer { NSApp.delegate = previousDelegate; ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: root) }
        let url = try fixture(in: root, name: "original")
        let window = MainWindowController()
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        await split.externalDocumentLoadTask?.value
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        var dirty = true
        var attempts = 0
        window.testingSetManualHaplotypeTransitionState(hasUnsavedDraft: { dirty }, prepare: { _ in
            attempts += 1
            if attempts == 1 { return false }
            dirty = false
            return true
        })
        _ = await split.sidebarController.retryProjectFilesystem()
        await window.testingWaitForFallbackManualHaplotypeTransitions()
        XCTAssertTrue(window.projectSession.isFilesystemUnavailable)
        XCTAssertNil(window.projectSession.project)
        _ = await split.sidebarController.retryProjectFilesystem()
        await window.testingWaitForFallbackManualHaplotypeTransitions()
        await app.testingWaitForProjectOpen(in: window)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(window.projectSession.isFilesystemUnavailable)
        XCTAssertNotNil(window.projectSession.project)
        window.projectSession.closeProject()
        window.close()
    }

    func testFolderScopeRemainsWriteBlockedWhileRecoveryOpenIsSuspended() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolderRecovery-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { NSApp.delegate = previousDelegate; ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: folder) }
        let window = MainWindowController()
        app.testingSetMainWindowControllers([window])
        app.openProject(folder, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        XCTAssertNil(window.projectSession.projectURL)
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: folder)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: folder)
        let started = expectation(description: "folder reopen suspended")
        let gate = FilesystemProjectPreparationGate(started: started)
        split.projectPreparation = { _ in await gate.wait() }
        _ = await split.sidebarController.retryProjectFilesystem()
        let open = try XCTUnwrap(split.projectOpenTask)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(app.isProjectWriteBlocked(projectURL: folder, windowStateScope: window.projectSession.windowStateScope))
        await gate.finish(.failure(ProjectFileError.missingMetadata(url: folder)))
        await open.value
        XCTAssertFalse(window.projectSession.isFilesystemUnavailable)
        XCTAssertFalse(app.isProjectWriteBlocked(projectURL: folder, windowStateScope: window.projectSession.windowStateScope))
        window.close()
    }

    private func exerciseExternalRecovery(insideProject: Bool, ordinaryFolder: Bool = false) async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExternalRecovery-\(UUID())")
        defer { NSApp.delegate = previousDelegate; ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: root) }
        let url: URL
        if ordinaryFolder {
            url = root.appendingPathComponent("original", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            url = try fixture(in: root, name: "original")
        }
        let source = (insideProject ? url : root).appendingPathComponent("external.fa")
        try Data(">invented-external\nGGGG\n".utf8).write(to: source)
        let window = MainWindowController()
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        await split.externalDocumentLoadTask?.value
        split.loadExternalDocument(at: source)
        await split.externalDocumentLoadTask?.value
        await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        let moved = root.appendingPathComponent(ordinaryFolder ? "moved" : "moved.lungfish")
        try FileManager.default.moveItem(at: url, to: moved)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        let rebound = await split.sidebarController.retryProjectFilesystem(at: moved)
        XCTAssertTrue(rebound)
        await app.testingWaitForProjectOpen(in: window)
        await split.externalDocumentLoadTask?.value
        XCTAssertNil(split.viewerController.currentDocument?.projectSequenceID)
        XCTAssertEqual(split.viewerController.currentDocument?.url.path,
            (insideProject ? moved.appendingPathComponent("external.fa") : source).path)
        XCTAssertEqual(split.viewerController.currentDocument?.sequences.first?.asString(), "GGGG")
        window.projectSession.closeProject()
        window.close()
    }
}

private actor FilesystemProjectPreparationGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Result<ProjectSession.PreparedProject, Error>, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async -> Result<ProjectSession.PreparedProject, Error> {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish(_ value: Result<ProjectSession.PreparedProject, Error>) { continuation?.resume(returning: value); continuation = nil }
}

private actor FilesystemSelectedHydrationGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<ProjectHydrationSnapshot, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async -> ProjectHydrationSnapshot {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish(_ snapshot: ProjectHydrationSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}
