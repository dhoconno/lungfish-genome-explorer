import XCTest
@testable import LungfishApp
import LungfishCore

final class ProjectOpenCoordinatorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-open-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testCreateProjectUsesSessionAndRecordsRecentProject() throws {
        var recents: [(url: URL, name: String)] = []
        let coordinator = ProjectOpenCoordinator { url, name in
            recents.append((url, name))
        }
        let session = ProjectSession()
        let projectURL = tempRoot.appendingPathComponent("Created.lungfish", isDirectory: true)

        let project = try coordinator.createProject(at: projectURL, using: session)

        XCTAssertEqual(project.url.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(session.projectURL, projectURL.standardizedFileURL)
        XCTAssertEqual(recents.map(\.url), [projectURL.standardizedFileURL])
        XCTAssertEqual(recents.map(\.name), ["Created"])
    }

    @MainActor
    func testOpenProjectUsesSessionAndRecordsProjectMetadata() throws {
        var recents: [(url: URL, name: String)] = []
        let coordinator = ProjectOpenCoordinator { url, name in
            recents.append((url, name))
        }
        let projectURL = tempRoot.appendingPathComponent("Existing.lungfish", isDirectory: true)
        _ = try ProjectFile.create(at: projectURL, name: "Existing Project")
        let session = ProjectSession()

        let result = coordinator.openProject(at: projectURL, using: session)

        guard case .opened(let project) = result else {
            return XCTFail("Expected project open result")
        }
        XCTAssertEqual(project.name, "Existing Project")
        XCTAssertEqual(session.projectURL, projectURL.standardizedFileURL)
        XCTAssertEqual(recents.map(\.url), [projectURL.standardizedFileURL])
        XCTAssertEqual(recents.map(\.name), ["Existing Project"])
    }

    @MainActor
    func testOpenProjectFallsBackForPlainWorkingDirectoryAndRecordsIt() throws {
        var recents: [(url: URL, name: String)] = []
        let coordinator = ProjectOpenCoordinator { url, name in
            recents.append((url, name))
        }
        let workingDirectory = tempRoot.appendingPathComponent("Scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let session = ProjectSession()

        let result = coordinator.openProject(at: workingDirectory, using: session)

        guard case .filesystemFallback(let fallback) = result else {
            return XCTFail("Expected filesystem fallback result")
        }
        XCTAssertEqual(fallback.url.standardizedFileURL, workingDirectory.standardizedFileURL)
        XCTAssertEqual(fallback.name, "Scratch")
        XCTAssertNil(session.projectURL)
        XCTAssertEqual(recents.map(\.url), [workingDirectory])
        XCTAssertEqual(recents.map(\.name), ["Scratch"])
    }
}
