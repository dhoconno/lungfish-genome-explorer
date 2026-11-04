// BuildDbTaxTriageSampleFoldersTests.swift - build-db taxtriage reads the root report and the sample folders
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTBUILDDB, row BUILD-DB-ROOT-HIDES-SAMPLE-FOLDERS. `build-db taxtriage` returned the root report's rows
// before it looked at the sample folders, so a folder that held a flat run and later sample folders of a batch
// showed the root's sample alone and said nothing about the others (lane report, measured at the base).

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbTaxTriageSampleFoldersTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDbSampleFolders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Tests

    /// BIO ruling 3 of TTIMPORT: `S0` 2 rows at the root, `S1` 3 and `NTC1` 1 in sample folders.
    func testBuildDbReadsRootAndSampleFolders() async throws {
        let root = folder.appendingPathComponent("batch", isDirectory: true)
        try writeReport(for: "S0", rows: 2, to: root.appendingPathComponent("report/S0.odr.txt"))
        try writeReport(for: "S1", rows: 3, to: root.appendingPathComponent("S1/report/S1.odr.txt"))
        try writeReport(for: "NTC1", rows: 1, to: root.appendingPathComponent("NTC1/report/NTC1.odr.txt"))

        let output = try await build(root)

        let db = try TaxTriageDatabase(at: root.appendingPathComponent("taxtriage.sqlite"))
        XCTAssertEqual(try db.fetchSamples().map(\.sample).sorted(), ["NTC1", "S0", "S1"])
        XCTAssertEqual(try db.fetchRows(samples: ["S0"]).count, 2)
        XCTAssertEqual(try db.fetchRows(samples: ["S1"]).count, 3)
        XCTAssertEqual(try db.fetchRows(samples: ["NTC1"]).count, 1)
        let named = output.components(separatedBy: "\n").filter { $0.contains("NTC1") && $0.contains("S1") }
        XCTAssertEqual(named.count, 1, "one line names both sample folders that were read: \(output)")
        XCTAssertFalse(output.contains("already read"), "no sample name clashes here: \(output)")
    }

    /// A flat run has `report/` and no sample folder. `report/` is the root's own report, and is read once.
    func testBuildDbReadsAFlatRunOnce() async throws {
        let root = folder.appendingPathComponent("flat", isDirectory: true)
        try writeReport(for: "S0", rows: 4, to: root.appendingPathComponent("report/S0.odr.txt"))

        let output = try await build(root)

        let db = try TaxTriageDatabase(at: root.appendingPathComponent("taxtriage.sqlite"))
        XCTAssertEqual(try db.fetchSamples().map(\.sample), ["S0"])
        XCTAssertEqual(try db.fetchRows(samples: ["S0"]).count, 4)
        XCTAssertFalse(output.contains("already read"), output)
        XCTAssertFalse(output.contains("sample folders"), output)
    }

    /// The root's rows win when a sample folder holds the same sample name, and one line names the clash.
    func testBuildDbKeepsTheFirstRowsOfASampleNameThatClashes() async throws {
        let root = folder.appendingPathComponent("clash", isDirectory: true)
        try writeReport(for: "S1", rows: 2, to: root.appendingPathComponent("report/S1.odr.txt"))
        try writeReport(for: "S1", rows: 3, to: root.appendingPathComponent("A/report/A.odr.txt"))
        try writeReport(for: "S2", rows: 1, to: root.appendingPathComponent("B/report/B.odr.txt"))

        let output = try await build(root)

        let db = try TaxTriageDatabase(at: root.appendingPathComponent("taxtriage.sqlite"))
        XCTAssertEqual(try db.fetchSamples().map(\.sample).sorted(), ["S1", "S2"])
        XCTAssertEqual(try db.fetchRows(samples: ["S1"]).count, 2, "the root's rows are the first rows of S1")
        XCTAssertEqual(try db.fetchRows(samples: ["S2"]).count, 1)
        let clashes = output.components(separatedBy: "\n").filter { $0.contains("already read") }
        XCTAssertEqual(clashes.count, 1, "one line names every clash: \(output)")
        XCTAssertTrue(clashes.first?.contains("S1") == true && clashes.first?.contains("S2") == false, "\(clashes)")
    }

    // MARK: - Helpers

    /// Runs `build-db taxtriage` on `root` with its human text on, and returns what it printed.
    private func build(_ root: URL) async throws -> String {
        let command = try BuildDbCommand.TaxTriageSubcommand.parse([root.path, "--no-cleanup"])
        return try await captureStandardOutput { try await command.run() }
    }

    /// A report table of the fixture's header and its first `rows` data lines, with the sample named in each line.
    private func writeReport(for sample: String, rows: Int, to url: URL) throws {
        let lines = try String(contentsOf: try fixtureReport(), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        let kept = lines.prefix(1 + rows).enumerated().map { index, line -> String in
            guard index > 0 else { return line }
            var fields = line.components(separatedBy: "\t")
            fields[3] = sample
            return fields.joined(separator: "\t")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (kept.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func fixtureReport() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent(
                "Tests/Fixtures/taxtriage-odr-3.3.8/SRR12486983/report/SRR12486983.odr.txt"
            )
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw XCTSkip("taxtriage-odr-3.3.8 fixture not found")
    }

    private func captureStandardOutput(_ operation: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStdout = dup(STDOUT_FILENO)
        fflush(stdout)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        do {
            try await operation()
            fflush(stdout)
        } catch {
            fflush(stdout)
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        dup2(originalStdout, STDOUT_FILENO)
        close(originalStdout)
        pipe.fileHandleForWriting.closeFile()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
