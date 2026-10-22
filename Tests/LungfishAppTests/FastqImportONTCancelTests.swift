// FastqImportONTCancelTests.swift - SIGTERM cancels `fastq import-ont`, alone and through the app's transport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M2 (panel decisions P2, G1 and S30 review section 5 note 2). The window cancels a CLI
// route with SIGTERM and gives the command `CLIProcessLauncher.operationGrace` before SIGKILL. The leaf turns
// the signal into a cancel, so the import stops at its next chunk, the workflow rolls its staged bundles
// back, the stream ends in one `failed` event that says "Import cancelled", and the command exits 125.
// The stream is this command's record of the cancel, since a rolled back import writes no run record.
//
// Both tests hold the import at a known point. The second barcode's first chunk is a FIFO. With flattened
// storage the importer opens it once the first barcode is done, and blocks in that read until the test
// closes its writer. A writer opens once the import reads the FIFO, so the cancel lands while the import is
// at work. The writer closes once the command reports on standard error that its cancel reached the import,
// and the import then meets its next chunk, a plain file, and stops there.
//
// The first test signals the CLI alone, as `CLISIGTERMHarness.cancel` does. The second cancels through
// `CLIProcessLauncher` and `CLIRunCancellation`, which signal the command's group and tree at once, as the
// window does. These tests live with the app because the transport belongs to LungfishKit.
//
// The third test (lane C2-ONTBIN review fix 1) cancels a default import in its chunk binning phase. A chunked
// import bins each stored chunk with `reformat.sh` once the importer ends, one launch per chunk, so twelve plain
// chunks keep the phase open for seconds. The test signals the command when the stream first names a chunk being
// binned. It asserts the same cancel and rollback, and that no process keeps the test's folder in its command line.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

