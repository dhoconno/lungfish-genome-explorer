import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class ManualMetadataConsistencyTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testViralReconManualEntryPointNamesMappingDialog() throws {
        let chapter = try readManualFile("chapters/05-variants/05-consensus-and-lineage.md")
        let mappingPath = "Tools > Mapping > Mapping\u{2026}"

        XCTAssertTrue(chapter.contains("\"\(mappingPath) > Viral Recon tool row\""))
        XCTAssertTrue(chapter.contains("Choose `\(mappingPath)`, then select the `Viral Recon` tool row in the Mapping category."))
        XCTAssertFalse(chapter.contains("Tools > FASTQ/FASTA Operations > Viral Recon"))
        XCTAssertFalse(chapter.contains("Tools > FASTQ/FASTA Operations > Mapping"))
        XCTAssertFalse(chapter.contains("then select `Viral Recon` in the tool sidebar"))
    }

    func testGoToGeneHelpMetadataMatchesMainMenuShortcut() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let sequenceMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Sequence" }?.submenu)
        let goToGene = try XCTUnwrap(sequenceMenu.items.first { $0.title == "Go to Gene\u{2026}" })
        let shortcut = shortcutDescription(for: goToGene)
        XCTAssertEqual(shortcut, "Cmd-Option-G")

        let helpIDs = try readManualFile("help-ids.yaml")
        XCTAssertTrue(helpIDs.contains("description: Sequence > Go to Gene (\(shortcut))"))
        XCTAssertFalse(helpIDs.contains("description: Sequence > Go to Gene (Cmd-Shift-G)"))
    }

    func testSupersededShortcutReviewArtifactCarriesCurrentCorrection() throws {
        let appendicesReview = try readManualFile("reviews/part-ii-fidelity-2026-06-02/round-2/appendices.md")
        XCTAssertTrue(appendicesReview.contains("Superseded shortcut note"))
        XCTAssertTrue(appendicesReview.contains("Current code and active manual text use `Cmd-Shift-G` for Find Previous"))
        XCTAssertTrue(appendicesReview.contains("`Cmd-Option-G` for Sequence > Go to Gene"))
    }

    private func readManualFile(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("docs/user-manual")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func shortcutDescription(for item: NSMenuItem) -> String {
        let modifiers = item.keyEquivalentModifierMask
        var parts: [String] = []
        if modifiers.contains(.command) {
            parts.append("Cmd")
        }
        if modifiers.contains(.shift) {
            parts.append("Shift")
        }
        if modifiers.contains(.option) {
            parts.append("Option")
        }
        if modifiers.contains(.control) {
            parts.append("Control")
        }
        parts.append(item.keyEquivalent.uppercased())
        return parts.joined(separator: "-")
    }
}
