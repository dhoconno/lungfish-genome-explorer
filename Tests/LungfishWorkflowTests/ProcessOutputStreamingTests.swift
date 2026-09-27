import Foundation
import XCTest
@testable import LungfishWorkflow

final class ProcessOutputStreamingTests: XCTestCase {
    func testStderrFramesSplitUTF8CRLFAndFinalLine() async throws {
        let fixture = try StreamingProcessFixture(script: #"printf '\316'; sleep 0.1; printf '\262\r'; sleep 0.1; printf '\nnext\rfinal'"# + " >&2")
        defer { fixture.remove() }
        // All writes belong to stderr, including the split UTF-8 prefix.
        let lines = StreamingLines()
        let result = try await fixture.manager.runTool(
            name: "fake", environment: "fake"
        ) { lines.append($0) }
        XCTAssertEqual(lines.values, ["β", "next", "final"])
        XCTAssertEqual(result.stderr, "β\r\nnext\rfinal")
    }

    func testFramerHandlesEveryByteBoundaryAndPreservesEmptyLines() {
        let bytes = Data("α\r\nβ\n\nγ\rdelta\r\n最後".utf8)
        for chunkSize in 1...bytes.count {
            var framer = ProcessOutputLineFramer()
            var lines: [String] = []
            for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                lines += framer.append(bytes.subdata(in: start..<min(start + chunkSize, bytes.count)))
            }
            lines += framer.finish()
            XCTAssertEqual(lines, ["α", "β", "", "γ", "delta", "最後"], "Chunk size \(chunkSize)")
            XCTAssertTrue(framer.finish().isEmpty)
        }
    }

