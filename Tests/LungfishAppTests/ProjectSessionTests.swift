import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit

@MainActor
final class ProjectSessionTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        DocumentManager.shared.closeActiveProject()
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    func testLockedSessionCannotSaveOrMutateProject() throws {
        let url = tempRoot.appendingPathComponent("Locked.lungfish")
        _ = try ProjectFile.create(at: url, name: "Locked")
        let lockURL = ProjectLockManager.lockURL(for: url)
        try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt lock".utf8).write(to: lockURL)
        let metadataBefore = try Data(contentsOf: url.appendingPathComponent("metadata.json"))
        let session = ProjectSession()
        let project = try session.openProject(at: url)
        XCTAssertTrue(session.isReadOnlyRecommended)
        project.name = "Must not save"
        XCTAssertThrowsError(try project.save())
        XCTAssertThrowsError(try project.addSequence(Sequence(name: "invented", alphabet: .dna, bases: "ACGT")))
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("metadata.json")), metadataBefore)
        XCTAssertTrue(try project.listSequences().isEmpty)
    }

    func testExplicitReadOnlySessionEnforcesAccessWithoutWriterLock() throws {
        let url = tempRoot.appendingPathComponent("Inspect.lungfish")
        _ = try ProjectFile.create(at: url, name: "Inspect")
        let session = ProjectSession()
        let project = try session.openProject(at: url, access: .readOnly)
        XCTAssertEqual(project.accessMode, .readOnly)
        XCTAssertTrue(session.isReadOnlyRecommended)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectLockManager.lockURL(for: url).path))
        XCTAssertThrowsError(try project.save())
    }

    func testReadOnlyMetadataResolvesReadOnlySession() throws {
        let url = tempRoot.appendingPathComponent("Permissions.lungfish")
        _ = try ProjectFile.create(at: url, name: "Permissions")
        let metadata = url.appendingPathComponent("metadata.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: metadata.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path) }
        let session = ProjectSession()
        let project = try session.openProject(at: url)
        XCTAssertEqual(project.accessMode, .readOnly)
        XCTAssertTrue(session.isReadOnlyRecommended)
        XCTAssertThrowsError(try project.save())
    }

    func testRejectedNativeFilesystemFallbackRetainsReadOnlyRootIdentity() throws {
        let url = tempRoot.appendingPathComponent("Future.lungfish")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let session = ProjectSession()
        session.openReadOnlyFilesystemFallback(at: url)
        XCTAssertEqual(session.projectURL, url.standardizedFileURL)
        XCTAssertEqual(session.workingDirectoryURL, url.standardizedFileURL)
        XCTAssertNil(session.project)
        XCTAssertTrue(session.isReadOnlyRecommended)
        XCTAssertTrue(session.isReadOnlyFilesystemFallback)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        session.closeProject()
        XCTAssertNil(session.projectURL)
        XCTAssertFalse(session.isReadOnlyRecommended)
    }

    func testTwoSessionsCanOpenSameProjectWithIndependentActiveDocument() throws {
        let projectURL = tempRoot.appendingPathComponent("Shared.lungfish", isDirectory: true)
        let project = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")
        let seqA = try Sequence(name: "alpha", alphabet: .dna, bases: "ATCG")
        let seqB = try Sequence(name: "beta", alphabet: .dna, bases: "GGCC")
        _ = try project.addSequence(seqA)
        _ = try project.addSequence(seqB)
        try project.save()

        let first = ProjectSession(windowStateScope: WindowStateScope())
        let second = ProjectSession(windowStateScope: WindowStateScope())

        try first.openProject(at: projectURL)
        try second.openProject(at: projectURL)

        XCTAssertEqual(first.projectURL?.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(second.projectURL?.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(first.documents.count, 2)
        XCTAssertEqual(second.documents.count, 2)

        first.setActiveDocument(first.documents[0])
        second.setActiveDocument(second.documents[1])

        XCTAssertEqual(first.activeDocument?.name, "alpha")
        XCTAssertEqual(second.activeDocument?.name, "beta")
    }
}
