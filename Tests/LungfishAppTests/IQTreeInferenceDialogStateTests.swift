// IQTreeInferenceDialogStateTests.swift - Readiness, mapping and launch rules of the IQ-TREE dialog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO

/// Rulings D1-D7 and K4 (dialog side) from the 2026-10-05 IQ-TREE session.
@MainActor
final class IQTreeInferenceDialogStateTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/project", isDirectory: true)
    private let bundleURL = URL(
        fileURLWithPath: "/project/Analyses/Multiple Sequence Alignments/alignment.lungfishmsa",
        isDirectory: true
    )
    private let outputURL = URL(
        fileURLWithPath: "/project/Phylogenetic Trees/alignment-tree.lungfishtree",
        isDirectory: true
    )

    private func alignment(
        rowCount: Int = 6,
        alignedLength: Int = 300,
        alphabet: String = "dna",
        names: [String]? = nil
    ) -> IQTreeAlignmentSummary {
        let displayNames = names ?? (1...rowCount).map { "Sequence \($0)" }
        return IQTreeAlignmentSummary(
            rows: displayNames.enumerated().map { index, name in
                IQTreeAlignmentSummary.Row(id: "row-\(index + 1)", displayName: name)
            },
            alignedLength: alignedLength,
            alphabet: alphabet
        )
    }

    private func makeState(
        rows: String? = nil,
        columns: String? = nil,
        alignment: IQTreeAlignmentSummary?
    ) -> IQTreeInferenceDialogState {
        IQTreeInferenceDialogState(
            request: MultipleSequenceAlignmentTreeInferenceRequest(
                bundleURL: bundleURL,
                rows: rows,
                columns: columns,
                suggestedName: "alignment-tree.lungfishtree",
                displayName: "alignment"
            ),
            projectURL: projectURL,
            alignment: alignment
        )
    }

    private func preparedOptions(
        _ state: IQTreeInferenceDialogState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> IQTreeInferenceOptions {
        state.prepareForRun()
        return try XCTUnwrap(state.pendingOptions, state.validationMessage ?? "no message", file: file, line: line)
    }

    private func launch(_ options: IQTreeInferenceOptions, seed: Int = 777) -> IQTreeInferenceLaunch {
        IQTreeInferenceLaunch.make(
            bundleURL: bundleURL,
            projectURL: projectURL,
            outputURL: outputURL,
            outputName: "alignment-tree",
            options: options,
            drawSeed: { seed }
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    // MARK: - D1 chrome

    func testDialogChromeUsesBuildTreeTitles() {
        let state = makeState(alignment: alignment())
        XCTAssertEqual(state.dialogTitle, "Build Tree with IQ-TREE")
        XCTAssertEqual(state.dialogSubtitle, "Infer a maximum-likelihood tree from an alignment.")
        XCTAssertEqual(state.primaryActionTitle, "Build Tree")
    }

    func testReadinessLineCarriesWarningSymbolOnlyWhenBlocked() {
        let state = makeState(alignment: alignment())
        XCTAssertTrue(state.isRunEnabled)
        XCTAssertFalse(state.readinessText.hasPrefix(IQTreeInferenceDialogState.warningSymbol))

        state.seedText = "12a"
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "\(IQTreeInferenceDialogState.warningSymbol) Seed must be a whole number.")
    }

    func testUnreadableAlignmentBlocksRun() {
        let state = makeState(alignment: nil)
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.validationMessage, "The alignment bundle could not be read.")
    }

    // MARK: - K4 scope

    func testWholeScopeIsTheOnlyChoiceWithoutSelection() {
        let state = makeState(alignment: alignment(rowCount: 6, alignedLength: 300))
        XCTAssertFalse(state.offersSelectedScope)
        XCTAssertEqual(state.scope, .whole)
        XCTAssertEqual(state.wholeScopeTitle, "Whole alignment (6 sequences, 300 columns)")
    }

    func testSelectedScopeIsDefaultWithThreeOrMoreSelectedRows() {
        let state = makeState(rows: "row-1,row-2,row-3", columns: "10-200", alignment: alignment())
        XCTAssertTrue(state.offersSelectedScope)
        XCTAssertEqual(state.scope, .selected)
        XCTAssertEqual(state.selectedScopeTitle, "Selected rows and columns (3 sequences, columns 10-200)")
        XCTAssertEqual(state.inScopeSequenceCount, 3)
        XCTAssertEqual(state.inScopeColumnCount, 191)
    }

    func testWholeScopeIsDefaultWithFewerThanThreeSelectedRows() {
        let state = makeState(rows: "row-1,row-2", columns: "10-200", alignment: alignment())
        XCTAssertTrue(state.offersSelectedScope)
        XCTAssertEqual(state.scope, .whole)
    }

    func testSelectedRowsResolveByDisplayNameAsWellAsRowID() {
        let state = makeState(rows: "row-1,Sequence 2,row-3", alignment: alignment())
        XCTAssertEqual(state.inScopeSequenceCount, 3)
        XCTAssertEqual(state.selectedScopeTitle, "Selected rows and columns (3 sequences, columns 1-300)")
    }

    func testWholeScopeSendsNoRowsOrColumns() throws {
        let state = makeState(rows: "row-1,row-2,row-3,row-4", columns: "10-200", alignment: alignment())
        state.scope = .whole
        let options = try preparedOptions(state)
        XCTAssertNil(options.rows)
        XCTAssertNil(options.columns)
        let arguments = launch(options).arguments
        XCTAssertFalse(arguments.contains("--rows"))
        XCTAssertFalse(arguments.contains("--columns"))
    }

    func testSelectedScopeSendsRequestRowsAndColumns() throws {
        let state = makeState(rows: "row-1,row-2,row-3,row-4", columns: "10-200", alignment: alignment())
        let options = try preparedOptions(state)
        let arguments = launch(options).arguments
        XCTAssertEqual(value(after: "--rows", in: arguments), "row-1,row-2,row-3,row-4")
        XCTAssertEqual(value(after: "--columns", in: arguments), "10-200")
    }

    func testFewerThanThreeSequencesBlocksRun() {
        let state = makeState(alignment: alignment(rowCount: 2))
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.validationMessage, "IQ-TREE needs at least 3 sequences. This scope has 2.")
    }

    func testThreeSequencesDisableAndUncheckBranchSupport() throws {
        let state = makeState(alignment: alignment(rowCount: 3))
        XCTAssertFalse(state.isBranchSupportAvailable)
        XCTAssertFalse(state.bootstrapEnabled)
        XCTAssertFalse(state.alrtEnabled)
        XCTAssertEqual(state.branchSupportUnavailableCaption, "Bootstrap and SH-aLRT need at least 4 sequences.")
        XCTAssertTrue(state.isRunEnabled)

        state.bootstrapEnabled = true
        let options = try preparedOptions(state)
        XCTAssertNil(options.bootstrap)
        XCTAssertNil(options.alrt)
    }

    func testSwitchingToASmallScopeUnchecksSupportBoxes() {
        let state = makeState(rows: "row-1,row-2,row-3", alignment: alignment(rowCount: 6))
        state.scope = .whole
        XCTAssertTrue(state.isBranchSupportAvailable)
        state.bootstrapEnabled = true
        state.alrtEnabled = true
        state.scope = .selected
        XCTAssertFalse(state.bootstrapEnabled)
        XCTAssertFalse(state.alrtEnabled)
    }

    // MARK: - D4 branch support defaults

    func testBranchSupportDefaultsToUFBootAndSHaLRTAt1000() throws {
        let state = makeState(alignment: alignment())
        XCTAssertTrue(state.bootstrapEnabled)
        XCTAssertTrue(state.alrtEnabled)
        XCTAssertEqual(state.bootstrapReplicatesText, "1000")
        XCTAssertEqual(state.alrtReplicatesText, "1000")
        let options = try preparedOptions(state)
        XCTAssertEqual(options.bootstrap, 1000)
        XCTAssertEqual(options.alrt, 1000)
    }

    /// Fix F1 (m3): growing the scope back to 4 or more sequences restores the
    /// D4 defaults while the user has not touched either box.
    func testGrowingScopeRestoresSupportDefaultsWhenNeverToggled() throws {
        let state = makeState(rows: "row-1,row-2,row-3", alignment: alignment(rowCount: 6))
        XCTAssertFalse(state.bootstrapEnabled)
        XCTAssertFalse(state.alrtEnabled)
        state.scope = .whole
        XCTAssertTrue(state.bootstrapEnabled)
        XCTAssertTrue(state.alrtEnabled)
        let options = try preparedOptions(state)
        XCTAssertEqual(options.bootstrap, 1000)
        XCTAssertEqual(options.alrt, 1000)
    }

    func testGrowingScopeKeepsSupportBoxesTheUserToggled() {
        let state = makeState(rows: "row-1,row-2,row-3", alignment: alignment(rowCount: 6))
        state.scope = .whole
        state.alrtEnabled = false
        state.scope = .selected
        state.scope = .whole
        XCTAssertFalse(state.bootstrapEnabled)
        XCTAssertFalse(state.alrtEnabled)
    }

    func testBootstrapBelowUFBootMinimumBlocksRun() {
        let state = makeState(alignment: alignment())
        state.bootstrapReplicatesText = "100"
        XCTAssertEqual(state.validationMessage, "UFBoot replicates must be at least 1000.")
        state.bootstrapReplicatesText = "1000"
        XCTAssertTrue(state.isRunEnabled)
    }

    func testNonNumericReplicatesBlockRun() {
        let state = makeState(alignment: alignment())
        state.bootstrapReplicatesText = "1e3"
        XCTAssertEqual(state.validationMessage, "UFBoot replicates must be a whole number.")
        state.bootstrapReplicatesText = "1000"
        state.alrtReplicatesText = "ten"
        XCTAssertEqual(state.validationMessage, "SH-aLRT replicates must be a whole number.")
        state.alrtReplicatesText = "0"
        XCTAssertEqual(state.validationMessage, "SH-aLRT replicates must be at least 1.")
    }

    func testReplicateTextIsIgnoredWhileItsBoxIsOff() throws {
        let state = makeState(alignment: alignment())
        state.bootstrapEnabled = false
        state.bootstrapReplicatesText = "junk"
        let options = try preparedOptions(state)
        XCTAssertNil(options.bootstrap)
    }

    func testUFBootStepperStepsBy1000WithMinimum1000() {
        let state = makeState(alignment: alignment())
        XCTAssertEqual(IQTreeInferenceDialogState.ufbootStep, 1000)
        XCTAssertEqual(IQTreeInferenceDialogState.ufbootRange.lowerBound, 1000)
        state.bootstrapReplicatesStepperValue += IQTreeInferenceDialogState.ufbootStep
        XCTAssertEqual(state.bootstrapReplicatesText, "2000")
        state.bootstrapReplicatesText = "abc"
        XCTAssertEqual(state.bootstrapReplicatesStepperValue, 1000)
    }

    // MARK: - D2 model

    func testModelPopUpListsModelFinderFixedDNAModelsAndCustom() {
        let state = makeState(alignment: alignment(alphabet: "dna"))
        XCTAssertEqual(state.modelChoice, .modelFinder)
        XCTAssertEqual(state.availableFixedModels, ["JC", "HKY+F+G4", "GTR+F+I+G4", "GTR+F+R4"])
        XCTAssertEqual(IQTreeModelChoice.modelFinder.title, "Find best model (ModelFinder)")
        XCTAssertEqual(IQTreeModelChoice.custom.title, "Custom…")
    }

    func testProteinAlignmentListsProteinModels() {
        let state = makeState(alignment: alignment(alphabet: "protein"))
        XCTAssertEqual(state.availableFixedModels, ["LG+G4", "WAG+G4", "JTT+G4", "LG+F+R4"])
    }

    func testModelChoiceMapsToModelArgument() throws {
        let state = makeState(alignment: alignment())
        XCTAssertEqual(try preparedOptions(state).model, "MFP")
        state.modelChoice = .fixed("GTR+F+I+G4")
        XCTAssertEqual(try preparedOptions(state).model, "GTR+F+I+G4")
        state.modelChoice = .custom
        state.customModel = "  TIM2+F+I+G4  "
        XCTAssertEqual(try preparedOptions(state).model, "TIM2+F+I+G4")
    }

    func testCustomModelRejectsModelFinderOnlyPresets() {
        let state = makeState(alignment: alignment())
        state.modelChoice = .custom
        state.customModel = ""
        XCTAssertEqual(state.validationMessage, "Enter a custom IQ-TREE model.")
        for rejected in ["MF", "TESTONLY", "MFONLY", "testmergeonly", "mf"] {
            state.customModel = rejected
            XCTAssertEqual(
                state.validationMessage,
                "\(rejected) only selects a model and builds no tree. Choose Find best model (ModelFinder) instead.",
                rejected
            )
        }
        state.customModel = "TEST"
        XCTAssertTrue(state.isRunEnabled)
    }

    // MARK: - D3 sequence type

    func testSequenceTypesFollowTheAlphabet() {
        XCTAssertEqual(makeState(alignment: alignment(alphabet: "dna")).availableSequenceTypes, [.auto, .dna, .codon])
        XCTAssertEqual(makeState(alignment: alignment(alphabet: "rna")).availableSequenceTypes, [.auto, .dna, .codon])
        XCTAssertEqual(makeState(alignment: alignment(alphabet: "protein")).availableSequenceTypes, [.auto, .protein])
    }

    func testSequenceTypeMapsToCLIValue() throws {
        let state = makeState(alignment: alignment(alignedLength: 300))
        XCTAssertEqual(try preparedOptions(state).sequenceType, "auto")
        XCTAssertFalse(launch(try preparedOptions(state)).arguments.contains("--sequence-type"))
        state.sequenceType = .dna
        XCTAssertEqual(try preparedOptions(state).sequenceType, "DNA")
        state.sequenceType = .codon
        state.geneticCode = .standard
        XCTAssertEqual(try preparedOptions(state).sequenceType, "CODON1")
        state.geneticCode = .vertebrateMitochondrial
        XCTAssertEqual(try preparedOptions(state).sequenceType, "CODON2")

        let protein = makeState(alignment: alignment(alphabet: "protein"))
        protein.sequenceType = .protein
        XCTAssertEqual(try preparedOptions(protein).sequenceType, "AA")
    }

    func testCodonNeedsColumnCountMultipleOfThree() {
        let state = makeState(rows: "row-1,row-2,row-3,row-4", columns: "1-100", alignment: alignment(alignedLength: 300))
        state.sequenceType = .codon
        XCTAssertEqual(
            state.validationMessage,
            "Codon models need a column count that is a multiple of 3. This scope has 100 columns."
        )
        state.scope = .whole
        XCTAssertTrue(state.isRunEnabled)
    }

    func testCodonHidesNucleotideFixedModels() {
        let state = makeState(alignment: alignment(alignedLength: 300))
        state.modelChoice = .fixed("GTR+F+R4")
        state.sequenceType = .codon
        XCTAssertEqual(state.availableFixedModels, [])
        XCTAssertEqual(
            state.validationMessage,
            "GTR+F+R4 is not a codon model. Choose Find best model (ModelFinder) or a custom codon model."
        )
    }

    // MARK: - D5 seed

    func testBlankSeedIsDrawnAndRecorded() throws {
        let state = makeState(alignment: alignment())
        XCTAssertEqual(state.seedText, "")
        XCTAssertEqual(IQTreeInferenceDialogState.seedPlaceholder, "Random")
        let options = try preparedOptions(state)
        XCTAssertNil(options.seed)

        let drawn = launch(options, seed: 424242)
        XCTAssertTrue(drawn.seedWasDrawn)
        XCTAssertEqual(drawn.seed, 424242)
        XCTAssertEqual(value(after: "--seed", in: drawn.arguments), "424242")
        XCTAssertTrue(drawn.cliCommand.contains("--seed 424242"))
        XCTAssertTrue(drawn.seedLogMessage.contains("424242"))
    }

    func testRandomSeedStaysInIQTreeRange() {
        for _ in 0..<64 {
            let seed = IQTreeInferenceLaunch.drawRandomSeed()
            XCTAssertTrue((1...Int(Int32.max)).contains(seed))
        }
    }

    func testTypedSeedIsUsedVerbatim() throws {
        let state = makeState(alignment: alignment())
        state.seedText = " 12345 "
        let options = try preparedOptions(state)
        XCTAssertEqual(options.seed, 12345)
        let typed = launch(options, seed: 1)
        XCTAssertFalse(typed.seedWasDrawn)
        XCTAssertEqual(value(after: "--seed", in: typed.arguments), "12345")
    }

    func testNonNumericSeedBlocksRun() {
        let state = makeState(alignment: alignment())
        for text in ["12a", "-5", "0", "1.5"] {
            state.seedText = text
            XCTAssertEqual(state.validationMessage, "Seed must be a whole number.", text)
        }
    }

    // MARK: - D6 threads

    /// Revised D6: one thread for every scope, because IQ-TREE with more
    /// threads gives slightly different branch lengths on each run.
    func testThreadsDefaultToOneForEveryScope() throws {
        let small = makeState(alignment: alignment(rowCount: 6, alignedLength: 300))
        XCTAssertEqual(small.threadsText, "1")
        XCTAssertEqual(value(after: "--threads", in: launch(try preparedOptions(small)).arguments), "1")
        let large = makeState(alignment: alignment(rowCount: 60, alignedLength: 20_000))
        XCTAssertEqual(large.threadsText, "1")
        XCTAssertEqual(value(after: "--threads", in: launch(try preparedOptions(large)).arguments), "1")
    }

    func testEditedThreadsAreRecordedAndSurviveScopeChanges() throws {
        let names = (1...60).map { "Sequence \($0)" }
        let state = makeState(rows: "row-1,row-2,row-3", alignment: alignment(names: names))
        state.scope = .whole
        XCTAssertEqual(state.threadsText, "1")
        state.threadsText = "4"
        state.scope = .selected
        XCTAssertEqual(state.threadsText, "4")
        XCTAssertEqual(value(after: "--threads", in: launch(try preparedOptions(state)).arguments), "4")
    }

    func testThreadsCaptionExplainsReproducibility() {
        XCTAssertEqual(
            IQTreeInferenceDialogState.threadsCaption,
            "One thread gives the same tree on every run. More threads can be faster on large alignments, but IQ-TREE then gives slightly different branch lengths each run."
        )
    }

    func testNonNumericThreadsBlockRun() {
        let state = makeState(alignment: alignment())
        state.threadsText = "auto"
        XCTAssertEqual(state.validationMessage, "Threads must be a whole number.")
        state.threadsText = ""
        XCTAssertEqual(state.validationMessage, "Threads must be a whole number.")
    }

    // MARK: - D7 outgroup

    /// Fix F1 (m6): every in-scope row is a candidate, commas included, and
    /// each one is keyed by its row ID.
    func testOutgroupCandidatesAreEveryInScopeRow() {
        let state = makeState(
            rows: "row-1,row-2,row-3,row-4",
            alignment: alignment(names: ["Homo sapiens", "Macaca mulatta", "Pan, troglodytes", "Gorilla", "Mus musculus"])
        )
        XCTAssertEqual(state.outgroupCandidates.map(\.displayName), ["Homo sapiens", "Macaca mulatta", "Pan, troglodytes", "Gorilla"])
        XCTAssertEqual(state.outgroupCandidates.map(\.id), ["row-1", "row-2", "row-3", "row-4"])
        state.scope = .whole
        XCTAssertEqual(state.outgroupCandidates.map(\.id), ["row-1", "row-2", "row-3", "row-4", "row-5"])
    }

    /// Fix F1 (m6): the outgroup reaches the CLI as row IDs in row order, so a
    /// name with a comma is passed safely.
    func testOutgroupArgumentListsSelectedRowIDsInRowOrder() throws {
        let state = makeState(alignment: alignment(names: ["Homo sapiens", "Macaca mulatta", "Pan, troglodytes", "Mus musculus"]))
        XCTAssertFalse(launch(try preparedOptions(state)).arguments.contains("--outgroup"))
        state.setOutgroup(rowID: "row-4", selected: true)
        state.setOutgroup(rowID: "row-3", selected: true)
        XCTAssertTrue(state.isOutgroupSelected(rowID: "row-3"))
        let options = try preparedOptions(state)
        XCTAssertEqual(options.outgroup, ["row-3", "row-4"])
        XCTAssertEqual(value(after: "--outgroup", in: launch(options).arguments), "row-3,row-4")
    }

    func testScopeChangeDropsOutOfScopeOutgroupRows() throws {
        let state = makeState(
            rows: "row-1,row-2,row-3",
            alignment: alignment(names: ["Homo sapiens", "Macaca mulatta", "Gorilla", "Mus musculus"])
        )
        state.scope = .whole
        state.setOutgroup(rowID: "row-4", selected: true)
        state.scope = .selected
        XCTAssertEqual(try preparedOptions(state).outgroup, [])
    }

    /// Fix F1 (M2): the dialog blocks what the CLI rejects at staging.
    func testDuplicateInScopeDisplayNamesBlockRun() {
        let state = makeState(
            rows: "row-1,row-2,row-3,row-4",
            alignment: alignment(names: ["Homo sapiens", "Macaca mulatta", "Homo sapiens", "Gorilla", "Macaca mulatta"])
        )
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(
            state.validationMessage,
            "Rows row-1, row-3 share the display name 'Homo sapiens'. Tree tips need distinct names."
        )
        XCTAssertEqual(state.outgroupCandidates.map(\.id), ["row-1", "row-2", "row-3", "row-4"])
    }

    /// Fix F1 (M2): an outgroup of every in-scope row leaves no ingroup.
    func testOutgroupCoveringEveryRowBlocksRun() {
        let state = makeState(alignment: alignment(rowCount: 4))
        for id in ["row-1", "row-2", "row-3"] {
            state.setOutgroup(rowID: id, selected: true)
        }
        XCTAssertTrue(state.isRunEnabled)
        state.setOutgroup(rowID: "row-4", selected: true)
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.validationMessage, "The outgroup must leave at least one sequence in the ingroup.")
    }

    /// Fix C1: the dialog splits the model on the first "+" like the CLI does.
    func testCustomModelRejectsSelectionOnlyBaseWithSuffixes() {
        let state = makeState(alignment: alignment())
        state.modelChoice = .custom
        for rejected in ["MF+MERGE", "testonly", "TESTNEWONLY+F", "mf"] {
            state.customModel = rejected
            XCTAssertFalse(state.isRunEnabled, rejected)
        }
        for accepted in ["TEST", "MFP+MERGE", "GTR+F+I+G4"] {
            state.customModel = accepted
            XCTAssertTrue(state.isRunEnabled, accepted)
        }
    }

    /// Fix C1: curated flags in the advanced text block Run, as the CLI rejects them.
    func testAdvancedParametersBlockCuratedFlags() {
        let state = makeState(alignment: alignment())
        let flags = ["-s", "--prefix", "-pre", "-m", "-T", "-nt", "--seed", "-seed", "-B", "-bb",
                     "--ufboot", "--alrt", "-alrt", "-o", "-st", "--seqtype"]
        for flag in flags {
            state.extraIQTreeOptions = "\(flag)=4"
            XCTAssertFalse(state.isRunEnabled, flag)
        }
        state.extraIQTreeOptions = "-T 4"
        XCTAssertTrue(state.readinessText.contains("Remove -T from the additional parameters. Use Threads instead."))
        state.extraIQTreeOptions = "-b=100 -bnni"
        XCTAssertTrue(state.isRunEnabled)
    }

    // MARK: - Recorded command

    /// Every option that exists on the lane C tip parses with the real CLI parser.
    func testRecordedCommandParsesWithLungfishCLI() throws {
        let state = makeState(rows: "row-1,row-2,row-3,row-4", columns: "10-200", alignment: alignment())
        state.modelChoice = .fixed("HKY+F+G4")
        state.sequenceType = .dna
        state.safeMode = true
        state.keepIdenticalSequences = true
        state.extraIQTreeOptions = "-bnni"
        let launch = launch(try preparedOptions(state), seed: 99)

        let parsed = try RecordedCLICommand.parse(launch.cliCommand, as: TreeCommand.InferIQTreeSubcommand.self)
        XCTAssertEqual(parsed.rows, "row-1,row-2,row-3,row-4")
        XCTAssertEqual(parsed.columns, "10-200")
        XCTAssertEqual(parsed.model, "HKY+F+G4")
        XCTAssertEqual(parsed.sequenceType, "DNA")
        XCTAssertEqual(parsed.bootstrap, 1000)
        XCTAssertEqual(parsed.alrt, 1000)
        XCTAssertEqual(parsed.seed, 99)
        XCTAssertEqual(parsed.globalOptions.threads, 1)
        XCTAssertTrue(parsed.safeMode)
        XCTAssertTrue(parsed.keepIdenticalSequences)
    }

    /// The codon genetic code and the outgroup row IDs parse with the real CLI parser.
    func testRecordedCommandParsesCodonTypeAndOutgroupRowIDs() throws {
        let state = makeState(alignment: alignment(names: ["Homo sapiens", "Macaca mulatta", "Gorilla", "Mus musculus"]))
        state.sequenceType = .codon
        state.geneticCode = .vertebrateMitochondrial
        state.setOutgroup(rowID: "row-4", selected: true)
        let launch = launch(try preparedOptions(state), seed: 5)

        let parsed = try RecordedCLICommand.parse(launch.cliCommand, as: TreeCommand.InferIQTreeSubcommand.self)
        XCTAssertEqual(parsed.sequenceType, "CODON2")
        XCTAssertEqual(parsed.outgroup, "row-4")
    }

    /// The command ViewerViewController.runIQTreeInferenceViaCLI records is
    /// `IQTreeInferenceLaunch.make(...).cliCommand`. Every option the dialog
    /// sets parses back to the same value with the real CLI parser.
    func testRunIQTreeInferenceViaCLIRecordsACommandThatParsesToTheOptions() throws {
        let options = IQTreeInferenceOptions(
            outputName: "alignment-tree",
            rows: "row-1,row-2,row-3,row-4",
            columns: "10-200",
            model: "GTR+F+I+G4",
            sequenceType: "DNA",
            bootstrap: 2000,
            alrt: 1000,
            seed: 31,
            threads: 3,
            outgroup: ["row-2", "row-4"],
            safeMode: true,
            keepIdenticalSequences: true,
            iqtreePath: "/opt/iqtree/bin/iqtree3",
            extraIQTreeOptions: "-bnni"
        )
        let launch = IQTreeInferenceLaunch.make(
            bundleURL: bundleURL,
            projectURL: projectURL,
            outputURL: outputURL,
            outputName: options.outputName,
            options: options,
            drawSeed: { XCTFail("a set seed is never drawn"); return 1 }
        )

        let parsed = try RecordedCLICommand.parse(launch.cliCommand, as: TreeCommand.InferIQTreeSubcommand.self)
        XCTAssertEqual(parsed.msaBundlePath, bundleURL.path)
        XCTAssertEqual(parsed.projectPath, projectURL.path)
        XCTAssertEqual(parsed.outputPath, outputURL.path)
        XCTAssertEqual(parsed.name, options.outputName)
        XCTAssertEqual(parsed.rows, options.rows)
        XCTAssertEqual(parsed.columns, options.columns)
        XCTAssertEqual(parsed.model, options.model)
        XCTAssertEqual(parsed.sequenceType, options.sequenceType)
        XCTAssertEqual(parsed.bootstrap, options.bootstrap)
        XCTAssertEqual(parsed.alrt, options.alrt)
        XCTAssertEqual(parsed.seed, options.seed)
        XCTAssertEqual(parsed.globalOptions.threads, options.threads)
        XCTAssertEqual(parsed.outgroup, options.outgroup.joined(separator: ","))
        XCTAssertEqual(parsed.safeMode, options.safeMode)
        XCTAssertEqual(parsed.keepIdenticalSequences, options.keepIdenticalSequences)
        XCTAssertEqual(parsed.iqtreePath, options.iqtreePath)
        XCTAssertEqual(parsed.extraArgs, options.extraIQTreeOptions)
        XCTAssertFalse(parsed.force)
    }
}
