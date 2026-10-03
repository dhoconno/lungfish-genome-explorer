// AppDelegateImportCenterOperationTests.swift - begin() sites in AppDelegate+ImportCenter
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Import Center and the sequence exports register nine rows through static
// begin helpers (R4). The VCF and BAM imports lock the bundle they attach to,
// so a held bundle lock must refuse their rows and launch nothing. The other
// seven declare no lock, and a reporter that refuses every begin proves they
// launch nothing either. Every recorded command that a lungfish-cli command
// reproduces must parse with the values the run uses. The batch sequence
// export and the single exports that cannot be a command record no command
// that parses, and their tests pin that, so a command added later fails here
// and prompts a deliberate test change.

import XCTest
import os
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class AppDelegateImportCenterOperationTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish", isDirectory: true)
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Reference Sequences/Sample.lungfishref", isDirectory: true)

    private func makeRouteContext() -> OperationRouteContext {
        OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
    }

    /// A fresh center whose bundle lock is already held, as when another
    /// operation is running on the same bundle.
    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Delete Annotation Track",
            detail: "Running",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli sequence delete-annotation-track"
        ).startedID)
        return center
    }

    // MARK: - Reference import

    func testReferenceImportRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/Mito Reference.fasta")
        var launchedID: UUID?

        AppDelegate.beginReferenceImportOperation(
            sourceURL: sourceURL,
            projectURL: projectURL,
            preferredBundleName: "Mito reference",
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Reference Import")
        XCTAssertEqual(item.initialDetail, "Importing Mito Reference.fasta...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // The command writes under the project it names, because `import fasta`
        // adds the Reference Sequences folder itself, where the run writes.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FASTASubcommand.self)
        XCTAssertEqual(command.inputFile, sourceURL.path)
        XCTAssertEqual(command.outputDir, projectURL.path)
        XCTAssertEqual(command.name, "Mito reference")
    }

    func testReferenceImportRecordsNoNameWhenTheRunHasNone() throws {
        for preferredBundleName in [nil, "", "  \n "] as [String?] {
            let reporter = RecordingOperationReporter()

            AppDelegate.beginReferenceImportOperation(
                sourceURL: URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/ref.fa"),
                projectURL: projectURL,
                preferredBundleName: preferredBundleName,
                routeContext: nil,
                reporter: reporter
            ) { _ in }

            let item = try XCTUnwrap(reporter.items.first)
            let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.FASTASubcommand.self)
            XCTAssertNil(command.name, "a run without a preferred name records no --name (\(preferredBundleName ?? "nil"))")
            XCTAssertFalse(try XCTUnwrap(item.cliCommand).contains("--name"))
        }
    }

    // MARK: - Application export and native bundle imports

    func testGeneiousImportRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/MHC haplotypes.geneious")
        let arguments = CLIApplicationExportImportRunner.buildGeneiousArguments(
            sourceURL: sourceURL,
            projectURL: projectURL
        )
        var launchedID: UUID?

        AppDelegate.beginGeneiousImportOperation(
            sourceURL: sourceURL,
            arguments: arguments,
            routeContext: routeContext,
            reporter: reporter,
            onCancel: {}
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Geneious Import")
        XCTAssertEqual(item.initialDetail, "Importing MHC haplotypes.geneious...")
        XCTAssertEqual(item.operationType, .applicationExportImport)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertTrue(item.hasCancelCallback, "the row must be cancellable from the moment it starts")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.GeneiousSubcommand.self)
        XCTAssertEqual(command.sourcePath, sourceURL.path)
        XCTAssertEqual(command.projectPath, projectURL.path)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testApplicationExportImportRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/CLC Export.zip")
        let arguments = CLIApplicationExportImportRunner.buildApplicationExportArguments(
            sourceURL: sourceURL,
            projectURL: projectURL,
            kind: .clcWorkbench
        )
        var launchedID: UUID?

        AppDelegate.beginApplicationExportImportOperation(
            kind: .clcWorkbench,
            sourceURL: sourceURL,
            arguments: arguments,
            routeContext: routeContext,
            reporter: reporter,
            onCancel: {}
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "CLC Workbench Import")
        XCTAssertEqual(item.initialDetail, "Importing CLC Export.zip...")
        XCTAssertEqual(item.operationType, .applicationExportImport)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertTrue(item.hasCancelCallback, "the row must be cancellable from the moment it starts")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.ApplicationExportSubcommand.self)
        XCTAssertEqual(command.kind, "clc-workbench")
        XCTAssertEqual(command.sourcePath, sourceURL.path)
        XCTAssertEqual(command.projectPath, projectURL.path)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testMultipleSequenceAlignmentImportRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/MHC alignment.aln")
        let arguments = CLINativeBundleImportRunner.buildArguments(
            sourceURL: sourceURL,
            projectURL: projectURL,
            kind: .msa
        )
        var launchedID: UUID?

        AppDelegate.beginNativeBundleImportOperation(
            kind: .msa,
            sourceURL: sourceURL,
            arguments: arguments,
            routeContext: routeContext,
            reporter: reporter,
            onCancel: {}
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "MSA Import")
        XCTAssertEqual(item.initialDetail, "Importing MHC alignment.aln...")
        XCTAssertEqual(item.operationType, .multipleSequenceAlignmentImport)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertTrue(item.hasCancelCallback, "the row must be cancellable from the moment it starts")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.MSASubcommand.self)
        XCTAssertEqual(command.inputFile, sourceURL.path)
        XCTAssertEqual(command.projectPath, projectURL.path)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testPhylogeneticTreeImportRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/MHC tree.nwk")
        let arguments = CLINativeBundleImportRunner.buildArguments(
            sourceURL: sourceURL,
            projectURL: projectURL,
            kind: .tree
        )
        var launchedID: UUID?

        AppDelegate.beginNativeBundleImportOperation(
            kind: .tree,
            sourceURL: sourceURL,
            arguments: arguments,
            routeContext: routeContext,
            reporter: reporter,
            onCancel: {}
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Tree Import")
        XCTAssertEqual(item.initialDetail, "Importing MHC tree.nwk...")
        XCTAssertEqual(item.operationType, .phylogeneticTreeImport)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertTrue(item.hasCancelCallback, "the row must be cancellable from the moment it starts")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.TreeSubcommand.self)
        XCTAssertEqual(command.inputFile, sourceURL.path)
        XCTAssertEqual(command.projectPath, projectURL.path)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testRunnerImportsRegisterTheCancelCallbackTheRowRuns() throws {
        let reporter = RecordingOperationReporter()
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/MHC tree.nwk")
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        AppDelegate.beginNativeBundleImportOperation(
            kind: .tree,
            sourceURL: sourceURL,
            arguments: CLINativeBundleImportRunner.buildArguments(sourceURL: sourceURL, projectURL: projectURL, kind: .tree),
            routeContext: nil,
            reporter: reporter,
            onCancel: { cancelled.withLock { $0 = true } }
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        reporter.cancel(id: item.id)

        XCTAssertTrue(cancelled.withLock { $0 }, "cancelling the row must reach the runner's cancel")
        XCTAssertEqual(reporter.item(item.id)?.state, .cancelling)
    }

    // MARK: - Classifier result imports

    func testClassifierResultImportsRecordTheClassificationTypeAndARunnableCommand() throws {
        let importsURL = projectURL.appendingPathComponent("Imports", isDirectory: true)
        let routeContext = makeRouteContext()

        // Kraken2.
        do {
            let reporter = RecordingOperationReporter()
            let inputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/sample one.kreport")
            var launchedID: UUID?
            AppDelegate.beginClassifierResultImportOperation(
                kind: .kraken2,
                operationTitle: "Kraken2 Import",
                inputURL: inputURL,
                outputDirectory: importsURL,
                preferredName: nil,
                naoMgsOptions: nil,
                routeContext: routeContext,
                reporter: reporter
            ) { launchedID = $0 }

            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertEqual(launchedID, item.id)
            XCTAssertEqual(item.title, "Kraken2 Import")
            XCTAssertEqual(item.initialDetail, "Importing sample one.kreport...")
            XCTAssertEqual(item.operationType, .classification)
            XCTAssertNil(item.targetBundleURL)
            XCTAssertEqual(item.additionalLockedBundleURLs, [])
            XCTAssertEqual(item.routeContext, routeContext)
            let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.Kraken2Subcommand.self)
            XCTAssertEqual(command.kreportFile, inputURL.path)
            XCTAssertEqual(command.outputDir, importsURL.path)
            XCTAssertNil(command.name)
        }
        // EsViritu.
        do {
            let reporter = RecordingOperationReporter()
            let inputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/esviritu results", isDirectory: true)
            AppDelegate.beginClassifierResultImportOperation(
                kind: .esviritu,
                operationTitle: "EsViritu Import",
                inputURL: inputURL,
                outputDirectory: importsURL,
                preferredName: nil,
                naoMgsOptions: nil,
                routeContext: routeContext,
                reporter: reporter
            ) { _ in }

            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertEqual(item.title, "EsViritu Import")
            XCTAssertEqual(item.operationType, .classification)
            let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.EsVirituSubcommand.self)
            XCTAssertEqual(command.inputPath, inputURL.path)
            XCTAssertEqual(command.outputDir, importsURL.path)
        }
        // TaxTriage.
        do {
            let reporter = RecordingOperationReporter()
            let inputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/taxtriage results", isDirectory: true)
            AppDelegate.beginClassifierResultImportOperation(
                kind: .taxtriage,
                operationTitle: "TaxTriage Import",
                inputURL: inputURL,
                outputDirectory: importsURL,
                preferredName: nil,
                naoMgsOptions: nil,
                routeContext: routeContext,
                reporter: reporter
            ) { _ in }

            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertEqual(item.title, "TaxTriage Import")
            XCTAssertEqual(item.operationType, .classification)
            let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.TaxTriageSubcommand.self)
            XCTAssertEqual(command.inputPath, inputURL.path)
            XCTAssertEqual(command.outputDir, importsURL.path)
        }
    }

    func testKraken2ImportKeepsItsRecordedCommandByteForByte() throws {
        // The Kraken2, EsViritu and TaxTriage rows recorded this exact string
        // before the migration, so the shared builder must not change it.
        let reporter = RecordingOperationReporter()

        AppDelegate.beginClassifierResultImportOperation(
            kind: .kraken2,
            operationTitle: "Kraken2 Import",
            inputURL: URL(fileURLWithPath: "/tmp/in/sample.kreport"),
            outputDirectory: URL(fileURLWithPath: "/tmp/project.lungfish/Imports", isDirectory: true),
            preferredName: nil,
            naoMgsOptions: nil,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        XCTAssertEqual(
            reporter.items.first?.cliCommand,
            "lungfish-cli import kraken2 /tmp/in/sample.kreport --output-dir /tmp/project.lungfish/Imports"
        )
    }

    func testNaoMgsImportRecordsACommandTheCLIParses() throws {
        let analysesURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let inputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/nao results", isDirectory: true)

        // Fetching references is the default, so the command needs no flag.
        // The row used to record `--fetch-references true`, which the CLI
        // rejects because `--fetch-references` is a flag, not an option.
        let fetching = RecordingOperationReporter()
        AppDelegate.beginClassifierResultImportOperation(
            kind: .naomgs,
            operationTitle: "NAO-MGS Import",
            inputURL: inputURL,
            outputDirectory: analysesURL,
            preferredName: nil,
            naoMgsOptions: .init(fetchReferences: true),
            routeContext: nil,
            reporter: fetching
        ) { _ in }
        let fetchingItem = try XCTUnwrap(fetching.items.first)
        XCTAssertEqual(fetchingItem.title, "NAO-MGS Import")
        XCTAssertEqual(fetchingItem.operationType, .classification)
        let fetchingCommand = try RecordedCLICommand.parse(fetchingItem.cliCommand, as: ImportCommand.NaoMgsSubcommand.self)
        XCTAssertEqual(fetchingCommand.inputPath, inputURL.path)
        XCTAssertEqual(fetchingCommand.outputDir, analysesURL.path)
        XCTAssertTrue(fetchingCommand.fetchReferences)
        XCTAssertFalse(try XCTUnwrap(fetchingItem.cliCommand).contains("--fetch-references"))

        let skipping = RecordingOperationReporter()
        AppDelegate.beginClassifierResultImportOperation(
            kind: .naomgs,
            operationTitle: "NAO-MGS Import",
            inputURL: inputURL,
            outputDirectory: analysesURL,
            preferredName: nil,
            naoMgsOptions: .init(fetchReferences: false),
            routeContext: nil,
            reporter: skipping
        ) { _ in }
        let skippingCommand = try RecordedCLICommand.parse(
            skipping.items.first?.cliCommand,
            as: ImportCommand.NaoMgsSubcommand.self
        )
        XCTAssertFalse(skippingCommand.fetchReferences)

        // A nil option set means the default, as in the helper the run launches.
        let defaulted = RecordingOperationReporter()
        AppDelegate.beginClassifierResultImportOperation(
            kind: .naomgs,
            operationTitle: "NAO-MGS Import",
            inputURL: inputURL,
            outputDirectory: analysesURL,
            preferredName: nil,
            naoMgsOptions: nil,
            routeContext: nil,
            reporter: defaulted
        ) { _ in }
        let defaultedCommand = try RecordedCLICommand.parse(
            defaulted.items.first?.cliCommand,
            as: ImportCommand.NaoMgsSubcommand.self
        )
        XCTAssertTrue(defaultedCommand.fetchReferences)
    }

    func testClassifierResultImportRecordsOnlyANameTheRunUses() throws {
        let importsURL = projectURL.appendingPathComponent("Imports", isDirectory: true)
        let inputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/esviritu results", isDirectory: true)

        let named = RecordingOperationReporter()
        AppDelegate.beginClassifierResultImportOperation(
            kind: .esviritu,
            operationTitle: "EsViritu Import",
            inputURL: inputURL,
            outputDirectory: importsURL,
            preferredName: "  Sample A  ",
            naoMgsOptions: nil,
            routeContext: nil,
            reporter: named
        ) { _ in }
        let namedCommand = try RecordedCLICommand.parse(
            named.items.first?.cliCommand,
            as: ImportCommand.EsVirituSubcommand.self
        )
        XCTAssertEqual(namedCommand.name, "Sample A")

        let blank = RecordingOperationReporter()
        AppDelegate.beginClassifierResultImportOperation(
            kind: .esviritu,
            operationTitle: "EsViritu Import",
            inputURL: inputURL,
            outputDirectory: importsURL,
            preferredName: "   ",
            naoMgsOptions: nil,
            routeContext: nil,
            reporter: blank
        ) { _ in }
        let blankCommand = try RecordedCLICommand.parse(
            blank.items.first?.cliCommand,
            as: ImportCommand.EsVirituSubcommand.self
        )
        XCTAssertNil(blankCommand.name)

        // NAO-MGS names the sample with --sample-name, not --name.
        let nao = RecordingOperationReporter()
        AppDelegate.beginClassifierResultImportOperation(
            kind: .naomgs,
            operationTitle: "NAO-MGS Import",
            inputURL: inputURL,
            outputDirectory: importsURL,
            preferredName: "Wastewater A",
            naoMgsOptions: nil,
            routeContext: nil,
            reporter: nao
        ) { _ in }
        let naoCommand = try RecordedCLICommand.parse(
            nao.items.first?.cliCommand,
            as: ImportCommand.NaoMgsSubcommand.self
        )
        XCTAssertEqual(naoCommand.sampleName, "Wastewater A")
    }

    // MARK: - VCF import, a bundle lock

    func testVCFImportRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        let result = AppDelegate.beginVCFImportOperation(
            vcfURL: URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/calls.vcf.gz"),
            bundleURL: bundleURL,
            importProfile: .auto,
            replaceTrackID: nil,
            routeContext: nil,
            reporter: center,
            onCancel: { cancelled.withLock { $0 = true } }
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the VCF import row")
        }
        XCTAssertFalse(launched, "a refused row must start no import")
        XCTAssertEqual(refusal.blockingOperationTitle, "Delete Annotation Track")
    }

    func testVCFImportRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let vcfURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/calls one.vcf.gz")
        var launchedID: UUID?

        AppDelegate.beginVCFImportOperation(
            vcfURL: vcfURL,
            bundleURL: bundleURL,
            importProfile: .lowMemory,
            replaceTrackID: "calls",
            routeContext: routeContext,
            reporter: reporter,
            onCancel: {}
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Importing calls one.vcf.gz")
        XCTAssertEqual(item.initialDetail, "Importing VCF variants (Low Memory)...")
        XCTAssertEqual(item.operationType, .vcfImport)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertTrue(item.hasCancelCallback, "the row must be cancellable from the moment it starts")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.VCFSubcommand.self)
        XCTAssertEqual(command.inputFile, vcfURL.path)
        XCTAssertEqual(command.outputDir, bundleURL.path)
        XCTAssertEqual(command.importProfile, .lowMemory)
        XCTAssertEqual(command.replace, "calls")
    }

    func testVCFImportDetailNamesEachImportProfile() throws {
        let labels: [(VCFImportProfile, String)] = [
            (.auto, "Auto"),
            (.lowMemory, "Low Memory"),
            (.fast, "Fast"),
            (.ultraLowMemory, "Ultra Low Memory"),
        ]
        for (profile, label) in labels {
            let reporter = RecordingOperationReporter()

            AppDelegate.beginVCFImportOperation(
                vcfURL: URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/calls.vcf"),
                bundleURL: bundleURL,
                importProfile: profile,
                replaceTrackID: nil,
                routeContext: nil,
                reporter: reporter,
                onCancel: {}
            ) { _ in }

            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertEqual(item.initialDetail, "Importing VCF variants (\(label))...")
            let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.VCFSubcommand.self)
            XCTAssertEqual(command.importProfile, profile)
            XCTAssertNil(command.replace)
        }
    }

    func testVCFImportRegistersTheCancelCallbackTheRowRuns() throws {
        let reporter = RecordingOperationReporter()
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        AppDelegate.beginVCFImportOperation(
            vcfURL: URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/calls.vcf"),
            bundleURL: bundleURL,
            importProfile: .auto,
            replaceTrackID: nil,
            routeContext: nil,
            reporter: reporter,
            onCancel: { cancelled.withLock { $0 = true } }
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        reporter.cancel(id: item.id)

        XCTAssertTrue(cancelled.withLock { $0 }, "cancelling the row must set the import's cancel flag")
    }

    // MARK: - BAM import, a bundle lock

    func testBAMImportRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        let result = AppDelegate.beginBAMImportOperation(
            bamURL: URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/sample.sorted.bam"),
            bundleURL: bundleURL,
            routeContext: nil,
            reporter: center,
            onCancel: { cancelled.withLock { $0 = true } }
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the BAM import row")
        }
        XCTAssertFalse(launched, "a refused row must start no import")
        XCTAssertEqual(refusal.blockingOperationTitle, "Delete Annotation Track")
    }

    func testBAMImportRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let bamURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/sample one.sorted.bam")
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        var launchedID: UUID?

        AppDelegate.beginBAMImportOperation(
            bamURL: bamURL,
            bundleURL: bundleURL,
            routeContext: routeContext,
            reporter: reporter,
            onCancel: { cancelled.withLock { $0 = true } }
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Importing sample one.sorted.bam")
        XCTAssertEqual(item.initialDetail, "Importing alignments...")
        XCTAssertEqual(item.operationType, .bamImport)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertTrue(item.hasCancelCallback, "the row must be cancellable from the moment it starts")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.BAMSubcommand.self)
        XCTAssertEqual(command.inputFile, bamURL.path)
        XCTAssertEqual(command.outputDir, bundleURL.path)
        XCTAssertEqual(command.name, bamURL.lastPathComponent)
        reporter.cancel(id: item.id)
        XCTAssertTrue(cancelled.withLock { $0 }, "cancelling the row must set the import's cancel flag")
    }

    // MARK: - Sequence exports

    func testSingleFileSequenceExportRecordsItsRowAndARunnableConvertCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let inputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish/Imports/sample one.fasta")
        let outputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Exports/sample one.gb")
        var launchedID: UUID?

        AppDelegate.beginSequenceExportOperation(
            outputURL: outputURL,
            inputURL: inputURL,
            format: .genbank,
            compression: .none,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Exporting sample one.gb")
        XCTAssertEqual(item.initialDetail, "Preparing sequence export...")
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ConvertCommand.self)
        XCTAssertEqual(command.input, inputURL.path)
        XCTAssertEqual(command.outputFile, outputURL.path)
        XCTAssertEqual(command.toFormat, "genbank")
        XCTAssertTrue(command.force)
        // The run writes the source file's annotations into a GenBank file,
        // and `convert` drops them without this flag. The row used to omit it.
        XCTAssertTrue(command.includeAnnotations)
    }

    func testSingleFileFastaExportRecordsNoAnnotationFlag() throws {
        let reporter = RecordingOperationReporter()
        let inputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish/Imports/sample one.gb")
        let outputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Exports/sample one.fa")

        AppDelegate.beginSequenceExportOperation(
            outputURL: outputURL,
            inputURL: inputURL,
            format: .fasta,
            compression: .none,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        // A FASTA file has no annotations, so the command is unchanged.
        let command = try RecordedCLICommand.parse(reporter.items.first?.cliCommand, as: ConvertCommand.self)
        XCTAssertEqual(command.input, inputURL.path)
        XCTAssertEqual(command.outputFile, outputURL.path)
        XCTAssertEqual(command.toFormat, "fasta")
        XCTAssertTrue(command.force)
        XCTAssertFalse(command.includeAnnotations)
    }

    func testReferenceBundleSequenceExportRecordsTheConvertCommandTheRunExecutes() throws {
        let reporter = RecordingOperationReporter()
        let outputURL = URL(fileURLWithPath: "/tmp/lane 1a2/Exports/Sample.fa")

        AppDelegate.beginSequenceExportOperation(
            outputURL: outputURL,
            inputURL: bundleURL,
            format: .fasta,
            compression: .none,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ConvertCommand.self)
        XCTAssertEqual(command.input, bundleURL.path)
        XCTAssertEqual(command.outputFile, outputURL.path)
        XCTAssertEqual(command.toFormat, "fasta")
        XCTAssertTrue(command.includeAnnotations)
        XCTAssertTrue(command.force)
        XCTAssertTrue(command.globalOptions.quiet)
        // The run executes these arguments for a single reference bundle.
        let runArguments = AppDelegate.referenceBundleSequenceExportCLIArguments(
            bundleURL: bundleURL,
            outputURL: outputURL,
            format: .fasta
        )
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), runArguments)
    }

    func testSequenceExportWithNoSingleFileInputRecordsNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()

        AppDelegate.beginSequenceExportOperation(
            outputURL: URL(fileURLWithPath: "/tmp/lane 1a2/Exports/exported_sequences.fa"),
            inputURL: nil,
            format: .fasta,
            compression: .none,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        // Several sources or a captured document snapshot have no single
        // input file for `convert`.
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "sequence-export-compressed-or-bundle")
    }

    func testCompressedSequenceExportRecordsNoCommandAsAParityGap() throws {
        for compression in [SequenceExportCompression.gzip, .zstd] {
            let reporter = RecordingOperationReporter()

            AppDelegate.beginSequenceExportOperation(
                outputURL: URL(fileURLWithPath: "/tmp/lane 1a2/Exports/sample.fa.gz"),
                inputURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish/Imports/sample.fasta"),
                format: .fasta,
                compression: compression,
                routeContext: nil,
                reporter: reporter
            ) { _ in }

            // `convert` writes no compressed output.
            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertNil(item.cliCommand, "\(compression) export has no convert equivalent")
            assertCLIParityGap(item.cliCommand, id: "sequence-export-compressed-or-bundle")
        }
    }

    func testBatchSequenceExportRecordsItsRowAndNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let outputFolder = URL(fileURLWithPath: "/tmp/lane 1a2/Exports", isDirectory: true)
        let bundles = [
            URL(fileURLWithPath: "/tmp/lane 1a2/Reference Sequences/Alpha.lungfishref", isDirectory: true),
            URL(fileURLWithPath: "/tmp/lane 1a2/Reference Sequences/Beta Name.lungfishref", isDirectory: true),
            URL(fileURLWithPath: "/tmp/lane 1a2/Reference Sequences/Gamma.lungfishref", isDirectory: true),
        ]
        var launchedID: UUID?

        AppDelegate.beginBatchSequenceExportOperation(
            bundleURLs: bundles,
            outputFolder: outputFolder,
            format: .genbank,
            compression: .none,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Exporting 3 sequence files")
        XCTAssertEqual(item.initialDetail, "Preparing batch export...")
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)

        // One `convert` command exports one bundle and no command covers the
        // batch, so the row records no command.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "sequence-export-batch")
    }

    func testCompressedBatchSequenceExportRecordsNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()

        AppDelegate.beginBatchSequenceExportOperation(
            bundleURLs: [
                URL(fileURLWithPath: "/tmp/lane 1a2/Reference Sequences/Alpha.lungfishref", isDirectory: true),
                URL(fileURLWithPath: "/tmp/lane 1a2/Reference Sequences/Beta.lungfishref", isDirectory: true),
            ],
            outputFolder: URL(fileURLWithPath: "/tmp/lane 1a2/Exports", isDirectory: true),
            format: .fasta,
            compression: .gzip,
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "Exporting 2 sequence files")
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "sequence-export-batch")
    }

    // MARK: - Sites with no lock launch nothing when the begin is refused

    func testSitesWithNoLockLaunchNothingWhenTheBeginIsRefused() throws {
        // No real center refuses these rows, because they request no lock. A
        // reporter that refuses every begin proves each launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/source.file")
        var launched: [String] = []

        func check(_ name: String, _ result: OperationStartResult) {
            guard case .refused = result else { return XCTFail("\(name) must report the refusal") }
        }

        check("reference import", AppDelegate.beginReferenceImportOperation(
            sourceURL: sourceURL, projectURL: projectURL, preferredBundleName: nil,
            routeContext: nil, reporter: reporter
        ) { _ in launched.append("reference import") })
        check("Geneious import", AppDelegate.beginGeneiousImportOperation(
            sourceURL: sourceURL, arguments: ["import", "geneious"],
            routeContext: nil, reporter: reporter, onCancel: {}
        ) { _ in launched.append("Geneious import") })
        check("application export import", AppDelegate.beginApplicationExportImportOperation(
            kind: .benchlingBulk, sourceURL: sourceURL, arguments: ["import", "application-export"],
            routeContext: nil, reporter: reporter, onCancel: {}
        ) { _ in launched.append("application export import") })
        check("native bundle import", AppDelegate.beginNativeBundleImportOperation(
            kind: .msa, sourceURL: sourceURL, arguments: ["import", "msa"],
            routeContext: nil, reporter: reporter, onCancel: {}
        ) { _ in launched.append("native bundle import") })
        check("classifier result import", AppDelegate.beginClassifierResultImportOperation(
            kind: .kraken2, operationTitle: "Kraken2 Import", inputURL: sourceURL,
            outputDirectory: projectURL, preferredName: nil, naoMgsOptions: nil,
            routeContext: nil, reporter: reporter
        ) { _ in launched.append("classifier result import") })
        check("sequence export", AppDelegate.beginSequenceExportOperation(
            outputURL: sourceURL, inputURL: nil, format: .fasta, compression: .none,
            routeContext: nil, reporter: reporter
        ) { _ in launched.append("sequence export") })
        check("batch sequence export", AppDelegate.beginBatchSequenceExportOperation(
            bundleURLs: [bundleURL], outputFolder: projectURL, format: .fasta, compression: .none,
            routeContext: nil, reporter: reporter
        ) { _ in launched.append("batch sequence export") })

        XCTAssertEqual(launched, [], "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 7)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
