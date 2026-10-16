// TreeTransformSIGTERMTests.swift - How a SIGTERM ends a tree transform (Phase 2.11 lane S61, K7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `tree reroot`, `tree extract-subtree` and `tree relabel` share one writer, `executeTreeTransform`, and
// one cancel path, `TreeTransformCommand.runTransformCancellingOnSIGTERM`. They run no external tool,
// and Foundation refuses to read a FIFO, so neither a stand-in tool nor a blocked read can hold them in
// flight in a child process. This test runs the real writer and the real cancel path in the test
// process instead. The transform step is a seam that waits for the SIGTERM handler's cancel, a second
// task posts one SIGTERM to the test process once the writer is held, and the writer then finishes its
// step with the cancel pending.

import ArgumentParser
import Darwin
import Foundation
import Synchronization
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class TreeTransformSIGTERMTests: XCTestCase {
    private final class EmittedLines: Sendable {
        private let storage = Mutex<[String]>([])
        func append(_ line: String) { storage.withLock { $0.append(line) } }
        var all: [String] { storage.withLock { $0 } }
    }

    /// A SIGTERM during the transform cancels the run. The command exits 125, records the run as
    /// cancelled beside the output it did not write, ends the stream with one `failed` line and removes
    /// the bundle the writer had finished.
    func testSIGTERMCancelsATransformHeldInFlightAndRecordsItCancelled() async throws {
        let directory = try TestTempDirectory.make(prefix: "tree-transform-sigterm")
        defer { TestTempDirectory.cleanup(directory) }
        let newick = directory.appendingPathComponent("Source.nwk")
        try "((A:0.1,B:0.2)Clade:0.3,C:0.4);\n".write(to: newick, atomically: true, encoding: .utf8)
        let source = directory.appendingPathComponent("Source.lungfishtree", isDirectory: true)
        _ = try PhylogeneticTreeBundleImporter.importTree(from: newick, to: source, options: .init(name: "Source"))
        let output = directory.appendingPathComponent("Rerooted.lungfishtree", isDirectory: true)
        let record = URL(fileURLWithPath: output.path + ".cancelled" + ProvenanceRecorder.provenanceFilename)
        let command = try TreeCommand.RerootSubcommand.parse([
            "--bundle", source.path, "--on", "C", "--output", output.path, "--format", "json",
        ])
        let emitted = EmittedLines()
        let held = DispatchSemaphore(value: 0)

        // A SIGTERM that arrives late must not end the test runner.
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }

        @Sendable func awaitHeld() -> Bool { held.wait(timeout: .now() + 30) == .success }
        let poster = Task.detached {
            if awaitHeld() { kill(getpid(), SIGTERM) }
        }
        var thrown: (any Error)?
        do {
            try await command.runTransformCancellingOnSIGTERM(emit: { emitted.append($0) }) {
                try executeTreeTransform(
                    bundlePath: source.path,
                    outputPath: output.path,
                    toolName: "lungfish tree reroot",
                    argv: ["lungfish", "tree", "reroot"],
                    globalOptions: try GlobalOptions.parse(["--format", "json"]),
                    emit: { emitted.append($0) }
                ) { bundle, outputURL, provenance in
                    held.signal()
                    // Held in flight until the SIGTERM handler cancels this task.
                    let deadline = ContinuousClock.now + .seconds(20)
                    while !Task.isCancelled, ContinuousClock.now < deadline { usleep(10_000) }
                    return try bundle.rerootedBundle(on: "C", to: outputURL, provenance: provenance)
                }
            }
        } catch {
            thrown = error
        }
        await poster.value

        XCTAssertEqual(thrown as? ExitCode, CLIExitCode.cancelled.exitCode, "a cancelled transform exits 125, ended with \(String(describing: thrown))")
        XCTAssertEqual(try SIGTERMPinSupport.recordStatus(at: record), "cancelled", "the command records its run as cancelled")
        XCTAssertEqual(
            emitted.all.filter { $0.contains(#""event":"failed""#) }.count, 1,
            "the stream ends with one failed line: \(emitted.all)"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "no tree bundle was left behind")
    }
}
