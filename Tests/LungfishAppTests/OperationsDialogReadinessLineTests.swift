// OperationsDialogReadinessLineTests.swift - One readiness line in each Operations dialog, and no Overview that repeats a card (5.6 TV-SHELL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.6, lane TV-SHELL. Each of the seven dialogs that use `DatasetOperationsDialog` shows its readiness text once, in the
// footer. The footer's text carries the readiness help tag and, where the dialog names an identifier namespace, the `status-text`
// identifier, so the tests read the footer by either and fail if a pane draws the text again. The Workflow dialog's footer also holds
// the replay line, and Check Configuration sits in the Run Again block. The states are `OperationsDialogFixtures` of
// `OperationsDialogPaneOrderTests`, whose pins hold the order of every pane.

import XCTest
import SwiftUI
import ViewInspector
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class OperationsDialogReadinessLineTests: XCTestCase {
    private typealias Fx = OperationsDialogFixtures

    private var defaults: UserDefaults { makeTestDefaultsSuite(prefix: "OperationsDialogReadinessLineTests").defaults }

    /// The readiness text is drawn once. The one line that carries the readiness help tag is the footer's, and a dialog with an
    /// identifier namespace names that line `status-text`.
    private func assertDrawnOnceInTheFooter(
        _ texts: [InspectableView<ViewType.Text>], _ readinessText: String, hasIdentifier: Bool, _ dialog: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(readinessText.isEmpty, dialog, file: file, line: line)
        XCTAssertEqual(Fx.drawn(readinessText, in: texts), 1, dialog, file: file, line: line)
        let tagged = texts.filter { (try? $0.help().string()) == LungfishHelpContent.operationReadiness.summary }
        XCTAssertEqual(tagged.compactMap { try? $0.string() }, [readinessText], dialog, file: file, line: line)
        XCTAssertEqual(Fx.footerLines(texts), hasIdentifier ? [readinessText] : [], dialog, file: file, line: line)
    }

    func testTheFASTQDialogDrawsItsReadinessTextOnce() throws {
        for tool in [FASTQOperationToolID.qualityTrim, .mafft, .rnaSeqQuant] {
            let state = Fx.fastqState(tool)
            let texts = try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
            assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: false, "FASTQ \(tool.rawValue)")
        }
    }

    func testTheWorkflowDialogDrawsItsReadinessTextOnce() throws {
        let state = try Fx.workflowState(
            selecting: "MiSeq Amplicon MHC Genotyping", defaults: defaults, enabling: { $0.setWorkflow(.ontGenotyping, enabled: true) })
        let texts = try Fx.workflowDialog(state).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: true, "Workflow")
        let pseudobulk = try Fx.workflowState(
            selecting: "Pseudobulk RNA-seq Cells", defaults: defaults,
            enabling: { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqPseudobulkItem, enabled: true) })
        let pseudobulkTexts = try Fx.workflowDialog(pseudobulk).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(pseudobulkTexts, pseudobulk.readinessText, hasIdentifier: true, "Workflow pseudobulk")
    }

    func testThePrimerDesignDialogDrawsItsReadinessTextOnce() throws {
        let state = PrimerDesignDialogState()
        let texts = try PrimerDesignDialog(state: state, onRun: {}, onClose: {}).inspect().findAll(ViewType.Text.self)
        let text = state.errorMessage ?? state.validationMessage ?? state.inputReadinessMessage ?? "Ready. Progress will appear in Operations."
        assertDrawnOnceInTheFooter(texts, text, hasIdentifier: true, "Primer design")
    }

    func testTheBAMVariantCallingDialogDrawsItsReadinessTextOnce() throws {
        for tool in [nil, BAMVariantCallingToolID.ivar] {
            let state = try Fx.bamState(tool: tool)
            let texts = try BAMVariantCallingDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
            assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: false, "BAM variant calling \(tool?.rawValue ?? "default")")
        }
    }

    func testTheORFDialogDrawsItsReadinessTextOnce() throws {
        let state = Fx.orfState()
        let texts = try SequenceORFOperationDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: true, "ORF")
    }

    func testTheDatabaseSearchDialogDrawsItsReadinessTextOnce() throws {
        let state = DatabaseSearchDialogState(initialDestination: .genBankGenomes)
        let texts = try DatabaseSearchDialog(state: state).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(
            texts, DatabaseSearchDialogPresentation(state: state).statusText, hasIdentifier: true, "Database search")
    }

    func testTheIQTreeDialogDrawsItsReadinessTextOnce() throws {
        let state = Fx.iqTreeState()
        state.seedText = "12a"
        let texts = try IQTreeInferenceDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(texts, state.readinessText, hasIdentifier: true, "IQ-TREE")
    }

    // MARK: Workflow, the replay line and Check Configuration

    func testTheWorkflowFooterShowsTheReplayLineWhileARunAgainSubmits() throws {
        let fixture = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state.restoreReplayConfiguration(
            fixture.configuration, sourceBundleURL: fixture.root.appendingPathComponent("original.lungfishrun"))
        let line = "Validating the captured configuration before launch…"

        let before = try Fx.workflowDialog(fixture.state).inspect().findAll(ViewType.Text.self)
        assertDrawnOnceInTheFooter(before, fixture.state.readinessText, hasIdentifier: true, "Run Again before submit")
        XCTAssertEqual(Fx.drawn(line, in: before), 0)

        fixture.state.isSubmittingReplay = true
        let submitting = try Fx.workflowDialog(fixture.state).inspect().findAll(ViewType.Text.self)
        XCTAssertEqual(Fx.drawn(line, in: submitting), 1)
        XCTAssertEqual(Fx.footerLines(submitting), [line])
        XCTAssertEqual(Fx.drawn(fixture.state.readinessText, in: submitting), 0)
    }

    func testCheckConfigurationSitsInTheRunAgainBlockAndNoSectionIsNamedReadiness() throws {
        let fixture = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state.restoreReplayConfiguration(
            fixture.configuration, sourceBundleURL: fixture.root.appendingPathComponent("original.lungfishrun"))
        let detail = try Fx.workflowDetailTexts(fixture.state, paths: fixture.paths)
        let runAgain = try XCTUnwrap(detail.firstIndex { $0.hasPrefix("Run Again: ") })
        let check = try XCTUnwrap(detail.firstIndex(of: "Check Configuration"))
        let inputs = try XCTUnwrap(detail.firstIndex(of: "Inputs"))
        XCTAssertLessThan(runAgain, check)
        XCTAssertLessThan(check, inputs)
        XCTAssertEqual(detail.filter { $0 == "Check Configuration" }.count, 1)
        XCTAssertEqual(detail.filter { $0 == "Readiness" }.count, 0)
        _ = try Fx.workflowDialog(fixture.state).inspect().find(viewWithAccessibilityIdentifier: "workflow-operations-check-repeat")
    }

    // MARK: No Overview that repeats the card

    func testTheWorkflowOverviewShowsOnlyWhatItHolds() throws {
        let pseudobulk = try Fx.workflowState(
            selecting: "Pseudobulk RNA-seq Cells", defaults: defaults,
            enabling: { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqPseudobulkItem, enabled: true) })
        let pseudobulkTexts = try Fx.workflowDetailTexts(pseudobulk)
        XCTAssertEqual(pseudobulkTexts.first, "Inputs", "no Previous Run button and no replay, so no Overview")
        XCTAssertEqual(pseudobulkTexts.filter { $0 == "Overview" }.count, 0)

        let ont = try Fx.workflowState(
            selecting: "MiSeq Amplicon MHC Genotyping", defaults: defaults, enabling: { $0.setWorkflow(.ontGenotyping, enabled: true) })
        let ontTexts = try Fx.workflowDetailTexts(ont)
        XCTAssertEqual(Array(ontTexts.prefix(3)), ["Overview", "Open Previous Run…", "Inputs"], "the summary is the card's")
    }

    func testTheFASTQPanesNoLongerOpenWithAnOverview() throws {
        for tool in [FASTQOperationToolID.qualityTrim, .mafft, .rnaSeqQuant] {
            let state = Fx.fastqState(tool)
            let texts = Fx.strings(try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self))
            XCTAssertEqual(texts.first, "Inputs", tool.rawValue)
            XCTAssertEqual(texts.filter { $0 == "Overview" || $0 == "Readiness" }, [], tool.rawValue)
            XCTAssertEqual(texts.filter { $0 == state.selectedToolSummary }, [], tool.rawValue)
        }
    }

    // MARK: Sentence case headings

    func testTheHeadingsOfTheSevenDialogsAreInSentenceCase() throws {
        let bam = Fx.strings(try BAMVariantCallingToolPanes(state: try Fx.bamState(tool: .ivar)).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(bam.filter { $0 == "iVar options" || $0 == "iVar settings" }, ["iVar settings", "iVar options"])
        let loFreq = Fx.strings(try BAMVariantCallingToolPanes(state: try Fx.bamState()).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(loFreq.filter { $0.hasSuffix(" settings") }, ["LoFreq settings"])
        let orf = Fx.strings(
            try SequenceORFOperationDialog(state: Fx.orfState(), onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(orf.filter { $0 == "Reading frames" || $0 == "Reading Frames" }, ["Reading frames"])
        let iqTree = Fx.strings(
            try IQTreeInferenceDialog(state: Fx.iqTreeState(), onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(iqTree.filter { $0 == "Branch support" || $0 == "Branch Support" }, ["Branch support"])
        XCTAssertEqual(
            DatasetOperationSection.allCases.map(\.title),
            ["Overview", "Inputs", "Primary settings", "Advanced settings", "Output"])
    }

    /// A disclosure group label is the label of a control, so it keeps title case (5.6 U4, `UX-SHELL-WIZARDS` Q2). The mapping dialog
    /// draws both as `DisclosureGroup` labels, so they are not headings.
    func testTheMappingDisclosureLabelsKeepTitleCase() {
        XCTAssertEqual(MappingWizardSheet.readGroupSectionTitle, "Read Group")
        XCTAssertEqual(MappingWizardSheet.advancedSectionTitle, "Advanced Settings")
    }

    func testOnlyAToolWithAControlShowsAdvancedSettings() throws {
        for tool in [FASTQOperationToolID.qualityTrim, .mafft, .rnaSeqQuant] {
            let state = Fx.fastqState(tool)
            let texts = Fx.strings(try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self))
            XCTAssertEqual(
                texts.filter { $0 == "Advanced settings" }.count, tool.hasAdvancedSettingsControls ? 1 : 0, tool.rawValue)
        }
        XCTAssertEqual(
            Set(FASTQOperationToolID.allCases.filter(\.hasAdvancedSettingsControls)), [.pbaa, .savont, .ontGenotyping, .mafft])
        let package = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: package.root) }
        XCTAssertEqual(try Fx.workflowDetailTexts(package.state, paths: package.paths).filter { $0 == "Advanced settings" }, [])
    }

    // MARK: The summary is the card's help tag

    @MainActor
    private final class EnabledFASTQLibrary: WorkflowLibraryEnabling {
        func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool { true }
    }

    /// The card of the selected tool, found by its title in the rendered sidebar, holds the tool's summary as its help tag, which the
    /// pane's Overview held before.
    func testTheRenderedCardHoldsTheToolSummaryAsItsHelpTag() throws {
        for tool in [FASTQOperationToolID.qualityTrim, .mafft, .rnaSeqQuant] {
            let state = FASTQOperationDialogState(
                initialCategory: tool.categoryID, selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
                workflowLibrary: EnabledFASTQLibrary())
            state.selectTool(tool)
            let dialog = try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect()
            let card = try dialog.find(ViewType.Button.self) { (try? $0.labelView().find(text: tool.title)) != nil }
            XCTAssertEqual(try card.help().string(), state.selectedToolSummary, tool.rawValue)
            XCTAssertEqual(try card.help().string(), FASTQOperationDialogState.toolSummary(for: tool), tool.rawValue)
        }
    }

    /// The twelve help tags of `TV-SHELL-decided.md` (H1 to H6, M1 to M6), each the card's help tag and one sentence of at most 20 words by
    /// whitespace (`LungfishHelpContent+Placement.summaryWordLimit`). M1 to M6 keep the fact of a removed Advanced settings line, and the
    /// card of pbAA shows the same sentence as its subtitle.
    func testTheCardHelpTagsHoldTheDecidedSentences() {
        let pbaaSentence = "Save consensus sequences that pass PacBio HiFi amplicon clustering as a reference bundle."
        let decided: [(tool: FASTQOperationToolID, sentence: String)] = [
            (.ontGenotyping, "Keep full-amplicon matches allowing only indels from one ONT barcode FASTQ, split reads by barcode, and report genotypes in Excel."),
            (.ontFluidigmSampleSplit, "Split one bulk ONT Fluidigm amplicon bundle by selected sample-barcode definition into one counted CS1-CS2 insert FASTQ bundle per sample."),
            (.removeRibosomalRNA, "Use Deacon and the managed ribokmers database to keep the selected read classes."),
            (.savont, "Use Savont to cluster each FASTQ dataset separately and save counted consensus sequences as FASTA."),
            (.pbaa, pbaaSentence),
            (.rnaSeqQuant, "Count bulk RNA-seq reads with salmon using the reference set index and treat each FASTQ bundle as one sample."),
            (.removeContaminants, "Filter reads that match a contaminant reference, using the reference FASTA in Inputs for custom contaminants."),
            (.removeHumanReads, "Filter reads that match the configured human database using the managed Deacon pan-human index."),
            (.translate, "Translate frame 1 to protein FASTA, appending .1 (mate 1) and .2 (mate 2) only to interleaved mates’ shared IDs."),
            (.mergeOverlappingPairs, "Merge overlapping paired-end reads and store merged amplicon reads as counted exemplars with duplicate support in FASTQ headers."),
            (.orientReads, "Set read orientation using the selected reference sequence, which is required, without saving a separate unoriented bundle."),
            (.adapterRemoval, "Remove adapter sequences from reads, with manual trimming limited to a single literal sequence."),
        ]
        XCTAssertEqual(Set(decided.map(\.tool)).count, 12)
        for item in decided {
            XCTAssertEqual(FASTQOperationDialogState.toolSummary(for: item.tool), item.sentence, item.tool.rawValue)
        }
        XCTAssertEqual(FASTQOperationToolID.pbaa.subtitle, pbaaSentence)
        for tool in FASTQOperationToolID.allCases {
            let words = FASTQOperationDialogState.toolSummary(for: tool).split { $0.isWhitespace || $0.isNewline }.count
            XCTAssertLessThanOrEqual(words, 20, "\(tool.rawValue) holds \(words) words")
        }
    }

    /// A custom contaminant reference is chosen in the Inputs row, which says it is required and offers Choose…, and the footer says what
    /// is missing. Primary settings draws no third line that says the same. The one fact the row lacks, the FASTA format, is in the
    /// card's help tag (`TV-SHELL-decided.md`, open item 4).
    func testTheContaminantPaneLeavesTheChoosingToTheInputsRow() throws {
        let state = Fx.fastqState(.removeContaminants)
        state.removeContaminantsMode = .custom
        let texts = Fx.strings(try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(texts.filter { $0 == "Contaminant Reference" }, ["Contaminant Reference"])
        XCTAssertEqual(texts.filter { $0 == "Required before this tool can run." }, ["Required before this tool can run."])
        XCTAssertEqual(texts.filter { $0 == "Select the contaminant reference FASTA in the Inputs section." }, [])
        XCTAssertEqual(state.readinessText, "Select a contaminant reference to continue.")
    }

    // MARK: No section title without a control

    /// The controls a stack can hold. A custom control shows through the standard ones it draws.
    private static func controls(in stack: InspectableView<ViewType.ParentView>) -> Int {
        stack.findAll(ViewType.Picker.self).count + stack.findAll(ViewType.Toggle.self).count
            + stack.findAll(ViewType.TextField.self).count + stack.findAll(ViewType.Button.self).count
            + stack.findAll(ViewType.Stepper.self).count + stack.findAll(ViewType.Slider.self).count
            + stack.findAll(ViewType.Menu.self).count
    }

    private struct DrawnSection: Equatable {
        let title: String
        let controls: Int
    }

    /// The named sections of a pane, each with the number of controls in its stack. A section title is a headline `Text`, and its
    /// parent is the stack that holds the section, as the `section(_:content:)` of each pane draws it. A title that is not drawn is left out.
    private static func sections(_ texts: [InspectableView<ViewType.Text>], titles: [String]) -> [DrawnSection] {
        titles.compactMap { title in
            guard let text = texts.first(where: { (try? $0.string()) == title && (try? $0.attributes().font()) == Font.headline }),
                  let stack = try? text.parent()
            else { return nil }
            return DrawnSection(title: title, controls: controls(in: stack))
        }
    }

    /// Inputs shows the selected dataset and holds no control. It is the one section allowed to hold none.
    private func assertNoSectionWithoutAControl(
        _ texts: [InspectableView<ViewType.Text>], titles: [String], _ pane: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let drawn = Self.sections(texts, titles: titles)
        XCTAssertEqual(drawn.map(\.title), titles, pane, file: file, line: line)
        XCTAssertEqual(drawn.filter { $0.controls == 0 && $0.title != "Inputs" }, [], pane, file: file, line: line)
    }

    func testNoDerivativeToolShowsASectionWithoutAControl() throws {
        let wizardTools: Set<FASTQOperationToolID> = [
            .rnaSeqQuant, .minimap2, .bwaMem2, .bowtie2, .bbmap, .viralRecon, .spades, .megahit, .skesa, .flye, .hifiasm, .kraken2,
            .esViritu, .taxTriage,
        ]
        let derivative = FASTQOperationToolID.allCases.filter { !wizardTools.contains($0) }
        XCTAssertEqual(derivative.count, 29, "the tools the derivative pane draws")
        for tool in derivative {
            let state = Fx.fastqState(tool)
            let texts = try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self)
            assertNoSectionWithoutAControl(texts, titles: state.visibleSections.map(\.title), tool.rawValue)
        }
    }

    func testTheRNASeqQuantPaneShowsNoSectionWithoutAControl() throws {
        let texts = try FASTQOperationToolPanes(state: Fx.fastqState(.rnaSeqQuant)).inspect().findAll(ViewType.Text.self)
        assertNoSectionWithoutAControl(texts, titles: ["Inputs", "Reference set", "Index", "Trimming"], "RNA-seq quant")
    }

    private func workflowDetailTextViews(_ state: WorkflowOperationDialogState) throws -> [InspectableView<ViewType.Text>] {
        let scrolls = try Fx.workflowDialog(state).inspect().findAll(ViewType.ScrollView.self)
        XCTAssertGreaterThanOrEqual(scrolls.count, 2)
        return scrolls[1].findAll(ViewType.Text.self)
    }

    func testNoWorkflowToolShowsASectionWithoutAControl() throws {
        let cases: [(title: String, enable: (WorkflowLibraryEnablementStore) -> Void, sections: [String])] = [
            ("MiSeq Amplicon MHC Genotyping", { $0.setWorkflow(.ontGenotyping, enabled: true) },
             ["Overview", "Inputs", "Primary settings", "Advanced settings", "Output"]),
            ("Pseudobulk RNA-seq Cells", { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqPseudobulkItem, enabled: true) },
             ["Inputs", "Primary settings", "Output"]),
        ]
        for item in cases {
            let state = try Fx.workflowState(selecting: item.title, defaults: defaults, enabling: item.enable)
            assertNoSectionWithoutAControl(try workflowDetailTextViews(state), titles: item.sections, item.title)
        }
    }

    func testAnImportedPackageAndARunAgainShowNoSectionWithoutAControl() throws {
        let fixture = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        assertNoSectionWithoutAControl(
            try workflowDetailTextViews(fixture.state), titles: ["Overview", "Inputs", "Primary settings", "Output"], "imported package")
        try fixture.state.restoreReplayConfiguration(
            fixture.configuration, sourceBundleURL: fixture.root.appendingPathComponent("original.lungfishrun"))
        assertNoSectionWithoutAControl(
            try workflowDetailTextViews(fixture.state), titles: ["Overview", "Inputs", "Primary settings", "Output"], "Run Again")
    }

    // MARK: The Assembly, Viral Recon and primer trim headings

    private func primerTrimState() -> BAMPrimerTrimDialogState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationsDialogReadinessLine-\(UUID().uuidString)", isDirectory: true)
        let manifest = BundleManifest(
            name: "Stub", identifier: "stub.test",
            source: SourceInfo(organism: "Virus", assembly: "StubAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/ref.fa", indexPath: "genome/ref.fa.fai", totalLength: 1000,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 1000, offset: 0, lineBases: 60, lineWidth: 61)]),
            variants: [], alignments: [])
        return BAMPrimerTrimDialogState(
            bundle: ReferenceBundle(url: url, manifest: manifest), availability: .available, builtInSchemes: [], projectSchemes: [])
    }

    /// Hosts the three views that no test hosted, and pins the sentence case of their section headings by `XCTAssertEqual`. The filter
    /// ignores case, so a heading that turns Title Case is the one that fails.
    func testTheAssemblyViralReconAndPrimerTrimHeadingsAreInSentenceCase() throws {
        let assembly = Fx.strings(try AssemblyWizardSheet(inputFiles: [], outputDirectory: nil).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(assembly.filter { $0.lowercased() == "primary settings" }, ["Primary settings"])
        XCTAssertEqual(assembly.filter { $0.lowercased() == "advanced settings" }, ["Advanced settings"])
        let viralRecon = Fx.strings(
            try ViralReconWizardSheet(
                inputFiles: [], projectURL: nil, embeddedInOperationsDialog: false, embeddedRunTrigger: 0,
                onRun: { _ in }, onRunnerAvailabilityChange: { _ in }
            ).inspect().findAll(ViewType.Text.self))
        XCTAssertEqual(viralRecon.filter { $0.lowercased() == "primer scheme" }, ["Primer scheme"])
        // The pane also draws a picker label in Title Case, so this pin reads the headline `Text` only.
        let primerTrim = try BAMPrimerTrimToolPanes(state: primerTrimState(), onBrowseScheme: {}).inspect().findAll(ViewType.Text.self)
            .filter { (try? $0.attributes().font()) == Font.headline }
        XCTAssertEqual(Fx.strings(primerTrim).filter { $0.lowercased() == "primer scheme" }, ["Primer scheme"])
    }

    // MARK: The embedded Assembly and Viral Recon panes hold no Readiness card (UX-SHELL-WIZARDS Q1 b, work item A)

    private static let reads = [URL(fileURLWithPath: "/tmp/reads.fastq")]
    private static let assemblyOutput = URL(fileURLWithPath: "/tmp/assembly-out", isDirectory: true)

    private func viralRecon(embedded: Bool, onDetail: @escaping (String?) -> Void = { _ in }) -> ViralReconWizardSheet {
        ViralReconWizardSheet(
            inputFiles: [], projectURL: nil, embeddedInOperationsDialog: embedded, embeddedRunTrigger: 0,
            onRun: { _ in }, onRunnerAvailabilityChange: { _ in }, onReadinessDetailChange: onDetail)
    }

    /// Embedded, the Assembly pane draws no Readiness heading, no card message and no managed tool status, since the footer line beside
    /// Run holds them. The standalone sheet keeps its one Readiness (5.6 A2).
    func testTheEmbeddedAssemblyPaneDrawsNoReadinessCard() throws {
        let embedded = try AssemblyWizardSheet(
            inputFiles: Self.reads, outputDirectory: Self.assemblyOutput, embeddedInOperationsDialog: true).inspect()
        let texts = Fx.strings(embedded.findAll(ViewType.Text.self))
        XCTAssertEqual(texts.filter { $0 == "Readiness" }, [])
        XCTAssertEqual(texts.filter { $0.hasPrefix("Managed tool status") || $0.hasPrefix("Install the Genome Assembly pack") }, [])
        XCTAssertThrowsError(try embedded.find(viewWithAccessibilityIdentifier: "assembly-readiness-message"))

        let standalone = try AssemblyWizardSheet(inputFiles: Self.reads, outputDirectory: Self.assemblyOutput).inspect()
        XCTAssertEqual(Fx.strings(standalone.findAll(ViewType.Text.self)).filter { $0 == "Readiness" }, ["Readiness"])
        XCTAssertEqual(
            try standalone.find(viewWithAccessibilityIdentifier: "assembly-readiness-message").text().string(),
            "Install the Genome Assembly pack to enable SPAdes.")
    }

    /// Embedded, the Viral Recon pane draws no Readiness section and still draws Advanced. The standalone sheet keeps its one Readiness.
    func testTheEmbeddedViralReconPaneDrawsNoReadinessCard() throws {
        let embedded = try viralRecon(embedded: true).inspect()
        XCTAssertEqual(Fx.strings(embedded.findAll(ViewType.Text.self)).filter { $0 == "Readiness" }, [])
        XCTAssertThrowsError(try embedded.find(viewWithAccessibilityIdentifier: ViralReconAccessibilityID.readinessLabel))
        XCTAssertNoThrow(try embedded.find(viewWithAccessibilityIdentifier: ViralReconAccessibilityID.advancedDisclosure))

        let standalone = try viralRecon(embedded: false).inspect()
        XCTAssertEqual(Fx.strings(standalone.findAll(ViewType.Text.self)).filter { $0 == "Readiness" }, ["Readiness"])
        XCTAssertEqual(
            try standalone.find(viewWithAccessibilityIdentifier: ViralReconAccessibilityID.readinessLabel).text().string(),
            "Select at least one FASTQ bundle.")
    }

    func testTheFASTQDialogDrawsNoReadinessHeadingForAnEmbeddedAssemblyOrViralRecon() throws {
        for tool in [FASTQOperationToolID.spades, .flye, .viralRecon] {
            let state = Fx.fastqState(tool)
            XCTAssertEqual(state.selectedToolID, tool)
            let texts = Fx.strings(try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self))
            XCTAssertEqual(texts.filter { $0 == "Readiness" }, [], tool.rawValue)
        }
    }

    static let readClassWarning =
        "SPAdes is ready. SPAdes is designed for other reads than ONT reads. The run uses SPAdes as chosen."
    static let buildError = "Could not prepare Viral Recon: The disk is full."
    static let assemblySmokeLine = "SPAdes is not ready in the Genome Assembly pack yet. Managed tool status: Needs reinstall "
        + "spades.py --version exited with status 1."
    static let assemblyPackFailureLine = "Install the Genome Assembly pack to enable SPAdes. Managed tool status: Needs install "
        + "The Genome Assembly pack could not be checked."

    /// UX-SHELL-WIZARDS Q1 Table 1, the Assembly rows: the line the embedded wizard sends for each card state. A tool or pack failure
    /// follows the reason Run is off in the card's order, and a read-class warning shows with Run on once no other reason is left.
    func testTheAssemblyLineOfEachTable1Case() throws {
        let pack = try XCTUnwrap(PluginPack.builtInPack(id: "assembly"))
        let requirement = try XCTUnwrap(pack.toolRequirements.first { $0.id == AssemblyTool.spades.rawValue })
        func tool(installed: Bool, smokeTestFailure: String? = nil) -> PackToolStatus {
            PackToolStatus(
                requirement: requirement, environmentExists: installed, missingExecutables: installed ? [] : ["spades.py"],
                smokeTestFailure: smokeTestFailure, storageUnavailablePath: nil)
        }
        func line(
            name: String = "reads_assembly", inputs: Bool = true, reads: AssemblyReadType = .illuminaShortReads,
            tool: PackToolStatus?, loaded: Bool = true, packFailure: String? = nil
        ) -> String? {
            let packStatus = loaded
                ? PluginPackStatus(
                    pack: pack, state: packFailure == nil ? .ready : .failed, toolStatuses: tool.map { [$0] } ?? [],
                    failureMessage: packFailure)
                : nil
            let compatibility = AssemblyCompatibilityPresentation(
                tool: .spades, readType: reads, packReady: tool?.environmentExists == true, toolReady: tool?.isReady == true,
                blockingMessage: nil)
            return AssemblyWizardRunPresentation(
                hasInputFiles: inputs, hasOutputDirectory: true, projectName: name, requiresManualReadTypeConfirmation: false,
                hasConfirmedManualReadType: false, advancedOptionsParseError: nil, compatibilityPresentation: compatibility,
                configurationBlockingMessage: nil
            ).embeddedReadinessDetail(packStatus: packStatus, toolStatus: tool)
        }
        let ready = tool(installed: true)
        let missing = tool(installed: false)
        let smoke = tool(installed: true, smokeTestFailure: "spades.py --version exited with status 1.")
        XCTAssertEqual(AssemblyWizardRunPresentation.checkingPackText, "Checking the Genome Assembly pack\u{2026}")
        XCTAssertEqual(line(tool: nil, loaded: false), "Checking the Genome Assembly pack\u{2026}", "pack status not loaded")
        XCTAssertEqual(line(inputs: false, tool: nil, loaded: false), "Select at least one FASTQ input.", "no inputs")
        XCTAssertEqual(line(name: " ", tool: nil, loaded: false), "Project name is required.", "an earlier reason while loading")
        XCTAssertEqual(line(name: "", tool: ready), "Project name is required.", "empty project name")
        XCTAssertEqual(
            line(tool: missing), "Install the Genome Assembly pack to enable SPAdes. Managed tool status: Needs install", "pack missing")
        XCTAssertEqual(line(tool: smoke), Self.assemblySmokeLine, "tool not ready with a smoke-test failure")
        XCTAssertEqual(
            line(tool: missing, packFailure: "The Genome Assembly pack could not be checked."), Self.assemblyPackFailureLine,
            "pack failure")
        XCTAssertEqual(
            line(tool: smoke, packFailure: "spades.py --version exited with status 1."), Self.assemblySmokeLine,
            "the service copies the tool's smoke-test failure into the pack's failure, and the footer shows it once")
        XCTAssertEqual(line(reads: .ontReads, tool: ready), Self.readClassWarning, "read-class warning with Run on")
        XCTAssertEqual(line(name: "", reads: .ontReads, tool: ready), "Project name is required.", "the warning waits")
        XCTAssertNil(line(tool: ready), "Run on, no warning")
    }

    /// UX-SHELL-WIZARDS Q1 Table 1, the Viral Recon rows. Embedded, `visibleControls` holds no Readiness.
    func testTheViralReconLineOfEachTable1CaseAndItsControls() {
        let blocked = ViralReconWizardReadiness.evaluate(.init(
            hasInputFiles: true, effectivePlatform: .illumina, inputError: nil, primerManifest: nil, outputRootAvailable: true,
            minimumMappedReads: 1000))
        let ready = ViralReconWizardReadiness.Evaluation(canRun: true, message: "Ready to run Viral Recon.")
        XCTAssertEqual(
            ViralReconWizardSheet.embeddedReadinessDetail(isPreparing: true, buildError: nil, evaluation: ready),
            "Preparing inputs\u{2026}", "preparing")
        XCTAssertEqual(
            ViralReconWizardSheet.embeddedReadinessDetail(isPreparing: false, buildError: Self.buildError, evaluation: ready),
            Self.buildError, "buildError with Run on")
        XCTAssertEqual(
            ViralReconWizardSheet.embeddedReadinessDetail(isPreparing: false, buildError: nil, evaluation: blocked),
            "Select a SARS-CoV-2 primer scheme.", "Run off, the exact reason")
        XCTAssertNil(
            ViralReconWizardSheet.embeddedReadinessDetail(isPreparing: false, buildError: nil, evaluation: ready), "Run on, no error")
        for detected in [true, false] {
            let embedded = ViralReconWizardSheet.visibleControls(platformDetected: detected, embedded: true)
            XCTAssertEqual(embedded.filter { $0 == .readiness }, [])
            let standalone = ViralReconWizardSheet.visibleControls(platformDetected: detected, embedded: false)
            XCTAssertEqual(standalone.filter { $0 == .readiness }, [.readiness])
        }
    }

    /// Both wizards send their line on appear, so the footer holds it from the first frame.
    func testTheEmbeddedWizardsSendTheirLineOnAppear() throws {
        var assembly: [String?] = []
        try AssemblyWizardSheet(
            inputFiles: [], outputDirectory: nil, embeddedInOperationsDialog: true, onReadinessDetailChange: { assembly.append($0) }
        ).inspect().group().callOnAppear()
        XCTAssertEqual(assembly, ["Select at least one FASTQ input."])
        var recon: [String?] = []
        try viralRecon(embedded: true, onDetail: { recon.append($0) }).inspect().scrollView().callOnAppear()
        XCTAssertEqual(recon, ["Select at least one FASTQ bundle."])
    }
}

