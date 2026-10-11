// OperationCenterCLIBridgeTests.swift - One test for each label a bridged lungfish-cli run can end on
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

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
        for variant in Variant.allCases {
            bundleImports.reset()
            let cli = try standInCLI(playing: try transcript("tree-reroot", as: variant), variant: variant)
            let id = beginRow(title: "Reroot tree", type: .phylogeneticTreeTransform)
            defer { OperationCenter.shared.clearItem(id: id) }

            let result = try await CLITreeRunner(label: "tree transform", cliURLOverride: cli)
                .run(arguments: ["tree", "reroot"], operationID: id)

            let item = try await settledItem(id, logging: ["info: Starting tree transform."], variant: variant)
            XCTAssertEqual(result.bundleURL.path, "/work/Rerooted.lungfishtree", "\(variant)")
            XCTAssertEqual(item.displayStateLabel, "Completed", "\(variant)")
            XCTAssertEqual(eventLines(of: item), ["info: Starting tree transform."], "\(variant)")
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
        let expectedLog = ["info: Starting MSA export.", "warning: \(warning)"]
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
        let expectedLog = ["info: Starting tree transform.", "error: Failed: Tree node not found: NoSuchTip"]
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
            return self.loggedLines(of: item).count == 3
        }
        let item = try XCTUnwrap(item(id))
        let logged = loggedLines(of: item)
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertEqual(item.errorMessage, failure)
        XCTAssertEqual(logged.last, "error: Failed: \(failure)", "the failure entry stays last")
        XCTAssertEqual(logged.filter { $0 == "info: \(errorLine)" }.count, 1, "the standard error line is logged once at info")
        XCTAssertEqual(Set(logged), ["info: Starting tree transform.", "info: \(errorLine)", "error: Failed: \(failure)"])
        XCTAssertEqual(bundleImports.paths, [])
    }

    /// The user cancels while the CLI is finishing. The CLI still prints its `complete`
    /// line, naming a bundle, but a row that is cancelling when its run ends reads
    /// Cancelled and imports nothing.
    func testARunCancelledBeforeItsCompletionReadsCancelledAndImportsNothing() async throws {
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
                    && self.eventLines(of: self.item(id)) == ["info: Starting MSA extraction."]
            }
            XCTAssertTrue(started, "\(variant): the stand-in CLI never reached its last line")
            OperationCenter.shared.cancel(id: id)

            let outcome = await run.result
            guard case .failure(let error) = outcome, error is CancellationError else {
                return XCTFail("\(variant): a cancelled run must end in CancellationError, got \(outcome)")
            }
            let item = try await settledItem(id, logging: ["info: Starting MSA extraction."], variant: variant)
            XCTAssertEqual(item.displayStateLabel, "Cancelled", "\(variant)")
            XCTAssertEqual(eventLines(of: item), ["info: Starting MSA extraction."], "\(variant)")
            XCTAssertEqual(standardErrorLines(of: item), expectedStandardError(variant), "\(variant)")
            XCTAssertEqual(item.bundleURLs, [], "\(variant)")
            XCTAssertEqual(item.outputURLs, [], "\(variant)")
            XCTAssertEqual(bundleImports.paths, [], "\(variant): a cancelled run imports nothing, even when its CLI completed")
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
