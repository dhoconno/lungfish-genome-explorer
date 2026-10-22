// FASTQImportSheetRecipeSwitchTests.swift - The Import FASTQ sheet's checkboxes for a recipe's switches reach the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

/// CHTC lane C2-SHEET. The merged recipe `illumina-paired-cleanup` has two switches, and its presets
/// `vsp2-target-enrichment` and `wastewater-metagenomics` set them. The sheet lists the presets, shows one checkbox for
/// each switch at the chosen preset's value, and passes the CLI an option only for a checkbox that differs from the
/// preset. These tests drive the sheet as a user does and read what comes out: the argv of the import, the row's
/// command and the Workflow line. None of them reads source text.
final class FASTQImportSheetRecipeSwitchTests: XCTestCase {

    private static let dedup = "Remove duplicate reads"
    private static let ribo = "Remove ribosomal RNA reads"
    private static let vsp2 = "VSP2 target enrichment"
    private static let wastewater = "Wastewater metagenomics"
    private static let arrow = " \u{2192} "

    private let r1 = URL(fileURLWithPath: "/data/sample_R1.fastq.gz")
    private let r2 = URL(fileURLWithPath: "/data/sample_R2.fastq.gz")
    private let project = URL(fileURLWithPath: "/projects/demo.lungfish")

    private func pair() -> FASTQFilePair { FASTQFilePair(r1: r1, r2: r2) }

    private func argv(_ configuration: FASTQImportConfiguration) -> [String] {
        FASTQIngestionService.cliImportArguments(pair: pair(), projectDirectory: project, importConfig: configuration)
    }

    private func isSwitchOption(_ token: String) -> Bool {
        token.hasPrefix("--remove-") || token.hasPrefix("--no-remove-")
    }

    /// `--recipe <name>` and the switch options right after it. Fails when a switch option sits anywhere else.
    private func recipeTokens(in args: [String]) throws -> [String] {
        let start = try XCTUnwrap(args.firstIndex(of: "--recipe"), "\(args)")
        XCTAssertLessThan(start + 1, args.count, "\(args)")
        let following = Array(args.dropFirst(start + 2).prefix(while: { isSwitchOption($0) }))
        XCTAssertEqual(args.filter { isSwitchOption($0) }, following, "A switch option away from --recipe: \(args)")
        return ["--recipe", args[start + 1]] + following
    }

    // MARK: - The picker lists presets

    func testTheMergedRecipeListsItsPresetsAndTheirCheckboxValues() throws {
        let merged = try XCTUnwrap(RecipeRegistryV2.builtinRecipes().first { $0.id == "illumina-paired-cleanup" })
        let options = FASTQImportSheetRecipeOption.options(for: merged)
        XCTAssertEqual(options.map(\.id), ["vsp2-target-enrichment", "wastewater-metagenomics"])
        XCTAssertEqual(options.map(\.name), [Self.vsp2, Self.wastewater])
        func switches(dedup: Bool, ribo: Bool) -> [FASTQImportSheetSwitch] {
            [
                FASTQImportSheetSwitch(id: "removeDuplicates", label: Self.dedup, presetValue: dedup),
                FASTQImportSheetSwitch(id: "removeRibosomalRNA", label: Self.ribo, presetValue: ribo),
            ]
        }
        XCTAssertEqual(options[0].switches, switches(dedup: true, ribo: false))
        XCTAssertEqual(options[1].switches, switches(dedup: true, ribo: true))
        let amplicon = try XCTUnwrap(RecipeRegistryV2.builtinRecipes().first { $0.id == "illumina-amplicon-merge" })
        XCTAssertEqual(FASTQImportSheetRecipeOption.options(for: amplicon).map(\.id), ["illumina-amplicon-merge"])
        XCTAssertTrue(FASTQImportSheetRecipeOption.options(for: amplicon)[0].switches.isEmpty)
    }

    // MARK: - The state of each preset gives its argv

    @MainActor
    func testEachPresetStartsTheCheckboxesAtItsValuesAndPassesNoSwitchOption() throws {
        let presets: [(name: String, id: String, dedup: Bool, ribo: Bool)] = [
            (Self.vsp2, "vsp2-target-enrichment", true, false),
            (Self.wastewater, "wastewater-metagenomics", true, true),
        ]
        for preset in presets {
            let run = SheetRun(r1: r1, r2: r2)
            try run.choose(preset.name)
            XCTAssertEqual(run.state(of: Self.dedup), preset.dedup, preset.name)
            XCTAssertEqual(run.state(of: Self.ribo), preset.ribo, preset.name)
            let configuration = try run.importConfiguration()
            XCTAssertEqual(configuration.recipeName, preset.id)
            let args = argv(configuration)
            XCTAssertEqual(try recipeTokens(in: args), ["--recipe", preset.id], "\(preset.name): \(args)")
            // The row's command is the argv that runs, and the SRA download builds the same recipe arguments.
            XCTAssertEqual(
                FASTQIngestionService.cliImportCommandPreview(pair: pair(), projectDirectory: project, importConfig: configuration),
                CLIImportRunner.commandLine(arguments: args)
            )
            let sra = DatabaseBrowserViewModel.sraImportCLIArguments(
                importConfig: configuration, r1: r1, r2: r2, projectDirectory: project
            )
            XCTAssertEqual(try recipeTokens(in: sra), ["--recipe", preset.id])
        }
    }

