// MarkdupCommandTests.swift - Integration tests for lungfish-cli markdup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

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
            if [ "${1:-}" = "-m" ]; then
              shift
            fi
            if [ "${1:-}" = "--reference" ]; then
              shift 2
            fi
            input="${1:--}"
            output="${2:--}"
            if [ "$input" = "-" ] && [ "$output" = "-" ]; then
              cat
            elif [ "$input" = "-" ]; then
              cat > "$output"
            elif [ "$output" = "-" ]; then
              cat "$input"
            else
              cat "$input" > "$output"
            fi
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

    private func writePipelineOnlySamtools(at samtoolsPath: URL) throws {
        try """
        #!/bin/sh
        set -eu

        cmd="${1:-}"
        if [ $# -gt 0 ]; then
          shift
        fi
        if [ -n "${SAMTOOLS_LOG:-}" ]; then
          printf '%s' "$cmd" >> "$SAMTOOLS_LOG"
          for arg in "$@"; do
            printf '\\t%s' "$arg" >> "$SAMTOOLS_LOG"
          done
          printf '\\n' >> "$SAMTOOLS_LOG"
        fi

        case "$cmd" in
          --version)
            echo "samtools 1.99"
            ;;
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
                -m)
                  shift 2
                  ;;
                -n|--reference)
                  if [ "$1" = "--reference" ]; then
                    shift 2
                  else
                    shift
                  fi
                  ;;
                -*)
                  echo "unexpected sort option: $1" >&2
                  exit 3
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
            if [ "${1:-}" = "-m" ]; then
              shift
            fi
            if [ "${1:-}" = "--reference" ]; then
              shift 2
            fi
            input="${1:--}"
            output="${2:--}"
            if [ "$input" = "-" ] && [ "$output" = "-" ]; then
              cat
            elif [ "$input" = "-" ]; then
              cat > "$output"
            elif [ "$output" = "-" ]; then
              cat "$input"
            else
              cat "$input" > "$output"
            fi
            ;;
          markdup)
            if [ "${1:-}" = "-r" ]; then
              shift
            fi
            input="${1:--}"
            output="${2:-}"
            if [ -z "$input" ] || [ "$input" = "-" ] || [ -z "$output" ]; then
              if [ "$input" = "-" ] && [ -n "$output" ]; then
                {
                  printf '@PG\\tID:samtools.markdup\\tCL:samtools markdup\\n'
                  cat
                } > "$output"
                exit 0
              fi
              echo "markdup requires output path" >&2
              exit 7
            fi
            {
              printf '@PG\\tID:samtools.markdup\\tCL:samtools markdup\\n'
              cat "$input"
            } > "$output"
            ;;
          index)
            input="${1:-}"
            if [ -z "$input" ] || [ "$input" = "-" ]; then
              echo "pipeline index requires file input" >&2
              exit 8
            fi
            printf 'BAI\\n' > "$input.bai"
            ;;
          view)
            header=0
            count=0
            bam=""
            bam_from_stdin=0
            while [ $# -gt 0 ]; do
              case "$1" in
                -bS)
                  bam_from_stdin=1
                  shift
                  ;;
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
                -)
                  bam="-"
                  shift
                  ;;
                *)
                  bam="$1"
                  shift
                  ;;
              esac
            done
            if [ "$bam_from_stdin" -eq 1 ] && [ "$bam" = "-" ]; then
              cat
              exit 0
            fi
            if [ "$header" -eq 1 ]; then
              printf '@HD\\tVN:1.6\\tSO:coordinate\\n'
              if [ -n "$bam" ] && [ -f "$bam" ] && /usr/bin/grep -aq 'samtools markdup' "$bam"; then
                printf '@PG\\tID:samtools.markdup\\tCL:samtools markdup\\n'
              fi
              exit 0
            fi
            if [ "$count" -eq 1 ]; then
              if [ -n "$bam" ] && [ -f "$bam" ] && /usr/bin/grep -aq 'samtools markdup' "$bam"; then
                if [ -n "${SAMTOOLS_FAIL_MARKDUP_COUNT:-}" ]; then
                  echo "forced post-replacement count failure" >&2
                  exit 42
                fi
                echo 4
              else
                echo 5
              fi
              exit 0
            fi
            exit 1
            ;;
          *)
            echo "unexpected samtools subcommand: $cmd" >&2
            exit 9
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

    private func withEnvironment<T>(
        _ updates: [String: String],
        perform block: () async throws -> T
    ) async throws -> T {
        var original: [String: String?] = [:]
        for key in updates.keys {
            original[key] = ProcessInfo.processInfo.environment[key]
        }
        for (key, value) in updates {
            setenv(key, value, 1)
        }
        defer {
            for (key, value) in original {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
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

    private func makeNaoMgsDatabase(at dbURL: URL, sample: String = "S1") throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            dbURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK else {
            throw NSError(domain: "MarkdupCommandTests", code: 1)
        }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
        CREATE TABLE virus_hits (
            rowid INTEGER PRIMARY KEY,
            sample TEXT NOT NULL,
            seq_id TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            subject_seq_id TEXT NOT NULL,
            subject_title TEXT NOT NULL,
            ref_start INTEGER,
            cigar TEXT,
            read_sequence TEXT,
            read_quality TEXT,
            percent_identity REAL NOT NULL,
            bit_score REAL NOT NULL,
            e_value REAL NOT NULL,
            edit_distance INTEGER,
            query_length INTEGER,
            is_reverse_complement INTEGER,
            pair_status TEXT NOT NULL,
            fragment_length INTEGER NOT NULL,
            best_alignment_score REAL,
            ref_start_rev INTEGER,
            read_sequence_rev TEXT,
            read_quality_rev TEXT,
            edit_distance_rev INTEGER,
            query_length_rev INTEGER,
            is_reverse_complement_rev INTEGER,
            best_alignment_score_rev REAL
        );
        CREATE TABLE reference_lengths (accession TEXT PRIMARY KEY, length INTEGER NOT NULL);
        CREATE TABLE taxon_summaries (
            sample TEXT NOT NULL,
            tax_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            hit_count INTEGER NOT NULL,
            unique_read_count INTEGER NOT NULL,
            avg_identity REAL NOT NULL,
            avg_bit_score REAL NOT NULL,
            avg_edit_distance REAL NOT NULL,
            pcr_duplicate_count INTEGER NOT NULL,
            accession_count INTEGER NOT NULL,
            top_accessions_json TEXT NOT NULL,
            bam_path TEXT,
            bam_index_path TEXT,
            PRIMARY KEY (sample, tax_id)
        );
        """, nil, nil, nil)

        sqlite3_exec(db, "INSERT INTO reference_lengths VALUES ('NC_001', 1000)", nil, nil, nil)
        sqlite3_exec(db, """
        INSERT INTO taxon_summaries VALUES (
            '\(sample)', 1, 'Test virus', 1, 1, 99.0, 100.0, 0.0, 0, 1, '[]', NULL, NULL
        )
        """, nil, nil, nil)

        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        sqlite3_exec(db, """
        INSERT INTO virus_hits VALUES (
            NULL, '\(sample)', 'read1', 1, 'NC_001', 'Test virus',
            100, '50M', '\(seq)', '\(qual)', 99.0, 100.0, 0.001, 0, 50, 0,
            'unpaired', 50, 90.0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
        )
        """, nil, nil, nil)
    }

    private func cliBinaryURL() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates = [
            repoRoot.appendingPathComponent(".build/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/lungfish-cli"),
            repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/lungfish-cli"),
        ]

        guard let binary = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("CLI binary not built at expected path — run `swift build --product lungfish-cli` first")
        }
        return binary
    }

    private func runCLI(
        _ arguments: [String],
        homeDirectory: URL
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try cliBinaryURL()
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory.path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return (
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    // MARK: - Tests

    func testCliMarkdupDirectoryJSONResultsAreSortedByStandardizedPath() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let zDir = dir.appendingPathComponent("z", isDirectory: true)
        let aDir = dir.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: zDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        let zBam = zDir.appendingPathComponent("z.bam")
        let aBam = aDir.appendingPathComponent("a.bam")
        try makeSyntheticBam(at: zBam, samtools: samtools)
        try makeSyntheticBam(at: aBam, samtools: samtools)
        try writePipelineOnlySamtools(at: managedHome.samtoolsPath)

        var output: [String] = []
        try await withHomeDirectory(managedHome.home) {
            let cmd = try MarkdupCommand.parse([
                dir.path,
                "--format", "json",
            ])
            _ = try await cmd.executeForTesting { output.append($0) }
        }

        let summary = try XCTUnwrap(decodeMarkdupJSONOutput(output.last ?? ""))
        let normalizeTempPath: (String) -> String = { path in
            path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        }
        XCTAssertEqual(
            summary.results.map { normalizeTempPath($0.bamPath) },
            [aBam, zBam].map { normalizeTempPath($0.path) }
        )
    }

    func testCliMarkdupRejectsInvalidSortThreads() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: managedHome.samtoolsPath.path)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try MarkdupCommand.parse([
                bamURL.path,
                "--sort-threads", "0",
                "-q",
            ])
            do {
                try await cmd.run()
                XCTFail("Expected --sort-threads 0 to be rejected")
            } catch {
                XCTAssertTrue("\(error)".contains("sort-threads"))
                XCTAssertTrue("\(error)".contains(">= 1"))
            }
        }
    }

    func testCliMarkdupRunsSharedPipelineCommandChain() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)
        try writePipelineOnlySamtools(at: managedHome.samtoolsPath)

        let logURL = dir.appendingPathComponent("samtools.log")
        try Data().write(to: logURL)

        try await withEnvironment(["SAMTOOLS_LOG": logURL.path]) {
            try await withHomeDirectory(managedHome.home) {
                let cmd = try MarkdupCommand.parse([
                    bamURL.path,
                    "--sort-threads", "7",
                    "-q",
                ])
                try await cmd.run()
            }
        }

        let logLines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let pipelineLines = logLines.filter { line in
            let command = line.split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init)
            return command != "view" && command != "--version"
        }
        let commandNames = pipelineLines.map {
            String($0.split(separator: "\t", omittingEmptySubsequences: false).first ?? "")
        }
        XCTAssertEqual(commandNames, ["sort", "fixmate", "sort", "markdup", "index"])

        let sortLines = pipelineLines.filter { $0.hasPrefix("sort\t") }
        XCTAssertEqual(sortLines.count, 2)
        XCTAssertTrue(sortLines.allSatisfy { $0.contains("\t-@\t7") })
        XCTAssertTrue(sortLines.allSatisfy { $0.contains("\t-o\t") })
        let markdupLine = try XCTUnwrap(pipelineLines.first { $0.hasPrefix("markdup\t") })
        XCTAssertFalse(markdupLine.contains("\t-\t"))
        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtools))
    }

    func testCliMarkdupWritesCanonicalProvenanceForBamOutput() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)
        try writePipelineOnlySamtools(at: managedHome.samtoolsPath)

        let logURL = dir.appendingPathComponent("samtools.log")
        try Data().write(to: logURL)

        try await withEnvironment(["SAMTOOLS_LOG": logURL.path]) {
            try await withHomeDirectory(managedHome.home) {
                let cmd = try MarkdupCommand.parse([
                    bamURL.path,
                    "--sort-threads", "3",
                    "-q",
                ])
                try await cmd.run()
            }
        }

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: bamURL)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.workflowName, "lungfish markdup")
        XCTAssertEqual(envelope.toolName, "lungfish markdup")
        XCTAssertEqual(envelope.output?.path, bamURL.path)
        XCTAssertTrue(envelope.argv.contains("markdup"))
        XCTAssertTrue(envelope.argv.contains(bamURL.path))
        XCTAssertEqual(envelope.options.defaults["sortThreads"]?.integerValue, 4)
        XCTAssertEqual(envelope.options.resolvedDefaults["sortThreads"]?.integerValue, 3)
        XCTAssertEqual(envelope.options.resolvedDefaults["force"]?.booleanValue, false)

        let outputPaths = Set(envelope.outputs.map(\.path))
        XCTAssertTrue(outputPaths.contains(bamURL.path))
        XCTAssertTrue(outputPaths.contains(bamURL.path + ".bai"))
        XCTAssertTrue(envelope.outputs.allSatisfy { $0.checksumSHA256 != nil && $0.fileSize != nil })

        let samtoolsSteps = envelope.steps.filter { $0.toolName == "samtools" }
        XCTAssertEqual(
            samtoolsSteps.compactMap { $0.argv.dropFirst().first },
            ["sort", "fixmate", "sort", "markdup", "index"]
        )
        XCTAssertTrue(samtoolsSteps.allSatisfy { $0.exitStatus == 0 && $0.wallTimeSeconds != nil })
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertNotNil(envelope.wallTimeSeconds)
    }

    func testCliMarkdupFullRunIndexSidecarFocusesIndexOutput() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        try makeSyntheticBam(at: bamURL, samtools: samtools)
        try writePipelineOnlySamtools(at: managedHome.samtoolsPath)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try MarkdupCommand.parse([bamURL.path, "-q"])
            try await cmd.run()
        }

        let envelope = try XCTUnwrap(
            ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: baiURL))
        )
        XCTAssertEqual(envelope.output?.path, baiURL.path)
        XCTAssertEqual(envelope.outputs.first?.path, baiURL.path)
        XCTAssertTrue(envelope.outputs.map(\.path).contains(bamURL.path))
        XCTAssertEqual(envelope.steps.last?.outputs.map(\.path), [baiURL.path])
    }

    func testCliMarkdupWritesFailureProvenanceAfterPostReplacementFailure() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)
        try writePipelineOnlySamtools(at: managedHome.samtoolsPath)

        try await withEnvironment(["SAMTOOLS_FAIL_MARKDUP_COUNT": "1"]) {
            try await withHomeDirectory(managedHome.home) {
                let cmd = try MarkdupCommand.parse([bamURL.path, "-q"])
                do {
                    try await cmd.run()
                    XCTFail("Expected post-replacement count failure")
                } catch {
                    XCTAssertTrue("\(error)".contains("count") || "\(error)".contains("42"))
                }
            }
        }

        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtools))
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: bamURL)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecarURL))
        XCTAssertNotEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.output?.path, bamURL.path)
        XCTAssertTrue(envelope.stderr?.contains("forced post-replacement count failure") == true)
    }

    func testCliMarkdupWritesProvenanceWhenSkipPathRebuildsIndex() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        try makeSyntheticBam(at: bamURL, samtools: samtools)
        try writePipelineOnlySamtools(at: managedHome.samtoolsPath)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try MarkdupCommand.parse([bamURL.path, "-q"])
            try await cmd.run()
        }

        try FileManager.default.removeItem(at: baiURL)
        try? FileManager.default.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: baiURL))

        try await withHomeDirectory(managedHome.home) {
            let cmd = try MarkdupCommand.parse([bamURL.path, "-q"])
            try await cmd.run()
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: baiURL.path))
        let indexSidecarURL = ProvenanceRecorder.fileSidecarURL(for: baiURL)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: indexSidecarURL))
        XCTAssertEqual(envelope.output?.path, baiURL.path)
        XCTAssertEqual(Set(envelope.outputs.map(\.path)), [baiURL.path])
        XCTAssertEqual(
            envelope.steps.compactMap { $0.argv.dropFirst().first },
            ["index"]
        )
        XCTAssertEqual(envelope.steps.first?.outputs.map(\.path), [baiURL.path])
        XCTAssertEqual(envelope.exitStatus, 0)
    }

    func testCliMarkdupNaoMgsDirectoryUsesSharedPipelineForMaterializedBAMs() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        try makeNaoMgsDatabase(at: dir.appendingPathComponent("hits.sqlite"))
        let bamsDir = dir.appendingPathComponent("bams", isDirectory: true)
        try FileManager.default.createDirectory(at: bamsDir, withIntermediateDirectories: true)
        let bamURL = bamsDir.appendingPathComponent("S1.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)
        try writePipelineOnlySamtools(at: managedHome.samtoolsPath)

        let logURL = dir.appendingPathComponent("samtools.log")
        try Data().write(to: logURL)

        try await withEnvironment(["SAMTOOLS_LOG": logURL.path]) {
            try await withHomeDirectory(managedHome.home) {
                let cmd = try MarkdupCommand.parse([dir.path, "-q"])
                try await cmd.run()
            }
        }

        let logLines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let markdupLines = logLines.filter { $0.hasPrefix("markdup\t") }
        XCTAssertEqual(markdupLines.count, 1)
        let markdupLine = try XCTUnwrap(markdupLines.first)
        XCTAssertFalse(
            markdupLine.contains("\t-\t"),
            "NAO-MGS CLI directory markdup should be the shared file-based pipeline pass, not MarkdupService's stdin/stdout shell pipeline"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: bamURL.path))
        XCTAssertNotNil(ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: bamURL)))
    }

    func testCliMarkdupNaoMgsExistingAlreadyMarkedBamMissingIndexWritesIndexProvenance() async throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        try makeNaoMgsDatabase(at: dir.appendingPathComponent("hits.sqlite"))
        let bamsDir = dir.appendingPathComponent("bams", isDirectory: true)
        try FileManager.default.createDirectory(at: bamsDir, withIntermediateDirectories: true)
        let bamURL = bamsDir.appendingPathComponent("S1.bam")
        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        try makeSyntheticBam(at: bamURL, samtools: samtools)
        try writePipelineOnlySamtools(at: managedHome.samtoolsPath)

        try await withHomeDirectory(managedHome.home) {
            let cmd = try MarkdupCommand.parse([bamURL.path, "-q"])
            try await cmd.run()
        }
        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtools))

        try FileManager.default.removeItem(at: baiURL)
        try? FileManager.default.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: baiURL))

        let logURL = dir.appendingPathComponent("samtools.log")
        try Data().write(to: logURL)
        try await withEnvironment(["SAMTOOLS_LOG": logURL.path]) {
            try await withHomeDirectory(managedHome.home) {
                let cmd = try MarkdupCommand.parse([dir.path, "-q"])
                try await cmd.run()
            }
        }

        let logLines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(logLines.filter { $0.hasPrefix("index\t") }.count, 1)
        XCTAssertEqual(logLines.filter { $0.hasPrefix("markdup\t") }.count, 0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: baiURL.path))
        let envelope = try XCTUnwrap(
            ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: baiURL))
        )
        let normalizePath: (String) -> String = { path in
            path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        }
        let expectedIndexPath = normalizePath(baiURL.path)
        XCTAssertEqual(envelope.output.map { normalizePath($0.path) }, expectedIndexPath)
        XCTAssertEqual(Set(envelope.outputs.map { normalizePath($0.path) }), [expectedIndexPath])
        XCTAssertEqual(envelope.steps.compactMap { $0.argv.dropFirst().first }, ["index"])
        XCTAssertEqual(envelope.steps.first?.outputs.map { normalizePath($0.path) }, [expectedIndexPath])
    }

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

    func testMarkdupCommandRejectsTSVOutputFormat() {
        XCTAssertThrowsError(
            try MarkdupCommand.parse([
                "/tmp/test.bam",
                "--format", "tsv",
            ])
        ) { error in
            XCTAssertTrue("\(error)".contains("tsv"))
        }
    }

    func testMarkdupHelpOmitsUnsupportedTSVFormat() {
        let help = MarkdupCommand.helpMessage()
        XCTAssertTrue(help.contains("Output format: text, json"))
        XCTAssertFalse(help.contains("tsv"))
    }

    func testRootLevelQuietAppliesToBamMarkdupExecutable() throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)

        let result = try runCLI(
            ["-q", "bam", "markdup", bamURL.path],
            homeDirectory: managedHome.home
        )

        XCTAssertEqual(result.exitCode, 0, "CLI bam markdup failed: \(result.stderr)")
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(
            MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtools),
            "BAM should be marked after CLI run"
        )
    }

    func testRootLevelJSONFormatAppliesToLegacyMarkdupExecutable() throws {
        let managedHome = try makeFunctionalManagedSamtoolsHome()
        let samtools = managedHome.samtoolsPath.path
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: managedHome.home)
        }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeSyntheticBam(at: bamURL, samtools: samtools)

        let result = try runCLI(
            ["--format", "json", "markdup", bamURL.path],
            homeDirectory: managedHome.home
        )

        XCTAssertEqual(result.exitCode, 0, "CLI markdup failed: \(result.stderr)")
        let summary = try XCTUnwrap(
            decodeMarkdupJSONOutput(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertEqual(summary.processedBAMs, 1)
        XCTAssertEqual(summary.results.map(\.bamPath), [bamURL.path])
        XCTAssertTrue(
            MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtools),
            "BAM should be marked after CLI run"
        )
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
