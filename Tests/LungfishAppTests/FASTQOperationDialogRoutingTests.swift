import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class FASTQOperationDialogRoutingTests: XCTestCase {
    func testDerivativeToolsExposeStandardizedPaneSectionsAndOutputStrategy() {
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        XCTAssertEqual(
            state.visibleSections,
            [.inputs, .primarySettings, .advancedSettings, .output, .readiness]
        )
        XCTAssertEqual(state.inputSectionTitle, "Inputs")
        XCTAssertEqual(state.outputSectionTitle, "Output")
        XCTAssertEqual(state.readinessText, "Ready to configure output.")
        XCTAssertEqual(state.outputStrategyOptions, [.perInput, .groupedResult])
        XCTAssertEqual(state.selectedToolID, .fastpTrim)
    }

    func testTrimFilterDefaultBuildsCombinedFastpAdapterAndQualityRequest() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [inputURL]
        )

        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .fastpTrim(
                    threshold: 20,
                    windowSize: 4,
                    mode: .cutRight,
                    adapterMode: .autoDetect,
                    adapterSequence: nil
                ),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
    }

    func testSubsampleByProportionWaitsForARealProportionBeforeBuildingLaunchRequest() {
        let state = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.subsampleByProportion)
        state.prepareForRun()

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertNil(state.pendingLaunchRequest)

        state.subsampleByProportionValue = 0.25
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .subsampleProportion(0.25),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testLengthFilterRemainsDisabledUntilARealRangeIsEntered() {
        let state = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.filterByReadLength)
        state.prepareForRun()

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertNil(state.pendingLaunchRequest)

        state.filterByReadLengthMin = 100
        state.filterByReadLengthMax = 500
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .lengthFilter(min: 100, max: 500),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testAdapterRemovalRequiresManualAdapterSequence() {
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.adapterRemoval)
        state.adapterRemovalMode = .specified
        state.prepareForRun()

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertNil(state.pendingLaunchRequest)

        state.adapterRemovalSequence = "AGATCGGAAGAGC"
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .adapterTrim(mode: .specified, sequence: "AGATCGGAAGAGC", sequenceR2: nil, fastaFilename: nil),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testPrimerTrimmingLiteralModeDoesNotRequireAuxiliaryPrimerInput() {
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.primerTrimming)

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset])
        XCTAssertFalse(state.isRunEnabled)

        state.primerTrimmingLiteralSequence = "AGATCGGAAGAGC"
        state.prepareForRun()

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .primerRemoval(configuration: FASTQPrimerTrimConfiguration(
                    source: .literal,
                    forwardSequence: "AGATCGGAAGAGC",
                    tool: .bbduk,
                    kmerSize: 15,
                    minKmer: 11,
                    hammingDistance: 1
                )),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testPrimerTrimmingReferenceModeRequiresPrimerInputSelection() {
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.primerTrimming)
        state.primerTrimmingSource = .reference

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset, .primerSource])
        XCTAssertFalse(state.isRunEnabled)

        state.setAuxiliaryInput(URL(fileURLWithPath: "/tmp/primers.fasta"), for: .primerSource)
        state.prepareForRun()

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .primerRemoval(configuration: FASTQPrimerTrimConfiguration(
                    source: .reference,
                    mode: .linked,
                    referenceFasta: "/tmp/primers.fasta",
                    tool: .cutadapt
                )),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testSwitchingAwayAndBackPreservesSpecializedAuxiliarySelections() {
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )
        let primerURL = URL(fileURLWithPath: "/tmp/primers.fasta")

        state.selectTool(.primerTrimming)
        state.primerTrimmingSource = .reference
        state.setAuxiliaryInput(primerURL, for: .primerSource)

        state.selectTool(.qualityTrim)
        state.selectTool(.primerTrimming)
        state.primerTrimmingSource = .reference

        XCTAssertEqual(state.auxiliaryInputURL(for: .primerSource), primerURL)
        XCTAssertTrue(state.isRunEnabled)
    }

    func testSearchTextRemainsDisabledUntilQueryAndFieldAreSet() {
        let state = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.extractReadsByID)
        state.prepareForRun()

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertNil(state.pendingLaunchRequest)

        state.extractReadsByIDQuery = "SRR1770413"
        state.extractReadsByIDField = .description
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .searchText(query: "SRR1770413", field: .description, regex: false),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testSelectReadsBySequenceUsesEnteredSequenceAndParameters() {
        let state = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.selectReadsBySequence)
        state.prepareForRun()

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertNil(state.pendingLaunchRequest)

        state.selectReadsBySequenceValue = "AGATCGGAAGAGC"
        state.selectReadsBySequenceSearchEnd = .fivePrime
        state.selectReadsBySequenceMinOverlap = 16
        state.selectReadsBySequenceErrorRate = 0.15
        state.selectReadsBySequenceKeepMatched = true
        state.selectReadsBySequenceSearchReverseComplement = false
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .sequencePresenceFilter(
                    sequence: "AGATCGGAAGAGC",
                    fastaPath: nil,
                    searchEnd: .fivePrime,
                    minOverlap: 16,
                    errorRate: 0.15,
                    keepMatched: true,
                    searchReverseComplement: false
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testOrientingRequiresReferenceSequenceBeforeRunCanProceed() {
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.orientReads)

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset, .referenceSequence])
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Select a reference sequence to continue.")

        state.setAuxiliaryInput(
            URL(fileURLWithPath: "/tmp/reference.fasta"),
            for: .referenceSequence
        )

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(state.auxiliaryInputURL(for: .referenceSequence)?.lastPathComponent, "reference.fasta")
        XCTAssertEqual(state.readinessText, "Ready to configure output.")
    }

    /// Regression test for AS22: prepareForRun()'s mafft branch checked
    /// selectedToolConfigurationIsReady (FASTQ-input confirmation, thread
    /// count, advanced-options parseability) but never checked for a
    /// non-nil projectURL, while makeMSAAlignmentRequest() does
    /// `guard let projectURL else { return nil }`. With no project open,
    /// isRunEnabled/readinessText previously reported "ready" while Run
    /// silently produced no pending request at all.
    func testMAFFTRequiresProjectBeforeRunCanProceed() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [inputURL],
            projectURL: nil
        )

        state.selectTool(.mafft)

        XCTAssertFalse(state.isRunEnabled, "MAFFT must not report ready with no project open")
        XCTAssertNotEqual(state.readinessText, "Ready to configure output.")

        state.prepareForRun()
        XCTAssertNil(state.pendingMSAAlignmentRequest, "Run must not silently no-op with a stale/absent pending request")
    }

    func testMAFFTBuildsAlignmentRequestOnceProjectIsSet() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.fasta")
        let projectURL = URL(fileURLWithPath: "/tmp/Fixture.lungfish", isDirectory: true)
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [inputURL],
            projectURL: projectURL
        )

        state.selectTool(.mafft)

        XCTAssertTrue(state.isRunEnabled)
        state.prepareForRun()
        XCTAssertNotNil(state.pendingMSAAlignmentRequest)
    }

    func testQualityTrimRoutesExtraArgumentsIntoLaunchRequest() {
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.qualityTrim)
        state.qualityTrimExtraArguments = "--length_required 75"
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .qualityTrim(
                    threshold: 20,
                    windowSize: 4,
                    mode: .cutRight,
                    extraArguments: ["--length_required", "75"]
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testOrientRoutesExtraArgumentsIntoLaunchRequest() {
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.orientReads)
        state.setAuxiliaryInput(URL(fileURLWithPath: "/tmp/reference.fasta"), for: .referenceSequence)
        state.orientExtraArguments = "--id 0.97"
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .orient(
                    referenceURL: URL(fileURLWithPath: "/tmp/reference.fasta"),
                    wordLength: 12,
                    dbMask: "dust",
                    saveUnoriented: false,
                    extraArguments: ["--id", "0.97"]
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testPBAABuildsLaunchRequestWithSimpleAndAdvancedOptions() throws {
        let input = URL(fileURLWithPath: "/tmp/reads.fastq")
        let guide = URL(fileURLWithPath: "/tmp/guide.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .clustering,
            selectedInputURLs: [input],
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )

        state.selectTool(.pbaa)
        state.setAuxiliaryInput(guide, for: .referenceSequence)
        state.pbaaOutputName = "sample clusters"
        state.pbaaThreads = 4
        state.pbaaSeed = 7
        state.pbaaExtraArguments = "--min-cluster-read-count 2"
        state.prepareForRun()

        guard case .pbaa(let request)? = state.pendingLaunchRequest else {
            return XCTFail("Expected pbaa launch request")
        }

        XCTAssertEqual(request.inputFASTQURL, input)
        XCTAssertEqual(request.guideSourceURL, guide)
        XCTAssertEqual(request.outputName, "sample-clusters")
        XCTAssertEqual(request.threads, 4)
        XCTAssertEqual(request.seed, 7)
        XCTAssertEqual(request.extraArguments, ["--min-cluster-read-count", "2"])
    }

    func testSavontDefaultsAndRetainsEverySelectedInput() async throws {
        let inputs = [
            URL(fileURLWithPath: "/tmp/barcode01.fastq.gz"),
            URL(fileURLWithPath: "/tmp/barcode02.lungfishfastq", isDirectory: true),
        ]
        let state = FASTQOperationDialogState(
            initialCategory: .clustering,
            selectedInputURLs: inputs,
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            workflowLibrary: AllEnabledFASTQWorkflowLibrary(),
            savontRuntimeStatusProvider: ReadySavontRuntimeStatusProvider()
        )

        state.selectTool(.savont)
        await state.refreshSavontRuntimeReadiness()

        XCTAssertEqual(state.savontQualityValueCutoff, 90)
        XCTAssertEqual(state.savontMinimumClusterSize, 3)
        XCTAssertNil(state.savontMinimumReadLength)
        XCTAssertNil(state.savontMaximumReadLength)
        XCTAssertFalse(state.savontSingleStrand)
        XCTAssertNil(state.savontSingleInputOutputName)
        XCTAssertEqual(state.outputMode, .perInput)
        XCTAssertFalse(state.showsOutputStrategyPicker)
        XCTAssertTrue(state.isRunEnabled)

        state.prepareForRun()

        guard case .savont(let request)? = state.pendingLaunchRequest else {
            return XCTFail("Expected Savont launch request")
        }
        XCTAssertEqual(request.inputURLs, inputs)
        XCTAssertEqual(request.outputDirectoryURL, URL(fileURLWithPath: "/tmp/project/Analyses", isDirectory: true))
        XCTAssertNil(request.singleInputOutputName)
        XCTAssertEqual(request.threads, max(1, ProcessInfo.processInfo.activeProcessorCount))
        XCTAssertEqual(request.qualityValueCutoff, 90)
        XCTAssertEqual(request.minimumClusterSize, 3)
        XCTAssertNil(request.minimumReadLength)
        XCTAssertNil(request.maximumReadLength)
        XCTAssertFalse(request.singleStrand)
    }

    func testSavontSingleInputUsesEditableOutputNameAndAdvancedOptions() async throws {
        let input = URL(fileURLWithPath: "/tmp/barcode12.fastq.gz")
        let state = FASTQOperationDialogState(
            initialCategory: .clustering,
            selectedInputURLs: [input],
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            workflowLibrary: AllEnabledFASTQWorkflowLibrary(),
            savontRuntimeStatusProvider: ReadySavontRuntimeStatusProvider()
        )

        state.selectTool(.savont)
        await state.refreshSavontRuntimeReadiness()
        XCTAssertEqual(state.savontSingleInputOutputName, "barcode12-savont-clusters")

        state.savontSingleInputOutputName = "curated-clusters"
        state.savontThreads = 6
        state.savontQualityValueCutoff = 95
        state.savontMinimumClusterSize = 4
        state.savontMinimumReadLength = 400
        state.savontMaximumReadLength = 2_000
        state.savontSingleStrand = true
        state.prepareForRun()

        guard case .savont(let request)? = state.pendingLaunchRequest else {
            return XCTFail("Expected Savont launch request")
        }
        XCTAssertEqual(request.singleInputOutputName, "curated-clusters")
        XCTAssertEqual(request.threads, 6)
        XCTAssertEqual(request.qualityValueCutoff, 95)
        XCTAssertEqual(request.minimumClusterSize, 4)
        XCTAssertEqual(request.minimumReadLength, 400)
        XCTAssertEqual(request.maximumReadLength, 2_000)
        XCTAssertTrue(request.singleStrand)
    }

    func testSavontRejectsUnsafeSingleInputOutputNames() {
        for unsafeName in [
            "../outside.fasta",
            "nested/name",
            "/tmp/absolute.fasta",
            ".",
            "..",
            "   ",
        ] {
            let state = FASTQOperationDialogState(
                initialCategory: .clustering,
                selectedInputURLs: [URL(fileURLWithPath: "/tmp/barcode12.fastq")],
                projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
                workflowLibrary: AllEnabledFASTQWorkflowLibrary()
            )
            state.selectTool(.savont)
            state.savontSingleInputOutputName = unsafeName

            XCTAssertFalse(state.isRunEnabled, "Expected Savont to reject \(unsafeName.debugDescription)")
            state.prepareForRun()
            XCTAssertNil(state.pendingLaunchRequest)
        }
    }

    func testSavontAcceptsSafeLeafOutputNameWithFastaExtension() async {
        let state = FASTQOperationDialogState(
            initialCategory: .clustering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/barcode12.fastq")],
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            workflowLibrary: AllEnabledFASTQWorkflowLibrary(),
            savontRuntimeStatusProvider: ReadySavontRuntimeStatusProvider()
        )
        state.selectTool(.savont)
        await state.refreshSavontRuntimeReadiness()
        state.savontSingleInputOutputName = "curated.fasta"

        XCTAssertTrue(state.isRunEnabled)
        state.prepareForRun()

        guard case .savont(let request)? = state.pendingLaunchRequest else {
            return XCTFail("Expected Savont launch request")
        }
        XCTAssertEqual(request.singleInputOutputName, "curated.fasta")
    }

    func testSavontRejectsInvalidBoundsAndNonFASTQInputs() {
        let state = FASTQOperationDialogState(
            initialCategory: .clustering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/barcode12.fastq")],
            workflowLibrary: AllEnabledFASTQWorkflowLibrary()
        )
        state.selectTool(.savont)

        state.savontMinimumReadLength = 2_000
        state.savontMaximumReadLength = 400
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertTrue(state.readinessText.contains("Minimum read length"))

        state.savontMinimumReadLength = nil
        state.savontMaximumReadLength = nil
        state.savontThreads = 0
        XCTAssertFalse(state.isRunEnabled)

        let fastaState = FASTQOperationDialogState(
            initialCategory: .clustering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fasta")],
            workflowLibrary: AllEnabledFASTQWorkflowLibrary()
        )
        XCTAssertFalse(fastaState.visibleToolIDs.contains(.savont))
    }

    func testReverseComplementBuildsGenericOperationLaunchRequest() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.reverseComplement)
        state.prepareForRun()

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .reverseComplement,
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
    }

    func testTranslateBuildsGenericFASTAOutputLaunchRequest() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.translate)
        state.prepareForRun()

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .translate(frameOffset: 0),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
    }

    func testOrientingRejectsInvalidReferenceSelection() {
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.orientReads)
        state.setAuxiliaryInput(URL(fileURLWithPath: "/tmp/not-a-reference.pdf"), for: .referenceSequence)

        XCTAssertFalse(state.isAuxiliaryInputValid(for: .referenceSequence))
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Select a reference sequence to continue.")
    }

    func testPhixContaminantModeDoesNotRequireCustomReferenceSelection() throws {
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.removeContaminants)

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset])
        XCTAssertTrue(state.isRunEnabled)

        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .contaminantFilter(
                    mode: .phix,
                    referenceFasta: nil,
                    kmerSize: 31,
                    hammingDistance: 1
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )

        let launchRequest = try XCTUnwrap(state.pendingLaunchRequest)
        let invocation = try FASTQOperationExecutionService().buildInvocation(for: launchRequest)
        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(
            invocation.arguments,
            [
                "contaminant-filter",
                "/tmp/sample.lungfishfastq",
                "--mode",
                "phix",
                "--kmer",
                "31",
                "--hdist",
                "1",
                "-o",
                "<derived>",
            ]
        )
        XCTAssertFalse(invocation.arguments.contains("--ref"))
    }

    func testCustomContaminantModeRequiresReferenceSelection() {
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.removeContaminants)
        state.removeContaminantsMode = .custom

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset, .contaminantReference])
        XCTAssertFalse(state.isRunEnabled)

        state.setAuxiliaryInput(URL(fileURLWithPath: "/tmp/contaminants.fasta"), for: .contaminantReference)
        state.prepareForRun()

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .contaminantFilter(
                    mode: .custom,
                    referenceFasta: "/tmp/contaminants.fasta",
                    kmerSize: 31,
                    hammingDistance: 1
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testLowComplexityFilterRoutesToEntropyFilterWithBenchmarkedDefaults() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.removeLowComplexityReads)

        // Entropy filtering needs no auxiliary reference, so it is runnable at once.
        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset])
        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(state.removeLowComplexityEntropy, 0.6, accuracy: 0.0001)
        XCTAssertEqual(state.removeLowComplexityWindow, 50)
        XCTAssertEqual(state.removeLowComplexityKmer, 5)

        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .lowComplexityFilter(entropy: 0.6, window: 50, kmer: 5),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )

        let launchRequest = try XCTUnwrap(state.pendingLaunchRequest)
        let invocation = try FASTQOperationExecutionService().buildInvocation(for: launchRequest)
        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(
            invocation.arguments,
            [
                "entropy-filter",
                "/tmp/sample.lungfishfastq",
                "--entropy",
                "0.6",
                "--window",
                "50",
                "--kmer",
                "5",
                "-o",
                "<derived>",
            ]
        )
    }

    func testLowComplexityFilterCarriesAdvancedWindowAndKmerIntoRequest() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.removeLowComplexityReads)
        state.removeLowComplexityEntropy = 0.75
        state.removeLowComplexityWindow = 40
        state.removeLowComplexityKmer = 4
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .lowComplexityFilter(entropy: 0.75, window: 40, kmer: 4),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
    }

    func testLowComplexityFilterRejectsEntropyOutsideSupportedRange() {
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.removeLowComplexityReads)
        state.removeLowComplexityEntropy = 0.1

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Entropy threshold must be between 0.3 and 0.9.")
    }

    func testLowComplexityFilterAppearsInDecontaminationCategory() {
        XCTAssertTrue(
            FASTQOperationDialogState.toolIDs(for: .decontamination)
                .contains(.removeLowComplexityReads)
        )
        XCTAssertEqual(FASTQOperationToolID.removeLowComplexityReads.categoryID, .decontamination)
    }

    func testRibosomalRNAFilterDefaultsToDeaconRiboDepletion() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.removeRibosomalRNA)

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset])
        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(state.riboDetectorRetention, .nonRRNA)
        XCTAssertFalse(state.showsOutputStrategyPicker)

        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .ribosomalRNAFilter(retention: .nonRRNA, ensure: .rrna),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )

        let launchRequest = try XCTUnwrap(state.pendingLaunchRequest)
        let invocation = try FASTQOperationExecutionService().buildInvocation(for: launchRequest)
        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(
            invocation.arguments,
            [
                "deacon-ribo",
                "/tmp/sample.lungfishfastq",
                "--database-id",
                "deacon-ribokmers",
                "--retain",
                "norrna",
                "-o",
                "<derived>",
            ]
        )
    }

    func testRibosomalRNAFilterCanRetainBothRRNAAndNonRRNA() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.removeRibosomalRNA)
        state.riboDetectorRetention = .both
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .ribosomalRNAFilter(retention: .both, ensure: .rrna),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
    }

    func testDemultiplexBuiltInKitDoesNotRequireBarcodeDefinitionSelection() {
        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.demultiplexBarcodes)
        state.demultiplexKitID = "rapid-kit"

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset])
        XCTAssertTrue(state.isRunEnabled)

        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .demultiplex(
                    kitID: "rapid-kit",
                    customCSVPath: nil,
                    location: "bothends",
                    symmetryMode: nil,
                    maxDistanceFrom5Prime: 0,
                    maxDistanceFrom3Prime: 0,
                    errorRate: 0.15,
                    engine: .cutadapt,
                    trimBarcodes: true,
                    sampleAssignments: nil,
                    kitOverride: nil
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testDemultiplexCustomBarcodeDefinitionUsesAuxiliaryInput() {
        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.demultiplexBarcodes)
        state.demultiplexBarcodeSource = .customDefinition

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset, .barcodeDefinition])
        XCTAssertFalse(state.isRunEnabled)

        state.setAuxiliaryInput(URL(fileURLWithPath: "/tmp/barcodes.csv"), for: .barcodeDefinition)
        state.prepareForRun()

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .demultiplex(
                    kitID: "barcodes",
                    customCSVPath: "/tmp/barcodes.csv",
                    location: "bothends",
                    symmetryMode: nil,
                    maxDistanceFrom5Prime: 0,
                    maxDistanceFrom3Prime: 0,
                    errorRate: 0.15,
                    engine: .cutadapt,
                    trimBarcodes: true,
                    sampleAssignments: nil,
                    kitOverride: nil
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testONTFluidigmSampleSplitUsesBarcodeDefinitionAndFixedBatchOutput() {
        let inputURL = URL(fileURLWithPath: "/tmp/barcode11.lungfishfastq", isDirectory: true)
        let barcodeURL = URL(fileURLWithPath: "/tmp/ONT09_NB11_samples.csv")
        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.ontFluidigmSampleSplit)

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset, .barcodeDefinition])
        XCTAssertEqual(state.outputMode, .fixedBatch)
        XCTAssertEqual(state.readinessText, "Select a Fluidigm sample barcode CSV or TSV.")
        XCTAssertFalse(FASTQOperationToolID.ontFluidigmSampleSplit.supportsFASTA)

        state.setAuxiliaryInput(barcodeURL, for: .barcodeDefinition)
        state.prepareForRun()

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .ontFluidigmSampleSplit(
                inputFASTQURL: inputURL,
                barcodeDefinitionsURL: barcodeURL,
                threads: max(1, ProcessInfo.processInfo.activeProcessorCount)
            )
        )
    }

    func testDemultiplexSelectedEngineRoutesIntoLaunchRequest() {
        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.demultiplexBarcodes)
        state.demultiplexKitID = "fluidigm-access-array"
        state.demultiplexEngine = .exactBareBarcode
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .demultiplex(
                    kitID: "fluidigm-access-array",
                    customCSVPath: nil,
                    location: "bothends",
                    symmetryMode: nil,
                    maxDistanceFrom5Prime: 0,
                    maxDistanceFrom3Prime: 0,
                    errorRate: 0.15,
                    engine: .exactBareBarcode,
                    trimBarcodes: false,
                    sampleAssignments: nil,
                    kitOverride: nil
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testExactBareBarcodeEngineUsesCompatibleBuiltInKitAndPreservesReads() {
        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.demultiplexBarcodes)
        state.demultiplexKitID = "truseq-single-a"
        state.demultiplexEngine = .exactBareBarcode
        state.prepareForRun()

        XCTAssertEqual(state.demultiplexBuiltInKitOptions.map(\.id), ["fluidigm-access-array"])
        XCTAssertEqual(state.demultiplexKitID, "fluidigm-access-array")
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .demultiplex(
                    kitID: "fluidigm-access-array",
                    customCSVPath: nil,
                    location: "bothends",
                    symmetryMode: nil,
                    maxDistanceFrom5Prime: 0,
                    maxDistanceFrom3Prime: 0,
                    errorRate: 0.15,
                    engine: .exactBareBarcode,
                    trimBarcodes: false,
                    sampleAssignments: nil,
                    kitOverride: nil
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    // The recursive barcode-definition-candidate scan (F8) no longer runs synchronously
    // during `init` -- it starts as an empty array and is populated by
    // `refreshProjectBarcodeDefinitionCandidates()`, which the dialog's `.task` awaits once
    // the view appears. These two tests were written against the old synchronous contract;
    // they now explicitly await that same call to drive the (now-async) scan before asserting
    // on its result, exercising the exact API the dialog itself uses.

    func testProjectBarcodeDefinitionCandidatesIncludeTextBarcodeFiles() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationDialogRouting-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let downloadsURL = projectURL.appendingPathComponent("Downloads", isDirectory: true)
        let hiddenURL = projectURL.appendingPathComponent(".lungfish-cache", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hiddenURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let rootBarcodeURL = projectURL.appendingPathComponent("fluidigm.tsv")
        let nestedBarcodeURL = downloadsURL.appendingPathComponent("fluidigm-subset.csv")
        try "FLD0001\tGTATCGTCGT\n".write(to: rootBarcodeURL, atomically: true, encoding: .utf8)
        try "FLD0002,GTGTATGCGT\n".write(to: nestedBarcodeURL, atomically: true, encoding: .utf8)
        try "hidden\tGTATCGTCGT\n".write(
            to: hiddenURL.appendingPathComponent("hidden.tsv"),
            atomically: true,
            encoding: .utf8
        )
        try "inside\tGTATCGTCGT\n".write(
            to: bundleURL.appendingPathComponent("inside.tsv"),
            atomically: true,
            encoding: .utf8
        )

        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            projectURL: projectURL
        )
        XCTAssertEqual(state.projectBarcodeDefinitionCandidates, [], "scan must not run synchronously during init")
        await state.refreshProjectBarcodeDefinitionCandidates()

        XCTAssertEqual(
            state.projectBarcodeDefinitionCandidates.map { FASTQOperationDialogState.displayPath(for: $0, relativeTo: projectURL) },
            ["Downloads/fluidigm-subset.csv", "fluidigm.tsv"]
        )
    }

    func testProjectBarcodeDefinitionCandidatesDoNotRefreshDuringUnrelatedTextEdits() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationDialogRouting-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let firstBarcodeURL = projectURL.appendingPathComponent("initial-barcodes.tsv")
        let laterBarcodeURL = projectURL.appendingPathComponent("later-barcodes.tsv")
        try "FLD0001\tGTATCGTCGT\n".write(to: firstBarcodeURL, atomically: true, encoding: .utf8)

        let state = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            projectURL: projectURL
        )
        state.selectTool(.ontGenotyping)
        await state.refreshProjectBarcodeDefinitionCandidates()

        XCTAssertEqual(state.projectBarcodeDefinitionCandidates, [firstBarcodeURL.standardizedFileURL])

        try "FLD0002\tGTGTATGCGT\n".write(to: laterBarcodeURL, atomically: true, encoding: .utf8)
        state.ontGenotypingOutputName = "typed-report-name"

        XCTAssertEqual(
            state.projectBarcodeDefinitionCandidates,
            [firstBarcodeURL.standardizedFileURL],
            "Typing into MHC genotyping fields should not rescan the whole project for barcode files."
        )
    }

    func testONTGenotypingAllowsMultiplePreparedONTSampleInputsWithoutBarcodes() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationDialogRouting-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let referenceURL = projectURL.appendingPathComponent("Reference Sequences/mhc.lungfishmhcref", isDirectory: true)
        let firstReadsURL = projectURL.appendingPathComponent("Reads/LF2871.lungfishfastq", isDirectory: true)
        let secondReadsURL = projectURL.appendingPathComponent("Reads/LF2872.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstReadsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondReadsURL, withIntermediateDirectories: true)

        let state = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [firstReadsURL, secondReadsURL],
            projectURL: projectURL
        )
        state.selectTool(.ontGenotyping)
        state.setAuxiliaryInput(referenceURL, for: .referenceSequence)
        state.ontGenotypingOutputName = "amplicon-genotyping"
        state.ontGenotypingAnalysisName = "amplicon-genotyping"

        state.prepareForRun()

        guard case .ontGenotyping(let request) = state.pendingLaunchRequest else {
            return XCTFail("Expected amplicon genotyping launch request")
        }
        XCTAssertEqual(request.inputFASTQURLs, [
            firstReadsURL.standardizedFileURL,
            secondReadsURL.standardizedFileURL,
        ])
        XCTAssertNil(request.barcodeDefinitionsURL)
        XCTAssertEqual(request.mode, .ontSampleBundles)
        XCTAssertEqual(request.readType, .ont)
        XCTAssertNil(request.haplotypeDropoutLocusFraction)
        XCTAssertTrue(request.haplotypeDropoutLocusFractionOverrides.isEmpty)
    }

    func testONTGenotypingAllowsSelectedFolderOfPreparedONTSamplesWithoutBarcodes() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationDialogRouting-\(UUID().uuidString).lungfish", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        let referenceURL = projectURL.appendingPathComponent("Reference Sequences/mhc.lungfishmhcref", isDirectory: true)
        let demultiplexedFolderURL = projectURL.appendingPathComponent("Reads/Demultiplexed ONT", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: demultiplexedFolderURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(
            to: demultiplexedFolderURL.appendingPathComponent("LF2871.fastq"),
            atomically: true,
            encoding: .utf8
        )
        try "@r2\nTGCA\n+\nIIII\n".write(
            to: demultiplexedFolderURL.appendingPathComponent("LF2872.fastq"),
            atomically: true,
            encoding: .utf8
        )

        let state = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [demultiplexedFolderURL],
            projectURL: projectURL
        )
        state.selectTool(.ontGenotyping)
        state.setAuxiliaryInput(referenceURL, for: .referenceSequence)

        state.prepareForRun()

        guard case .ontGenotyping(let request) = state.pendingLaunchRequest else {
            return XCTFail("Expected amplicon genotyping launch request")
        }
        XCTAssertEqual(request.inputFASTQURLs, [demultiplexedFolderURL.standardizedFileURL])
        XCTAssertNil(request.barcodeDefinitionsURL)
        XCTAssertEqual(request.mode, .ontSampleBundles)
        XCTAssertEqual(request.readType, .ont)
    }

    func testDeduplicatePresetSynthesizesCliCompatibleValues() {
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.removeDuplicates)
        state.removeDuplicatesPreset = .opticalNovaSeq
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .deduplicate(
                    preset: .opticalNovaSeq,
                    substitutions: 0,
                    optical: true,
                    opticalDistance: 12000
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
    }

    func testClassificationToolsUseFixedBatchOutputModeAndHideOutputStrategyPicker() {
        let state = FASTQOperationDialogState(
            initialCategory: .classification,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        for toolID in [FASTQOperationToolID.kraken2, .esViritu, .taxTriage] {
            state.selectTool(toolID)

            XCTAssertEqual(state.outputMode, .fixedBatch, "\(toolID.rawValue) should force fixedBatch output mode")
            XCTAssertFalse(state.showsOutputStrategyPicker, "\(toolID.rawValue) should hide the output strategy picker")
            state.outputMode = .perInput
            XCTAssertEqual(state.outputMode, .fixedBatch, "\(toolID.rawValue) should clamp outputMode back to fixedBatch")
            XCTAssertFalse(state.showsOutputStrategyPicker, "\(toolID.rawValue) should keep the output strategy picker hidden")
        }
    }

    func testMappingDefaultsToPerInputOutputModeAndRequiresReferenceSelection() {
        let state = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.minimap2)

        XCTAssertEqual(state.outputMode, .perInput)
        XCTAssertTrue(state.showsOutputStrategyPicker)
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertTrue(state.requiredInputKinds.contains(.referenceSequence))

        state.outputMode = .groupedResult
        XCTAssertEqual(state.outputMode, .groupedResult)
    }

    func testMappingCategoryExposesAllV1Mappers() {
        XCTAssertEqual(
            FASTQOperationDialogState.toolIDs(for: .mapping),
            [.minimap2, .bwaMem2, .bowtie2, .bbmap, .viralRecon]
        )
    }

    func testGenotypingDialogShowsBundledONTByDefaultAndHonorsExplicitLibraryDisable() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FASTQOperationDialogRoutingTests-\(UUID().uuidString)"))
        let workflowLibrary = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let defaultState = FASTQOperationDialogState(
            initialCategory: .genotyping,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            workflowLibrary: workflowLibrary
        )

        XCTAssertTrue(defaultState.visibleToolIDs.contains(.ontGenotyping))

        workflowLibrary.setWorkflow(.ontGenotyping, enabled: false)
        let disabledState = FASTQOperationDialogState(
            initialCategory: .genotyping,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            workflowLibrary: workflowLibrary
        )

        XCTAssertFalse(disabledState.visibleToolIDs.contains(.ontGenotyping))

        workflowLibrary.setWorkflow(.ontGenotyping, enabled: true)
        let enabledState = FASTQOperationDialogState(
            initialCategory: .genotyping,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            workflowLibrary: workflowLibrary
        )

        XCTAssertTrue(enabledState.visibleToolIDs.contains(.ontGenotyping))
    }

    func testViralReconAppearsInMappingTools() {
        let mappingTools = FASTQOperationDialogState.toolIDs(for: .mapping)

        XCTAssertTrue(mappingTools.contains(.viralRecon))
        XCTAssertEqual(FASTQOperationToolID.viralRecon.categoryID, .mapping)
        XCTAssertEqual(FASTQOperationToolID.viralRecon.title, "Viral Recon")
        XCTAssertEqual(FASTQOperationToolID.viralRecon.subtitle, "Run SARS-CoV-2 viral consensus and variant analysis.")
        XCTAssertTrue(FASTQOperationToolID.viralRecon.usesEmbeddedConfiguration)
        XCTAssertEqual(FASTQOperationToolID.viralRecon.embeddedReadinessText, "Complete the viral recon settings to continue.")
    }

    func testViralReconPendingRequestControlsRunReadiness() throws {
        let state = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/A.lungfishfastq")]
        )
        state.selectTool(.viralRecon)

        XCTAssertFalse(state.isRunEnabled)
        state.captureViralReconRequest(try ViralReconAppTestFixtures.illuminaRequest(root: URL(fileURLWithPath: "/tmp")))

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertNotNil(state.pendingViralReconRequest)
    }

    func testViralReconPlatformOverrideDoesNotMaskMixedDetectedPlatforms() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralReconPlatformOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let illuminaFASTQ = root.appendingPathComponent("illumina.fastq")
        let nanoporeFASTQ = root.appendingPathComponent("nanopore.fastq")
        try """
        @A00488:17:H7WFLDMXX:1:1101:10000:1000 1:N:0:ATCACG
        ACGT
        +
        !!!!
        """.write(to: illuminaFASTQ, atomically: true, encoding: .utf8)
        try """
        @9b50942a-4ec6-48d2-8f3b-4ff4f63cb17a runid=2de0f6d4 sampleid=sample1 read=1 ch=12 start_time=2024-01-01T00:00:00Z flow_cell_id=FLO-MIN114
        ACGT
        +
        !!!!
        """.write(to: nanoporeFASTQ, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try ViralReconWizardInputPolicy.resolveInputs(
                [illuminaFASTQ, nanoporeFASTQ],
                platformOverride: .illumina
            )
        ) { error in
            XCTAssertEqual(error as? ViralReconInputResolver.ResolveError, .mixedPlatforms)
        }
    }

    func testViralReconPrimerCompatibilityRejectsIncompatibleGenomeAccession() {
        let manifest = PrimerSchemeManifest(
            schemaVersion: 1,
            name: "qia-seq-direct-sars2",
            displayName: "QIASeq DIRECT SARS-CoV-2",
            referenceAccessions: [
                PrimerSchemeManifest.ReferenceAccession(accession: "MN908947.3", canonical: true),
                PrimerSchemeManifest.ReferenceAccession(accession: "NC_045512.2", equivalent: true),
            ],
            primerCount: 2,
            ampliconCount: 1
        )

        XCTAssertThrowsError(
            try ViralReconWizardPrimerCompatibility.validateGenomeAccession(
                "MT192765.1",
                manifest: manifest
            )
        ) { error in
            XCTAssertEqual(
                error as? ViralReconWizardPrimerCompatibility.ValidationError,
                .unknownAccession(requested: "MT192765.1", known: ["MN908947.3", "NC_045512.2"])
            )
        }
    }

    func testViralReconPrimerDerivationUsesTheProjectCanonicalReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralReconGenomePrimerDerivation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let primerBundle = root.appendingPathComponent("sars2.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: primerBundle, withIntermediateDirectories: true)
        let manifestData = try JSONEncoder().encode(Self.sarsCoV2PrimerManifest())
        try manifestData.write(to: primerBundle.appendingPathComponent("manifest.json"))
        try "Test primer scheme\n".write(
            to: primerBundle.appendingPathComponent("PROVENANCE.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        MN908947.3\t0\t4\tamplicon_1_LEFT\t1\t+
        MN908947.3\t4\t8\tamplicon_1_RIGHT\t1\t-
        """.write(to: primerBundle.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)

        let project = root.appendingPathComponent("Project", isDirectory: true)
        try Self.writeCanonicalReferenceBundle(
            inProject: project,
            sequence: "AAAACCCCGGGGTTTT"
        )

        let selection = try ViralReconWizardPrimerStaging.stageForCanonicalReference(
            primerBundleURL: primerBundle,
            projectURL: project,
            destinationDirectory: root
        )

        XCTAssertTrue(selection.derivedFasta)
        let stagedBED = try String(contentsOf: selection.bedURL, encoding: .utf8)
        XCTAssertTrue(stagedBED.contains("MN908947.3\t0\t4\tamplicon_1_LEFT"))
        XCTAssertFalse(stagedBED.contains("NC_045512.2\t0\t4\tamplicon_1_LEFT"))
        let stagedFASTA = try String(contentsOf: selection.fastaURL, encoding: .utf8)
        XCTAssertTrue(stagedFASTA.contains(">amplicon_1_LEFT\nAAAA"))
        XCTAssertTrue(stagedFASTA.contains(">amplicon_1_RIGHT\nGGGG"))

        XCTAssertEqual(selection.bedURL.lastPathComponent, "primers.bed")
    }

    // With no reference bundle in the project the wizard cannot cut primer
    // sequences yet, so it stages the BED and leaves the FASTA to the launch
    // path, which is the only place that downloads the reference.
    func testViralReconPrimerStagingDefersFASTAWhenReferenceIsNotYetPresent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralReconDeferredPrimerFASTA-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let primerBundle = root.appendingPathComponent("sars2.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: primerBundle, withIntermediateDirectories: true)
        try JSONEncoder().encode(Self.sarsCoV2PrimerManifest())
            .write(to: primerBundle.appendingPathComponent("manifest.json"))
        try "Test primer scheme\n".write(
            to: primerBundle.appendingPathComponent("PROVENANCE.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        MN908947.3\t0\t4\tamplicon_1_LEFT\t1\t+
        MN908947.3\t4\t8\tamplicon_1_RIGHT\t1\t-
        """.write(to: primerBundle.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)

        let selection = try ViralReconWizardPrimerStaging.stageForCanonicalReference(
            primerBundleURL: primerBundle,
            projectURL: root.appendingPathComponent("EmptyProject", isDirectory: true),
            destinationDirectory: root
        )

        XCTAssertTrue(selection.derivedFasta)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selection.bedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selection.fastaURL.path))
        XCTAssertEqual(selection.leftSuffix, "_LEFT")
        XCTAssertEqual(selection.rightSuffix, "_RIGHT")
    }

    func testViralReconPrimerDerivationAcceptsGzippedCanonicalReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralReconGzippedGenomePrimerDerivation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let primerBundle = root.appendingPathComponent("sars2.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: primerBundle, withIntermediateDirectories: true)
        try JSONEncoder().encode(Self.sarsCoV2PrimerManifest())
            .write(to: primerBundle.appendingPathComponent("manifest.json"))
        try "Test primer scheme\n".write(
            to: primerBundle.appendingPathComponent("PROVENANCE.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        MN908947.3\t0\t4\tamplicon_1_LEFT\t1\t+
        MN908947.3\t4\t8\tamplicon_1_RIGHT\t1\t-
        """.write(to: primerBundle.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)

        let project = root.appendingPathComponent("Project", isDirectory: true)
        let referenceBundle = ViralReconReferenceCatalog.bundleURL(inProject: project)
        try FileManager.default.createDirectory(at: referenceBundle, withIntermediateDirectories: true)
        let compressedReference = referenceBundle.appendingPathComponent("sequence.fa.gz")
        try writeGzipFixture(
            ">MN908947.3 downloaded SARS-CoV-2 reference\nAAAACCCCGGGGTTTT\n",
            to: compressedReference
        )
        XCTAssertEqual(
            ViralReconWizardSheet.referenceName(from: compressedReference, fallback: "NC_045512.2"),
            "MN908947.3"
        )

        let selection = try ViralReconWizardPrimerStaging.stageForCanonicalReference(
            primerBundleURL: primerBundle,
            projectURL: project,
            destinationDirectory: root
        )

        XCTAssertTrue(selection.derivedFasta)
        let stagedFASTA = try String(contentsOf: selection.fastaURL, encoding: .utf8)
        XCTAssertTrue(stagedFASTA.contains(">amplicon_1_LEFT\nAAAA"))
        XCTAssertTrue(stagedFASTA.contains(">amplicon_1_RIGHT\nGGGG"))
    }

    func testViralReconBundledPrimerFastaStagesWithoutTheReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViralReconBundledPrimerFasta-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let primerBundle = root.appendingPathComponent("sars2.lungfishprimers", isDirectory: true)
        try FileManager.default.createDirectory(at: primerBundle, withIntermediateDirectories: true)
        let manifestData = try JSONEncoder().encode(Self.sarsCoV2PrimerManifest())
        try manifestData.write(to: primerBundle.appendingPathComponent("manifest.json"))
        try "Test primer scheme\n".write(
            to: primerBundle.appendingPathComponent("PROVENANCE.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        MN908947.3\t0\t4\tamplicon_1_LEFT\t1\t+
        MN908947.3\t4\t8\tamplicon_1_RIGHT\t1\t-
        """.write(to: primerBundle.appendingPathComponent("primers.bed"), atomically: true, encoding: .utf8)
        try """
        >amplicon_1_LEFT
        AAAA
        >amplicon_1_RIGHT
        CCCC
        """.write(to: primerBundle.appendingPathComponent("primers.fasta"), atomically: true, encoding: .utf8)

        let selection = try ViralReconWizardPrimerStaging.stageForCanonicalReference(
            primerBundleURL: primerBundle,
            projectURL: root.appendingPathComponent("EmptyProject", isDirectory: true),
            destinationDirectory: root
        )

        // A scheme that ships its own primer FASTA needs no reference at all, so
        // it stages completely even before the reference has been acquired.
        XCTAssertFalse(selection.derivedFasta)
        let stagedBED = try String(contentsOf: selection.bedURL, encoding: .utf8)
        XCTAssertTrue(stagedBED.contains("MN908947.3\t0\t4\tamplicon_1_LEFT"))
        XCTAssertFalse(stagedBED.contains("NC_045512.2\t0\t4\tamplicon_1_LEFT"))
        let stagedFASTA = try String(contentsOf: selection.fastaURL, encoding: .utf8)
        XCTAssertTrue(stagedFASTA.contains(">amplicon_1_LEFT\nAAAA"))

        XCTAssertEqual(selection.bedURL.lastPathComponent, "primers.bed")
    }

    // The reference is fixed now, so readiness never asks for one. It only
    // refuses a primer scheme that was written against a different genome.
    func testViralReconReadinessRejectsPrimerSchemeForAnotherGenomeBeforeRun() {
        let evaluation = ViralReconWizardReadiness.evaluate(
            ViralReconWizardReadiness.State(
                hasInputFiles: true,
                effectivePlatform: .illumina,
                inputError: nil,
                primerManifest: Self.nonSARSCoV2PrimerManifest(),
                outputRootAvailable: true,
                minimumMappedReads: 1000
            )
        )

        XCTAssertFalse(evaluation.canRun)
        XCTAssertEqual(
            evaluation.message,
            "MN908947.3 is not compatible with this SARS-CoV-2 primer scheme. Expected MT192765.1."
        )
    }

    func testViralReconReadinessNeverAsksForAReference() {
        let evaluation = ViralReconWizardReadiness.evaluate(
            ViralReconWizardReadiness.State(
                hasInputFiles: true,
                effectivePlatform: .illumina,
                inputError: nil,
                primerManifest: Self.sarsCoV2PrimerManifest(),
                outputRootAvailable: true,
                minimumMappedReads: 1000
            )
        )

        XCTAssertTrue(evaluation.canRun)
        XCTAssertEqual(evaluation.message, "Ready to run Viral Recon.")
    }

    func testViralReconReadinessSurfacesAdvancedParameterErrors() {
        let evaluation = ViralReconWizardReadiness.evaluate(
            ViralReconWizardReadiness.State(
                hasInputFiles: true,
                effectivePlatform: .illumina,
                inputError: nil,
                primerManifest: Self.sarsCoV2PrimerManifest(),
                outputRootAvailable: true,
                minimumMappedReads: 1000,
                advancedError: "varient_caller is not a Viral Recon parameter. Check the spelling."
            )
        )

        XCTAssertFalse(evaluation.canRun)
        XCTAssertEqual(
            evaluation.message,
            "varient_caller is not a Viral Recon parameter. Check the spelling."
        )
    }

    func testViralReconBuildFailureDoesNotForceParentReadinessFalse() throws {
        // ViralReconWizardSheet owns this SwiftUI callback choreography privately:
        // build failures should surface an error without forcing the parent FASTQ
        // dialog disabled, and later input changes must clear the error. There is
        // no state/result seam for that view behavior yet, so this is intentionally
        // kept as a narrow source guard rather than a broad implementation scan.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("onRunnerAvailabilityChange(false)"))
        XCTAssertTrue(source.contains("onRunnerAvailabilityChange(canRun)"))
        XCTAssertTrue(source.contains(".onChange(of: buildErrorRecoveryKey)"))
        XCTAssertTrue(source.contains("clearBuildError()"))
    }

    func testMinimap2UsesGenericEmbeddedReadinessText() {
        XCTAssertEqual(
            FASTQOperationToolID.minimap2.embeddedReadinessText,
            "Complete the mapping settings to continue."
        )
    }

    func testAllSharedMappingToolsUseGenericEmbeddedReadinessText() {
        for toolID in [FASTQOperationToolID.minimap2, .bwaMem2, .bowtie2, .bbmap] {
            XCTAssertEqual(
                toolID.embeddedReadinessText,
                "Complete the mapping settings to continue."
            )
        }
    }

    func testStaleEmbeddedReadinessCallbackCannotAffectNewlySelectedTool() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.fastq")]
        )
        let originalAssemblyTool = state.selectedToolID

        state.selectTool(.minimap2)
        XCTAssertEqual(state.readinessText, "Complete the mapping settings to continue.")
        XCTAssertFalse(state.isRunEnabled)

        state.updateEmbeddedReadiness(true, for: originalAssemblyTool)
        XCTAssertEqual(state.readinessText, "Complete the mapping settings to continue.")
        XCTAssertFalse(state.isRunEnabled)

        state.updateEmbeddedReadiness(true, for: .minimap2)
        XCTAssertTrue(state.isRunEnabled)
    }

    func testCaptureMappingRequestStoresSharedMappingRequest() {
        let sampleFASTQ = illuminaFASTQFixtureURL
        let state = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [sampleFASTQ]
        )

        let request = MappingRunRequest(
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [sampleFASTQ],
            referenceFASTAURL: URL(fileURLWithPath: "/tmp/reference.fa"),
            outputDirectory: URL(fileURLWithPath: "/tmp/mapping-out"),
            sampleName: "Demo",
            readGroup: MappingReadGroup(
                id: "rg-custom",
                sampleName: "sample-custom",
                library: "library-custom",
                platform: "ILLUMINA",
                platformUnit: "unit-custom"
            ),
            pairedEnd: false,
            threads: 8
        )
        let plan = MappingRunPlan(requests: [request], mode: .perBundle, warning: nil)

        state.captureMappingRequest(plan)

        XCTAssertEqual(state.pendingMappingRequest?.requests, [request])
        XCTAssertNil(state.pendingMappingRequest?.warning)
        XCTAssertEqual(state.pendingMappingRequest?.requests.first?.readGroup?.id, "rg-custom")
        XCTAssertEqual(state.pendingMappingRequest?.requests.first?.readGroup?.sampleName, "sample-custom")
        XCTAssertEqual(state.pendingMappingRequest?.requests.first?.readGroup?.library, "library-custom")
        XCTAssertEqual(state.pendingMappingRequest?.requests.first?.readGroup?.platform, "ILLUMINA")
        XCTAssertEqual(state.pendingMappingRequest?.requests.first?.readGroup?.platformUnit, "unit-custom")
        guard case .map(let inputURLs, let referenceURL, let outputMode) = state.pendingLaunchRequest else {
            return XCTFail("Expected mapping launch request")
        }
        XCTAssertEqual(inputURLs, [sampleFASTQ])
        XCTAssertEqual(referenceURL, URL(fileURLWithPath: "/tmp/reference.fa"))
        XCTAssertEqual(outputMode, .perInput)
    }

    func testAssemblyAllowsGroupedResultOutputMode() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        XCTAssertEqual(state.outputMode, .perInput)

        state.outputMode = .groupedResult
        XCTAssertEqual(state.outputMode, .groupedResult)
    }

    func testAssemblyCategoryExposesAllV1Assemblers() {
        XCTAssertEqual(
            FASTQOperationDialogState.toolIDs(for: .assembly),
            [.spades, .megahit, .skesa, .flye, .hifiasm]
        )
    }

    func testAssemblyCategorySeedsSpadesAsDefaultToolAndRequiresEmbeddedConfiguration() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [illuminaFASTQFixtureURL]
        )

        XCTAssertEqual(state.selectedToolID, .spades)
        XCTAssertEqual(state.outputMode, .perInput)
        XCTAssertFalse(state.isRunEnabled)
    }

    func testCaptureAssemblyRequestStoresGenericAssemblyRequest() {
        let sampleFASTQ = illuminaFASTQFixtureURL
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [sampleFASTQ]
        )
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [sampleFASTQ],
            projectName: "Demo",
            outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
            threads: 8,
            memoryGB: nil,
            minContigLength: nil,
            selectedProfileID: nil,
            extraArguments: []
        )

        state.captureAssemblyRequest(request)

        XCTAssertEqual(state.pendingAssemblyRequest, request)
        guard case .assemble(let storedRequest, let outputMode) = state.pendingLaunchRequest else {
            return XCTFail("Expected generic assembly request")
        }
        XCTAssertEqual(storedRequest, request)
        XCTAssertEqual(outputMode, .perInput)
    }

    func testAssemblyReadTypeDetectionUsesSelectedFASTQs() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [illuminaFASTQFixtureURL]
        )

        XCTAssertEqual(state.detectedAssemblyReadType, .illuminaShortReads)
        XCTAssertNil(state.assemblyReadClassMismatchMessage)
    }

    func testAssemblySidebarFiltersToShortReadToolsForDetectedIlluminaReadType() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [illuminaFASTQFixtureURL]
        )

        XCTAssertEqual(state.sidebarItems.map(\.id), [
            FASTQOperationToolID.spades.rawValue,
            FASTQOperationToolID.megahit.rawValue,
            FASTQOperationToolID.skesa.rawValue,
        ])
    }

    func testAssemblyReadTypeDetectionUsesSelectedFASTQBundles() throws {
        let bundleURL = try makeFASTQBundle(
            fastqName: "reads.fastq",
            fastqContents: """
            @A00488:17:H7WFLDMXX:1:1101:10000:1000 1:N:0:ATCACG
            ACGT
            +
            !!!!
            """
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [bundleURL]
        )

        XCTAssertEqual(state.detectedAssemblyReadType, .illuminaShortReads)
        XCTAssertNil(state.assemblyReadClassMismatchMessage)
    }

    func testAssemblySidebarFiltersToCompatibleToolsForPersistedONTReadType() throws {
        let bundleURL = try makeFASTQBundle(
            fastqName: "reads.fastq",
            fastqContents: """
            @unknown-read
            ACGT
            +
            !!!!
            """
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let primaryFASTQURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(assemblyReadType: .ontReads),
            for: primaryFASTQURL
        )

        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [bundleURL]
        )

        XCTAssertEqual(state.sidebarItems.map(\.id), [
            FASTQOperationToolID.flye.rawValue,
            FASTQOperationToolID.hifiasm.rawValue,
        ])
        XCTAssertTrue(state.sidebarItems.allSatisfy { $0.availability == .available })
    }

    func testHifiasmSubtitleDescribesONTAndHiFiCCSSupport() {
        XCTAssertEqual(
            FASTQOperationToolID.hifiasm.subtitle,
            "Assemble ONT or PacBio HiFi/CCS long reads into phased contigs."
        )
    }

    func testAssemblyCategorySeedsCompatibleDefaultToolForPersistedReadType() throws {
        let bundleURL = try makeFASTQBundle(
            fastqName: "reads.fastq",
            fastqContents: """
            @unknown-read
            ACGT
            +
            !!!!
            """
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let primaryFASTQURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL))
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(assemblyReadType: .pacBioHiFi),
            for: primaryFASTQURL
        )

        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [bundleURL]
        )

        XCTAssertEqual(state.selectedToolID, .hifiasm)
    }

    func testMixedAssemblyReadTypesExposeHybridBlockMessage() throws {
        let ontFASTQ = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationDialogRoutingTests-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: ontFASTQ) }

        let fastq = """
        @9b50942a-4ec6-48d2-8f3b-4ff4f63cb17a runid=2de0f6d4 sampleid=sample1 read=1 ch=12 start_time=2024-01-01T00:00:00Z flow_cell_id=FLO-MIN114
        ACGT
        +
        !!!!
        """
        try Data(fastq.utf8).write(to: ontFASTQ)

        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [illuminaFASTQFixtureURL, ontFASTQ]
        )

        XCTAssertNil(state.detectedAssemblyReadType)
        XCTAssertEqual(
            state.assemblyReadClassMismatchMessage,
            AssemblyCompatibility.hybridAssemblyUnsupportedMessage
        )
        XCTAssertFalse(state.isRunEnabled)
    }

    func testKnownAndUnclassifiedAssemblyReadTypesAreBlocked() throws {
        let pacBioSubreadsFASTQ = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationDialogRoutingTests-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: pacBioSubreadsFASTQ) }

        let fastq = """
        @m64001_190101_000000/123/subreads
        ACGT
        +
        !!!!
        """
        try Data(fastq.utf8).write(to: pacBioSubreadsFASTQ)

        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [illuminaFASTQFixtureURL, pacBioSubreadsFASTQ]
        )

        XCTAssertNil(state.detectedAssemblyReadType)
        XCTAssertEqual(
            state.assemblyReadClassMismatchMessage,
            "Selected FASTQ inputs mix detected and unclassified read classes. Select one read class per run."
        )
        XCTAssertFalse(state.isRunEnabled)
    }

    func testUnknownOnlyAssemblyInputsStayBlockedUntilReadTypeIsConfirmed() throws {
        let pacBioSubreadsFASTQ = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationDialogRoutingTests-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: pacBioSubreadsFASTQ) }

        let fastq = """
        @m64001_190101_000000/123/subreads
        ACGT
        +
        !!!!
        """
        try Data(fastq.utf8).write(to: pacBioSubreadsFASTQ)

        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [pacBioSubreadsFASTQ]
        )

        XCTAssertNil(state.detectedAssemblyReadType)
        XCTAssertNil(state.assemblyReadClassMismatchMessage)
        XCTAssertFalse(state.isRunEnabled)
    }

    func testNonSpadesAssemblersStayDisabledInEmbeddedFASTQDialog() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [illuminaFASTQFixtureURL]
        )

        state.selectTool(.megahit)

        XCTAssertFalse(state.isRunEnabled)
    }

    func testCaptureAssemblyWizardConfigPreservesPairedEndTopology() {
        let forward = illuminaFASTQFixtureURL
        let reverse = illuminaFASTQFixtureURL
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [forward, reverse]
        )

        state.captureAssemblyWizardConfig(
            SPAdesAssemblyConfig(
                mode: .meta,
                forwardReads: [forward],
                reverseReads: [reverse],
                unpairedReads: [],
                kmerSizes: nil,
                memoryGB: 16,
                threads: 8,
                minContigLength: 500,
                skipErrorCorrection: false,
                careful: false,
                outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
                projectName: "Demo"
            )
        )

        guard case .assemble(let request, _) = state.pendingLaunchRequest else {
            return XCTFail("Expected paired assembly launch request")
        }

        XCTAssertTrue(request.pairedEnd)
    }

    func testDatasetLabelSummarizesMultipleSelectedInputs() {
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [
                URL(fileURLWithPath: "/tmp/sample-1.fastq"),
                URL(fileURLWithPath: "/tmp/sample-2.fastq"),
                URL(fileURLWithPath: "/tmp/sample-3.fastq"),
            ]
        )

        XCTAssertEqual(state.datasetLabel, "3 FASTQ datasets")
    }

    func testDatasetLabelUsesProjectRelativePathForSingleSelectedInput() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let state = FASTQOperationDialogState(
            initialCategory: .assembly,
            selectedInputURLs: [
                projectURL.appendingPathComponent("Samples/A/reads.fastq")
            ],
            projectURL: projectURL
        )

        XCTAssertEqual(state.datasetLabel, "Samples/A/reads.fastq")
    }

    func testSpecialToolsUseEmbeddedConfigurationPresentation() {
        let embeddedTools: [FASTQOperationToolID] = [
            .minimap2, .bwaMem2, .bowtie2, .bbmap,
            .viralRecon,
            .spades, .megahit, .skesa, .flye, .hifiasm,
            .kraken2, .esViritu, .taxTriage,
        ]

        XCTAssertTrue(embeddedTools.allSatisfy(\.usesEmbeddedConfiguration))
        XCTAssertEqual(FASTQOperationToolID.minimap2.mappingTool, .minimap2)
        XCTAssertEqual(FASTQOperationToolID.spades.assemblyTool, .spades)
        XCTAssertEqual(FASTQOperationToolID.kraken2.embeddedReadinessText, "Complete the classifier settings to continue.")
    }

    func testAllAssemblyToolsMapToSharedAssemblyWizardInputs() {
        for toolID in [FASTQOperationToolID.spades, .megahit, .skesa, .flye, .hifiasm] {
            XCTAssertTrue(toolID.usesEmbeddedConfiguration)
            XCTAssertEqual(toolID.assemblyTool?.rawValue, toolID.rawValue)
            XCTAssertEqual(toolID.embeddedReadinessText, "Complete the assembly settings to continue.")
        }
    }

    func testDerivativeToolPaneAuxiliarySelectionUpdatesState() {
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )
        let primerURL = URL(fileURLWithPath: "/tmp/primers.fasta")

        state.selectTool(.primerTrimming)
        state.primerTrimmingSource = .reference

        XCTAssertEqual(state.requiredInputKinds, [.fastqDataset, .primerSource])
        XCTAssertFalse(state.isRunEnabled)

        state.setAuxiliaryInput(primerURL, for: .primerSource)

        XCTAssertEqual(state.auxiliaryInputURL(for: .primerSource), primerURL)
        XCTAssertTrue(state.isRunEnabled)
    }

    func testDialogRunButtonStateIncrementsEmbeddedRunTriggerForSpecialToolPanes() {
        let state = FASTQOperationDialogState(
            initialCategory: .mapping,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )

        state.selectTool(.minimap2)
        let initialTrigger = state.embeddedRunTrigger

        state.prepareForRun()

        XCTAssertEqual(state.embeddedRunTrigger, initialTrigger + 1)
        XCTAssertNil(state.pendingLaunchRequest)
    }

    func testDialogRunPresentationRunsWhenEmbeddedViralReconRequestIsCaptured() {
        XCTAssertTrue(FASTQOperationDialogRunPresentation.shouldRunAfterEmbeddedRequestCapture(
            selectedToolID: .viralRecon,
            hasPendingViralReconRequest: true
        ))
        XCTAssertFalse(FASTQOperationDialogRunPresentation.shouldRunAfterEmbeddedRequestCapture(
            selectedToolID: .kraken2,
            hasPendingViralReconRequest: true
        ))
        XCTAssertFalse(FASTQOperationDialogRunPresentation.shouldRunAfterEmbeddedRequestCapture(
            selectedToolID: .viralRecon,
            hasPendingViralReconRequest: false
        ))
    }

    func testMAFFTPrepareForRunBuildsAlignmentRequestInsteadOfGenericLaunchRequest() throws {
        let project = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("input.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )

        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingMSAAlignmentRequest)
        XCTAssertEqual(request.inputSequenceURLs, [input])
        XCTAssertEqual(request.projectURL, project)
        XCTAssertEqual(request.name, "input")
        XCTAssertNil(state.pendingLaunchRequest)
        XCTAssertNil(state.pendingMappingRequest)
        XCTAssertNil(state.pendingMinimap2Config)
    }

    func testMAFFTAdvancedOptionsRouteIntoPendingMSARequest() throws {
        let project = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let input = project.appendingPathComponent("input.fasta")
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )

        XCTAssertFalse(state.mafftAdvancedOptionsExpanded)

        state.mafftAdvancedOptionsExpanded = true
        state.mafftDirectionAdjustment = .accurate
        state.mafftSymbolPolicy = .any
        state.mafftThreads = 8
        state.mafftDeterministicThreads = false
        state.mafftAllowFASTQAssemblyInputs = true
        state.mafftExtraOptionsText = #"--op 1.53 --retree "2""#
        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingMSAAlignmentRequest)
        XCTAssertTrue(state.mafftAdvancedOptionsExpanded)
        XCTAssertEqual(request.directionAdjustment, .accurate)
        XCTAssertEqual(request.symbolPolicy, .any)
        XCTAssertEqual(request.threads, 8)
        XCTAssertFalse(request.deterministicThreads)
        XCTAssertTrue(request.allowFASTQAssemblyInputs)
        XCTAssertEqual(request.extraArguments, ["--op", "1.53", "--retree", "2"])
    }

    func testMAFFTRequestUsesAnalysesMSAFolderAndAvoidsExistingBundle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scratch = root
            .appendingPathComponent(".build/test-scratch/FASTQOperationDialogRoutingTests-\(UUID().uuidString)", isDirectory: true)
        let project = scratch.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let input = project
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("sars-cov-2-genomes.lungfishref", isDirectory: true)
        let existingOutput = project
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("Multiple Sequence Alignments", isDirectory: true)
            .appendingPathComponent("sars-cov-2-genomes.lungfishmsa", isDirectory: true)

        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existingOutput, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [input],
            projectURL: project
        )

        state.prepareForRun()

        let request = try XCTUnwrap(state.pendingMSAAlignmentRequest)
        XCTAssertEqual(
            request.outputBundleURL,
            project
                .appendingPathComponent("Analyses", isDirectory: true)
                .appendingPathComponent("Multiple Sequence Alignments", isDirectory: true)
                .appendingPathComponent("sars-cov-2-genomes-2.lungfishmsa", isDirectory: true)
        )
        XCTAssertEqual(request.name, "sars-cov-2-genomes-2")
    }

    func testOperationsDialogStateUsesCurrentProjectForRelativeDatasetLabel() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let state = FASTQOperationDialogState(
            initialCategory: .readProcessing,
            selectedInputURLs: [
                projectURL.appendingPathComponent("Reads/sample.lungfishfastq", isDirectory: true)
            ],
            projectURL: projectURL
        )

        XCTAssertEqual(state.projectURL, projectURL)
        XCTAssertEqual(state.datasetLabel, "Reads/sample.lungfishfastq")
    }

    func testRepresentativeDerivativeSettingsRouteIntoLaunchRequests() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let trimState = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [inputURL]
        )

        trimState.qualityTrimThreshold = 31
        trimState.adapterRemovalMode = .specified
        trimState.adapterRemovalSequence = "AGATCGGAAGAGC"
        trimState.prepareForRun()

        XCTAssertEqual(
            trimState.pendingLaunchRequest,
            .derivative(
                request: .fastpTrim(
                    threshold: 31,
                    windowSize: 4,
                    mode: .cutRight,
                    adapterMode: .specified,
                    adapterSequence: "AGATCGGAAGAGC"
                ),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )

        let sequenceState = FASTQOperationDialogState(
            initialCategory: .searchSubsetting,
            selectedInputURLs: [inputURL]
        )
        sequenceState.selectTool(.selectReadsBySequence)
        sequenceState.selectReadsBySequenceValue = "TTAGGG"
        sequenceState.selectReadsBySequenceSearchEnd = .threePrime
        sequenceState.prepareForRun()

        XCTAssertEqual(
            sequenceState.pendingLaunchRequest,
            .derivative(
                request: .sequencePresenceFilter(
                    sequence: "TTAGGG",
                    fastaPath: nil,
                    searchEnd: .threePrime,
                    minOverlap: 16,
                    errorRate: 0.15,
                    keepMatched: true,
                    searchReverseComplement: false
                ),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )

        let demultiplexState = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [inputURL]
        )
        demultiplexState.selectTool(.demultiplexBarcodes)
        demultiplexState.demultiplexKitID = "rapid-kit"
        demultiplexState.demultiplexLocation = "start"
        demultiplexState.demultiplexMaxDistanceFrom5Prime = 3
        demultiplexState.demultiplexMaxDistanceFrom3Prime = 5
        demultiplexState.demultiplexErrorRate = 0.05
        demultiplexState.demultiplexTrimBarcodes = false
        demultiplexState.prepareForRun()

        XCTAssertEqual(
            demultiplexState.pendingLaunchRequest,
            .derivative(
                request: .demultiplex(
                    kitID: "rapid-kit",
                    customCSVPath: nil,
                    location: "start",
                    symmetryMode: nil,
                    maxDistanceFrom5Prime: 3,
                    maxDistanceFrom3Prime: 5,
                    errorRate: 0.05,
                    engine: .cutadapt,
                    trimBarcodes: false,
                    sampleAssignments: nil,
                    kitOverride: nil
                ),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
    }

    func testCustomDeduplicationSettingsRouteIntoLaunchRequest() {
        let inputURL = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")
        let state = FASTQOperationDialogState(
            initialCategory: .decontamination,
            selectedInputURLs: [inputURL]
        )

        state.selectTool(.removeDuplicates)
        state.removeDuplicatesPreset = .custom
        state.removeDuplicatesSubstitutions = 2
        state.removeDuplicatesOptical = true
        state.removeDuplicatesOpticalDistance = 450
        state.prepareForRun()

        XCTAssertEqual(
            state.pendingLaunchRequest,
            .derivative(
                request: .deduplicate(
                    preset: .custom,
                    substitutions: 2,
                    optical: true,
                    opticalDistance: 450
                ),
                inputURLs: [inputURL],
                outputMode: .perInput
            )
        )
    }

    func testClassificationCapturePreservesAllBatchInputs() {
        let databaseURL = URL(fileURLWithPath: "/tmp/kraken-db")
        let outputURL = URL(fileURLWithPath: "/tmp/classification")
        let state = FASTQOperationDialogState(
            initialCategory: .classification,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample-1.fastq")]
        )

        state.captureClassificationConfigs([
            ClassificationConfig(
                inputFiles: [URL(fileURLWithPath: "/tmp/sample-1.fastq")],
                isPairedEnd: false,
                databaseName: "standard",
                databasePath: databaseURL,
                outputDirectory: outputURL
            ),
            ClassificationConfig(
                inputFiles: [URL(fileURLWithPath: "/tmp/sample-2.fastq")],
                isPairedEnd: false,
                databaseName: "standard",
                databasePath: databaseURL,
                outputDirectory: outputURL
            ),
        ])

        XCTAssertEqual(state.pendingClassificationConfigs.count, 2)
        XCTAssertEqual(
            state.pendingLaunchRequest,
            .classify(
                tool: .kraken2,
                inputURLs: [
                    URL(fileURLWithPath: "/tmp/sample-1.fastq"),
                    URL(fileURLWithPath: "/tmp/sample-2.fastq"),
                ],
                databaseName: "standard"
            )
        )
    }

    private var illuminaFASTQFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/sarscov2/test_1.fastq.gz")
    }

    private static func sarsCoV2PrimerManifest() -> PrimerSchemeManifest {
        PrimerSchemeManifest(
            schemaVersion: 1,
            name: "qia-seq-direct-sars2",
            displayName: "QIASeq DIRECT SARS-CoV-2",
            referenceAccessions: [
                PrimerSchemeManifest.ReferenceAccession(accession: "MN908947.3", canonical: true),
                PrimerSchemeManifest.ReferenceAccession(accession: "NC_045512.2", equivalent: true),
            ],
            primerCount: 2,
            ampliconCount: 1
        )
    }

    /// A scheme written against a genome that is not the fixed reference.
    private static func nonSARSCoV2PrimerManifest() -> PrimerSchemeManifest {
        PrimerSchemeManifest(
            schemaVersion: 1,
            name: "other-genome-scheme",
            displayName: "Other Genome Scheme",
            referenceAccessions: [
                PrimerSchemeManifest.ReferenceAccession(accession: "MT192765.1", canonical: true),
            ],
            primerCount: 2,
            ampliconCount: 1
        )
    }

    /// Writes `Downloads/MN908947.3.lungfishref` holding a plain FASTA, which is
    /// what the wizard looks for before staging primers.
    @discardableResult
    private static func writeCanonicalReferenceBundle(
        inProject projectURL: URL,
        sequence: String
    ) throws -> URL {
        let bundleURL = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastaURL = bundleURL.appendingPathComponent("sequence.fasta")
        try ">\(ViralReconReferenceCatalog.canonicalAccession) SARS-CoV-2 reference\n\(sequence)\n"
            .write(to: fastaURL, atomically: true, encoding: .utf8)
        return fastaURL
    }

    private func makeFASTQBundle(
        fastqName: String,
        fastqContents: String
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQOperationDialogRoutingTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(fastqContents.utf8).write(to: bundleURL.appendingPathComponent(fastqName))
        return bundleURL
    }

    private func writeGzipFixture(_ content: String, to gzipURL: URL) throws {
        let sourceURL = gzipURL.deletingLastPathComponent()
            .appendingPathComponent("reference-source-\(UUID().uuidString).fa")
        try content.write(to: sourceURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", sourceURL.path]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        let compressed = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr, encoding: .utf8) ?? "gzip failed"
            throw NSError(
                domain: "FASTQOperationDialogRoutingTests.GzipFixture",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        try compressed.write(to: gzipURL)
    }
}

@MainActor
private final class AllEnabledFASTQWorkflowLibrary: WorkflowLibraryEnabling {
    func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool {
        true
    }
}

private struct ReadySavontRuntimeStatusProvider: PluginPackStatusProviding {
    func visibleStatuses() async -> [PluginPackStatus] {
        guard let status = await status(forPackID: "full-length-mhc-genotyping") else { return [] }
        return [status]
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        makeReadyStatus(for: pack)
    }

    func status(forPackID packID: String) async -> PluginPackStatus? {
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return makeReadyStatus(for: pack)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}

    private func makeReadyStatus(for pack: PluginPack) -> PluginPackStatus {
        PluginPackStatus(
            pack: pack,
            state: .ready,
            toolStatuses: pack.toolRequirements.map { requirement in
                PackToolStatus(
                    requirement: requirement,
                    environmentExists: true,
                    missingExecutables: [],
                    smokeTestFailure: nil,
                    storageUnavailablePath: nil
                )
            },
            failureMessage: nil
        )
    }
}