    // MARK: - A changed switch adds its option

    @MainActor
    func testChangingASwitchAddsItsOptionAndOnlyIt() throws {
        let cases: [(preset: String, id: String, clicks: [String], options: [String])] = [
            (Self.wastewater, "wastewater-metagenomics", [Self.dedup], ["--no-remove-duplicates"]),
            (Self.wastewater, "wastewater-metagenomics", [Self.ribo], ["--no-remove-ribosomal-rna"]),
            (Self.vsp2, "vsp2-target-enrichment", [Self.ribo], ["--remove-ribosomal-rna"]),
            (Self.vsp2, "vsp2-target-enrichment", [Self.dedup, Self.ribo], ["--no-remove-duplicates", "--remove-ribosomal-rna"]),
            (Self.vsp2, "vsp2-target-enrichment", [Self.ribo, Self.ribo], []),
        ]
        for testCase in cases {
            let run = SheetRun(r1: r1, r2: r2)
            try run.choose(testCase.preset)
            for title in testCase.clicks { try run.clickSwitch(title) }
            let configuration = try run.importConfiguration()
            let args = argv(configuration)
            let expected = ["--recipe", testCase.id] + testCase.options
            let label = "\(testCase.preset) after \(testCase.clicks): \(args)"
            XCTAssertEqual(try recipeTokens(in: args), expected, label)
            let preview = FASTQIngestionService.cliImportCommandPreview(
                pair: pair(), projectDirectory: project, importConfig: configuration
            )
            XCTAssertEqual(preview, CLIImportRunner.commandLine(arguments: args), label)
            let sra = DatabaseBrowserViewModel.sraImportCLIArguments(
                importConfig: configuration, r1: r1, r2: r2, projectDirectory: project
            )
            XCTAssertEqual(try recipeTokens(in: sra), expected, label)
        }
    }

    func testBuildCLIArgumentsPutsTheSwitchOptionsRightAfterTheRecipe() {
        let withRecipe = CLIImportRunner.buildCLIArguments(
            r1: r1, r2: r2, projectDirectory: project, platform: "illumina",
            recipeName: "wastewater-metagenomics",
            recipeSwitchOptions: ["removeRibosomalRNA": false, "removeDuplicates": false],
            qualityBinning: "none", optimizeStorage: false, compressionLevel: "fast"
        )
        XCTAssertEqual(
            Array(withRecipe.suffix(5)),
            ["--recipe", "wastewater-metagenomics", "--no-remove-duplicates", "--no-remove-ribosomal-rna", "--no-optimize-storage"]
        )
        let withoutRecipe = CLIImportRunner.buildCLIArguments(
            r1: r1, r2: r2, projectDirectory: project, platform: "illumina",
            recipeName: nil, recipeSwitchOptions: ["removeDuplicates": false],
            qualityBinning: "none", optimizeStorage: true, compressionLevel: "fast"
        )
        XCTAssertFalse(withoutRecipe.contains("--no-remove-duplicates"), "A switch option needs the recipe it belongs to")
    }

    // MARK: - The checkboxes follow the picker

    @MainActor
    func testTheCheckboxesGoBackToThePresetWhenThePickerChanges() throws {
        let run = SheetRun(r1: r1, r2: r2)
        try run.choose(Self.wastewater)
        try run.clickSwitch(Self.dedup)
        XCTAssertEqual(run.state(of: Self.dedup), false)
        try run.choose(Self.vsp2)
        XCTAssertEqual(run.state(of: Self.dedup), true)
        XCTAssertEqual(run.state(of: Self.ribo), false)
        try run.choose(Self.wastewater)
        XCTAssertEqual(run.state(of: Self.dedup), true)
        XCTAssertEqual(run.state(of: Self.ribo), true)
        let args = argv(try run.importConfiguration())
        XCTAssertEqual(try recipeTokens(in: args), ["--recipe", "wastewater-metagenomics"])
    }

    // MARK: - The Workflow line follows the switches

