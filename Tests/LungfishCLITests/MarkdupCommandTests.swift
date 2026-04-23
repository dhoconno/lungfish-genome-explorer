// MarkdupCommandTests.swift - Integration tests for lungfish-cli markdup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO

final class MarkdupCommandTests: XCTestCase {
    private typealias MarkdupRuntime = MarkdupCommand.Runtime

    private struct MarkdupJSONOutput: Decodable, Equatable {
        struct Result: Decodable, Equatable {
            let bamPath: String
            let wasAlreadyMarkduped: Bool
            let totalReads: Int
            let duplicateReads: Int
            let durationSeconds: Double
        }

        let processedBAMs: Int
        let alreadyMarkedBAMs: Int
        let totalReads: Int
        let duplicateReads: Int
        let elapsedSeconds: Double
        let results: [Result]
    }

    private func makeManagedSamtoolsHome() throws -> (home: URL, samtoolsPath: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("MarkdupManagedHome-\(UUID().uuidString)", isDirectory: true)
        let samtoolsPath = home
            .appendingPathComponent(".lungfish/conda/envs/samtools/bin/samtools", isDirectory: false)
        try fm.createDirectory(at: samtoolsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        #!/bin/sh
        exit 0
        """.write(to: samtoolsPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsPath.path)
        return (home, samtoolsPath)
    }

    private func makeFunctionalManagedSamtoolsHome() throws -> (home: URL, samtoolsPath: URL) {
        let fixture = try makeManagedSamtoolsHome()
        try writeScriptedSamtools(at: fixture.samtoolsPath)
        return fixture
    }

    private func writeScriptedSamtools(at samtoolsPath: URL) throws {
        try """
        #!/bin/sh
        set -eu

        cmd="${1:-}"
        if [ $# -gt 0 ]; then
          shift
        fi

        case "$cmd" in
          sort)
            output=""
            input="-"
            while [ $# -gt 0 ]; do
              case "$1" in
                -o)
                  output="$2"
                  shift 2
                  ;;
                -@)
                  shift 2
                  ;;
                -n|-m)
                  shift
                  ;;
                -)
                  input="-"
                  shift
                  ;;
                *)
                  input="$1"
                  shift
                  ;;
              esac
            done
            if [ -n "$output" ]; then
              if [ "$input" = "-" ]; then
                cat > "$output"
              else
                cat "$input" > "$output"
              fi
            else
              if [ "$input" = "-" ]; then
                cat
              else
                cat "$input"
              fi
            fi
            ;;
          fixmate)
            cat
            ;;
          markdup)
            input="${1:--}"
            output="${2:?missing output path}"
            {
              printf '@PG\\tID:samtools.markdup\\tCL:samtools markdup\\n'
              if [ "$input" = "-" ]; then
                cat
              else
                cat "$input"
              fi
            } > "$output"
            ;;
          index)
            : > "$1.bai"
            ;;
          view)
            header=0
            count=0
            while [ $# -gt 0 ]; do
              case "$1" in
                -H)
                  header=1
                  shift
                  ;;
                -c)
                  count=1
                  shift
                  ;;
                -F)
                  shift 2
                  ;;
                *)
                  bam="$1"
                  shift
                  ;;
              esac
            done
            if [ "${header:-0}" -eq 1 ]; then
              printf '@HD\\tVN:1.6\\tSO:coordinate\\n'
              if [ -n "${bam:-}" ] && [ -f "$bam" ] && /usr/bin/grep -aq 'samtools markdup' "$bam"; then
                printf '@PG\\tID:samtools.markdup\\tCL:samtools markdup\\n'
              fi
              exit 0
            fi
            if [ "${count:-0}" -eq 1 ]; then
              if [ -n "${bam:-}" ] && [ -f "$bam" ] && /usr/bin/grep -aq 'samtools markdup' "$bam"; then
                echo 4
              else
                echo 5
              fi
              exit 0
            fi
            exit 1
            ;;
          *)
            exit 1
            ;;
        esac
        """.write(to: samtoolsPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsPath.path)
    }

    private func withHomeDirectory<T>(_ home: URL, perform block: () async throws -> T) async throws -> T {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
        }
        return try await block()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdupCliTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSyntheticBam(at url: URL, samtools: String) throws {
        let refs = [BamFixtureBuilder.Reference(name: "chr1", length: 1000)]
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        let reads = (0..<5).map { i in
            BamFixtureBuilder.Read(
                qname: "r\(i)", flag: 0, rname: "chr1",
                pos: 100, mapq: 60, cigar: "50M", seq: seq, qual: qual
            )
        }
        try BamFixtureBuilder.makeBAM(at: url, references: refs, reads: reads, samtoolsPath: samtools)
    }

    // MARK: - Tests

    func testCliMarkdupSingleBAM() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try MarkdupCommand.parse([bamURL.path, "-q"])
            try await cmd.run()
        }

        XCTAssertTrue(
            MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtools),
            "BAM should be marked after CLI run"
        )
    }

    func testCliBamMarkdupSingleBAM() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try BAMCommand.MarkdupSubcommand.parse(["markdup", bamURL.path, "-q"])
            try await cmd.run()
        }

        XCTAssertTrue(
            MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtools),
            "BAM should be marked after CLI run"
        )
    }

    func testCliMarkdupDirectory() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bam1 = dir.appendingPathComponent("a.bam")
        let bam2 = dir.appendingPathComponent("sub/b.bam")
        try makeSyntheticBam(at: bam1, samtools: samtools)
        try makeSyntheticBam(at: bam2, samtools: samtools)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try MarkdupCommand.parse([dir.path, "-q"])
            try await cmd.run()
        }

        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bam1, samtoolsPath: samtools))
        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bam2, samtoolsPath: samtools))
    }

    func testCliMarkdupSkipsAlreadyMarked() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)

        try await withHomeDirectory(managedHome.home) {
            let cmd1 = try MarkdupCommand.parse([bamURL.path, "-q"])
            try await cmd1.run()
        }
        let firstMtime = (try? FileManager.default.attributesOfItem(atPath: bamURL.path)[.modificationDate]) as? Date

        try await Task.sleep(nanoseconds: 1_100_000_000)

        try await withHomeDirectory(managedHome.home) {
            let cmd2 = try MarkdupCommand.parse([bamURL.path, "-q"])
            try await cmd2.run()
        }
        let secondMtime = (try? FileManager.default.attributesOfItem(atPath: bamURL.path)[.modificationDate]) as? Date

        XCTAssertEqual(firstMtime, secondMtime, "File should not be rewritten on second run")
    }

    func testCliMarkdupForceReruns() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)

        try await withHomeDirectory(managedHome.home) {
            let cmd1 = try MarkdupCommand.parse([bamURL.path, "-q"])
            try await cmd1.run()
        }
        let firstMtime = (try? FileManager.default.attributesOfItem(atPath: bamURL.path)[.modificationDate]) as? Date

        try await Task.sleep(nanoseconds: 1_100_000_000)

        try await withHomeDirectory(managedHome.home) {
            let cmd2 = try MarkdupCommand.parse([bamURL.path, "--force", "-q"])
            try await cmd2.run()
        }
        let secondMtime = (try? FileManager.default.attributesOfItem(atPath: bamURL.path)[.modificationDate]) as? Date

        XCTAssertNotEqual(firstMtime, secondMtime, "File SHOULD be rewritten on forced re-run")
    }

    func testCliMarkdupErrorsOnMissingFile() async throws {
        let cmd = try MarkdupCommand.parse(["/nonexistent/path.bam"])
        do {
            try await cmd.run()
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
    }

    func testBamMarkdupSubcommandUsesSameWorkflowAsLegacyCommand() async throws {
        let expectedInputURL = URL(fileURLWithPath: "/tmp/input.bam")
        let expectedResult = MarkdupResult(
            bamURL: expectedInputURL,
            wasAlreadyMarkduped: false,
            totalReads: 12,
            duplicateReads: 3,
            durationSeconds: 0.75
        )

        actor CallLog {
            private(set) var invocations: [(path: String, force: Bool, sortThreads: Int, quiet: Bool)] = []

            func record(path: String, force: Bool, sortThreads: Int, quiet: Bool) {
                invocations.append((path, force, sortThreads, quiet))
            }

            func snapshot() -> [(path: String, force: Bool, sortThreads: Int, quiet: Bool)] {
                invocations
            }
        }

        let callLog = CallLog()
        let runtime = MarkdupRuntime(
            execute: { input, emit in
                await callLog.record(
                    path: input.path,
                    force: input.force,
                    sortThreads: input.sortThreads,
                    quiet: input.quiet
                )
                emit("Processed 1 BAM file(s) (0 already marked)")
                emit("Total reads: 12, duplicates: 3")
                emit("Elapsed: 0.8s")
                return [expectedResult]
            }
        )

        let legacyCommand = try MarkdupCommand.parse([
            expectedInputURL.path,
            "--force",
            "--sort-threads", "7",
        ])
        let canonicalCommand = try BAMCommand.MarkdupSubcommand.parse([
            "markdup",
            expectedInputURL.path,
            "--force",
            "--sort-threads", "7",
        ])

        var legacyOutput: [String] = []
        _ = try await legacyCommand.executeForTesting(runtime: runtime) { legacyOutput.append($0) }

        var canonicalOutput: [String] = []
        _ = try await canonicalCommand.executeForTesting(runtime: runtime) { canonicalOutput.append($0) }

        let calls = await callLog.snapshot()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.path), [expectedInputURL.path, expectedInputURL.path])
        XCTAssertEqual(calls.map(\.force), [true, true])
        XCTAssertEqual(calls.map(\.sortThreads), [7, 7])
        XCTAssertEqual(calls.map(\.quiet), [false, false])
        XCTAssertEqual(canonicalOutput, legacyOutput)
    }

    func testLegacyMarkdupJSONOutputUsesStructuredSummary() async throws {
        let resultURL = URL(fileURLWithPath: "/tmp/legacy-json.bam")
        let runtime = MarkdupRuntime(
            execute: { _, _ in
                [
                    MarkdupResult(
                        bamURL: resultURL,
                        wasAlreadyMarkduped: true,
                        totalReads: 42,
                        duplicateReads: 9,
                        durationSeconds: 1.25
                    )
                ]
            }
        )
        let command = try MarkdupCommand.parse([
            resultURL.path,
            "--format", "json",
        ])

        var output: [String] = []
        _ = try await command.executeForTesting(runtime: runtime) { output.append($0) }

        XCTAssertEqual(output.count, 1)
        XCTAssertFalse(output[0].contains("Processed 1 BAM file"))

        let summary = try XCTUnwrap(decodeMarkdupJSONOutput(output[0]))
        XCTAssertEqual(summary.processedBAMs, 1)
        XCTAssertEqual(summary.alreadyMarkedBAMs, 1)
        XCTAssertEqual(summary.totalReads, 42)
        XCTAssertEqual(summary.duplicateReads, 9)
        XCTAssertEqual(summary.elapsedSeconds, 1.25)
        XCTAssertEqual(summary.results.map(\.bamPath), [resultURL.path])
    }

    func testCanonicalBamMarkdupJSONOutputMatchesLegacyShape() async throws {
        let resultURL = URL(fileURLWithPath: "/tmp/canonical-json.bam")
        let runtime = MarkdupRuntime(
            execute: { _, _ in
                [
                    MarkdupResult(
                        bamURL: resultURL,
                        wasAlreadyMarkduped: false,
                        totalReads: 64,
                        duplicateReads: 7,
                        durationSeconds: 2.5
                    )
                ]
            }
        )
        let legacyCommand = try MarkdupCommand.parse([
            resultURL.path,
            "--format", "json",
        ])
        let canonicalCommand = try BAMCommand.MarkdupSubcommand.parse([
            "markdup",
            resultURL.path,
            "--format", "json",
        ])

        var legacyOutput: [String] = []
        _ = try await legacyCommand.executeForTesting(runtime: runtime) { legacyOutput.append($0) }

        var canonicalOutput: [String] = []
        _ = try await canonicalCommand.executeForTesting(runtime: runtime) { canonicalOutput.append($0) }

        XCTAssertEqual(canonicalOutput.count, 1)
        XCTAssertEqual(legacyOutput.count, 1)

        let legacySummary = try XCTUnwrap(decodeMarkdupJSONOutput(legacyOutput[0]))
        let canonicalSummary = try XCTUnwrap(decodeMarkdupJSONOutput(canonicalOutput[0]))
        XCTAssertEqual(canonicalSummary, legacySummary)

        XCTAssertEqual(canonicalSummary.processedBAMs, 1)
        XCTAssertEqual(canonicalSummary.alreadyMarkedBAMs, 0)
        XCTAssertEqual(canonicalSummary.totalReads, 64)
        XCTAssertEqual(canonicalSummary.duplicateReads, 7)
        XCTAssertEqual(canonicalSummary.elapsedSeconds, 2.5)
        XCTAssertEqual(canonicalSummary.results.map(\.bamPath), [resultURL.path])
    }

    private func decodeMarkdupJSONOutput(_ line: String) -> MarkdupJSONOutput? {
        let data = Data(line.utf8)
        return try? JSONDecoder().decode(MarkdupJSONOutput.self, from: data)
    }
}
