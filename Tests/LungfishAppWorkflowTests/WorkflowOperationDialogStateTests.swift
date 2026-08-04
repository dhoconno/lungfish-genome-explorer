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

        let ont = try XCTUnwrap(state.tools.first { $0.title == "miSeq amplicon MHC genotyping" })
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

    func testAsynchronousProjectDiscoveryPublishesProjectDefaults() async throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("Reference Sequences/ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("Reads/reads.lungfishfastq", isDirectory: true)
        let barcodesURL = temp.appendingPathComponent("barcodes.csv")
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: barcodesURL)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            projectDiscoveryMode: .asynchronous,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        try await waitForProjectDiscovery(state)

        XCTAssertEqual(state.projectReferenceCandidates, [referenceURL.standardizedFileURL])
        XCTAssertEqual(state.selectedReferenceURL, referenceURL.standardizedFileURL)
        XCTAssertEqual(state.projectBarcodeDefinitionCandidates, [barcodesURL.standardizedFileURL])
        XCTAssertEqual(state.selectedBarcodeDefinitionURL, barcodesURL.standardizedFileURL)
        XCTAssertFalse(state.isDiscoveringProjectResources)
    }

    func testAsynchronousProjectDiscoveryPreservesManualSelectionsMadeDuringScan() async throws {
        WorkflowOperationDialogState.testingProjectDiscoveryDelay = .milliseconds(80)
        defer { WorkflowOperationDialogState.testingProjectDiscoveryDelay = nil }
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let discoveredReferenceURL = temp.appendingPathComponent("Reference Sequences/ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("Reads/reads.lungfishfastq", isDirectory: true)
        let discoveredBarcodesURL = temp.appendingPathComponent("barcodes.csv")
        let manualReferenceURL = temp.appendingPathComponent("Manual/manual.lungfishref", isDirectory: true)
        let manualBarcodesURL = temp.appendingPathComponent("Manual/barcodes.tsv")
        try FileManager.default.createDirectory(at: discoveredReferenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manualReferenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manualBarcodesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sample,barcode\nDW472,ACGT\n".utf8).write(to: discoveredBarcodesURL)
        try Data("sample\tbarcode\nDW999\tTGCA\n".utf8).write(to: manualBarcodesURL)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            projectDiscoveryMode: .asynchronous,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(manualReferenceURL)
        state.setBarcodeDefinition(manualBarcodesURL)

        try await waitForProjectDiscovery(state)

        XCTAssertEqual(state.selectedReferenceURL, manualReferenceURL.standardizedFileURL)
        XCTAssertEqual(state.selectedBarcodeDefinitionURL, manualBarcodesURL.standardizedFileURL)
        XCTAssertTrue(state.projectReferenceCandidates.contains(discoveredReferenceURL.standardizedFileURL))
        XCTAssertTrue(state.projectBarcodeDefinitionCandidates.contains(discoveredBarcodesURL.standardizedFileURL))
        XCTAssertFalse(state.isDiscoveringProjectResources)
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
        state.setAmpliconAnalysisMode(.deterministicHaplotyping)
        state.setReference(referenceURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "barcode10-mhc"

        XCTAssertEqual(state.selectedHaplotypeDefinitionSetID, definition.id)
        XCTAssertEqual(state.selectedHaplotypeAssayID, definition.assayID)
        XCTAssertEqual(state.selectedHaplotypeSpeciesCode, definition.speciesCode)
        XCTAssertEqual(state.selectedMHCReferenceBundleURL, referenceURL.standardizedFileURL)
        let launch = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launch else {
            return XCTFail("Expected ONT genotyping request")
        }
        XCTAssertEqual(request.referenceSourceURL, referenceURL.standardizedFileURL)
        XCTAssertNil(request.presetID)
        XCTAssertEqual(request.haplotypeDefinitionSetID, definition.id)
        XCTAssertEqual(request.haplotypeAssayID, definition.assayID)
        XCTAssertEqual(request.haplotypeSpeciesCode, definition.speciesCode)
        XCTAssertEqual(request.resultWorkflowKind, .miSeqAmpliconMHCGenotype)
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
        state.setAmpliconAnalysisMode(.deterministicHaplotyping)

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
        var ont = try XCTUnwrap(state.tools.first { $0.title == "miSeq amplicon MHC genotyping" })
        XCTAssertEqual(ont.availability, .available)
        var twelveS = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        XCTAssertEqual(twelveS.availability, .available)

        libraryStore.setWorkflow(.ontGenotyping, enabled: false)
        libraryStore.setWorkflow(twelveSItem, enabled: false)

        ont = try XCTUnwrap(state.tools.first { $0.title == "miSeq amplicon MHC genotyping" })
        XCTAssertEqual(ont.availability, .disabled(reason: "Enable in Library"))
        twelveS = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        XCTAssertEqual(twelveS.availability, .disabled(reason: "Enable in Library"))

        libraryStore.setWorkflow(.ontGenotyping, enabled: true)
        libraryStore.setWorkflow(twelveSItem, enabled: true)

        ont = try XCTUnwrap(state.tools.first { $0.title == "miSeq amplicon MHC genotyping" })
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

    func testOperationsDialogStateInvalidatesWhenEnablementNotificationPostsOffMainThread() async throws {
        let defaults = try makeDefaults()
        let operationsStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: operationsStore,
            packageStore: packageStore
        )
        let initialRevision = state.workflowAvailabilityRevision
        let posted = expectation(description: "background notification posted")

        DispatchQueue.global(qos: .userInitiated).async {
            NotificationCenter.default.post(name: .workflowLibraryEnablementDidChange, object: nil)
            posted.fulfill()
        }

        await fulfillment(of: [posted], timeout: 2)
        for _ in 0..<50 where state.workflowAvailabilityRevision == initialRevision {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertGreaterThan(state.workflowAvailabilityRevision, initialRevision)
    }

    func testWorkflowEnablementObserverMarshalsNotificationsToMainQueue() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift"),
            encoding: .utf8
        )
        let observerBlock = try sourceBlock(
            startingAt: "        self.enablementObserver = WorkflowOperationNotificationObserver(",
            endingBefore: "        if projectDiscoveryMode == .asynchronous {",
            in: source
        )

        XCTAssertTrue(observerBlock.contains("queue: .main"))
        XCTAssertFalse(observerBlock.contains("queue: nil"))
    }

    func testFullLengthONTMHCGenotypingLaunchRequestUsesSavontAndAdvancedInputsWithoutGuide() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let fullLengthItem = try XCTUnwrap(
            WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        )
        enablementStore.setWorkflow(fullLengthItem, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("Reference Sequences/Mamu-class-I.lungfishmhcref", isDirectory: true)
        let referenceFASTAURL = referenceURL.appendingPathComponent("reference.fa")
        let readsURL = temp.appendingPathComponent("Reads/NB13.lungfishfastq", isDirectory: true)
        let orientReferenceURL = temp.appendingPathComponent("Reference Sequences/MHC_class_I_orient.fasta")
        let forwardPrimerURL = temp.appendingPathComponent("Reference Sequences/MHC_class_I_F.fasta")
        let reversePrimerURL = temp.appendingPathComponent("Reference Sequences/MHC_class_I_R.fasta")
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try ">Mamu-A1*001\nACGT\n".write(to: referenceFASTAURL, atomically: true, encoding: .utf8)
        try ">orient\nACGT\n".write(to: orientReferenceURL, atomically: true, encoding: .utf8)
        try ">F\nACGT\n".write(to: forwardPrimerURL, atomically: true, encoding: .utf8)
        try ">R\nTGCA\n".write(to: reversePrimerURL, atomically: true, encoding: .utf8)
        try MHCAmpliconReferenceBundle.writeManifest(
            MHCAmpliconReferenceBundleManifest(
                name: "Mamu class I",
                referenceFastaPath: "reference.fa",
                haplotypeDefinitionPaths: [],
                defaultHaplotypeDefinitionID: nil,
                metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
                createdAt: "2026-06-06T00:00:00Z"
            ),
            to: referenceURL
        )
        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [readsURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.selectTool(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        state.setReference(referenceURL)
        state.setOutputDirectory(outputURL)
        state.outputName = "nb13-full-length"
        state.fullLengthOrientReferenceURL = orientReferenceURL
        state.fullLengthForwardPrimerURL = forwardPrimerURL
        state.fullLengthReversePrimerURL = reversePrimerURL
        state.fullLengthMinimumLength = 2000
        state.fullLengthMaximumLength = 4000
        state.threads = 8

        XCTAssertEqual(state.readinessText, "Ready to run.")
        let launchRequest = try state.makeLaunchRequest()
        guard case .fullLengthONTMHCGenotyping(let request) = launchRequest else {
            return XCTFail("Expected full-length ONT MHC genotyping request")
        }

        XCTAssertEqual(request.inputFASTQURLs, [readsURL.standardizedFileURL])
        XCTAssertEqual(request.referenceSourceURL, referenceURL.standardizedFileURL)
        XCTAssertEqual(request.orientReferenceURL, orientReferenceURL.standardizedFileURL)
        XCTAssertEqual(request.forwardPrimerURL, forwardPrimerURL.standardizedFileURL)
        XCTAssertEqual(request.reversePrimerURL, reversePrimerURL.standardizedFileURL)
        XCTAssertEqual(request.minimumLength, 2000)
        XCTAssertEqual(request.maximumLength, 4000)
        XCTAssertEqual(request.savontQualityValueCutoff, 90)
        XCTAssertEqual(request.savontMinimumClusterSize, 3)
        XCTAssertEqual(request.threads, 8)
        XCTAssertEqual(
            request.outputDirectory,
            outputURL.appendingPathComponent("nb13-full-length.lungfishgenotype", isDirectory: true).standardizedFileURL
        )
    }

    func testFullLengthONTMHCDoesNotRequireProjectGuideBundle() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let fullLengthItem = try XCTUnwrap(
            WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        )
        enablementStore.setWorkflow(fullLengthItem, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let alleleReferenceURL = temp.appendingPathComponent("Reference Sequences/Mamu_classI_all.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: alleleReferenceURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.selectTool(WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)

        XCTAssertEqual(state.readinessText, "Select one or more FASTQ bundles.")
    }

    func testWorkflowOperationsDialogDoesNotExposePBAAControlsForFullLengthONTMHC() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("guidePicker"))
        XCTAssertFalse(source.contains("pbaaClusterSourcePicker"))
        XCTAssertFalse(source.contains("pbAA Guides"))
        XCTAssertFalse(source.contains("pbAA Clusters"))
    }

    func testWorkflowOperationsDialogUsesCommonMacOSFormTypography() throws {
        let root = repositoryRoot()
        let workflowDialogSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )
        let datasetDialogSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(workflowDialogSource.contains("private func workflowFormGroup"))
        XCTAssertTrue(workflowDialogSource.contains("workflowFormGroup(\"Length Filter\")"))
        XCTAssertFalse(workflowDialogSource.contains(".caption2"))
        XCTAssertTrue(datasetDialogSource.contains("RoundedRectangle(cornerRadius: 8"))
        XCTAssertFalse(datasetDialogSource.contains("RoundedRectangle(cornerRadius: 10"))
    }

    func testEnabledWorkflowPackageBuildsLocalWorkflowRunWithExpectedOutputs() async throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let packageURL = helloWorldNextflowPackageURL()
        let package = try WorkflowPackageValidator.validatePackage(at: packageURL)
        packageStore.addValidatedPackage(package)
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

    func testWorkflowOperationDialogLoadsColdImportedPackagesAsynchronously() async throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        packageStore.addPackage(at: helloWorldNextflowPackageURL())

        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        XCTAssertFalse(state.tools.contains { $0.id == "package.org.lungfish.templates.hello-world-nextflow" })

        try await waitForWorkflowPackageTool(state, id: "package.org.lungfish.templates.hello-world-nextflow")

        XCTAssertTrue(state.tools.contains { $0.id == "package.org.lungfish.templates.hello-world-nextflow" })
    }

    func testWorkflowOperationDialogSelectsColdEnabledPackageWhenCurrentSelectionIsDisabled() async throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: false)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let package = try WorkflowPackageValidator.validatePackage(at: helloWorldNextflowPackageURL())
        packageStore.addPackage(at: package.packageURL)
        enablementStore.setUserWorkflow(package, enabled: true)

        let state = WorkflowOperationDialogState(
            projectURL: nil,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        XCTAssertNotEqual(state.selectedToolID, "package.org.lungfish.templates.hello-world-nextflow")

        try await waitForWorkflowPackageTool(state, id: "package.org.lungfish.templates.hello-world-nextflow")

        XCTAssertEqual(state.selectedToolID, "package.org.lungfish.templates.hello-world-nextflow")
        XCTAssertEqual(state.outputName, "hello-world-nextflow")
    }

    func testWorkflowPackageIsNotRunnableWithFolderBatchMultiReadSelection() {
        let state = WorkflowOperationDialogState(
            projectURL: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            selectedReadURLs: [
                URL(fileURLWithPath: "/tmp/project/A.lungfishfastq", isDirectory: true),
                URL(fileURLWithPath: "/tmp/project/B.lungfishfastq", isDirectory: true),
            ]
        )
        state.setReference(URL(fileURLWithPath: "/tmp/project/ref.lungfishref", isDirectory: true))
        state.outputDirectoryURL = URL(fileURLWithPath: "/tmp/project/Analyses", isDirectory: true)
        state.testingReplaceTools([
            WorkflowOperationTool(
                id: "package-test",
                title: "Package Test",
                subtitle: "Fixture package",
                kind: .workflowPackage(makeRunnableWorkflowPackage()),
                availability: .available
            ),
        ])
        state.selectTool("package-test")

        XCTAssertFalse(state.isRunEnabled)
        XCTAssertEqual(
            state.readinessText,
            "Imported workflow packages currently accept one FASTQ bundle. Select one bundle, or choose a built-in workflow for folder batches."
        )
    }

    func testONTGenotypingLaunchRequestUsesConfiguredSimpleOptions() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setReference(referenceURL)
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
        XCTAssertNil(request.presetID)
        XCTAssertNil(request.barcodeDefinitionsURL)
        XCTAssertEqual(request.mode, .ontSampleBundles)
        XCTAssertEqual(request.readType, .ont)
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

    func testFolderResolvedBuiltInWorkflowLaunchRequestUsesConcreteBundleURLs() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        try enableTwelveSAmpliconMatching(in: enablementStore)

        let projectURL = try temporaryDirectory()
        let folderURL = projectURL.appendingPathComponent("Runs", isDirectory: true)
        let direct = folderURL.appendingPathComponent("A.lungfishfastq", isDirectory: true)
        let nested = folderURL.appendingPathComponent("Nested/B.lungfishfastq", isDirectory: true)
        let referenceURL = projectURL.appendingPathComponent("ref.fasta")
        let outputURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        try Data(">target\nACGT\n".utf8).write(to: referenceURL)
        for url in [direct, nested, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let selection = WorkflowSidebarInputSelection(
            directReadURLs: [direct.standardizedFileURL],
            recursiveReadURLs: [direct.standardizedFileURL, nested.standardizedFileURL],
            detailRows: [
                .init(url: direct.standardizedFileURL, displayPath: "Runs/A.lungfishfastq"),
            ],
            recursiveDetailRows: [
                .init(url: direct.standardizedFileURL, displayPath: "Runs/A.lungfishfastq"),
                .init(url: nested.standardizedFileURL, displayPath: "Runs/Nested/B.lungfishfastq"),
            ],
            folderSelectionCount: 1,
            explicitBundleCount: 0,
            duplicateBundleCount: 0,
            recursiveDuplicateBundleCount: 0,
            skippedItemCount: 0,
            selectedFolderNames: ["Runs"],
            emptyFolderNames: [],
            additionalDescendantBundleCount: 1
        )
        let state = WorkflowOperationDialogState(
            projectURL: projectURL,
            selectedReadURLs: [],
            sidebarInputSelection: selection,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        let twelveSTool = try XCTUnwrap(state.tools.first { $0.title == "12S Amplicon Matching" })
        state.selectTool(twelveSTool.id)
        state.setReference(referenceURL)
        state.outputDirectoryURL = outputURL
        state.outputName = "folder-batch"
        state.setIncludeSubfolderBundles(true)

        let request = try state.makeLaunchRequest()

        guard case .twelveSAmpliconMatching(let config) = request else {
            return XCTFail("Expected 12S amplicon matching launch request")
        }
        XCTAssertEqual(config.inputFASTQs, [direct.standardizedFileURL, nested.standardizedFileURL])
        XCTAssertFalse(config.inputFASTQs.contains(folderURL.standardizedFileURL))
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

    func testONTGenotypingAISpecialistPresetUsesPromptPresetWithoutDeterministicDefinition() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let readsURL = temp.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: readsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            aiSpecialistPresetsAvailable: true,
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.setAmpliconAnalysisMode(.aiSpecialistPreset)
        state.setReads([readsURL])
        state.setOutputDirectory(outputURL)

        state.selectedHaplotypeAssayID = "MHC-exon2-miSeq"
        state.selectedHaplotypeDefinitionSetID = "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"

        let launchRequest = try state.makeLaunchRequest()
        guard case .ontGenotyping(let request) = launchRequest else {
            return XCTFail("Expected ONT genotyping request")
        }

        XCTAssertEqual(request.referenceSourceURL, try MCMHaplotypingPreset.mcmMHCmiseq.bundledReferenceBundleURL())
        XCTAssertEqual(request.presetID, MCMHaplotypingPreset.mcmMHCmiseq.id)
        XCTAssertEqual(request.aiSpecialistPresetID, MCMHaplotypingPreset.mcmMHCmiseq.id)
        XCTAssertEqual(request.resultWorkflowKind, .miSeqAmpliconMHCGenotype)
        XCTAssertNil(request.haplotypeAssayID)
        XCTAssertNil(request.haplotypeDefinitionSetID)
    }

    func testONTGenotypingLaunchRequestPassesDeterministicHaplotypeDropoutThresholds() throws {
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
        state.setAmpliconAnalysisMode(.deterministicHaplotyping)
        state.setReference(referenceURL)
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

        XCTAssertEqual(request.haplotypeDropoutSampleFraction, 0.001)
        XCTAssertEqual(request.haplotypeDropoutLocusFraction, 0.01)
        XCTAssertEqual(request.haplotypeDropoutLocusFractionOverrides, [
            "MHC-DQ": 0.10,
            "MHC-DP": 0.10,
        ])
        XCTAssertEqual(request.resultWorkflowKind, .miSeqAmpliconMHCGenotype)
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

    func testExternalBarcodeDefinitionIsIgnoredByPerSampleBundleONTLaunch() throws {
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
        XCTAssertNil(request.barcodeDefinitionsURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedURL.path))
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

    func testAmpliconGenotypingONTSampleBundleModeAllowsSelectedFolderWithoutBarcodes() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enablementStore.setWorkflow(.ontGenotyping, enabled: true)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let referenceURL = temp.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let demultiplexedFolderURL = temp.appendingPathComponent("Reads/Demultiplexed ONT", isDirectory: true)
        let outputURL = temp.appendingPathComponent("Analyses", isDirectory: true)
        for url in [referenceURL, demultiplexedFolderURL, outputURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
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

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [demultiplexedFolderURL],
            enablementStore: enablementStore,
            packageStore: packageStore
        )
        state.selectedGenotypingMode = .ontSampleBundles
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
        XCTAssertEqual(request.inputFASTQURLs, [demultiplexedFolderURL.standardizedFileURL])
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

    func testWorkflowOperationDialogStateUsesDirectFolderSelectionByDefaultAndCanIncludeSubfolders() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let directReadsURL = temp.appendingPathComponent("Reads/direct.lungfishfastq", isDirectory: true)
        let nestedReadsURL = temp.appendingPathComponent("Reads/Nested/nested.lungfishfastq", isDirectory: true)
        let selection = WorkflowSidebarInputSelection(
            directReadURLs: [directReadsURL.standardizedFileURL],
            recursiveReadURLs: [directReadsURL.standardizedFileURL, nestedReadsURL.standardizedFileURL],
            detailRows: [
                .init(url: directReadsURL.standardizedFileURL, displayPath: "Reads/direct.lungfishfastq")
            ],
            recursiveDetailRows: [
                .init(url: directReadsURL.standardizedFileURL, displayPath: "Reads/direct.lungfishfastq"),
                .init(url: nestedReadsURL.standardizedFileURL, displayPath: "Reads/Nested/nested.lungfishfastq")
            ],
            folderSelectionCount: 1,
            explicitBundleCount: 0,
            duplicateBundleCount: 0,
            recursiveDuplicateBundleCount: 0,
            skippedItemCount: 0,
            selectedFolderNames: ["Reads"],
            emptyFolderNames: [],
            additionalDescendantBundleCount: 1
        )

        let state = WorkflowOperationDialogState(
            projectURL: temp,
            selectedReadURLs: [],
            sidebarInputSelection: selection,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        XCTAssertEqual(state.selectedReadURLs, [directReadsURL.standardizedFileURL])
        XCTAssertFalse(state.includeSubfolderBundles)
        XCTAssertEqual(state.selectedReadsDisplay, "Folder \"Reads\" expands to 1 eligible FASTQ bundle.")
        XCTAssertEqual(state.folderSubfolderNoticeText, "Subfolders contain 1 additional eligible FASTQ bundle.")

        state.setIncludeSubfolderBundles(true)

        XCTAssertEqual(state.selectedReadURLs, [
            directReadsURL.standardizedFileURL,
            nestedReadsURL.standardizedFileURL,
        ])
        XCTAssertTrue(state.includeSubfolderBundles)
        XCTAssertEqual(state.selectedReadsDisplay, "Folder \"Reads\" expands to 2 eligible FASTQ bundles.")
    }

    func testWorkflowOperationDialogConfigureProjectReplacesSidebarInputSelection() throws {
        let defaults = try makeDefaults()
        let enablementStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let firstProjectURL = temp.appendingPathComponent("first.lungfish", isDirectory: true)
        let secondProjectURL = temp.appendingPathComponent("second.lungfish", isDirectory: true)
        let firstReadsURL = firstProjectURL.appendingPathComponent("Reads/first.lungfishfastq", isDirectory: true)
        let secondReadsURL = secondProjectURL.appendingPathComponent("Reads/second.lungfishfastq", isDirectory: true)
        let firstSelection = WorkflowSidebarInputSelection(
            directReadURLs: [firstReadsURL.standardizedFileURL],
            recursiveReadURLs: [firstReadsURL.standardizedFileURL],
            detailRows: [
                .init(url: firstReadsURL.standardizedFileURL, displayPath: "Reads/first.lungfishfastq")
            ],
            folderSelectionCount: 1,
            explicitBundleCount: 0,
            duplicateBundleCount: 0,
            skippedItemCount: 0,
            selectedFolderNames: ["First Reads"],
            emptyFolderNames: [],
            additionalDescendantBundleCount: 0
        )
        let secondSelection = WorkflowSidebarInputSelection(
            directReadURLs: [secondReadsURL.standardizedFileURL],
            recursiveReadURLs: [secondReadsURL.standardizedFileURL],
            detailRows: [
                .init(url: secondReadsURL.standardizedFileURL, displayPath: "Reads/second.lungfishfastq")
            ],
            folderSelectionCount: 1,
            explicitBundleCount: 0,
            duplicateBundleCount: 0,
            skippedItemCount: 0,
            selectedFolderNames: ["Second Reads"],
            emptyFolderNames: [],
            additionalDescendantBundleCount: 0
        )

        let state = WorkflowOperationDialogState(
            projectURL: firstProjectURL,
            selectedReadURLs: [],
            sidebarInputSelection: firstSelection,
            enablementStore: enablementStore,
            packageStore: packageStore
        )

        state.configureProject(
            projectURL: secondProjectURL,
            selectedReadURLs: [],
            sidebarInputSelection: secondSelection
        )

        XCTAssertEqual(state.selectedReadURLs, [secondReadsURL.standardizedFileURL])
        XCTAssertEqual(state.selectedReadsDisplay, "Folder \"Second Reads\" expands to 1 eligible FASTQ bundle.")
    }

    func testWorkflowOperationsPreserveEnclosingFASTQFallbackForNonFolderSidebarSelection() throws {
        let temp = try temporaryDirectory()
        let projectURL = temp.appendingPathComponent("project.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        let readFileURL = bundleURL.appendingPathComponent("reads.fastq")
        let selectedItem = SidebarItem(
            title: "reads.fastq",
            type: .sequence,
            url: readFileURL
        )

        let result = AppDelegate.resolveWorkflowSidebarInputSelectionForOperations(
            items: [selectedItem],
            projectURL: projectURL
        )

        XCTAssertEqual(result.selectedReadURLs, [bundleURL.standardizedFileURL])
        XCTAssertNil(result.sidebarInputSelection)
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
            endingBefore: "    private var twelveSSampleMetadataPicker: some View",
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

    func testWorkflowOperationsDialogShowsFolderBatchSummaryAndSubfolderToggleText() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Include subfolders"))
        XCTAssertTrue(source.contains("When enabled, all eligible bundles in descendant folders are added to this batch."))
        XCTAssertTrue(source.contains("folderSubfolderNoticeText"))
        XCTAssertTrue(source.contains("folderDuplicateNoticeText"))
        XCTAssertTrue(source.contains("folderEmptyNoticeText"))
        XCTAssertTrue(source.contains("resolvedReadDetailRows"))
        XCTAssertTrue(source.contains("workflow-operations-include-subfolders"))
        XCTAssertTrue(source.contains("workflow-operations-empty-folder-notice"))
        XCTAssertTrue(source.contains("workflow-operations-subfolder-notice"))
        XCTAssertTrue(source.contains("workflow-operations-duplicate-folder-inputs"))
    }

    func testWorkflowOperationsDialogRemovesBarcodeDefinitionPickerAndShowsMutuallyExclusiveAnalysisModes() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )
        let analysisModePicker = try sourceBlock(
            startingAt: "    private var ampliconAnalysisModePicker: some View",
            endingBefore: "    private var haplotypeDefinitionPicker: some View",
            in: source
        )

        XCTAssertFalse(source.contains("barcodePicker"))
        XCTAssertFalse(source.contains("barcodeDefinitionProjectFileBinding"))
        XCTAssertFalse(source.contains("browseForBarcodeDefinition"))
        XCTAssertTrue(analysisModePicker.contains("WorkflowOperationAmpliconAnalysisMode.allCases"))
        XCTAssertTrue(analysisModePicker.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(analysisModePicker.contains("state.setAmpliconAnalysisMode(mode)"))
        XCTAssertTrue(analysisModePicker.contains(".disabled(mode == .aiSpecialistPreset && !state.aiSpecialistPresetsAvailable)"))
        XCTAssertTrue(analysisModePicker.contains("AI specialist presets require configured API access."))
    }

    func testWorkflowOperationsDialogShowsTwelveSMatchingModeAsPrimaryGUIControl() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift"),
            encoding: .utf8
        )
        let primarySettings = try sourceBlock(
            startingAt: "    @ViewBuilder\n    private var primarySettings",
            endingBefore: "    private var ampliconAnalysisModePicker",
            in: source
        )
        let matchingModePicker = try sourceBlock(
            startingAt: "    private var twelveSMatchingModePicker: some View",
            endingBefore: "    private var ampliconAnalysisModePicker",
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
        XCTAssertTrue(source.contains("packageStore.cachedValidatedPackages()"))
        XCTAssertTrue(source.contains("packageStore.validatedPackagesInBackground()"))
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

    private func makeRunnableWorkflowPackage(id: String = "package-test") -> WorkflowPackageValidationResult {
        let temp = URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true)
        let manifest = WorkflowPackageManifest(
            id: id,
            name: "Package Test",
            version: "1.0.0",
            category: "Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [
                WorkflowPackageInput(id: "reference", name: "Reference", bundleTypes: [.lungfishref], required: true),
                WorkflowPackageInput(id: "reads", name: "Reads", bundleTypes: [.lungfishfastq], required: true),
            ],
            outputs: [
                WorkflowPackageOutput(id: "out", name: "Output", bundleType: .lungfishref, pathTemplate: "out.lungfishref"),
            ]
        )
        return WorkflowPackageValidationResult(
            packageURL: temp,
            manifestURL: temp.appendingPathComponent("manifest.json"),
            manifest: manifest,
            warnings: []
        )
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

    private func waitForProjectDiscovery(_ state: WorkflowOperationDialogState) async throws {
        let deadline = Date().addingTimeInterval(2)
        while state.isDiscoveringProjectResources && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForWorkflowPackageTool(_ state: WorkflowOperationDialogState, id: String) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !state.tools.contains(where: { $0.id == id }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
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