    @MainActor
    func testTheWorkflowLineFollowsTheSwitches() throws {
        let trim = "Adapter + quality trim"
        let human = "Remove human reads"
        let merge = "Merge overlapping pairs"
        let short = "Remove short reads"
        func line(_ steps: [String]) -> String { "Workflow: " + steps.joined(separator: Self.arrow) }

        let run = SheetRun(r1: r1, r2: r2)
        try run.choose(Self.vsp2)
        XCTAssertEqual(run.workflowLine(), line([Self.dedup, trim, human, merge, short]))
        try run.clickSwitch(Self.ribo)
        XCTAssertEqual(run.workflowLine(), line([Self.dedup, trim, human, Self.ribo, merge, short]))
        try run.clickSwitch(Self.dedup)
        XCTAssertEqual(run.workflowLine(), line([trim, human, Self.ribo, merge, short]))
        try run.clickSwitch(Self.ribo)
        try run.clickSwitch(Self.dedup)
        XCTAssertEqual(run.workflowLine(), line([Self.dedup, trim, human, merge, short]), "Back at the preset's values")

        try run.choose(Self.wastewater)
        XCTAssertEqual(run.workflowLine(), line([Self.dedup, trim, human, Self.ribo, merge, short]))
        try run.clickSwitch(Self.ribo)
        XCTAssertEqual(run.workflowLine(), line([Self.dedup, trim, human, merge, short]))

        // The model gives the same line without the sheet.
        let wastewater = try XCTUnwrap(
            FASTQImportSheetRecipeOption.options(for: try XCTUnwrap(
                RecipeRegistryV2.builtinRecipes().first { $0.id == "illumina-paired-cleanup" }
            )).first { $0.name == Self.wastewater }
        )
        XCTAssertTrue(wastewater.presentationText.contains(Self.ribo))
        let withoutRibo = wastewater.descriptionText(switchValues: ["removeRibosomalRNA": false])
        let withoutRiboLine = try XCTUnwrap(withoutRibo.components(separatedBy: "\n").first { $0.hasPrefix("Workflow: ") })
        XCTAssertEqual(withoutRiboLine, line([Self.dedup, trim, human, merge, short]))
    }

    // MARK: - A recipe without switches

    @MainActor
    func testARecipeWithoutSwitchesLeavesTheSheetUnchanged() throws {
        let recipe = try XCTUnwrap(RecipeRegistryV2.builtinRecipes().first { $0.id == "illumina-amplicon-merge" })
        XCTAssertTrue(recipe.switches.isEmpty)
        let run = SheetRun(r1: r1, r2: r2)
        try run.choose(recipe.name)
        run.sheet.view.layoutSubtreeIfNeeded()
        XCTAssertNil(run.button(titled: Self.dedup))
        XCTAssertNil(run.button(titled: Self.ribo))
        let controls = try XCTUnwrap(run.sheet.view.recipeSwitchTestDescendants(of: FASTQImportSheetSwitchControls.self).first)
        XCTAssertTrue(controls.isHidden)
        XCTAssertEqual(controls.frame.height, 0, "The switch controls take no room")
        let configuration = try run.importConfiguration()
        XCTAssertEqual(configuration.recipeName, recipe.id)
        XCTAssertTrue(configuration.recipeSwitchOptions.isEmpty)
        XCTAssertEqual(try recipeTokens(in: argv(configuration)), ["--recipe", recipe.id])
    }

    // MARK: - The sheet's height

    /// The checkboxes add about 46 points above the Import and Cancel buttons, which hang from the bottom of a sheet of
    /// fixed height while every row hangs from the top. Extra height overlaps without a constraint error, so this reads
    /// the frames after layout, in the states that change the description and the stack.
    @MainActor
    func testTheSwitchesAndTheDescriptionStayClearOfTheButtons() throws {
        let states: [(preset: String, clicks: [String])] = [
            (Self.vsp2, []), (Self.vsp2, [Self.ribo]), (Self.vsp2, [Self.ribo, Self.dedup]),
            (Self.wastewater, []), (Self.wastewater, [Self.ribo]), (Self.wastewater, [Self.ribo, Self.dedup]),
        ]
        for state in states {
            let label = "\(state.preset) after \(state.clicks)"
            let run = SheetRun(r1: r1, r2: r2)
            try run.choose(state.preset)
            for title in state.clicks { try run.clickSwitch(title) }
            let view = run.sheet.view
            view.layoutSubtreeIfNeeded()
            func frame(of subview: NSView) -> NSRect { view.convert(subview.bounds, from: subview) }

            let controls = try XCTUnwrap(view.recipeSwitchTestDescendants(of: FASTQImportSheetSwitchControls.self).first, label)
            let description = try XCTUnwrap(
                view.recipeSwitchTestDescendants(of: NSTextField.self).first {
                    $0.stringValue.components(separatedBy: "\n").contains { $0.hasPrefix("Workflow: ") }
                },
                label
            )
            let importFrame = frame(of: try XCTUnwrap(run.button(titled: "Import"), label))
            let cancelFrame = frame(of: try XCTUnwrap(run.button(titled: "Cancel"), label))
            for (name, control) in [("switches", controls as NSView), ("description", description as NSView)] {
                let box = frame(of: control)
                for (button, buttonFrame) in [("Import", importFrame), ("Cancel", cancelFrame)] {
                    XCTAssertFalse(
                        box.intersects(buttonFrame),
                        "\(label): the \(name) \(box) run into \(button) \(buttonFrame), by \(box.intersection(buttonFrame).height) points"
                    )
                }
                XCTAssertTrue(view.bounds.contains(box), "\(label): the \(name) \(box) leave the sheet \(view.bounds)")
            }
        }
    }

