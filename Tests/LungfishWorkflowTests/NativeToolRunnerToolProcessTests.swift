// NativeToolRunnerToolProcessTests.swift - NativeToolRunner on ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.2 lane 2A (R7). NativeToolRunner runs every process through
// ToolProcess. These tests run small fake tools, shell scripts in a temporary
// managed storage root, through the real path.

import XCTest
import Darwin
@testable import LungfishWorkflow

final class NativeToolRunnerToolProcessTests: XCTestCase {
    /// 3000 lines of 75 bytes each, 225,000 bytes per stream.
    private static let lineCount = 3000

    private static func expectedLines(_ prefix: String) -> String {
        (0..<lineCount).map {
            String(format: "%@-%04d-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n", prefix, $0)
        }.joined()
    }

    // MARK: Incomplete output

    func testRunProcessRefusesOutputAChildKeptOpenAfterTheToolExited() async throws {
        let fixture = try FakeToolRoot()
        defer { fixture.remove() }
        let pidFile = fixture.root.appendingPathComponent("child.pid")
        let runner = fixture.runner

        do {
            _ = try await runner.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'head\\n'; sleep 30 & echo $! > \"$1\"; exit 0", "lingering", pidFile.path],
                timeout: 20,
                toolName: "lingering"
            )
            XCTFail("Output a background child kept open must not pass as complete")
        } catch NativeToolError.executionFailed(let name, let status, let message) {
            XCTAssertEqual(name, "lingering")
            XCTAssertEqual(status, 0)
            XCTAssertEqual(message, "lingering output was incomplete: a child process kept its output open after it exited")
        }
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await assertProcessEnds(child)
    }

    func testRunWithFileOutputRefusesAFileAChildKeptWritingAndPublishesNothing() async throws {
        let fixture = try FakeToolRoot()
        defer { fixture.remove() }
        try fixture.install(environment: "pigz", executable: "pigz", script: """
        #!/bin/sh
        printf 'compressed\\n'
        (sleep 30; printf 'late\\n') &
        exit 0
        """)
        let output = fixture.root.appendingPathComponent("out.gz")
        try "original\n".write(to: output, atomically: true, encoding: .utf8)

        do {
            _ = try await fixture.runner.runWithFileOutput(.pigz, arguments: [], outputFile: output, timeout: 20)
            XCTFail("A file a background child kept writing must not be published")
        } catch NativeToolError.executionFailed(let name, let status, let message) {
            XCTAssertEqual(name, "pigz")
            XCTAssertEqual(status, 0)
            XCTAssertTrue(message.hasPrefix("pigz output was incomplete"), message)
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "original\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix(".out.gz.") }
        XCTAssertEqual(leftovers, [], "the temporary output must be removed")
    }

    // MARK: Cancellation of a JVM-style tree

    /// A BBTools wrapper runs java as its child, and java can start helpers of
    /// its own. Cancelling the run must leave none of them alive, even when
    /// they ignore SIGTERM.
    func testCancellingABBToolsRunKillsTheWrapperItsJavaChildAndItsHelpers() async throws {
        let fixture = try FakeToolRoot()
        defer { fixture.remove() }
        let pids = fixture.root.appendingPathComponent("pids")
        try FileManager.default.createDirectory(at: pids, withIntermediateDirectories: true)
        try fixture.install(environment: "bbtools", executable: "reformat.sh", script: """
        #!/bin/sh
        # A helper the "JVM" starts in the background, deaf to SIGTERM.
        /bin/sh -c 'trap "" TERM HUP; echo $$ > "$1/helper"; exec sleep 30' helper "$1" &
        # The "JVM" itself, in the foreground as `eval $CMD` runs it.
        /bin/sh -c 'trap "" TERM HUP; echo $$ > "$1/java"; while :; do sleep 1; done' java "$1"
        """)

        let task = Task {
            try await fixture.runner.run(.reformat, arguments: [pids.path], timeout: 30)
        }
        let java = try await waitForPID(pids.appendingPathComponent("java"))
        let helper = try await waitForPID(pids.appendingPathComponent("helper"))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled run must throw CancellationError")
        } catch is CancellationError {
        }
        try await assertProcessEnds(java)
        try await assertProcessEnds(helper)
    }

    // MARK: More than 64 KB on both streams

    func testRunReturnsEveryByteOfLargeStdoutAndStderr() async throws {
        let fixture = try FakeToolRoot()
        defer { fixture.remove() }
        try fixture.installLargeSeqkit()

        let result = try await fixture.runner.run(.seqkit, arguments: ["large-output"], timeout: 30)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, Self.expectedLines("stdout"))
        XCTAssertEqual(result.stderr, Self.expectedLines("stderr"))
    }

    func testRunPipelineReturnsEveryByteOfLargeStreamsFromEveryStage() async throws {
        let fixture = try FakeToolRoot()
        defer { fixture.remove() }
        try fixture.installLargeSeqkit()

        let result = try await fixture.runner.runPipeline(
            [
                NativePipelineStage(.seqkit, arguments: ["large-output"]),
                NativePipelineStage(.seqkit, arguments: ["echo-both"]),
            ],
            timeout: 60
        )

        XCTAssertEqual(result.exitCodes, [0, 0])
        XCTAssertEqual(result.stdout, Self.expectedLines("stdout"))
        XCTAssertEqual(result.stderrByStage, [Self.expectedLines("stderr"), Self.expectedLines("stdout")])
    }

    // MARK: Pipeline reporting

    /// Every stage runs to its own end, so a later stage reports its own exit
    /// code and stderr after an earlier stage fails.
    func testRunPipelineLetsEveryStageReportItsOwnExitAfterAnEarlierStageFails() async throws {
        let fixture = try FakeToolRoot()
        defer { fixture.remove() }
        try fixture.install(environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "fail" ]; then echo "stage one failed" >&2; exit 1; fi
        cat >/dev/null
        sleep 0.3
        echo "stage two saw end of input" >&2
        exit 4
        """)

        let result = try await fixture.runner.runPipeline(
            [
                NativePipelineStage(.samtools, arguments: ["fail"]),
                NativePipelineStage(.samtools, arguments: ["sink"]),
            ],
            timeout: 20
        )

        XCTAssertEqual(result.exitCodes, [1, 4])
        XCTAssertEqual(result.stderrByStage, ["stage one failed\n", "stage two saw end of input\n"])
        XCTAssertEqual(result.firstFailureCode, 1)
    }

    func testRunPipelineTimeoutThrowsTheJoinedStageNames() async throws {
        let fixture = try FakeToolRoot()
        defer { fixture.remove() }
        try fixture.install(environment: "samtools", executable: "samtools", script: "#!/bin/sh\nexec sleep 30\n")

        do {
            _ = try await fixture.runner.runPipeline(
                [NativePipelineStage(.samtools, arguments: []), NativePipelineStage(.samtools, arguments: [])],
                timeout: 0.5
            )
            XCTFail("The pipeline must time out")
        } catch NativeToolError.timeout(let name, let seconds) {
            XCTAssertEqual(name, "samtools | samtools")
            XCTAssertEqual(seconds, 0.5)
        }
    }

    func testRunProcessReportsALaunchFailureAsExecutionFailedWithMinusOne() async throws {
        let runner = NativeToolRunner(toolsDirectory: nil)
        do {
            _ = try await runner.runProcess(
                executableURL: URL(fileURLWithPath: "/nonexistent/lungfish-tool"),
                arguments: [],
                timeout: 5
            )
            XCTFail("A missing executable must not launch")
        } catch NativeToolError.executionFailed(let name, let status, _) {
            XCTAssertEqual(name, "lungfish-tool")
            XCTAssertEqual(status, -1)
        }
    }

    // MARK: Exit status

    /// A tool that calls exit(-1), as bcftools and seqkit do on a missing
    /// input, has always reported 255, the 8 bits wait(2) keeps.
    func testExitMinusOneReportsTwoHundredFiftyFiveThroughEveryEntryPoint() async throws {
        let fixture = try FakeToolRoot()
        defer { fixture.remove() }
        let script = "#!/usr/bin/perl\nprint STDERR \"failing\\n\";\nexit(-1);\n"
        try fixture.install(environment: "seqkit", executable: "seqkit", script: script)
        try fixture.install(environment: "samtools", executable: "samtools", script: "#!/bin/sh\ncat >/dev/null\n")

        let run = try await fixture.runner.run(.seqkit, arguments: [], timeout: 20)
        XCTAssertEqual(run.exitCode, 255)
        XCTAssertEqual(run.stderr, "failing\n")

        let output = fixture.root.appendingPathComponent("out.txt")
        let file = try await fixture.runner.runWithFileOutput(.seqkit, arguments: [], outputFile: output, timeout: 20)
        XCTAssertEqual(file.exitCode, 255)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))

        let pipeline = try await fixture.runner.runPipeline(
            [NativePipelineStage(.seqkit, arguments: []), NativePipelineStage(.samtools, arguments: [])],
            timeout: 20
        )
        XCTAssertEqual(pipeline.exitCodes, [255, 0])
        XCTAssertEqual(pipeline.firstFailureCode, 255)
    }

    // MARK: Helpers

    private func waitForPID(_ url: URL) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("No pid appeared at \(url.path)")
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func assertProcessEnds(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        kill(pid, SIGKILL)
        XCTFail("Process \(pid) is still alive", file: file, line: line)
    }
}

/// A managed storage root, without whitespace in its path, holding fake tools.
private struct FakeToolRoot {
    let root: URL
    let runner: NativeToolRunner

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-native-toolprocess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Debug, because a Preview home also honours the legacy
        // DatabaseStorageLocation preference of the test process's defaults
        // domain, which can point tool resolution away from this root.
        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .debug)
    }

    func install(environment: String, executable: String, script: String) throws {
        let directory = CoreToolLocator.environmentURL(named: environment, homeDirectory: root, appIdentity: .debug)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(executable)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func installLargeSeqkit() throws {
        try install(environment: "seqkit", executable: "seqkit", script: """
        #!/bin/sh
        case "$1" in
          large-output)
            i=0
            while [ "$i" -lt 3000 ]; do
              printf 'stdout-%04d-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\\n' "$i"
              printf 'stderr-%04d-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\\n' "$i" >&2
              i=$((i + 1))
            done
            ;;
          echo-both)
            while IFS= read -r line; do
              printf '%s\\n' "$line"
              printf '%s\\n' "$line" >&2
            done
            ;;
        esac
        """)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
