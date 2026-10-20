// MarkdupServiceSpawnPinTests.swift - Pins of the samtools spawns of MarkdupService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Lane 13.10, M0. Each test passes at the base, where `MarkdupService` starts samtools on a raw
/// `Process` and runs the four-stage pipeline through `/bin/sh -c`, and stays unchanged once the
/// spawns run on `ToolProcess`. A stand-in samtools logs the argv of every call, so each argv is
/// pinned byte for byte, along with the data flow from stage to stage and the words of each failure.
final class MarkdupServiceSpawnPinTests: XCTestCase {

    private struct Fixture {
        let root: URL
        let bam: URL
        let samtools: URL
        let log: URL
        var tempBam: String { bam.path + ".markdup.tmp" }
    }

    /// A folder with `bin/samtools` and a BAM that holds the bytes "ORIGINAL". The stand-in appends one line to
    /// its log for each call, `argv[0]` and every argument each followed by a unit separator, and then runs `body`.
    /// The BAM sits in a folder whose name holds a space, a dollar sign and quotes.
    private func makeFixture(body: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("markdup-spawn-pin-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let data = root.appendingPathComponent("data $dir \"q\"", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("calls.log")
        let samtools = bin.appendingPathComponent("samtools")
        try """
        #!/bin/sh
        { printf '%s\\037' "$0" "$@"; printf '\\n'; } >> "\(log.path)"
        \(body)
        exit 99
        """.write(to: samtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)
        let bam = data.appendingPathComponent("test.bam")
        try Data("ORIGINAL".utf8).write(to: bam)
        return Fixture(root: root, bam: bam, samtools: samtools, log: log)
    }

    private func loggedCalls(_ fixture: Fixture) throws -> [[String]] {
        let text = try String(contentsOf: fixture.log, encoding: .utf8)
        return text.split(separator: "\n").map { line in
            var parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            parts.removeLast()
            return parts
        }
    }

    /// Every call of a successful markdup, with the read counts 5 and 3.
    private static let successBody = """
    case "$1" in
      view)
        if [ "$2" = "-H" ]; then printf '@HD\\tVN:1.6\\n'; exit 0; fi
        if [ "$2" = "-c" ]; then if [ "$4" = "2308" ]; then echo 5; else echo 3; fi; exit 0; fi ;;
      sort)
        if [ "$2" = "-n" ]; then printf 'by-name\\n'; exit 0; fi
        cat; exit 0 ;;
      fixmate) cat; exit 0 ;;
      markdup) cat > "$3"; exit 0 ;;
      index) printf 'bai' > "$2.bai"; exit 0 ;;
    esac
    """

    /// The stand-in of a markdup in which stage `failing` (1 sort -n, 2 fixmate, 3 sort, 4 markdup) fails with
    /// a message of its own, after it read all its input. Every other stage passes its input on.
    private func failingStageBody(_ failing: [Int]) -> String {
        func stage(_ number: Int, _ pass: String) -> String {
            failing.contains(number)
                ? "cat >/dev/null; echo 'wrapper: stage \(number) failed' >&2; exit \(10 + number)"
                : pass
        }
        return """
        case "$1" in
          view) if [ "$2" = "-H" ]; then printf '@HD\\tVN:1.6\\n'; exit 0; fi ;;
          sort)
            if [ "$2" = "-n" ]; then
              \(failing.contains(1) ? "echo 'wrapper: stage 1 failed' >&2; exit 11" : "printf 'by-name\\n'; exit 0")
            fi
            \(stage(3, "cat; exit 0")) ;;
          fixmate) \(stage(2, "cat; exit 0")) ;;
          markdup) \(stage(4, "cat > \"$3\"; exit 0")) ;;
        esac
        """
    }

    private func assertUntouched(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: fixture.bam), Data("ORIGINAL".utf8), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tempBam), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.tempBam + ".bai"), file: file, line: line)
    }

    // MARK: - The pipeline

    func testAMarkdupRunStartsEachCallWithItsArgvAndPassesTheDataFromStageToStage() throws {
        let f = try makeFixture(body: Self.successBody)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let s = f.samtools.path
        let result = try MarkdupService.markdup(bamURL: f.bam, samtoolsPath: s)
        XCTAssertFalse(result.wasAlreadyMarkduped)
        XCTAssertEqual(result.totalReads, 5)
        XCTAssertEqual(result.duplicateReads, 2)

        let calls = try loggedCalls(f)
        XCTAssertEqual(calls.count, 8)
        XCTAssertEqual(calls[0], [s, "view", "-H", f.bam.path])
        // The four stages start together, so only their set is fixed.
        let stages = calls[1...4].sorted { $0.joined(separator: " ") < $1.joined(separator: " ") }
        let expectedStages: [[String]] = [
            [s, "fixmate", "-m", "-", "-"],
            [s, "markdup", "-", f.tempBam],
            [s, "sort", "-@", "4", "-"],
            [s, "sort", "-n", "-@", "4", f.bam.path],
        ]
        XCTAssertEqual(stages, expectedStages.sorted { $0.joined(separator: " ") < $1.joined(separator: " ") })
        XCTAssertEqual(calls[5], [s, "index", f.tempBam])
        XCTAssertEqual(calls[6], [s, "view", "-c", "-F", "2308", f.bam.path])
        XCTAssertEqual(calls[7], [s, "view", "-c", "-F", "3332", f.bam.path])

        // The BAM now holds what stage 1 wrote, after fixmate and the second sort passed it on to markdup.
        XCTAssertEqual(try Data(contentsOf: f.bam), Data("by-name\n".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.bam.path + ".bai")), Data("bai".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.tempBam))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.tempBam + ".bai"))
    }

    func testAThreadsArgumentReachesTheTwoSortStages() throws {
        let f = try makeFixture(body: Self.successBody)
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try MarkdupService.markdup(bamURL: f.bam, samtoolsPath: f.samtools.path, threads: 7, force: true)
        let calls = try loggedCalls(f)
        let s = f.samtools.path
        XCTAssertTrue(calls.contains([s, "sort", "-n", "-@", "7", f.bam.path]))
        XCTAssertTrue(calls.contains([s, "sort", "-@", "7", "-"]))
        XCTAssertFalse(calls.contains { $0.count > 1 && $0[1] == "view" && $0.contains("-H") }, "force skips the check")
    }

    func testAFailingStageFailsTheRunWithItsOwnWordsWhicheverStageItIs() throws {
        for stage in 1...4 {
            let f = try makeFixture(body: failingStageBody([stage]))
            defer { try? FileManager.default.removeItem(at: f.root) }
            XCTAssertThrowsError(try MarkdupService.markdup(bamURL: f.bam, samtoolsPath: f.samtools.path), "stage \(stage)") { error in
                guard case MarkdupError.pipelineFailed(let name, let stderr) = error else {
                    return XCTFail("stage \(stage): expected pipelineFailed, got \(error)")
                }
                XCTAssertEqual(name, "markdup-pipeline", "stage \(stage)")
                XCTAssertEqual(stderr, "wrapper: stage \(stage) failed\n", "stage \(stage)")
                XCTAssertEqual(
                    error.localizedDescription,
                    "markdup pipeline failed at stage 'markdup-pipeline': wrapper: stage \(stage) failed\n"
                )
            }
            try assertUntouched(f)
        }
    }

    func testTwoFailingStagesGiveTheirWordsInStageOrder() throws {
        let f = try makeFixture(body: failingStageBody([1, 3]))
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try MarkdupService.markdup(bamURL: f.bam, samtoolsPath: f.samtools.path)) { error in
            guard case MarkdupError.pipelineFailed(let name, let stderr) = error else {
                return XCTFail("expected pipelineFailed, got \(error)")
            }
            XCTAssertEqual(name, "markdup-pipeline")
            XCTAssertEqual(stderr, "wrapper: stage 1 failed\nwrapper: stage 3 failed\n")
        }
        try assertUntouched(f)
    }

    func testAnUnlaunchableSamtoolsFailsThePipelineAndLeavesTheBAM() throws {
        let f = try makeFixture(body: Self.successBody)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let missing = f.root.appendingPathComponent("bin/no-such-samtools").path
        XCTAssertThrowsError(try MarkdupService.markdup(bamURL: f.bam, samtoolsPath: missing)) { error in
            guard case MarkdupError.pipelineFailed = error else {
                return XCTFail("expected pipelineFailed, got \(error)")
            }
        }
        try assertUntouched(f)
    }

    // MARK: - The index

    func testAnIndexFailureAfterThePipelineIsReportedAndCleanedUp() throws {
        let f = try makeFixture(body: Self.successBody.replacingOccurrences(
            of: "index) printf 'bai' > \"$2.bai\"; exit 0 ;;",
            with: "index) echo 'index boom' >&2; exit 4 ;;"
        ))
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try MarkdupService.markdup(bamURL: f.bam, samtoolsPath: f.samtools.path)) { error in
            guard case MarkdupError.indexFailed(let stderr) = error else {
                return XCTFail("expected indexFailed, got \(error)")
            }
            XCTAssertEqual(stderr, "index boom\n")
            XCTAssertEqual(error.localizedDescription, "samtools index failed: index boom\n")
        }
        try assertUntouched(f)
    }

    func testAnAlreadyMarkedBAMWithNoIndexGetsOneAndKeepsItsBytes() throws {
        let marked = Self.successBody.replacingOccurrences(
            of: "printf '@HD\\tVN:1.6\\n'; exit 0; fi",
            with: "printf '@PG\\tID:samtools.3\\tPN:samtools\\tCL:samtools markdup - x\\n'; exit 0; fi"
        )
        let f = try makeFixture(body: marked)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let result = try MarkdupService.markdup(bamURL: f.bam, samtoolsPath: f.samtools.path)
        XCTAssertTrue(result.wasAlreadyMarkduped)
        XCTAssertEqual(result.totalReads, 5)
        XCTAssertEqual(result.duplicateReads, 2)
        let s = f.samtools.path
        XCTAssertEqual(try loggedCalls(f), [
            [s, "view", "-H", f.bam.path],
            [s, "index", f.bam.path],
            [s, "view", "-c", "-F", "2308", f.bam.path],
            [s, "view", "-c", "-F", "3332", f.bam.path],
        ])
        XCTAssertEqual(try Data(contentsOf: f.bam), Data("ORIGINAL".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: f.bam.path + ".bai")), Data("bai".utf8))
    }

    func testAnIndexThatFailsOnAnAlreadyMarkedBAMReportsItsStderr() throws {
        let f = try makeFixture(body: """
        case "$1" in
          view) printf '@PG\\tID:samtools.3\\tCL:samtools markdup - x\\n'; exit 0 ;;
          index) echo 'index boom' >&2; exit 4 ;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(try MarkdupService.markdup(bamURL: f.bam, samtoolsPath: f.samtools.path)) { error in
            guard case MarkdupError.indexFailed(let stderr) = error else {
                return XCTFail("expected indexFailed, got \(error)")
            }
            XCTAssertEqual(stderr, "index boom\n")
        }
    }

    // MARK: - The header check

    func testTheHeaderCheckReadsOnlyAZeroExitHeaderThatNamesMarkdup() throws {
        let marked = "printf '@PG\\tID:samtools.3\\tCL:samtools markdup - x\\n'"
        let cases: [(body: String, expected: Bool)] = [
            (marked + "; exit 0", true),
            ("printf '@HD\\tVN:1.6\\n'; exit 0", false),
            (marked + "; exit 3", false),
        ]
        for (body, expected) in cases {
            let f = try makeFixture(body: "case \"$1\" in view) \(body) ;; esac")
            defer { try? FileManager.default.removeItem(at: f.root) }
            XCTAssertEqual(MarkdupService.isAlreadyMarkduped(bamURL: f.bam, samtoolsPath: f.samtools.path), expected, body)
            XCTAssertEqual(try loggedCalls(f), [[f.samtools.path, "view", "-H", f.bam.path]])
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-samtools-\(UUID().uuidString)")
        XCTAssertFalse(MarkdupService.isAlreadyMarkduped(bamURL: URL(fileURLWithPath: "/tmp/x.bam"), samtoolsPath: missing.path))
    }

    // MARK: - The read count

    func testACountPassesItsFlagAndAccessionAndParsesTheNumber() throws {
        let f = try makeFixture(body: "case \"$1\" in view) printf ' 42 \\n'; exit 0 ;; esac")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let s = f.samtools.path
        XCTAssertEqual(try MarkdupService.countReads(bamURL: f.bam, accession: nil, flagFilter: 0x904, samtoolsPath: s), 42)
        XCTAssertEqual(try MarkdupService.countReads(bamURL: f.bam, accession: "", flagFilter: 0x404, samtoolsPath: s), 42)
        XCTAssertEqual(try MarkdupService.countReads(bamURL: f.bam, accession: "chr1", flagFilter: 4, samtoolsPath: s), 42)
        XCTAssertEqual(try loggedCalls(f), [
            [s, "view", "-c", "-F", "2308", f.bam.path],
            [s, "view", "-c", "-F", "1028", f.bam.path],
            [s, "view", "-c", "-F", "4", f.bam.path, "chr1"],
        ])
    }

    func testACountOfNonNumericOutputIsZero() throws {
        let f = try makeFixture(body: "case \"$1\" in view) printf 'not a number\\n'; exit 0 ;; esac")
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(try MarkdupService.countReads(bamURL: f.bam, accession: nil, flagFilter: 4, samtoolsPath: f.samtools.path), 0)
    }

    func testACountThatExitsNonzeroFailsAtTheCountStageWithItsStderr() throws {
        let f = try makeFixture(body: "case \"$1\" in view) echo 'count boom' >&2; exit 4 ;; esac")
        defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertThrowsError(
            try MarkdupService.countReads(bamURL: f.bam, accession: nil, flagFilter: 4, samtoolsPath: f.samtools.path)
        ) { error in
            guard case MarkdupError.pipelineFailed(let stage, let stderr) = error else {
                return XCTFail("expected pipelineFailed, got \(error)")
            }
            XCTAssertEqual(stage, "count")
            XCTAssertEqual(stderr, "count boom\n")
        }
    }

    func testACountOfAnUnlaunchableSamtoolsFailsAtTheCountStage() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-samtools-\(UUID().uuidString)")
        XCTAssertThrowsError(
            try MarkdupService.countReads(
                bamURL: URL(fileURLWithPath: "/tmp/x.bam"), accession: nil, flagFilter: 4, samtoolsPath: missing.path
            )
        ) { error in
            guard case MarkdupError.pipelineFailed(let stage, _) = error else {
                return XCTFail("expected pipelineFailed, got \(error)")
            }
            XCTAssertEqual(stage, "count")
        }
    }
}