    // MARK: - Accessibility and the keyboard

    @MainActor
    func testEachCheckboxHasALabelAHelpTextAndAKeyboardRoute() throws {
        let run = SheetRun(r1: r1, r2: r2)
        try run.choose(Self.vsp2)
        run.sheet.view.layoutSubtreeIfNeeded()
        let controls = try XCTUnwrap(run.sheet.view.recipeSwitchTestDescendants(of: FASTQImportSheetSwitchControls.self).first)
        XCTAssertFalse(controls.isHidden)
        XCTAssertGreaterThan(controls.frame.height, 30, "Two checkboxes show")
        for (title, option) in [(Self.dedup, "--no-remove-duplicates"), (Self.ribo, "--remove-ribosomal-rna")] {
            let checkbox = try XCTUnwrap(run.button(titled: title), title)
            XCTAssertEqual(checkbox.accessibilityLabel(), title)
            XCTAssertEqual(checkbox.accessibilityHelp()?.contains(option), true, "\(title): \(checkbox.accessibilityHelp() ?? "")")
            XCTAssertEqual(checkbox.toolTip, checkbox.accessibilityHelp())
            XCTAssertFalse(checkbox.isHidden, title)
            XCTAssertTrue(checkbox.isEnabled, title)
            XCTAssertFalse(checkbox.refusesFirstResponder, "\(title) must take keyboard focus")
        }
    }
}

// MARK: - Driving the sheet

/// An Import FASTQ sheet, loaded, with the configuration its Import button hands over.
@MainActor
private final class SheetRun {
    var configuration: FASTQImportConfiguration?
    var sheet: FASTQImportConfigSheet!

    init(r1: URL, r2: URL) {
        sheet = FASTQImportConfigSheet(
            pairs: [FASTQFilePair(r1: r1, r2: r2)],
            detectedPlatform: .illumina,
            onImport: { [unowned self] configuration in self.configuration = configuration }
        )
        sheet.loadViewIfNeeded()
    }

    func button(titled title: String) -> NSButton? {
        sheet.view.recipeSwitchTestDescendants(of: NSButton.self).first { $0.title == title }
    }

    /// Turns the recipe on and picks `itemTitle` in the picker, as a user does.
    func choose(_ itemTitle: String) throws {
        let toggle = try XCTUnwrap(button(titled: "Apply processing recipe after import"))
        if toggle.state == .off { toggle.performClick(nil) }
        let popup = try XCTUnwrap(
            sheet.view.recipeSwitchTestDescendants(of: NSPopUpButton.self).first { $0.itemTitles.contains(itemTitle) },
            "No picker item named \(itemTitle)"
        )
        popup.selectItem(withTitle: itemTitle)
        popup.sendAction(popup.action, to: popup.target)
    }

    func clickSwitch(_ title: String) throws {
        try XCTUnwrap(button(titled: title), "No checkbox titled \(title)").performClick(nil)
    }

    func state(of title: String) -> Bool? {
        button(titled: title).map { $0.state == .on }
    }

    func importConfiguration() throws -> FASTQImportConfiguration {
        try XCTUnwrap(button(titled: "Import")).performClick(nil)
        return try XCTUnwrap(configuration, "Import produced no configuration")
    }

    /// The sheet's Workflow line, as the description under the picker shows it now.
    func workflowLine() -> String? {
        sheet.view.recipeSwitchTestDescendants(of: NSTextField.self)
            .flatMap { $0.stringValue.components(separatedBy: "\n") }
            .first { $0.hasPrefix("Workflow: ") }
    }
}

private extension NSView {
    func recipeSwitchTestDescendants<T: NSView>(of type: T.Type) -> [T] {
        var found: [T] = []
        for subview in subviews {
            if let match = subview as? T { found.append(match) }
            found += subview.recipeSwitchTestDescendants(of: type)
        }
        return found
    }
}
