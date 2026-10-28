import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp
import LungfishKit
@testable import LungfishOperations

@MainActor
final class ProjectFilesystemWindowOwnershipTests: XCTestCase {
    /// The termination tests reach the project task path only when no operation is running, since
    /// `applicationShouldTerminate` asks to confirm first otherwise and its sheet waits for a click. A process that
    /// runs every class of the bundle (the full tier) carries a row an earlier test left Running. Fail at once and
    /// name the rows.
    override func setUp() async throws {
        try await super.setUp()
        try OperationCenter.shared.requireNoActiveOperationsForTest()
    }

    func testClosingLastProjectWindowReleasesWriterLock() async throws {
        _ = NSApplication.shared
        DocumentManager.shared.closeActiveProject()
        let app = makeAppDelegateWithTemporaryState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClosedWriter-\(UUID())")
        defer {
            DocumentManager.shared.closeActiveProject()
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let lockURL = ProjectLockManager.lockURL(for: url)
        let window = MainWindowController()
        app.testingSetMainWindowControllers([window])

        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertNotNil(DocumentManager.shared.activeProject)

        _ = app.perform(
            NSSelectorFromString("windowWillClose:"),
            with: NSNotification(name: NSWindow.willCloseNotification, object: window.window)
        )

        let didRemoveLock = await waitForMissingFile(at: lockURL)
        XCTAssertTrue(didRemoveLock,
            "A clean last-window close must remove the writer lease before the project is copied")
        XCTAssertNil(DocumentManager.shared.activeProject)
        window.close()
    }

    func testClosingOneOfTwoProjectWindowsKeepsLeaseUntilLastWindowCloses() async throws {
        _ = NSApplication.shared
        DocumentManager.shared.closeActiveProject()
        let app = makeAppDelegateWithTemporaryState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedWriter-\(UUID())")
        defer {
            DocumentManager.shared.closeActiveProject()
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let lockURL = ProjectLockManager.lockURL(for: url)
        let first = MainWindowController()
        let second = MainWindowController()
        app.testingSetMainWindowControllers([first, second])
        for window in [first, second] {
            app.openProject(url, in: window)
            await app.testingWaitForProjectOpen(in: window)
        }

        _ = app.perform(
            NSSelectorFromString("windowWillClose:"),
            with: NSNotification(name: NSWindow.willCloseNotification, object: second.window)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path),
            "Another live project window must keep the shared writer lease")
        XCTAssertTrue(DocumentManager.shared.activeProject === first.projectSession.project)

        _ = app.perform(
            NSSelectorFromString("windowWillClose:"),
            with: NSNotification(name: NSWindow.willCloseNotification, object: first.window)
        )
        let didRemoveLock = await waitForMissingFile(at: lockURL)
        XCTAssertTrue(didRemoveLock)
        first.close()
        second.close()
    }

    func testApplicationTerminationSynchronouslyReleasesProjectWriterLock() async throws {
        _ = NSApplication.shared
        DocumentManager.shared.closeActiveProject()
        let app = makeAppDelegateWithTemporaryState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminatedWriter-\(UUID())")
        defer {
            DocumentManager.shared.closeActiveProject()
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let lockURL = ProjectLockManager.lockURL(for: url)
        let window = MainWindowController()
        app.testingSetMainWindowControllers([window])
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        await window.mainSplitViewController?.externalDocumentLoadTask?.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))

        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path),
            "Termination must finish lease cleanup before the process can exit")
        window.close()
    }

    func testApplicationTerminationCancelsAndAwaitsHydrationBeforeReleasingWriterLock() async throws {
        _ = NSApplication.shared
        DocumentManager.shared.closeActiveProject()
        let app = makeAppDelegateWithTemporaryState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HydratingWriter-\(UUID())")
        defer {
            DocumentManager.shared.closeActiveProject()
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let lockURL = ProjectLockManager.lockURL(for: url)
        let window = MainWindowController()
        app.testingSetMainWindowControllers([window])
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        await split.externalDocumentLoadTask?.value

        let hydrationStarted = expectation(description: "hydration retains the project store")
        window.projectSession.hydrationLoader = { store, _ in
            hydrationStarted.fulfill()
            try await Task.sleep(for: .seconds(60))
            _ = store.accessMode
            throw CancellationError()
        }
        split.loadProjectDocument(try XCTUnwrap(window.projectSession.documents.last))
        let hydration = try XCTUnwrap(split.externalDocumentLoadTask)
        await fulfillment(of: [hydrationStarted], timeout: 10)

        var replies: [Bool] = []
        let initialReply = app.testingApplicationShouldTerminate { replies.append($0) }
        if initialReply != .terminateLater {
            // Keep the RED case bounded when termination fails to own the task.
            split.invalidateDisplayRequest()
        }
        await hydration.value
        await app.testingWaitForManualHaplotypeTermination()

        XCTAssertEqual(initialReply, .terminateLater)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(app.testingApplicationShouldTerminate { replies.append($0) }, .terminateNow)
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        window.close()
    }

    func testApplicationTerminationAwaitsProjectTaskAfterUIFieldWasCleared() async throws {
        _ = NSApplication.shared
        DocumentManager.shared.closeActiveProject()
        let app = makeAppDelegateWithTemporaryState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RetiredHydration-\(UUID())")
        defer {
            DocumentManager.shared.closeActiveProject()
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let lockURL = ProjectLockManager.lockURL(for: url)
        let window = MainWindowController()
        app.testingSetMainWindowControllers([window])
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        await split.externalDocumentLoadTask?.value

        let hydrationStarted = expectation(description: "retired hydration retains the project store")
        let gate = FilesystemSelectedHydrationGate(started: hydrationStarted)
        window.projectSession.hydrationLoader = { store, _ in
            let value = await gate.wait()
            _ = store.accessMode
            return value
        }
        split.loadProjectDocument(try XCTUnwrap(window.projectSession.documents.last))
        let hydration = try XCTUnwrap(split.externalDocumentLoadTask)
        await fulfillment(of: [hydrationStarted], timeout: 10)
        split.invalidateDisplayRequest()
        XCTAssertNil(split.externalDocumentLoadTask)

        var replies: [Bool] = []
        let initialReply = app.testingApplicationShouldTerminate { replies.append($0) }
        let snapshot = ProjectHydrationSnapshot(
            sequence: try Sequence(name: "released", alphabet: .dna, bases: "ACGT"),
            annotations: []
        )
        await gate.finish(snapshot)
        await hydration.value
        await app.testingWaitForManualHaplotypeTermination()

        XCTAssertEqual(initialReply, .terminateLater)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(app.testingApplicationShouldTerminate { replies.append($0) }, .terminateNow)
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        window.close()
    }

    func testApplicationTerminationAwaitsRetiredMultiDocumentHydration() async throws {
        _ = NSApplication.shared
        DocumentManager.shared.closeActiveProject()
        let app = makeAppDelegateWithTemporaryState()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RetiredMultiHydration-\(UUID())")
        defer {
            DocumentManager.shared.closeActiveProject()
            ProjectFilesystemRefreshCoordinator.shared.unregisterAll()
            try? FileManager.default.removeItem(at: root)
        }
        let url = try fixture(in: root, name: "original")
        let lockURL = ProjectLockManager.lockURL(for: url)
        let window = MainWindowController()
        app.testingSetMainWindowControllers([window])
        app.openProject(url, in: window)
        await app.testingWaitForProjectOpen(in: window)
        let split = try XCTUnwrap(window.mainSplitViewController)
        await split.externalDocumentLoadTask?.value

        let selected = try XCTUnwrap(window.projectSession.documents.last)
        XCTAssertNotNil(selected.projectSequenceID)
        let item = SidebarItem(title: selected.name, type: .sequence)
        item.userInfo["documentID"] = selected.id.uuidString
        let hydrationStarted = expectation(description: "multi-document hydration retains the project store")
        let gate = FilesystemSelectedHydrationGate(started: hydrationStarted)
        window.projectSession.hydrationLoader = { store, _ in
            let value = await gate.wait()
            _ = store.accessMode
            return value
        }
        split.handleMultipleItemsSelected([item])
        let hydration = try XCTUnwrap(split.multiDocumentLoadTask)
        await fulfillment(of: [hydrationStarted], timeout: 10)
        split.cancelMultiDocumentLoadIfNeeded(hideProgress: true, reason: "termination regression")
        XCTAssertNil(split.multiDocumentLoadTask)

        var replies: [Bool] = []
        let initialReply = app.testingApplicationShouldTerminate { replies.append($0) }
        let snapshot = ProjectHydrationSnapshot(
            sequence: try Sequence(name: "released", alphabet: .dna, bases: "ACGT"),
            annotations: []
        )
        await gate.finish(snapshot)
        await hydration.value
        await app.testingWaitForManualHaplotypeTermination()

        XCTAssertEqual(initialReply, .terminateLater)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(app.testingApplicationShouldTerminate { replies.append($0) }, .terminateNow)
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        window.close()
    }

    /// Lock release goes through the file system, so the wait allows for a loaded host.
    private func waitForMissingFile(at url: URL) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while FileManager.default.fileExists(atPath: url.path), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !FileManager.default.fileExists(atPath: url.path)
    }

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
        await fulfillment(of: [started], timeout: 10)
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
        await fulfillment(of: [started], timeout: 10)
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
        await fulfillment(of: [started], timeout: 10)
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

    /// Runs one await of a case under a 30-second bound, so a continuation that
    /// never resumes fails the case with the await's own name instead of
    /// hanging the class (2.11 S60, carry-in R5).
    private func awaitBounded<T: Sendable>(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @MainActor () async -> T
    ) async throws -> T {
        let resumed = XCTestExpectation(description: name)
        let task = Task { @MainActor () -> T in
            let value = await operation()
            resumed.fulfill()
            return value
        }
        guard await XCTWaiter().fulfillment(of: [resumed], timeout: 30) == .completed else {
            // A sheet nobody answers is the usual reason a continuation never resumes.
            // Name it, then end it so the stuck work and its sheet leave with this case.
            let sheets = NSApp.windows.compactMap(\.attachedSheet).map { sheetText(in: $0.contentView) }
            XCTFail("The await \"\(name)\" did not resume within 30 seconds. Open sheets: \(sheets)",
                file: file, line: line)
            for window in NSApp.windows {
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
            }
            task.cancel()
            throw BoundedAwaitTimeout(name: name)
        }
        return await task.value
    }

    private func sheetText(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { sheetText(in: $0) }.filter { !$0.isEmpty }
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

    /// The lock this window wrote moves with the project folder, and its lease
    /// releases only the old path, so Locate met a lock sheet naming this process (2.11 S60).
    func testLocatedNativeProjectReopensWritableWithoutAskingAboutItsOwnLock() async throws {
        _ = NSApplication.shared
        let app = makeAppDelegateWithTemporaryState()
        let previousDelegate = NSApp.delegate
        NSApp.delegate = app
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocatedOwnLock-\(UUID())")
        defer { NSApp.delegate = previousDelegate; ProjectFilesystemRefreshCoordinator.shared.unregisterAll(); try? FileManager.default.removeItem(at: root) }
        let url = try fixture(in: root, name: "original")
        let window = MainWindowController()
        window.window?.setFrameAutosaveName("")
        defer { window.projectSession.closeProject(); window.close() }
        app.openProject(url, in: window)
        try await awaitBounded("project open") { await app.testingWaitForProjectOpen(in: window) }
        try await awaitBounded("root identity read") {
            await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        }
        let moved = root.appendingPathComponent("moved.lungfish")
        try FileManager.default.moveItem(at: url, to: moved)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        let split = try XCTUnwrap(window.mainSplitViewController)
        let rebound = try await awaitBounded("located-root rebind") {
            await split.sidebarController.retryProjectFilesystem(at: moved)
        }
        XCTAssertTrue(rebound)
        try await awaitBounded("recovery project open") { await app.testingWaitForProjectOpen(in: window) }
        XCTAssertNil(window.window?.attachedSheet)
        XCTAssertEqual(window.projectSession.project?.url.resolvingSymlinksInPath().standardizedFileURL.path,
            moved.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertFalse(window.projectSession.isReadOnlyRecommended,
            "The located project is the one this window wrote, so it reopens writable")
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
        await fulfillment(of: [started], timeout: 10)
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
        window.window?.setFrameAutosaveName("")
        defer {
            window.projectSession.closeProject()
            window.close()
        }
        app.openProject(url, in: window)
        try await awaitBounded("first project open") { await app.testingWaitForProjectOpen(in: window) }
        let split = try XCTUnwrap(window.mainSplitViewController)
        try await awaitBounded("first document load") { await split.externalDocumentLoadTask?.value }
        split.loadExternalDocument(at: source)
        try await awaitBounded("external document load") { await split.externalDocumentLoadTask?.value }
        try await awaitBounded("root identity read") {
            await ProjectFilesystemRefreshCoordinator.shared.testingWaitForIdentity(projectURL: url)
        }
        let moved = root.appendingPathComponent(ordinaryFolder ? "moved" : "moved.lungfish")
        try FileManager.default.moveItem(at: url, to: moved)
        ProjectFilesystemRefreshCoordinator.shared.testingSimulateRootChanged(projectURL: url)
        let rebound = try await awaitBounded("located-root rebind") {
            await split.sidebarController.retryProjectFilesystem(at: moved)
        }
        XCTAssertTrue(rebound)
        try await awaitBounded("recovery project open") { await app.testingWaitForProjectOpen(in: window) }
        try await awaitBounded("recovered document load") { await split.externalDocumentLoadTask?.value }
        XCTAssertNil(split.viewerController.currentDocument?.projectSequenceID)
        XCTAssertEqual(split.viewerController.currentDocument?.url.path,
            (insideProject ? moved.appendingPathComponent("external.fa") : source).path)
        XCTAssertEqual(split.viewerController.currentDocument?.sequences.first?.asString(), "GGGG")
    }
}

private struct BoundedAwaitTimeout: Error, CustomStringConvertible {
    let name: String
    var description: String { "The await \"\(name)\" did not resume within 30 seconds" }
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
