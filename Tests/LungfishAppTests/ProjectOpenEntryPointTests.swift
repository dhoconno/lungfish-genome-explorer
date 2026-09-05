import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

@MainActor
final class ProjectOpenEntryPointTests: XCTestCase {
    func testWelcomeRoutesSelectedURLWithoutOpeningOrReplacingAnotherSession() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WelcomeOpen-\(UUID())")
        defer { DocumentManager.shared.closeActiveProject(); try? FileManager.default.removeItem(at: root) }
        let url = try fixture(in: root)
        let existing = ProjectSession()
        DocumentManager.shared.mirrorProjectSession(existing)
        let generation = existing.documentGeneration
        let welcome = WelcomeWindowController()
        var selected: URL?
        welcome.onProjectSelected = { selected = $0 }
        welcome.openProject(at: url)
        XCTAssertEqual(selected?.path, url.path)
        XCTAssertNil(existing.project, "Welcome must route to the captured async open authority without opening in the last mirrored session")
        XCTAssertNil(existing.projectURL)
        XCTAssertEqual(existing.documentGeneration, generation)
        XCTAssertTrue(existing.documents.isEmpty)
        welcome.close()
    }

    func testLegacyProjectNotificationUsesCatalogAndSelectedHydrationAuthority() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyOpen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try fixture(in: root)
        let session = ProjectSession()
        let project = try session.openProject(at: url)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        split.handleProjectOpened(Notification(name: DocumentManager.projectOpenedNotification, object: nil,
            userInfo: ["sessionID": session.id, "project": project]))
        await split.externalDocumentLoadTask?.value
        XCTAssertEqual(split.viewerController.currentDocument?.sequences.first?.asString(), "ACGT")
        XCTAssertTrue(split.sidebarController.rootItems.contains { $0.title == "PROJECT SEQUENCES" })
        session.closeProject()
    }

    private func fixture(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("invented.lungfish")
        let project = try ProjectFile.create(at: url, name: "Invented")
        _ = try project.addSequence(Sequence(name: "invented", alphabet: .dna, bases: "ACGT"))
        try project.save()
        return url
    }
}