// MARK: - The footer line of an embedded wizard (UX-SHELL-WIZARDS Q1 Table 1, work item B)

extension OperationsDialogReadinessLineTests {
    /// One row of Table 1 as the FASTQ dialog's state receives it: the wizard's Run state and the detail it sends.
    private struct FooterCase {
        let row: String
        let tool: FASTQOperationToolID
        let runOn: Bool
        let detail: String?
        let footer: String
    }

    private static let footerCases: [FooterCase] = [
        FooterCase(row: "Assembly, tool not ready with a smoke-test failure", tool: .spades, runOn: false,
                   detail: assemblySmokeLine, footer: assemblySmokeLine),
        FooterCase(row: "Assembly, pack failure", tool: .hifiasm, runOn: false,
                   detail: assemblyPackFailureLine, footer: assemblyPackFailureLine),
        FooterCase(row: "Assembly, pack status not loaded", tool: .spades, runOn: false,
                   detail: "Checking the Genome Assembly pack\u{2026}", footer: "Checking the Genome Assembly pack\u{2026}"),
        FooterCase(row: "Assembly, Run off", tool: .megahit, runOn: false,
                   detail: "Project name is required.", footer: "Project name is required."),
        FooterCase(row: "Assembly, Run on, read-class warning", tool: .spades, runOn: true,
                   detail: readClassWarning, footer: readClassWarning),
        FooterCase(row: "Assembly, Run on, no warning", tool: .flye, runOn: true, detail: nil, footer: "Ready to configure output."),
        FooterCase(row: "Viral Recon, preparing", tool: .viralRecon, runOn: false,
                   detail: "Preparing inputs\u{2026}", footer: "Preparing inputs\u{2026}"),
        FooterCase(row: "Viral Recon, buildError", tool: .viralRecon, runOn: true, detail: buildError, footer: buildError),
        FooterCase(row: "Viral Recon, Run off", tool: .viralRecon, runOn: false,
                   detail: "Select a SARS-CoV-2 primer scheme.", footer: "Select a SARS-CoV-2 primer scheme."),
        FooterCase(row: "Viral Recon, Run on, no error", tool: .viralRecon, runOn: true, detail: nil, footer: "Ready to configure output."),
        FooterCase(row: "kraken2, Run on", tool: .kraken2, runOn: true, detail: nil, footer: "Output is fixed for this tool."),
        FooterCase(row: "EsViritu, Run on", tool: .esViritu, runOn: true, detail: nil, footer: "Output is fixed for this tool."),
    ]

