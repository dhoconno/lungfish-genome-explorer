// TaxTriageLaunchRouteRunTests.swift - Under each value of its key the TaxTriage launch runs or refuses in words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U30 M1 (panel decision K1, owner direction of 2026-10-15, UX U-211-1). The Tools
// menu hands its TaxTriage config to `launchTaxTriage`, which takes the route the hidden key names.
// `legacy` runs `runTaxTriage` unchanged, here on a stand-in engine. `cli` begins a row that records
// `lungfish-cli taxtriage run --project` and runs a stand-in command that plays the captured
// transcript. Either route refuses a launch with no project open in the same words.

import AppKit
import os
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriageLaunchRouteRunTests: XCTestCase {
    private var root: URL!
    private var rowIDs: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "taxtriage-launch-run")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        rowIDs.forEach { OperationCenter.shared.clearItem(id: $0) }
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    private func config(inputs: [URL]) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: inputs.map { TaxTriageSample(sampleId: $0.deletingPathExtension().lastPathComponent, fastq1: $0) },
            outputDirectory: root.appendingPathComponent("Unused/taxtriage-output", isDirectory: true),
            kraken2DatabasePath: root.appendingPathComponent("Databases/kraken2", isDirectory: true),
            maxCpus: 2,
            profile: "local"
        )
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// A viewer in a window, so a sheet has somewhere to sit.
    private func makeViewerInWindow() -> (ViewerViewController, NSWindow) {
        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        return (viewer, window)
    }

    private func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.contentViewController = nil
        window.close()
    }

    /// Launches `config` on `route` and returns the row it began, or nil when it began none.
    private func launch(
        _ config: TaxTriageConfig,
        route: TaxTriageLaunchRoute,
        viewer: ViewerViewController,
        routeContext: OperationRouteContext?,
        cli: URL? = nil
    ) -> OperationCenter.Item? {
        let existing = Set(OperationCenter.shared.items.map(\.id))
        // A runner that ends the legacy launch at once, so it never reaches the managed Nextflow.
        AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue({
            TaxTriageSerialBatchRunner(runPipeline: { _, _ in throw CancellationError() })
        }) {
            makeAppDelegateWithTemporaryState().launchTaxTriage(
                config: config,
                viewerController: viewer,
                routeContext: routeContext,
                route: route,
                cliURLOverride: cli
            )
        }
        let started = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        rowIDs.append(contentsOf: started.map(\.id))
        return started.first
    }

    // MARK: - No project

    func testEachRouteRefusesALaunchWithNoProjectInTheSameWords() throws {
        let reads = try ClassifierRouteFixtures.makeProject(in: root).inputs
        for route in TaxTriageLaunchRoute.allCases {
            let before = try ClassifierRouteFixtures.snapshot(of: root)
            let recorder = RecordingNoProjectPresenter()
            let row = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
                launch(config(inputs: reads), route: route, viewer: ViewerViewController(), routeContext: nil)
            }
            XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open"], "\(route)")
            XCTAssertEqual(
                recorder.presentations.map(\.message),
                ["Open or create a project before running TaxTriage. LGE saves its results in the project's Analyses folder."],
                "\(route)"
            )
            XCTAssertNil(row, "\(route): a refused launch registers no row")
            XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: root), before, "\(route): a refused launch writes nothing")
        }
    }

    // MARK: - legacy

    /// `legacy` runs `runTaxTriage` unchanged. Its row records the legacy command, with `--output`
    /// into the batch folder it made, and its stand-in engine fails the one sample.
    func testTheLegacyValueRunsTheInProcessRoute() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let routeContext = OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
        let (viewer, window) = makeViewerInWindow()
        defer { close(window) }
        let row = try XCTUnwrap(launch(config(inputs: made.inputs), route: .legacy, viewer: viewer, routeContext: routeContext))

        XCTAssertEqual(row.title, "TaxTriage (1 sample)")
        let command = try XCTUnwrap(row.cliCommand)
        XCTAssertTrue(command.hasPrefix("lungfish-cli taxtriage --input "), command)
        XCTAssertTrue(command.contains(" --output \(made.project.path)/Analyses/taxtriage-batch-"), command)
        XCTAssertFalse(command.contains("--project"), command)
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the legacy row did not finish")
    }

    /// The M1 review's item 3 (b), the legacy side of a mixed-platform request (U30 M3). A bundle whose
    /// reads record Oxford Nanopore runs on the dialog's Illumina on `legacy`, because the serial batch
    /// hands each sample the dialog's config. On `cli` the command runs the sample on the platform its
    /// reads record (`TaxTriageRunBundleInputsTests.testEachSampleRunsOnThePlatformItsBundleRecordsAndAPooledRunOfTwoPlatformsIsRefused`),
    /// a declared difference that Q32 M3 and BIO read.
    func testTheLegacyValueRunsABundleThatRecordsNanoporeOnTheDialogsPlatform() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let bundle = made.project.appendingPathComponent("Imports/ont.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let reads = bundle.appendingPathComponent("ont.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        try FASTQMetadataStore.write(PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore), for: reads)
        let routeContext = OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
        let (viewer, window) = makeViewerInWindow()
        defer { close(window) }
        let received = OSAllocatedUnfairLock<[TaxTriageConfig]>(initialState: [])
        let existing = Set(OperationCenter.shared.items.map(\.id))
        AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue({
            TaxTriageSerialBatchRunner(runPipeline: { config, _ in
                received.withLock { $0.append(config) }
                throw CancellationError()
            })
        }) {
            makeAppDelegateWithTemporaryState().launchTaxTriage(
                config: config(inputs: [bundle]), viewerController: viewer, routeContext: routeContext, route: .legacy
            )
        }
        let row = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) })
        rowIDs.append(row.id)
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the legacy row did not finish")

        let configs = received.withLock { $0 }
        XCTAssertEqual(configs.map(\.platform), [.illumina], "the sample's run takes the dialog's platform")
        XCTAssertEqual(configs.flatMap(\.samples).map(\.platform), [.illumina], "and so does its sample")
    }

    // MARK: - The key's values at the launch (U30 M4)

    /// The route a key in a defaults suite of the test's own names, read as the Tools menu's launch
    /// reads the user's defaults (`TaxTriageLaunchRouteSettings.currentRoute`).
    private func route(ofAKeyHolding value: String?) -> TaxTriageLaunchRoute {
        let suite = makeTestDefaultsSuite(prefix: "taxtriage-launch-run")
        if let value { suite.defaults.set(value, forKey: TaxTriageLaunchRouteSettings.defaultsKey) }
        return TaxTriageLaunchRouteSettings(defaults: suite.defaults).route
    }

    /// U30 M4. Since the flip an unset key launches `lungfish-cli taxtriage run --project`, so the row
    /// records the command's argv and not the in-process command.
    func testAnUnsetKeyLaunchesTheCLIRouteSinceTheFlip() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let routeContext = OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
        let expected = try XCTUnwrap(try ClassifierCLIRouteLaunch.taxTriage(config: config(inputs: made.inputs), projectURL: made.project))
        let cli = try ClassifierRouteFixtures.standInCLI(
            in: root,
            lines: [
                #"{"event":"start","message":"Starting TaxTriage.","progress":0,"schemaVersion":2}"#,
                #"{"error":"Database not found: \/missing-db","event":"failed","schemaVersion":2}"#,
            ],
            exitStatus: 64
        )
        let keyRoute = route(ofAKeyHolding: nil)
        XCTAssertEqual(keyRoute, .cli, "an unset key takes the CLI route")
        let (viewer, window) = makeViewerInWindow()
        defer { close(window) }

        let row = try XCTUnwrap(launch(config(inputs: made.inputs), route: keyRoute, viewer: viewer, routeContext: routeContext, cli: cli))
        XCTAssertEqual(row.cliCommand, expected.cliCommand)
        XCTAssertTrue(expected.cliCommand.hasPrefix("lungfish-cli taxtriage run --input \(made.inputs[0].path) "), expected.cliCommand)
        XCTAssertTrue(expected.cliCommand.contains(" --project \(made.project.path) "), expected.cliCommand)
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the CLI row did not finish")
        _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
    }

    /// U30 M4. An explicit `legacy` still runs `runTaxTriage` in this process for one Preview, so the row
    /// records the in-process command, with `--output` into the batch folder it made (K1).
    func testAnExplicitLegacyKeyStillRunsTheInProcessRouteForOnePreview() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let routeContext = OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
        let keyRoute = route(ofAKeyHolding: "legacy")
        XCTAssertEqual(keyRoute, .legacy, "an explicit legacy keeps the in-process route")
        let (viewer, window) = makeViewerInWindow()
        defer { close(window) }

        let row = try XCTUnwrap(launch(config(inputs: made.inputs), route: keyRoute, viewer: viewer, routeContext: routeContext))
        let command = try XCTUnwrap(row.cliCommand)
        XCTAssertTrue(command.hasPrefix("lungfish-cli taxtriage --input "), command)
        XCTAssertTrue(command.contains(" --output \(made.project.path)/Analyses/taxtriage-batch-"), command)
        XCTAssertFalse(command.contains("--project"), command)
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the legacy row did not finish")
    }

    // MARK: - cli

    /// `cli` begins a row with today's title and first detail that records the argv it runs, runs
    /// the stand-in command, and completes with the command's message. The app writes nothing into the
    /// project, before or after the command, and no sheet opens.
    func testTheCLIValueRunsTaxTriageRunAgainstTheTranscript() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let routeContext = OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
        let config = config(inputs: made.inputs)
        let expected = try XCTUnwrap(try ClassifierCLIRouteLaunch.taxTriage(config: config, projectURL: made.project))
        let transcript = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "complete-project", root: root)
        // The result the command leaves in its batch folder, which the row reads back (M2).
        let folder = try XCTUnwrap(transcript.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = TaxTriageResult(config: config, runtime: 3, exitCode: 0, outputDirectory: folder)
        try result.save()
        let cli = try ClassifierRouteFixtures.standInCLI(in: root, lines: transcript.lines)
        let before = try ClassifierRouteFixtures.snapshot(of: made.project)
        let (viewer, window) = makeViewerInWindow()
        defer { close(window) }

        let row = try XCTUnwrap(launch(config, route: .cli, viewer: viewer, routeContext: routeContext, cli: cli))
        XCTAssertEqual(row.title, "TaxTriage (1 sample)")
        XCTAssertEqual(row.detail, "Starting TaxTriage pipeline\u{2026}")
        XCTAssertEqual(row.cliCommand, expected.cliCommand)
        XCTAssertTrue(expected.cliCommand.hasPrefix("lungfish-cli taxtriage run --input \(made.inputs[0].path) "), expected.cliCommand)
        XCTAssertTrue(expected.cliCommand.contains(" --project \(made.project.path) "), expected.cliCommand)

        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the CLI row did not finish")
        let ended = try XCTUnwrap(item(row.id))
        XCTAssertEqual(ended.displayStateLabel, "Completed")
        XCTAssertEqual(ended.detail, result.summary, "the legacy row's detail, read back from the result")
        XCTAssertNil(window.attachedSheet, "a completed run opens no sheet")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: made.project), before, "the route wrote into the project")
    }

    /// A failed command fails the row with its message and shows today's `TaxTriage Failed` sheet
    /// with the message as its text (UX F5).
    func testTheCLIValueFailsWithTodaysAlert() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let routeContext = OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
        let cli = try ClassifierRouteFixtures.standInCLI(
            in: root,
            lines: [
                #"{"event":"start","message":"Starting TaxTriage.","progress":0,"schemaVersion":2}"#,
                #"{"error":"Database not found: \/missing-db","event":"failed","schemaVersion":2}"#,
            ],
            exitStatus: 64
        )
        let (viewer, window) = makeViewerInWindow()
        defer { close(window) }

        let row = try XCTUnwrap(launch(config(inputs: made.inputs), route: .cli, viewer: viewer, routeContext: routeContext, cli: cli))
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the CLI row did not finish")
        _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
        let ended = try XCTUnwrap(item(row.id))
        XCTAssertEqual(ended.displayStateLabel, "Failed")
        XCTAssertEqual(ended.detail, "Database not found: /missing-db")
        XCTAssertEqual(window.attachedSheet.map(Self.texts(in:)), "TaxTriage Failed\nDatabase not found: /missing-db")
    }

    /// A launch the argv cannot carry is refused in words before any row or byte (U-211-1).
    func testTheCLIValueRefusesAPairOutsideABundleInWords() throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["S1_R1.fastq", "S1_R2.fastq", "S2.fastq"])
        var config = config(inputs: [made.inputs[0], made.inputs[2]])
        config.samples[0].fastq2 = made.inputs[1]
        let before = try ClassifierRouteFixtures.snapshot(of: root)
        let recorder = RecordingNoProjectPresenter()
        let row = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
            launch(
                config,
                route: .cli,
                viewer: ViewerViewController(),
                routeContext: OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
            )
        }
        XCTAssertEqual(recorder.presentations.map(\.title), ["TaxTriage Cannot Run These Samples"])
        XCTAssertEqual(recorder.presentations.map(\.message), [TaxTriageCLIRouteRefusal.pairOutsideABundle(sampleID: "S1_R1").message])
        XCTAssertNil(row, "a refused launch registers no row")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: root), before, "a refused launch writes nothing")
    }

    /// The M1 review's item 5. Several samples the command would name otherwise than the dialog shows
    /// them are refused through the same presenter as the pair, before any row or byte (U-211-1).
    func testTheCLIValueRefusesSamplesTheCommandWouldRenameInWords() throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let cases: [(names: [String], refusal: TaxTriageCLIRouteRefusal)] = [
            (["air.B", "blank"], .renamed(sampleID: "air.B", commandName: "air")),
            (["Plate.1", "Plate.2"], .sharedName(first: "Plate.1", second: "Plate.2", name: "Plate")),
        ]
        for (names, refusal) in cases {
            let bundles = try names.map { name -> URL in
                let bundle = root.appendingPathComponent("Reads/\(name).lungfishfastq", isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try "@r1\nACGT\n+\nIIII\n".write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
                return bundle
            }
            let before = try ClassifierRouteFixtures.snapshot(of: root)
            let recorder = RecordingNoProjectPresenter()
            let row = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
                launch(
                    config(inputs: bundles),
                    route: .cli,
                    viewer: ViewerViewController(),
                    routeContext: OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
                )
            }
            XCTAssertEqual(recorder.presentations.map(\.title), ["TaxTriage Cannot Run These Samples"], "\(names)")
            XCTAssertEqual(recorder.presentations.map(\.message), [refusal.message], "\(names)")
            XCTAssertNil(row, "\(names): a refused launch registers no row")
            XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: root), before, "\(names): a refused launch writes nothing")
        }
    }

    /// The text fields of a sheet, top to bottom, one per line.
    private static func texts(in window: NSWindow) -> String {
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return texts.joined(separator: "\n")
    }
}
