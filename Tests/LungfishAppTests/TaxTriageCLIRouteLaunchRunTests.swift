// TaxTriageCLIRouteLaunchRunTests.swift - The TaxTriage launch runs its CLI route or refuses in words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U30 M1 (panel decision K1, owner direction of 2026-10-15, UX U-211-1). The Tools
// menu hands its TaxTriage config to `launchTaxTriage`, which begins a row that records
// `lungfish-cli taxtriage run --project` and runs a stand-in command that plays the captured
// transcript, with no hidden key to read since Phase 2.12 K1. A launch with no project open is refused
// in words.

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
final class TaxTriageCLIRouteLaunchRunTests: XCTestCase {
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

    /// Launches `config` and returns the row it began, or nil when it began none.
    private func launch(
        _ config: TaxTriageConfig,
        viewer: ViewerViewController,
        routeContext: OperationRouteContext?,
        cli: URL? = nil
    ) -> OperationCenter.Item? {
        let existing = Set(OperationCenter.shared.items.map(\.id))
        makeAppDelegateWithTemporaryState().launchTaxTriage(
            config: config, viewerController: viewer, routeContext: routeContext, cliURLOverride: cli
        )
        let started = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        rowIDs.append(contentsOf: started.map(\.id))
        return started.first
    }

    // MARK: - No project

    func testTheLaunchRefusesALaunchWithNoProjectInTodaysWords() throws {
        let reads = try ClassifierRouteFixtures.makeProject(in: root).inputs
        let before = try ClassifierRouteFixtures.snapshot(of: root)
        let recorder = RecordingNoProjectPresenter()
        let row = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
            launch(config(inputs: reads), viewer: ViewerViewController(), routeContext: nil)
        }
        XCTAssertEqual(recorder.presentations.map(\.title), ["No Project Open"])
        XCTAssertEqual(
            recorder.presentations.map(\.message),
            ["Open or create a project before running TaxTriage. LGE saves its results in the project's Analyses folder."]
        )
        XCTAssertNil(row, "a refused launch registers no row")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: root), before, "a refused launch writes nothing")
    }

    // MARK: - The launch (2.12 K1)

    /// 2.12 K1. The launch runs `lungfish-cli taxtriage run --project` with no key to read, so the row
    /// records the command's argv and not the in-process command.
    func testTheLaunchRunsTheCLIRouteWithNoKeyToRead() async throws {
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
        let (viewer, window) = makeViewerInWindow()
        defer { close(window) }

        let row = try XCTUnwrap(launch(config(inputs: made.inputs), viewer: viewer, routeContext: routeContext, cli: cli))
        XCTAssertEqual(row.cliCommand, expected.cliCommand)
        XCTAssertTrue(expected.cliCommand.hasPrefix("lungfish-cli taxtriage run --input \(made.inputs[0].path) "), expected.cliCommand)
        XCTAssertTrue(expected.cliCommand.contains(" --project \(made.project.path) "), expected.cliCommand)
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the CLI row did not finish")
        _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
    }

    // MARK: - The CLI route

    /// The launch begins a row with today's title and first detail that records the argv it runs, runs
    /// the stand-in command, and completes with the command's message. The app writes nothing into the
    /// project, before or after the command, and no sheet opens.
    func testTheCLIRouteRunsTaxTriageRunAgainstTheTranscript() async throws {
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

        let row = try XCTUnwrap(launch(config, viewer: viewer, routeContext: routeContext, cli: cli))
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
    func testTheCLIRouteFailsWithTodaysAlert() async throws {
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

        let row = try XCTUnwrap(launch(config(inputs: made.inputs), viewer: viewer, routeContext: routeContext, cli: cli))
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the CLI row did not finish")
        _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
        let ended = try XCTUnwrap(item(row.id))
        XCTAssertEqual(ended.displayStateLabel, "Failed")
        XCTAssertEqual(ended.detail, "Database not found: /missing-db")
        XCTAssertEqual(window.attachedSheet.map(Self.texts(in:)), "TaxTriage Failed\nDatabase not found: /missing-db")
    }

    /// A launch the argv cannot carry is refused in words before any row or byte (U-211-1).
    func testTheCLIRouteRefusesAPairOutsideABundleInWords() throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["S1_R1.fastq", "S1_R2.fastq", "S2.fastq"])
        var config = config(inputs: [made.inputs[0], made.inputs[2]])
        config.samples[0].fastq2 = made.inputs[1]
        let before = try ClassifierRouteFixtures.snapshot(of: root)
        let recorder = RecordingNoProjectPresenter()
        let row = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(recorder) {
            launch(
                config,
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
    func testTheCLIRouteRefusesSamplesTheCommandWouldRenameInWords() throws {
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
