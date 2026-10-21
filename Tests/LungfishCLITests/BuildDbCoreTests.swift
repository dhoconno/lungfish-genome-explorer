// BuildDbCoreTests.swift - What the build-db cores hand a caller that runs them in process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// What `build-db esviritu` hands a caller that runs its core in process, such as the index step of the
/// analysis run executor (plan decision E6 of Phase 2.7), and what its command prints for the same run.
/// The fixture is `esviritu-mini` without its BAMs. A test that needs a BAM gives one sample a stand-in BAM
/// and runs a stand-in samtools, so no real tool runs.
final class BuildDbCoreTests: XCTestCase {
    /// The `esviritu-mini` sample that gets the stand-in BAM. Its detection table holds two detections.
    private static let sample = "SRR35517705"

    /// What the read count pass reports when markdup fails on the stand-in BAM.
    private static var markdupWarning: String {
        "  Warning: markdup failed on \(sample).third.filt.sorted.bam: samtools duplicate workflow failed: samtools exited with 1"
    }

    /// A failed markdup leaves an index whose unique read counts include duplicates, and the run goes on.
    /// The core reports it on `textWarning`, never on `text`, so a caller in process counts it as a warning
    /// of the run and not as a line of its log (review fix 1 of lane A7).
    func testAFailedMarkdupReachesTheCallerAsAWarning() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try esVirituResultWithStandInBAM(in: scratch)
        let samtools = try ManagedSamtoolsHome.makeStub(rootURL: scratch.root, namePrefix: "Home", script: Self.failingMarkdupSamtools)
        let recorder = SinkRecorder()

        let built = try await withHome(samtools.homeURL) {
            try await BuildDbCommand.EsVirituSubcommand.buildDatabase(
                in: result,
                options: BuildDbRunOptions(globalOptions: try GlobalOptions.parse([])),
                events: recorder.sink
            )
        }

