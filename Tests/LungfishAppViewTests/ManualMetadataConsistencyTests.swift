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

    func testViralReconManualEntryPointMatchesToolsMappingMenu() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Tools" }?.submenu)
        let mappingMenu = try XCTUnwrap(toolsMenu.items.first { $0.title == "Mapping" }?.submenu)
        // Enabled workflows read "Viral Recon…"; disabled ones read
        // "Viral Recon (not enabled)" and prompt for enablement.
        XCTAssertNotNil(
            mappingMenu.items.first { $0.title.hasPrefix("Viral Recon") },
            "Tools > Mapping should list Viral Recon as its own item"
        )

        // The launch procedure lives in the Viral Recon wizard chapter. The
        // consensus chapter only cross-references it.
        let wizard = try readManualFile("chapters/04-alignments/05-viral-recon-wizard.md")
        XCTAssertTrue(wizard.contains("Tools > Mapping > Viral Recon"))
        let consensus = try readManualFile("chapters/05-variants/05-consensus-and-lineage.md")
        XCTAssertTrue(consensus.contains("(../04-alignments/05-viral-recon-wizard.md)"))

        for chapter in [wizard, consensus] {
            XCTAssertFalse(chapter.contains("Tools > FASTQ/FASTA Operations > Viral Recon"))
            XCTAssertFalse(chapter.contains("Tools > FASTQ/FASTA Operations > Mapping"))
            XCTAssertFalse(chapter.contains("Mapping\u{2026} > Viral Recon tool row"))
        }
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
