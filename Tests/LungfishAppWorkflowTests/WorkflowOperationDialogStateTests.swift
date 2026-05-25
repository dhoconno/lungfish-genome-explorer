import XCTest
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

        let ont = try XCTUnwrap(state.tools.first { $0.title == "ONT Genotyping" })
        XCTAssertEqual(ont.availability, .available)
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
        var ont = try XCTUnwrap(state.tools.first { $0.title == "ONT Genotyping" })
        XCTAssertEqual(ont.availability, .available)

        libraryStore.setWorkflow(.ontGenotyping, enabled: false)

        ont = try XCTUnwrap(state.tools.first { $0.title == "ONT Genotyping" })
        XCTAssertEqual(ont.availability, .disabled(reason: "Enable in Library"))

        libraryStore.setWorkflow(.ontGenotyping, enabled: true)

        ont = try XCTUnwrap(state.tools.first { $0.title == "ONT Genotyping" })
        XCTAssertEqual(ont.availability, .available)
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

    func testHaplotypeDefinitionSelectionTracksAssayScope() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: enablementStore,
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        )

        state.setHaplotypeAssay(nil)
        state.setHaplotypeDefinition("MHC-exon2-miSeq.rhesus-macaques")

        XCTAssertEqual(state.selectedHaplotypeAssayID, "MHC-exon2-miSeq")
        XCTAssertEqual(state.selectedHaplotypeDefinitionSetID, "MHC-exon2-miSeq.rhesus-macaques")

        state.setHaplotypeAssay("unsupported-assay")

        XCTAssertEqual(state.selectedHaplotypeAssayID, "unsupported-assay")
        XCTAssertNil(state.selectedHaplotypeDefinitionSetID)
    }

    func testHaplotypeDefinitionSelectionIncludesProjectUserDefinitions() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let projectRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: projectRoot) }
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
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(custom)

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

    func testONTGenotypingRequiresExactlyOneSelectedReadBundle() throws {
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
        state.setReference(referenceURL)
        state.setBarcodeDefinition(barcodesURL)
        state.setOutputDirectory(outputURL)

        XCTAssertEqual(state.selectedReadURLs, [
            firstReadsURL.standardizedFileURL,
            secondReadsURL.standardizedFileURL,
        ])
        XCTAssertEqual(state.datasetLabel, "2 read bundles selected")
        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(state.readinessText, "Select one ONT barcode FASTQ bundle.")

        XCTAssertThrowsError(try state.makeLaunchRequest())
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
                .appendingPathComponent("Analyses/ONT genotyping results", isDirectory: true)
                .standardizedFileURL
        )

        state.configureProject(projectURL: secondProjectURL, selectedReadURLs: [secondReadsURL])

        XCTAssertEqual(state.projectURL, secondProjectURL.standardizedFileURL)
        XCTAssertEqual(state.selectedReferenceURL, secondReferenceURL.standardizedFileURL)
        XCTAssertEqual(state.selectedReadURLs, [secondReadsURL.standardizedFileURL])
        XCTAssertEqual(
            state.outputDirectoryURL,
            secondProjectURL
                .appendingPathComponent("Analyses/ONT genotyping results", isDirectory: true)
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
            temp.appendingPathComponent("Analyses/ONT genotyping results", isDirectory: true).standardizedFileURL
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

        XCTAssertTrue(barcodePicker.contains("Picker(\"Project File\""))
        XCTAssertTrue(barcodePicker.contains("barcodeDefinitionProjectFileBinding"))
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

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "WorkflowOperationDialogStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
