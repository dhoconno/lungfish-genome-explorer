import Foundation
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class SequenceExportSourceResolverTests: XCTestCase {
    func testSameURLRowsResolveExactDocumentIDInsteadOfBorrowingVisiblePayload() async throws {
        let session = ProjectSession()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("same-name-\(UUID()).fa")
        let native = try document(at: url, bases: "AAAA")
        native.projectSequenceID = UUID()
        let external = try document(at: url, bases: "CCCC")
        session.registerDocument(native)
        session.registerDocument(external)
        let request = try SequenceExportSourceResolver.capture(items: [row(native)], session: session, currentDocument: external)
        let sources = try await request.resolve()
        XCTAssertEqual(sources.first?.metadata.documentID, native.id)
        XCTAssertEqual(sources.first?.metadata.nativeSequenceID, native.projectSequenceID)
        XCTAssertEqual(sources.first?.document?.sequences.first?.asString(), "AAAA")
    }

    func testLoadedPayloadIsFrozenAtCaptureAndDoesNotReloadChangedDisk() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("external.fa")
        try Data(">disk\nTTTT\n".utf8).write(to: url)
        let selected = try document(at: url, bases: "ACGT")
        let session = ProjectSession()
        session.registerDocument(selected)
        let request = try SequenceExportSourceResolver.capture(items: [row(selected)], session: session)
        selected.sequences = [try Sequence(name: "later", alphabet: .dna, bases: "GGGG")]
        try FileManager.default.removeItem(at: url)
        let sources = try await request.resolve()
        XCTAssertEqual(sources.first?.metadata.kind, .openDocument)
        XCTAssertEqual(sources.first?.document?.sequences.first?.asString(), "ACGT")
    }

    func testFilesystemRowCapturesMatchingExternalVisibleVersionButNeverBorrowsNativePayload() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("visible.fa")
        try Data(">disk\nTTTT\n".utf8).write(to: url)
        let item = SidebarItem(title: "visible", type: .sequence, url: url)
        let session = ProjectSession()
        let external = try document(at: url, bases: "ACGT")
        session.registerDocument(external)
        let captured = try SequenceExportSourceResolver.capture(items: [item], session: session, currentDocument: external)
        external.sequences = [try Sequence(name: "later", alphabet: .dna, bases: "GGGG")]
        try FileManager.default.removeItem(at: url)
        let externalSources = try await captured.resolve()
        XCTAssertEqual(externalSources.first?.document?.sequences.first?.asString(), "ACGT")
        XCTAssertEqual(externalSources.first?.metadata.documentID, external.id)
        let native = try document(at: url, bases: "CCCC")
        native.projectSequenceID = UUID()
        session.registerDocument(native)
        let nativeSources = try await SequenceExportSourceResolver.capture(items: [item], session: session, currentDocument: native).resolve()
        XCTAssertNil(nativeSources.first?.document)
        XCTAssertEqual(nativeSources.first?.metadata.kind, .filesystem)
    }

    func testUnhydratedNativeMultiSelectionAndFilesystemSourceRetainOrderWithoutUIMutation() async throws {
        let root = try temporaryRoot()
        let session = ProjectSession()
        defer { session.closeProject(); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invented.lungfish")
        do {
            let project = try ProjectFile.create(at: url, name: "invented")
            _ = try project.addSequence(Sequence(name: "first", alphabet: .dna, bases: "AAAA"))
            _ = try project.addSequence(Sequence(name: "second", alphabet: .dna, bases: "CCCC"))
            try project.save()
        }
        _ = try await session.openProjectAsync(at: url)
        let first = try XCTUnwrap(session.documents.first)
        let second = try XCTUnwrap(session.documents.last)
        XCTAssertTrue(session.documents.allSatisfy { $0.sequences.isEmpty })
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        let file = root.appendingPathComponent("filesystem.fa")
        let fileRow = SidebarItem(title: "filesystem", type: .sequence, url: file)
        let activeID = session.activeDocument?.id
        let request = try SequenceExportSourceResolver.capture(items: [row(second), fileRow, row(first)], session: session)
        let sources = try await request.resolve()
        XCTAssertEqual(sources.map(\.metadata.kind), [.nativeProjectSequence, .filesystem, .nativeProjectSequence])
        XCTAssertEqual(sources.compactMap { $0.document?.sequences.first?.asString() }, ["CCCC", "AAAA"])
        XCTAssertEqual(sources.map(\.metadata.url), [second.url, file, first.url])
        XCTAssertEqual(session.activeDocument?.id, activeID)
        XCTAssertTrue(session.documents.allSatisfy { $0.sequences.isEmpty }, "Export resolution must not hydrate the observable catalog")
    }

    func testUnknownDocumentIDCannotFallBackToReadableFilesystemPath() async throws {
        let item = SidebarItem(title: "stale", type: .sequence, url: FileManager.default.temporaryDirectory)
        item.userInfo["documentID"] = UUID().uuidString
        do {
            let request = try SequenceExportSourceResolver.capture(items: [item], session: ProjectSession())
            _ = try await request.resolve()
            XCTFail("A stale document row must fail closed instead of reading an unrelated path")
        } catch {}
    }

    func testSessionCloseDiscardsCapturedResolution() async throws {
        let session = ProjectSession()
        let selected = try document(at: FileManager.default.temporaryDirectory.appendingPathComponent("closed.fa"), bases: "ACGT")
        session.registerDocument(selected)
        let request = try SequenceExportSourceResolver.capture(items: [row(selected)], session: session)
        session.closeProject()
        do {
            _ = try await request.resolve()
            XCTFail("Closing the source session must invalidate the pending export destination")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testClosingSessionDuringNativeWorkerDiscardsCompletionWithoutPublishingCatalog() async throws {
        let root = try temporaryRoot()
        let session = ProjectSession()
        defer { session.closeProject(); try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("suspended.lungfish")
        do {
            let project = try ProjectFile.create(at: url, name: "suspended")
            _ = try project.addSequence(Sequence(name: "first", alphabet: .dna, bases: "AAAA"))
            try project.save()
        }
        _ = try await session.openProjectAsync(at: url)
        let selected = try XCTUnwrap(session.documents.first)
        let started = expectation(description: "export worker suspended")
        let gate = ExportSourceHydrationGate(started: started)
        session.hydrationLoader = { _, _ in await gate.wait() }
        let request = try SequenceExportSourceResolver.capture(items: [row(selected)], session: session)
        let task = Task { try await request.resolve() }
        await fulfillment(of: [started], timeout: 3)
        session.closeProject()
        await gate.finish(ProjectHydrationSnapshot(sequence: try Sequence(name: "late", alphabet: .dna, bases: "CCCC"), annotations: []))
        do {
            _ = try await task.value
            XCTFail("The originating session closed while its export worker was running")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(selected.sequences.isEmpty)
        XCTAssertTrue(session.documents.isEmpty)
    }

    func testNativeViewerFallbackFromPreviousProjectCannotBeRelabeledAsCurrentSession() async throws {
        let root = try temporaryRoot()
        let session = ProjectSession()
        defer { session.closeProject(); try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.lungfish")
        let secondURL = root.appendingPathComponent("second.lungfish")
        for (url, bases) in [(firstURL, "AAAA"), (secondURL, "CCCC")] {
            let project = try ProjectFile.create(at: url, name: url.lastPathComponent)
            _ = try project.addSequence(Sequence(name: "invented", alphabet: .dna, bases: bases))
            try project.save()
        }
        _ = try await session.openProjectAsync(at: firstURL)
        let oldViewerDocument = try XCTUnwrap(session.documents.first)
        _ = try await session.hydrateProjectDocument(oldViewerDocument)
        _ = try await session.openProjectAsync(at: secondURL)
        XCTAssertFalse(session.documents.contains { $0 === oldViewerDocument })
        do {
            let request = try SequenceExportSourceResolver.capture(items: [], session: session, currentDocument: oldViewerDocument)
            _ = try await request.resolve()
            XCTFail("A native document retained by the old viewport cannot become a source in the newly accepted project")
        } catch {}
    }

    func testCurrentDocumentFallbackCapturesValuesWithoutRequiringSidebarSelection() async throws {
        let selected = try document(at: FileManager.default.temporaryDirectory.appendingPathComponent("viewer.fa"), bases: "ACGT")
        let request = try SequenceExportSourceResolver.capture(items: [], session: ProjectSession(), currentDocument: selected)
        let sources = try await request.resolve()
        XCTAssertEqual(sources.first?.document?.sequences.first?.asString(), "ACGT")
        XCTAssertEqual(sources.first?.metadata.documentID, selected.id)
    }

    private func row(_ document: LoadedDocument) -> SidebarItem {
        let item = SidebarItem(title: document.name, type: .sequence, url: document.url)
        item.userInfo["documentID"] = document.id.uuidString
        return item
    }

    private func document(at url: URL, bases: String) throws -> LoadedDocument {
        let document = LoadedDocument(url: url, type: .fasta)
        document.sequences = [try Sequence(name: "invented", alphabet: .dna, bases: bases)]
        return document
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExportSourceResolver-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor ExportSourceHydrationGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<ProjectHydrationSnapshot, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async -> ProjectHydrationSnapshot {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish(_ snapshot: ProjectHydrationSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}
