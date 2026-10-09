// VCFImportHelperToolProcessTests.swift - The per-chromosome VCF helper never deadlocks on a full pipe
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import os
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishApp

/// The per-chromosome VCF import runs bcftools and a child helper import.
/// Each of those used to wait for the process to exit before reading either
/// pipe, so a run that wrote more than 64 KB to stdout or stderr blocked on a
/// full pipe forever (Phase 2.2 lane 3B1, finding R7).
///
/// The tests reach the spawns through the seams the helper already has. The
/// managed bcftools resolves through `LUNGFISH_CONDA_ROOT`, and the child
/// helper is whatever executable argv[0] names, so the subprocess tests launch
/// the built `Lungfish` executable with argv[0] pointing at a fake helper.
final class VCFImportHelperToolProcessTests: XCTestCase {
    private static let noiseLines = 2_000
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vcf-helper-toolprocess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        killRecordedProcesses()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private var fixtures: URL {
        CLITestBinaryResolver.repositoryRoot(containing: #filePath)
            .appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
    }

    private var pidFile: URL { tempDirectory.appendingPathComponent("pids") }

    // MARK: - bcftools runs

    /// Every bcftools run writes well over 64 KB to both streams. The helper
    /// must drain them while bcftools runs, finish the per-chromosome pass
    /// (the shard reports no records) and fall back to a single-pass import.
    func testBcftoolsWritingOver64KBToBothStreamsDoesNotDeadlock() throws {
        let condaRoot = try makeFakeBcftools(body: """
        case "$1 $2" in
          "index --nrecords") echo 0 ;;
        esac
        \(Self.noiseLoop)
        exit 0
        """)
        let input = try copyFixtureVCFWithoutIndex()
        let output = tempDirectory.appendingPathComponent("out.db")

        let exitCode = try withEnvironment("LUNGFISH_CONDA_ROOT", condaRoot.path) {
            try runHelperInProcess(arguments: [
                "Lungfish", "--vcf-import-helper",
                "--vcf-path", input.path,
                "--output-db-path", output.path,
                "--import-profile", "ultra-low-memory",
            ])
        }

        XCTAssertEqual(exitCode, 0)
        // The helper defers the index build to the app, so the database is
        // still marked as indexing and only its rows can be read.
        XCTAssertEqual(try Self.rows(output, "SELECT COUNT(*) FROM variants", quoted: false), ["9"])
        let bcftoolsRuns = try String(contentsOf: pidFile, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(bcftoolsRuns, 4, "index source, view, index shard and index --nrecords")
    }

    func testFailingBcftoolsWithOver64KBOfOutputFailsTheImport() throws {
        let condaRoot = try makeFakeBcftools(body: """
        \(Self.noiseLoop)
        echo "bcftools: index exploded" >&2
        exit 3
        """)
        let input = try copyFixtureVCFWithoutIndex()
        let output = tempDirectory.appendingPathComponent("out.db")
        let exitCode = try withEnvironment("LUNGFISH_CONDA_ROOT", condaRoot.path) {
            try runHelperInProcess(arguments: [
                "Lungfish", "--vcf-import-helper",
                "--vcf-path", input.path, "--output-db-path", output.path,
                "--import-profile", "ultra-low-memory",
            ])
        }
        XCTAssertEqual(exitCode, 1)
    }

    // MARK: - Child helper import

    /// The child helper writes over 64 KB of progress events and stderr. The
    /// parent must read both while the child runs, then apply its events.
    func testChildHelperWritingOver64KBToBothStreamsDoesNotDeadlock() throws {
        let lungfish = try builtLungfishExecutable()
        let condaRoot = try makeFakeBcftools(body: """
        case "$1 $2" in
          "index --nrecords") echo 9 ;;
          "view --regions") cp "$7" "$6" ;;
        esac
        exit 0
        """)
        let helper = tempDirectory.appendingPathComponent("fake-helper")
        try writeExecutable(helper, """
        #!/bin/sh
        echo $$ >> "\(pidFile.path)"
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--output-db-path" ]; then out="$2"; fi
          shift
        done
        /usr/bin/sqlite3 "$out" "CREATE TABLE db_metadata (key TEXT PRIMARY KEY, value TEXT);"
        i=0
        while [ $i -lt \(Self.noiseLines) ]; do
          echo '{"event":"progress","progress":0.5,"message":"child progress line padded to make the stream long enough"}'
          echo "child stderr line $i padded to make the stream long enough to fill a pipe" >&2
          i=$((i+1))
        done
        echo '{"event":"done","progress":1.0,"variantCount":9}'
        exit 0
        """)
        let input = try copyFixtureVCFWithoutIndex()
        let output = tempDirectory.appendingPathComponent("out.db")

        let result = try runHelperSubprocess(
            lungfish: lungfish, argv0: helper.path, condaRoot: condaRoot,
            arguments: ["--vcf-path", input.path, "--output-db-path", output.path, "--import-profile", "ultra-low-memory"]
        )

        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("\"variantCount\":9"), result.stdout)
        XCTAssertEqual(try metadataValue(output, key: "import_partition_mode"), "helper-subprocess-per-chromosome")
    }

    /// The real per-chromosome pass, with the real managed bcftools and the
    /// built app as its child helper, builds the database a direct import of
    /// the same chromosome builds.
    func testPerChromosomeImportWithRealBcftoolsMatchesADirectImport() throws {
        let lungfish = try builtLungfishExecutable()
        let condaRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda")
        guard FileManager.default.isExecutableFile(atPath: condaRoot.appendingPathComponent("envs/bcftools/bin/bcftools").path) else {
            try ToolAvailability.skipOrFail("The managed bcftools of ~/.lungfish is required")
        }
        let input = try copyFixtureVCFWithoutIndex()
        let output = tempDirectory.appendingPathComponent("out.db")

        let result = try runHelperSubprocess(
            lungfish: lungfish, argv0: lungfish.path, condaRoot: condaRoot,
            arguments: ["--vcf-path", input.path, "--output-db-path", output.path, "--import-profile", "ultra-low-memory"]
        )
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("\"variantCount\":9"), result.stdout)
        XCTAssertEqual(try metadataValue(output, key: "import_partition_mode"), "helper-subprocess-per-chromosome")

        let direct = tempDirectory.appendingPathComponent("direct.db")
        _ = try VCFBundleVariantImport.createDatabase(
            vcfURL: fixtures.appendingPathComponent("test.vcf.gz"), outputDBURL: direct,
            sourceFile: input.lastPathComponent, importProfile: .ultraLowMemory, onlyChromosome: "MT192765.1"
        )
        XCTAssertEqual(try Self.dump(output), try Self.dump(direct))
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path + ".csi"), "The source index the helper made is removed")
    }

    // MARK: - Helpers

    /// Writes 2,000 lines of about 80 bytes to each stream, so each holds
    /// about 160 KB, well past the 64 KB pipe buffer.
    private static let noiseLoop = """
    i=0
    while [ $i -lt \(noiseLines) ]; do
      echo "noise on stdout, line $i, padded so the stream overflows a pipe buffer"
      echo "noise on stderr, line $i, padded so the stream overflows a pipe buffer" >&2
      i=$((i+1))
    done
    """

    private func makeFakeBcftools(body: String) throws -> URL {
        let condaRoot = tempDirectory.appendingPathComponent("conda", isDirectory: true)
        let bin = condaRoot.appendingPathComponent("envs/bcftools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(bin.appendingPathComponent("bcftools"), """
        #!/bin/sh
        echo $$ >> "\(pidFile.path)"
        \(body)
        """)
        return condaRoot
    }

    private func writeExecutable(_ url: URL, _ script: String) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func copyFixtureVCFWithoutIndex() throws -> URL {
        let input = tempDirectory.appendingPathComponent("input.vcf.gz")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("test.vcf.gz"), to: input)
        return input
    }

    /// Runs the helper on a thread of its own. A deadlocked helper never
    /// returns, so after the deadline the processes it started are killed,
    /// which unblocks it, and the test fails instead of hanging.
    private func runHelperInProcess(arguments: [String], deadline: TimeInterval = 60) throws -> Int32? {
        let outcome = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let code = VCFImportHelper.runIfRequested(arguments: arguments)
            outcome.withLock { $0 = code }
            finished.signal()
        }
        thread.start()
        if finished.wait(timeout: .now() + deadline) == .timedOut {
            killRecordedProcesses()
            _ = finished.wait(timeout: .now() + 30)
            XCTFail("The helper import did not finish within \(Int(deadline)) seconds, so a pipe deadlocked")
        }
        return outcome.withLock { $0 }
    }

    private func runHelperSubprocess(
        lungfish: URL, argv0: String, condaRoot: URL, arguments: [String]
    ) throws -> LungfishTestSupport.ProcessResult {
        do {
            return try ProcessRunner.run(
                URL(fileURLWithPath: "/bin/bash"),
                ["-c", "exec -a \"$0\" \"$@\"", argv0, lungfish.path, "--vcf-import-helper"] + arguments,
                environment: ["LUNGFISH_CONDA_ROOT": condaRoot.path],
                timeout: 90
            )
        } catch {
            killRecordedProcesses()
            XCTFail("The helper import did not finish, so a pipe deadlocked: \(error)")
            throw error
        }
    }

    private func builtLungfishExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment["LUNGFISH_TEST_APP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
        let sibling = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Lungfish")
        guard let executable = [environment, sibling].compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("The built Lungfish executable is not beside the test bundle. Run swift build --build-tests first.")
        }
        return executable
    }

    private func killRecordedProcesses() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        for pid in text.split(separator: "\n").compactMap({ Int32($0) }) {
            kill(pid, SIGKILL)
        }
    }

    private func withEnvironment<T>(_ key: String, _ value: String, _ body: () throws -> T) rethrows -> T {
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, value, 1)
        defer {
            if let previous {
                setenv(key, previous, 1)
            } else {
                unsetenv(key)
            }
        }
        return try body()
    }

    private func metadataValue(_ url: URL, key: String) throws -> String? {
        try Self.rows(url, "SELECT value FROM db_metadata WHERE key = '\(key)'", quoted: false).first
    }

    /// The rows an import writes, without the source path or timestamps.
    private static func dump(_ url: URL) throws -> String {
        try [
            "SELECT chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count FROM variants ORDER BY id",
            "SELECT variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields FROM genotypes ORDER BY variant_id, sample_name",
            "SELECT name, display_name, metadata FROM samples ORDER BY name",
            "SELECT key, type, number, description FROM variant_info_defs ORDER BY key",
            "SELECT variant_id, key, value FROM variant_info ORDER BY variant_id, key",
        ].map { try rows(url, $0).joined(separator: "\n") }.joined(separator: "\n--\n")
    }

    private static func rows(_ url: URL, _ query: String, quoted: Bool = true) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw VariantDatabaseError.createFailed("Could not open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return ["! \(query)"]
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { quoted ? String(cString: $0).debugDescription : String(cString: $0) } ?? "NULL"
            }.joined(separator: "|"))
        }
        return rows
    }
}
