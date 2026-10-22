// OperationCenterCLIBridgeTests.swift - One test for each label a bridged lungfish-cli run can end on, and the row rule
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Combine
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// Phase 2.6 lane C3. No test covered `OperationCenterCLIBridge` directly. Each test plays a
/// version 1 transcript captured from a real run (`CLIEventCompatCorpus`) through a stand-in
/// `lungfish-cli`, `CLISubprocessTransport` and a runner that maps the events with the
/// bridge, then reads the row's label and log the way the Operations panel shows them. The
/// rows live on `OperationCenter.shared`, because the bridge writes there.
///
/// Each test plays its run twice. Once as captured, and once rewritten as version 2 lines
/// with typed artifacts on the completion and plain text on standard error, which must
/// end on the same label, log the same event lines, keep the text at info level and import
/// the same paths.
///
/// Phase 2.10 lane U32 adds the tests of the row rule (decision W2). They hand events straight to
/// the closure the bridge returns, then read the row once every event has been applied. A run's log
/// holds its start line and each progress message once, so the expectations of the label tests list
/// the progress messages of their captured runs.
@MainActor
final class OperationCenterCLIBridgeTests: XCTestCase {
    private var folder: URL!
    private var savedBundleReady: (([URL], OperationRouteContext?) -> Void)?
    private var bundleImports: BundleImportLog!

    /// The text the version 2 stand-in prints on standard error. The second line says
    /// "warning" and still must not make a run Completed with Warnings.
    private static let standardErrorText = [
        "Reading the input bundle.",
        "warning: this text on standard error is not a warning event",
    ]

