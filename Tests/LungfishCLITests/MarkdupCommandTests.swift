// MarkdupCommandTests.swift - Integration tests for lungfish-cli markdup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class MarkdupCommandTests: XCTestCase {
    private typealias MarkdupRuntime = MarkdupCommand.Runtime

    // MARK: - Inline BAM fixture helper
    // The canonical BamFixtureBuilder lives in LungfishIOTests and isn't
    // visible here. We duplicate a minimal version locally to avoid cross-target
    // dependencies.

    private struct Reference {
        let name: String
        let length: Int
    }

    private struct Read {
        let qname: String
        let flag: Int
        let rname: String
        let pos: Int
        let mapq: Int
        let cigar: String
        let seq: String
        let qual: String
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

    private func makeBAM(
        at outputURL: URL,
        references: [Reference],
        reads: [Read],
        samtoolsPath: String
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var sam = "@HD\tVN:1.6\tSO:coordinate\n"
        for ref in references {
            sam += "@SQ\tSN:\(ref.name)\tLN:\(ref.length)\n"
        }
        for read in reads {
            sam += "\(read.qname)\t\(read.flag)\t\(read.rname)\t\(read.pos)\t\(read.mapq)\t\(read.cigar)\t*\t0\t0\t\(read.seq)\t\(read.qual)\n"
        }

        let samURL = outputURL.deletingPathExtension().appendingPathExtension("sam")
        try sam.write(to: samURL, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: samURL) }

        let sortProc = Process()
        sortProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        sortProc.arguments = ["sort", "-o", outputURL.path, samURL.path]
        let errPipe = Pipe()
        sortProc.standardOutput = FileHandle.nullDevice
        sortProc.standardError = errPipe
        try sortProc.run()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        sortProc.waitUntilExit()
        guard sortProc.terminationStatus == 0 else {
            throw NSError(domain: "MarkdupCommandTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "samtools sort failed"])
        }

        let indexProc = Process()
        indexProc.executableURL = URL(fileURLWithPath: samtoolsPath)
        indexProc.arguments = ["index", outputURL.path]
        indexProc.standardOutput = FileHandle.nullDevice
        indexProc.standardError = FileHandle.nullDevice
        try indexProc.run()
        indexProc.waitUntilExit()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdupCliTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeSyntheticBam(at url: URL, samtools: String) throws {
        let refs = [Reference(name: "chr1", length: 1000)]
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        let reads = (0..<5).map { i in
            Read(
                qname: "r\(i)", flag: 0, rname: "chr1",
                pos: 100, mapq: 60, cigar: "50M", seq: seq, qual: qual
            )
        }
        try makeBAM(at: url, references: refs, reads: reads, samtoolsPath: samtools)
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
}