final class FastqImportONTCancelTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-import-ont-cancel")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The run folder, the output the import is asked for and the FIFO that holds the import.
    private struct Scene {
        let arguments: [String]
        let output: URL
        let fifo: URL
    }

    private func makeScene() throws -> Scene {
        let source = root.appendingPathComponent("fastq_pass", isDirectory: true)
        func chunk(_ barcode: String, _ name: String) throws {
            let directory = source.appendingPathComponent(barcode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "@\(barcode)-\(name) runid=test barcode=\(barcode)\nACGTACGT\n+\nIIIIIIII\n".write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }
        try chunk("barcode01", "chunk_0.fastq")
        try chunk("barcode02", "chunk_1.fastq")
        let fifo = source.appendingPathComponent("barcode02/chunk_0.fastq")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, "the held chunk is a FIFO")
        let output = root.appendingPathComponent("imported", isDirectory: true)
        return Scene(
            arguments: [
                "fastq", "import-ont", source.path, "--output", output.path, "--concurrency", "1",
                "--storage-mode", "flattened", "--format", "json",
            ],
            output: output,
            fifo: fifo
        )
    }

    // MARK: - The CLI alone

    func testSIGTERMCancelsTheImportRollsItBackAndEndsTheStreamCancelled() async throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let scene = try makeScene()
        let standardOutput = root.appendingPathComponent("stdout.txt")
        let standardError = root.appendingPathComponent("stderr.txt")
        // The shell puts the command's two streams in files the test reads while it runs, and `exec`
        // keeps the process ID, so the SIGTERM reaches the command itself.
        let run = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec \"$0\" \"$@\" >\"$ONT_STDOUT\" 2>\"$ONT_STDERR\"", cli.path] + scene.arguments,
            environment: CLISIGTERMHarness.childEnvironment(
                overriding: ["ONT_STDOUT": standardOutput.path, "ONT_STDERR": standardError.path]
            )
        )
        defer { run.stop() }

        let atWork = await Self.waitForText("barcode02: Concatenating 2 chunks...", in: standardOutput)
        guard atWork, let writer = await Self.openWriter(of: scene.fifo) else {
            let stop = await CLISIGTERMHarness.cancel(run)
            return XCTFail("The import never reached the held chunk.\(stop.diagnostics) \(Self.text(of: standardError))")
        }
        let closer = Task.detached { () -> Bool in
            let reported = await Self.waitForText("Cancelling the import", in: standardError)
            close(writer)
            return reported
        }
        let stop = await CLISIGTERMHarness.cancel(run)
        let reported = await closer.value

        XCTAssertTrue(reported, "The command never reported that its cancel reached the import.\(stop.diagnostics)")
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertRecordCancelled { Self.streamStatus(Self.text(of: standardOutput)) }
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        Self.assertRolledBack(scene.output)
    }

    // MARK: - Through the transport

    func testACancelThroughTheTransportEndsTheSameWayInsideTheGrace() async throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let scene = try makeScene()
        let lines = LineRecorder()
        let cancellation = CLIRunCancellation()
        let spec = CLIProcessLauncher.spec(
            executableURL: cli,
            arguments: scene.arguments,
            terminationGracePeriod: CLIProcessLauncher.operationGrace,
            drainGracePeriod: CLIProcessLauncher.operationDrain
        )
        let processesBefore = Set(ProcessTreeTerminator.descendantProcessIDs(of: getpid()))
        let launched = Task {
            await CLIProcessLauncher.run(
                spec,
                cancellation: cancellation,
                onStdoutLine: { lines.append(stdout: $0) },
                onStderrLine: { lines.append(stderr: $0) }
            )
        }

        let atWork = await waitUntil(timeout: CLISIGTERMHarness.processWait) {
            lines.standardOutput.contains { $0.contains("barcode02: Concatenating 2 chunks...") }
        }
        guard atWork, let writer = await Self.openWriter(of: scene.fifo) else {
            cancellation.cancel()
            _ = await launched.value
            return XCTFail("The import never reached the held chunk. Standard error: \(lines.standardError)")
        }
        let closer = Task.detached { () -> Bool in
            let reported = await waitUntil(timeout: CLISIGTERMHarness.processWait) {
                lines.standardError.contains { $0.contains("Cancelling the import") }
            }
            close(writer)
            return reported
        }
        // Every process this test started since the launch is the CLI and its tree.
        let tree = ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { !processesBefore.contains($0) }
        let sent = ContinuousClock.now
        cancellation.cancel()
        let outcome = await launched.value
        let elapsed = ContinuousClock.now - sent
        let reported = await closer.value

        XCTAssertTrue(reported, "The command never reported that its cancel reached the import. Standard error: \(lines.standardError)")
        guard case .cancelled(let exit?) = outcome else {
            return XCTFail("The run was not cancelled through the transport: \(outcome)")
        }
        CLISIGTERMHarness.assertCancelledExit(
            status: exit.status, elapsed: elapsed, within: CLIProcessLauncher.operationGrace,
            detail: " Standard error: \(lines.standardError)"
        )
        CLISIGTERMHarness.assertRecordCancelled { Self.streamStatus(lines.standardOutput.joined(separator: "\n")) }
        await CLISIGTERMHarness.assertNoProcessLeft(tree)
        Self.assertRolledBack(scene.output)
    }

    // MARK: - During the chunk binning phase

    /// A default import bins each stored chunk with `reformat.sh` once the importer ends, one launch per chunk. A
    /// SIGTERM there stops the loop, the workflow rolls its staging folder back and the stream ends cancelled.
    func testSIGTERMDuringChunkBinningCancelsTheImportAndLeavesNothingBehind() async throws {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        do {
            _ = try await NativeToolRunner.shared.toolPath(for: .reformat)
        } catch {
            try ToolAvailability.skipOrFail("Binning needs the managed BBTools reformat.sh: \(error)")
        }
        let source = root.appendingPathComponent("fastq_pass", isDirectory: true)
        let barcode = source.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)
        // Twelve plain chunks of four reads: each chunk is one reformat.sh launch, so the phase stays open for seconds.
        for chunk in 0..<12 {
            let reads = (0..<4).map { read in
                "@barcode01-chunk_\(chunk)-\(read) runid=test barcode=barcode01\nACGTACGT\n+\nIIIIIIII\n"
            }.joined()
            try reads.write(to: barcode.appendingPathComponent("chunk_\(chunk).fastq"), atomically: true, encoding: .utf8)
        }
        let output = root.appendingPathComponent("imported", isDirectory: true)
        let standardOutput = root.appendingPathComponent("stdout.txt")
        let standardError = root.appendingPathComponent("stderr.txt")
        let run = try CLISIGTERMHarness.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec \"$0\" \"$@\" >\"$ONT_STDOUT\" 2>\"$ONT_STDERR\"", cli.path] + [
                "fastq", "import-ont", source.path, "--output", output.path,
                "--concurrency", "1", "--threads", "1", "--format", "json",
            ],
            environment: CLISIGTERMHarness.childEnvironment(
                overriding: ["ONT_STDOUT": standardOutput.path, "ONT_STDERR": standardError.path]
            )
        )
        defer { run.stop() }

        // The detail names the chunk before its launch, so the loop is open when the signal lands.
        guard await Self.waitForText("binning quality scores of", in: standardOutput) else {
            let stop = await CLISIGTERMHarness.cancel(run)
            return XCTFail("The import never reached the chunk binning phase.\(stop.diagnostics) \(Self.text(of: standardOutput).suffix(1_000))")
        }
        let stop = await CLISIGTERMHarness.cancel(run)

        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertRecordCancelled { Self.streamStatus(Self.text(of: standardOutput)) }
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        Self.assertRolledBack(output)
        // Every reformat.sh launch names a path under the test's folder, so none may outlive the command.
        let marker = root.lastPathComponent
        await waitUntil(timeout: CLISIGTERMHarness.operationGrace, pollInterval: .milliseconds(100)) {
            Self.commandLines(containing: marker)?.isEmpty ?? false
        }
        let remaining = try XCTUnwrap(Self.commandLines(containing: marker), "ps -axo command could not run")
        XCTAssertEqual(remaining, [], "no process keeps the cancelled import's folder in its command line")
    }

    // MARK: - Helpers

    /// The command lines of the processes running now that contain `marker`, read with `ps -axo command`, or nil
    /// when `ps` cannot run, so a check that reads nothing never passes.
    private static func commandLines(containing marker: String) -> [String]? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard ps.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.contains(marker) }
    }

    /// The status the stream records: the terminal event, `cancelled` for the failed event that says so.
    private static func streamStatus(_ standardOutput: String) -> String? {
        let decoder = CLIEventLineDecoder()
        let events = standardOutput.split(separator: "\n").compactMap { try? decoder.decode(line: String($0)) }
        switch events.last {
        case .complete?: return "completed"
        case .failed(let message, _)?: return message == "Import cancelled" ? CLISIGTERMHarness.cancelledRecordStatus : "failed"
        default: return nil
        }
    }

    /// A rolled back import leaves no bundle and no staging folder in the output it was given.
    private static func assertRolledBack(_ output: URL, file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        XCTAssertEqual(names, [], "a cancelled import leaves nothing in its output folder", file: file, line: line)
    }

    private final class LineRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var out: [String] = []
        private var err: [String] = []

        func append(stdout line: String) { lock.lock(); out.append(line); lock.unlock() }
        func append(stderr line: String) { lock.lock(); err.append(line); lock.unlock() }
        var standardOutput: [String] { lock.lock(); defer { lock.unlock() }; return out }
        var standardError: [String] { lock.lock(); defer { lock.unlock() }; return err }
    }

    /// Opens the FIFO at `url` for writing once a reader holds it, waiting up to the harness's process
    /// wait. A write after the reader left fails instead of raising SIGPIPE.
    private static func openWriter(of url: URL) async -> Int32? {
        let deadline = ContinuousClock.now + CLISIGTERMHarness.processWait
        while ContinuousClock.now < deadline {
            let descriptor = open(url.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
                _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
                return descriptor
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// Waits up to the harness's process wait until `file` holds `text`, reading it every 10 ms.
    private static func waitForText(_ text: String, in file: URL) async -> Bool {
        let deadline = ContinuousClock.now + CLISIGTERMHarness.processWait
        while ContinuousClock.now < deadline {
            if Self.text(of: file).contains(text) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func text(of file: URL) -> String {
        (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }
}
