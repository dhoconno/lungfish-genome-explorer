// MappingSummaryBuilderSpawnPinTests.swift - Pins of the four samtools spawns of MappingSummaryBuilder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
import CryptoKit
import LungfishCore
@testable import LungfishWorkflow

/// Lane 13.10, M0. Each test passes at the base, where the builder starts samtools on a raw
/// `Process`, and stays unchanged once the spawns run on `ToolProcess`. A stand-in samtools logs
/// the working directory and the argv of every call, so the table, each argv byte for byte, the
/// directory a spawn runs in and the words of each failure are pinned without a real samtools.
final class MappingSummaryBuilderSpawnPinTests: XCTestCase {

    private struct Fixture {
        let root: URL
        let bam: URL
        let log: URL

        var runner: NativeToolRunner {
            NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .preview)
        }
    }

    /// A temporary home whose managed samtools logs `cwd|argv` and then runs `body`.
    private func makeFixture(body: String, shebang: String = "#!/bin/bash") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-summary-pin-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("samtools.log")
        let samtools = bin.appendingPathComponent("samtools")
        try """
        \(shebang)
        echo "$PWD|$*" >> "\(log.path)"
        \(body)
        exit 93
        """.write(to: samtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtools.path)
        let bam = root.appendingPathComponent("input.bam")
        try Data().write(to: bam)
        return Fixture(root: root, bam: bam, log: log)
    }

    /// A script for the direct calls of the two process functions.
    private func makeScript(_ body: String) throws -> (root: URL, script: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-summary-pin-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("stand-in.sh")
        try "#!/bin/bash\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (root, script)
    }

    private func tokenized(_ text: String, root: URL) -> String {
        // bash prints the physical folder, /private/var/..., where the URL says /var/...
        text.replacingOccurrences(of: "/private" + root.path, with: "<ROOT>")
            .replacingOccurrences(of: root.path, with: "<ROOT>")
            .replacingOccurrences(
                of: "[^ ]*lungfish-read-groups-[0-9A-Fa-f-]+\\.txt",
                with: "<LIST>",
                options: .regularExpression
            )
    }

    /// The stand-in's log, one line per call, the folder and the read-group list replaced by tokens
    /// and the lines sorted, since the two stages of a pipe start in no fixed order.
    private func loggedCalls(_ fixture: Fixture) throws -> [String] {
        let text = try String(contentsOf: fixture.log, encoding: .utf8)
        return text.split(separator: "\n").map { tokenized(String($0), root: fixture.root) }.sorted()
    }

    private func assertRow(
        _ row: MappingContigSummary, _ name: String, length: Int, reads: Int, percent: Double,
        depth: Double, breadth: Double, mapq: Double, identity: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(row.contigName, name, file: file, line: line)
        XCTAssertEqual(row.contigLength, length, name, file: file, line: line)
        XCTAssertEqual(row.mappedReads, reads, name, file: file, line: line)
        XCTAssertEqual(row.mappedReadPercent, percent, accuracy: 1e-9, name, file: file, line: line)
        XCTAssertEqual(row.meanDepth, depth, accuracy: 1e-9, name, file: file, line: line)
        XCTAssertEqual(row.coverageBreadth, breadth, accuracy: 1e-9, name, file: file, line: line)
        XCTAssertEqual(row.medianMAPQ, mapq, accuracy: 1e-9, name, file: file, line: line)
        XCTAssertEqual(row.meanIdentity, identity, accuracy: 1e-9, name, file: file, line: line)
    }

    private func kind(_ error: Error) -> String {
        if error is CancellationError { return "cancellation" }
        if error is MappingSummaryBuilderError { return "samtools failure" }
        return "other"
    }

    private static let coverageHeader = "'#rname\\tstartpos\\tendpos\\tnumreads\\tcovbases\\tcoverage\\tmeandepth\\tmeanbaseq\\tmeanmapq\\n'"

    /// Three references. chr1 has three primary reads, chr2 no record at all, chr3 a secondary one.
    private static let unfilteredBody = """
    if [[ "$1" == "coverage" && "$2" == "--ff" ]]; then
      printf \(coverageHeader)
      printf 'chr1\\t1\\t100\\t3\\t60\\t60.0\\t0.6\\t30\\t40\\n'
      printf 'chr2\\t1\\t200\\t0\\t0\\t0.0\\t0.0\\t0\\t0\\n'
      printf 'chr3\\t1\\t300\\t0\\t0\\t0.0\\t0.0\\t0\\t0\\n'
      exit 0
    fi
    if [[ "$1" == "view" ]]; then
      printf 'r1\\t0\\tchr1\\t1\\t60\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:0\\n'
      printf 'r2\\t0\\tchr1\\t5\\t40\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:1\\n'
      printf 'r3\\t0\\tchr1\\t9\\t20\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:2\\n'
      printf 'r4\\t256\\tchr3\\t1\\t0\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:0\\n'
      exit 0
    fi
    """

    /// The read-group path: `view -c` is the denominator, `view -h` feeds `coverage -` and `view -R` the metrics.
    private static let readGroupBody = """
    if [[ "$1 $2" == "view -c" ]]; then echo 4; exit 0; fi
    if [[ "$1 $2" == "view -h" ]]; then
      printf '@HD\\tVN:1.6\\n'
      printf 'r1\\t0\\tchr1\\t1\\t60\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:0\\n'
      exit 0
    fi
    if [[ "$1 $2" == "view -R" ]]; then
      printf 'r1\\t0\\tchr1\\t1\\t60\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:0\\n'
      printf 'r2\\t0\\tchr1\\t5\\t40\\t10M\\t*\\t0\\t0\\tAAAAAAAAAA\\t*\\tNM:i:2\\n'
      exit 0
    fi
    if [[ "$1 $2" == "coverage -" ]]; then
      cat >/dev/null
      printf \(coverageHeader)
      printf 'chr1\\t1\\t100\\t2\\t20\\t20.0\\t0.2\\t30\\t50\\n'
      exit 0
    fi
    """

    // MARK: - The table and the argv of each pass

    func testTheUnfilteredPathReturnsEveryCoverageRowWithItsViewMetrics() async throws {
        let f = try makeFixture(body: Self.unfilteredBody)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let table = try await MappingSummaryBuilder.build(
            sortedBAMURL: f.bam, totalReads: 10, runner: f.runner, timeout: 300
        )
        XCTAssertEqual(table.referenceCount, 3)
        XCTAssertEqual(table.unalignedReferenceCount, 0)
        XCTAssertEqual(table.rows.count, 3)
        assertRow(table.rows[0], "chr1", length: 100, reads: 3, percent: 30, depth: 0.6, breadth: 0.6, mapq: 40, identity: 0.9)
        assertRow(table.rows[1], "chr2", length: 200, reads: 0, percent: 0, depth: 0, breadth: 0, mapq: 0, identity: 0)
        assertRow(table.rows[2], "chr3", length: 300, reads: 0, percent: 0, depth: 0, breadth: 0, mapq: 0, identity: 1)
        XCTAssertEqual(try loggedCalls(f), [
            "<ROOT>|coverage --ff UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP <ROOT>/input.bam",
            "<ROOT>|view <ROOT>/input.bam",
        ])
    }

    /// BIO 4 of the 13.16 M2 review. The mapping golden masks every digest, so it cannot show which file
    /// the pass hashed. This test hashes the two files itself with CryptoKit and FileManager, and holds
    /// both recorded steps to those values and each step's argv to the line its spawn logged.
    func testTheRecordedStepsHoldTheArgvAndTheDigestsOfTheSpawnsThatRan() async throws {
        let f = try makeFixture(body: Self.unfilteredBody)
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Two files of different bytes and sizes, so a swapped or a wrong file cannot give the expected pair.
        try Data("a stand-in for the sorted BAM, which no spawn here reads".utf8).write(to: f.bam)
        let index = URL(fileURLWithPath: f.bam.path + ".bai")
        try Data("a stand-in index".utf8).write(to: index)
        let expected = try [f.bam, index].map { url -> (sha256: String, size: UInt64) in
            let digest = CryptoKit.SHA256.hash(data: try Data(contentsOf: url))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap((attributes[.size] as? NSNumber)?.uint64Value, url.lastPathComponent)
            return (digest.map { String(format: "%02x", $0) }.joined(), size)
        }
        XCTAssertNotEqual(expected[0].sha256, expected[1].sha256)
        XCTAssertNotEqual(expected[0].size, expected[1].size)
        let version = "1.24 (stand-in)"

        let result = try await MappingSummaryBuilder.buildRecordingSteps(
            sortedBAMURL: f.bam, indexURL: index, totalReads: 10, toolVersion: version, runner: f.runner, timeout: 300
        )
        let table = result.table
        XCTAssertEqual(table.referenceCount, 3)
        XCTAssertEqual(table.rows.count, 3)
        guard table.rows.count == 3 else { return XCTFail("three rows expected, got \(table.rows.count)") }
        assertRow(table.rows[0], "chr1", length: 100, reads: 3, percent: 30, depth: 0.6, breadth: 0.6, mapq: 40, identity: 0.9)
        assertRow(table.rows[1], "chr2", length: 200, reads: 0, percent: 0, depth: 0, breadth: 0, mapq: 0, identity: 0)
        assertRow(table.rows[2], "chr3", length: 300, reads: 0, percent: 0, depth: 0, breadth: 0, mapq: 0, identity: 1)

        let steps = result.steps
        guard steps.count == 2 else { return XCTFail("two steps expected, got \(steps.count)") }
        XCTAssertEqual(
            Array(steps[0].command.dropFirst()), ["coverage", "--ff", "UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP", f.bam.path]
        )
        XCTAssertEqual(Array(steps[1].command.dropFirst()), ["view", f.bam.path])
        let samtools = try await f.runner.findTool(.samtools).path
        for step in steps {
            let label = step.command.joined(separator: " ")
            XCTAssertEqual(step.command.first, samtools, label)
            // The BAM first with its role and format, then the index.
            XCTAssertEqual(step.inputs.map { ($0.path as NSString).lastPathComponent }, ["input.bam", "input.bam.bai"], label)
            XCTAssertEqual(step.inputs.map(\.role), [.input, .index], label)
            XCTAssertEqual(step.inputs.first?.format, .bam, label)
            XCTAssertEqual(step.inputs.map(\.sha256), expected.map { Optional($0.sha256) }, label)
            XCTAssertEqual(step.inputs.map(\.sizeBytes), expected.map { Optional($0.size) }, label)
            XCTAssertTrue(step.outputs.isEmpty, label)
            XCTAssertEqual(step.exitCode, 0, label)
            XCTAssertEqual(step.stdoutReadInProcess, true, label)
            XCTAssertEqual(step.toolVersion, version, label)
            let end = try XCTUnwrap(step.endTime, label)
            XCTAssertLessThanOrEqual(step.startTime, end, label)
        }
        let coverageEnd = try XCTUnwrap(steps[0].endTime)
        XCTAssertLessThanOrEqual(coverageEnd, steps[1].startTime)

        // The step and the spawn come from one argv, so each step's argv is the line its spawn logged.
        let logged = try loggedCalls(f)
        XCTAssertEqual(logged, [
            "<ROOT>|coverage --ff UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP <ROOT>/input.bam",
            "<ROOT>|view <ROOT>/input.bam",
        ])
        let fromSteps = steps.map { "<ROOT>|" + tokenized($0.command.dropFirst().joined(separator: " "), root: f.root) }
        XCTAssertEqual(fromSteps.sorted(), logged)
    }

    func testTheUnfilteredPathLeavesOutOnlyAReferenceNoRecordNames() async throws {
        let f = try makeFixture(body: Self.unfilteredBody)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let table = try await MappingSummaryBuilder.build(
            sortedBAMURL: f.bam, totalReads: 10, runner: f.runner, timeout: 300,
            includeUnmappedReferenceRows: false
        )
        XCTAssertEqual(table.rows.map(\.contigName), ["chr1", "chr3"])
        XCTAssertEqual(table.referenceCount, 3)
        XCTAssertEqual(table.unalignedReferenceCount, 1)
    }

    func testTheReadGroupPathReturnsTheTableAndRunsEachPassWithItsArgvInTheBAMFolder() async throws {
        let f = try makeFixture(body: Self.readGroupBody)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let table = try await MappingSummaryBuilder.build(
            sortedBAMURL: f.bam, totalReads: 99, readGroupIDs: ["S1-A", "S1-B"], runner: f.runner, timeout: 300
        )
        XCTAssertEqual(table.referenceCount, 1)
        XCTAssertEqual(table.unalignedReferenceCount, 0)
        assertRow(table.rows[0], "chr1", length: 100, reads: 2, percent: 50, depth: 0.2, breadth: 0.2, mapq: 50, identity: 0.9)
        let primary = "SECONDARY,SUPPLEMENTARY,QCFAIL,DUP"
        XCTAssertEqual(try loggedCalls(f), [
            "<ROOT>|coverage -",
            "<ROOT>|view -R <LIST> <ROOT>/input.bam",
            "<ROOT>|view -c -F \(primary) -R <LIST> <ROOT>/input.bam",
            "<ROOT>|view -h -F UNMAP,\(primary) -R <LIST> <ROOT>/input.bam",
        ].sorted())
    }

    // MARK: - The words of each failure

    func testACoverageThatExitsNonzeroFailsTheReadGroupPipeWithItsOwnStderr() async throws {
        let f = try makeFixture(body: """
        if [[ "$1 $2" == "view -h" ]]; then printf '@HD\\tVN:1.6\\n'; exit 0; fi
        if [[ "$1 $2" == "coverage -" ]]; then cat >/dev/null; echo 'coverage boom' >&2; exit 5; fi
        """)
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            _ = try await MappingSummaryBuilder.build(
                sortedBAMURL: f.bam, totalReads: 99, readGroupIDs: ["S1-A"], runner: f.runner, timeout: 300
            )
            XCTFail("a coverage that exits 5 succeeded")
        } catch let error as MappingSummaryBuilderError {
            guard case .samtoolsCoverageFailed(let detail) = error else {
                return XCTFail("expected a coverage failure, got \(error.localizedDescription)")
            }
            XCTAssertEqual(detail, "coverage boom\n")
            XCTAssertEqual(error.localizedDescription, "samtools coverage failed: coverage boom\n")
        }
    }

    func testAViewAndACoverageThatBothFailReportTheView() async throws {
        let f = try makeFixture(body: """
        if [[ "$1 $2" == "view -h" ]]; then echo 'view boom' >&2; exit 94; fi
        if [[ "$1 $2" == "coverage -" ]]; then cat >/dev/null; echo 'coverage boom' >&2; exit 5; fi
        """)
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            _ = try await MappingSummaryBuilder.build(
                sortedBAMURL: f.bam, totalReads: 99, readGroupIDs: ["S1-A"], runner: f.runner, timeout: 300
            )
            XCTFail("a view that exits 94 succeeded")
        } catch let error as MappingSummaryBuilderError {
            guard case .samtoolsViewFailed(let detail) = error else {
                return XCTFail("expected a view failure, got \(error.localizedDescription)")
            }
            XCTAssertEqual(detail, "view boom\n")
            XCTAssertEqual(error.localizedDescription, "samtools view failed: view boom\n")
        }
    }

    func testACapturedViewThatExitsNonzeroFailsWithItsStderr() async throws {
        let (root, script) = try makeScript("echo 'cap boom' >&2\nexit 7")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await MappingSummaryBuilder.runProcessCapturingOutput(
                executableURL: script, arguments: [], workingDirectory: root, timeout: 300
            )
            XCTFail("a view that exits 7 succeeded")
        } catch let error as MappingSummaryBuilderError {
            guard case .samtoolsViewFailed(let detail) = error else {
                return XCTFail("expected a view failure, got \(error.localizedDescription)")
            }
            XCTAssertEqual(detail, "cap boom\n")
            XCTAssertEqual(error.localizedDescription, "samtools view failed: cap boom\n")
        }
    }

    func testAStreamedViewThatExitsNonzeroFailsWithItsStderr() async throws {
        let (root, script) = try makeScript("echo 'stream boom' >&2\nexit 9")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await MappingSummaryBuilder.runProcessStreamingOutput(
                executableURL: script, arguments: [], workingDirectory: root, timeout: 300, consumeStdout: { _ in }
            )
            XCTFail("a view that exits 9 succeeded")
        } catch let error as MappingSummaryBuilderError {
            guard case .samtoolsViewFailed(let detail) = error else {
                return XCTFail("expected a view failure, got \(error.localizedDescription)")
            }
            XCTAssertEqual(detail, "stream boom\n")
        }
    }

    func testACapturedAndAStreamedViewPastTheirLimitEndAsACancellation() async throws {
        let (root, script) = try makeScript("exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        do {
            _ = try await MappingSummaryBuilder.runProcessCapturingOutput(
                executableURL: script, arguments: [], workingDirectory: root, timeout: 1
            )
            XCTFail("a view that sleeps 30 seconds finished within a 1 second limit")
        } catch is CancellationError {
            // A timeout ends this spawn as a cancellation, not as a samtools failure.
        }
        do {
            try await MappingSummaryBuilder.runProcessStreamingOutput(
                executableURL: script, arguments: [], workingDirectory: root, timeout: 1, consumeStdout: { _ in }
            )
            XCTFail("a streamed view that sleeps 30 seconds finished within a 1 second limit")
        } catch is CancellationError {
            // Same for the streamed read.
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 25, "a sleeping view was not stopped")
    }

    func testALaunchFailureIsNeitherACancellationNorASamtoolsFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-summary-pin-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("no-such-samtools")
        var kinds: [String] = []
        do {
            _ = try await MappingSummaryBuilder.runProcessCapturingOutput(
                executableURL: missing, arguments: ["view"], workingDirectory: root, timeout: 300
            )
        } catch { kinds.append(kind(error)) }
        do {
            try await MappingSummaryBuilder.runProcessStreamingOutput(
                executableURL: missing, arguments: ["view"], workingDirectory: root, timeout: 300, consumeStdout: { _ in }
            )
        } catch { kinds.append(kind(error)) }
        let f = try makeFixture(body: "", shebang: "#!/nonexistent/interpreter")
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            _ = try await MappingSummaryBuilder.build(
                sortedBAMURL: f.bam, totalReads: 99, readGroupIDs: ["S1-A"], runner: f.runner, timeout: 300
            )
        } catch { kinds.append(kind(error)) }
        XCTAssertEqual(kinds, ["other", "other", "other"])
    }

    // MARK: - What each process function passes and returns

    func testACapturedViewRunsInItsFolderWithEachArgumentWhole() async throws {
        let (root, script) = try makeScript("printf '%s|' \"$PWD\"\nprintf '%s;' \"$@\"")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = try await MappingSummaryBuilder.runProcessCapturingOutput(
            executableURL: script, arguments: ["view", "-c", "a b"], workingDirectory: root, timeout: 300
        )
        XCTAssertEqual(tokenized(output, root: root), "<ROOT>|view;-c;a b;")
    }

    func testAStreamedViewDeliversEveryByteInOrderDespiteLargeStderr() async throws {
        let (root, script) = try makeScript("""
        head -c 300000 /dev/zero | tr '\\0' 'e' >&2
        /usr/bin/seq 1 200000
        printf 'tail without newline'
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = OSAllocatedUnfairLock(initialState: Data())
        try await MappingSummaryBuilder.runProcessStreamingOutput(
            executableURL: script, arguments: [], workingDirectory: root, timeout: 300,
            consumeStdout: { chunk in sink.withLock { $0.append(chunk) } }
        )
        let expected = (1...200_000).map(String.init).joined(separator: "\n") + "\ntail without newline"
        XCTAssertEqual(sink.withLock { $0 }, Data(expected.utf8))
    }

    func testAStreamedViewRunsInItsFolderWithEachArgumentWhole() async throws {
        let (root, script) = try makeScript("printf '%s|' \"$PWD\"\nprintf '%s;' \"$@\"")
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = OSAllocatedUnfairLock(initialState: Data())
        try await MappingSummaryBuilder.runProcessStreamingOutput(
            executableURL: script, arguments: ["view", "-R", "a b"], workingDirectory: root, timeout: 300,
            consumeStdout: { chunk in sink.withLock { $0.append(chunk) } }
        )
        let text = String(decoding: sink.withLock { $0 }, as: UTF8.self)
        XCTAssertEqual(tokenized(text, root: root), "<ROOT>|view;-R;a b;")
    }
}
