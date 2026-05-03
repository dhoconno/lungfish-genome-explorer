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

        state.selectTool(.qualityTrim)

        XCTAssertEqual(
            state.visibleSections,
            [.inputs, .primarySettings, .advancedSettings, .output, .readiness]
        )
        XCTAssertEqual(state.inputSectionTitle, "Inputs")
        XCTAssertEqual(state.outputSectionTitle, "Output")
        XCTAssertEqual(state.readinessText, "Ready to configure output.")
        XCTAssertEqual(state.outputStrategyOptions, [.perInput, .groupedResult])
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
                    referenceFasta: "/tmp/primers.fasta",
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
                    trimBarcodes: true,
                    sampleAssignments: nil,
                    kitOverride: nil
                ),
                inputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
                outputMode: .perInput
            )
        )
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

    func testViralReconGenomePrimerDerivationKeepsBedAlignedToGenomeAccession() throws {
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

        let referenceFASTA = root.appendingPathComponent("local-reference.fasta")
        try """
        >NC_045512.2 local SARS-CoV-2 sequence source
        AAAACCCCGGGGTTTT
        """.write(to: referenceFASTA, atomically: true, encoding: .utf8)

        let selection = try ViralReconWizardPrimerStaging.stageGenomePrimerSelection(
            primerBundleURL: primerBundle,
            sourceReferenceFASTAURL: referenceFASTA,
            genomeAccession: "  MN908947.3  ",
            destinationDirectory: root
        )

        XCTAssertTrue(selection.derivedFasta)
        let stagedBED = try String(contentsOf: selection.bedURL, encoding: .utf8)
        XCTAssertTrue(stagedBED.contains("MN908947.3\t0\t4\tamplicon_1_LEFT"))
        XCTAssertFalse(stagedBED.contains("NC_045512.2\t0\t4\tamplicon_1_LEFT"))
        let stagedFASTA = try String(contentsOf: selection.fastaURL, encoding: .utf8)
        XCTAssertTrue(stagedFASTA.contains(">amplicon_1_LEFT\nAAAA"))
        XCTAssertTrue(stagedFASTA.contains(">amplicon_1_RIGHT\nGGGG"))

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(wizardSource.contains("genomeAccession: genomeReferenceName ?? genomeAccession"))
    }

    func testViralReconBundledPrimerFastaKeepsBedAlignedToEquivalentGenomeAccession() throws {
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

        let selection = try ViralReconWizardPrimerStaging.stageBundledGenomePrimerSelection(
            primerBundleURL: primerBundle,
            genomeAccession: "NC_045512.2",
            destinationDirectory: root
        )

        XCTAssertFalse(selection.derivedFasta)
        let stagedBED = try String(contentsOf: selection.bedURL, encoding: .utf8)
        XCTAssertTrue(stagedBED.contains("NC_045512.2\t0\t4\tamplicon_1_LEFT"))
        XCTAssertFalse(stagedBED.contains("MN908947.3\t0\t4\tamplicon_1_LEFT"))

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(wizardSource.contains("stageBundledGenomePrimerSelection"))
    }

    func testViralReconReadinessRejectsBlankGenomeBeforeRun() {
        let evaluation = ViralReconWizardReadiness.evaluate(
            ViralReconWizardReadiness.State(
                hasInputFiles: true,
                effectivePlatform: .illumina,
                inputError: nil,
                primerManifest: Self.sarsCoV2PrimerManifest(),
                outputRootAvailable: true,
                version: "3.0.0",
                minimumMappedReads: 1000,
                maxCPUs: 4,
                maxMemory: "8.GB",
                reference: .sarsCoV2Genome(accession: "  "),
                primerRequiresLocalReference: false,
                hasSelectedLocalReference: false
            )
        )

        XCTAssertFalse(evaluation.canRun)
        XCTAssertEqual(evaluation.message, "Enter a SARS-CoV-2 genome accession.")
    }

    func testViralReconReadinessRejectsIncompatibleGenomeBeforeRun() {
        let evaluation = ViralReconWizardReadiness.evaluate(
            ViralReconWizardReadiness.State(
                hasInputFiles: true,
                effectivePlatform: .illumina,
                inputError: nil,
                primerManifest: Self.sarsCoV2PrimerManifest(),
                outputRootAvailable: true,
                version: "3.0.0",
                minimumMappedReads: 1000,
                maxCPUs: 4,
                maxMemory: "8.GB",
                reference: .sarsCoV2Genome(accession: "MT192765.1"),
                primerRequiresLocalReference: false,
                hasSelectedLocalReference: false
            )
        )

        XCTAssertFalse(evaluation.canRun)
        XCTAssertEqual(
            evaluation.message,
            "MT192765.1 is not compatible with this SARS-CoV-2 primer scheme. Expected MN908947.3, NC_045512.2."
        )
    }

    func testViralReconReadinessStopsPromptingForPrimerDerivedReferenceAfterSelection() {
        let evaluation = ViralReconWizardReadiness.evaluate(
            ViralReconWizardReadiness.State(
                hasInputFiles: true,
                effectivePlatform: .illumina,
                inputError: nil,
                primerManifest: Self.sarsCoV2PrimerManifest(),
                outputRootAvailable: true,
                version: "3.0.0",
                minimumMappedReads: 1000,
                maxCPUs: 4,
                maxMemory: "8.GB",
                reference: .sarsCoV2Genome(accession: "MN908947.3"),
                primerRequiresLocalReference: true,
                hasSelectedLocalReference: true
            )
        )

        XCTAssertTrue(evaluation.canRun)
        XCTAssertEqual(evaluation.message, "Ready to run Viral Recon.")
    }

    func testViralReconBuildFailureDoesNotForceParentReadinessFalse() throws {
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
            pairedEnd: false,
            threads: 8
        )

        state.captureMappingRequest(request)

        XCTAssertEqual(state.pendingMappingRequest, request)
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

    func testToolPaneFileRoutesSpecialToolsThroughEmbeddedSheets() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root
            .appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("MappingWizardSheet("))
        XCTAssertTrue(source.contains("AssemblyWizardSheet("))
        XCTAssertTrue(source.contains("ClassificationWizardSheet("))
        XCTAssertTrue(source.contains("embeddedInOperationsDialog: true"))
    }

    func testToolPaneFileRoutesAllAssemblyToolsThroughSharedAssemblyWizard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root
            .appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("case .spades, .megahit, .skesa, .flye, .hifiasm:"))
        XCTAssertTrue(source.contains("initialTool: state.selectedToolID.assemblyTool ?? .spades"))
        XCTAssertTrue(source.contains("onRun: state.captureAssemblyRequest(_:),"))
        XCTAssertFalse(source.contains("Embedded managed assembly execution is not available in this FASTQ dialog yet."))
    }

    func testDerivativeToolPaneProvidesAuxiliaryInputChooser() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root
            .appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".fileImporter("))
        XCTAssertTrue(source.contains("state.setAuxiliaryInput(url, for: browsingInputKind)"))
        XCTAssertTrue(source.contains(#"Button(state.auxiliaryInputURL(for: kind) == nil ? "Choose…" : "Replace…")"#))
    }

    func testDialogRunButtonWiresEmbeddedRunTriggerIntoSpecialToolPanes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let toolPanesSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift"),
            encoding: .utf8
        )
        let dialogSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationDialog.swift"),
            encoding: .utf8
        )
        let stateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(toolPanesSource.contains("embeddedRunTrigger: state.embeddedRunTrigger"))
        XCTAssertTrue(dialogSource.contains("state.prepareForRun()"))
        XCTAssertTrue(stateSource.contains("var embeddedRunTrigger"))
    }

    func testDialogRunsWhenEmbeddedViralReconRequestIsCaptured() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dialogSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(dialogSource.contains(".onChange(of: state.pendingViralReconRequest)"))
        XCTAssertTrue(dialogSource.contains("state.selectedToolID == .viralRecon"))
        XCTAssertTrue(dialogSource.contains("request != nil"))
        XCTAssertTrue(dialogSource.contains("onRun()"))
    }

    func testOperationsDialogRoutesCurrentWindowProjectIntoDialogState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let presenterSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationsDialogPresenter.swift"),
            encoding: .utf8
        )
        let appDelegateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(presenterSource.contains("projectURL: projectURL"))
        XCTAssertTrue(appDelegateSource.contains("projectURL: currentProjectURL"))
    }

    func testDerivativeToolPaneContainsRealHonestControls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root
            .appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("qualityTrimThreshold"))
        XCTAssertTrue(source.contains("adapterRemovalMode"))
        XCTAssertTrue(source.contains("selectReadsBySequenceValue"))
        XCTAssertTrue(source.contains("demultiplexLocation"))
    }

    func testDerivativeToolPaneExposesEditableControlsForCustomDeduplication() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root
            .appendingPathComponent("Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("removeDuplicatesSubstitutions"))
        XCTAssertTrue(source.contains("removeDuplicatesOptical"))
        XCTAssertTrue(source.contains("removeDuplicatesOpticalDistance"))
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
}
