import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class ProjectHydrationOwnershipTests: XCTestCase {
    func testActualOpenPublishesCatalogThenSelectedContentWhileWindowRemainsAvailable() async throws {
        _ = NSApplication.shared
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeProject(in: root, name: "first")
        let prepared = try ProjectSession.prepareProject(at: url, deferCleanup: true)
        let started = expectation(description: "preparation suspended")
        let gate = ProjectPreparationGate(started: started)
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController()
        let split = try XCTUnwrap(controller.mainSplitViewController)
        split.projectPreparation = { _ in await gate.wait() }
        delegate.openProject(url, in: controller)
        let open = try XCTUnwrap(split.projectOpenTask)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(controller.projectSession.project)
        controller.window?.title = "Window interaction remains available"
        XCTAssertEqual(controller.window?.title, "Window interaction remains available")
        await gate.finish(.success(prepared))
        await open.value
        await split.externalDocumentLoadTask?.value
        XCTAssertEqual(controller.projectSession.documents.count, 3)
        XCTAssertEqual(controller.projectSession.documents.filter { !$0.sequences.isEmpty }.count, 1)
        XCTAssertEqual(split.viewerController.currentDocument?.sequences.first?.asString(), "ACGT")
        XCTAssertEqual(split.inspectorController.activeContentSelectionIdentity?.standardizedURLPath,
            controller.projectSession.activeDocument?.url.path)
        let group = try XCTUnwrap(split.sidebarController.rootItems.first { $0.title == "PROJECT SEQUENCES" })
        XCTAssertEqual(group.children.count, 3)
        split.displayContent(for: group.children[1])
        await split.externalDocumentLoadTask?.value
        XCTAssertEqual(split.viewerController.currentDocument?.name, "invented-1")
        XCTAssertEqual(controller.projectSession.documents.filter { !$0.sequences.isEmpty }.count, 1)
        controller.close()
    }

    func testSuspendedHydrationCannotReplaceNewerSelection() async throws {
        _ = NSApplication.shared
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeProject(in: root, name: "selection")
        let session = ProjectSession()
        _ = try await session.openProjectAsync(at: url)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        let first = session.documents[0]
        let second = session.documents[1]
        let firstStarted = expectation(description: "first hydration suspended")
        let gate = ProjectHydrationGate(started: firstStarted)
        let firstID = try XCTUnwrap(first.projectSequenceID)
        let snapshot = ProjectHydrationSnapshot(sequence: try Sequence(name: "late", alphabet: .dna, bases: "TTTT"), annotations: [])
        session.hydrationLoader = { store, id in
            if id == firstID { return await gate.wait() }
            let value = try store.sequenceSnapshot(id: id)
            return ProjectHydrationSnapshot(sequence: try Sequence(id: id, name: value.name, alphabet: .dna, bases: value.content), annotations: [])
        }
        split.loadProjectDocument(first)
        let firstTask = try XCTUnwrap(split.externalDocumentLoadTask)
        await fulfillment(of: [firstStarted], timeout: 3)
        split.loadProjectDocument(second)
        await split.externalDocumentLoadTask?.value
        await gate.finish(snapshot)
        await firstTask.value
        XCTAssertEqual(split.viewerController.currentDocument?.id, second.id)
        XCTAssertEqual(split.inspectorController.activeContentSelectionIdentity?.standardizedURLPath, second.url.path)
        XCTAssertTrue(first.sequences.isEmpty)
        XCTAssertEqual(session.activeDocument?.id, second.id)
        session.closeProject()
    }

    func testTwoSessionsShareCacheAndBudgetEvictsByContentSize() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeProject(in: root, name: "cache")
        let first = ProjectSession()
        let second = ProjectSession()
        _ = try await first.openProjectAsync(at: url)
        _ = try await second.openProjectAsync(at: url)
        XCTAssertTrue(first.hydrationWorker === second.hydrationWorker)
        _ = try await first.hydrateProjectDocument(first.documents[0])
        _ = try await second.hydrateProjectDocument(second.documents[0])
        let shared = try XCTUnwrap(first.hydrationWorker)
        let sharedStats = await shared.statistics()
        XCTAssertEqual(sharedStats.misses, 1)
        XCTAssertEqual(sharedStats.hits, 1)
        let worker = ProjectHydrationWorker(byteBudget: 8)
        let store = try XCTUnwrap(first.project?.hydrationStore)
        for document in first.documents { _ = try await worker.hydrate(sequenceID: XCTUnwrap(document.projectSequenceID), store: store) }
        let stats = await worker.statistics()
        XCTAssertEqual(stats.cachedSequences, 2)
        XCTAssertEqual(stats.cacheBytes, 8)
        first.closeProject()
        second.closeProject()
    }

    func testNativeCatalogAndSameNamedExternalFileKeepDistinctOrigins() async throws {
        _ = NSApplication.shared
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("collision.lungfish")
        do {
            let project = try ProjectFile.create(at: url, name: "Collision")
            _ = try project.addSequence(Sequence(name: "same.fa", alphabet: .dna, bases: "ACGT"))
            try project.save()
        }
        let file = url.appendingPathComponent("same.fa")
        try Data(">external\nTTTT\n".utf8).write(to: file)
        let session = ProjectSession()
        _ = try await session.openProjectAsync(at: url)
        let catalog = try XCTUnwrap(session.documents.first)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        split.loadExternalDocument(at: file)
        await split.externalDocumentLoadTask?.value
        XCTAssertEqual(session.documents.count, 2)
        XCTAssertNotEqual(split.viewerController.currentDocument?.id, catalog.id)
        XCTAssertNil(split.viewerController.currentDocument?.projectSequenceID)
        XCTAssertTrue(catalog.sequences.isEmpty)
        XCTAssertEqual(split.viewerController.currentDocument?.sequences.first?.asString(), "TTTT")
        session.closeProject()
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Hydration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func makeProject(in root: URL, name: String) throws -> URL {
        let url = root.appendingPathComponent(name + ".lungfish")
        let project = try ProjectFile.create(at: url, name: name)
        for index in 0..<3 { _ = try project.addSequence(Sequence(name: "invented-\(index)", alphabet: .dna, bases: "ACGT")) }
        try project.save()
        return url
    }
}

private actor ProjectPreparationGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Result<ProjectSession.PreparedProject, Error>, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async -> Result<ProjectSession.PreparedProject, Error> {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish(_ value: Result<ProjectSession.PreparedProject, Error>) { continuation?.resume(returning: value); continuation = nil }
}

private actor ProjectHydrationGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<ProjectHydrationSnapshot, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async -> ProjectHydrationSnapshot {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish(_ value: ProjectHydrationSnapshot) { continuation?.resume(returning: value); continuation = nil }
}
