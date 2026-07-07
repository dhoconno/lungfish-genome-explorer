import XCTest
@testable import LungfishApp

final class ClassificationFolderInputTests: XCTestCase {
    func testFolderInputAdapterUsesWorkflowSidebarSelection() {
        let projectURL = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let direct = projectURL.appendingPathComponent("Runs/A.lungfishfastq", isDirectory: true)
        let nested = projectURL.appendingPathComponent("Runs/Nested/B.lungfishfastq", isDirectory: true)
        let folder = SidebarItem(
            title: "Runs",
            type: .folder,
            children: [
                SidebarItem(title: "A", type: .fastqBundle, url: direct),
                SidebarItem(
                    title: "Nested",
                    type: .folder,
                    children: [
                        SidebarItem(title: "B", type: .fastqBundle, url: nested),
                    ],
                    url: projectURL.appendingPathComponent("Runs/Nested", isDirectory: true)
                ),
            ],
            url: projectURL.appendingPathComponent("Runs", isDirectory: true)
        )

        let input = AppDelegate.classificationFolderInput(items: [folder], projectURL: projectURL)

        XCTAssertEqual(input.directReadURLs, [direct.standardizedFileURL])
        XCTAssertEqual(input.recursiveReadURLs, [direct.standardizedFileURL, nested.standardizedFileURL])
        XCTAssertEqual(input.additionalDescendantCount, 1)
        XCTAssertEqual(input.folderSelectionCount, 1)
        XCTAssertTrue(input.hasSubfolderBundles)
        XCTAssertFalse(input.isEmpty)
    }

    func testChoiceSelectsCorrectURLList() {
        let input = ClassificationFolderInput(
            directReadURLs: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
            recursiveReadURLs: [
                URL(fileURLWithPath: "/a"),
                URL(fileURLWithPath: "/b"),
                URL(fileURLWithPath: "/sub/c"),
            ],
            additionalDescendantCount: 1,
            folderSelectionCount: 1
        )

        XCTAssertEqual(ClassificationFolderPrompt.readURLs(for: .topLevelOnly, from: input)?.count, 2)
        XCTAssertEqual(ClassificationFolderPrompt.readURLs(for: .includeSubfolders, from: input)?.count, 3)
        XCTAssertNil(ClassificationFolderPrompt.readURLs(for: .cancel, from: input))
    }

    func testClassificationDialogSourceRoutesFolderSelectionsThroughPrompt() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("initialCategory == .classification"))
        XCTAssertTrue(source.contains("ClassificationFolderPrompt.present"))
        XCTAssertTrue(source.contains("classificationFolderInput(items:"))
        XCTAssertTrue(source.contains("No FASTQ Samples Found"))
    }
}
