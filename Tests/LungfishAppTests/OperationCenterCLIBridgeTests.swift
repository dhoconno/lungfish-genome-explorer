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
@MainActor
final class OperationCenterCLIBridgeTests: XCTestCase {
    private var folder: URL!
    private var savedBundleReady: (([URL], OperationRouteContext?) -> Void)?
    private var bundleImports: BundleImportLog!

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
        let cli = try standInCLI(playing: try transcript("tree-reroot"))
        let id = beginRow(title: "Reroot tree", type: .phylogeneticTreeTransform)
        defer { OperationCenter.shared.clearItem(id: id) }

        let result = try await CLITreeRunner(label: "tree transform", cliURLOverride: cli)
            .run(arguments: ["tree", "reroot"], operationID: id)

        let item = try await settledItem(id, logging: ["info: Starting tree transform."])
        XCTAssertEqual(result.bundleURL.path, "/work/Rerooted.lungfishtree")
        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertEqual(loggedLines(of: item), ["info: Starting tree transform."])
        XCTAssertEqual(item.bundleURLs.map(\.path), ["/work/Rerooted.lungfishtree"])
        XCTAssertEqual(bundleImports.paths, [["/work/Rerooted.lungfishtree"]], "only the completion's outputs reach bundle import")
    }

    func testARunThatLoggedAWarningReadsCompletedWithWarnings() async throws {
        let warning = "Export format phylip does not preserve MSA annotations; 2 annotation(s) remain in the source .lungfishmsa bundle."
        let expectedLog = ["info: Starting MSA export.", "warning: \(warning)"]
        let cli = try standInCLI(playing: try transcript("msa-export-with-warning"))
        let id = beginRow(title: "Export alignment", type: .multipleSequenceAlignmentAction)
        defer { OperationCenter.shared.clearItem(id: id) }

        let result = try await CLIMSAActionRunner(cliURLOverride: cli)
            .run(arguments: ["msa", "export"], operationID: id)

        let item = try await settledItem(id, logging: expectedLog)
        XCTAssertEqual(result.outputURL.path, "/work/annotated.phy")
        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(loggedLines(of: item), expectedLog)
        XCTAssertEqual(item.outputURLs.map(\.path), ["/work/annotated.phy"])
        XCTAssertEqual(bundleImports.paths, [], "a loose output file is not a bundle to import")
    }

    func testAFailedRunReadsFailedAndLogsWhy() async throws {
        let expectedLog = ["info: Starting tree transform.", "error: Failed: Tree node not found: NoSuchTip"]
        let cli = try standInCLI(playing: try transcript("tree-reroot-failed"), exitStatus: 1)
        let id = beginRow(title: "Reroot tree", type: .phylogeneticTreeTransform)
        defer { OperationCenter.shared.clearItem(id: id) }

        do {
            _ = try await CLITreeRunner(label: "tree transform", cliURLOverride: cli)
                .run(arguments: ["tree", "reroot"], operationID: id)
            XCTFail("a run that ends in a failed event must throw")
        } catch let error as CLITreeRunner.RunError {
            XCTAssertEqual(error, .underlying("Tree node not found: NoSuchTip"))
        }

        let item = try await settledItem(id, logging: expectedLog)
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertEqual(loggedLines(of: item), expectedLog)
        XCTAssertEqual(bundleImports.paths, [])
    }

    /// The user cancels while the CLI is finishing. The CLI still prints its `complete`
    /// line, naming a bundle, but a row that is cancelling when its run ends reads
    /// Cancelled and imports nothing.
    func testARunCancelledBeforeItsCompletionReadsCancelledAndImportsNothing() async throws {
        let ready = folder.appendingPathComponent("ready")
        let go = folder.appendingPathComponent("go")
        let lines = try transcript("msa-extract")
        XCTAssertTrue(try XCTUnwrap(lines.last).contains(#""outputs":["\/work\/selected.lungfishmsa"]"#))
        let cli = try standInCLI(playing: lines, holdingTheLastLineUntil: go, announcing: ready)
        let id = beginRow(title: "Extract alignment", type: .multipleSequenceAlignmentAction) {
            FileManager.default.createFile(atPath: go.path, contents: nil)
        }
        defer { OperationCenter.shared.clearItem(id: id) }

        let runner = CLIMSAActionRunner(cliURLOverride: cli)
        let run = Task { try await runner.run(arguments: ["msa", "extract"], operationID: id) }
        let started = await waitUntil(timeout: .seconds(30)) {
            FileManager.default.fileExists(atPath: ready.path)
                && self.loggedLines(of: self.item(id)) == ["info: Starting MSA extraction."]
        }
        XCTAssertTrue(started, "the stand-in CLI never reached its last line")
        OperationCenter.shared.cancel(id: id)

        let outcome = await run.result
        guard case .failure(let error) = outcome, error is CancellationError else {
            return XCTFail("a cancelled run must end in CancellationError, got \(outcome)")
        }
        let item = try await settledItem(id, logging: ["info: Starting MSA extraction."])
        XCTAssertEqual(item.displayStateLabel, "Cancelled")
        XCTAssertEqual(loggedLines(of: item), ["info: Starting MSA extraction."])
        XCTAssertEqual(item.bundleURLs, [])
        XCTAssertEqual(item.outputURLs, [])
        XCTAssertEqual(bundleImports.paths, [], "a cancelled run imports nothing, even when its CLI completed")
    }

    // MARK: - Helpers

    /// The lines of a captured version 1 run.
    private func transcript(_ name: String) throws -> [String] {
        XCTAssertTrue(CLIEventCompatCorpus.capturedRuns.contains(name), "\(name) is not a captured run")
        let url = CLIEventCompatCorpus.v1Folder.appendingPathComponent("\(name).ndjson")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// A shell script in place of `lungfish-cli` that prints `lines` on standard output and
    /// exits with `exitStatus`. With `go` set it prints every line but the last, touches
    /// `ready`, and waits for `go` to exist before it prints the last line.
    private func standInCLI(
        playing lines: [String],
        exitStatus: Int32 = 0,
        holdingTheLastLineUntil go: URL? = nil,
        announcing ready: URL? = nil
    ) throws -> URL {
        let head = folder.appendingPathComponent("head.ndjson")
        let last = folder.appendingPathComponent("last.ndjson")
        var script = "#!/bin/sh\n"
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
        let url = folder.appendingPathComponent("lungfish-cli")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

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

    /// The row once it has ended and its log holds `expected`. The bridge hops each event
    /// to the main queue, so a line can land after the runner returns.
    private func settledItem(_ id: UUID, logging expected: [String]) async throws -> OperationCenter.Item {
        await waitUntil(timeout: .seconds(30)) {
            guard let item = self.item(id), !item.state.isActive else { return false }
            return self.loggedLines(of: item) == expected
        }
        return try XCTUnwrap(item(id))
    }

    /// The log as the expanded row shows it, one `level: message` string per entry.
    private func loggedLines(of item: OperationCenter.Item?) -> [String] {
        (item?.logEntries ?? [])
            .filter { !$0.isElisionMarker }
            .map { "\($0.level.rawValue): \($0.message)" }
    }
}

/// What reached `onBundleReadyWithContext`, one array of paths per call.
@MainActor
private final class BundleImportLog {
    private(set) var paths: [[String]] = []

    func record(_ urls: [URL]) {
        paths.append(urls.map(\.path))
    }
}