    private func fastqState(_ item: FooterCase) -> FASTQOperationDialogState {
        let state = Fx.fastqState(item.tool)
        state.updateEmbeddedReadiness(item.runOn, for: item.tool)
        state.updateEmbeddedReadinessDetail(item.detail, for: item.tool)
        return state
    }

    /// The footer shows the detail the wizard sends whenever it is set, so a read-class warning and a build error show with Run on.
    /// With no detail and Run on, the footer keeps its own ready line, for the two wizards and for kraken2 and EsViritu.
    func testTheFooterShowsTheEmbeddedWizardDetailOfEachTable1Case() throws {
        for item in Self.footerCases {
            let state = fastqState(item)
            XCTAssertEqual(state.selectedToolID, item.tool, item.row)
            XCTAssertEqual(state.isRunEnabled, item.runOn, item.row)
            XCTAssertEqual(state.readinessText, item.footer, item.row)
            let texts = try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
            assertDrawnOnceInTheFooter(texts, item.footer, hasIdentifier: item.tool.categoryID != .classification, item.row)
        }
    }

    /// The footer is orange while Run is off and while a line shows with Run on, so a build error or a read-class warning keeps the
    /// card's orange. With no line and Run on it is grey. The FASTQ dialog hands that to its shell.
    func testTheFooterColorOfEachTable1Case() throws {
        for item in Self.footerCases {
            let state = fastqState(item)
            let attention = !item.runOn || item.detail != nil
            XCTAssertEqual(state.readinessNeedsAttention, attention, item.row)
            let shell = try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect()
                .find(DatasetOperationsDialog<FASTQOperationToolPanes>.self).actualView()
            XCTAssertEqual(shell.statusColor, attention ? Color.lungfishOrangeFallback : Color.lungfishSecondaryText, item.row)
        }
    }

