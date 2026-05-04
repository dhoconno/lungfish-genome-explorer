import XCTest
@testable import LungfishApp
import LungfishIO

@MainActor
final class SidebarViewControllerSelectionTests: XCTestCase {
    func testDraggedItemIdentifiersReadsEveryPasteboardItem() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()

        let first = NSPasteboardItem()
        first.setString("/tmp/project/A.lungfishref", forType: sidebarItemPasteboardType)
        let second = NSPasteboardItem()
        second.setString("/tmp/project/B.lungfishref", forType: sidebarItemPasteboardType)
        pasteboard.writeObjects([first, second])

        XCTAssertEqual(
            SidebarViewController.draggedItemIdentifiers(from: pasteboard),
            ["/tmp/project/A.lungfishref", "/tmp/project/B.lungfishref"]
        )
    }

    func testBatchSequenceExportTargetsCreatesOneFilePerBundle() {
        let folder = URL(fileURLWithPath: "/tmp/Exports", isDirectory: true)
        let bundles = [
            URL(fileURLWithPath: "/tmp/project/Alpha.lungfishref", isDirectory: true),
            URL(fileURLWithPath: "/tmp/project/Beta.lungfishref", isDirectory: true),
        ]

        let targets = AppDelegate.batchSequenceExportTargets(
            for: bundles,
            outputFolder: folder,
            format: .genbank,
            compression: .none
        )

        XCTAssertEqual(targets, [
            bundles[0]: folder.appendingPathComponent("Alpha.gb"),
            bundles[1]: folder.appendingPathComponent("Beta.gb"),
        ])
    }

    func testBatchSequenceExportCLICommandsUseConvertForEachBundle() {
        let folder = URL(fileURLWithPath: "/tmp/Exports", isDirectory: true)
        let bundles = [
            URL(fileURLWithPath: "/tmp/project/Alpha.lungfishref", isDirectory: true),
            URL(fileURLWithPath: "/tmp/project/Beta Name.lungfishref", isDirectory: true),
        ]

        let commands = AppDelegate.batchSequenceExportCLICommands(
            for: bundles,
            outputFolder: folder,
            format: .genbank,
            compression: .none
        )

        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[0].contains("lungfish convert"))
        XCTAssertTrue(commands[0].contains("--to-format genbank"))
        XCTAssertTrue(commands[0].contains("--include-annotations"))
        XCTAssertTrue(commands[1].contains("Beta Name.lungfishref"))
        XCTAssertTrue(commands[1].contains("Beta Name.gb"))
    }

    func testBatchSequenceExportCLICommandsOmitUnsupportedCompressionWrapper() {
        let folder = URL(fileURLWithPath: "/tmp/Exports", isDirectory: true)
        let bundles = [
            URL(fileURLWithPath: "/tmp/project/Alpha.lungfishref", isDirectory: true),
        ]

        let commands = AppDelegate.batchSequenceExportCLICommands(
            for: bundles,
            outputFolder: folder,
            format: .genbank,
            compression: .gzip
        )

        XCTAssertTrue(commands.isEmpty)
    }

    func testSuggestedMergedBundleNameUsesFirstSelectedTitle() {
        let items = [
            SidebarItem(
                title: "Sample A",
                type: .fastqBundle,
                url: URL(fileURLWithPath: "/tmp/A.lungfishfastq")
            ),
            SidebarItem(
                title: "Sample B",
                type: .fastqBundle,
                url: URL(fileURLWithPath: "/tmp/B.lungfishfastq")
            ),
        ]

        XCTAssertEqual(
            SidebarViewController.suggestedMergedBundleName(for: items),
            "Sample A merged"
        )
    }

    func testDeepestCommonParentUsesSharedContainingDirectory() {
        let urls = [
            URL(fileURLWithPath: "/tmp/project/Reads/A.lungfishfastq"),
            URL(fileURLWithPath: "/tmp/project/Reads/B.lungfishfastq"),
            URL(fileURLWithPath: "/tmp/project/Reads/C.lungfishfastq"),
        ]

        XCTAssertEqual(
            SidebarViewController.deepestCommonParent(for: urls),
            URL(fileURLWithPath: "/tmp/project/Reads", isDirectory: true)
        )
    }

    func testInternalDropWithNoDestinationTargetsProjectRoot() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)

        XCTAssertEqual(
            SidebarViewController.internalDropDestinationURL(projectURL: projectURL, destinationItem: nil),
            projectURL.standardizedFileURL
        )
    }

    func testSelectItemFindsAnalysisWhenCallerUsesSymlinkedPath() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSelection-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let aliasURL = tempRoot.appendingPathComponent("Fixture-alias.lungfish", isDirectory: false)

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let analysisURL = try AnalysesFolder.createAnalysisDirectory(
            tool: "skesa",
            in: projectURL,
            date: Date(timeIntervalSince1970: 1_715_000_000)
        )
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: projectURL)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        let symlinkedAnalysisURL = aliasURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent(analysisURL.lastPathComponent, isDirectory: true)

        XCTAssertTrue(sidebar.selectItem(forURL: symlinkedAnalysisURL))
        XCTAssertEqual(
            sidebar.selectedFileURL?.resolvingSymlinksInPath(),
            analysisURL.resolvingSymlinksInPath()
        )
    }

    func testSelectItemFindsAnalysisInsideUserGroupingFolder() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarNestedAnalysis-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let analysesDir = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let groupURL = analysesDir.appendingPathComponent("Map NHP genomic FASTA to Zhang pan-genomes", isDirectory: true)
        let analysisURL = groupURL.appendingPathComponent("minimap2-ont-2026-04-24T20-03-58", isDirectory: true)

        try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "minimap2", isBatch: false, created: Date(timeIntervalSince1970: 1_776_000_000)),
            to: analysisURL
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: analysisURL))
        XCTAssertEqual(sidebar.selectedFileURL?.resolvingSymlinksInPath(), analysisURL.resolvingSymlinksInPath())
    }

    func testSelectItemRoutesMAFFTAnalysisBundleAsMultipleSequenceAlignment() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scratch = repositoryRoot
            .appendingPathComponent(".build/test-scratch/SidebarMAFFTAnalysis-\(UUID().uuidString)", isDirectory: true)
        let projectURL = scratch.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let analysisURL = projectURL
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("Multiple Sequence Alignments", isDirectory: true)
            .appendingPathComponent("sars-cov-2-genomes.lungfishmsa", isDirectory: true)

        try FileManager.default.createDirectory(at: analysisURL, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(
            .init(tool: "mafft", isBatch: false, created: Date(timeIntervalSince1970: 1_776_000_000)),
            to: analysisURL
        )

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: scratch)
        }

        sidebar.openProject(at: projectURL)

        XCTAssertTrue(sidebar.selectItem(forURL: analysisURL))
        let item = try XCTUnwrap(sidebar.selectedItems().first)
        XCTAssertEqual(item.type, .multipleSequenceAlignmentBundle)
        XCTAssertEqual(item.title, "sars-cov-2-genomes")
        XCTAssertEqual(sidebar.selectedFileURL?.resolvingSymlinksInPath(), analysisURL.resolvingSymlinksInPath())
    }
}
