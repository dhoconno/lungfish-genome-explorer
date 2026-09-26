import AppKit
import LungfishWorkflow
import XCTest
@testable import LungfishApp

@MainActor
final class ToolsMenuStructureTests: XCTestCase {
    func testPrimerDesignSubmenuRoutesDirectlyToEachEngine() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let toolsMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Tools" }?.submenu)
        let item = try XCTUnwrap(toolsMenu.items.first { $0.title == "PCR Primer Design" })
        XCTAssertEqual(item.identifier?.rawValue, "tools-pcr-primer-design")
        XCTAssertNotEqual(item.action, #selector(ToolsMenuActions.showPCRPrimerDesign(_:)))
        let submenu = try XCTUnwrap(item.submenu)
        // One entry per engine, in declaration order, each carrying its engine so the
        // action opens the dialog on that engine directly.
        XCTAssertEqual(submenu.items.map(\.title), PrimerDesignEngine.allCases.map { "\($0.rawValue)…" })
        XCTAssertEqual(submenu.items.map(\.title), ["Primer3…", "PrimalScheme…", "Olivar…", "varVAMP…"])
        XCTAssertEqual(
            submenu.items.compactMap { $0.representedObject as? PrimerDesignEngine },
            [.primer3, .primalScheme, .olivar, .varVAMP]
        )
        XCTAssertTrue(submenu.items.allSatisfy { $0.action == #selector(ToolsMenuActions.showPCRPrimerDesign(_:)) })
    }

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

    // MARK: - Tools > Workflows (linked packages)

    func testToolsMenuModelWithNoLinkedPackagesHasNoPackageEntries() {
        let model = ToolsMenuModel.build(catalog: [], isEnabled: { _ in false })
        XCTAssertTrue(model.linkedPackages.isEmpty)
    }

    func testToolsMenuModelListsEnabledPackagesFirstAndMarksDisabledOnes() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = try makeLinkedPackage(id: "org.test.alpha", name: "Alpha Flow", in: root)
        let zulu = try makeLinkedPackage(id: "org.test.zulu", name: "Zulu Flow", in: root)
        let commandOnly = try makeLinkedPackage(id: "org.test.cmd", name: "Command Only", in: root, runnerKind: .command)

        let model = ToolsMenuModel.build(
            catalog: [],
            isEnabled: { _ in false },
            linkedPackages: [alpha, zulu, commandOnly],
            isPackageEnabled: { $0.manifest.id != "org.test.alpha" }
        )

        XCTAssertEqual(model.linkedPackages.map(\.title), ["Zulu Flow", "Alpha Flow", "Command Only"])
        XCTAssertEqual(model.linkedPackages.map(\.isEnabled), [true, false, false])
        XCTAssertEqual(model.linkedPackages.map(\.menuTitle), [
            "Zulu Flow\u{2026}",
            "Alpha Flow (not enabled)",
            "Command Only (not enabled)",
        ])
        XCTAssertEqual(model.linkedPackages.first?.workflowOperationToolID, "package.org.test.zulu")
    }

    func testWorkflowsSubmenuHoldsOnlyLibraryWhenNothingIsLinked() throws {
        _ = NSApplication.shared
        let item = MainMenu.workflowsMenuItem(for: [])
        XCTAssertEqual(item.title, "Workflows")
        XCTAssertEqual(item.identifier?.rawValue, MainMenuAccessibilityID.workflows)
        let submenu = try XCTUnwrap(item.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Workflow Library\u{2026}", "", "Save Selection as Workflow Template\u{2026}", "Run Workflow Template\u{2026}"])
        // Only the separator before the template commands; no package separator.
        XCTAssertEqual(submenu.items.filter(\.isSeparatorItem).count, 1)
        XCTAssertTrue(submenu.items[1].isSeparatorItem)
        XCTAssertEqual(submenu.items.first?.action, #selector(ToolsMenuActions.showWorkflowLibrary(_:)))
        XCTAssertEqual(submenu.items.first?.identifier?.rawValue, MainMenuAccessibilityID.workflowLibrary)
    }

    func testWorkflowsSubmenuRoutesEnabledPackagesToOperationsAndDisabledOnesToLibrary() throws {
        _ = NSApplication.shared
        let item = MainMenu.workflowsMenuItem(for: [
            ToolsMenuModel.LinkedPackageEntry(manifestID: "org.test.on", title: "Switched On", isEnabled: true),
            ToolsMenuModel.LinkedPackageEntry(manifestID: "org.test.off", title: "Switched Off", isEnabled: false),
        ])
        let submenu = try XCTUnwrap(item.submenu)
        XCTAssertEqual(submenu.items.map(\.title), [
            "Switched On\u{2026}",
            "Switched Off (not enabled)",
            "",
            "Workflow Library\u{2026}",
            "",
            "Save Selection as Workflow Template\u{2026}",
            "Run Workflow Template\u{2026}",
        ])
        XCTAssertTrue(submenu.items[2].isSeparatorItem)
        XCTAssertTrue(submenu.items[4].isSeparatorItem)
        XCTAssertEqual(submenu.items[5].action, #selector(ToolsMenuActions.saveSelectionAsWorkflowTemplate(_:)))
        XCTAssertEqual(submenu.items[5].identifier?.rawValue, MainMenuAccessibilityID.saveWorkflowTemplate)
        XCTAssertEqual(submenu.items[6].action, #selector(ToolsMenuActions.runWorkflowTemplate(_:)))
        XCTAssertEqual(submenu.items[6].identifier?.rawValue, MainMenuAccessibilityID.runWorkflowTemplate)

        let enabled = submenu.items[0]
        XCTAssertEqual(enabled.action, #selector(ToolsMenuActions.launchLinkedWorkflowPackageFromMenu(_:)))
        XCTAssertEqual(enabled.representedObject as? String, "org.test.on")
        XCTAssertEqual(enabled.identifier?.rawValue, MainMenuAccessibilityID.workflowPackage("org.test.on"))
        XCTAssertNil(enabled.attributedTitle)

        let disabled = submenu.items[1]
        XCTAssertEqual(disabled.action, #selector(ToolsMenuActions.revealLinkedWorkflowPackageInLibrary(_:)))
        XCTAssertEqual(disabled.representedObject as? String, "org.test.off")
        XCTAssertNotNil(disabled.attributedTitle)
        XCTAssertTrue(disabled.isEnabled, "the item must stay enabled so its action can open the Library")

        XCTAssertEqual(
            AppDelegate.workflowOperationToolID(forPackageManifestID: "org.test.on"),
            "package.org.test.on"
        )
    }

    func testToolsMenuRebuildsWorkflowsSubmenuWhenPackageIsLinkedEnabledDisabledAndUnlinked() throws {
        _ = NSApplication.shared
        let suiteName = "ToolsMenuWorkflows-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makeLinkedPackage(id: "org.test.hello", name: "Hello Linked", in: root)

        func workflowsTitles() throws -> [String] {
            let mainMenu = MainMenu.createMainMenu(
                workflowFeatureAvailability: .init(hasWorkflowOperations: true, hasHaplotypeDefinitions: false),
                workflowLibraryEnablementStore: enablementStore,
                workflowPackageStore: packageStore
            )
            let toolsMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Tools" }?.submenu)
            let workflows = try XCTUnwrap(toolsMenu.items.first { $0.title == "Workflows" }?.submenu)
            return workflows.items.map { $0.isSeparatorItem ? "-" : $0.title }
        }

        XCTAssertEqual(try workflowsTitles(), ["Workflow Library\u{2026}", "-", "Save Selection as Workflow Template\u{2026}", "Run Workflow Template\u{2026}"])

        // Link: the store announces the change and the rebuilt menu lists the package as not enabled.
        let linkExpectation = expectation(forNotification: .workflowLibraryPackagesChanged, object: packageStore)
        packageStore.addValidatedPackage(package)
        wait(for: [linkExpectation], timeout: 1)
        XCTAssertEqual(try workflowsTitles(), ["Hello Linked (not enabled)", "-", "Workflow Library\u{2026}", "-", "Save Selection as Workflow Template\u{2026}", "Run Workflow Template\u{2026}"])

        // Enable: the enablement store posts the notification AppDelegate already rebuilds on.
        let enableExpectation = expectation(forNotification: .workflowLibraryEnablementChanged, object: enablementStore)
        enablementStore.setUserWorkflow(package, enabled: true)
        wait(for: [enableExpectation], timeout: 1)
        XCTAssertEqual(try workflowsTitles(), ["Hello Linked\u{2026}", "-", "Workflow Library\u{2026}", "-", "Save Selection as Workflow Template\u{2026}", "Run Workflow Template\u{2026}"])

        // Disable.
        enablementStore.setUserWorkflow(package, enabled: false)
        XCTAssertEqual(try workflowsTitles(), ["Hello Linked (not enabled)", "-", "Workflow Library\u{2026}", "-", "Save Selection as Workflow Template\u{2026}", "Run Workflow Template\u{2026}"])

        // Unlink.
        let unlinkExpectation = expectation(forNotification: .workflowLibraryPackagesChanged, object: packageStore)
        packageStore.removePackage(withManifestID: package.manifest.id)
        wait(for: [unlinkExpectation], timeout: 1)
        XCTAssertEqual(try workflowsTitles(), ["Workflow Library\u{2026}", "-", "Save Selection as Workflow Template\u{2026}", "Run Workflow Template\u{2026}"])
    }

    func testWorkflowOperationsSelectsMenuRequestedPackageOnceRefreshListsIt() async throws {
        let suiteName = "ToolsMenuWorkflowsDialog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try makeLinkedPackage(id: "org.test.pending", name: "Pending Flow", in: root)
        // Register the path only, so the store's validation cache is cold, as it is right
        // after launch, and the dialog must wait for the background refresh to list it.
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        packageStore.addPackage(at: package.packageURL)
        enablementStore.setUserWorkflow(package, enabled: true)
        let toolID = AppDelegate.workflowOperationToolID(forPackageManifestID: package.manifest.id)

        let state = WorkflowOperationDialogState(
            projectURL: nil,
            initialToolID: toolID,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        XCTAssertEqual(state.pendingToolID, toolID)
        XCTAssertNotEqual(state.selectedToolID, toolID)

        for _ in 0..<200 where state.selectedToolID != toolID {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(state.selectedToolID, toolID)
        XCTAssertNil(state.pendingToolID)
        XCTAssertEqual(state.selectedTool?.title, "Pending Flow")
    }

    // MARK: - Fixtures

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-menu-workflows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeLinkedPackage(
        id: String,
        name: String,
        in root: URL,
        runnerKind: WorkflowPackageRunnerKind = .nextflow
    ) throws -> WorkflowPackageValidationResult {
        let packageURL = root.appendingPathComponent("\(name).lungfishflowpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let entrypoint = runnerKind == .command ? "run.sh" : "main.nf"
        try "// invented fixture; never executed"
            .write(to: packageURL.appendingPathComponent(entrypoint), atomically: true, encoding: .utf8)
        let manifest = WorkflowPackageManifest(
            id: id, name: name, version: "1", category: "Templates",
            runner: WorkflowPackageRunner(
                kind: runnerKind,
                entrypoint: entrypoint,
                commandTemplate: runnerKind == .command ? ["sh", entrypoint] : nil
            ),
            inputs: [
                WorkflowPackageInput(id: "reference", name: "Reference", bundleTypes: [.lungfishref]),
                WorkflowPackageInput(id: "reads", name: "Reads", bundleTypes: [.lungfishfastq]),
            ],
            outputs: [
                WorkflowPackageOutput(id: "result", name: "Result", bundleType: .lungfishref, pathTemplate: "{outputName}.lungfishref"),
            ]
        )
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        return try WorkflowPackageValidator.validatePackage(at: packageURL)
    }
}
