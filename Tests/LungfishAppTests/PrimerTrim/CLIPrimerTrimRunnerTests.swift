import XCTest
import Foundation
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class CLIPrimerTrimRunnerTests: XCTestCase {
    func testRunCompletesForFastExitingCLIProcess() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPrimerTrimRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cliURL = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"event":"start","message":"starting","progress":0}'
        printf '%s\\n' '{"event":"complete","output":"/tmp/trimmed.bam","outputs":["/tmp/trimmed.bam","/tmp/trimmed.bam.bai","/tmp/trimmed.primer-trim-provenance.json"],"message":"trackID=trimmed trackName=Trimmed"}'
        exit 0
        """
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: cliURL.path
        )

        let originalCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cliURL.path, 1)
        defer {
            if let originalCLIPath {
                setenv("LUNGFISH_CLI_PATH", originalCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }

        final class Capturer: @unchecked Sendable {
            var events: [CLIEvent] = []
        }
        let capturer = Capturer()

        let runner = CLIPrimerTrimRunner()
        let result = try await runner.run(arguments: ["bam", "primer-trim"]) { event in
            capturer.events.append(event)
        }

        XCTAssertTrue(capturer.events.contains { event in
            if case .start = event { return true }
            return false
        })
        XCTAssertEqual(result.trackID, "trimmed")
        XCTAssertEqual(result.trackName, "Trimmed")
        XCTAssertEqual(result.bamPath, "/tmp/trimmed.bam")
        XCTAssertEqual(result.baiPath, "/tmp/trimmed.bam.bai")
        XCTAssertEqual(result.provenanceSidecarPath, "/tmp/trimmed.primer-trim-provenance.json")
    }

    func testCancelTerminatesCLIProcessTree() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPrimerTrimRunnerCancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let childPIDURL = tempDir.appendingPathComponent("child.pid")
        let cliURL = tempDir.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        nohup /bin/sh -c 'trap "" TERM HUP INT; while :; do sleep 1; done' >/dev/null 2>&1 &
        echo "$!" > "\(childPIDURL.path)"
        printf '%s\\n' '{"event":"start","message":"starting","progress":0}'
        while kill -0 "$!" 2>/dev/null; do
          sleep 0.1
        done
        """
        try script.write(to: cliURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: cliURL.path
        )

        let originalCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cliURL.path, 1)
        defer {
            if let originalCLIPath {
                setenv("LUNGFISH_CLI_PATH", originalCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }

        let runner = CLIPrimerTrimRunner()
        let runTask = Task {
            try await runner.run(arguments: ["bam", "primer-trim"]) { _ in }
        }
        let childPID = try await waitForPIDFile(childPIDURL)
        defer { ProcessTreeTerminator.terminate(rootPID: childPID, gracePeriod: 0) }

        await runner.cancel()
        _ = await runTask.result

        try await waitForProcessExit(pid: childPID)
    }

    func testBuildCLIArgumentsIncludesAllRequiredFlags() {
        let arguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: URL(fileURLWithPath: "/tmp/proj/Sample.lungfishref"),
            alignmentTrackID: "aln-1",
            schemeURL: URL(fileURLWithPath: "/tmp/QIASeq.lungfishprimers"),
            outputTrackName: "Primer-trimmed Sample"
        )

        XCTAssertEqual(arguments[0], "bam")
        XCTAssertEqual(arguments[1], "primer-trim")
        XCTAssertTrue(arguments.contains("--bundle"))
        XCTAssertTrue(arguments.contains("/tmp/proj/Sample.lungfishref"))
        XCTAssertTrue(arguments.contains("--alignment-track"))
        XCTAssertTrue(arguments.contains("aln-1"))
        XCTAssertTrue(arguments.contains("--scheme"))
        XCTAssertTrue(arguments.contains("/tmp/QIASeq.lungfishprimers"))
        XCTAssertTrue(arguments.contains("--name"))
        XCTAssertTrue(arguments.contains("Primer-trimmed Sample"))
        XCTAssertTrue(arguments.contains("--format"))
        XCTAssertTrue(arguments.contains("json"))
    }
}

private func waitForPIDFile(_ url: URL, timeout: TimeInterval = 2) async throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) {
            let text = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return try XCTUnwrap(Int32(text), "Expected pid in \(url.path)")
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Timed out waiting for \(url.path)")
    throw CancellationError()
}

private func waitForProcessExit(pid: Int32, timeout: TimeInterval = 2) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !ProcessTreeTerminator.processExists(pid: pid) {
            return
        }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    XCTFail("Process \(pid) was still running after cancellation")
}
