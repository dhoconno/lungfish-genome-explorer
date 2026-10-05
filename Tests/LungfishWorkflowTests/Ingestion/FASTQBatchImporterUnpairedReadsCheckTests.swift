// FASTQBatchImporterUnpairedReadsCheckTests.swift - What an import does with a run's joined third file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

private final class ImportEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ImportLogEvent] = []

    func append(_ event: ImportLogEvent) {
        lock.withLock { storage.append(event) }
    }

    var events: [ImportLogEvent] {
        lock.withLock { storage }
    }
}

/// A run's third file, the reads whose mate is missing, joins its `_1` and
/// `_2` pair as one sample (lane F9). These tests cover what the import
/// does with such a sample. Trim Galore cannot store it without leaving
/// reads out, and failed deep in the pipeline with a message that named
/// neither the run nor the file (finding F9-N2). The per-sample log and the
/// `sampleStart` event named only the pair (F9-N3).
final class FASTQBatchImporterUnpairedReadsCheckTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-unpaired-check")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Trim Galore (F9-N2)

    func testTrimGaloreRefusesARunWithReadsWithoutAMateAndNamesTheFile() async throws {
        let files = try writeRun("SRR9000007", pairedSpots: [1, 2], unpairedSpots: [3])

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: files),
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project,
                platform: .given(.illumina),
                qualityBinning: QualityBinningScheme.none,
                optimizeStorage: true,
                clumpingTool: .trimGalore,
                threads: 1
            )
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1, "Trim Galore would leave the reads without a mate out")
        let error = try XCTUnwrap(result.errors.first?.error)
        XCTAssertEqual(
            error,
            "Trim Galore cannot optimize storage for sample 'SRR9000007', because SRR9000007.fastq holds reads whose "
                + "mate is missing, and Trim Galore reads only pairs or only single reads. Choose BBTools clumpify or "
                + "skip storage optimization to keep every read."
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Imports/SRR9000007.lungfishfastq").path
        ))
    }

    // MARK: - What the import logs (F9-N3)

    func testThePerSampleLogAndTheSampleStartEventNameTheThirdFile() async throws {
        let files = try writeRun("SRR9000008", pairedSpots: [1, 2], unpairedSpots: [3])
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let collector = ImportEventCollector()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: files),
            config: config(logDirectory: logs),
            log: { collector.append($0) }
        )

        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        let entry = try Self.jsonObject(at: logs.appendingPathComponent("SRR9000008.import.log"))
        XCTAssertEqual(entry["r1"] as? String, "SRR9000008_1.fastq")
        XCTAssertEqual(entry["r2"] as? String, "SRR9000008_2.fastq")
        XCTAssertEqual(entry["unpaired"] as? String, "SRR9000008.fastq")

        let start = try XCTUnwrap(Self.sampleStartJSON(in: collector.events))
        XCTAssertEqual(start["r1"] as? String, "SRR9000008_1.fastq")
        XCTAssertEqual(start["r2"] as? String, "SRR9000008_2.fastq")
        XCTAssertEqual(start["unpaired"] as? String, "SRR9000008.fastq")
    }

    func testAPairsLogAndSampleStartEventHaveNoThirdFile() async throws {
        let files = try writeRun("SRR9000009", pairedSpots: [1, 2], unpairedSpots: [])
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let collector = ImportEventCollector()

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: files),
            config: config(logDirectory: logs),
            log: { collector.append($0) }
        )

        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        let entry = try Self.jsonObject(at: logs.appendingPathComponent("SRR9000009.import.log"))
        XCTAssertEqual(Set(entry.keys), ["sample", "r1", "r2", "bundle", "timestamp"], "the log reads as it did")
        let start = try XCTUnwrap(Self.sampleStartJSON(in: collector.events))
        XCTAssertNil(start["unpaired"], "the event reads as it did")
        XCTAssertEqual(start["r2"] as? String, "SRR9000009_2.fastq")
    }

    // MARK: - Helpers

    private func config(logDirectory: URL? = nil) -> FASTQBatchImporter.ImportConfig {
        FASTQBatchImporter.ImportConfig(
            projectDirectory: project,
            platform: .given(.illumina),
            qualityBinning: QualityBinningScheme.none,
            optimizeStorage: false,
            threads: 1,
            logDirectory: logDirectory
        )
    }

    /// Writes one run as fasterq-dump names it, `<run>_1.fastq` and
    /// `<run>_2.fastq` for the spots with both reads, and `<run>.fastq` for
    /// the spots whose mate is missing when there are any.
    private func writeRun(_ run: String, pairedSpots: [Int], unpairedSpots: [Int]) throws -> [URL] {
        let folder = root.appendingPathComponent("download-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ name: String, _ spots: [Int], bases: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let text = spots.map { "@\(run).\($0) \($0) length=8\n\(bases)\n+\nIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: url)
            return url
        }
        var files = [
            try write("\(run)_1.fastq", pairedSpots, bases: "ACGTACGT"),
            try write("\(run)_2.fastq", pairedSpots, bases: "TTGGCCAA"),
        ]
        if !unpairedSpots.isEmpty {
            files.append(try write("\(run).fastq", unpairedSpots, bases: "GATTACAG"))
        }
        return files
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The `sampleStart` event as the CLI prints it.
    private static func sampleStartJSON(in events: [ImportLogEvent]) -> [String: Any]? {
        for event in events {
            guard case .sampleStart = event else { continue }
            let line = FASTQBatchImporter.encodeLogEvent(event)
            return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
        return nil
    }
}
