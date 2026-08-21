import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class ToolsMenuStructureTests: XCTestCase {
    func testGenotypingCategoryExists() {
        XCTAssertTrue(FASTQOperationCategoryID.allCases.contains(.genotyping))
        XCTAssertEqual(FASTQOperationCategoryID.genotyping.title, "GENOTYPING")
    }

    func testGenotypingWorkflowsMapToGenotypingCategory() {
        XCTAssertEqual(FASTQOperationToolID.ontGenotyping.categoryID, .genotyping)
        XCTAssertEqual(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.categoryID, .genotyping)
        XCTAssertEqual(WorkflowLibraryCatalog.twelveSAmpliconMatchingItem.categoryID, .genotyping)
    }

    func testToolsMenuModelGroupsWorkflowsUnderCategoriesWithEnabledFlag() throws {
        let model = ToolsMenuModel.build(
            catalog: [
                WorkflowLibraryItem(toolID: .kraken2, maturity: .core),
                WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem,
                WorkflowLibraryCatalog.twelveSAmpliconMatchingItem,
            ],
            isEnabled: { $0.toolID == .kraken2 }
        )

        let categoryIDs = model.categories.map(\.id)
        XCTAssertTrue(categoryIDs.contains(.classification))
        XCTAssertTrue(categoryIDs.contains(.genotyping))

        let classification = try XCTUnwrap(model.categories.first { $0.id == .classification })
        XCTAssertTrue(classification.workflows.isEmpty)

        let genotyping = try XCTUnwrap(model.categories.first { $0.id == .genotyping })
        XCTAssertEqual(
            genotyping.workflows.map(\.title),
            ["12S Amplicon Matching", "Full-length ONT MHC genotyping"]
        )
        XCTAssertEqual(genotyping.workflows.compactMap(\.toolID), [])
        XCTAssertTrue(genotyping.workflows.allSatisfy { !$0.isEnabled && $0.isInstallable })
    }

    func testToolsMenuFlattensOperationCategoriesAndInlinesWorkflows() throws {
        _ = NSApplication.shared
        let suiteName = "ToolsMenuStructure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let mainMenu = MainMenu.createMainMenu(
            workflowFeatureAvailability: .init(
                hasWorkflowOperations: true,
                hasHaplotypeDefinitions: true
            ),
            workflowLibraryEnablementStore: store
        )
        let toolsMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Tools" }?.submenu)

        XCTAssertNil(toolsMenu.items.first { $0.title == "FASTQ/FASTA Operations" })
        XCTAssertNil(toolsMenu.items.first { $0.title == "Workflow Operations\u{2026}" })

        let mapping = try XCTUnwrap(toolsMenu.items.first { $0.title == "Mapping" })
        let mappingMenu = try XCTUnwrap(mapping.submenu)
        XCTAssertEqual(mappingMenu.items.prefix(5).map(\.title), [
            "minimap2\u{2026}",
            "BWA-MEM2\u{2026}",
            "Bowtie2\u{2026}",
            "BBMap\u{2026}",
            "Viral Recon\u{2026}",
        ])
        XCTAssertEqual(mappingMenu.items.first?.action, #selector(ToolsMenuActions.launchFASTQOperationToolFromMenu(_:)))
        XCTAssertEqual(mappingMenu.items.first?.representedObject as? FASTQOperationToolID, .minimap2)

        let genotyping = try XCTUnwrap(toolsMenu.items.first { $0.title == "Genotyping" })
        let genotypingMenu = try XCTUnwrap(genotyping.submenu)
        XCTAssertNil(genotypingMenu.items.first { $0.title == "Genotyping\u{2026}" })

        let enabled = try XCTUnwrap(genotypingMenu.items.first { $0.title == "\(FASTQOperationToolID.ontGenotyping.title)\u{2026}" })
        XCTAssertEqual(enabled.action, #selector(ToolsMenuActions.launchWorkflowFromMenu(_:)))
        XCTAssertEqual(enabled.representedObject as? FASTQOperationToolID, .ontGenotyping)
        XCTAssertTrue(enabled.isEnabled)

        let installable = try XCTUnwrap(genotypingMenu.items.first { $0.title == "12S Amplicon Matching (not enabled)" })
        XCTAssertEqual(installable.action, #selector(ToolsMenuActions.promptEnableWorkflowFromMenu(_:)))
        XCTAssertNotNil(installable.attributedTitle)
        XCTAssertEqual(installable.representedObject as? String, WorkflowLibraryCatalog.twelveSAmpliconMatchingID)
        XCTAssertTrue(installable.isEnabled)
    }

}
