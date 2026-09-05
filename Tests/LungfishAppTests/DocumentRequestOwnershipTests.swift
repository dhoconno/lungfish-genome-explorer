import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class DocumentRequestOwnershipTests: XCTestCase {
    override func tearDown() async throws {
        DocumentManager.shared.closeActiveProject()
        try await super.tearDown()
    }

    func testExternalALateFailureCannotChangeBViewportInspectorMembershipOrProgress() async throws {
        _ = NSApplication.shared
        let session = ProjectSession()
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        let loader = SuspendedDocumentReader()
        split.externalDocumentLoader = { try await loader.read($0) }
        let a = URL(fileURLWithPath: "/tmp/invented-A.fa")
        let b = URL(fileURLWithPath: "/tmp/invented-B.fa")
        let startedA = expectation(description: "A read started")
        let startedB = expectation(description: "B read started")
        loader.started[a] = startedA
        loader.started[b] = startedB
        split.loadExternalDocument(at: a)
        let taskA = try XCTUnwrap(split.externalDocumentLoadTask)
        await fulfillment(of: [startedA], timeout: 3)
        split.loadExternalDocument(at: b)
        let taskB = try XCTUnwrap(split.externalDocumentLoadTask)
        await fulfillment(of: [startedB], timeout: 3)
        let progress = try XCTUnwrap(findProgress(in: split.viewerController.view))
        XCTAssertFalse(progress.isHidden)
        loader.fail(a)
        await taskA.value
        XCTAssertFalse(progress.isHidden, "A cleanup must not hide B progress")
        XCTAssertTrue(session.documents.isEmpty)
        XCTAssertNil(split.viewerController.currentDocument)
        let documentB = try inventedDocument(at: b)
        loader.finish(b, document: documentB)
        await taskB.value
        XCTAssertTrue(progress.isHidden)
        XCTAssertEqual(session.documents.map(\.id), [documentB.id])
        XCTAssertEqual(split.viewerController.currentDocument?.id, documentB.id)
        XCTAssertEqual(split.inspectorController.activeContentSelectionIdentity?.standardizedURLPath, b.path)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(split.activeContentSelectionIdentity?.kind, "externalDocument",
            "Registration must not schedule a second sidebar display request")
        XCTAssertEqual(split.viewerController.currentDocument?.id, documentB.id)
    }

    func testExternalOpenHonorsDraftCancelBeforeLoading() async throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        delegate.mainWindowController = controller
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DraftCancel-\(UUID().uuidString).fa")
        try Data(">invented\nACGT\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var prepared = false
        var loads = 0
        controller.testingSetManualHaplotypeTransitionState(hasUnsavedDraft: { true }, prepare: { transition in
            XCTAssertEqual(transition, .bundleSwitch)
            prepared = true
            return false
        })
        controller.mainSplitViewController.externalDocumentLoader = { url in
            loads += 1
            return try self.inventedDocument(at: url)
        }
        XCTAssertTrue(delegate.openDocument(at: url))
        await controller.testingWaitForFallbackManualHaplotypeTransitions()
        await controller.mainSplitViewController.externalDocumentLoadTask?.value
        XCTAssertTrue(prepared)
        XCTAssertEqual(loads, 0)
        XCTAssertTrue(controller.projectSession.documents.isEmpty)
    }

    func testExternalDraftApprovalRetainsCapturedWindowAfterFocusSwitch() async throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let origin = MainWindowController()
        let other = MainWindowController()
        delegate.mainWindowController = origin
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DraftApprove-\(UUID().uuidString).fa")
        try Data(">invented\nACGT\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var dirty = true
        var prepared = false
        origin.testingSetManualHaplotypeTransitionState(hasUnsavedDraft: { dirty }, prepare: { _ in
            prepared = true
            delegate.mainWindowController = other
            dirty = false
            return true
        })
        origin.mainSplitViewController.externalDocumentLoader = { try self.inventedDocument(at: $0) }
        XCTAssertTrue(delegate.openDocument(at: url))
        await origin.testingWaitForFallbackManualHaplotypeTransitions()
        await origin.mainSplitViewController.externalDocumentLoadTask?.value
        XCTAssertTrue(prepared)
        XCTAssertEqual(origin.projectSession.documents.map(\.url), [url])
        XCTAssertTrue(other.projectSession.documents.isEmpty)
        XCTAssertEqual(origin.mainSplitViewController.viewerController.currentDocument?.url, url)
    }

    func testExternalDraftApprovalCannotReopenClosedOriginSession() async throws {
        _ = NSApplication.shared
        let delegate = makeAppDelegateWithTemporaryState()
        let origin = MainWindowController()
        delegate.mainWindowController = origin
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DraftClosed-\(UUID().uuidString).fa")
        try Data(">invented\nACGT\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var dirty = true
        var loads = 0
        origin.testingSetManualHaplotypeTransitionState(hasUnsavedDraft: { dirty }, prepare: { _ in
            origin.projectSession.closeProject()
            dirty = false
            return true
        })
        origin.mainSplitViewController.externalDocumentLoader = { url in
            loads += 1
            return try self.inventedDocument(at: url)
        }
        XCTAssertTrue(delegate.openDocument(at: url))
        await origin.testingWaitForFallbackManualHaplotypeTransitions()
        await origin.mainSplitViewController.externalDocumentLoadTask?.value
        XCTAssertEqual(loads, 0)
        XCTAssertTrue(origin.projectSession.documents.isEmpty)
        XCTAssertNil(origin.mainSplitViewController.viewerController.currentDocument)
    }

    func testSessionCloseSuppressesRegistrationViewportErrorAndProgressCompletion() async throws {
        let session = ProjectSession()
        let loader = SuspendedDocumentReader()
        let url = URL(fileURLWithPath: "/tmp/closed-session.fa")
        let started = expectation(description: "read started")
        loader.started[url] = started
        let probe = PublicationProbe()
        let task = Task { @MainActor in
            await session.loadAndPublishDocument(at: url, loader: { try await loader.read($0) },
                canPublish: { true }, publish: { probe.documents.append($0.id) },
                failure: { _ in probe.errors += 1 }, loading: { probe.loading.append($0) })
        }
        await fulfillment(of: [started], timeout: 3)
        session.closeProject()
        loader.fail(url)
        await task.value
        XCTAssertTrue(session.documents.isEmpty)
        XCTAssertTrue(probe.documents.isEmpty)
        XCTAssertEqual(probe.errors, 0)
        XCTAssertEqual(probe.loading, [true])
    }

    func testFocusSwitchPublishesOnlyToOriginatingSession() async throws {
        let first = ProjectSession()
        let second = ProjectSession()
        DocumentManager.shared.mirrorProjectSession(first)
        let loader = SuspendedDocumentReader()
        let url = URL(fileURLWithPath: "/tmp/first-window.fa")
        let started = expectation(description: "origin read started")
        loader.started[url] = started
        let probe = PublicationProbe()
        let task = Task { @MainActor in
            await first.loadAndPublishDocument(at: url, loader: { try await loader.read($0) },
                canPublish: { true }, publish: { probe.documents.append($0.id) },
                failure: { _ in probe.errors += 1 }, loading: { probe.loading.append($0) })
        }
        await fulfillment(of: [started], timeout: 3)
        DocumentManager.shared.mirrorProjectSession(second)
        let document = try inventedDocument(at: url)
        loader.finish(url, document: document)
        await task.value
        XCTAssertEqual(first.documents.map(\.id), [document.id])
        XCTAssertTrue(second.documents.isEmpty)
        XCTAssertTrue(DocumentManager.shared.documents.isEmpty)
        XCTAssertEqual(probe.documents, [document.id])
        XCTAssertEqual(probe.loading, [true, false])
    }

    func testCurrentFailureOnlyPublishesErrorAndTerminatesItsProgress() async throws {
        let session = ProjectSession()
        let probe = PublicationProbe()
        await session.loadAndPublishDocument(at: URL(fileURLWithPath: "/tmp/failure.fa"),
            loader: { _ in throw CocoaError(.fileReadCorruptFile) }, canPublish: { true },
            publish: { probe.documents.append($0.id) }, failure: { _ in probe.errors += 1 },
            loading: { probe.loading.append($0) })
        XCTAssertTrue(session.documents.isEmpty)
        XCTAssertTrue(probe.documents.isEmpty)
        XCTAssertEqual(probe.errors, 1)
        XCTAssertEqual(probe.loading, [true, false])
    }

    func testScopedDocumentEventAddsOpenDocumentOnlyToItsWindow() throws {
        _ = NSApplication.shared
        let first = MainSplitViewController(projectSession: ProjectSession())
        let second = MainSplitViewController(projectSession: ProjectSession())
        _ = first.view
        _ = second.view
        let document = try inventedDocument(at: URL(fileURLWithPath: "/tmp/scoped-document.fa"))
        first.projectSession.registerDocument(document)
        XCTAssertTrue(first.sidebarController.rootItems.contains { $0.children.contains { $0.url == document.url } })
        XCTAssertFalse(second.sidebarController.rootItems.contains { $0.children.contains { $0.url == document.url } })
    }

    func testReloadAtSameURLPublishesNewPayloadWithStableSessionIdentity() async throws {
        let session = ProjectSession()
        let url = URL(fileURLWithPath: "/tmp/reloaded.fa")
        let original = try inventedDocument(at: url)
        session.registerDocument(original)
        let replacement = LoadedDocument(url: url, type: .fasta)
        replacement.sequences = [try Sequence(name: "revised", alphabet: .dna, bases: "TTTT")]
        var displayed: LoadedDocument?
        await session.loadAndPublishDocument(at: url, loader: { _ in replacement },
            canPublish: { true }, publish: { displayed = $0 }, failure: { _ in XCTFail("Reload failed") }, loading: { _ in })
        XCTAssertEqual(session.documents.count, 1)
        XCTAssertEqual(displayed?.id, original.id)
        XCTAssertEqual(displayed?.sequences.first?.asString(), "TTTT")
        XCTAssertEqual(session.documents.first?.sequences.first?.name, "revised")
    }

    func testBackgroundRegistrationPreservesExistingSidebarSelection() throws {
        _ = NSApplication.shared
        let split = MainSplitViewController(projectSession: ProjectSession())
        _ = split.view
        let first = try inventedDocument(at: URL(fileURLWithPath: "/tmp/selected-first.fa"))
        let second = try inventedDocument(at: URL(fileURLWithPath: "/tmp/background-second.fa"))
        split.projectSession.registerDocument(first)
        XCTAssertEqual(split.sidebarController.selectedItems().map(\.url), [first.url])
        split.projectSession.registerDocument(second, makeActive: false)
        XCTAssertEqual(split.sidebarController.selectedItems().map(\.url), [first.url])
        XCTAssertEqual(split.projectSession.activeDocument?.id, first.id)
    }

    func testContainmentRejectsSiblingPrefixAndResolvesSymlinkTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Containment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("sample.lungfish")
        let sibling = root.appendingPathComponent("sample.lungfish-backup")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let inside = project.appendingPathComponent("invented.fa")
        try Data("ACGT".utf8).write(to: inside)
        let alias = sibling.appendingPathComponent("alias.fa")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: inside)
        XCTAssertTrue(ProjectSession.contains(inside, in: project))
        XCTAssertFalse(ProjectSession.contains(sibling.appendingPathComponent("other.fa"), in: project))
        XCTAssertTrue(ProjectSession.contains(alias, in: project))
    }

    private func inventedDocument(at url: URL) throws -> LoadedDocument {
        let document = LoadedDocument(url: url, type: .fasta)
        document.sequences = [try Sequence(name: "invented", alphabet: .dna, bases: "ACGT")]
        return document
    }

    private func findProgress(in view: NSView) -> ProgressOverlayView? {
        if let progress = view as? ProgressOverlayView { return progress }
        return view.subviews.lazy.compactMap { self.findProgress(in: $0) }.first
    }
}

@MainActor
private final class SuspendedDocumentReader {
    var started: [URL: XCTestExpectation] = [:]
    private var continuations: [URL: CheckedContinuation<LoadedDocument, Error>] = [:]

    func read(_ url: URL) async throws -> LoadedDocument {
        try await withCheckedThrowingContinuation { continuation in
            continuations[url] = continuation
            started[url]?.fulfill()
        }
    }

    func finish(_ url: URL, document: LoadedDocument) {
        continuations.removeValue(forKey: url)?.resume(returning: document)
    }

    func fail(_ url: URL) {
        continuations.removeValue(forKey: url)?.resume(throwing: CocoaError(.fileReadCorruptFile))
    }
}

@MainActor
private final class PublicationProbe {
    var documents: [UUID] = []
    var errors = 0
    var loading: [Bool] = []
}