        XCTAssertEqual(built.rowCount, 19)
        XCTAssertEqual(recorder.lines(on: .textWarning), [Self.markdupWarning], "The failed markdup is a warning")
        XCTAssertFalse(recorder.lines(on: .text).contains(Self.markdupWarning), "and never a line of text")
        XCTAssertEqual(recorder.lines(on: .warning), [], "It travels with the text, so it is not on warning")
    }

    /// Text mode prints the warning in its place among the human text on standard output, as it did before
    /// `textWarning`, and `--format json` prints the same lines on standard error.
    func testTextModeKeepsTheMarkdupWarningWithTheHumanText() async throws {
        let textScratch = try ImportStreamCapture.Scratch()
        defer { textScratch.remove() }
        let textSamtools = try ManagedSamtoolsHome.makeStub(rootURL: textScratch.root, namePrefix: "Home", script: Self.failingMarkdupSamtools)
        let text = try await withHome(textSamtools.homeURL) {
            try await BuildDbStreamCapture.run("build-db esviritu", try esVirituResultWithStandInBAM(in: textScratch), in: textScratch)
        }
        let jsonScratch = try ImportStreamCapture.Scratch()
        defer { jsonScratch.remove() }
        let jsonSamtools = try ManagedSamtoolsHome.makeStub(rootURL: jsonScratch.root, namePrefix: "Home", script: Self.failingMarkdupSamtools)
        let json = try await withHome(jsonSamtools.homeURL) {
            try await BuildDbStreamCapture.run(
                "build-db esviritu", try esVirituResultWithStandInBAM(in: jsonScratch), ["--format", "json"], in: jsonScratch
            )
        }

        XCTAssertNil(text.thrown)
        XCTAssertEqual(BuildDbStreamCapture.withoutFreedSize(text.standardOutput), [
            "Parsed 19 detection rows from EsViritu results",
            "Parsed 4000 coverage windows from EsViritu results",
            "Built esviritu.sqlite with 19 rows.",
            "Running markdup on 1 BAM file(s)...",
            Self.markdupWarning,
            "Counting reads per organism...",
            "  Updated read counts for 0/2 organisms, 2 left uncounted",
        ])
        XCTAssertEqual(text.standardError, [])
        XCTAssertNil(json.thrown)
        XCTAssertEqual(
            BuildDbStreamCapture.withoutFreedSize(json.standardError),
            BuildDbStreamCapture.withoutFreedSize(text.standardOutput),
            "--format json prints the text of text mode, the warning among it, on standard error"
        )
        XCTAssertFalse(json.standardOutput.contains { !$0.hasPrefix("{") }, "Standard output holds events only")
    }

    /// The analysis run executor writes the root record last, in phase P4, so its index step runs the core
    /// with `writesFolderRecord` false (risk R8, review fix 2 of lane A7). The core then leaves the result
    /// root without a record, still writes the sidecar of the database and still returns the run's record,
    /// whose last step is the database build.
    func testACoreThatWritesNoFolderRecordLeavesTheRootToTheExecutor() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)

        let built = try await BuildDbCommand.EsVirituSubcommand.buildDatabase(
            in: result,
            options: BuildDbRunOptions(globalOptions: try GlobalOptions.parse([]), writesFolderRecord: false),
            events: .silent
        )

        let fileManager = FileManager.default
        XCTAssertFalse(
            fileManager.fileExists(atPath: result.appendingPathComponent(".lungfish-provenance.json").path),
            "The root holds no record until the executor writes it"
        )
        XCTAssertTrue(fileManager.fileExists(atPath: result.appendingPathComponent("esviritu.sqlite.lungfish-provenance.json").path))
        XCTAssertEqual(built.record?.steps.last?.toolName, "lungfish build-db esviritu")
    }

    // MARK: Fixtures

    /// A stand-in samtools that reports no `samtools markdup` in a BAM header, fails every other command
    /// but `view -c` with exit 1 and nothing on standard error, and counts two reads.
    private static let failingMarkdupSamtools = """
    #!/bin/sh
    case "$1" in
      --version) echo "samtools 1.21" ;;
      view)
        case "$2" in
          -H) printf '@HD\\tVN:1.6\\n' ;;
          -c) echo 2 ;;
        esac ;;
      *) exit 1 ;;
    esac
    exit 0
    """

    /// `esviritu-mini` without its BAMs, and one stand-in BAM in the `_temp` folder of `sample`, where
    /// EsViritu leaves it, so the rows of that sample name it.
    private func esVirituResultWithStandInBAM(in scratch: ImportStreamCapture.Scratch) throws -> URL {
        let result = try BuildDbStreamCapture.esVirituResultWithoutBAMs(in: scratch)
        let temp = result.appendingPathComponent("\(Self.sample)/\(Self.sample)_temp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("BAM".utf8).write(to: temp.appendingPathComponent("\(Self.sample).third.filt.sorted.bam"))
        return result
    }

    /// Runs `body` with `HOME` at `home`, where `build-db` finds its managed samtools.
    private func withHome<T>(_ home: URL, _ body: () async throws -> T) async throws -> T {
        let original = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let original { setenv("HOME", original, 1) } else { unsetenv("HOME") }
        }
        return try await body()
    }
}

/// A sink that keeps each line by the channel it arrived on.
private final class SinkRecorder: @unchecked Sendable {
    enum Channel { case text, textWarning, warning }

    private let lock = NSLock()
    private var storage: [(channel: Channel, line: String)] = []

    var sink: BuildDbEventSink {
        BuildDbEventSink(
            progress: { _, _ in },
            text: { self.append(.text, $0) },
            textWarning: { self.append(.textWarning, $0) },
            warning: { self.append(.warning, $0) }
        )
    }

    func lines(on channel: Channel) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.filter { $0.channel == channel }.map(\.line)
    }

    private func append(_ channel: Channel, _ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append((channel, line))
    }
}
