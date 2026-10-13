// ClassifierLaunchRouteTests.swift - The CLI route's argv and its rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A10 (panel decisions E1, E11 and E15, UX differences D1 to D4). The CLI route
// records the argv the transport runs, `kraken2 classify` or `esviritu detect` into the project
// with `--format json`, and begins its row with today's title and first detail. The hidden keys
// that chose between this route and the in-process route went in Phase 2.9 (E14), and
// ClassifierNoProjectRefusalTests holds the refusal of a launch with no project (decision L1).

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ClassifierLaunchRouteTests: XCTestCase {
    private let projectURL = URL(fileURLWithPath: "/tmp/lane a10/Project.lungfish")
    private let databaseURL = URL(fileURLWithPath: "/tmp/lane a10/Databases/Viral DB")
    private let digest = String(repeating: "ab", count: 32)

    // MARK: - Kraken2 argv

    func testKraken2RunsKraken2ClassifyIntoTheProjectWithJSONEvents() throws {
        let inputs = [importURL("Sample 1_R1.fastq.gz"), importURL("Sample 1_R2.fastq.gz")]
        var config = kraken2Config(inputs: inputs, output: "classification-0000A10A")
        config.isPairedEnd = true
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: [config], projectURL: projectURL))
        let builder = Array(ClassificationCLIInvocationBuilder.build(for: config).arguments.dropFirst(2))

        XCTAssertEqual(launch.arguments, [
            "kraken2", "classify",
            "--db", "Viral",
            "--db-digest", digest,
            "--project", projectURL.path,
            "--confidence", "0.35",
            "--min-hit-groups", "3",
            "--threads", "6",
            "--paired",
            "--memory-mapping",
            "--quick",
            "--extra-args", "--minimum-base-quality 20",
            "--profile",
            "--bracken-read-length", String(BrackenProfileRequest.automaticDefault.readLength),
            "--bracken-threshold", String(BrackenProfileRequest.automaticDefault.threshold),
            "--format", "json",
        ] + inputs.map(\.path))
        XCTAssertFalse(launch.arguments.contains("--output-dir"), "the command makes Analyses/kraken2-<timestamp> itself (E1)")
        XCTAssertFalse(launch.arguments.contains("--batch"))
        // Every flag of the builder is there, so the route adds no mapping of its own.
        let routeFlags = Set(launch.arguments.filter { $0.hasPrefix("--") })
        for flag in builder.filter({ $0.hasPrefix("--") && $0 != "--output-dir" }) {
            XCTAssertTrue(routeFlags.contains(flag), "\(flag) of the builder is missing")
        }
        XCTAssertEqual(launch.title, "Profiling Sample 1_R1.fastq.gz")
        XCTAssertEqual(launch.firstDetail, "Starting Kraken2 with Viral...")
        XCTAssertFalse(launch.isBatch)
        XCTAssertEqual(launch.failureAlertTitle, "Classification Failed")
    }

    func testAKraken2BatchIsOneCommandThatPairsItsSamplesItself() throws {
        var first = kraken2Config(inputs: [importURL("A_R1.fastq.gz"), importURL("A_R2.fastq.gz")], output: "classification-batch-x/A")
        first.isPairedEnd = true
        var second = kraken2Config(inputs: [importURL("B.lungfishfastq")], output: "classification-batch-x/B")
        second.plansReadSet = true
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: [first, second], projectURL: projectURL))

        XCTAssertEqual(Array(launch.arguments.prefix(2)), ["kraken2", "classify"])
        XCTAssertEqual(launch.arguments.filter { $0 == "--batch" }.count, 1)
        for refused in ["--paired", "--unpaired", "--read-format", "--output-dir"] {
            XCTAssertFalse(launch.arguments.contains(refused), "--batch plans each sample's reads itself, so \(refused) goes")
        }
        XCTAssertEqual(
            Array(launch.arguments.suffix(3)),
            [importURL("A_R1.fastq.gz").path, importURL("A_R2.fastq.gz").path, importURL("B.lungfishfastq").path],
            "every sample's inputs, in plan order, after the options"
        )
        XCTAssertEqual(value(after: "--project", in: launch.arguments), projectURL.path)
        XCTAssertEqual(value(after: "--format", in: launch.arguments), "json")
        XCTAssertEqual(launch.title, "Classification Batch (2 samples)")
        XCTAssertEqual(launch.firstDetail, "Starting Kraken2/Bracken batch\u{2026}")
        XCTAssertEqual(launch.sampleIDs, ["A", "B"])
        XCTAssertEqual(launch.failureAlertTitle, "Classification Batch Failed")
        XCTAssertEqual(launch.cliCommand.components(separatedBy: "\n").count, 1, "one command, not one per sample (E8)")
    }

    /// E9. The route keeps the `--db-digest` that `ClassificationCLIInvocationBuilder` writes since
    /// lane A8, the lower-case SHA-256 of a registry digest, and adds none of its own.
    func testOnlyARegistryDigestOfSHA256IsChecked() throws {
        let cases: [(digest: String?, expected: String?)] = [
            ("sha256:" + digest.uppercased(), digest),
            (digest, digest),
            ("md5:abc", nil),
            (String(repeating: "z", count: 64), nil),
            (nil, nil),
        ]
        for testCase in cases {
            let config = kraken2Config(inputs: [importURL("reads.fastq")], output: "classification-x", databaseDigest: testCase.digest)
            let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: [config], projectURL: projectURL))
            XCTAssertEqual(value(after: "--db-digest", in: launch.arguments), testCase.expected, "\(testCase.digest ?? "nil")")
            XCTAssertLessThanOrEqual(launch.arguments.filter { $0 == "--db-digest" }.count, 1, "one digest check")
        }
    }

    func testTheKraken2ExtractGoalKeepsItsTitleAndOpensTheExtractionSheet() throws {
        let config = kraken2Config(inputs: [importURL("reads.fastq")], output: "classification-x", goal: .extract)
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: [config], projectURL: projectURL))
        XCTAssertEqual(launch.title, "Classifying (extract) reads.fastq")
        XCTAssertTrue(launch.extractsReads)
    }

    // MARK: - EsViritu argv

    func testEsVirituRunsEsVirituDetectIntoTheProjectWithJSONEvents() throws {
        let config = esVirituConfig(sample: "air-A", inputs: [importURL("air-A.lungfishfastq")], plansReadSet: true)
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.esViritu(configs: [config], projectURL: projectURL))

        XCTAssertEqual(launch.arguments, [
            "esviritu", "detect",
            "--input", importURL("air-A.lungfishfastq").path,
            "--sample", "air-A",
            "--read-format", "auto",
            "--db", databaseURL.path,
            "--project", projectURL.path,
            "--threads", "4",
            "--no-qc",
            "--format", "json",
        ])
        XCTAssertEqual(
            launch.arguments.dropFirst(2).filter { $0 != "--project" && $0 != projectURL.path && $0 != "--format" && $0 != "json" },
            EsVirituCLIInvocationBuilder.esVirituDetectCLIArguments(for: config)
                .filter { $0 != "--output" && $0 != config.outputDirectory.path },
            "the builder's argv with the project in place of the output folder"
        )
        XCTAssertEqual(launch.title, "EsViritu air-A")
        XCTAssertEqual(launch.firstDetail, "Starting EsViritu viral detection\u{2026}")
        XCTAssertEqual(launch.failureAlertTitle, "EsViritu Failed")
    }

    func testAnEsVirituBatchIsOneCommandWithEverySamplesInputs() throws {
        let configs = [
            esVirituConfig(sample: "air-A", inputs: [importURL("air-A_R1.fastq.gz"), importURL("air-A_R2.fastq.gz")], plansReadSet: false),
            esVirituConfig(sample: "air.B", inputs: [importURL("air.B.lungfishfastq")], plansReadSet: true),
        ]
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.esViritu(configs: configs, projectURL: projectURL))

        XCTAssertEqual(launch.arguments, [
            "esviritu", "detect",
            "--input", importURL("air-A_R1.fastq.gz").path, importURL("air-A_R2.fastq.gz").path, importURL("air.B.lungfishfastq").path,
            "--batch",
            "--db", databaseURL.path,
            "--project", projectURL.path,
            "--threads", "4",
            "--no-qc",
            "--format", "json",
        ])
        XCTAssertEqual(launch.title, "EsViritu Batch (2 samples)")
        XCTAssertEqual(launch.firstDetail, "Starting EsViritu batch\u{2026}")
        XCTAssertEqual(launch.sampleIDs, configs.map { MetagenomicsSampleGrouper.sanitizeSampleId($0.sampleName) })
        XCTAssertEqual(launch.failureAlertTitle, "EsViritu Batch Failed")
    }

    // MARK: - The row (D1 to D4)

    /// Each CLI route row begins with the title and first detail of the launch's row before the
    /// CLI route, which lane A32 froze as the literals below when it deleted the in-process begin
    /// helpers that made them. It has the classification type, the route and no lock, and records
    /// the argv the transport runs, which a shell splits back into the same arguments.
    func testEachCLIRouteRowBeginsAsTodaysRowAndRecordsTheArgvThatRuns() throws {
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
        let kraken2 = [kraken2Config(inputs: [importURL("A.fastq")], output: "a"), kraken2Config(inputs: [importURL("B.fastq")], output: "b")]
        let esViritu = [
            esVirituConfig(sample: "A", inputs: [importURL("A.fastq")], plansReadSet: false),
            esVirituConfig(sample: "B", inputs: [importURL("B.fastq")], plansReadSet: false),
        ]
        let cases: [(name: String, launch: ClassifierCLIRouteLaunch?, title: String, detail: String)] = [
            ("kraken2 single", .kraken2(configs: [kraken2[0]], projectURL: projectURL), "Profiling A.fastq", "Starting Kraken2 with Viral..."),
            ("kraken2 batch", .kraken2(configs: kraken2, projectURL: projectURL), "Classification Batch (2 samples)", "Starting Kraken2/Bracken batch\u{2026}"),
            ("esviritu single", .esViritu(configs: [esViritu[0]], projectURL: projectURL), "EsViritu A", "Starting EsViritu viral detection\u{2026}"),
            ("esviritu batch", .esViritu(configs: esViritu, projectURL: projectURL), "EsViritu Batch (2 samples)", "Starting EsViritu batch\u{2026}"),
        ]
        for testCase in cases {
            let launch = try XCTUnwrap(testCase.launch, testCase.name)
            let routes = RecordingOperationReporter()
            var started: UUID?
            AppDelegate.beginClassifierCLIRouteOperation(launch, routeContext: routeContext, reporter: routes) { started = $0 }

            let row = try XCTUnwrap(routes.items.first, testCase.name)
            XCTAssertEqual(started, row.id, testCase.name)
            XCTAssertEqual(row.title, testCase.title, "\(testCase.name): D1")
            XCTAssertEqual(row.initialDetail, testCase.detail, "\(testCase.name): D2")
            XCTAssertEqual(row.operationType, .classification, "\(testCase.name): D3")
            XCTAssertNil(row.targetBundleURL, testCase.name)
            XCTAssertEqual(row.additionalLockedBundleURLs, [], testCase.name)
            XCTAssertEqual(row.routeContext, routeContext, testCase.name)
            let recorded = try XCTUnwrap(row.cliCommand, testCase.name)
            XCTAssertTrue(recorded.hasPrefix("lungfish-cli \(launch.arguments[0]) \(launch.arguments[1]) "), "\(testCase.name): D4")
            XCTAssertEqual(try RecordedCLICommand.arguments(of: recorded), launch.arguments, "\(testCase.name): the row records the argv that runs")
        }
    }

    // MARK: - The CLI parses what the row records (E1)

    /// Each command the CLI route's row records runs through the real `kraken2 classify` or
    /// `esviritu detect` parser with the launch's values, so Copy CLI Command replays the run into
    /// a new folder of the project (E1, UX checklist 4). A batch is one command with `--batch`
    /// over every sample's inputs in plan order. A Kraken2 command checks the database's digest
    /// (E9), and an EsViritu batch names no sample or read format, which `--batch` refuses.
    func testEachCLIRouteCommandParsesThroughTheCLI() throws {
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: nil)
        let single = kraken2Config(inputs: [importURL("A.fastq")], output: "a")
        for configs in [[single], [single, kraken2Config(inputs: [importURL("B.fastq")], output: "b")]] {
            let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: configs, projectURL: projectURL))
            let reporter = RecordingOperationReporter()
            AppDelegate.beginClassifierCLIRouteOperation(launch, routeContext: routeContext, reporter: reporter) { _ in }
            let recorded = try XCTUnwrap(reporter.items.first?.cliCommand)

            let command = try RecordedCLICommand.parse(recorded, as: ClassifyCommand.self)
            XCTAssertEqual(command.project, projectURL.path, recorded)
            XCTAssertNil(command.outputDir, "the command makes Analyses/kraken2[-batch]-<timestamp> itself (E1)")
            XCTAssertEqual(command.batch, configs.count > 1, recorded)
            XCTAssertEqual(command.databaseName, "Viral")
            XCTAssertEqual(command.databaseDigest, digest, "E9")
            XCTAssertEqual(command.fastqFiles, configs.flatMap { $0.inputFiles.map(\.path) }, "every sample's inputs in plan order")
            XCTAssertEqual(command.globalOptions.outputFormat, .json)
        }

        let samples = [
            esVirituConfig(sample: "A", inputs: [importURL("A_R1.fastq.gz"), importURL("A_R2.fastq.gz")], plansReadSet: false),
            esVirituConfig(sample: "B", inputs: [importURL("B.lungfishfastq")], plansReadSet: true),
        ]
        for configs in [[samples[0]], samples] {
            let isBatch = configs.count > 1
            let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.esViritu(configs: configs, projectURL: projectURL))
            let reporter = RecordingOperationReporter()
            AppDelegate.beginClassifierCLIRouteOperation(launch, routeContext: routeContext, reporter: reporter) { _ in }
            let recorded = try XCTUnwrap(reporter.items.first?.cliCommand)

            let command = try RecordedCLICommand.parse(recorded, as: EsVirituCommand.DetectSubcommand.self)
            XCTAssertEqual(command.project, projectURL.path, recorded)
            XCTAssertNil(command.outputDir, "the command makes Analyses/esviritu-batch-<timestamp> itself (E1)")
            XCTAssertEqual(command.batch, isBatch, recorded)
            XCTAssertEqual(command.inputFiles, configs.flatMap { $0.inputFiles.map(\.path) }, "every sample's inputs in plan order")
            XCTAssertEqual(command.databasePath, databaseURL.path)
            XCTAssertEqual(command.globalOptions.threads, 4)
            XCTAssertTrue(command.noQC)
            XCTAssertEqual(command.globalOptions.outputFormat, .json)
            let arguments = try RecordedCLICommand.arguments(of: recorded)
            if isBatch {
                XCTAssertNil(command.sampleName, recorded)
                XCTAssertFalse(arguments.contains("--sample"), "--batch names each sample by its files")
                XCTAssertFalse(arguments.contains("--read-format"), "--batch plans each sample's reads itself")
            } else {
                XCTAssertEqual(command.sampleName, "A")
                XCTAssertEqual(command.readFormat, .paired)
            }
        }
    }

    // MARK: - Helpers

    private func importURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/lane a10/Imports/\(name)")
    }

    private func kraken2Config(
        inputs: [URL],
        output: String,
        goal: ClassificationConfig.Goal = .profile,
        databaseDigest: String? = "default"
    ) -> ClassificationConfig {
        ClassificationConfig(
            goal: goal,
            inputFiles: inputs,
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: databaseURL,
            databaseDigest: databaseDigest == "default" ? "sha256:" + digest : databaseDigest,
            brackenProfileRequest: .automaticDefault,
            confidence: 0.35,
            minimumHitGroups: 3,
            threads: 6,
            memoryMapping: true,
            quickMode: true,
            outputDirectory: URL(fileURLWithPath: "/tmp/lane a10/Imports/\(output)"),
            extraArguments: ["--minimum-base-quality", "20"]
        )
    }

    private func esVirituConfig(sample: String, inputs: [URL], plansReadSet: Bool) -> EsVirituConfig {
        var config = EsVirituConfig(
            inputFiles: inputs,
            isPairedEnd: inputs.count == 2,
            sampleName: sample,
            outputDirectory: URL(fileURLWithPath: "/tmp/lane a10/Imports/esviritu-x/\(sample)"),
            databasePath: databaseURL,
            qualityFilter: false,
            threads: 4,
            extraArguments: [],
            readFormat: inputs.count == 2 ? .paired : .unpaired,
            inputLayout: nil
        )
        config.plansReadSet = plansReadSet
        return config
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
