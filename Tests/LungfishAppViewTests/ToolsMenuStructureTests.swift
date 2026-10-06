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

    /// The two MHC genotyping workflows are Genotyping. 12S identifies species
    /// from a reference FASTA, so it is Classification (U4).
    func testGenotypingWorkflowsMapToGenotypingAndTwelveSToClassification() {
        XCTAssertEqual(FASTQOperationToolID.ontGenotyping.categoryID, .genotyping)
        XCTAssertEqual(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.categoryID, .genotyping)
        XCTAssertEqual(WorkflowLibraryCatalog.twelveSAmpliconMatchingItem.categoryID, .classification)
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

        XCTAssertEqual(model.categories.map(\.id), FASTQOperationCategoryID.allCases)
        XCTAssertEqual(model.categories.map(\.title), FASTQOperationCategoryID.allCases.map(\.displayName))

        let classification = try XCTUnwrap(model.categories.first { $0.id == .classification })
        XCTAssertEqual(classification.workflows.map(\.title), ["12S Amplicon Matching"])
        XCTAssertEqual(classification.workflows.compactMap(\.toolID), [])
        XCTAssertTrue(classification.workflows.allSatisfy { !$0.isEnabled && $0.isInstallable })

        let genotyping = try XCTUnwrap(model.categories.first { $0.id == .genotyping })
        XCTAssertEqual(genotyping.workflows.map(\.title), ["Full-length ONT MHC genotyping"])
        XCTAssertEqual(genotyping.workflows.compactMap(\.toolID), [])
        XCTAssertTrue(genotyping.workflows.allSatisfy { !$0.isEnabled && $0.isInstallable })
    }

    func testToolsMenuFlattensOperationCategoriesAndInlinesWorkflows() throws {
        try withMainMenu(everyWorkflowEnabled: true) { mainMenu in
            let toolsMenu = try self.toolsMenu(in: mainMenu)

            XCTAssertNil(toolsMenu.items.first { $0.title == "FASTQ/FASTA Operations" })
            XCTAssertNil(toolsMenu.items.first { $0.title == "Workflow Operations\u{2026}" })

            let mappingMenu = try self.categoryMenu(.mapping, in: toolsMenu)
            XCTAssertEqual(mappingMenu.items.map(\.title), [
                "minimap2\u{2026}",
                "BWA-MEM2\u{2026}",
                "Bowtie2\u{2026}",
                "BBMap\u{2026}",
            ])
            XCTAssertEqual(mappingMenu.items.first?.action, #selector(ToolsMenuActions.launchFASTQOperationToolFromMenu(_:)))
            XCTAssertEqual(mappingMenu.items.first?.representedObject as? FASTQOperationToolID, .minimap2)

            let genotypingMenu = try self.categoryMenu(.genotyping, in: toolsMenu)
            XCTAssertNil(genotypingMenu.items.first { $0.title == "Genotyping\u{2026}" })
            let enabled = try XCTUnwrap(genotypingMenu.items.first { $0.title == "\(FASTQOperationToolID.ontGenotyping.title)\u{2026}" })
            XCTAssertEqual(enabled.action, #selector(ToolsMenuActions.launchWorkflowFromMenu(_:)))
            XCTAssertEqual(enabled.representedObject as? FASTQOperationToolID, .ontGenotyping)
            XCTAssertTrue(enabled.isEnabled)
        }

        // 12S lives in Classification now. Not enabled, it offers to enable itself.
        try withMainMenu(everyWorkflowEnabled: false) { mainMenu in
            let classificationMenu = try self.categoryMenu(.classification, in: try self.toolsMenu(in: mainMenu))
            let installable = try XCTUnwrap(classificationMenu.items.first { $0.title == "Enable 12S Amplicon Matching\u{2026}" })
            XCTAssertEqual(installable.action, #selector(ToolsMenuActions.promptEnableWorkflowFromMenu(_:)))
            XCTAssertNil(installable.attributedTitle, "the item reads in normal type, not dimmed")
            XCTAssertEqual(installable.representedObject as? String, WorkflowLibraryCatalog.twelveSAmpliconMatchingID)
            XCTAssertTrue(installable.isEnabled)
        }
    }

    // MARK: - Layout (U1, U5, U8, U9, U11)

    func testLayoutNamesEveryCategoryExactlyOnce() {
        let listed = ToolsMenuLayout.categories
        XCTAssertEqual(listed.count, Set(listed).count, "no category appears twice")
        XCTAssertEqual(Set(listed), Set(FASTQOperationCategoryID.allCases), "every category appears")
        XCTAssertEqual(listed, FASTQOperationCategoryID.allCases, "the enum's case order is the menu order")
    }

    func testToolsMenuHasFourSeparatedGroupsInLayoutOrder() throws {
        try withMainMenu(everyWorkflowEnabled: true) { mainMenu in
            let tools = try self.toolsMenu(in: mainMenu)
            XCTAssertEqual(self.titles(of: tools), [
                // Read preparation
                "QC & Reporting", "Demultiplexing", "Trimming & Filtering", "Decontamination", "Read Processing", "Search & Subsetting",
                "-",
                // Read analysis
                "Mapping", "Variant Calling", "Assembly", "Clustering", "Classification", "Genotyping",
                "-",
                // Sequences and alignments
                "Alignment & Phylogenetics", "PCR Primer Design",
                "-",
                // Workflows and plug-ins
                "Workflows", "Plugin Manager\u{2026}",
            ])
            let plugin = try XCTUnwrap(tools.items.last)
            XCTAssertEqual(plugin.keyEquivalent, "b")
            XCTAssertEqual(plugin.keyEquivalentModifierMask, [.command, .shift])
            XCTAssertEqual(plugin.identifier?.rawValue, MainMenuAccessibilityID.pluginManager)
        }
    }

    func testEveryGeneratedToolAppearsExactlyOnceInItsCategorySubmenu() throws {
        for everyWorkflowEnabled in [true, false] {
            try withMainMenu(everyWorkflowEnabled: everyWorkflowEnabled) { mainMenu in
                let tools = try self.toolsMenu(in: mainMenu)
                let launchAction = #selector(ToolsMenuActions.launchFASTQOperationToolFromMenu(_:))
                var seen: [FASTQOperationToolID] = []
                for category in FASTQOperationCategoryID.allCases {
                    let submenu = try self.categoryMenu(category, in: tools)
                    let expected = FASTQOperationDialogState.toolIDs(for: category).filter {
                        WorkflowLibraryCatalog.item(for: $0)?.capabilities.contains(.workflowOperations) != true
                    }
                    let built = submenu.items.filter { $0.action == launchAction }.compactMap { $0.representedObject as? FASTQOperationToolID }
                    XCTAssertEqual(built, expected, "\(category.rawValue) lists its generated tools in toolIDs(for:) order")
                    seen += built
                }
                XCTAssertEqual(seen.count, Set(seen).count, "no tool is built twice")

                let allGenerated = MenuOutline.allItems(in: tools).filter { $0.action == launchAction }
                XCTAssertEqual(allGenerated.count, seen.count, "no generated tool sits outside its category submenu")

                // Every tool a category lists is in the menu once, as a generated item or, for a
                // catalog workflow such as MiSeq amplicon genotyping, as a workflow item.
                let everyToolItem = MenuOutline.allItems(in: tools).compactMap { $0.representedObject as? FASTQOperationToolID }
                XCTAssertEqual(everyToolItem.count, Set(everyToolItem).count, "no tool appears twice")
                XCTAssertEqual(Set(everyToolItem), Set(FASTQOperationToolID.allCases), "every tool appears")
            }
        }
    }

    func testEveryCatalogWorkflowAppearsInItsCategorySubmenuWhetherEnabledOrNot() throws {
        for everyWorkflowEnabled in [true, false] {
            try withMainMenu(everyWorkflowEnabled: everyWorkflowEnabled) { mainMenu in
                let tools = try self.toolsMenu(in: mainMenu)
                let workflows = WorkflowLibraryCatalog.builtIn.filter { $0.capabilities.contains(.workflowOperations) }
                XCTAssertFalse(workflows.isEmpty)
                for workflow in workflows {
                    let identifier = MainMenuAccessibilityID.toolsWorkflow(workflow.id)
                    let matches = MenuOutline.allItems(in: tools).filter { $0.identifier?.rawValue == identifier }
                    XCTAssertEqual(matches.count, 1, "\(workflow.id) appears exactly once")

                    let submenu = try self.categoryMenu(workflow.categoryID, in: tools)
                    let inCategory = submenu.items.first { $0.identifier?.rawValue == identifier }
                    XCTAssertNotNil(inCategory, "\(workflow.id) sits in \(workflow.categoryID.displayName)")
                    let expectedTitle = everyWorkflowEnabled ? "\(workflow.title)\u{2026}" : "Enable \(workflow.title)\u{2026}"
                    XCTAssertEqual(inCategory?.title, expectedTitle)
                }
            }
        }
    }

    func testSeparatorsAppearOnlyBetweenNonEmptySectionsInEveryMenu() throws {
        for everyWorkflowEnabled in [true, false] {
            try withMainMenu(everyWorkflowEnabled: everyWorkflowEnabled, linkedPackageNamed: "Linked Example") { mainMenu in
                for title in ["Tools", "File", "Selection"] {
                    let menu = try XCTUnwrap(mainMenu.items.first { $0.title == title }?.submenu)
                    XCTAssertEqual(MenuOutline.separatorProblems(in: menu), [], "\(title) menu")
                }
            }
        }
        // An empty section never leaves a separator behind. With no linked package, Workflows holds the library alone.
        try withMainMenu(everyWorkflowEnabled: true) { mainMenu in
            let workflows = try XCTUnwrap(try self.toolsMenu(in: mainMenu).items.first { $0.title == "Workflows" }?.submenu)
            XCTAssertEqual(self.titles(of: workflows), ["Workflow Library\u{2026}"])
        }
    }

    func testCategorySubmenusHoldLeadingCommandsToolsWorkflowsThenTrailingCommands() throws {
        let tool = { (id: FASTQOperationToolID) in "\(id.title)\u{2026}" }
        try withMainMenu(everyWorkflowEnabled: true) { mainMenu in
            let tools = try self.toolsMenu(in: mainMenu)
            // Call Variants… leads, with no separator before Viral Recon.
            XCTAssertEqual(
                self.titles(of: try self.categoryMenu(.variantCalling, in: tools)),
                ["Call Variants\u{2026}", tool(.viralRecon)]
            )
            XCTAssertEqual(
                self.titles(of: try self.categoryMenu(.classification, in: tools)),
                [tool(.kraken2), tool(.esViritu), tool(.taxTriage), "-", "12S Amplicon Matching\u{2026}"]
            )
            XCTAssertEqual(
                self.titles(of: try self.categoryMenu(.genotyping, in: tools)),
                [
                    "\(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.title)\u{2026}",
                    tool(.ontGenotyping),
                    "-",
                    "Haplotype Definitions\u{2026}",
                ]
            )
            XCTAssertEqual(
                self.titles(of: try self.categoryMenu(.alignment, in: tools)),
                [tool(.mafft), "-", "Build Tree with IQ-TREE\u{2026}"]
            )
        }
        try withMainMenu(everyWorkflowEnabled: false) { mainMenu in
            let tools = try self.toolsMenu(in: mainMenu)
            XCTAssertEqual(
                self.titles(of: try self.categoryMenu(.classification, in: tools)),
                [tool(.kraken2), tool(.esViritu), tool(.taxTriage), "-", "Enable 12S Amplicon Matching\u{2026}"]
            )
            XCTAssertEqual(
                self.titles(of: try self.categoryMenu(.genotyping, in: tools)),
                [
                    "Enable \(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.title)\u{2026}",
                    "Enable \(FASTQOperationToolID.ontGenotyping.title)\u{2026}",
                    "-",
                    "Haplotype Definitions\u{2026}",
                ]
            )
        }
    }

    /// The tree item is a fixed trailing command of the alignment entry, and
    /// the layout builds it through the same factory the IQ-TREE session used.
    func testBuildTreeIsTheTrailingCommandOfTheAlignmentEntry() throws {
        try withMainMenu(everyWorkflowEnabled: true) { mainMenu in
            let tools = try self.toolsMenu(in: mainMenu)
            let alignment = try self.categoryMenu(.alignment, in: tools)
            let buildTree = try XCTUnwrap(alignment.items.last)
            XCTAssertEqual(buildTree.identifier?.rawValue, MainMenuAccessibilityID.buildTreeIQTree)
            XCTAssertEqual(buildTree.identifier?.rawValue, "tools-build-tree-iqtree")
            XCTAssertEqual(buildTree.action, #selector(ToolsMenuActions.showIQTreeInference(_:)))
            XCTAssertEqual(buildTree.keyEquivalent, "")
            XCTAssertNil(buildTree.target)
            XCTAssertTrue(alignment.items[alignment.items.count - 2].isSeparatorItem)
            let others = MenuOutline.allMenus(in: tools).filter { $0 !== alignment }
                .flatMap(\.items).filter { $0.action == buildTree.action }
            XCTAssertTrue(others.isEmpty, "the tree item is built once")
        }
    }

    // MARK: - Identifiers (U16)

    func testEveryToolsItemCarriesAUniqueGeneratedIdentifier() throws {
        for everyWorkflowEnabled in [true, false] {
            try withMainMenu(everyWorkflowEnabled: everyWorkflowEnabled, linkedPackageNamed: "Linked Example") { mainMenu in
                let tools = try self.toolsMenu(in: mainMenu)
                let items = MenuOutline.allItems(in: tools).filter { !$0.isSeparatorItem }
                var identifiers: [String] = []
                for item in items {
                    let identifier = item.identifier?.rawValue ?? ""
                    XCTAssertFalse(identifier.isEmpty, "'\(item.title)' needs an identifier")
                    identifiers.append(identifier)
                }
                XCTAssertEqual(identifiers.count, Set(identifiers).count, "identifiers are unique")

                for category in FASTQOperationCategoryID.allCases {
                    let item = try XCTUnwrap(tools.items.first { $0.title == category.displayName })
                    XCTAssertEqual(item.identifier?.rawValue, "tools-menu-category-\(category.rawValue)")
                    XCTAssertEqual(item.identifier?.rawValue, MainMenuAccessibilityID.toolsCategory(category))
                    for generated in item.submenu?.items ?? []
                    where generated.action == #selector(ToolsMenuActions.launchFASTQOperationToolFromMenu(_:)) {
                        let toolID = try XCTUnwrap(generated.representedObject as? FASTQOperationToolID)
                        XCTAssertEqual(generated.identifier?.rawValue, "tools-menu-tool-\(toolID.rawValue)")
                    }
                }
                let pcr = try XCTUnwrap(tools.items.first { $0.title == "PCR Primer Design" })
                XCTAssertEqual(pcr.identifier?.rawValue, MainMenuAccessibilityID.pcrPrimerDesign)
            }
        }
        XCTAssertEqual(MainMenuAccessibilityID.toolsWorkflow("builtin.12s-amplicon-matching"), "tools-menu-workflow-builtin.12s-amplicon-matching")
    }

    // MARK: - Enable items (U6)

    func testNotEnabledWorkflowsSortAfterEnabledOnesThenByTitle() throws {
        _ = NSApplication.shared
        let suiteName = "ToolsMenuSorting-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // A fresh store enables MiSeq amplicon genotyping alone, so Full-length is not enabled.
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let mainMenu = MainMenu.createMainMenu(
            workflowLibraryEnablementStore: store,
            workflowPackageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        )
        let genotyping = try categoryMenu(.genotyping, in: try toolsMenu(in: mainMenu))
        XCTAssertEqual(titles(of: genotyping), [
            "\(FASTQOperationToolID.ontGenotyping.title)\u{2026}",
            "Enable \(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.title)\u{2026}",
            "-",
            "Haplotype Definitions\u{2026}",
        ])
    }

    func testEnablePromptNamesTheWorkflowFromTheCatalogAndNeverFromTheMenuTitle() throws {
        let twelveS = WorkflowLibraryCatalog.twelveSAmpliconMatchingItem
        XCTAssertEqual(ToolsMenuModel.catalogItem(forRepresentedObject: twelveS.id)?.id, twelveS.id)
        XCTAssertEqual(ToolsMenuModel.catalogItem(forRepresentedObject: FASTQOperationToolID.ontGenotyping)?.title, FASTQOperationToolID.ontGenotyping.title)
        XCTAssertNil(ToolsMenuModel.catalogItem(forRepresentedObject: "builtin.no-such-workflow"))
        XCTAssertNil(ToolsMenuModel.catalogItem(forRepresentedObject: nil))

        // The menu item's own title plays no part, whatever it says.
        let alert = try XCTUnwrap(MainMenu.enableWorkflowAlert(for: twelveS.id))
        XCTAssertEqual(alert.messageText, "Enable \u{201C}\(twelveS.title)\u{201D}?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Open Workflow Library", "Cancel"])
        XCTAssertNil(MainMenu.enableWorkflowAlert(for: "builtin.no-such-workflow"))

        try withMainMenu(everyWorkflowEnabled: false) { mainMenu in
            let tools = try self.toolsMenu(in: mainMenu)
            let item = try XCTUnwrap(MenuOutline.allItems(in: tools).first {
                $0.identifier?.rawValue == MainMenuAccessibilityID.toolsWorkflow(twelveS.id)
            })
            item.title = "Not the workflow's name"
            let relabelled = try XCTUnwrap(MainMenu.enableWorkflowAlert(for: item.representedObject))
            XCTAssertEqual(relabelled.messageText, "Enable \u{201C}\(twelveS.title)\u{201D}?")
        }
    }

    // MARK: - Haplotype Definitions (U3)

    /// The item is built whatever is enabled and never hidden. Menu validation
    /// disables it when no enabled workflow uses haplotype definitions.
    func testHaplotypeDefinitionsIsAlwaysBuiltAndMenuValidationDisablesItWithoutHidingIt() throws {
        let noHaplotypes = WorkflowFeatureAvailability(hasWorkflowOperations: false, hasHaplotypeDefinitions: false)
        let withHaplotypes = WorkflowFeatureAvailability(hasWorkflowOperations: true, hasHaplotypeDefinitions: true)
        try withMainMenu(everyWorkflowEnabled: false) { mainMenu in
            let genotyping = try self.categoryMenu(.genotyping, in: try self.toolsMenu(in: mainMenu))
            let item = try XCTUnwrap(genotyping.items.first { $0.title == "Haplotype Definitions\u{2026}" })
            XCTAssertEqual(item.identifier?.rawValue, MainMenuAccessibilityID.haplotypeDefinitions)
            XCTAssertEqual(item.action, #selector(ToolsMenuActions.showHaplotypeDefinitions(_:)))
            XCTAssertEqual(genotyping.items.last, item, "it closes the Genotyping submenu, in a section of its own")
            XCTAssertTrue(genotyping.items[genotyping.items.count - 2].isSeparatorItem)

            self.withApplicationDelegate(availability: noHaplotypes) {
                genotyping.update()
                XCTAssertFalse(item.isHidden, "validation disables the item and never hides it")
                XCTAssertFalse(item.isEnabled)
            }
            self.withApplicationDelegate(availability: withHaplotypes) {
                genotyping.update()
                XCTAssertFalse(item.isHidden)
                XCTAssertTrue(item.isEnabled)
            }
        }
    }

    /// AppKit's own validation path, with the app delegate as the target of
    /// every nil-target Tools item. The delegate's rules were dead before
    /// 2026.10.5 and are live now.
    func testToolsItemsValidateThroughAppKitWithTheAppDelegateAsTarget() throws {
        let noHaplotypes = WorkflowFeatureAvailability(hasWorkflowOperations: true, hasHaplotypeDefinitions: false)
        try withMainMenu(everyWorkflowEnabled: true) { mainMenu in
            let tools = try self.toolsMenu(in: mainMenu)
            self.withApplicationDelegate(availability: noHaplotypes) {
                for menu in MenuOutline.allMenus(in: tools) { menu.update() }
                let all = MenuOutline.allItems(in: tools).filter { !$0.isSeparatorItem }
                var byIdentifier: [String: NSMenuItem] = [:]
                for item in all { if let identifier = item.identifier?.rawValue { byIdentifier[identifier] = item } }
                // There is nothing to act on, with no project, no alignment and no reference bundle.
                XCTAssertEqual(byIdentifier[MainMenuAccessibilityID.callVariants]?.isEnabled, false)
                XCTAssertEqual(byIdentifier[MainMenuAccessibilityID.buildTreeIQTree]?.isEnabled, false)
                XCTAssertEqual(byIdentifier[MainMenuAccessibilityID.haplotypeDefinitions]?.isEnabled, false)
                // Everything else stays enabled.
                let disabled = Set(all.filter { !$0.isEnabled }.compactMap { $0.identifier?.rawValue })
                XCTAssertEqual(disabled, [
                    MainMenuAccessibilityID.callVariants,
                    MainMenuAccessibilityID.buildTreeIQTree,
                    MainMenuAccessibilityID.haplotypeDefinitions,
                ])
            }
        }
    }

    // MARK: - Outlines

    /// The Tools menu as a tree, with every catalog workflow enabled and the
    /// one linked package enabled. Generated items take their titles from the
    /// catalog, so a rename there does not touch this tree.
    func testToolsMenuOutlineWithEveryWorkflowEnabled() throws {
        try withMainMenu(everyWorkflowEnabled: true, linkedPackageNamed: "Linked Example") { mainMenu in
            let outline = MenuOutline.lines(titled: "Tools", in: mainMenu)
            print("TOOLS MENU, EVERY WORKFLOW ENABLED\n" + MenuOutline.text(outline))
            XCTAssertEqual(outline, self.expectedToolsOutline(
                linkedPackageTitle: "Linked Example\u{2026}",
                genotyping: [
                    "\(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.title)\u{2026}",
                    "\(FASTQOperationToolID.ontGenotyping.title)\u{2026}",
                ],
                classificationWorkflow: "\(WorkflowLibraryCatalog.twelveSAmpliconMatchingItem.title)\u{2026}"
            ))
        }
    }

    func testToolsMenuOutlineWithNoWorkflowEnabled() throws {
        try withMainMenu(everyWorkflowEnabled: false, linkedPackageNamed: "Linked Example") { mainMenu in
            let outline = MenuOutline.lines(titled: "Tools", in: mainMenu)
            print("TOOLS MENU, NO WORKFLOW ENABLED\n" + MenuOutline.text(outline))
            XCTAssertEqual(outline, self.expectedToolsOutline(
                linkedPackageTitle: "Enable Linked Example\u{2026}",
                genotyping: [
                    "Enable \(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingItem.title)\u{2026}",
                    "Enable \(FASTQOperationToolID.ontGenotyping.title)\u{2026}",
                ],
                classificationWorkflow: "Enable \(WorkflowLibraryCatalog.twelveSAmpliconMatchingItem.title)\u{2026}"
            ))
        }
    }

    /// File as far as Export. Open Recent holds whatever projects the machine has opened,
    /// so the tree is pinned from Import Center… on.
    func testFileMenuTopPartOutline() throws {
        for everyWorkflowEnabled in [true, false] {
            try withMainMenu(everyWorkflowEnabled: everyWorkflowEnabled) { mainMenu in
                let outline = MenuOutline.lines(titled: "File", in: mainMenu)
                let exportHeader = try XCTUnwrap(outline.firstIndex(of: "  Export \u{25B8}"))
                let state = everyWorkflowEnabled ? "EVERY WORKFLOW ENABLED" : "NO WORKFLOW ENABLED"
                print("FILE MENU (TOP PART), \(state)\n" + MenuOutline.text(Array(outline[...exportHeader])))
                let importCenter = try XCTUnwrap(outline.firstIndex(of: "  Import Center\u{2026}  \u{21E7}\u{2318}I"))
                XCTAssertEqual(Array(outline[importCenter...exportHeader]), [
                    "  Import Center\u{2026}  \u{21E7}\u{2318}I",
                    "  Search Online Databases \u{25B8}",
                    "    Search NCBI\u{2026}",
                    "    Search SRA\u{2026}",
                    "    Search Pathoplexus\u{2026}",
                    "  Export \u{25B8}",
                ])
            }
        }
    }

    func testSelectionMenuOutline() throws {
        for everyWorkflowEnabled in [true, false] {
            try withMainMenu(everyWorkflowEnabled: everyWorkflowEnabled) { mainMenu in
                let outline = MenuOutline.lines(titled: "Selection", in: mainMenu)
                let state = everyWorkflowEnabled ? "EVERY WORKFLOW ENABLED" : "NO WORKFLOW ENABLED"
                print("SELECTION MENU, \(state)\n" + MenuOutline.text(outline))
                let genotypeSample = try XCTUnwrap(outline.firstIndex(of: "  Genotype Sample \u{25B8}"))
                XCTAssertEqual(Array(outline[genotypeSample...]), [
                    "  Genotype Sample \u{25B8}",
                    "    Mark Sample Reviewed  \u{2318}R",
                    "    Mark Sample Confirmed  \u{2318}K",
                    "    Flag Sample for Review  \u{21E7}\u{2318}F",
                    "    Sample Detail\u{2026}  \u{21E7}\u{2318}O",
                    "  Genotype Call \u{25B8}",
                    "    Mark False Positive  \u{2325}\u{2318}P",
                    "    Mark False Negative  \u{2325}\u{2318}X",
                    "    Clear Review  \u{2325}\u{2318}R",
                    "    Edit Comment\u{2026}",
                    "    Remove Comments",
                    "  ---",
                    "  Show in Inspector  \u{2325}\u{2318}S",
                ])
                XCTAssertEqual(
                    outline.filter { $0.hasPrefix("  ") && !$0.hasPrefix("    ") },
                    [
                        "  Sidebar Item \u{25B8}", "  Table Row \u{25B8}", "  Tree Node \u{25B8}",
                        "  Genotype Sample \u{25B8}", "  Genotype Call \u{25B8}", "  ---", "  Show in Inspector  \u{2325}\u{2318}S",
                    ]
                )
            }
        }
    }

    private func expectedToolsOutline(
        linkedPackageTitle: String,
        genotyping: [String],
        classificationWorkflow: String
    ) -> [String] {
        func tool(_ id: FASTQOperationToolID) -> String { "\(id.title)\u{2026}" }
        func submenu(_ name: String, _ children: [String]) -> [String] {
            ["  \(name) \u{25B8}"] + children.map { "    \($0)" }
        }
        let separator = ["  ---"]
        return ["Tools"]
            + submenu("QC & Reporting", [tool(.refreshQCSummary)])
            + submenu("Demultiplexing", [tool(.demultiplexBarcodes), tool(.ontFluidigmSampleSplit)])
            + submenu("Trimming & Filtering", [
                tool(.fastpTrim), tool(.qualityTrim), tool(.adapterRemoval), tool(.primerTrimming),
                tool(.trimFixedBases), tool(.filterByReadLength), tool(.removeLowComplexityReads), tool(.removeDuplicates),
            ])
            + submenu("Decontamination", [tool(.removeHumanReads), tool(.removeRibosomalRNA), tool(.removeContaminants)])
            + submenu("Read Processing", [
                tool(.mergeOverlappingPairs), tool(.repairPairedEndFiles), tool(.reverseComplement),
                tool(.translate), tool(.orientReads), tool(.correctSequencingErrors),
            ])
            + submenu("Search & Subsetting", [
                tool(.subsampleByProportion), tool(.subsampleByCount), tool(.extractReadsByID),
                tool(.extractReadsByMotif), tool(.selectReadsBySequence),
            ])
            + separator
            + submenu("Mapping", [tool(.minimap2), tool(.bwaMem2), tool(.bowtie2), tool(.bbmap)])
            + submenu("Variant Calling", ["Call Variants\u{2026}", tool(.viralRecon)])
            + submenu("Assembly", [tool(.spades), tool(.megahit), tool(.skesa), tool(.flye), tool(.hifiasm)])
            + submenu("Clustering", [tool(.savont), tool(.pbaa)])
            + submenu("Classification", [tool(.kraken2), tool(.esViritu), tool(.taxTriage), "---", classificationWorkflow])
            + submenu("Genotyping", genotyping + ["---", "Haplotype Definitions\u{2026}"])
            + separator
            + submenu("Alignment & Phylogenetics", [tool(.mafft), "---", "Build Tree with IQ-TREE\u{2026}"])
            + submenu("PCR Primer Design", PrimerDesignEngine.allCases.map { "\($0.rawValue)\u{2026}" })
            + separator
            + submenu("Workflows", [linkedPackageTitle, "---", "Workflow Library\u{2026}"])
            + ["  Plugin Manager\u{2026}  \u{21E7}\u{2318}B"]
    }

    // MARK: - Helpers

    private func toolsMenu(in mainMenu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(mainMenu.items.first { $0.title == "Tools" }?.submenu)
    }

    private func categoryMenu(_ category: FASTQOperationCategoryID, in tools: NSMenu) throws -> NSMenu {
        try XCTUnwrap(
            tools.items.first { $0.identifier?.rawValue == MainMenuAccessibilityID.toolsCategory(category) }?.submenu,
            "no \(category.displayName) submenu"
        )
    }

    /// Titles in order, with a separator as "-".
    private func titles(of menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    /// Builds the whole menu bar over a throwaway defaults suite, with every
    /// built-in workflow enabled or none, and optionally one linked package
    /// that is enabled or not along with them.
    private func withMainMenu<Result>(
        everyWorkflowEnabled: Bool,
        linkedPackageNamed packageName: String? = nil,
        _ body: (NSMenu) throws -> Result
    ) throws -> Result {
        _ = NSApplication.shared
        let suiteName = "ToolsMenuLayout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        for item in WorkflowLibraryCatalog.builtIn {
            enablementStore.setWorkflow(item, enabled: everyWorkflowEnabled)
        }
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        if let packageName {
            let package = try makeLinkedPackage(id: "org.test.linked", name: packageName, in: root)
            packageStore.addValidatedPackage(package)
            enablementStore.setUserWorkflow(package, enabled: everyWorkflowEnabled)
        }
        return try body(
            MainMenu.createMainMenu(
                workflowLibraryEnablementStore: enablementStore,
                workflowPackageStore: packageStore
            )
        )
    }

    /// Runs `body` with an app delegate installed as `NSApp.delegate`, the
    /// last stop of the responder chain for a nil-target menu item, and with
    /// the workflow feature availability the validation reads fixed.
    private func withApplicationDelegate(
        availability: WorkflowFeatureAvailability,
        _ body: () throws -> Void
    ) rethrows {
        let delegate = AppDelegate()
        delegate.workflowFeatureAvailabilityProvider = { availability }
        let application = NSApplication.shared
        let previous = application.delegate
        application.delegate = delegate
        defer { application.delegate = previous }
        try withExtendedLifetime(delegate) { try body() }
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
            "Enable Alpha Flow\u{2026}",
            "Enable Command Only\u{2026}",
        ])
        XCTAssertEqual(model.linkedPackages.first?.workflowOperationToolID, "package.org.test.zulu")
    }

    func testWorkflowsSubmenuHoldsOnlyLibraryWhenNothingIsLinked() throws {
        _ = NSApplication.shared
        let item = MainMenu.workflowsMenuItem(for: [])
        XCTAssertEqual(item.title, "Workflows")
        XCTAssertEqual(item.identifier?.rawValue, MainMenuAccessibilityID.workflows)
        let submenu = try XCTUnwrap(item.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Workflow Library\u{2026}"])
        XCTAssertFalse(submenu.items.contains { $0.isSeparatorItem })
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
            "Enable Switched Off\u{2026}",
            "",
            "Workflow Library\u{2026}",
        ])
        XCTAssertTrue(submenu.items[2].isSeparatorItem)

        let enabled = submenu.items[0]
        XCTAssertEqual(enabled.action, #selector(ToolsMenuActions.launchLinkedWorkflowPackageFromMenu(_:)))
        XCTAssertEqual(enabled.representedObject as? String, "org.test.on")
        XCTAssertEqual(enabled.identifier?.rawValue, MainMenuAccessibilityID.workflowPackage("org.test.on"))
        XCTAssertNil(enabled.attributedTitle)

        let disabled = submenu.items[1]
        XCTAssertEqual(disabled.action, #selector(ToolsMenuActions.revealLinkedWorkflowPackageInLibrary(_:)))
        XCTAssertEqual(disabled.representedObject as? String, "org.test.off")
        XCTAssertNil(disabled.attributedTitle, "it reads in normal type, not dimmed")
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
                workflowLibraryEnablementStore: enablementStore,
                workflowPackageStore: packageStore
            )
            let toolsMenu = try XCTUnwrap(mainMenu.items.first { $0.title == "Tools" }?.submenu)
            let workflows = try XCTUnwrap(toolsMenu.items.first { $0.title == "Workflows" }?.submenu)
            return workflows.items.map { $0.isSeparatorItem ? "-" : $0.title }
        }

        XCTAssertEqual(try workflowsTitles(), ["Workflow Library\u{2026}"])

        // Link: the store announces the change and the rebuilt menu lists the package as not enabled.
        let linkExpectation = expectation(forNotification: .workflowLibraryPackagesChanged, object: packageStore)
        packageStore.addValidatedPackage(package)
        wait(for: [linkExpectation], timeout: 1)
        XCTAssertEqual(try workflowsTitles(), ["Enable Hello Linked\u{2026}", "-", "Workflow Library\u{2026}"])

        // Enable: the enablement store posts the notification AppDelegate already rebuilds on.
        let enableExpectation = expectation(forNotification: .workflowLibraryEnablementChanged, object: enablementStore)
        enablementStore.setUserWorkflow(package, enabled: true)
        wait(for: [enableExpectation], timeout: 1)
        XCTAssertEqual(try workflowsTitles(), ["Hello Linked\u{2026}", "-", "Workflow Library\u{2026}"])

        // Disable.
        enablementStore.setUserWorkflow(package, enabled: false)
        XCTAssertEqual(try workflowsTitles(), ["Enable Hello Linked\u{2026}", "-", "Workflow Library\u{2026}"])

        // Unlink.
        let unlinkExpectation = expectation(forNotification: .workflowLibraryPackagesChanged, object: packageStore)
        packageStore.removePackage(withManifestID: package.manifest.id)
        wait(for: [unlinkExpectation], timeout: 1)
        XCTAssertEqual(try workflowsTitles(), ["Workflow Library\u{2026}"])
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
            id: id, name: name, version: "1", category: "Examples",
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
