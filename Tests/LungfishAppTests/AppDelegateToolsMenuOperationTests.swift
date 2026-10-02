// AppDelegateToolsMenuOperationTests.swift - begin() sites in AppDelegate+ToolsMenu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Tools menu launches register five rows through static begin helpers
// (R4). They are the NVD and CZ-ID result imports, the Viral Recon launch
// failure, the managed read mapping and the MAFFT alignment. None of them
// declares a lock, so a real center never refuses them, and a reporter that
// refuses every begin proves that each launch closure sits behind the
// `.started` case. Every recorded command that a lungfish-cli command
// reproduces must parse with the values the run uses. The Viral Recon failure
// row records no command, and its test pins that, so a command added later
// fails here and prompts a deliberate test change.

import XCTest
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class AppDelegateToolsMenuOperationTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish", isDirectory: true)

    private func makeRouteContext() -> OperationRouteContext {
        OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
    }

    // MARK: - NVD import

    func testNvdImportRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/NVD run 7", isDirectory: true)
        let importsURL = projectURL.appendingPathComponent("Imports", isDirectory: true)
        var launchedID: UUID?

        AppDelegate.beginNvdImportOperation(
            sourceURL: sourceURL,
            importsDirectory: importsURL,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "NVD Import")
        XCTAssertEqual(item.initialDetail, "Importing NVD run 7...")
        // The row showed as a Download while the call passed no type.
        XCTAssertEqual(item.operationType, .classification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.NvdSubcommand.self)
        XCTAssertEqual(command.inputPath, sourceURL.path)
        XCTAssertEqual(command.outputDir, importsURL.path)
        XCTAssertNil(command.name)
    }

    func testNvdImportKeepsItsRecordedCommandByteForByte() {
        // The row recorded this exact string before the migration.
        let reporter = RecordingOperationReporter()

        AppDelegate.beginNvdImportOperation(
            sourceURL: URL(fileURLWithPath: "/tmp/in/nvd-run", isDirectory: true),
            importsDirectory: URL(fileURLWithPath: "/tmp/project.lungfish/Imports", isDirectory: true),
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        XCTAssertEqual(
            reporter.items.first?.cliCommand,
            "lungfish-cli import nvd /tmp/in/nvd-run --output-dir /tmp/project.lungfish/Imports"
        )
    }

    // MARK: - CZ-ID import

    func testCzIdImportRecordsItsRowAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/CZ-ID report.tsv")
        // The run records the standardized project path, as the workflow
        // writes it into the result's provenance.
        let unstandardizedProjectURL = URL(
            fileURLWithPath: "/tmp/lane 1a2/Elsewhere/../Project.lungfish",
            isDirectory: true
        )
        var launchedID: UUID?

        AppDelegate.beginCzIdImportOperation(
            sourceURL: sourceURL,
            projectURL: unstandardizedProjectURL,
            sampleName: "Sample 7",
            reportFileName: "CZ-ID report.tsv",
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "CZ-ID Import")
        XCTAssertEqual(item.initialDetail, "Converting CZ-ID report.tsv...")
        // The row showed as a Download while the call passed no type.
        XCTAssertEqual(item.operationType, .classification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: ImportCommand.CzIdSubcommand.self)
        XCTAssertEqual(command.inputPath, sourceURL.path)
        XCTAssertEqual(command.projectPath, unstandardizedProjectURL.standardizedFileURL.path)
        XCTAssertFalse(command.projectPath.contains(".."))
        XCTAssertEqual(command.sampleName, "Sample 7")
        XCTAssertNil(command.metadataPath)
        XCTAssertNil(command.nonHostFastqPath)
    }

    func testCzIdImportRecordsTheCommandTheWorkflowWritesIntoProvenance() throws {
        // CzIdProjectImportWorkflow builds its provenance command from the same
        // values, so the row and the result's provenance name the same run.
        let reporter = RecordingOperationReporter()
        let sourceURL = URL(fileURLWithPath: "/tmp/in/report.tsv")

        AppDelegate.beginCzIdImportOperation(
            sourceURL: sourceURL,
            projectURL: URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true),
            sampleName: "S1",
            reportFileName: "report.tsv",
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        XCTAssertEqual(
            reporter.items.first?.cliCommand,
            "lungfish-cli import cz-id /tmp/in/report.tsv --project /tmp/project.lungfish --sample-name S1"
        )
    }

    // MARK: - Viral Recon launch failure

    func testViralReconLaunchFailureRecordsItsRowWithNoLockAndNoCommandAsAParityGap() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        var launchedID: UUID?

        AppDelegate.beginViralReconLaunchFailureOperation(
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Viral Recon")
        XCTAssertEqual(item.initialDetail, "Starting Viral Recon")
        XCTAssertEqual(item.operationType, .viralRecon)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // CLI parity gap. The failure happens before the run builds its
        // command, so the row records none. The closest real command is
        // `workflow run nf-core/viralrecon`. When a command can stand behind
        // this row, record it and replace this pin with a parse test.
        XCTAssertNil(item.cliCommand)
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
    }

    func testViralReconLaunchFailureLeavesAFailedRowThatCarriesTheReason() throws {
        let reporter = RecordingOperationReporter()
        let error = ViralReconWorkflowExecutionError.noProjectForResults
        let reason = error.localizedDescription

        let reported = AppDelegate.reportViralReconLaunchFailure(
            error,
            operationCenter: reporter,
            routeContext: nil
        )

        XCTAssertEqual(reporter.items.count, 1)
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reported, item.id)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.detail, reason)
        XCTAssertEqual(item.failure?.detail, reason)
        XCTAssertEqual(item.failure?.errorMessage, "Viral Recon could not start")
        XCTAssertEqual(item.failure?.errorDetail, reason)
        XCTAssertEqual(item.logs.map(\.level), [.error])
        XCTAssertEqual(item.logs.map(\.message), ["Viral Recon could not start: \(reason)"])
    }

    func testViralReconLaunchFailureReportsNothingWhenTheBeginIsRefused() {
        // The row requests no lock, so no real center refuses it. A reporter
        // that refuses every begin proves the log and the failure sit behind
        // the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")

        let reported = AppDelegate.reportViralReconLaunchFailure(
            ViralReconWorkflowExecutionError.noProjectForResults,
            operationCenter: reporter,
            routeContext: nil
        )

        XCTAssertNil(reported)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        XCTAssertTrue(reporter.items.allSatisfy { $0.logs.isEmpty && $0.failure == nil })
    }

    // MARK: - Managed read mapping

    private func bundleURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/lane 1a2/Imports/\(name).lungfishfastq", isDirectory: true)
    }

    private var referenceFASTAURL: URL {
        URL(fileURLWithPath: "/tmp/lane 1a2/Reference Sequences/Mito.lungfishref/genome/sequence.fa")
    }

    private var analysisDirectoryURL: URL {
        projectURL.appendingPathComponent("Analyses/minimap2-2026-10-02T10-00-00", isDirectory: true)
    }

    func testManagedMappingRecordsItsRowAndACommandThatMatchesTheRequest() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        let readGroup = MappingReadGroup(
            id: "rg-1",
            sampleName: "Sample A",
            library: "lib-1",
            platform: "ONT",
            platformUnit: "unit-1"
        )
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [bundleURL("Sample A")],
            referenceFASTAURL: referenceFASTAURL,
            projectURL: projectURL,
            outputDirectory: analysisDirectoryURL,
            sampleName: "Sample A",
            readGroup: readGroup,
            threads: 6,
            includeSecondary: true,
            includeSupplementary: false,
            minimumMappingQuality: 20,
            advancedArguments: ["--eqx", "-N", "5"],
            outputTrackName: "Sample A ONT"
        )
        var launchedID: UUID?

        AppDelegate.beginManagedMappingOperation(
            request: request,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Map Reads (minimap2): Sample A")
        XCTAssertEqual(item.initialDetail, "Mapping 1 file(s) to sequence.fa")
        XCTAssertEqual(item.operationType, .mapping)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: MapCommand.self)
        // The command names the bundle the user chose and the layout stays in auto.
        XCTAssertEqual(command.fastqFiles, [bundleURL("Sample A").path])
        XCTAssertEqual(command.reference, referenceFASTAURL.path)
        XCTAssertEqual(command.mapper, "minimap2")
        XCTAssertEqual(command.preset, "map-ont")
        XCTAssertEqual(command.project, projectURL.path)
        XCTAssertEqual(command.outputDir, analysisDirectoryURL.path)
        XCTAssertEqual(command.sampleName, "Sample A")
        XCTAssertEqual(command.trackName, "Sample A ONT")
        XCTAssertEqual(command.readGroupID, readGroup.id)
        XCTAssertEqual(command.readGroupSampleName, readGroup.sampleName)
        XCTAssertEqual(command.readGroupLibrary, readGroup.library)
        XCTAssertEqual(command.readGroupPlatform, readGroup.platform)
        XCTAssertEqual(command.readGroupPlatformUnit, readGroup.platformUnit)
        XCTAssertFalse(command.pairedEnd)
        XCTAssertEqual(command.readLayout, .auto)
        XCTAssertEqual(command.globalOptions.threads, 6)
        XCTAssertTrue(command.secondary)
        XCTAssertTrue(command.noSupplementary)
        XCTAssertEqual(command.minMapQ, 20)
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(command.extraArgs), ["--eqx", "-N", "5"])
    }

    func testManagedMappingRecordsTheCommandForARequestTheDialogBuilds() throws {
        // The request goes through the dialog's own plan builder and the output
        // directory the run assigns, so the recorded command is the one the Map
        // Reads window shows for a real selection.
        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [bundleURL("Sample B")],
            mode: .perBundle,
            tool: .bowtie2,
            modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: referenceFASTAURL,
            sourceReferenceBundleURL: nil,
            projectURL: projectURL,
            outputDirectory: projectURL.appendingPathComponent("Analyses", isDirectory: true),
            runToken: "abc123",
            readGroupIDText: "",
            readGroupSampleText: "",
            readGroupLibraryText: "",
            readGroupPlatformText: "",
            readGroupPlatformUnitText: "",
            threads: 4,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: ["--very-sensitive"]
        )
        let request = try XCTUnwrap(plan.requests.first).withOutputDirectory(analysisDirectoryURL)
        let readGroup = try XCTUnwrap(request.readGroup)
        let reporter = RecordingOperationReporter()

        AppDelegate.beginManagedMappingOperation(request: request, routeContext: nil, reporter: reporter) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "Map Reads (Bowtie2): Sample B")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: MapCommand.self)
        XCTAssertEqual(command.fastqFiles, [bundleURL("Sample B").path])
        XCTAssertEqual(command.reference, referenceFASTAURL.path)
        XCTAssertEqual(command.mapper, "bowtie2")
        XCTAssertNil(command.preset)
        XCTAssertEqual(command.project, projectURL.path)
        XCTAssertEqual(command.outputDir, analysisDirectoryURL.path)
        XCTAssertEqual(command.sampleName, "Sample B")
        XCTAssertNil(command.trackName)
        XCTAssertEqual(command.readGroupID, readGroup.id)
        XCTAssertEqual(command.readGroupSampleName, readGroup.sampleName)
        XCTAssertEqual(command.readGroupLibrary, readGroup.library)
        XCTAssertEqual(command.readGroupPlatform, readGroup.platform)
        XCTAssertEqual(command.readGroupPlatformUnit, readGroup.platformUnit)
        // The dialog's pairedEnd is a placeholder, and the CLI resolves the pairing.
        XCTAssertFalse(command.pairedEnd)
        XCTAssertEqual(command.readLayout, .auto)
        XCTAssertEqual(command.globalOptions.threads, 4)
        XCTAssertFalse(command.secondary)
        XCTAssertFalse(command.noSupplementary)
        XCTAssertEqual(command.minMapQ, 0)
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(command.extraArgs), ["--very-sensitive"])
    }

    func testManagedMappingOfAPairRecordsThePairedFlag() throws {
        let reporter = RecordingOperationReporter()
        let mates = [
            URL(fileURLWithPath: "/tmp/lane 1a2/Imports/Sample C_R1.fastq.gz"),
            URL(fileURLWithPath: "/tmp/lane 1a2/Imports/Sample C_R2.fastq.gz"),
        ]
        let request = MappingRunRequest(
            tool: .bwaMem2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: mates,
            referenceFASTAURL: referenceFASTAURL,
            outputDirectory: analysisDirectoryURL,
            sampleName: "Sample C",
            pairedEnd: true,
            threads: 8
        )

        AppDelegate.beginManagedMappingOperation(request: request, routeContext: nil, reporter: reporter) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.initialDetail, "Mapping 2 file(s) to sequence.fa")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: MapCommand.self)
        XCTAssertEqual(command.fastqFiles, mates.map(\.path))
        XCTAssertEqual(command.mapper, "bwa-mem2")
        XCTAssertTrue(command.pairedEnd)
        XCTAssertNil(command.project)
        XCTAssertEqual(command.globalOptions.threads, 8)
    }

    // MARK: - MAFFT alignment

    private var mafftInputURLs: [URL] {
        [
            URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/Genes A.fasta"),
            URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/Genes B.fasta"),
        ]
    }

    private var mafftOutputURL: URL {
        projectURL.appendingPathComponent("Analyses/Multiple Sequence Alignments/Genes.lungfishmsa", isDirectory: true)
    }

    func testMAFFTAlignmentRecordsItsRowAndACommandThatMatchesTheRun() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = makeRouteContext()
        // The argv the runner executes, with every option off its default.
        let argv = CLIMSAAlignmentRunner.buildArguments(
            inputURLs: mafftInputURLs,
            projectURL: projectURL,
            outputURL: mafftOutputURL,
            name: "Genes aligned",
            strategy: "linsi",
            outputOrder: "aligned",
            threads: 6,
            sequenceType: "nucleotide",
            adjustDirection: "accurate",
            symbols: "any",
            allowNondeterministicThreads: true,
            allowFASTQAssemblyInputs: true,
            extraArguments: ["--op", "1.53", "--leavegappyregion"],
            includedSequenceNames: ["seq 1", "seq 2"]
        )
        var launchedID: UUID?

        AppDelegate.beginMAFFTAlignmentOperation(
            cliArguments: argv,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Align Sequences (MAFFT)")
        XCTAssertEqual(item.initialDetail, "Preparing MAFFT alignment...")
        XCTAssertEqual(item.operationType, .multipleSequenceAlignmentGeneration)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: AlignCommand.MAFFTSubcommand.self)
        XCTAssertEqual(command.inputFiles, mafftInputURLs.map(\.path))
        XCTAssertEqual(command.projectPath, projectURL.path)
        XCTAssertEqual(command.outputPath, mafftOutputURL.path)
        XCTAssertEqual(command.name, "Genes aligned")
        XCTAssertEqual(command.strategy, "linsi")
        XCTAssertEqual(command.outputOrder, "aligned")
        XCTAssertEqual(command.sequenceType, "nucleotide")
        XCTAssertEqual(command.adjustDirection, "accurate")
        XCTAssertEqual(command.symbols, "any")
        XCTAssertTrue(command.allowNondeterministicThreads)
        XCTAssertTrue(command.allowFASTQAssemblyInputs)
        XCTAssertEqual(command.sequences, ["seq 1", "seq 2"])
        XCTAssertEqual(try AdvancedCommandLineOptions.parse(command.extraArgs), ["--op", "1.53", "--leavegappyregion"])
        XCTAssertEqual(command.globalOptions.threads, 6)
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testMAFFTAlignmentWithDefaultOptionsRecordsTheShortCommand() throws {
        let reporter = RecordingOperationReporter()
        let argv = CLIMSAAlignmentRunner.buildArguments(
            inputURLs: [mafftInputURLs[0]],
            projectURL: projectURL,
            outputURL: nil,
            name: nil,
            strategy: "auto",
            outputOrder: "input",
            threads: nil,
            extraArguments: []
        )

        AppDelegate.beginMAFFTAlignmentOperation(cliArguments: argv, routeContext: nil, reporter: reporter) { _ in }

        // The row recorded this exact string before the migration.
        XCTAssertEqual(
            reporter.items.first?.cliCommand,
            "lungfish-cli align mafft '/tmp/lane 1a2/Incoming/Genes A.fasta' --project '/tmp/lane 1a2/Project.lungfish' --strategy auto --output-order input --format json"
        )
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand,
            as: AlignCommand.MAFFTSubcommand.self
        )
        XCTAssertEqual(command.inputFiles, [mafftInputURLs[0].path])
        XCTAssertNil(command.outputPath)
        XCTAssertNil(command.name)
        XCTAssertEqual(command.sequenceType, "auto")
        XCTAssertEqual(command.adjustDirection, "off")
        XCTAssertEqual(command.symbols, "strict")
        XCTAssertFalse(command.allowNondeterministicThreads)
        XCTAssertFalse(command.allowFASTQAssemblyInputs)
        XCTAssertEqual(command.sequences, [])
        XCTAssertNil(command.globalOptions.threads)
    }

    // MARK: - Sites with no lock launch nothing when the begin is refused

    func testSitesWithNoLockLaunchNothingWhenTheBeginIsRefused() {
        // No real center refuses these rows, because they request no lock. A
        // reporter that refuses every begin proves each launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        let sourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Incoming/source.file")
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: [bundleURL("Sample A")],
            referenceFASTAURL: referenceFASTAURL,
            outputDirectory: analysisDirectoryURL,
            sampleName: "Sample A",
            threads: 4
        )
        var launched: [String] = []

        func check(_ name: String, _ result: OperationStartResult) {
            guard case .refused = result else { return XCTFail("\(name) must report the refusal") }
        }

        check("NVD import", AppDelegate.beginNvdImportOperation(
            sourceURL: sourceURL, importsDirectory: projectURL, routeContext: nil, reporter: reporter
        ) { _ in launched.append("NVD import") })
        check("CZ-ID import", AppDelegate.beginCzIdImportOperation(
            sourceURL: sourceURL, projectURL: projectURL, sampleName: "S1", reportFileName: "report.tsv",
            routeContext: nil, reporter: reporter
        ) { _ in launched.append("CZ-ID import") })
        check("Viral Recon launch failure", AppDelegate.beginViralReconLaunchFailureOperation(
            routeContext: nil, reporter: reporter
        ) { _ in launched.append("Viral Recon launch failure") })
        check("managed mapping", AppDelegate.beginManagedMappingOperation(
            request: request, routeContext: nil, reporter: reporter
        ) { _ in launched.append("managed mapping") })
        check("MAFFT alignment", AppDelegate.beginMAFFTAlignmentOperation(
            cliArguments: ["align", "mafft"], routeContext: nil, reporter: reporter
        ) { _ in launched.append("MAFFT alignment") })

        XCTAssertEqual(launched, [], "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 5)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
