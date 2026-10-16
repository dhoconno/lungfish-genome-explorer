// TaxTriageLaunchRouteTests.swift - The hidden key of the TaxTriage launch and the argv of its CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U30 M1 (panel decision K1, UX R2 and U-211-1). The Tools menu's TaxTriage launch
// takes the in-process route or, behind the hidden key `TaxTriageLaunchRoute`, `lungfish-cli taxtriage
// run --project`. The key stays `legacy` until the flip (M4). These tests read each value of the key
// from a defaults suite of their own and pin the argv the CLI route runs and records, which the
// command's own parser reads back.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageLaunchRouteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try TestTempDirectory.make(prefix: "taxtriage-launch-route")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
        try super.tearDownWithError()
    }

    // MARK: - The key

    private func route(holding value: Any?) -> TaxTriageLaunchRoute {
        let suite = makeTestDefaultsSuite(prefix: "taxtriage-launch-route")
        if let value { suite.defaults.set(value, forKey: TaxTriageLaunchRouteSettings.defaultsKey) }
        return TaxTriageLaunchRouteSettings(defaults: suite.defaults).route
    }

    func testTheKeyReadsEachValueAndAnUnknownOneTakesTheDefault() {
        XCTAssertEqual(TaxTriageLaunchRouteSettings.defaultsKey, "TaxTriageLaunchRoute")
        XCTAssertEqual(route(holding: "cli"), .cli)
        XCTAssertEqual(route(holding: "CLI"), .cli)
        XCTAssertEqual(route(holding: "legacy"), .legacy)
        XCTAssertEqual(route(holding: true), .cli)
        XCTAssertEqual(route(holding: false), .legacy)
        XCTAssertEqual(route(holding: "in-process"), TaxTriageLaunchRouteSettings.defaultRoute, "a value nothing reads")
        XCTAssertEqual(route(holding: 7), TaxTriageLaunchRouteSettings.defaultRoute, "a number is not a route")
        XCTAssertEqual(TaxTriageLaunchRoute.allCases, [.legacy, .cli])
    }

    /// K1. The default stays the in-process route until Q32 M3's evidence and BIO's read (M4).
    func testTheDefaultRouteStaysLegacyUntilTheFlip() {
        XCTAssertEqual(TaxTriageLaunchRouteSettings.defaultRoute, .legacy)
        XCTAssertEqual(route(holding: nil), .legacy, "an unset key keeps the in-process route")
        XCTAssertEqual(route(holding: "in-process"), .legacy, "a value nothing reads keeps the in-process route")
    }

    // MARK: - The argv

    private func write(_ name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try "@r1\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
        return url
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
        let launch = try XCTUnwrap(try TaxTriageCLIRouteLaunch.taxTriage(config: sampleConfig, projectURL: project))

        var legacy = try RecordedCLICommand.arguments(of: AppDelegate.taxTriageCLICommand(for: sampleConfig))
        XCTAssertEqual(legacy.first, "taxtriage")
        let output = try XCTUnwrap(legacy.firstIndex(of: "--output"))
        legacy.replaceSubrange(output...(output + 1), with: ["--project", project.path])
        XCTAssertEqual(launch.arguments, ["taxtriage", "run"] + legacy.dropFirst() + ["--format", "json"])
        XCTAssertEqual(launch.sampleIDs, ["air A"])
        XCTAssertEqual(launch.title, "TaxTriage (1 sample)")
        XCTAssertEqual(launch.firstDetail, "Starting TaxTriage pipeline\u{2026}")
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

    /// Several samples take one `--input` each and `--batch`. A pair takes its bundle, which the
    /// command plans as a pair, and each control takes `--negative-control` with the name the command
    /// gives its sample. A request whose samples name two platforms carries the dialog's platform,
    /// which the command gives each sample whose reads record none (BIO, a mixed-platform request).
    func testSeveralSamplesTakeOneInputEachTheBatchAndTheirControls() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let pairBundle = project.appendingPathComponent("Imports/air.B.lungfishfastq", isDirectory: true)
        let single = try write("blank 1.fastq.gz", in: project.appendingPathComponent("Imports", isDirectory: true))
        var control = TaxTriageSample(sampleId: "blank", fastq1: single, platform: .oxford)
        control.isNegativeControl = true
        let samples = [
            TaxTriageSample(
                sampleId: "air-B",
                fastq1: try write("air_R1.fastq", in: pairBundle),
                fastq2: try write("air_R2.fastq", in: pairBundle),
                platform: .illumina
            ),
            control,
        ]
        let launch = try XCTUnwrap(try TaxTriageCLIRouteLaunch.taxTriage(config: config(samples), projectURL: project))

        XCTAssertEqual(Array(launch.arguments.prefix(9)), [
            "taxtriage", "run", "--input", pairBundle.path, "--input", single.path, "--project", project.path, "--batch",
        ])
        XCTAssertEqual(Array(launch.arguments[9...12]), ["--negative-control", "blank 1", "--db", root.appendingPathComponent("Databases/kraken2").path])
        XCTAssertEqual(Array(launch.arguments[13...14]), ["--platform", "illumina"])
        XCTAssertEqual(Array(launch.arguments.suffix(2)), ["--format", "json"])
        XCTAssertFalse(launch.arguments.contains("--sample"))
        XCTAssertFalse(launch.arguments.contains("--input2"))
        XCTAssertEqual(launch.title, "TaxTriage (2 samples)")
        // The command drops the last two extensions of an input's name, so `air.B.lungfishfastq`
        // gives `air` and the dialog's `air-B` is not kept, a difference BIO reads with Q32.
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

    /// The begin names the `cliCommand`, the argv that runs, which `taxtriage run` parses back, with
    /// today's title, first detail and type, and starts the run only on the row it began.
    @MainActor
    func testTheBeginRecordsTheArgvItRunsAsItsCommand() throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let reads = root.appendingPathComponent("Reads", isDirectory: true)
        let launch = try XCTUnwrap(try TaxTriageCLIRouteLaunch.taxTriage(
            config: config([TaxTriageSample(sampleId: "S1", fastq1: try write("S1.fastq", in: reads))]),
            projectURL: project
        ))
        let routeContext = OperationRouteContext(projectURL: project, windowStateScopeID: nil)
        let reporter = RecordingOperationReporter()
        var started: UUID?
        AppDelegate.beginTaxTriageCLIRouteOperation(launch, routeContext: routeContext, reporter: reporter) { started = $0 }

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

    /// A pair of several samples whose files lie in no bundle cannot be one `--input`, so the launch
    /// refuses in words before it starts anything (U-211-1).
    func testAPairOutsideABundleInSeveralSamplesIsRefusedInWords() throws {
        let reads = root.appendingPathComponent("Reads", isDirectory: true)
        let samples = [
            TaxTriageSample(sampleId: "S1", fastq1: try write("S1_R1.fastq", in: reads), fastq2: try write("S1_R2.fastq", in: reads)),
            TaxTriageSample(sampleId: "S2", fastq1: try write("S2.fastq", in: reads)),
        ]
        XCTAssertThrowsError(try TaxTriageCLIRouteLaunch.taxTriage(config: config(samples), projectURL: root)) { error in
            XCTAssertEqual(error as? TaxTriageCLIRouteRefusal, .pairOutsideABundle(sampleID: "S1"))
        }
        let refusal = TaxTriageCLIRouteRefusal.pairOutsideABundle(sampleID: "S1")
        XCTAssertEqual(refusal.title, "TaxTriage Cannot Run These Samples")
        XCTAssertEqual(
            refusal.message,
            "Sample S1 is a pair of reads outside a FASTQ bundle. A TaxTriage run of several samples reads each pair from its bundle. Import the reads into the project, or run this sample alone."
        )
        XCTAssertNil(try TaxTriageCLIRouteLaunch.taxTriage(config: config([]), projectURL: root), "no sample, no launch")
    }
}
