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
/// (F9-N3). An interleaved copy of the pair that starts at another pair
/// still joined (F10-N1), and the warning promised that the pair imports
/// even when the reason was the pair's own file (F10-N2).
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
        // The third file holds one read of each of two other spots, so its
        // first two reads are compared and are not mates.
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
                "SRR1\(style.ext)": Self.fastq([style.name(3, 1), style.name(6, 2)]),
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
        // The pair imports by position, as a pair of files always does, so
        // the third file's own sample is skipped, and the warning says so.
        // It used to say that both import as separate samples (F11-S1).
        XCTAssertEqual(
            message,
            "SRR2.fastq was not joined to SRR2_1.fastq and SRR2_2.fastq as reads whose mate is missing, because the "
                + "names of their first reads, SRR2.1.1 and SRR2.1.2, do not mark the two as mates. The pair imports "
                + "without it, and SRR2.fastq is a separate sample named SRR2, which the import skips."
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
            // The reason is about the third file, so the pair imports, and
            // the warning says the third file's own sample is skipped (F10-N2).
            XCTAssertEqual(
                message,
                "\(item.name) was not joined to SRR3_1.fastq and SRR3_2.fastq as reads whose mate is missing, because "
                    + "\(item.reason). The pair imports without it, and \(item.name) is a separate sample named SRR3, "
                    + "which the import skips."
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
        // An empty SRR4_1.fastq fails the pair as well, so the warning never
        // promises that the pair imports (F10-N2). SRR4.fastq is skipped
        // whether or not it does, so the run's name never holds its reads
        // whose mate is missing alone (review B-S2).
        XCTAssertEqual(
            message,
            "SRR4.fastq was not joined to SRR4_1.fastq and SRR4_2.fastq as reads whose mate is missing, because "
                + "SRR4_1.fastq holds no reads. SRR4.fastq is a separate sample named SRR4, which the import skips "
                + "whether or not the pair imports."
        )
    }

    // MARK: - A copy of the pair in another order (F10-N1)

    func testAnInterleavedCopyOfThePairThatStartsAtAnotherPairIsNotJoined() throws {
        // The pair holds fragments 1 to 4. Each copy starts at another
        // fragment, as a copy does that a filter started at another spot or
        // that clumpify wrote in its own order, so its first read is not of
        // the pair's first fragment. A file of reads whose mate is missing
        // holds one read of each spot, so its first two reads are never
        // mates, while an interleaved copy starts with both reads of one
        // fragment, in either order.
        let styles: [(folder: String, ext: String, name: (Int, Int) -> String)] = [
            ("slash", ".fastq", { spot, mate in "S.\(spot)/\(mate)" }),
            ("identical-gzip", ".fastq.gz", { spot, _ in "S.\(spot) \(spot) length=8" }),
            ("ena-gzip", ".fastq.gz", { spot, mate in "S.\(spot) \(spot)/\(mate)" }),
            ("illumina", ".fastq", { spot, mate in "A00123:8:H5:1:1101:\(spot):1000 \(mate):N:0:ACGT" }),
        ]
        let orders: [(name: String, reads: [(spot: Int, mate: Int)])] = [
            ("from-the-second-pair", [(2, 1), (2, 2), (3, 1), (3, 2), (4, 1), (4, 2)]),
            ("from-the-last-pair", [(4, 1), (4, 2), (1, 1), (1, 2), (2, 1), (2, 2), (3, 1), (3, 2)]),
            ("shuffled-pairs", [(3, 1), (3, 2), (1, 1), (1, 2), (4, 1), (4, 2), (2, 1), (2, 2)]),
            ("second-mate-first", [(2, 2), (2, 1), (1, 2), (1, 1), (3, 2), (3, 1), (4, 2), (4, 1)]),
        ]
        for style in styles {
            for order in orders {
                let label = "\(style.folder) \(order.name)"
                let files = try writeFiles("\(style.folder)-\(order.name)", [
                    "S_1\(style.ext)": Self.fastq((1...4).map { style.name($0, 1) }),
                    "S_2\(style.ext)": Self.fastq((1...4).map { style.name($0, 2) }),
                    "S\(style.ext)": Self.fastq(order.reads.map { style.name($0.spot, $0.mate) }),
                ])

                let check = FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.detectPairs(from: files))

                XCTAssertEqual(
                    check.samples.map { $0.inputFiles.map(\.lastPathComponent) },
                    [["S_1\(style.ext)", "S_2\(style.ext)"], ["S\(style.ext)"]],
                    label
                )
                XCTAssertNil(check.samples.first?.unpaired, label)
                guard case .notice(let sample, let message)? = check.warnings.first else {
                    XCTFail("expected a notice for \(label)")
                    continue
                }
                let firstTwo = order.reads.prefix(2).map { style.name($0.spot, $0.mate).prefix { $0 != " " } }
                XCTAssertEqual(sample, "S", label)
                XCTAssertEqual(
                    message,
                    "S\(style.ext) was not joined to S_1\(style.ext) and S_2\(style.ext) as reads whose mate is "
                        + "missing, because its first two reads, \(firstTwo[0]) and \(firstTwo[1]), belong to one "
                        + "fragment, so the file looks like a copy of the pair. The pair imports without it, and "
                        + "S\(style.ext) is a separate sample named S, which the import skips.",
                    label
                )
            }
        }
    }

    // MARK: - A copy of the pair that starts with half a pair (F11-N1)

    func testACopyOfThePairThatStartsWithHalfAPairIsNotJoined() throws {
        // A filter that judged one read at a time dropped S.1/1, S.1/2 and
        // S.2/1, so the copy starts with S.2/2, whose mate is gone, and then
        // holds whole pairs. Its first read is not of the pair's first
        // fragment and its first two reads are not mates, so it joined and
        // its reads were stored a second time beside the pair.
        let cases: [(label: String, reads: [String], read: Int)] = [
            ("half-a-pair", ["S.2/2", "S.3/1", "S.3/2", "S.4/1", "S.4/2"], 2),
            ("mates-meet-later", ["S.2/2", "S.3/1", "S.4/2", "S.5/1", "S.6/1", "S.6/2"], 5),
        ]
        for item in cases {
            let files = try writeFiles(item.label, [
                "S_1.fastq": Self.fastq((1...6).map { "S.\($0)/1" }),
                "S_2.fastq": Self.fastq((1...6).map { "S.\($0)/2" }),
                "S.fastq": Self.fastq(item.reads),
            ])

            let check = FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.detectPairs(from: files))

            XCTAssertEqual(
                check.samples.map { $0.inputFiles.map(\.lastPathComponent) },
                [["S_1.fastq", "S_2.fastq"], ["S.fastq"]],
                item.label
            )
            guard case .notice(_, let message)? = check.warnings.first else {
                XCTFail("expected a notice for \(item.label)")
                continue
            }
            XCTAssertEqual(
                message,
                "S.fastq was not joined to S_1.fastq and S_2.fastq as reads whose mate is missing, because its reads "
                    + "\(item.read) and \(item.read + 1), \(item.reads[item.read - 1]) and \(item.reads[item.read]), "
                    + "belong to one fragment, so the file looks like a copy of the pair. The pair imports without it, "
                    + "and S.fastq is a separate sample named S, which the import skips.",
                item.label
            )
        }
    }

    func testAnImportRefusesACopyWhoseMatesFirstMeetPastTheReadsTheCheckCompares() async throws {
        // The check compares the third file's first 1,000 reads. This file
        // holds 1,000 reads of other spots, then both reads of one fragment,
        // so it joins, and the import compares every adjacent pair as it
        // copies the file. It fails the sample with the file named rather
        // than store a read of the pair twice.
        let checked = 1_000
        let others = (1...checked).map { "S.\($0 + 10)/\($0 % 2 + 1)" }
        let files = try writeFiles("late-mates", [
            "S_1.fastq": Self.fastq(["S.1/1", "S.2/1"]),
            "S_2.fastq": Self.fastq(["S.1/2", "S.2/2"]),
            "S.fastq": Self.fastq(others + ["S.2/1", "S.2/2"]),
        ])
        let check = FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.detectPairs(from: files))
        XCTAssertTrue(check.warnings.isEmpty, "\(check.warnings)")
        XCTAssertNotNil(check.samples.first?.unpaired)

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: check.samples,
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project,
                platform: .given(.illumina),
                qualityBinning: QualityBinningScheme.none,
                optimizeStorage: false,
                threads: 1
            )
        )

        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failed, 1, "\(result.errors)")
        XCTAssertEqual(
            result.errors.first?.error,
            "S.fastq was not joined to S_1.fastq and S_2.fastq as reads whose mate is missing, because its reads "
                + "1001 and 1002, S.2/1 and S.2/2, belong to one fragment, so the file looks like a copy of the pair. "
                + "Import the pair without it."
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: project.appendingPathComponent("Imports/S.lungfishfastq").path
        ))
    }

    func testAThirdFileOfManyReadsWhoseMatesAreMissingStillJoins() async throws {
        // fasterq-dump names both reads of a spot alike, and the third file
        // holds one read of each of 1,500 other spots, past the reads the
        // check compares. No two of them are mates, so the run imports whole.
        let files = try writeFiles("many-orphans", [
            "SRR8_1.fastq.gz": Self.fastq((1...3).map { "SRR8.\($0) \($0) length=8" }),
            "SRR8_2.fastq.gz": Self.fastq((1...3).map { "SRR8.\($0) \($0) length=8" }),
            "SRR8.fastq.gz": Self.fastq((4...1_503).map { "SRR8.\($0) \($0) length=8" }),
        ])
        let check = FASTQBatchImporter.checkingUnpairedReads(FASTQBatchImporter.detectPairs(from: files))
        XCTAssertTrue(check.warnings.isEmpty, "\(check.warnings)")

        let result = await FASTQBatchImporter.runBatchImport(
            pairs: check.samples,
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project,
                platform: .given(.illumina),
                qualityBinning: QualityBinningScheme.none,
                optimizeStorage: false,
                threads: 1
            )
        )

        XCTAssertEqual(result.completed, 1, "\(result.errors)")
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(
            for: project.appendingPathComponent("Imports/SRR8.lungfishfastq", isDirectory: true)
        ))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(metadata.readClassification?.pairedReadCount, 6)
        XCTAssertEqual(metadata.readClassification?.unpairedReadCount, 1_500)
    }

    func testAThirdFileOfOneWholeRecordStillJoins() throws {
        // A run with one spot whose mate is missing has a third file of one
        // record, with no second read to compare. A second record that is
        // not whole does not stop the join either, even when its header is
        // the first read's mate. Only whole records are compared, and the
        // import then fails the sample and names the damaged file.
        let cases: [(folder: String, ext: String, text: String)] = [
            ("one-record", ".fastq", Self.fastq(["SRR7.3 3 length=8"])),
            ("one-record-gzip", ".fastq.gz", Self.fastq(["SRR7.3 3 length=8"])),
            ("cut-second-record", ".fastq", Self.fastq(["SRR7.3 3 length=8"]) + "@SRR7.3 3 length=8\nACGT\n"),
        ]
        for item in cases {
            let files = try writeFiles(item.folder, [
                "SRR7_1\(item.ext)": Self.fastq(["SRR7.1 1 length=8", "SRR7.2 2 length=8"]),
                "SRR7_2\(item.ext)": Self.fastq(["SRR7.1 1 length=8", "SRR7.2 2 length=8"]),
                "SRR7\(item.ext)": item.text,
            ])
            let detected = FASTQBatchImporter.detectPairs(from: files)

            let check = FASTQBatchImporter.checkingUnpairedReads(detected)

            XCTAssertEqual(check.samples.map(\.inputFiles), detected.map(\.inputFiles), item.folder)
            XCTAssertEqual(check.samples.map { $0.unpaired?.lastPathComponent }, ["SRR7\(item.ext)"], item.folder)
            XCTAssertTrue(check.warnings.isEmpty, "\(item.folder): \(check.warnings)")
        }
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
