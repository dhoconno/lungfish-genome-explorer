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
/// `_2` pair by file name (lane F9). These tests cover the check that keeps
/// the join only when the first reads bear it out (findings F9-S1 and
/// F9-N1), and what the import does with a joined sample. Trim Galore
/// cannot store it without leaving reads out, and failed deep in the
/// pipeline with a message that named neither the run nor the file (F9-N2).
/// The per-sample log and the `sampleStart` event named only the pair
/// (F9-N3).
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

    // MARK: - The check (F9-S1, F9-N1)

    func testAThirdFileJoinsWhenThePairsFirstReadsAreMatesAndItsFirstReadIsAnotherSpot() throws {
        // fasterq-dump names both mates of a spot alike, ENA writes /1 and /2
        // after the spot number, and Illumina writes 1:N: and 2:N: comments.
        let styles: [(folder: String, ext: String, name: (Int, Int) -> String)] = [
            ("identical", ".fastq", { spot, _ in "SRR1.\(spot) \(spot) length=8" }),
            ("identical-gzip", ".fastq.gz", { spot, _ in "SRR1.\(spot) \(spot) length=8" }),
            ("ena", ".fastq.gz", { spot, mate in "SRR1.\(spot) \(spot)/\(mate)" }),
            ("slash", ".fastq", { spot, mate in "SRR1.\(spot)/\(mate)" }),
            ("illumina", ".fastq", { spot, mate in "A00123:8:H5:1:1101:\(spot):1000 \(mate):N:0:ACGT" }),
        ]
        for style in styles {
            let files = try writeFiles(style.folder, [
                "SRR1_1\(style.ext)": Self.fastq([style.name(1, 1), style.name(2, 1)]),
                "SRR1_2\(style.ext)": Self.fastq([style.name(1, 2), style.name(2, 2)]),
                "SRR1\(style.ext)": Self.fastq([style.name(3, 1)]),
            ])
            let detected = FASTQBatchImporter.detectPairs(from: files)

            let check = FASTQBatchImporter.checkingUnpairedReads(detected)

            XCTAssertEqual(check.samples.map(\.inputFiles), detected.map(\.inputFiles), style.folder)
            XCTAssertEqual(check.samples.map { $0.unpaired?.lastPathComponent }, ["SRR1\(style.ext)"], style.folder)
            XCTAssertTrue(check.warnings.isEmpty, "\(style.folder): \(check.warnings)")
        }
    }

    func testMatesNamedDotOneAndDotTwoLeaveTheThirdFileOutAsASampleOfItsOwn() throws {
        let files = try writeFiles("dots", [
            "SRR2_1.fastq": Self.fastq(["SRR2.1.1 1 length=8", "SRR2.2.1 2 length=8"]),
            "SRR2_2.fastq": Self.fastq(["SRR2.1.2 1 length=8", "SRR2.2.2 2 length=8"]),
            "SRR2.fastq": Self.fastq(["SRR2.3.1 3 length=8"]),
        ])

        let check = FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.detectPairs(from: files))

        // The pair, then the third file as a sample of the same name, which
        // is what detection gave before the join.
        XCTAssertEqual(check.samples.map(\.sampleName), ["SRR2", "SRR2"])
        XCTAssertEqual(
            check.samples.map { $0.inputFiles.map(\.lastPathComponent) },
            [["SRR2_1.fastq", "SRR2_2.fastq"], ["SRR2.fastq"]]
        )
        XCTAssertNil(check.samples[0].unpaired)
        XCTAssertEqual(check.warnings.count, 1)
        guard case .notice(let sample, let message)? = check.warnings.first else {
            return XCTFail("expected a notice, got \(check.warnings)")
        }
        XCTAssertEqual(sample, "SRR2")
        XCTAssertEqual(
            message,
            "SRR2.fastq was not joined to SRR2_1.fastq and SRR2_2.fastq as reads whose mate is missing, because the "
                + "names of their first reads, SRR2.1.1 and SRR2.1.2, do not mark the two as mates. The pair imports "
                + "without it, and SRR2.fastq is a separate sample named SRR2."
        )
    }

    func testAThirdFileThatStartsWithAReadOfThePairsFirstFragmentIsNotJoined() throws {
        // The pair's first reads, then the third file's first read.
        let cases: [(pair: [String], third: String)] = [
            (["S.1 1 length=8", "S.1 1 length=8"], "S.1 1 length=8"),
            (["S.1/1", "S.1/2"], "S.1/1"),
            (["S.1/1", "S.1/2"], "S.1/2"),
            (["M:1:FC:1:1:5:7 1:N:0:1", "M:1:FC:1:1:5:7 2:N:0:1"], "M:1:FC:1:1:5:7 1:N:0:1"),
            (["S.1", "S.1"], "S.1/1"),
        ]
        for (index, item) in cases.enumerated() {
            let files = try writeFiles("copy-\(index)", [
                "S_1.fastq": Self.fastq([item.pair[0]]),
                "S_2.fastq": Self.fastq([item.pair[1]]),
                "S.fastq": Self.fastq([item.third]),
            ])

            let check = FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.detectPairs(from: files))

            XCTAssertEqual(check.samples.count, 2, "\(item)")
            XCTAssertNil(check.samples.first?.unpaired, "\(item)")
            guard case .notice(_, let message)? = check.warnings.first else {
                XCTFail("expected a notice for \(item)")
                continue
            }
            XCTAssertTrue(
                message.contains("because its first read, \(item.third.prefix { $0 != " " }), belongs to the same fragment as the pair's first reads, so the file looks like a copy of the pair."),
                message
            )
        }
    }

    func testAThirdFileWithoutAWholeFirstRecordIsNotJoined() throws {
        let cases: [(name: String, bytes: Data, reason: String)] = [
            ("SRR3.fastq", Data(), "it holds no reads"),
            ("SRR3.fastq", Data("@SRR3.3 3 length=8\nGATTACAG\n+\nIII\n".utf8), "it does not start with a complete FASTQ record"),
            ("SRR3.fastq", Data("@SRR3.3 3 length=8\nGATTACAG\n".utf8), "it does not start with a complete FASTQ record"),
            ("SRR3.fastq", Data("SRR3.3 3 length=8\nGATTACAG\n+\nIIIIIIII\n".utf8), "it does not start with a complete FASTQ record"),
            ("SRR3.fastq", Data("@SRR3.3 3 length=8\nGATTACAG\n-\nIIIIIIII\n".utf8), "it does not start with a complete FASTQ record"),
            ("SRR3.fastq.gz", Data([0x1F, 0x8B]) + Data("not gzip".utf8), "it could not be read"),
        ]
        for (index, item) in cases.enumerated() {
            let folder = root.appendingPathComponent("short-\(index)", isDirectory: true)
            var files = try writeFiles("short-\(index)", [
                "SRR3_1.fastq": Self.fastq(["SRR3.1 1 length=8"]),
                "SRR3_2.fastq": Self.fastq(["SRR3.1 1 length=8"]),
            ])
            let third = folder.appendingPathComponent(item.name)
            try item.bytes.write(to: third)
            files.append(third)

            let check = FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.detectPairs(from: files))

            XCTAssertEqual(check.samples.map { $0.inputFiles.count }, [2, 1], item.reason)
            guard case .notice(_, let message)? = check.warnings.first else {
                XCTFail("expected a notice for case \(index)")
                continue
            }
            XCTAssertTrue(
                message.hasPrefix("\(item.name) was not joined to SRR3_1.fastq and SRR3_2.fastq as reads whose mate is missing, because \(item.reason)."),
                message
            )
        }
    }

    func testAPairWithoutAWholeFirstRecordKeepsTheThirdFileOut() throws {
        let files = try writeFiles("empty-mate", [
            "SRR4_1.fastq": "",
            "SRR4_2.fastq": Self.fastq(["SRR4.1 1 length=8"]),
            "SRR4.fastq": Self.fastq(["SRR4.2 2 length=8"]),
        ])

        let check = FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.detectPairs(from: files))

        XCTAssertEqual(check.samples.map { $0.inputFiles.count }, [2, 1])
        guard case .notice(_, let message)? = check.warnings.first else {
            return XCTFail("expected a notice")
        }
        XCTAssertTrue(message.contains("as reads whose mate is missing, because SRR4_1.fastq holds no reads."), message)
    }

    func testTheCheckReadsOnlyJoinedSamplesAndKeepsEachSamplesPlaceAndFolder() throws {
        // Files of samples with no third file are never opened, so these
        // paths need not exist.
        let missing = URL(fileURLWithPath: "/nonexistent-f10")
        let run = try writeFiles("sub", [
            "SRR5_1.fastq": Self.fastq(["SRR5.1.1 1 length=8"]),
            "SRR5_2.fastq": Self.fastq(["SRR5.1.2 1 length=8"]),
            "SRR5.fastq": Self.fastq(["SRR5.2.1 2 length=8"]),
        ]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let samples = [
            SamplePair(sampleName: "A", r1: missing.appendingPathComponent("A_R1.fastq"), r2: missing.appendingPathComponent("A_R2.fastq")),
            SamplePair(sampleName: "SRR5", r1: run[1], r2: run[2], unpaired: run[0], relativePath: "sub"),
            SamplePair(sampleName: "Z", r1: missing.appendingPathComponent("Z.fastq"), r2: nil),
        ]

        let check = FASTQBatchImporter.checkingUnpairedReads(samples)

        XCTAssertEqual(check.samples.map(\.sampleName), ["A", "SRR5", "SRR5", "Z"])
        XCTAssertEqual(check.samples.map(\.relativePath), [nil, "sub", "sub", nil])
        XCTAssertEqual(check.samples[1].inputFiles, [run[1], run[2]])
        XCTAssertEqual(check.samples[2].inputFiles, [run[0]])
        XCTAssertEqual(check.warnings.count, 1)
        XCTAssertTrue(FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.applyPairing(.single, to: samples)).warnings.isEmpty)
    }

    func testAnImportOfAJoinThatSkippedTheCheckFailsWithTheReasonAndWritesNothing() async throws {
        // `import fastq` runs the check first. A caller that does not gets
        // the reason, where the join said the mate files were out of step.
        let files = try writeFiles("unchecked", [
            "SRR6_1.fastq": Self.fastq(["SRR6.1.1 1 length=8"]),
            "SRR6_2.fastq": Self.fastq(["SRR6.1.2 1 length=8"]),
            "SRR6.fastq": Self.fastq(["SRR6.2.1 2 length=8"]),
        ])

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: FASTQBatchImporter.detectPairs(from: files),
            config: config()
        )

        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(
            result.errors.first?.error,
            "SRR6.fastq was not joined to SRR6_1.fastq and SRR6_2.fastq as reads whose mate is missing, because the "
                + "names of their first reads, SRR6.1.1 and SRR6.1.2, do not mark the two as mates. Import the pair "
                + "without it."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports/SRR6.lungfishfastq").path))
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

    /// Writes files into their own folder and returns them. A name ending
    /// in `.gz` is gzip compressed.
    private func writeFiles(_ folderName: String, _ files: [String: String]) throws -> [URL] {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try files.keys.sorted().map { name in
            let url = folder.appendingPathComponent(name)
            let text = Data(files[name, default: ""].utf8)
            guard name.hasSuffix(".gz") else {
                try text.write(to: url)
                return url
            }
            let plain = folder.appendingPathComponent("\(name).plain")
            try text.write(to: plain)
            try KrakenOutputCompactor.gzipCopy(source: plain, destination: url)
            try FileManager.default.removeItem(at: plain)
            return url
        }
    }

    /// One eight-base record per header, given without its `@`.
    private static func fastq(_ headers: [String]) -> String {
        headers.map { "@\($0)\nACGTACGT\n+\nIIIIIIII\n" }.joined()
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
