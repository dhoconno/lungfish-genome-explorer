import XCTest
@testable import LungfishApp
import LungfishCore

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
