// TaxTriageCLIRouteLaunchTests.swift - The argv the TaxTriage launch runs through its CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U30 M1, M2 and M4 (panel decision K1, UX R2 and U-211-1, the M1 review's items 2 to 4). The
// Tools menu's TaxTriage launch takes `lungfish-cli taxtriage run --project`, with no hidden key since Phase 2.12
// K1. These tests pin the argv the CLI route runs and records, which the command's own parser reads back, and the
// refusals of samples the command would not name as the dialog does.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageCLIRouteLaunchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try TestTempDirectory.make(prefix: "taxtriage-launch-route")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
        try super.tearDownWithError()
    }

    // MARK: - The argv

    private func write(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try "@r1\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A FASTQ bundle as the dialog hands it, the bundle's folder, with one file of reads and the role
    /// its metadata records.
    private func bundle(_ name: String, in folder: URL, role: SampleRole? = nil) throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        _ = try write("reads.fastq", in: bundle)
        if let role {
            try FASTQBundleCSVMetadata.save(FASTQBundleCSVMetadata(keyValuePairs: ["sample_name": name, "sample_role": role.rawValue]), to: bundle)
        }
        return bundle
    }

    private func config(_ samples: [TaxTriageSample], platform: TaxTriageConfig.Platform = .illumina) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: samples,
            platform: platform,
            outputDirectory: root.appendingPathComponent("Unused/taxtriage-output", isDirectory: true),
            kraken2DatabasePath: root.appendingPathComponent("Databases/kraken2", isDirectory: true),
            maxCpus: 2,
            profile: "local",
            revision: "e10bfebda32a62711f38a4e23ab03b61725a9675"
        )
    }

    private func launch(_ samples: [TaxTriageSample], project: URL) throws -> ClassifierCLIRouteLaunch {
        try XCTUnwrap(try ClassifierCLIRouteLaunch.taxTriage(config: config(samples), projectURL: project))
    }

    private func refusal(_ samples: [TaxTriageSample]) -> TaxTriageCLIRouteRefusal? {
        do {
            _ = try ClassifierCLIRouteLaunch.taxTriage(config: config(samples), projectURL: root)
            return nil
        } catch {
            return error
        }
    }

    /// One sample runs the words its legacy row records, `taxtriage run` with `--project` in place of
    /// `--output`, the words the parity class's side C runs (2.8 T17), and `--format json`.
    func testOneSampleRunsTheLegacyRowsWordsIntoTheProject() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let reads = root.appendingPathComponent("Reads", isDirectory: true)
        var sampleConfig = config([
            TaxTriageSample(sampleId: "air A", fastq1: try write("air_R1.fastq", in: reads), fastq2: try write("air_R2.fastq", in: reads)),
        ])
        sampleConfig.skipKrona = true
        sampleConfig.extraArguments = ["--min_reads", "5"]
        let launch = try XCTUnwrap(try ClassifierCLIRouteLaunch.taxTriage(config: sampleConfig, projectURL: project))

        var legacy = try RecordedCLICommand.arguments(of: AppDelegate.taxTriageCLICommand(for: sampleConfig))
        XCTAssertEqual(legacy.first, "taxtriage")
        let output = try XCTUnwrap(legacy.firstIndex(of: "--output"))
        legacy.replaceSubrange(output...(output + 1), with: ["--project", project.path])
        XCTAssertEqual(launch.arguments, ["taxtriage", "run"] + legacy.dropFirst() + ["--format", "json"])
        XCTAssertEqual(launch.tool, .taxTriage)
        XCTAssertFalse(launch.extractsReads)
        XCTAssertEqual(launch.sampleIDs, ["air A"])
        XCTAssertEqual(launch.title, "TaxTriage (1 sample)")
        XCTAssertEqual(launch.firstDetail, "Starting TaxTriage pipeline\u{2026}")
        XCTAssertEqual(launch.failureAlertTitle, "TaxTriage Failed")
        XCTAssertEqual(launch.workflowName, "TaxTriage")
        XCTAssertTrue(launch.cliCommand.hasPrefix("lungfish-cli taxtriage run --input "), launch.cliCommand)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: launch.cliCommand), launch.arguments, "Copy CLI Command is the argv")

        let parsed = try TaxTriageCommand.RunSubcommand.parse(Array(launch.arguments.dropFirst()))
        XCTAssertEqual(parsed.inputs, [reads.appendingPathComponent("air_R1.fastq").path])
        XCTAssertEqual(parsed.input2, reads.appendingPathComponent("air_R2.fastq").path)
        XCTAssertEqual(parsed.sampleId, "air A")
        XCTAssertEqual(parsed.project, project.path)
        XCTAssertNil(parsed.outputDir)
        XCTAssertFalse(parsed.batch)
        XCTAssertTrue(parsed.skipKrona)
    }

    /// Several samples whose names the command keeps take one `--input` each and `--batch`. A pair takes
    /// its bundle, which the command plans as a pair, and each control takes `--negative-control` with its
    /// name. A request whose samples name two platforms carries the dialog's platform, which the command
    /// gives each sample whose reads record none (BIO, a mixed-platform request).
    func testSeveralSamplesWithPlainNamesTakeOneInputEachTheBatchAndTheirControls() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let pairBundle = project.appendingPathComponent("Imports/air.lungfishfastq", isDirectory: true)
        let single = try write("blank 1.fastq.gz", in: project.appendingPathComponent("Imports", isDirectory: true))
        var control = TaxTriageSample(sampleId: "blank 1", fastq1: single, platform: .oxford)
        control.isNegativeControl = true
        let samples = [
            TaxTriageSample(
                sampleId: "air",
                fastq1: try write("air_R1.fastq", in: pairBundle),
                fastq2: try write("air_R2.fastq", in: pairBundle),
                platform: .illumina
            ),
            control,
        ]
        let launch = try launch(samples, project: project)

        XCTAssertEqual(Array(launch.arguments.prefix(9)), [
            "taxtriage", "run", "--input", pairBundle.path, "--input", single.path, "--project", project.path, "--batch",
        ])
        XCTAssertEqual(Array(launch.arguments[9...12]), ["--negative-control", "blank 1", "--db", root.appendingPathComponent("Databases/kraken2").path])
        XCTAssertEqual(Array(launch.arguments[13...14]), ["--platform", "illumina"])
        XCTAssertEqual(Array(launch.arguments.suffix(2)), ["--format", "json"])
        XCTAssertFalse(launch.arguments.contains("--sample"))
        XCTAssertFalse(launch.arguments.contains("--input2"))
        XCTAssertEqual(launch.title, "TaxTriage (2 samples)")
        XCTAssertEqual(launch.sampleIDs, ["air", "blank 1"])
        XCTAssertEqual(
            launch.sampleIDs,
            [pairBundle, single].map { TaxTriageAnalysisRunTool.sampleID(for: $0, explicitSampleID: nil, totalSampleCount: 2) },
            "the names the command gives the samples"
        )

        let parsed = try TaxTriageCommand.RunSubcommand.parse(Array(launch.arguments.dropFirst()))
        XCTAssertEqual(parsed.inputs, [pairBundle.path, single.path])
        XCTAssertNil(parsed.input2)
        XCTAssertNil(parsed.sampleId)
        XCTAssertTrue(parsed.batch)
        XCTAssertEqual(parsed.negativeControls, ["blank 1"])
        XCTAssertEqual(parsed.project, project.path)
    }

    /// The M1 review's item 1 (U30 M3). Loose files named with a dot and a space keep their names, so the
    /// launch runs, and the command spells each sample's folder by its own rule
    /// (`AnalysesFolder.batchSampleDirectory`), so `S.1` is folder `S_1` and `blank 1` is `blank_1`. The
    /// in-process route kept the dot until Phase 2.12 K1 deleted it.
    func testTheCommandSpellsASampleFolderByItsOwnRule() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        // The command drops the last two extensions of each of several inputs, so `.fastq.gz` keeps the dot.
        let samples = try ["S.1", "blank 1"].map { TaxTriageSample(sampleId: $0, fastq1: try write("\($0).fastq.gz", in: imports), platform: .illumina) }

        XCTAssertEqual(try launch(samples, project: project).sampleIDs, ["S.1", "blank 1"], "the command keeps both names, so nothing is refused")
        let batch = root.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        XCTAssertEqual(
            try samples.map { try AnalysesFolder.batchSampleDirectory(named: $0.sampleId, in: batch).lastPathComponent },
            ["S_1", "blank_1"],
            "cli"
        )
    }

    /// The M1 review's item 2. Several samples the command would not name as the dialog shows them are
    /// refused in words, first two samples that would share one name and then a sample whose name would
    /// change. One sample keeps its name through `--sample`, so it runs.
    func testSeveralSamplesTheCommandWouldRenameAreRefusedInWords() throws {
        let imports = root.appendingPathComponent("Imports", isDirectory: true)
        let dotted = try bundle("air.B", in: imports)
        let plain = try bundle("air", in: imports)
        let other = try bundle("blank", in: imports)
        let plate1 = try bundle("Plate.1", in: imports)
        let plate2 = try bundle("Plate.2", in: imports)

        XCTAssertEqual(
            refusal([TaxTriageSample(sampleId: "air.B", fastq1: dotted), TaxTriageSample(sampleId: "blank", fastq1: other)]),
            .renamed(sampleID: "air.B", commandName: "air"),
            "a dotted bundle loses its last dot"
        )
        XCTAssertEqual(
            refusal([TaxTriageSample(sampleId: "air-B", fastq1: plain), TaxTriageSample(sampleId: "blank", fastq1: other)]),
            .renamed(sampleID: "air-B", commandName: "air"),
            "a Sample ID typed in the dialog"
        )
        XCTAssertEqual(
            refusal([TaxTriageSample(sampleId: "Plate.1", fastq1: plate1), TaxTriageSample(sampleId: "Plate.2", fastq1: plate2)]),
            .sharedName(first: "Plate.1", second: "Plate.2", name: "Plate"),
            "two bundles that collapse to one name"
        )
        XCTAssertEqual(
            refusal([TaxTriageSample(sampleId: "air", fastq1: plain), TaxTriageSample(sampleId: "air", fastq1: other)]),
            .renamed(sampleID: "air", commandName: "blank"),
            "two samples typed with one id"
        )
        XCTAssertNil(refusal([TaxTriageSample(sampleId: "air", fastq1: plain), TaxTriageSample(sampleId: "blank", fastq1: other)]), "plain names pass")
        XCTAssertNil(refusal([TaxTriageSample(sampleId: "air.B", fastq1: dotted)]), "one sample keeps its name through --sample")

        XCTAssertEqual(TaxTriageCLIRouteRefusal.sharedName(first: "Plate.1", second: "Plate.2", name: "Plate").title, "TaxTriage Cannot Run These Samples")
        XCTAssertEqual(
            TaxTriageCLIRouteRefusal.sharedName(first: "Plate.1", second: "Plate.2", name: "Plate").message,
            "Samples Plate.1 and Plate.2 would both be named Plate when TaxTriage runs several samples. Change a Sample ID or rename a FASTQ bundle so that the names differ, or run the samples one at a time."
        )
        XCTAssertEqual(
            TaxTriageCLIRouteRefusal.renamed(sampleID: "air.B", commandName: "air").message,
            "TaxTriage would name sample air.B as air when it runs several samples, so the results would not match the name in this window. Set its Sample ID to air, rename its FASTQ bundle, or run this sample alone."
        )
    }

    /// The M1 review's fix 3 (a). The dialog hands each sample as its `.lungfishfastq` bundle with no mate,
    /// the dialog's platform and the test sample role (`TaxTriageCLIGUIParityReplayTests+Sides.swift`).
    func testAWizardShapedConfigRunsItsBundlesAsInputs() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let bundles = try ["S1", "S2", "S3"].map { try bundle($0, in: imports) }
        let samples = zip(["S1", "S2", "S3"], bundles).map { TaxTriageSample(sampleId: $0, fastq1: $1, fastq2: nil, platform: .illumina) }

        let one = try launch([samples[0]], project: project)
        XCTAssertEqual(Array(one.arguments.prefix(6)), ["taxtriage", "run", "--input", bundles[0].path, "--sample", "S1"])
        XCTAssertEqual(one.sampleIDs, ["S1"])
        XCTAssertEqual(try TaxTriageCommand.RunSubcommand.parse(Array(one.arguments.dropFirst())).inputs, [bundles[0].path])

        let three = try launch(samples, project: project)
        XCTAssertEqual(Array(three.arguments.prefix(11)), [
            "taxtriage", "run", "--input", bundles[0].path, "--input", bundles[1].path, "--input", bundles[2].path,
            "--project", project.path, "--batch",
        ])
        XCTAssertEqual(three.sampleIDs, ["S1", "S2", "S3"])
        let parsed = try TaxTriageCommand.RunSubcommand.parse(Array(three.arguments.dropFirst()))
        XCTAssertEqual(parsed.inputs, bundles.map(\.path))
        XCTAssertTrue(parsed.batch)
    }

    /// The M1 review's fix 3 (b). One sample marked as a control takes `--negative-control` with its own name.
    func testOneSampleMarkedAsAControlTakesNegativeControlWithItsOwnName() throws {
        let reads = root.appendingPathComponent("Reads", isDirectory: true)
        var control = TaxTriageSample(sampleId: "air A", fastq1: try write("air.fastq", in: reads))
        control.isNegativeControl = true
        let launch = try launch([control], project: root.appendingPathComponent("Project.lungfish", isDirectory: true))

        let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--negative-control"))
        XCTAssertEqual(launch.arguments[index + 1], "air A")
        let parsed = try TaxTriageCommand.RunSubcommand.parse(Array(launch.arguments.dropFirst()))
        XCTAssertEqual(parsed.negativeControls, ["air A"])
        XCTAssertEqual(parsed.sampleId, "air A")
    }

    /// The M1 review's item 3 (a). One sample carries its own platform as `--platform`. What the command
    /// makes of a bundle that records a platform is pinned by the command's own tests,
    /// `TaxTriageRunBundleInputsTests.testEachSampleRunsOnThePlatformItsBundleRecordsAndAPooledRunOfTwoPlatformsIsRefused`
    /// and `testAPooledRunOfOnePlatformRunsOnItAndReadsThatRecordNoneTakeThePlatformFlag`, so the dialog's word
    /// is not what runs for such a bundle, a declared difference for Q32 M3.
    func testOneSampleCarriesItsPlatformAsTheDialogShowsIt() throws {
        let reads = root.appendingPathComponent("Reads", isDirectory: true)
        let sample = TaxTriageSample(sampleId: "S1", fastq1: try write("S1.fastq", in: reads), platform: .oxford)
        let launch = try launch([sample], project: root.appendingPathComponent("Project.lungfish", isDirectory: true))
        let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--platform"))
        XCTAssertEqual(launch.arguments[index + 1], "oxford")
    }

    /// The M1 review's item 4. The dialog shows Test sample for a bundle whose role is a negative control,
    /// so the argv names no control, and the command's plan marks the sample from the bundle's role.
    func testABundleWhoseRoleIsAControlIsMarkedByTheCommandThoughTheDialogMarksNone() async throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let control = try bundle("ntc", in: project.appendingPathComponent("Imports", isDirectory: true), role: .negativeControl)
        let launch = try launch([TaxTriageSample(sampleId: "ntc", fastq1: control, platform: .illumina)], project: project)
        XCTAssertFalse(launch.arguments.contains("--negative-control"), "the dialog marks no control")

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Databases/kraken2", isDirectory: true), withIntermediateDirectories: true)
        let command = try TaxTriageCommand.RunSubcommand.parse(Array(launch.arguments.dropFirst()))
        let (destination, conflict) = command.resultDestination()
        let tool = TaxTriageAnalysisRunTool(
            request: command.runRequest(usageConflict: conflict),
            services: TaxTriageRunServices(
                expandInputs: { arguments, recursive in try CLIClassificationFolderResolver.expandInputArguments(arguments, recursive: recursive) },
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
            )
        )
        let plan = try await tool.plan(
            AnalysisRunRequest(inputs: [], destination: destination, groupsSamples: command.batch, commandLine: ["lungfish-cli", "taxtriage", "run"]),
            context: AnalysisRunPlanningContext(projectURL: destination.projectURL)
        )
        XCTAssertEqual(plan.units.flatMap(\.value.config.samples).map(\.isNegativeControl), [true], "the command marks the sample from its role")
    }

    /// The begin names the `cliCommand`, the argv that runs, which `taxtriage run` parses back, with
    /// today's title, first detail and type, and starts the run only on the row it began.
    @MainActor
    func testTheBeginRecordsTheArgvItRunsAsItsCommand() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let reads = root.appendingPathComponent("Reads", isDirectory: true)
        let launch = try launch([TaxTriageSample(sampleId: "S1", fastq1: try write("S1.fastq", in: reads))], project: project)
        let routeContext = OperationRouteContext(projectURL: project, windowStateScopeID: nil)
        let reporter = RecordingOperationReporter()
        var started: UUID?
        AppDelegate.beginClassifierCLIRouteOperation(launch, routeContext: routeContext, reporter: reporter) { started = $0 }

        let row = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(started, row.id)
        XCTAssertEqual(row.title, "TaxTriage (1 sample)")
        XCTAssertEqual(row.initialDetail, "Starting TaxTriage pipeline\u{2026}")
        XCTAssertEqual(row.operationType, .classification)
        XCTAssertEqual(row.routeContext, routeContext)
        XCTAssertNil(row.targetBundleURL, "the row locks no bundle")
        let recorded = try XCTUnwrap(row.cliCommand)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: recorded), launch.arguments, "the row records the argv that runs")
        let command = try RecordedCLICommand.parse(recorded, as: TaxTriageCommand.RunSubcommand.self)
        XCTAssertEqual(command.inputs, [reads.appendingPathComponent("S1.fastq").path])
        XCTAssertEqual(command.sampleId, "S1")
        XCTAssertEqual(command.project, project.path)
        XCTAssertNil(command.outputDir, "the command makes Analyses/taxtriage-batch-<timestamp> itself")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    /// A pair of several samples whose files lie in no one bundle cannot be one `--input`, so the launch
    /// refuses in words before it starts anything (U-211-1).
    func testAPairOutsideABundleInSeveralSamplesIsRefusedInWords() throws {
        let reads = root.appendingPathComponent("Reads", isDirectory: true)
        let samples = [
            TaxTriageSample(sampleId: "S1", fastq1: try write("S1_R1.fastq", in: reads), fastq2: try write("S1_R2.fastq", in: reads)),
            TaxTriageSample(sampleId: "S2", fastq1: try write("S2.fastq", in: reads)),
        ]
        XCTAssertEqual(refusal(samples), .pairOutsideABundle(sampleID: "S1"))
        let refusal = TaxTriageCLIRouteRefusal.pairOutsideABundle(sampleID: "S1")
        XCTAssertEqual(refusal.title, "TaxTriage Cannot Run These Samples")
        XCTAssertEqual(
            refusal.message,
            "Sample S1 is a pair of FASTQ files that do not lie together in one FASTQ bundle. When TaxTriage runs several samples, it takes each pair from one bundle. Import the reads into the project, or run this sample alone."
        )
        XCTAssertNil(try ClassifierCLIRouteLaunch.taxTriage(config: config([]), projectURL: root), "no sample, no launch")
    }
}
