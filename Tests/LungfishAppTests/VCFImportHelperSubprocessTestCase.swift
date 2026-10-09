// VCFImportHelperSubprocessTestCase.swift - Shared fixtures and helpers of the per-chromosome VCF helper tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
import os
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishApp

/// The temporary folder, fake bcftools, helper launchers and database readers
/// that `VCFImportHelperToolProcessTests` (fake scripts, unit tier) and
/// `VCFImportHelperRealToolTests` (the real managed bcftools, tool
/// conformance tier) share. It has no tests of its own.
class VCFImportHelperSubprocessTestCase: XCTestCase {
    static let noiseLines = 2_000
    var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vcf-helper-toolprocess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        killRecordedProcesses()
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    var fixtures: URL {
        CLITestBinaryResolver.repositoryRoot(containing: #filePath)
            .appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
    }

    var pidFile: URL { tempDirectory.appendingPathComponent("pids") }

    // MARK: - Helpers

    /// Writes 2,000 lines of about 80 bytes to each stream, so each holds
    /// about 160 KB, well past the 64 KB pipe buffer.
    static let noiseLoop = """
    i=0
    while [ $i -lt \(noiseLines) ]; do
      echo "noise on stdout, line $i, padded so the stream overflows a pipe buffer"
      echo "noise on stderr, line $i, padded so the stream overflows a pipe buffer" >&2
      i=$((i+1))
    done
    """

    func makeFakeBcftools(body: String) throws -> URL {
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

    func writeExecutable(_ url: URL, _ script: String) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func copyFixtureVCFWithoutIndex() throws -> URL {
        let input = tempDirectory.appendingPathComponent("input.vcf.gz")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("test.vcf.gz"), to: input)
        return input
    }

    /// Runs the helper on a thread of its own. A deadlocked helper never
    /// returns, so after the deadline the processes it started are killed,
    /// which unblocks it, and the test fails instead of hanging.
    func runHelperInProcess(arguments: [String], deadline: TimeInterval = 60) throws -> Int32? {
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

    func runHelperSubprocess(
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

    func builtLungfishExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment["LUNGFISH_TEST_APP_EXECUTABLE"].map { URL(fileURLWithPath: $0) }
        let sibling = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Lungfish")
        guard let executable = [environment, sibling].compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw XCTSkip("The built Lungfish executable is not beside the test bundle. Run swift build --build-tests first.")
        }
        return executable
    }

    func killRecordedProcesses() {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return }
        for pid in text.split(separator: "\n").compactMap({ Int32($0) }) {
            kill(pid, SIGKILL)
        }
    }

    func withEnvironment<T>(_ key: String, _ value: String, _ body: () throws -> T) rethrows -> T {
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

    func metadataValue(_ url: URL, key: String) throws -> String? {
        try Self.rows(url, "SELECT value FROM db_metadata WHERE key = '\(key)'", quoted: false).first
    }

    /// The rows an import writes, without the source path or timestamps.
    static func dump(_ url: URL) throws -> String {
        try [
            "SELECT chromosome, position, end_pos, variant_id, ref, alt, variant_type, quality, filter, info, sample_count FROM variants ORDER BY id",
            "SELECT variant_id, sample_name, genotype, allele1, allele2, is_phased, depth, genotype_quality, allele_depths, raw_fields FROM genotypes ORDER BY variant_id, sample_name",
            "SELECT name, display_name, metadata FROM samples ORDER BY name",
            "SELECT key, type, number, description FROM variant_info_defs ORDER BY key",
            "SELECT variant_id, key, value FROM variant_info ORDER BY variant_id, key",
        ].map { try rows(url, $0).joined(separator: "\n") }.joined(separator: "\n--\n")
    }

    static func rows(_ url: URL, _ query: String, quoted: Bool = true) throws -> [String] {
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