    func testBothStreamsArriveBeforeExitAndFlushTheirFinalLines() async throws {
        let fixture = try StreamingProcessFixture(script: #"""
        printf 'out\n'
        printf 'err\r' >&2
        while [ ! -f "$5" ]; do sleep 0.01; done
        printf 'stdout-final'
        printf 'stderr-final' >&2
        """#, mergeOutputIntoStderr: false)
        defer { fixture.remove() }
        let gate = fixture.root.appendingPathComponent("both-streams-received")
        let lines = StreamingLines()
        let receive: @Sendable (String) -> Void = { line in
            lines.append(line)
            if lines.values.contains("out") && lines.values.contains("err") {
                try? Data().write(to: gate)
            }
        }
        let result = try await fixture.manager.runTool(name: "fake", arguments: [gate.path],
            environment: "fake", timeout: 5, stdoutHandler: receive, stderrHandler: receive)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "out\nstdout-final")
        XCTAssertEqual(result.stderr, "err\rstderr-final")
        XCTAssertEqual(Set(lines.values), Set(["out", "err", "stdout-final", "stderr-final"]))
    }

    func testTimeoutDrainsFinalOutputBeforeThrowing() async throws {
        let fixture = try StreamingProcessFixture(script: "printf 'partial diagnostic'; exec sleep 10")
        defer { fixture.remove() }
        let lines = StreamingLines()
        do {
            _ = try await fixture.manager.runTool(name: "fake", environment: "fake", timeout: 0.5,
                stderrHandler: { lines.append($0) })
            XCTFail("Expected timeout")
        } catch let error as CondaError {
            guard case .timeout = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(lines.values, ["partial diagnostic"])
    }

    func testAssemblyStreamsToDurableLogAndReportsStagesWithoutSyntheticFractions() async throws {
        let fixture = try StreamingProcessFixture(script: #"""
        printf '== Running assembler ==\n'
        printf 'diagnostic\n' >&2
        printf 'last fragment'
        exit 7
        """#, mergeOutputIntoStderr: false)
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("final output")
        let lines = StreamingLines()
        let stages = StreamingLines()
        let request = AssemblyRunRequest(tool: .spades, readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/fake.fastq")], projectName: "fake",
            outputDirectory: output, threads: 1)
        do {
            _ = try await ManagedAssemblyPipeline(condaManager: fixture.manager).run(request: request,
                onOutput: { line in
                    let durable = try? String(contentsOf: output.appendingPathComponent("assembly.log"), encoding: .utf8)
                    XCTAssertTrue(durable?.contains(line) == true, "Output must reach disk before UI callbacks")
                    lines.append(line)
                }, progress: { fraction, stage in
                    XCTAssertEqual(fraction, 0)
                    stages.append(stage)
                })
            XCTFail("Expected nonzero exit")
        } catch let error as ManagedAssemblyPipelineError {
            guard case .executionFailed(_, let code, _) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(code, 7)
        }
        XCTAssertEqual(Set(lines.values), Set(["== Running assembler ==", "diagnostic", "last fragment"]))
        let durableLines = try String(contentsOf: output.appendingPathComponent("assembly.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(durableLines, lines.values, "Disk and callbacks must share observed stream ordering")
        XCTAssertTrue(stages.values.contains("Running assembler"))
        XCTAssertFalse(stages.values.contains("diagnostic"), "Raw output must not overwrite recognized activity")
    }

    func testFreshMegahitKeepsRequestedOutputPathAndPublishesFailureLog() async throws {
        let fixture = try StreamingProcessFixture(script: #"""
        previous=''
        for arg in "$@"; do
            if [ "$previous" = '-o' ]; then outdir="$arg"; fi
            previous="$arg"
        done
        printf 'actual-output=%s\n' "$outdir"
        if [ -d "$outdir" ]; then printf 'output-already-exists\n'; exit 8; fi
        printf 'diagnostic-before-failure\n'
        exit 7
        """#)
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("fresh-output")
        let request = AssemblyRunRequest(tool: .megahit, readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/fake.fastq")], projectName: "fake",
            outputDirectory: output, threads: 1)
        do {
            _ = try await ManagedAssemblyPipeline(condaManager: fixture.manager).run(request: request)
            XCTFail("Expected nonzero exit")
        } catch let error as ManagedAssemblyPipelineError {
            guard case .executionFailed(_, let code, _) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(code, 7)
        }
        let log = try String(contentsOf: output.appendingPathComponent("assembly.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("actual-output=\(output.path)\n"))
        XCTAssertTrue(log.contains("diagnostic-before-failure"))
        XCTAssertFalse(log.contains("output-already-exists"))
    }

    func testFreshMegahitPublishesLiveSiblingLogOnCancellation() async throws {
        let fixture = try StreamingProcessFixture(script: "echo diagnostic; exec sleep 10")
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("fresh-output")
        let received = expectation(description: "diagnostic received")
        let request = AssemblyRunRequest(tool: .megahit, readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/fake.fastq")], projectName: "fake",
            outputDirectory: output, threads: 1)
        let task = Task {
            try await ManagedAssemblyPipeline(condaManager: fixture.manager).run(request: request) { _, line in
                if line == "diagnostic" { received.fulfill() }
            }
        }
        await fulfillment(of: [received], timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Logging cannot precreate MEGAHIT's destination")
        let siblings = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".fresh-output.assembly-") }
        XCTAssertEqual(siblings.count, 1)
        if let sibling = siblings.first {
            XCTAssertTrue(try String(contentsOf: sibling, encoding: .utf8).contains("diagnostic"))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let text = try String(contentsOf: output.appendingPathComponent("assembly.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("diagnostic"))
        for sibling in siblings { XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path)) }
    }

    func testAssemblyLogSurvivesCancellationAtFinalOutputPath() async throws {
        let fixture = try StreamingProcessFixture(script: "echo diagnostic; exec sleep 10")
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("final output")
        let received = expectation(description: "diagnostic received")
        let request = AssemblyRunRequest(tool: .spades, readType: .illuminaShortReads,
            inputURLs: [URL(fileURLWithPath: "/tmp/fake.fastq")], projectName: "fake",
            outputDirectory: output, threads: 1)
        let task = Task {
            try await ManagedAssemblyPipeline(condaManager: fixture.manager).run(request: request) { _, line in
                if line == "diagnostic" { received.fulfill() }
            }
        }
        await fulfillment(of: [received], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let text = try String(contentsOf: output.appendingPathComponent("assembly.log"), encoding: .utf8)
        XCTAssertTrue(text.contains("diagnostic"))
    }

}

private final class StreamingLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
}

private struct StreamingProcessFixture {
    let root: URL
    let manager: CondaManager
    init(script: String, mergeOutputIntoStderr: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("output-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("micromamba")
        try """
        #!/bin/sh
        if [ "$1" = '--version' ]; then echo 2.0.5-0; exit 0; fi
        \(mergeOutputIntoStderr ? "exec 1>&2" : "")
        \(script)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        manager = CondaManager(rootPrefix: root.appendingPathComponent("conda"),
            bundledMicromambaProvider: { executable }, bundledMicromambaVersionProvider: { "2.0.5-0" })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
