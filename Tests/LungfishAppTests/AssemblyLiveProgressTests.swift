import Foundation
import XCTest
import LungfishWorkflow
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp

final class AssemblyLiveProgressTests: XCTestCase {
    func testGUIAssemblyRequestsLiveJSONEvents() throws {
        let request = AssemblyRunRequest(tool: .spades, readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")], projectName: "test",
            outputDirectory: URL(fileURLWithPath: "/tmp/assembly"), threads: 1)
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: .assemble(request: request, outputMode: .groupedResult))
        XCTAssertEqual(invocation.subcommand, "assemble")
        XCTAssertTrue(invocation.arguments.contains("--json-events"))
    }

    func testSharedLogEventIsDeliveredWithoutInventingProgress() throws {
        let event = try XCTUnwrap(FASTQCLIProgressEvent.parse(#"{"event":"log","level":"info","message":"Building graph"}"#))
        XCTAssertEqual(event.message, "Building graph")
        XCTAssertEqual(event.progress, 0)
    }

    @MainActor
    func testRawLogsPreserveRecognizedStageAndWarningSeverity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-cli")
        try """
        #!/bin/sh
        printf '%s\\n' '{"event":"start","message":"Starting"}' >&2
        printf '%s\\n' '{"event":"progress","progress":0,"message":"Building graph"}' >&2
        printf '%s\\n' '{"event":"log","level":"debug","message":"raw diagnostic"}' >&2
        printf '%s' '{"event":"log","level":"warning","message":"low support"}' >&2
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let center = OperationCenter()
        let id = center.begin(
            title: "Assembly",
            detail: "Preparing",
            operationType: .download,
            cliCommand: nil
        ).startedID!
        _ = try await LungfishCLIProcessRunner(cliURLProvider: { executable }).run(
            invocation: FASTQCLIInvocation(subcommand: "assemble", arguments: []),
            outputDirectory: directory,
            logHandler: { level, message in
                DispatchQueue.main.async { center.log(id: id, level: level, message: message) }
            },
            progress: { fraction, message in
                DispatchQueue.main.async { center.updateWithLog(id: id, progress: fraction, detail: message) }
            }
        )
        // Both callbacks enqueue on the same queue; this fence includes the final EOF line.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(center.items[0].detail, "Building graph")
        XCTAssertEqual(center.items[0].latestLogEntry?.message, "low support")
        XCTAssertEqual(center.items[0].latestLogEntry?.level, .warning)
        XCTAssertTrue(center.items[0].logEntries.contains { $0.level == .debug && $0.message == "raw diagnostic" })
        center.complete(id: id, detail: "Done")
        XCTAssertEqual(center.items[0].displayStateLabel, "Completed with Warnings")
    }

    func testCancellationDrainsUnterminatedWarningBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-cli")
        let ready = directory.appendingPathComponent("ready")
        try """
        #!/bin/sh
        printf '%s' '{"event":"log","level":"warning","message":"final diagnostic"}' >&2
        touch ready
        exec sleep 30
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let recorder = AssemblyLiveLogRecorder()
        let task = Task {
            try await LungfishCLIProcessRunner(cliURLProvider: { executable }).run(
                invocation: FASTQCLIInvocation(subcommand: "assemble", arguments: []),
                outputDirectory: directory,
                logHandler: { level, message in recorder.append(level, message) },
                progress: { _, _ in }
            )
        }
        // The wait returns once the script is ready. The 30 s child sleep keeps
        // it running until the cancel, even under the parallel unit tier.
        await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: ready.path) }
        task.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch LungfishCLIRunner.RunError.cancelled { }
        XCTAssertEqual(recorder.messages, ["warning:final diagnostic"])
    }

    func testLaunchFailureClosesPipeWritersAndReturns() async throws {
        let directory = FileManager.default.temporaryDirectory
        let absent = directory.appendingPathComponent("missing-cli-\(UUID().uuidString)")
        do {
            _ = try await LungfishCLIProcessRunner(cliURLProvider: { absent }).run(
                invocation: FASTQCLIInvocation(subcommand: "assemble", arguments: []),
                outputDirectory: directory, progress: { _, _ in }
            )
            XCTFail("Expected launch failure")
        } catch LungfishCLIRunner.RunError.launchFailed { }
    }

    func testAssemblyLogReachesCallbackWhileProcessIsStillRunning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-cli")
        let acknowledged = directory.appendingPathComponent("acknowledged")
        try """
        #!/bin/sh
        printf '%s\\n' '{"event":"log","level":"info","message":"Building graph"}' >&2
        attempts=0
        while [ ! -f acknowledged ] && [ "$attempts" -lt 1500 ]; do
          sleep 0.02
          attempts=$((attempts + 1))
        done
        test -f acknowledged || exit 19
        printf '%s' '{"event":"log","level":"info","message":"Final line"}' >&2
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let finalLine = expectation(description: "Unterminated final log is drained")
        _ = try await LungfishCLIProcessRunner(cliURLProvider: { executable }).run(
            invocation: FASTQCLIInvocation(subcommand: "assemble", arguments: []),
            outputDirectory: directory,
            progress: { _, message in
                if message == "Building graph" {
                    FileManager.default.createFile(atPath: acknowledged.path, contents: Data())
                }
                if message == "Final line" { finalLine.fulfill() }
            }
        )
        await fulfillment(of: [finalLine], timeout: 5)
    }
}

private final class AssemblyLiveLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ level: OperationLogLevel, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append("\(level.rawValue):\(message)")
    }
    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
