import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class WorkflowOperationDialogStateTests: XCTestCase {
    func testStateShowsEnabledONTGenotypingAsRunnableWorkflow() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)

        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        let ont = try XCTUnwrap(state.tools.first { $0.title == "Amplicon Genotyping" })
        XCTAssertEqual(ont.availability, .available)
    }

    func testONTGenotypingDefaultReportNameIsGeneric() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let readsURL = temp.appendingPathComponent("barcode11.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        XCTAssertEqual(state.outputName, "amplicon-genotyping")
    }

    func testFreshInstallONTGenotypingCanRunWithCompleteConfiguration() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "sample-ont"

        XCTAssertEqual(state.readinessText, "Ready to run.")
        XCTAssertTrue(state.isRunEnabled)
    }

    func testMHCReferenceBundleSelectionAppliesBundledHaplotypeDefinition() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("Reference Sequences/MCM-MHC.lungfishmhcref", isDirectory: true)
        let haplotypeURL = referenceURL.appendingPathComponent("haplotypes/mcm.json")
        let readsURL = temp.appendingPathComponent("Reads/barcode10.lungfishfastq", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: haplotypeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)
        try ">M1\nACGT\n".write(to: referenceURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        let definition = Self.mhcDefinition(id: "mcm-mhc")
        try JSONEncoder().encode(definition).write(to: haplotypeURL)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                name: "MCM MHC",
                referenceFastaPath: "reference.fa",
                haplotypeDefinitionPaths: ["haplotypes/mcm.json"],
                defaultHaplotypeDefinitionID: definition.id,
                metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: referenceURL
        )

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "barcode10-mhc"

        XCTAssertEqual(state.selectedHaplotypeDefinitionSetID, definition.id)
        XCTAssertEqual(state.selectedHaplotypeAssayID, definition.assayID)
        XCTAssertEqual(state.selectedHaplotypeSpeciesCode, definition.speciesCode)
        XCTAssertEqual(state.selectedMHCReferenceBundleURL, referenceURL.standardizedFileURL)
        let compatibleRecord = try XCTUnwrap(state.compatibleHaplotypeDefinitionRecords.first)
        XCTAssertEqual(compatibleRecord.definitionSet.id, definition.id)
        XCTAssertEqual(compatibleRecord.referenceBundleURL, referenceURL.standardizedFileURL)
        XCTAssertEqual(compatibleRecord.sourceDisplayName, "MHC Reference Bundle")
        let launch = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launch else {
            return XCTFail("Expected ONT genotyping request")
        }
        XCTAssertEqual(request.referenceSourceURL, referenceURL.standardizedFileURL)
        XCTAssertEqual(request.haplotypeDefinitionSetID, definition.id)
        XCTAssertEqual(request.haplotypeAssayID, definition.assayID)
        XCTAssertEqual(request.haplotypeSpeciesCode, definition.speciesCode)
    }

    func testMHCReferenceBundleSelectionCollapsesHaplotypePickerStackAndSummarizesBundle() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("Reference Sequences/MCM-MHC.lungfishmhcref", isDirectory: true)
        let haplotypeURL = referenceURL.appendingPathComponent("haplotypes/mcm.json")
        let readsURL = temp.appendingPathComponent("Reads/barcode10.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        let plainFASTAURL = temp.appendingPathComponent("plain.fa")
        try FileManager.default.createDirectory(at: haplotypeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try ">M1\nACGT\n".write(to: plainFASTAURL, atomically: true, encoding: .utf8)
        try ">M1\nACGT\n".write(to: referenceURL.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        let definition = Self.mhcDefinition(id: "mcm-mhc")
        try JSONEncoder().encode(definition).write(to: haplotypeURL)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                name: "MCM MHC",
                referenceFastaPath: "reference.fa",
                haplotypeDefinitionPaths: ["haplotypes/mcm.json"],
                defaultHaplotypeDefinitionID: definition.id,
                metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: referenceURL
        )

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        state.setReference(plainFASTAURL)
        XCTAssertFalse(state.usesBundledHaplotypeDefinitions)
        XCTAssertNil(state.referenceBundleSummary)

        state.setReference(referenceURL)

        XCTAssertTrue(state.usesBundledHaplotypeDefinitions)
        XCTAssertEqual(state.referenceBundleSummary, "From bundle: MCM MHC")
    }

    func testOperationsDialogReflectsWorkflowEnabledByLibraryStoreAfterDialogStoreWasCreated() throws {
        let defaults = try makeDefaults()
        let operationsStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: operationsStore,
            packageStore: packageStore
        )

        let libraryStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        // 12S is opt-in (disabled on fresh install); enable it explicitly so the
        // dialog reflects a library-store change made after it was created.
        let twelveSItem = try XCTUnwrap(WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.twelveSAmpliconMatchingID))
        libraryStore.setWorkflow(twelveSItem, enabled: true)
        var ont = try XCTUnwrap(state.tools.first { $0.title == "Amplicon Genotyping" })
        XCTAssertEqual(ont.availability, .available)
        var twelveS = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        XCTAssertEqual(twelveS.availability, .available)

        libraryStore.setWorkflow(.ontGenotyping, enabled: false)
        libraryStore.setWorkflow(twelveSItem, enabled: false)

        ont = try XCTUnwrap(state.tools.first { $0.title == "Amplicon Genotyping" })
        XCTAssertEqual(ont.availability, .disabled(reason: "Enable in Library"))
        twelveS = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        XCTAssertEqual(twelveS.availability, .disabled(reason: "Enable in Library"))

        libraryStore.setWorkflow(.ontGenotyping, enabled: true)
        libraryStore.setWorkflow(twelveSItem, enabled: true)

        ont = try XCTUnwrap(state.tools.first { $0.title == "Amplicon Genotyping" })
        XCTAssertEqual(ont.availability, .available)
        twelveS = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        XCTAssertEqual(twelveS.availability, .available)
    }

    func testOperationsDialogStateInvalidatesWhenLibraryEnablementChanges() throws {
        let defaults = try makeDefaults()
        let operationsStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: operationsStore,
            packageStore: packageStore
        )
        let initialRevision = state.workflowAvailabilityRevision
        let libraryStore = WorkflowLibraryEnablementStore(userDefaults: defaults)

        libraryStore.setWorkflow(.ontGenotyping, enabled: false)
        waitForMainQueue()

        XCTAssertGreaterThan(state.workflowAvailabilityRevision, initialRevision)
    }

    func testEnabledWorkflowPackageBuildsLocalWorkflowRunWithExpectedOutputs() async throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let packageURL = helloWorldNextflowPackageURL()
        packageStore.addPackage(at: packageURL)
        let package = try WorkflowPackageValidator.validatePackage(at: packageURL)
        enablementStore.setUserWorkflow(package, enabled: true)

        let temp = try temporaryDirectory()
        let projectURL = temp.appendingPathComponent("project.lungfish", isDirectory: true)
        let referenceURL = projectURL.appendingPathComponent("Reference Sequences/ref.lungfishref", isDirectory: true)
        let readsURL = projectURL.appendingPathComponent("Reads/sample.lungfishfastq", isDirectory: true)
        let outputURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.selectTool("package.org.lungfish.templates.hello-world-nextflow")
        state.setReference(referenceURL)
        state.setReads([readsURL])
        state.setOutputDirectory(outputURL)

        let launchRequest = try state.makeLaunchRequest()
        guard case .workflowPackage(let request, let bundleRoot) = launchRequest else {
            return XCTFail("Expected workflow package launch request")
        }

        XCTAssertEqual(request.workflowURL, packageURL.appendingPathComponent("main.nf").standardizedFileURL)
        XCTAssertEqual(request.engine, .nextflow)
        XCTAssertEqual(request.inputURLs, [referenceURL.standardizedFileURL, readsURL.standardizedFileURL])
        XCTAssertEqual(
            request.expectedOutputURLs,
            [outputURL.appendingPathComponent("hello-world-nextflow.lungfishref", isDirectory: true).standardizedFileURL]
        )
        XCTAssertEqual(request.params["reference_bundle"], referenceURL.standardizedFileURL.path)
        XCTAssertEqual(request.params["reads_bundle"], readsURL.standardizedFileURL.path)
        XCTAssertEqual(request.params["outdir"], outputURL.standardizedFileURL.path)
        XCTAssertEqual(bundleRoot, outputURL.appendingPathComponent("Workflow Runs", isDirectory: true).standardizedFileURL)
        XCTAssertTrue(request.cliArguments(bundlePath: bundleRoot.appendingPathComponent("run.lungfishrun")).contains("--expected-output"))
    }

    func testONTGenotypingLaunchRequestUsesConfiguredSimpleOptions() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setReads([readsURL])
        state.setOutputDirectory(outputURL)
        state.outputName = "sample-ont"
        state.threads = 6
        state.minSupport = 3

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }

        XCTAssertEqual(request.inputFASTQURL, readsURL.standardizedFileURL)
        XCTAssertEqual(request.referenceSourceURL, referenceURL.standardizedFileURL)
        XCTAssertEqual(request.barcodeDefinitionsURL, barcodesURL.standardizedFileURL)
        XCTAssertEqual(
            request.outputDirectory,
            outputURL.appendingPathComponent("sample-ont.lungfishgenotype", isDirectory: true).standardizedFileURL
        )
        XCTAssertEqual(request.outputName, "sample-ont")
        XCTAssertEqual(request.analysisName, "sample-ont")
        XCTAssertEqual(request.threads, 6)
        XCTAssertEqual(request.minSupport, 3)
        XCTAssertNil(request.haplotypeAssayID)
        XCTAssertNil(request.haplotypeDefinitionSetID)
    }

    func testTwelveSAmpliconMatchingLaunchRequestUsesFastaReferenceAndMultipleReadBundles() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("amplicons_12s.fa")
        let firstReadsURL = temp.appendingPathComponent("hilo-f09.lungfishfastq", isDirectory: true)
        let secondReadsURL = temp.appendingPathComponent("hilo-f10.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try Data(">target\nACGT\n".utf8).write(to: referenceURL)
        for url in [firstReadsURL, secondReadsURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [firstReadsURL, secondReadsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        try enableTwelveSAmpliconMatching(in: enablementStore)
        let twelveSTool = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        state.selectTool(twelveSTool.id)
        state.setReference(referenceURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "hilo-12s"
        state.twelveSMinimumSoftClipBases = 2
        state.twelveSMaximumIndelBases = 5
        state.threads = 6
        state.twelveSRunChimeraReview = false

        XCTAssertEqual(state.readinessText, "Ready to run.")
        XCTAssertTrue(state.isRunEnabled)
        let launchRequest = try state.makeLaunchRequest()
        guard case .twelveSAmpliconMatching(let configuration) = launchRequest else {
            return XCTFail("Expected 12S amplicon matching request")
        }

        XCTAssertEqual(configuration.inputFASTQs, [
            firstReadsURL.standardizedFileURL,
            secondReadsURL.standardizedFileURL,
        ])
        XCTAssertEqual(configuration.referenceFASTA, referenceURL.standardizedFileURL)
        XCTAssertEqual(configuration.outputDirectory, outputURL.standardizedFileURL)
        XCTAssertEqual(configuration.outputName, "hilo-12s")
        XCTAssertEqual(configuration.minimumSoftClipBases, 2)
        XCTAssertEqual(configuration.maximumIndelBases, 5)
        XCTAssertEqual(configuration.matchingMode, .illuminaExact)
        XCTAssertEqual(configuration.threads, 6)
        XCTAssertFalse(configuration.runChimeraReview)
        XCTAssertFalse(configuration.forceOverwrite)
    }

    func testTwelveSAmpliconMatchingLaunchRequestCarriesAnalysisSampleMetadata() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("amplicons_12s.fa")
        let readsURL = temp.appendingPathComponent("hilo-f09.lungfishfastq", isDirectory: true)
        let metadataURL = temp.appendingPathComponent("analysis-metadata.tsv")
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try Data(">target\nACGT\n".utf8).write(to: referenceURL)
        try Data("sample_id\tsite\nhilo-f09\tHilo WWTP\n".utf8).write(to: metadataURL)
        for url in [readsURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        try enableTwelveSAmpliconMatching(in: enablementStore)
        let twelveSTool = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        state.selectTool(twelveSTool.id)
        state.setReference(referenceURL)
        state.setTwelveSSampleMetadata(metadataURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "hilo-12s"

        let launchRequest = try state.makeLaunchRequest()
        guard case .twelveSAmpliconMatching(let configuration) = launchRequest else {
            return XCTFail("Expected 12S amplicon matching request")
        }

        XCTAssertEqual(configuration.sampleMetadata, metadataURL.standardizedFileURL)
        XCTAssertEqual(
            state.twelveSSampleMetadataDisplay,
            WorkflowOperationDialogState.displayPath(for: metadataURL, relativeTo: temp)
        )
    }

    func testTwelveSAmpliconMatchingResolvesProjectReferenceBundleToEmbeddedFasta() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let projectURL = temp.appendingPathComponent("project.lungfish", isDirectory: true)
        let sourceFastaURL = temp.appendingPathComponent("amplicons_12s.fa")
        let readsURL = projectURL.appendingPathComponent("Imports/hilo-f09.lungfishfastq", isDirectory: true)
        let outputURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data(">target\nACGT\n".utf8).write(to: sourceFastaURL)

        let referenceBundleURL = try ReferenceSequenceFolder.importReference(
            from: sourceFastaURL,
            into: projectURL,
            displayName: "amplicons_12s"
        )
        let expectedFastaURL = try XCTUnwrap(ReferenceSequenceFolder.fastaURL(in: referenceBundleURL))

        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        try enableTwelveSAmpliconMatching(in: enablementStore)
        let twelveSTool = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        state.selectTool(twelveSTool.id)
        state.setReference(referenceBundleURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "hilo-12s"

        XCTAssertEqual(state.readinessText, "Ready to run.")
        XCTAssertTrue(state.isRunEnabled)
        let launchRequest = try state.makeLaunchRequest()
        guard case .twelveSAmpliconMatching(let configuration) = launchRequest else {
            return XCTFail("Expected 12S amplicon matching request")
        }

        XCTAssertEqual(configuration.referenceFASTA, expectedFastaURL.standardizedFileURL)
    }

    func testTwelveSAmpliconMatchingResolvesFullReferenceBundleGenomeFasta() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let projectURL = temp.appendingPathComponent("project.lungfish", isDirectory: true)
        let referenceBundleURL = projectURL
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("amplicons_12s_deduplicated.lungfishref", isDirectory: true)
        let genomeURL = referenceBundleURL.appendingPathComponent("genome", isDirectory: true)
        let sequenceURL = genomeURL.appendingPathComponent("sequence.fa.gz")
        let readsURL = projectURL.appendingPathComponent("Imports/hilo-f09.lungfishfastq", isDirectory: true)
        let outputURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        for url in [genomeURL, readsURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data(">target\nACGT\n".utf8).write(to: sequenceURL)
        try Data("target\t4\t8\t4\t5\n".utf8).write(to: genomeURL.appendingPathComponent("sequence.fa.gz.fai"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.gzi"))
        let manifest = BundleManifest(
            name: "12S Amplicons",
            identifier: "org.lungfish.test.12s",
            source: SourceInfo(organism: "12S reference", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 4,
                chromosomes: [
                    ChromosomeInfo(name: "target", length: 4, offset: 8, lineBases: 4, lineWidth: 5),
                ]
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: referenceBundleURL.appendingPathComponent(BundleManifest.filename))

        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        try enableTwelveSAmpliconMatching(in: enablementStore)
        let twelveSTool = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        state.selectTool(twelveSTool.id)
        state.setReference(referenceBundleURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "hilo-12s"

        XCTAssertEqual(state.readinessText, "Ready to run.")
        let launchRequest = try state.makeLaunchRequest()
        guard case .twelveSAmpliconMatching(let configuration) = launchRequest else {
            return XCTFail("Expected 12S amplicon matching request")
        }

        XCTAssertEqual(configuration.referenceFASTA, sequenceURL.standardizedFileURL)
    }

    func testTwelveSAmpliconMatchingResolvesTwelveSReferenceBundleFastaAndMetadata() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let projectURL = temp.appendingPathComponent("project.lungfish", isDirectory: true)
        let referenceBundleURL = projectURL
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("MIDORI-12S.lungfish12sref", isDirectory: true)
        let readsURL = projectURL.appendingPathComponent("Imports/hilo-f09.lungfishfastq", isDirectory: true)
        let outputURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        for url in [referenceBundleURL, readsURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let fastaURL = referenceBundleURL.appendingPathComponent("reference.fa")
        let metadataURL = referenceBundleURL.appendingPathComponent("target-metadata.tsv")
        try Data(">target\nACGT\n".utf8).write(to: fastaURL)
        try Data("target_id\tsequence_sha256\nref\tsha\n".utf8).write(to: metadataURL)
        try TwelveSReferenceBundle.writeManifest(
            TwelveSReferenceBundleManifest(
                name: "MIDORI 12S",
                referenceFastaPath: "reference.fa",
                targetMetadataPath: "target-metadata.tsv",
                metrics: TwelveSReferenceBundleMetrics(
                    referenceCount: 1,
                    metadataRowCount: 1,
                    taxidCount: 1,
                    taxonGroupCount: 1,
                    taxonomyCount: 1,
                    alternateMatchCount: 0
                ),
                provenancePath: ".lungfish-provenance.json",
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: referenceBundleURL
        )

        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        try enableTwelveSAmpliconMatching(in: enablementStore)
        let twelveSTool = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        state.selectTool(twelveSTool.id)
        state.setReference(referenceBundleURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "hilo-12s"

        XCTAssertTrue(state.projectReferenceCandidates.contains(referenceBundleURL.standardizedFileURL))
        XCTAssertEqual(state.readinessText, "Ready to run.")
        let launchRequest = try state.makeLaunchRequest()
        guard case .twelveSAmpliconMatching(let configuration) = launchRequest else {
            return XCTFail("Expected 12S amplicon matching request")
        }

        XCTAssertEqual(configuration.referenceFASTA, fastaURL.standardizedFileURL)
        XCTAssertEqual(configuration.referenceMetadata, metadataURL.standardizedFileURL)
        XCTAssertEqual(configuration.referenceBundleURL, referenceBundleURL.standardizedFileURL)
    }

    func testTwelveSAmpliconMatchingRequiresFastaReference() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("hilo-f09.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        for url in [referenceURL, readsURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        try enableTwelveSAmpliconMatching(in: enablementStore)
        let twelveSTool = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        state.selectTool(twelveSTool.id)
        state.setReference(referenceURL)
        state.setOutputDirectory(outputURL)

        XCTAssertEqual(state.readinessText, "Select a 12S reference FASTA file or reference bundle.")
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertThrowsError(try state.makeLaunchRequest())
    }

    func testONTGenotypingLaunchRequestUsesExplicitAssayScopedHaplotypeDefinition() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setReads([readsURL])
        state.setOutputDirectory(outputURL)

        XCTAssertNil(state.selectedHaplotypeDefinitionSetID)
        state.selectedHaplotypeAssayID = "MHC-exon2-miSeq"
        state.selectedHaplotypeDefinitionSetID = "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }

        XCTAssertEqual(request.haplotypeAssayID, "MHC-exon2-miSeq")
        XCTAssertEqual(request.haplotypeDefinitionSetID, "MHC-exon2-miSeq.mauritian-cynomolgus-macaques")
    }

    func testONTGenotypingLaunchRequestIncludesOperationHaplotypeThresholds() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setReads([readsURL])
        state.setOutputDirectory(outputURL)
        state.selectedHaplotypeAssayID = "MHC-exon2-miSeq"
        state.selectedHaplotypeDefinitionSetID = "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        state.haplotypeDropoutSamplePercent = 0.1
        state.haplotypeDropoutLocusPercent = 1.0
        state.haplotypeDropoutLocusOverridePercents = [
            "MHC-DQ": 10.0,
            "MHC-DP": 10.0,
        ]

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }

        XCTAssertNil(request.haplotypeDropoutSampleFraction)
        XCTAssertEqual(request.haplotypeDropoutLocusFraction ?? -1, 0.01, accuracy: 0.000001)
        XCTAssertTrue(request.haplotypeDropoutLocusFractionOverrides.isEmpty)
    }

    func testHaplotypeDefinitionSelectionTracksAssayScope() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let projectRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        // Definitions now come exclusively from project `.lungfishmhcref` bundles, so the
        // selectable definition is provided by a bundle rather than a removed built-in.
        let definition = Self.mhcDefinition(id: "MHC-exon2-miSeq.rhesus-macaques")
        try makeMHCReferenceBundle(in: projectRoot, definition: definition)

        let state = WorkflowOperationDialogState(
            projectURL: projectRoot,
            enablementStore: enablementStore,
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        )

        state.setHaplotypeAssay(nil)
        state.setHaplotypeDefinition(definition.id)

        XCTAssertEqual(state.selectedHaplotypeAssayID, definition.assayID)
        XCTAssertEqual(state.selectedHaplotypeDefinitionSetID, definition.id)

        // Switching to an assay with no matching definition must clear the selection.
        state.setHaplotypeAssay("unsupported-assay")

        XCTAssertEqual(state.selectedHaplotypeAssayID, "unsupported-assay")
        XCTAssertNil(state.selectedHaplotypeDefinitionSetID)
    }

    func testHaplotypeDefinitionSelectionIncludesProjectBundleDefinitions() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let projectRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        // A project-local custom definition is selectable in the dialog only when it is
        // packaged as a `.lungfishmhcref` bundle (bare project-store defs are not surfaced
        // by the bundle-only GUI registry).
        let custom = GenotypeHaplotypeDefinitionSet(
            id: "custom.mhc-exon2.test",
            assayID: "MHC-exon2-miSeq",
            displayName: "Custom Test Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [GenotypeHaplotypeDefinition(name: "T1B", diagnosticAlleles: ["12_T1_B_001_01"])]
                )
            ]
        )
        try makeMHCReferenceBundle(in: projectRoot, definition: custom, name: "Custom Test MHC")

        let state = WorkflowOperationDialogState(
            projectURL: projectRoot,
            enablementStore: enablementStore,
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        )

        state.setHaplotypeAssay("MHC-exon2-miSeq")
        state.setHaplotypeDefinition(custom.id)

        XCTAssertEqual(state.haplotypeDefinitionRegistry.definitionSet(id: custom.id)?.displayName, "Custom Test Definition")
        XCTAssertEqual(state.selectedHaplotypeDefinitionSetID, custom.id)
        XCTAssertEqual(state.selectedHaplotypeAssayID, "MHC-exon2-miSeq")
    }

    func testONTGenotypingKeepsExplicitGenotypeBundleOutputDirectory() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let bundleURL = temp.appendingPathComponent("custom.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setReads([readsURL])
        state.setOutputDirectory(bundleURL)
        state.outputName = "sample-ont"

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }

        XCTAssertEqual(request.outputDirectory, bundleURL.standardizedFileURL)
    }

    func testONTGenotypingPrefersProjectBarcodeDefinitionCandidates() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let projectURL = try temporaryDirectory()
        let barcodesURL = projectURL.appendingPathComponent("Barcode Definitions/fluidigm.tsv")
        let hiddenBarcodeURL = projectURL.appendingPathComponent(".hidden/ignored.tsv")
        let bundledBarcodeURL = projectURL.appendingPathComponent("Reads/sample.lungfishfastq/ignored.csv")
        let referenceBundleBarcodeURL = projectURL.appendingPathComponent("Reference Sequences/ref.lungfishref/ignored.tsv")
        for url in [barcodesURL, hiddenBarcodeURL, bundledBarcodeURL, referenceBundleBarcodeURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("sample\tbarcode\nDW472\tACGT\n".utf8).write(to: url)
        }

        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        XCTAssertEqual(state.projectBarcodeDefinitionCandidates, [barcodesURL.standardizedFileURL])
        XCTAssertEqual(state.selectedBarcodeDefinitionURL, barcodesURL.standardizedFileURL)
    }

    func testExternalBarcodeDefinitionIsImportedIntoProjectBeforeONTLaunch() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let projectURL = temp.appendingPathComponent("project.lungfish", isDirectory: true)
        let externalURL = temp.appendingPathComponent("external/barcodes.csv")
        let referenceURL = projectURL.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = projectURL.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let outputURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: externalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: externalURL)

        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setBarcodeDefinition(externalURL)
        state.setReads([readsURL])
        state.setOutputDirectory(outputURL)

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }

        let importedURL = projectURL.appendingPathComponent("Barcode Definitions/barcodes.csv").standardizedFileURL
        XCTAssertEqual(request.barcodeDefinitionsURL, importedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))
        XCTAssertEqual(try String(contentsOf: importedURL, encoding: .utf8), "sample,barcode\nDW472,ACGT\n")

        let provenanceURL = importedURL.appendingPathExtension("lungfish-provenance.json")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.workflowName, "Workflow Operations Barcode Definition Import")
        XCTAssertEqual(envelope.outputs.map(\.path), [importedURL.path])
        XCTAssertTrue(envelope.files.contains {
            $0.path == externalURL.standardizedFileURL.path && $0.role == .input
        })
    }

    func testONTGenotypingTreatsMultipleSelectedReadBundlesAsSampleBundles() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let firstReadsURL = temp.appendingPathComponent("reads-a.lungfishfastq", isDirectory: true)
        let secondReadsURL = temp.appendingPathComponent("reads-b.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: firstReadsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondReadsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [firstReadsURL, secondReadsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.selectedGenotypingMode = .auto
        state.selectedGenotypingReadType = .ont
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setOutputDirectory(outputURL)

        XCTAssertEqual(state.selectedReadURLs, [
            firstReadsURL.standardizedFileURL,
            secondReadsURL.standardizedFileURL,
        ])
        XCTAssertEqual(state.datasetLabel, "2 read bundles selected")
        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Ready to run.")

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }
        XCTAssertEqual(request.inputFASTQURLs, [
            firstReadsURL.standardizedFileURL,
            secondReadsURL.standardizedFileURL,
        ])
        XCTAssertNil(request.barcodeDefinitionsURL)
        XCTAssertEqual(request.mode, .ontSampleBundles)
        XCTAssertEqual(request.readType, .ont)
    }

    func testAmpliconGenotypingIlluminaModeAllowsMultipleReadBundlesWithoutBarcodes() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let firstReadsURL = temp.appendingPathComponent("dw001.lungfishfastq", isDirectory: true)
        let secondReadsURL = temp.appendingPathComponent("dw002.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        for url in [referenceURL, firstReadsURL, secondReadsURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [firstReadsURL, secondReadsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.selectedGenotypingMode = .auto
        state.selectedGenotypingReadType = .illumina
        state.setReference(referenceURL)
        state.setBarcodeDefinition(nil)
        state.setOutputDirectory(outputURL)

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Ready to run.")
        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected amplicon genotyping request")
        }
        XCTAssertEqual(request.inputFASTQURLs, [firstReadsURL.standardizedFileURL, secondReadsURL.standardizedFileURL])
        XCTAssertNil(request.barcodeDefinitionsURL)
        XCTAssertEqual(request.mode, .illuminaPaired)
        XCTAssertEqual(request.readType, .illumina)
    }

    func testAmpliconGenotypingONTSampleBundleModeAllowsMultipleReadBundlesWithoutBarcodes() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let firstReadsURL = temp.appendingPathComponent("lf2871.lungfishfastq", isDirectory: true)
        let secondReadsURL = temp.appendingPathComponent("lf2872.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        for url in [referenceURL, firstReadsURL, secondReadsURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [firstReadsURL, secondReadsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.selectedGenotypingMode = .auto
        state.selectedGenotypingReadType = .ont
        state.setReference(referenceURL)
        state.setBarcodeDefinition(nil)
        state.setOutputDirectory(outputURL)

        XCTAssertTrue(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Ready to run.")
        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected amplicon genotyping request")
        }
        XCTAssertEqual(request.inputFASTQURLs, [firstReadsURL.standardizedFileURL, secondReadsURL.standardizedFileURL])
        XCTAssertNil(request.barcodeDefinitionsURL)
        XCTAssertEqual(request.mode, .ontSampleBundles)
        XCTAssertEqual(request.readType, .ont)
    }

    func testAmpliconGenotypingDefaultsReadTypeFromSelectedFASTQMetadata() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        let firstReadsURL = temp.appendingPathComponent("barcode10.lungfishfastq", isDirectory: true)
        let secondReadsURL = temp.appendingPathComponent("barcode11.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)
        for bundleURL in [referenceURL, firstReadsURL, secondReadsURL, outputURL] {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        }
        for bundleURL in [firstReadsURL, secondReadsURL] {
            let fastqURL = bundleURL.appendingPathComponent("reads.fastq")
            try "@\(bundleURL.deletingPathExtension().lastPathComponent)\nACGT\n+\nIIII\n".write(
                to: fastqURL,
                atomically: true,
                encoding: .utf8
            )
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(assemblyReadType: .ontReads),
                for: fastqURL
            )
        }

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [firstReadsURL, secondReadsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setOutputDirectory(outputURL)

        XCTAssertEqual(state.selectedGenotypingReadType, .ont)
        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected amplicon genotyping request")
        }
        XCTAssertEqual(request.inputFASTQURLs, [firstReadsURL.standardizedFileURL, secondReadsURL.standardizedFileURL])
        XCTAssertEqual(request.readType, .ont)
    }

    func testReconfiguringForNewProjectResetsBarcodeDefinitionToProjectCandidate() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let firstProjectURL = temp.appendingPathComponent("first.lungfish", isDirectory: true)
        let secondProjectURL = temp.appendingPathComponent("second.lungfish", isDirectory: true)
        let firstBarcodesURL = firstProjectURL.appendingPathComponent("Barcode Definitions/first.tsv")
        let secondBarcodesURL = secondProjectURL.appendingPathComponent("Barcode Definitions/second.tsv")
        let secondReadsURL = secondProjectURL.appendingPathComponent("Reads/sample.lungfishfastq", isDirectory: true)
        for url in [firstBarcodesURL, secondBarcodesURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("sample\tbarcode\nDW472\tACGT\n".utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: secondReadsURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: firstProjectURL,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        XCTAssertEqual(state.selectedBarcodeDefinitionURL, firstBarcodesURL.standardizedFileURL)

        state.configureProject(projectURL: secondProjectURL, selectedReadURLs: [secondReadsURL])

        XCTAssertEqual(state.projectBarcodeDefinitionCandidates, [secondBarcodesURL.standardizedFileURL])
        XCTAssertEqual(state.selectedBarcodeDefinitionURL, secondBarcodesURL.standardizedFileURL)
    }

    func testReconfiguringForNewProjectResetsReferenceAndOutputDirectory() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let firstProjectURL = temp.appendingPathComponent("first.lungfish", isDirectory: true)
        let secondProjectURL = temp.appendingPathComponent("second.lungfish", isDirectory: true)
        let firstReferenceURL = firstProjectURL.appendingPathComponent("Reference Sequences/ref-a.lungfishref", isDirectory: true)
        let secondReferenceURL = secondProjectURL.appendingPathComponent("Reference Sequences/ref-b.lungfishref", isDirectory: true)
        let secondReadsURL = secondProjectURL.appendingPathComponent("Reads/sample.lungfishfastq", isDirectory: true)
        for url in [firstReferenceURL, secondReferenceURL, secondReadsURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let state = WorkflowOperationDialogState(
            projectURL: firstProjectURL,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        XCTAssertEqual(state.selectedReferenceURL, firstReferenceURL.standardizedFileURL)
        XCTAssertEqual(
            state.outputDirectoryURL,
            firstProjectURL
                .appendingPathComponent("Analyses/Amplicon genotyping results", isDirectory: true)
                .standardizedFileURL
        )

        state.configureProject(projectURL: secondProjectURL, selectedReadURLs: [secondReadsURL])

        XCTAssertEqual(state.projectURL, secondProjectURL.standardizedFileURL)
        XCTAssertEqual(state.selectedReferenceURL, secondReferenceURL.standardizedFileURL)
        XCTAssertEqual(state.selectedReadURLs, [secondReadsURL.standardizedFileURL])
        XCTAssertEqual(
            state.outputDirectoryURL,
            secondProjectURL
                .appendingPathComponent("Analyses/Amplicon genotyping results", isDirectory: true)
                .standardizedFileURL
        )
    }

    func testONTGenotypingDefaultsToDedicatedAnalysesResultsDirectory() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        XCTAssertEqual(
            state.outputDirectoryURL,
            temp.appendingPathComponent("Analyses/Amplicon genotyping results", isDirectory: true).standardizedFileURL
        )
    }

    func testWorkflowOperationsDialogTreatsFASTQBundlesAsSidebarOnlySelection() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )
        let readPicker = try sourceBlock(
            startingAt: "    private var readPicker: some View",
            endingBefore: "    private var barcodePicker: some View",
            in: source
        )
        let referencePicker = try sourceBlock(
            startingAt: "    private var referencePicker: some View",
            endingBefore: "    private var readPicker: some View",
            in: source
        )

        XCTAssertTrue(readPicker.contains("Text(state.selectedReadsDisplay)"))
        XCTAssertFalse(readPicker.contains("Button("), "FASTQ bundles must be fixed to the project sidebar selection for the dialog lifetime.")
        XCTAssertFalse(source.contains("browseForReads"))
        XCTAssertFalse(source.contains("Choose FASTQ Bundles"))
        XCTAssertFalse(source.contains("state.setReads([])"))

        XCTAssertTrue(referencePicker.contains("browseForReference()"))
        XCTAssertTrue(referencePicker.contains("Button("), "Reference selection should remain editable.")
    }

    func testWorkflowOperationsDialogShowsProjectBarcodeDefinitionPicker() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )
        let barcodePicker = try sourceBlock(
            startingAt: "    private var barcodePicker: some View",
            endingBefore: "    @ViewBuilder\n    private var primarySettings",
            in: source
        )

        XCTAssertTrue(source.contains("state.effectiveGenotypingMode == .ontBarcodeDemux"))
        XCTAssertTrue(barcodePicker.contains("Picker(\"Project File\""))
        XCTAssertTrue(barcodePicker.contains("barcodeDefinitionProjectFileBinding"))
    }

    func testWorkflowOperationsDialogShowsTwelveSMatchingModeAsPrimaryGUIControl() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )
        let primarySettings = try sourceBlock(
            startingAt: "    @ViewBuilder\n    private var primarySettings",
            endingBefore: "    private var genotypingModePicker",
            in: source
        )
        let matchingModePicker = try sourceBlock(
            startingAt: "    private var twelveSMatchingModePicker: some View",
            endingBefore: "    private var genotypingModePicker",
            in: source
        )

        XCTAssertTrue(primarySettings.contains("twelveSMatchingModePicker"))
        XCTAssertTrue(matchingModePicker.contains("Picker(\"Read Platform\""))
        XCTAssertTrue(matchingModePicker.contains("TwelveSAmpliconMatchingMode.allCases"))
        XCTAssertTrue(matchingModePicker.contains(".pickerStyle(.segmented)"))
    }

    func testWorkflowOperationsRunClosesWindowAsSoonAsLaunchIsAccepted() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsWindowController.swift"),
            encoding: .utf8
        )
        let runStart = try XCTUnwrap(
            source.range(of: "    private func run(_ request: WorkflowOperationLaunchRequest) {")
        )
        let runSuffix = source[runStart.lowerBound...]
        let closeRange = try XCTUnwrap(runSuffix.range(of: "window?.close()"))
        let taskRange = try XCTUnwrap(runSuffix.range(of: "Task { @MainActor [weak self] in"))

        XCTAssertLessThan(
            closeRange.lowerBound,
            taskRange.lowerBound,
            "The workflow operations window should dismiss immediately after accepting Run, before waiting on the async operation."
        )
    }

    func testWorkflowOperationDialogStateCachesToolListAcrossUnrelatedEdits() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift"),
            encoding: .utf8
        )
        let toolsProperty = try sourceBlock(
            startingAt: "    var tools: [WorkflowOperationTool] {",
            endingBefore: "    var sidebarItems: [DatasetOperationToolSidebarItem] {",
            in: source
        )
        let refreshMethod = try sourceBlock(
            startingAt: "    func refreshWorkflowAvailability() {",
            endingBefore: "    func refreshProjectReferences",
            in: source
        )

        XCTAssertTrue(source.contains("private var cachedTools: [WorkflowOperationTool]"))
        XCTAssertTrue(toolsProperty.contains("cachedTools"))
        XCTAssertFalse(
            toolsProperty.contains("Self.makeTools"),
            "Reading dialog tools should not revalidate workflow packages during every SwiftUI body refresh."
        )
        XCTAssertTrue(refreshMethod.contains("cachedTools = Self.makeTools"))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "WorkflowOperationDialogStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// 12S amplicon matching is a niche, opt-in workflow (disabled on fresh
    /// install), so dialog tests that exercise it must enable it explicitly.
    private func enableTwelveSAmpliconMatching(in store: WorkflowLibraryEnablementStore) throws {
        let item = try XCTUnwrap(WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.twelveSAmpliconMatchingID))
        store.setWorkflow(item, enabled: true)
    }

    /// Writes a project-scoped `.lungfishmhcref` bundle containing `definition` under the
    /// project's `Reference Sequences/` folder. The dialog's bundle-only haplotype
    /// registry resolves definitions exclusively from such bundles.
    @discardableResult
    private func makeMHCReferenceBundle(
        in projectRoot: URL,
        definition: GenotypeHaplotypeDefinitionSet,
        name: String = "Project MHC"
    ) throws -> URL {
        let bundleURL = projectRoot
            .appendingPathComponent("Reference Sequences", isDirectory: true)
            .appendingPathComponent("\(definition.speciesCode)-MHC.lungfishmhcref", isDirectory: true)
        let definitionRelativePath = "haplotypes/\(definition.id).lungfishhaplotypedef.json"
        let definitionURL = bundleURL.appendingPathComponent(definitionRelativePath)
        try FileManager.default.createDirectory(
            at: definitionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ">M1\nACGT\n".write(
            to: bundleURL.appendingPathComponent("reference.fa"),
            atomically: true,
            encoding: .utf8
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: definitionURL, options: .atomic)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                name: name,
                referenceFastaPath: "reference.fa",
                haplotypeDefinitionPaths: [definitionRelativePath],
                defaultHaplotypeDefinitionID: definition.id,
                metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 1),
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: bundleURL
        )
        return bundleURL.standardizedFileURL
    }

    private func helloWorldNextflowPackageURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg", isDirectory: true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowOperationDialogStateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func waitForMainQueue() {
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }

    private static func mhcDefinition(id: String) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM MHC",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "MHC",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "MHC-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1", diagnosticAlleles: ["M1"])
                    ]
                )
            ]
        )
    }

    private func sourceBlock(
        startingAt startNeedle: String,
        endingBefore endNeedle: String,
        in source: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startNeedle))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: endNeedle))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
