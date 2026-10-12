// ClassifierLaunchRouteTests.swift - The hidden route switch, the CLI route's argv and its rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A10 (panel decisions E1, E10, E11 and E15, UX differences D1 to D4). The route
// of each classifier launch comes from its own hidden key, read through the defaults a test
// passes. The CLI route records the argv the transport runs, `kraken2 classify` or `esviritu
// detect` into the project with `--format json`, and begins its row with today's title and first
// detail.

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
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "ClassifierLaunchRouteTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    // MARK: - The switch

    func testEachLaunchHasItsOwnHiddenKey() {
        XCTAssertEqual(ClassifierLaunchPath.allCases.map(\.defaultsKey), [
            "ClassifierLaunchRoute.kraken2.single",
            "ClassifierLaunchRoute.kraken2.batch",
            "ClassifierLaunchRoute.esviritu.single",
            "ClassifierLaunchRoute.esviritu.batch",
        ])
        XCTAssertEqual(ClassifierLaunchPath.kraken2(sampleCount: 1), .kraken2Single)
        XCTAssertEqual(ClassifierLaunchPath.kraken2(sampleCount: 2), .kraken2Batch)
        XCTAssertEqual(ClassifierLaunchPath.esViritu(sampleCount: 1), .esVirituSingle)
        XCTAssertEqual(ClassifierLaunchPath.esViritu(sampleCount: 3), .esVirituBatch)
    }

    func testEveryLaunchTakesTheCLIRouteSinceParitySideCIsGreen() {
        XCTAssertEqual(ClassifierLaunchRouteSettings.defaultRoute, .cli, "lane F3 flipped the default after parity side C (E10)")
        let routes = ClassifierLaunchRouteSettings(defaults: defaults)
        for path in ClassifierLaunchPath.allCases {
            XCTAssertEqual(routes.route(for: path), .cli, path.rawValue)
        }
    }

    func testAKeyMovesOnlyItsOwnLaunch() {
        defaults.set("legacy", forKey: ClassifierLaunchPath.kraken2Batch.defaultsKey)
        defaults.set(false, forKey: ClassifierLaunchPath.esVirituSingle.defaultsKey)
        defaults.set("someday", forKey: ClassifierLaunchPath.esVirituBatch.defaultsKey)
        let routes = ClassifierLaunchRouteSettings(defaults: defaults)

        XCTAssertEqual(routes.route(for: .kraken2Single), .cli)
        XCTAssertEqual(routes.route(for: .kraken2Batch), .legacy)
        XCTAssertEqual(routes.route(for: .esVirituSingle), .legacy, "a Boolean false asks for the legacy route")
        XCTAssertEqual(routes.route(for: .esVirituBatch), .cli, "a value this reader does not know keeps the default")

        defaults.set(true, forKey: ClassifierLaunchPath.esVirituSingle.defaultsKey)
        defaults.set("CLI", forKey: ClassifierLaunchPath.kraken2Batch.defaultsKey)
        XCTAssertEqual(routes.route(for: .esVirituSingle), .cli)
        XCTAssertEqual(routes.route(for: .kraken2Batch), .cli)
    }

    /// Decision L1. Both routes write their result into the open project's Analyses folder, so a
    /// launch with no project open takes neither, whatever its key says. The launch is refused
    /// (ClassifierNoProjectRefusalTests).
    func testALaunchWithNoProjectTakesNoRouteWhateverItsKeySays() {
        let delegate = makeAppDelegateWithTemporaryState()
        for path in ClassifierLaunchPath.allCases {
            defaults.set("cli", forKey: path.defaultsKey)
        }
        let routes = ClassifierLaunchRouteSettings(defaults: defaults)
        let project = OperationRouteContext(projectURL: projectURL, windowStateScopeID: nil)
        let noProject = OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())

        for path in ClassifierLaunchPath.allCases {
            XCTAssertEqual(delegate.classifierLaunchRoute(for: path, routeContext: project, routes: routes), .cli, path.rawValue)
            XCTAssertNil(
                delegate.classifierLaunchRoute(for: path, routeContext: noProject, routes: routes),
                "\(path.rawValue): a launch without a project is refused and takes no route"
            )
            defaults.set("legacy", forKey: path.defaultsKey)
            XCTAssertEqual(delegate.classifierLaunchRoute(for: path, routeContext: project, routes: routes), .legacy, path.rawValue)
            XCTAssertNil(
                delegate.classifierLaunchRoute(for: path, routeContext: noProject, routes: routes),
                "\(path.rawValue): the legacy key does not keep a launch without a project on the in-process route"
            )
        }
        let unset = ClassifierLaunchRouteSettings(defaults: UserDefaults(suiteName: "\(suiteName!)-unset")!)
        XCTAssertEqual(delegate.classifierLaunchRoute(for: .kraken2Single, routeContext: project, routes: unset), .cli)
        XCTAssertNil(delegate.classifierLaunchRoute(for: .kraken2Single, routeContext: noProject, routes: unset))
    }

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

    /// Each CLI route row begins as today's row of the same launch, with the same title, first
    /// detail, type, route and no lock, and records the argv the transport runs, which a shell
    /// splits back into the same arguments.
    func testEachCLIRouteRowBeginsAsTodaysRowAndRecordsTheArgvThatRuns() throws {
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScopeID: UUID())
        let kraken2 = [kraken2Config(inputs: [importURL("A.fastq")], output: "a"), kraken2Config(inputs: [importURL("B.fastq")], output: "b")]
        let esViritu = [
            esVirituConfig(sample: "A", inputs: [importURL("A.fastq")], plansReadSet: false),
            esVirituConfig(sample: "B", inputs: [importURL("B.fastq")], plansReadSet: false),
        ]
        let cases: [(name: String, launch: ClassifierCLIRouteLaunch?, today: (any OperationReporting) -> Void)] = [
            ("kraken2 single", .kraken2(configs: [kraken2[0]], projectURL: projectURL), { reporter in
                AppDelegate.beginClassificationOperation(config: kraken2[0], routeContext: routeContext, reporter: reporter) { _ in }
            }),
            ("kraken2 batch", .kraken2(configs: kraken2, projectURL: projectURL), { reporter in
                AppDelegate.beginClassificationBatchOperation(configs: kraken2, routeContext: routeContext, reporter: reporter) { _ in }
            }),
            ("esviritu single", .esViritu(configs: [esViritu[0]], projectURL: projectURL), { reporter in
                AppDelegate.beginEsVirituOperation(config: esViritu[0], routeContext: routeContext, reporter: reporter) { _ in }
            }),
            ("esviritu batch", .esViritu(configs: esViritu, projectURL: projectURL), { reporter in
                AppDelegate.beginEsVirituBatchOperation(configs: esViritu, routeContext: routeContext, reporter: reporter) { _ in }
            }),
        ]
        for testCase in cases {
            let launch = try XCTUnwrap(testCase.launch, testCase.name)
            let todays = RecordingOperationReporter()
            testCase.today(todays)
            let routes = RecordingOperationReporter()
            var started: UUID?
            AppDelegate.beginClassifierCLIRouteOperation(launch, routeContext: routeContext, reporter: routes) { started = $0 }

            let today = try XCTUnwrap(todays.items.first, testCase.name)
            let row = try XCTUnwrap(routes.items.first, testCase.name)
            XCTAssertEqual(started, row.id, testCase.name)
            XCTAssertEqual(row.title, today.title, "\(testCase.name): D1")
            XCTAssertEqual(row.initialDetail, today.initialDetail, "\(testCase.name): D2")
            XCTAssertEqual(row.operationType, .classification, "\(testCase.name): D3")
            XCTAssertEqual(row.operationType, today.operationType, testCase.name)
            XCTAssertNil(row.targetBundleURL, testCase.name)
            XCTAssertEqual(row.additionalLockedBundleURLs, [], testCase.name)
            XCTAssertEqual(row.routeContext, routeContext, testCase.name)
            let recorded = try XCTUnwrap(row.cliCommand, testCase.name)
            XCTAssertTrue(recorded.hasPrefix("lungfish-cli \(launch.arguments[0]) \(launch.arguments[1]) "), "\(testCase.name): D4")
            XCTAssertEqual(try RecordedCLICommand.arguments(of: recorded), launch.arguments, "\(testCase.name): the row records the argv that runs")
            XCTAssertNotEqual(recorded, today.cliCommand, "\(testCase.name): today's row records its own output folder or nothing")
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