    /// A dialog that passes no `statusNeedsAttention` keeps its footer orange exactly while Run is off.
    func testTheShellFallsBackToRunOffForItsColor() {
        func shell(runOn: Bool, attention: Bool?) -> DatasetOperationsDialog<EmptyView> {
            DatasetOperationsDialog(
                title: "Operations", subtitle: "", datasetLabel: "", tools: [], selectedToolID: "tool", statusText: "Status",
                isRunEnabled: runOn, statusNeedsAttention: attention, onSelectTool: { _ in }, onCancel: {}, onRun: {}
            ) { EmptyView() }
        }
        XCTAssertEqual(shell(runOn: false, attention: nil).statusColor, Color.lungfishOrangeFallback)
        XCTAssertEqual(shell(runOn: true, attention: nil).statusColor, Color.lungfishSecondaryText)
        XCTAssertEqual(shell(runOn: true, attention: true).statusColor, Color.lungfishOrangeFallback)
    }

    /// The pane hands each embedded wizard's line to the dialog state. The argument defaults to nil, so a dropped one compiles, and
    /// the Assembly closure must name the tool selected, since the pane serves five tools.
    func testThePaneHandsAnEmbeddedWizardsLineToTheFooter() throws {
        for tool in [FASTQOperationToolID.spades, .hifiasm, .viralRecon] {
            let state = Fx.fastqState(tool)
            XCTAssertNil(state.embeddedToolReadinessDetail, tool.rawValue)
            let dialog = try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect()
            if tool == .viralRecon {
                try dialog.find(ViralReconWizardSheet.self).scrollView().callOnAppear()
            } else {
                try dialog.find(AssemblyWizardSheet.self).group().callOnAppear()
            }
            let detail = try XCTUnwrap(state.embeddedToolReadinessDetail, tool.rawValue)
            XCTAssertEqual(state.readinessText, detail, tool.rawValue)
        }
    }
}
