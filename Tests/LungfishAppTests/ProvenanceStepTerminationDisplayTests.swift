// ProvenanceStepTerminationDisplayTests.swift - What the Provenance tab shows of a step's observation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

/// Phase 2.10 lane U37. A classifier step now carries an `observation`, what ToolProcess saw of its launch
/// (lane S36). The Provenance tab shows it as P2 of Phase 2.8 settles it. A line shows only when it adds
/// something, Output reads Not recorded only when a step did not exit 0, and the Environment is one line in the
/// step's disclosure.
///
/// The cases load the hand-written records `Tests/Fixtures/provenance-display/Analyses/observed-*` through the real
/// lookup and compare what the tab shows with `Tests/Fixtures/provenance-display/expected/observed-*.json`. The
/// first commit of the lane pinned these files at the base, where the tab shows nothing of an observation. The
/// commit that adds the lines changes exactly the `observation` objects of the expected files, and no other
/// expected file of the folder.
@MainActor
final class ProvenanceStepTerminationDisplayTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try await super.tearDown()
    }

    // MARK: - The observed records

    /// A kraken2 step that exited 0 with its output read whole, in an environment its adapter started empty.
    func testACleanExitShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-clean-exit")

        XCTAssertEqual(try observation(of: model).termination, .exited(code: 0))
        XCTAssertEqual(try observation(of: model).outputComplete, true)
    }

    /// A Bracken step that exited 2 and never said whether its output was read whole.
    func testANonzeroExitShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-nonzero-exit")

        XCTAssertEqual(try observation(of: model).termination, .exited(code: 2))
        XCTAssertNil(try observation(of: model).outputComplete)
    }

    /// A kraken2 step an outside signal killed, which cut its output short.
    func testASignalShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-signal")

        XCTAssertEqual(try observation(of: model).termination, .signaled(signal: 9))
        XCTAssertEqual(try observation(of: model).outputComplete, false)
    }

    /// A Bracken step ToolProcess stopped because the run was cancelled.
    func testACancelShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-cancelled")

        XCTAssertEqual(try observation(of: model).termination, .signaled(signal: 15))
        XCTAssertEqual(try observation(of: model).stop, .cancelled)
        XCTAssertEqual(model.resolvedEnvelope?.status, .cancelled)
    }

    /// A Bracken step whose process could not start.
    func testALaunchFailureShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-launch-failure")

        XCTAssertEqual(
            try observation(of: model).termination,
            .launchFailed(reason: "posix_spawn failed, no such file or directory")
        )
    }

    /// An EsViritu step whose adapter extended the inherited environment, set one variable and removed one.
    func testAnEnvironmentChangeShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-environment-change")

        let environment = try XCTUnwrap(try observation(of: model).environment)
        XCTAssertEqual(environment.base, .inherited)
        XCTAssertEqual(environment.changed, ["ESVIRITU_DB", "PATH"])
        XCTAssertEqual(environment.unset, ["PYTHONHOME"])
    }

    /// A step whose adapter changed nothing in the inherited environment. The observation says so, and the
    /// display is the display of a record with no observation.
    func testAnUnchangedEnvironmentShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-environment-none")

        let environment = try XCTUnwrap(try observation(of: model).environment)
        XCTAssertEqual(environment.base, .inherited)
        XCTAssertTrue(environment.changed.isEmpty && environment.unset.isEmpty && environment.pathPrefix.isEmpty)
    }

    /// The same record as the unchanged environment, written before a step could carry an observation.
    func testAnOlderRecordWithNoObservationShowsItsExpectedDisplay() async throws {
        let model = try await assertDisplay(folder: "observed-older-record")

        XCTAssertNil(model.resolvedEnvelope?.steps.first?.observation)
    }

    // MARK: - The expected files

    /// Every expected display file of the folder is the exact text the snapshot writes for it, so a snapshot
    /// field added for the observation changes no file of a record that has none (QA 1).
    func testEveryExpectedFileIsTheCanonicalTextOfItsSnapshot() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: ProvenanceDisplayFixtures.expectedDirectory.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 16, "The folder holds the eight legacy files and the eight observed ones: \(names)")
        for name in names {
            let url = ProvenanceDisplayFixtures.expectedDirectory.appendingPathComponent(name)
            let onDisk = try String(contentsOf: url, encoding: .utf8)
            let rewritten = try ProvenanceDisplaySnapshot.decode(expected: Data(contentsOf: url)).canonicalJSON() + "\n"
            XCTAssertEqual(rewritten, onDisk, "\(name) is not the canonical text of its snapshot.")
        }
    }

    // MARK: - The Copy text

    /// The Copy text lists each line where the disclosure shows it, which is the order VoiceOver reads the rows.
    func testTheCopyTextListsEachLineWhereTheDisclosureShowsIt() async throws {
        let model = try await assertDisplay(folder: "observed-signal")

        XCTAssertEqual(
            Self.stepLabels(of: model.copyableText),
            ["1. kraken2 v2.1.3", "Command", "Environment", "Inputs", "Outputs", "Exit Status", "Termination",
             "Wall Time", "Output", "stderr"]
        )
        let copy = model.copyableText
        XCTAssertTrue(copy.contains("\nEnvironment: Empty, with HOME, MAMBA_ROOT_PREFIX, PATH and TMPDIR set\n"), copy)
        XCTAssertTrue(copy.contains("\nExit Status: 9\nTermination: Ended by signal 9 (SIGKILL)\nWall Time: 92.40 s\nOutput: Incomplete\n"), copy)
    }

    /// A record with no observation, or one that adds no line, copies as it always did.
    func testTheCopyTextOfAStepThatAddsNoLineIsUnchanged() async throws {
        let usual = ["Command", "Inputs", "Outputs", "Exit Status", "Wall Time", "stderr"]
        for (folder, header) in [
            ("observed-older-record", "1. kraken2 v2.1.3"),
            ("observed-environment-none", "1. kraken2 v2.1.3"),
            ("fastq-trim-failed", "1. fastp v0.24.0"),
        ] {
            let (model, _) = try await loadedModel(folder: folder)
            XCTAssertEqual(Self.stepLabels(of: model.copyableText), [header] + usual, folder)
        }
    }

    // MARK: - The rules (plan decision P2 of Phase 2.8)

    private typealias Environment = ProvenanceStepObservation.Environment

    private func observation(
        _ termination: ProvenanceStepObservation.Termination,
        stop: ProvenanceStepObservation.Stop? = nil,
        outputComplete: Bool? = true,
        environment: Environment? = nil
    ) -> ProvenanceStepObservation {
        ProvenanceStepObservation(
            termination: termination, stop: stop, outputComplete: outputComplete, environment: environment,
            stage: ProvenanceStepObservation.Stage(index: 0, count: 1)
        )
    }

    private func environment(
        _ base: Environment.Base, changed: [String] = [], unset: [String] = [], pathReplaced: Bool = false
    ) -> Environment {
        Environment(
            base: base, changed: changed, values: ["MAMBA_ROOT_PREFIX": "/Users/someone/.lungfish/conda"],
            unset: unset, pathPrefix: ["/Users/someone/.lungfish/conda/bin", "/usr/bin"], pathReplaced: pathReplaced
        )
    }

    /// Exit Status gives the code of a step that exited, so Termination says nothing for it. Every other ending
    /// and every stop adds the line. A time limit is the limit the step reached, and a launch failure's reason is
    /// shown as the host wrote it.
    func testTheTerminationLineShowsOnlyWhatExitStatusDoesNotSay() {
        let cases: [(String, ProvenanceStepObservation, String?)] = [
            ("exit 0", observation(.exited(code: 0)), nil),
            ("exit 2", observation(.exited(code: 2)), nil),
            ("kill", observation(.signaled(signal: 9)), "Ended by signal 9 (SIGKILL)"),
            ("segfault", observation(.signaled(signal: 11)), "Ended by signal 11 (SIGSEGV)"),
            ("a signal with no name here", observation(.signaled(signal: 77)), "Ended by signal 77"),
            ("status lost", observation(.statusLost), "Exit status taken by another process"),
            ("launch failure", observation(.launchFailed(reason: "no such file")), "Could not start (no such file)"),
            ("launch failure with no reason", observation(.launchFailed(reason: " ")), "Could not start"),
            ("not launched", observation(.notLaunched), "Did not start"),
            ("cancel, exit 0", observation(.exited(code: 0), stop: .cancelled), "Cancelled"),
            ("cancel, exit 143", observation(.exited(code: 143), stop: .cancelled), "Cancelled"),
            ("cancel, signal", observation(.signaled(signal: 15), stop: .cancelled), "Cancelled (signal 15, SIGTERM)"),
            ("wall clock limit", observation(.signaled(signal: 15), stop: .timedOut(limit: .wallClock, seconds: 3600)),
             "Timed out at its limit of 1h 0m (signal 15, SIGTERM)"),
            ("idle limit", observation(.signaled(signal: 9), stop: .timedOut(limit: .idle, seconds: 90)),
             "Timed out at its limit of 1m 30s without output (signal 9, SIGKILL)"),
            ("another stage failed", observation(.signaled(signal: 13), stop: .pipelineStageFailed(stage: 0)),
             "Stopped because another stage of its pipeline failed (signal 13, SIGPIPE)"),
            ("stage never started", observation(.notLaunched, stop: .pipelineStageFailed(stage: 0)),
             "Stopped because another stage of its pipeline failed (did not start)"),
        ]
        for (name, observation, expected) in cases {
            XCTAssertEqual(ProvenanceStepTerminationDisplay(observation)?.termination, expected, name)
        }
    }

    /// Output reads Incomplete when an output of the step was cut short, and Not recorded when a step that ran and
    /// did not exit 0 recorded nothing about its output. Output read whole adds nothing, and neither does a step that
    /// never started, since Termination says so.
    func testTheOutputLineReadsNotRecordedOnlyWhenTheStepDidNotExitZero() {
        let cases: [(String, ProvenanceStepObservation.Termination, Bool?, String?)] = [
            ("exit 0, whole", .exited(code: 0), true, nil),
            ("exit 0, not recorded", .exited(code: 0), nil, nil),
            ("exit 0, cut short", .exited(code: 0), false, "Incomplete"),
            ("exit 2, whole", .exited(code: 2), true, nil),
            ("exit 2, not recorded", .exited(code: 2), nil, "Not recorded"),
            ("exit 2, cut short", .exited(code: 2), false, "Incomplete"),
            ("signal, not recorded", .signaled(signal: 9), nil, "Not recorded"),
            ("never launched", .notLaunched, nil, nil),
            ("launch failure", .launchFailed(reason: "no such file"), nil, nil),
            ("status lost, not recorded", .statusLost, nil, "Not recorded"),
        ]
        for (name, termination, complete, expected) in cases {
            let display = ProvenanceStepTerminationDisplay(observation(termination, outputComplete: complete))
            XCTAssertEqual(display?.output, expected, name)
        }
    }

    func testTheEnvironmentIsOneLineThatNamesVariablesAndAddsNothingWhenNothingChanged() {
        let cases: [(String, Environment, String?)] = [
            ("started empty, nothing set", environment(.hermetic), "Empty"),
            ("started empty", environment(.hermetic, changed: ["HOME", "PATH"]), "Empty, with HOME and PATH set"),
            ("inherited, unchanged", environment(.inherited), nil),
            ("inherited, one set", environment(.inherited, changed: ["FOO"]), "Inherited from Lungfish, with FOO set"),
            ("inherited, three set", environment(.inherited, changed: ["A", "B", "C"]), "Inherited from Lungfish, with A, B and C set"),
            ("inherited, one removed", environment(.inherited, unset: ["X"]), "Inherited from Lungfish, with X removed"),
            ("inherited, set and removed", environment(.inherited, changed: ["FOO", "PATH"], unset: ["X", "Y"]),
             "Inherited from Lungfish, with FOO and PATH set and X and Y removed"),
        ]
        for (name, environment, expected) in cases {
            let display = ProvenanceStepTerminationDisplay(observation(.exited(code: 0), environment: environment))
            XCTAssertEqual(display?.environment, expected, name)
            XCTAssertFalse(display?.environment?.contains("/") ?? false, "\(name) shows a value or a PATH entry.")
        }
    }

    /// Phase 2.10 S8, the review of S36. A PATH the adapter set that does not end with the inherited PATH is worded
    /// that way. It is never said to have dropped or removed the inherited PATH, because a PATH that appends after
    /// the inherited entries also counts. A hermetic base inherits no PATH, so a flag written on one says nothing.
    func testAReplacedPathIsWordedAsAPathThatDoesNotEndWithTheInheritedOne() {
        let replaced = environment(.inherited, changed: ["ESVIRITU_DB", "PATH"], unset: ["PYTHONHOME"], pathReplaced: true)
        let line = ProvenanceStepTerminationDisplay(observation(.exited(code: 0), environment: replaced))?.environment
        XCTAssertEqual(
            line,
            "Inherited from Lungfish, with ESVIRITU_DB set, PATH set to a value that does not end with the inherited PATH and PYTHONHOME removed"
        )
        XCTAssertFalse(line?.localizedCaseInsensitiveContains("dropped") ?? true)
        XCTAssertFalse(line?.localizedCaseInsensitiveContains("removed the inherited") ?? true)

        let extended = environment(.inherited, changed: ["ESVIRITU_DB", "PATH"])
        XCTAssertEqual(
            ProvenanceStepTerminationDisplay(observation(.exited(code: 0), environment: extended))?.environment,
            "Inherited from Lungfish, with ESVIRITU_DB and PATH set"
        )
        let onlyPath = environment(.inherited, changed: ["PATH"], pathReplaced: true)
        XCTAssertEqual(
            ProvenanceStepTerminationDisplay(observation(.exited(code: 0), environment: onlyPath))?.environment,
            "Inherited from Lungfish, with PATH set to a value that does not end with the inherited PATH"
        )
        let handWritten = environment(.hermetic, changed: ["PATH"], pathReplaced: true)
        XCTAssertEqual(
            ProvenanceStepTerminationDisplay(observation(.exited(code: 0), environment: handWritten))?.environment,
            "Empty, with PATH set"
        )
    }

    /// `TMPDIR` is in `changed` only when the process that launched the step had it, so no rule may read it. The
    /// line lists the names the record holds, with or without that one.
    func testNoRuleReadsTheTemporaryFolderName() {
        for changed in [["HOME", "PATH"], ["HOME", "PATH", "TMPDIR"], ["TMPDIR"]] {
            let display = ProvenanceStepTerminationDisplay(
                observation(.exited(code: 0), environment: environment(.hermetic, changed: changed))
            )
            XCTAssertNotNil(display?.environment, "\(changed)")
        }
    }

    /// An observation that adds no line has no display, so the disclosure and the Copy text stay as they were. The
    /// Lineage search reads the lines that show.
    func testAnObservationThatAddsNoLineHasNoDisplay() {
        XCTAssertNil(ProvenanceStepTerminationDisplay(nil))
        XCTAssertNil(ProvenanceStepTerminationDisplay(observation(.exited(code: 0))))
        let unchanged = environment(.inherited)
        XCTAssertNil(ProvenanceStepTerminationDisplay(observation(.exited(code: 0), environment: unchanged)))

        let cancelled = ProvenanceStepTerminationDisplay(observation(.signaled(signal: 15), stop: .cancelled))
        XCTAssertEqual(cancelled?.searchText, "Cancelled (signal 15, SIGTERM)")
    }

    // MARK: - VoiceOver and the project

    /// VoiceOver reads the rows of a step in the order the disclosure draws them, which is the order of the Copy
    /// text. Environment follows the Command, Termination follows Exit Status and Output follows Wall Time. The case
    /// hosts the real section, presses the run and the step open, and lists the accessibility identifiers of the
    /// step's rows in tree order. Opening the rows writes nothing into the project (UX 6).
    func testVoiceOverReadsTheStepRowsInTheOrderOfTheCopyText() async throws {
        var before = ""
        let (model, project) = try await loadedModel(folder: "observed-signal") { before = try Self.digest(of: $0) }
        let host = host(ProvenanceSection(viewModel: model))
        try openFirstStep(in: host)
        spin { AccessibilityTreeProbe.element(in: host, identifier: "provenance-step-output") != nil }

        let rows = AccessibilityTreeProbe.all(in: host).compactMap { AccessibilityTreeProbe.identifier($0) }.filter(Self.stepRowIdentifiers.contains)
        var ordered: [String] = []
        for identifier in rows where ordered.last != identifier { ordered.append(identifier) }
        let start = try XCTUnwrap(ordered.firstIndex(of: "provenance-step-command"), AccessibilityTreeProbe.dump(host))
        XCTAssertEqual(
            Array(ordered[start...].prefix(8)),
            ["provenance-step-command", "provenance-step-environment", "provenance-path-list-value",
             "provenance-summary-value", "provenance-step-termination", "provenance-summary-value",
             "provenance-step-output", "provenance-summary-value"],
            "The order is Command, Environment, the Inputs and Outputs lists, Exit Status, Termination, Wall Time, Output, stderr."
        )
        let values = ["provenance-step-environment": "Empty, with HOME, MAMBA_ROOT_PREFIX, PATH and TMPDIR set",
                      "provenance-step-termination": "Ended by signal 9 (SIGKILL)",
                      "provenance-step-output": "Incomplete"]
        for (identifier, text) in values {
            let element = try XCTUnwrap(AccessibilityTreeProbe.element(in: host, identifier: identifier), identifier)
            XCTAssertEqual(AccessibilityTreeProbe.value(element), text, identifier)
        }
        XCTAssertEqual(try Self.digest(of: project), before, "Opening the rows wrote into the project.")
    }

    /// The step of a record with no observation draws none of the new rows.
    func testTheStepOfAnOlderRecordDrawsNoneOfTheNewRows() async throws {
        let (model, _) = try await loadedModel(folder: "observed-older-record")
        let host = host(ProvenanceSection(viewModel: model))
        try openFirstStep(in: host)

        let identifiers = Set(AccessibilityTreeProbe.all(in: host).compactMap { AccessibilityTreeProbe.identifier($0) })
        XCTAssertTrue(identifiers.contains("provenance-step-command"), "The step is open.")
        XCTAssertTrue(identifiers.isDisjoint(with: ["provenance-step-environment", "provenance-step-termination", "provenance-step-output"]))
    }

    /// Displaying writes nothing (UX 6). The project, record included, hashes the same before the lookup and after
    /// the lookup built the rows and the Copy text.
    func testDisplayingAnObservedRecordWritesNothing() async throws {
        for folder in Self.observedFolders {
            var before = ""
            let (model, project) = try await loadedModel(folder: folder) { before = try Self.digest(of: $0) }
            XCTAssertFalse(model.copyableText.isEmpty, folder)
            XCTAssertEqual(try Self.digest(of: project), before, "Loading \(folder) wrote into the project.")
        }
    }

    // MARK: - Real records

    /// The kraken2 and EsViritu records the S36 goldens hold are the shapes the producers write. Only the step the
    /// producer observed gains a line, and that line is the Environment of a clean exit. The goldens mask their
    /// dates, ids, durations and sizes, so the case gives them values and reads the rest as committed.
    func testTheRecordsOfTheClassifierGoldensShowOneEnvironmentLineOnTheObservedStep() async throws {
        let cases = [
            ("kraken2", "Empty, with HOME, MAMBA_ROOT_PREFIX, PATH and TMPDIR set"),
            ("esviritu", "Empty, with ESVIRITU_DB, HOME, MAMBA_ROOT_PREFIX, PATH and TMPDIR set"),
        ]
        for (golden, environment) in cases {
            let (model, _) = try await loadedModel(folder: "\(golden)-golden", record: Self.unmaskedGolden(golden))
            let steps = model.lineageRuns.last?.steps ?? []
            XCTAssertGreaterThan(steps.count, 1, "The golden \(golden) holds LGE's own steps beside the tool's.")
            let observed = steps.filter { $0.observation != nil }
            XCTAssertEqual(observed.count, 1, "\(golden): \(steps.map(\.toolName))")
            XCTAssertEqual(observed.first?.observation?.environment, environment, golden)
            XCTAssertNil(observed.first?.observation?.termination, golden)
            XCTAssertNil(observed.first?.observation?.output, golden)
            XCTAssertEqual(model.copyableText.components(separatedBy: "\nEnvironment: ").count - 1, 1, golden)
        }
    }

    // MARK: - Harness

    private static let observedFolders = [
        "observed-clean-exit", "observed-nonzero-exit", "observed-signal", "observed-cancelled",
        "observed-launch-failure", "observed-environment-change", "observed-environment-none", "observed-older-record",
    ]

    private static let stepRowIdentifiers: Set<String> = [
        "provenance-step-command", "provenance-step-environment", "provenance-path-list-value",
        "provenance-summary-value", "provenance-step-termination", "provenance-step-output",
    ]

    /// A hash of every file under `project` with its path, so a write of any kind shows.
    private static func digest(of project: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        let urls = (FileManager.default.enumerator(at: project, includingPropertiesForKeys: Array(keys))?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: keys).isRegularFile) == true }
            .sorted { $0.path < $1.path }
        var hasher = SHA256()
        for url in urls {
            hasher.update(data: Data(url.path.utf8))
            hasher.update(data: try Data(contentsOf: url))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The golden classifier record with a value for each masked date, id, duration and size, which the record
    /// reader needs, and every other byte as committed.
    private static func unmaskedGolden(_ name: String) throws -> Data {
        let url = ProvenanceDisplayFixtures.testsDirectory
            .appendingPathComponent("Fixtures/golden/classifiers/\(name)/lungfish-provenance.json")
        var text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"<TIMESTAMP>\"", with: "\"2026-10-14T12:00:00Z\"")
            .replacingOccurrences(of: "\"<DURATION>\"", with: "1.5")
            .replacingOccurrences(of: "\"<SIZE-R10>\"", with: "1024")
        for number in 1...60 {
            text = text.replacingOccurrences(
                of: "\"<UUID-\(number)>\"", with: "\"00000000-0000-0000-0000-\(String(format: "%012d", number))\""
            )
        }
        return Data(text.utf8)
    }

    private func openFirstStep(in host: NSObject) throws {
        spin { AccessibilityTreeProbe.element(in: host, identifier: "provenance-run-1") != nil }
        let run = try XCTUnwrap(AccessibilityTreeProbe.element(in: host, identifier: "provenance-run-1"), AccessibilityTreeProbe.dump(host))
        XCTAssertTrue(AccessibilityTreeProbe.press(run), "the run row must answer AXPress")
        spin { AccessibilityTreeProbe.element(in: host, identifier: "provenance-run-1-step-1") != nil }
        let step = try XCTUnwrap(AccessibilityTreeProbe.element(in: host, identifier: "provenance-run-1-step-1"), AccessibilityTreeProbe.dump(host))
        XCTAssertTrue(AccessibilityTreeProbe.press(step), "the step row must answer AXPress")
        spin { AccessibilityTreeProbe.element(in: host, identifier: "provenance-step-command") != nil }
    }

    /// Hosts `content` in a window and returns that window, the root of the tree to walk. SwiftUI builds its
    /// accessibility nodes only once an assistive client is attached, and this application attribute is how one
    /// announces itself.
    private func host<Content: View>(_ content: Content) -> NSObject {
        NSApplication.shared.accessibilitySetValue(
            true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 720)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        windows.append(window)
        return window
    }

    private func spin(timeout: TimeInterval = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// The label of each unindented line of the first Lineage step in `copy`, which is the step's header and then
    /// the label before the first colon of each of its lines.
    private static func stepLabels(of copy: String) -> [String] {
        guard let section = copy.components(separatedBy: "\n\n").first(where: { $0.hasPrefix("Lineage\n") }) else {
            return []
        }
        return section.components(separatedBy: "\n").dropFirst(2)
            .filter { !$0.hasPrefix(" ") }
            .map { line in line.firstIndex(of: ":").map { String(line[..<$0]) } ?? line }
    }

    private func observation(of model: ProvenanceInspectorViewModel) throws -> ProvenanceStepObservation {
        try XCTUnwrap(
            model.resolvedEnvelope?.steps.first?.observation,
            "The record's step carries an observation this build reads."
        )
    }

    /// Copies the committed record of `folder` into a temporary project and loads it through the real lookup.
    private func loadedModel(
        folder: String,
        record: Data? = nil,
        beforeLoad: (URL) throws -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (model: ProvenanceInspectorViewModel, project: URL) {
        let project = try makeProject()
        let analysis = project.appendingPathComponent("Analyses/\(folder)", isDirectory: true)
        let sidecar = analysis.appendingPathComponent(".lungfish-provenance.json")
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        if let record {
            try record.write(to: sidecar, options: .atomic)
        } else {
            try FileManager.default.copyItem(
                at: ProvenanceDisplayFixtures.directory
                    .appendingPathComponent("Analyses/\(folder)/.lungfish-provenance.json"),
                to: sidecar
            )
        }
        try beforeLoad(project)
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: analysis, sidebarType: .analysisResult, contentMode: .genomics, displayName: folder
        ))
        let finished = await waitUntil(timeout: .seconds(60)) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.", file: file, line: line)
        XCTAssertNotNil(model.resolvedEnvelope, "No record was found for \(folder).", file: file, line: line)
        XCTAssertEqual(model.resolvedSidecarURL?.lastPathComponent, ".lungfish-provenance.json", file: file, line: line)
        return (model, project)
    }

    /// Loads the committed record of `folder` and compares what the tab shows with the expected file of the same
    /// name. Returns the loaded model.
    @discardableResult
    private func assertDisplay(
        folder: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ProvenanceInspectorViewModel {
        let (model, project) = try await loadedModel(folder: folder, file: file, line: line)
        let snapshot = ProvenanceDisplaySnapshot.capture(
            model, for: ProvenanceDisplayCase(name: folder), redaction: ProvenanceDisplayRedaction(projectURL: project)
        )
        let actual = try snapshot.canonicalJSON()
        XCTAssertEqual(
            try snapshot.privatePathLeaks(), [],
            "The snapshot of \(folder) names a private path, so it cannot be committed.", file: file, line: line
        )
        let expectedURL = ProvenanceDisplayFixtures.expectedDirectory.appendingPathComponent("\(folder).json")
        guard let expectedData = try? Data(contentsOf: expectedURL) else {
            let written = ProvenanceDisplaySnapshot.writeActual(actual, named: folder)
            XCTFail(
                "No expected display at \(expectedURL.path). The display now is in \(written?.path ?? "(not written)").",
                file: file, line: line
            )
            return model
        }
        let expected = try ProvenanceDisplaySnapshot.decode(expected: expectedData)
        if snapshot != expected {
            let written = ProvenanceDisplaySnapshot.writeActual(actual, named: folder)
            XCTFail(
                """
                The Provenance tab no longer shows \(folder) as it did.
                Compare \(expectedURL.path)
                with    \(written?.path ?? "(not written)")
                \(ProvenanceDisplaySnapshot.lineDifferences(expected: try expected.canonicalJSON(), actual: actual))
                """,
                file: file, line: line
            )
        }
        return model
    }

    /// A fresh `.lungfish` project, named with a space as the other display suites name theirs.
    private func makeProject() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "provenance-step-termination")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Observed Records.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }
}