    private enum Variant: CaseIterable {
        /// The captured version 1 lines and nothing on standard error.
        case version1
        /// The same events as version 2 lines, with artifacts on the completion and
        /// ``standardErrorText`` on standard error.
        case version2
    }

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "cli-bridge")
        OperationCenter.useTemporaryFailureReportsForTesting()
        let imports = BundleImportLog()
        bundleImports = imports
        savedBundleReady = OperationCenter.shared.onBundleReadyWithContext
        OperationCenter.shared.onBundleReadyWithContext = { urls, _ in imports.record(urls) }
    }

    override func tearDown() async throws {
        OperationCenter.shared.onBundleReadyWithContext = savedBundleReady
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    // MARK: - One test per label

    func testACompletedRunReadsCompletedAndImportsOnlyItsOutput() async throws {
        // The start line and the two progress messages of the captured run, each logged once.
        let expectedLog = ["info: Starting tree transform.", "info: Loading tree bundle.", "info: Writing transformed tree bundle."]
        for variant in Variant.allCases {
            bundleImports.reset()
            let cli = try standInCLI(playing: try transcript("tree-reroot", as: variant), variant: variant)
            let id = beginRow(title: "Reroot tree", type: .phylogeneticTreeTransform)
            defer { OperationCenter.shared.clearItem(id: id) }

            let result = try await CLITreeRunner(label: "tree transform", cliURLOverride: cli)
                .run(arguments: ["tree", "reroot"], operationID: id)

            let item = try await settledItem(id, logging: expectedLog, variant: variant)
            XCTAssertEqual(result.bundleURL.path, "/work/Rerooted.lungfishtree", "\(variant)")
            XCTAssertEqual(item.displayStateLabel, "Completed", "\(variant)")
            XCTAssertEqual(eventLines(of: item), expectedLog, "\(variant)")
            XCTAssertEqual(standardErrorLines(of: item), expectedStandardError(variant), "\(variant)")
            XCTAssertEqual(item.bundleURLs.map(\.path), ["/work/Rerooted.lungfishtree"], "\(variant)")
            XCTAssertEqual(
                bundleImports.paths, [["/work/Rerooted.lungfishtree"]],
                "\(variant): only the completion's outputs reach bundle import, never an artifact path"
            )
        }
    }

    func testARunThatLoggedAWarningReadsCompletedWithWarnings() async throws {
        let warning = "Export format phylip does not preserve MSA annotations; 2 annotation(s) remain in the source .lungfishmsa bundle."
        let expectedLog = [
            "info: Starting MSA export.",
            "info: Loading MSA bundle.",
            "warning: \(warning)",
            "info: Writing phylip alignment.",
            "info: Writing export provenance.",
        ]
        for variant in Variant.allCases {
            bundleImports.reset()
            let cli = try standInCLI(playing: try transcript("msa-export-with-warning", as: variant), variant: variant)
            let id = beginRow(title: "Export alignment", type: .multipleSequenceAlignmentAction)
            defer { OperationCenter.shared.clearItem(id: id) }

            let result = try await CLIMSAActionRunner(cliURLOverride: cli)
                .run(arguments: ["msa", "export"], operationID: id)

            let item = try await settledItem(id, logging: expectedLog, variant: variant)
            XCTAssertEqual(result.outputURL.path, "/work/annotated.phy", "\(variant)")
            XCTAssertEqual(item.displayStateLabel, "Completed with Warnings", "\(variant)")
            XCTAssertEqual(eventLines(of: item), expectedLog, "\(variant)")
            XCTAssertEqual(standardErrorLines(of: item), expectedStandardError(variant), "\(variant)")
            XCTAssertEqual(item.outputURLs.map(\.path), ["/work/annotated.phy"], "\(variant)")
            XCTAssertEqual(bundleImports.paths, [], "\(variant): a loose output file is not a bundle to import")
        }
    }

    func testAFailedRunReadsFailedAndLogsWhy() async throws {
        let expectedLog = [
            "info: Starting tree transform.",
            "info: Loading tree bundle.",
            "info: Writing transformed tree bundle.",
            "error: Failed: Tree node not found: NoSuchTip",
        ]
        for variant in Variant.allCases {
            bundleImports.reset()
            let cli = try standInCLI(playing: try transcript("tree-reroot-failed", as: variant), variant: variant, exitStatus: 1)
            let id = beginRow(title: "Reroot tree", type: .phylogeneticTreeTransform)
            defer { OperationCenter.shared.clearItem(id: id) }

            do {
                _ = try await CLITreeRunner(label: "tree transform", cliURLOverride: cli)
                    .run(arguments: ["tree", "reroot"], operationID: id)
                XCTFail("\(variant): a run that ends in a failed event must throw")
            } catch let error as CLITreeRunner.RunError {
                XCTAssertEqual(error, .underlying("Tree node not found: NoSuchTip"), "\(variant)")
            }

            let item = try await settledItem(id, logging: expectedLog, variant: variant)
            XCTAssertEqual(item.displayStateLabel, "Failed", "\(variant)")
            XCTAssertEqual(eventLines(of: item), expectedLog, "\(variant)")
            XCTAssertEqual(standardErrorLines(of: item), expectedStandardError(variant), "\(variant)")
            XCTAssertEqual(bundleImports.paths, [], "\(variant)")
        }
    }

    /// A CLI that exits nonzero without a `failed` event fails the row with its standard
    /// error. The line reaches the log once at info, and the failure entry stays last.
    func testANonzeroExitWithNoFailedEventReadsFailedWithItsStandardError() async throws {
        let errorLine = "Error: Tree node not found: NoSuchTip"
        let failure = "lungfish-cli exited with status 2: \(errorLine)"
        let lines = Array(try transcript("tree-reroot-failed", as: .version1).prefix(3))
        XCTAssertFalse(lines.contains { $0.contains(#""event":"failed""#) }, "the stand-in prints no failed event")
        let cli = try standInCLI(playing: lines, variant: .version1, standardError: [errorLine], exitStatus: 2)
        let id = beginRow(title: "Reroot tree", type: .phylogeneticTreeTransform)
        defer { OperationCenter.shared.clearItem(id: id) }

        do {
            _ = try await CLITreeRunner(label: "tree transform", cliURLOverride: cli)
                .run(arguments: ["tree", "reroot"], operationID: id)
            XCTFail("a nonzero exit must throw")
        } catch let error as CLITreeRunner.RunError {
            XCTAssertEqual(error, .underlying(failure))
        }

        await waitUntil(timeout: .seconds(30)) {
            guard let item = self.item(id), !item.state.isActive else { return false }
            return self.loggedLines(of: item).count == 5
        }
        let item = try XCTUnwrap(item(id))
        let logged = loggedLines(of: item)
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertEqual(item.errorMessage, failure)
        XCTAssertEqual(logged.last, "error: Failed: \(failure)", "the failure entry stays last")
        XCTAssertEqual(logged.filter { $0 == "info: \(errorLine)" }.count, 1, "the standard error line is logged once at info")
        XCTAssertEqual(Set(logged), [
            "info: Starting tree transform.",
            "info: Loading tree bundle.",
            "info: Writing transformed tree bundle.",
            "info: \(errorLine)",
            "error: Failed: \(failure)",
        ])
        XCTAssertEqual(bundleImports.paths, [])
    }

    /// The user cancels while the CLI is finishing. The CLI still prints its `complete`
    /// line, naming a bundle, but a row that is cancelling when its run ends reads
    /// Cancelled and imports nothing.
    func testARunCancelledBeforeItsCompletionReadsCancelledAndImportsNothing() async throws {
        // Every line before the held `complete` line: the start line and the three progress messages.
        let expectedLog = [
            "info: Starting MSA extraction.",
            "info: Loading MSA bundle.",
            "info: Writing derived .lungfishmsa bundle.",
            "info: Extraction complete.",
        ]
        for variant in Variant.allCases {
            bundleImports.reset()
            let ready = folder.appendingPathComponent("ready-\(variant)")
            let go = folder.appendingPathComponent("go-\(variant)")
            let lines = try transcript("msa-extract", as: variant)
            XCTAssertTrue(try XCTUnwrap(lines.last).contains(#""outputs":["\/work\/selected.lungfishmsa"]"#), "\(variant)")
            let cli = try standInCLI(playing: lines, variant: variant, holdingTheLastLineUntil: go, announcing: ready)
            let id = beginRow(title: "Extract alignment", type: .multipleSequenceAlignmentAction) {
                FileManager.default.createFile(atPath: go.path, contents: nil)
            }
            defer { OperationCenter.shared.clearItem(id: id) }

            let runner = CLIMSAActionRunner(cliURLOverride: cli)
            let run = Task { try await runner.run(arguments: ["msa", "extract"], operationID: id) }
            let started = await waitUntil(timeout: .seconds(30)) {
                FileManager.default.fileExists(atPath: ready.path)
                    && self.eventLines(of: self.item(id)) == expectedLog
            }
            XCTAssertTrue(started, "\(variant): the stand-in CLI never reached its last line")
            OperationCenter.shared.cancel(id: id)

            let outcome = await run.result
            guard case .failure(let error) = outcome, error is CancellationError else {
                return XCTFail("\(variant): a cancelled run must end in CancellationError, got \(outcome)")
            }
            let item = try await settledItem(id, logging: expectedLog, variant: variant)
            XCTAssertEqual(item.displayStateLabel, "Cancelled", "\(variant)")
            XCTAssertEqual(eventLines(of: item), expectedLog, "\(variant)")
            XCTAssertEqual(standardErrorLines(of: item), expectedStandardError(variant), "\(variant)")
            XCTAssertEqual(item.bundleURLs, [], "\(variant)")
            XCTAssertEqual(item.outputURLs, [], "\(variant)")
            XCTAssertEqual(bundleImports.paths, [], "\(variant): a cancelled run imports nothing, even when its CLI completed")
        }
    }

    // MARK: - The row rule (Phase 2.10 lane U32, decision W2)

    /// A lower fraction after a higher one leaves the bar where it is. The detail still follows each
    /// message, a fraction outside 0...1 is clamped as the row clamps it, and a start event that
    /// arrives late does not pull the bar back to 0.
    func testALowerFractionLeavesTheBarWhereItIs() async throws {
        let id = beginRow(title: "Hold the bar", type: .phylogeneticTreeTransform)
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = OperationCenterCLIBridge.onEvent(operationID: id)

        var bar: [Double] = []
        for fraction in [0.1, 0.6, 0.3, 0.6, 0.0, 0.9, -1.0, 0.2, 5.0] {
            handle(.progress(fraction: fraction, message: "At \(fraction)"))
            await eventsApplied()
            bar.append(try XCTUnwrap(item(id)).progress)
        }
        XCTAssertEqual(bar, [0.1, 0.6, 0.6, 0.6, 0.6, 0.9, 0.9, 0.9, 1.0])
        XCTAssertEqual(item(id)?.detail, "At 5.0", "the detail follows each message while the bar holds")

        handle(.start(message: "Starting again"))
        await eventsApplied()
        XCTAssertEqual(item(id)?.progress, 1.0, "a start event never moves the bar back")
        XCTAssertEqual(item(id)?.detail, "Starting again")
        XCTAssertNil(item(id)?.progressEvidence, "the bridge holds the row's progress value and records no evidence")
        XCTAssertNil(item(id)?.displayProgressFraction, "a bridged row draws no bar (U30 W4 ruling)")
        XCTAssertEqual(item(id)?.displayProgressLabel, item(id)?.displayStateLabel, "the label names the state with no percentage")
    }

    /// Producers on several threads never lower the bar. Each event reads the bar and writes it in one
    /// hop to the main actor, so no event holds a maximum that another has outdated. The test reads the
    /// bar after every change the row publishes.
    func testEventsFromSeveralThreadsNeverLowerTheBar() async throws {
        let id = beginRow(title: "Hold the bar", type: .phylogeneticTreeTransform)
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = OperationCenterCLIBridge.onEvent(operationID: id)
        let seen = BarSamples()
        let subscription = OperationCenter.shared.changes.sink { change in
            guard case .updated(let changed, _) = change, changed == id else { return }
            MainActor.assumeIsolated { seen.record(OperationCenter.shared.items.first { $0.id == id }?.progress) }
        }
        defer { subscription.cancel() }

        let fractions = (0..<400).map { Double(($0 * 37) % 101) / 100 }
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                DispatchQueue.concurrentPerform(iterations: fractions.count) { index in
                    handle(.progress(fraction: fractions[index], message: "Step \(index)"))
                }
                finished.resume()
            }
        }
        await eventsApplied()

        XCTAssertGreaterThanOrEqual(seen.samples.count, fractions.count, "the row published a change for every event")
        XCTAssertEqual(seen.samples, seen.samples.sorted(), "the bar never moved back")
        XCTAssertEqual(item(id)?.progress, fractions.max())
    }

    /// A progress message is logged once when it changes. A repeat right after it adds nothing, a
    /// repeat after another entry is logged again, a warning with the same words does not hide it, and
    /// an empty message changes the bar only.
    func testAProgressMessageIsLoggedOnceWhenItChanges() async throws {
        let id = beginRow(title: "Log once", type: .phylogeneticTreeTransform)
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = OperationCenterCLIBridge.onEvent(operationID: id)

        let events: [CLIEvent] = [
            .progress(fraction: 0.1, message: "Running align (a)"),
            .progress(fraction: 0.2, message: "Running align (a)"),
            .progress(fraction: 0.3, message: "Running align (a)"),
            .progress(fraction: 0.4, message: "Running align (b)"),
            .progress(fraction: 0.5, message: "Running align (b)"),
            .log(level: .info, message: "Note from the command"),
            .progress(fraction: 0.6, message: "Running align (b)"),
            .progress(fraction: 0.7, message: ""),
            .log(level: .warning, message: "Careful"),
            .progress(fraction: 0.8, message: "Careful"),
        ]
        for event in events.prefix(8) { handle(event) }
        await eventsApplied()
        XCTAssertEqual(item(id)?.progress, 0.7, "an empty message still moves the bar")
        XCTAssertEqual(item(id)?.detail, "Running align (b)", "an empty message leaves the detail alone")

        for event in events.dropFirst(8) { handle(event) }
        await eventsApplied()
        XCTAssertEqual(loggedLines(of: item(id)), [
            "info: Running align (a)",
            "info: Running align (b)",
            "info: Note from the command",
            "info: Running align (b)",
            "warning: Careful",
            "info: Careful",
        ])
    }

    /// A route that sends a step as a progress event and again as a log event with the same words, as
    /// the classifier route does, gets one entry for the pair. A pair that repeats is logged once for
    /// each time it arrives, as the row logged it before the bridge logged progress.
    func testALogLineRightAfterItsProgressEventIsNotLoggedTwice() async throws {
        let id = beginRow(title: "Pairs", type: .classification)
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = OperationCenterCLIBridge.onEvent(operationID: id)

        for _ in 0..<3 {
            handle(.progress(fraction: 0.2, message: "Quality filtering reads..."))
            handle(.log(level: .info, message: "Quality filtering reads..."))
        }
        handle(.progress(fraction: 0.4, message: "Assembling viral contigs..."))
        handle(.log(level: .info, message: "Assembling viral contigs..."))
        handle(.log(level: .info, message: "Assembling viral contigs..."))
        await eventsApplied()

        XCTAssertEqual(loggedLines(of: item(id)), [
            "info: Quality filtering reads...",
            "info: Quality filtering reads...",
            "info: Quality filtering reads...",
            "info: Assembling viral contigs...",
            "info: Assembling viral contigs...",
        ])
    }

    /// The classifier route sends its database step as a progress event with today's detail and
    /// a log event with today's database line, which has other words, so the log holds both,
    /// the detail first (Phase 2.10 U32 review fix 1).
    func testTheClassifierDatabaseStepLogsItsDetailBeforeTodaysDatabaseLine() async throws {
        let id = beginRow(title: "EsViritu sarscov2", type: .classification)
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = OperationCenterCLIBridge.onEvent(operationID: id)
        var rowEvents = CLIClassifierRowEvents(tool: .esViritu, sampleIDs: ["sarscov2"])
        let events: [CLIEvent] = [
            .progress(fraction: 1, message: "Writing the EsViritu summary\u{2026}"),
            .progress(fraction: 1, message: "Building EsViritu database\u{2026}"),
        ]
        for event in events { rowEvents.effects(of: event).bridged.forEach(handle) }
        await eventsApplied()
        XCTAssertEqual(loggedLines(of: item(id)), [
            "info: Writing the EsViritu summary\u{2026}",
            "info: Building EsViritu database\u{2026}",
            "info: Building esviritu.sqlite from single-sample result",
        ])
    }

    /// Events from one producer land in the order they arrive. The log and the detail read the same
    /// sequence the producer sent.
    func testEventsKeepTheirArrivalOrder() async throws {
        let id = beginRow(title: "Order", type: .phylogeneticTreeTransform)
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = OperationCenterCLIBridge.onEvent(operationID: id)

        var events: [CLIEvent] = []
        var expectedLog: [String] = []
        for index in 0..<300 {
            if index % 3 == 2 {
                events.append(.log(level: .info, message: "note \(index)"))
                expectedLog.append("info: note \(index)")
            } else {
                events.append(.progress(fraction: Double(index) / 300, message: "step \(index)"))
                expectedLog.append("info: step \(index)")
            }
        }
        let sent = events
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                sent.forEach(handle)
                finished.resume()
            }
        }
        await eventsApplied()

        XCTAssertEqual(loggedLines(of: item(id)), expectedLog)
        XCTAssertEqual(item(id)?.detail, "step 298", "the detail is the last progress message")
    }

    /// The overlay closure gets a progress message only while the row runs. Once a cancel has moved the
    /// row to Cancelling, a late message leaves the bar, the detail and the overlay as they are, and the
    /// log keeps it. An empty message, a start event and a log event never reach the overlay.
    func testTheOverlayGetsAProgressMessageOnlyWhileTheRowRuns() async throws {
        let id = beginRow(title: "Overlay", type: .phylogeneticTreeTransform) {}
        defer { OperationCenter.shared.clearItem(id: id) }
        let overlay = OverlayLines()
        let handle = OperationCenterCLIBridge.onEvent(operationID: id) { line in overlay.lines.append(line) }

        handle(.start(message: "Starting"))
        handle(.progress(fraction: 0.2, message: "Reading"))
        handle(.progress(fraction: 0.3, message: ""))
        handle(.log(level: .info, message: "Not a progress line"))
        handle(.progress(fraction: 0.4, message: "Writing"))
        await eventsApplied()
        XCTAssertEqual(overlay.lines, ["Reading", "Writing"], "in the order the messages arrived")

        OperationCenter.shared.cancel(id: id)
        handle(.progress(fraction: 0.6, message: "Late line"))
        await eventsApplied()
        let row = try XCTUnwrap(item(id))
        XCTAssertEqual(row.state, .cancelling)
        XCTAssertEqual(row.detail, "Cancelling...", "the row refuses the late line")
        XCTAssertEqual(row.progress, 0.4, "and leaves the bar")
        XCTAssertEqual(overlay.lines, ["Reading", "Writing"], "the overlay refuses it too")
        XCTAssertEqual(loggedLines(of: row).last, "info: Late line", "the log keeps it")
        OperationCenter.shared.acknowledgeCancellation(id: id)
    }

    /// `import fastq --recipe vsp2 --no-remove-duplicates` prints what the name resolved to and each switch's value
    /// as info lines (`ImportFastqRun`, UX review points 3 and 11). A row that plays those lines and then completes
    /// reads Completed and holds no entry above info level, although a line such as "Remove duplicate reads: off
    /// (option)" reads like a caution. Only a warning event or `completeWithWarning` makes a row Completed with
    /// Warnings (S16).
    func testTheResolutionLinesOfAVSP2ImportWithDuplicatesKeptLeaveTheRowCompleted() async throws {
        let recipe = try XCTUnwrap(RecipeResolver.resolve(
            "vsp2", in: RecipeRegistryV2.builtinRecipes(), switchOptions: ["removeDuplicates": false]
        ))
        let lines = recipe.resolutionLines
        XCTAssertEqual(lines.count, 3, "the preset line and one line for each of the two switches")
        XCTAssertTrue(lines.contains { $0.hasSuffix("(option)") }, "the switch the option set says so")

        let id = beginRow(title: "Import FASTQ", type: .ingestion)
        defer { OperationCenter.shared.clearItem(id: id) }
        let handle = OperationCenterCLIBridge.onEvent(operationID: id)
        handle(.start(message: "Importing FASTQ"))
        for line in lines {
            handle(.log(level: .info, message: line))
        }
        handle(.progress(fraction: 0.9, message: "Writing the bundle"))
        await eventsApplied()
        _ = OperationCenter.shared.complete(id: id, detail: "Imported 1 sample", bundleURLs: [])

        let row = try XCTUnwrap(item(id))
        XCTAssertEqual(row.displayStateLabel, "Completed")
        let logged = loggedLines(of: row)
        for line in lines {
            XCTAssertTrue(logged.contains("info: \(line)"), "\(line) is logged at info level")
        }
        XCTAssertFalse(
            logged.contains { $0.hasPrefix("warning: ") || $0.hasPrefix("error: ") },
            "no entry above info level: \(logged)"
        )
    }

    /// Returns once the bridge has applied every event handed to it so far. The bridge hops each event
    /// to the main queue in arrival order, so a block queued afterwards runs after all of them.
    private func eventsApplied() async {
        await withCheckedContinuation { (applied: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { applied.resume() }
        }
    }

    // MARK: - Transcripts and the stand-in CLI

    /// The lines of a captured version 1 run, or the same events written as version 2
    /// lines. The version 2 completion lists an artifact for each output and one for a
    /// bundle that is not an output, which must never be imported.
    private func transcript(_ name: String, as variant: Variant) throws -> [String] {
        XCTAssertTrue(CLIEventCompatCorpus.capturedRuns.contains(name), "\(name) is not a captured run")
        let url = CLIEventCompatCorpus.v1Folder.appendingPathComponent("\(name).ndjson")
        let version1 = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard variant == .version2 else { return version1 }

        let decoder = CLIEventLineDecoder()
        var version2: [String] = []
        let emitter = CLIEventEmitter(enabled: true) { version2.append($0) }
        for line in version1 {
            let event = try XCTUnwrap(try decoder.decode(line: line), "\(name): \(line)")
            var artifacts: [CLIEventArtifact] = []
            if case let .complete(outputs, _) = event {
                artifacts = outputs.map { CLIEventArtifact(kind: "kind-from-a-later-registry", path: $0, role: "primary") }
                artifacts.append(CLIEventArtifact(kind: "phylogenetic-tree", path: "/work/not-an-output.lungfishtree", role: "unrelated"))
            }
            emitter.emit(event, artifacts: artifacts)
        }
        XCTAssertTrue(version2.allSatisfy { $0.contains(#""schemaVersion":2"#) }, name)
        return version2
    }

    /// A shell script in place of `lungfish-cli` that prints `lines` on standard output,
    /// after `standardError` on standard error, and exits with `exitStatus`. Without
    /// `standardError` it writes ``standardErrorText`` for version 2 and nothing for
    /// version 1. With `go` set it prints every line but the last, touches `ready`, and
    /// waits for `go` to exist before it prints the last line.
    private func standInCLI(
        playing lines: [String],
        variant: Variant,
        standardError: [String]? = nil,
        exitStatus: Int32 = 0,
        holdingTheLastLineUntil go: URL? = nil,
        announcing ready: URL? = nil
    ) throws -> URL {
        let tag = UUID().uuidString
        let head = folder.appendingPathComponent("head-\(tag).ndjson")
        let last = folder.appendingPathComponent("last-\(tag).ndjson")
        let text = folder.appendingPathComponent("stderr-\(tag).txt")
        var script = "#!/bin/sh\n"
        let errorLines = standardError ?? (variant == .version2 ? Self.standardErrorText : [])
        if !errorLines.isEmpty {
            try (errorLines.joined(separator: "\n") + "\n").write(to: text, atomically: true, encoding: .utf8)
            script += "/bin/cat '\(text.path)' >&2\n"
        }
        if let go, let ready {
            try (lines.dropLast().joined(separator: "\n") + "\n").write(to: head, atomically: true, encoding: .utf8)
            try ((lines.last ?? "") + "\n").write(to: last, atomically: true, encoding: .utf8)
            script += "/bin/cat '\(head.path)'\n"
            script += "/usr/bin/touch '\(ready.path)'\n"
            script += "while [ ! -f '\(go.path)' ]; do /bin/sleep 0.05; done\n"
            script += "/bin/cat '\(last.path)'\n"
        } else {
            try (lines.joined(separator: "\n") + "\n").write(to: head, atomically: true, encoding: .utf8)
            script += "/bin/cat '\(head.path)'\n"
        }
        script += "exit \(exitStatus)\n"
        let url = folder.appendingPathComponent("lungfish-cli-\(tag)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Rows and logs

    private func beginRow(
        title: String,
        type: OperationType,
        onCancel: (@Sendable () -> Void)? = nil
    ) -> UUID {
        OperationCenter.shared.begin(
            title: title,
            detail: "Launching...",
            operationType: type,
            cliCommand: nil,
            onCancel: onCancel
        ).rowID
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// The row once it has ended and its log holds the expected lines. The bridge hops
    /// each line to the main queue, so one can land after the runner returns.
    private func settledItem(_ id: UUID, logging expected: [String], variant: Variant) async throws -> OperationCenter.Item {
        await waitUntil(timeout: .seconds(30)) {
            guard let item = self.item(id), !item.state.isActive else { return false }
            return self.eventLines(of: item) == expected
                && self.standardErrorLines(of: item) == self.expectedStandardError(variant)
        }
        return try XCTUnwrap(item(id))
    }

    private func expectedStandardError(_ variant: Variant) -> [String] {
        variant == .version2 ? Self.standardErrorText.map { "info: \($0)" } : []
    }

    /// The log as the expanded row shows it, one `level: message` string per entry.
    private func loggedLines(of item: OperationCenter.Item?) -> [String] {
        (item?.logEntries ?? [])
            .filter { !$0.isElisionMarker }
            .map { "\($0.level.rawValue): \($0.message)" }
    }

    /// The logged lines that came from events. Standard error is read beside standard
    /// output, so its lines may land anywhere among them.
    private func eventLines(of item: OperationCenter.Item?) -> [String] {
        let text = Set(Self.standardErrorText)
        return (item?.logEntries ?? [])
            .filter { !$0.isElisionMarker && !text.contains($0.message) }
            .map { "\($0.level.rawValue): \($0.message)" }
    }

    /// The logged lines that came from standard error, in their own order.
    private func standardErrorLines(of item: OperationCenter.Item?) -> [String] {
        let text = Set(Self.standardErrorText)
        return loggedLines(of: item).filter { line in text.contains { line.hasSuffix(": \($0)") } }
    }
}

/// What reached `onBundleReadyWithContext`, one array of paths per call.
@MainActor
private final class BundleImportLog {
    private(set) var paths: [[String]] = []

    func record(_ urls: [URL]) {
        paths.append(urls.map(\.path))
    }

    func reset() {
        paths = []
    }
}

/// The lines a case's overlay closure showed.
@MainActor
private final class OverlayLines {
    var lines: [String] = []
}

/// The bar of a row as read after each change the row published.
@MainActor
private final class BarSamples {
    private(set) var samples: [Double] = []

    func record(_ progress: Double?) {
        if let progress { samples.append(progress) }
    }
}
