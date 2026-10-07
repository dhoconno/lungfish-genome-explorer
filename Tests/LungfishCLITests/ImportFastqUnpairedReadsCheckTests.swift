// ImportFastqUnpairedReadsCheckTests.swift - import fastq joins a run's third file only when its reads can be trusted
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// `import fastq` joins a run's third file, `<run>.fastq` beside `<run>_1`
/// and `<run>_2`, to the pair by its name alone (lane F9). A name is not
/// enough. Mates named `SRR123.1.1` and `SRR123.1.2`, as `fastq-dump
/// --split-3 --readids` writes them, are not mates to the rule the join
/// checks every pair with, so the whole sample failed with a message that
/// blamed the order of files that are in step (finding F9-S1). An
/// interleaved copy of the pair named after the sample was stored beside the
/// pair, so the bundle held every read twice (F9-N1).
///
/// The third file now joins only when the first reads show it holds the
/// run's reads without a mate. Otherwise the pair imports on its own and the
/// third file stays a sample of its own, as before the join, and a warning
/// names the file and says why, in the text output, in a dry run, and as a
/// JSON notice the window's Operations row logs. A copy of the pair that
/// starts at another pair still joined (F10-N1), and the warning promised
/// that the pair imports even when the reason was the pair's own file
/// (F10-N2).
final class ImportFastqUnpairedReadsCheckTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-fastq-unpaired-check")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Mates named .1 and .2 (F9-S1)

    func testMatesNamedDotOneAndDotTwoImportAsAPairAndTheThirdFileIsLeftOutWithAWarning() async throws {
        let folder = try writeRun("SRR123", files: [
            "SRR123_1.fastq": Self.records([("SRR123.1.1", 1), ("SRR123.2.1", 2), ("SRR123.3.1", 3)], bases: "ACGTACGT"),
            "SRR123_2.fastq": Self.records([("SRR123.1.2", 1), ("SRR123.2.2", 2), ("SRR123.3.2", 3)], bases: "TTGGCCAA"),
            "SRR123.fastq": Self.records([("SRR123.4.1", 4)], bases: "GATTACAG"),
        ])

        let run = try await runImport([folder.path])

        XCTAssertNil(run.error, "the pair imports and the command exits 0. Output:\n\(run.output)")
        // The whole warning, so the skip below is tied to its words (F11-S1).
        XCTAssertTrue(
            run.output.contains(
                "SRR123.fastq was not joined to SRR123_1.fastq and SRR123_2.fastq as reads whose mate is missing, "
                    + "because the names of their first reads, SRR123.1.1 and SRR123.1.2, do not mark the two as mates. "
                    + "The pair imports without it, and SRR123.fastq is a separate sample named SRR123, which the "
                    + "import skips once the pair's bundle exists."
            ),
            run.output
        )
        let bundle = try importedBundle("SRR123")
        XCTAssertEqual(
            try Self.headers(in: bundle),
            ["SRR123.1.1 1", "SRR123.1.2 1", "SRR123.2.1 2", "SRR123.2.2 2", "SRR123.3.1 3", "SRR123.3.2 3"]
                .map { "\($0) length=8" },
            "the pair imports by position, as it did before the third file was joined"
        )
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))))
        XCTAssertNil(metadata.readClassification, "the bundle holds the pairs alone")
        XCTAssertEqual(metadata.ingestion?.originalFilenames, ["SRR123_1.fastq", "SRR123_2.fastq"])
        // The third file is a sample of the same name, which the pair's
        // bundle keeps out, as before the join.
        let skips = Self.jsonEvents(in: run.output).filter { $0["event"] as? String == "sampleSkip" }
        XCTAssertEqual(skips.map { $0["sample"] as? String }, ["SRR123"], run.output)
        XCTAssertEqual(skips.first?["reason"] as? String, "Bundle already exists")
    }

    func testADryRunShowsTheWarningAndListsTheThirdFileAsItsOwnSample() async throws {
        let folder = try writeRun("SRR124", files: [
            "SRR124_1.fastq": Self.records([("SRR124.1.1", 1)], bases: "ACGTACGT"),
            "SRR124_2.fastq": Self.records([("SRR124.1.2", 1)], bases: "TTGGCCAA"),
            "SRR124.fastq": Self.records([("SRR124.2.1", 2)], bases: "GATTACAG"),
        ])

        let run = try await runImport([folder.path], ["--dry-run"])

        XCTAssertNil(run.error, run.output)
        XCTAssertTrue(run.output.contains("SRR124.fastq was not joined to SRR124_1.fastq and SRR124_2.fastq"), run.output)
        XCTAssertFalse(run.output.contains("Unpaired: SRR124.fastq"), run.output)
        XCTAssertTrue(run.output.contains("SRR124  [single-end]"), "the third file is listed as its own sample\n\(run.output)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports").path))
    }

    func testNameNamesThePairWhenTheThirdFileIsLeftOut() async throws {
        // --name counts the samples detection made, one here. The check then
        // leaves the third file out, both samples take the name, the pair
        // imports under it and the third file's sample is skipped, as the
        // warning says. The command used to print that warning and then
        // refuse the run with "found 2", so the warning described an import
        // that never ran (F11-N2).
        let folder = try writeRun("SRR126", files: [
            "SRR126_1.fastq": Self.records([("SRR126.1.1", 1)], bases: "ACGTACGT"),
            "SRR126_2.fastq": Self.records([("SRR126.1.2", 1)], bases: "TTGGCCAA"),
            "SRR126.fastq": Self.records([("SRR126.2.1", 2)], bases: "GATTACAG"),
        ])

        let run = try await runImport([folder.path], ["--name", "Patient7"])

        XCTAssertNil(run.error, run.output)
        XCTAssertFalse(run.output.contains("--name requires exactly one detected sample"), run.output)
        XCTAssertTrue(
            run.output.contains(
                "Patient7: SRR126.fastq was not joined to SRR126_1.fastq and SRR126_2.fastq as reads whose mate is "
                    + "missing, because the names of their first reads, SRR126.1.1 and SRR126.1.2, do not mark the two "
                    + "as mates. The pair imports without it, and SRR126.fastq is a separate sample named Patient7, "
                    + "which the import skips once the pair's bundle exists."
            ),
            run.output
        )
        XCTAssertEqual(
            try Self.headers(in: try importedBundle("Patient7")),
            ["SRR126.1.1 1 length=8", "SRR126.1.2 1 length=8"]
        )
        let skips = Self.jsonEvents(in: run.output).filter { $0["event"] as? String == "sampleSkip" }
        XCTAssertEqual(skips.compactMap { $0["sample"] as? String }, ["Patient7"], run.output)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: project.appendingPathComponent("Imports").path)
                .filter { !$0.hasPrefix(".") },
            ["Patient7.lungfishfastq"]
        )
    }

    func testNameStillRefusesTwoSamplesThatDetectionMade() async throws {
        let folder = try writeRun("two", files: [
            "A.fastq": Self.records([("A.1", 1)], bases: "ACGTACGT"),
            "B.fastq": Self.records([("B.1", 1)], bases: "ACGTACGT"),
        ])

        let run = try await runImport([folder.path], ["--name", "Patient8"])

        XCTAssertNotNil(run.error, run.output)
        XCTAssertTrue(run.output.contains("--name requires exactly one detected sample (found 2)."), run.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("Imports").path))
    }

    func testForceNeverLetsTheThirdFileReplaceThePairsBundle() async throws {
        // f10-report.md, concern 1. The check leaves the third file out, so
        // the pair and the third file are two samples of the run's name. With
        // --force the third file imported second and replaced the pair's
        // bundle with a bundle of its own reads.
        let folder = try writeRun("SRR131", files: [
            "SRR131_1.fastq": Self.records([("SRR131.1.1", 1), ("SRR131.2.1", 2)], bases: "ACGTACGT"),
            "SRR131_2.fastq": Self.records([("SRR131.1.2", 1), ("SRR131.2.2", 2)], bases: "TTGGCCAA"),
            "SRR131.fastq": Self.records([("SRR131.3.1", 3)], bases: "GATTACAG"),
        ])

        let run = try await runImport([folder.path], ["--force"])

        XCTAssertNil(run.error, run.output)
        XCTAssertEqual(
            try Self.headers(in: try importedBundle("SRR131")),
            ["SRR131.1.1 1", "SRR131.1.2 1", "SRR131.2.1 2", "SRR131.2.2 2"].map { "\($0) length=8" },
            "the pair's bundle keeps the pair"
        )
        let skips = Self.jsonEvents(in: run.output).filter { $0["event"] as? String == "sampleSkip" }
        XCTAssertEqual(skips.compactMap { $0["sample"] as? String }, ["SRR131"], run.output)
        XCTAssertTrue((skips.first?["reason"] as? String)?.contains("An earlier sample of this import wrote it") == true, run.output)
    }

    func testTheWindowsJSONOutputCarriesTheWarningAsANoticeEvent() async throws {
        let folder = try writeRun("SRR125", files: [
            "SRR125_1.fastq": Self.records([("SRR125.1.1", 1), ("SRR125.2.1", 2)], bases: "ACGTACGT"),
            "SRR125_2.fastq": Self.records([("SRR125.1.2", 1), ("SRR125.2.2", 2)], bases: "TTGGCCAA"),
            "SRR125.fastq": Self.records([("SRR125.3.1", 3)], bases: "GATTACAG"),
        ])
        let files = ["SRR125_1.fastq", "SRR125_2.fastq", "SRR125.fastq"].map { folder.appendingPathComponent($0).path }

        // The arguments `sraImportCLIArguments` builds for a run with no recipe.
        let run = try await runImport(files, [
            "--pairing", "paired", "--format", "json", "--compression", "balanced",
        ])

        XCTAssertNil(run.error, run.output)
        // CLIImportRunner logs a notice event in the Operations row as a warning.
        let notices = Self.jsonEvents(in: run.output).filter { $0["event"] as? String == "notice" }
        let notice = try XCTUnwrap(
            notices.first { ($0["message"] as? String)?.contains("was not joined") == true },
            run.output
        )
        XCTAssertEqual(notice["sample"] as? String, "SRR125")
        XCTAssertTrue((notice["message"] as? String)?.hasPrefix("SRR125.fastq was not joined to SRR125_1.fastq and SRR125_2.fastq") == true)
        XCTAssertEqual(try Self.headers(in: try importedBundle("SRR125")).count, 4, "the pair imports on its own")
    }

    // MARK: - A copy of the pair (F9-N1)

    func testAnInterleavedCopyOfThePairIsNotJoinedSoEachReadIsStoredOnce() async throws {
        // reformat.sh or seqtk mergepe writes the pair into one file, each R1
        // record followed by its R2 record. Here the mates are gzip files.
        let pairs = [1, 2, 3]
        let folder = try writeRun("S", files: [
            "S_1.fq.gz": Self.records(pairs.map { ("S.\($0)/1", $0) }, bases: "ACGTACGT"),
            "S_2.fq.gz": Self.records(pairs.map { ("S.\($0)/2", $0) }, bases: "TTGGCCAA"),
            "S.fastq": pairs.map {
                Self.records([("S.\($0)/1", $0)], bases: "ACGTACGT") + Self.records([("S.\($0)/2", $0)], bases: "TTGGCCAA")
            }.joined(),
        ])

        let run = try await runImport([folder.path])

        XCTAssertNil(run.error, run.output)
        XCTAssertTrue(
            run.output.contains(
                "S.fastq was not joined to S_1.fq.gz and S_2.fq.gz as reads whose mate is missing, because its first read, S.1/1, "
                    + "belongs to the same fragment as the pair's first reads, so the file looks like a copy of the pair."
            ),
            run.output
        )
        let headers = try Self.headers(in: try importedBundle("S"))
        XCTAssertEqual(headers.count, 6, "each read is stored once, not twice")
        XCTAssertEqual(Set(headers).count, 6)
    }

    func testAnInterleavedCopyOfThePairInAnotherOrderIsNotJoinedSoEachReadIsStoredOnce() async throws {
        // clumpify.sh in=T_1.fastq in2=T_2.fastq out=T.fastq writes the pairs
        // in its own order, and a filter that drops the first pair starts its
        // copy at the second, here from gzip files. Neither copy starts with
        // a read of the pair's first fragment, but each starts with both
        // reads of one fragment, which a file of reads whose mate is missing
        // never does (F10-N1).
        let pairs = [1, 2, 3, 4]
        func copy(of run: String, inOrder order: [Int]) -> String {
            order.map {
                Self.records([("\(run).\($0)/1", $0)], bases: "ACGTACGT")
                    + Self.records([("\(run).\($0)/2", $0)], bases: "TTGGCCAA")
            }.joined()
        }
        let folder = try writeRun("copies", files: [
            "S_1.fastq.gz": Self.records(pairs.map { ("S.\($0)/1", $0) }, bases: "ACGTACGT"),
            "S_2.fastq.gz": Self.records(pairs.map { ("S.\($0)/2", $0) }, bases: "TTGGCCAA"),
            "S.fastq.gz": copy(of: "S", inOrder: [2, 3, 4]),
            "T_1.fastq": Self.records(pairs.map { ("T.\($0)/1", $0) }, bases: "ACGTACGT"),
            "T_2.fastq": Self.records(pairs.map { ("T.\($0)/2", $0) }, bases: "TTGGCCAA"),
            "T.fastq": copy(of: "T", inOrder: [3, 1, 4, 2]),
        ])

        let run = try await runImport([folder.path])

        XCTAssertNil(run.error, run.output)
        for (sample, ext, firstPair) in [("S", ".fastq.gz", 2), ("T", ".fastq", 3)] {
            XCTAssertTrue(
                run.output.contains(
                    "\(sample): \(sample)\(ext) was not joined to \(sample)_1\(ext) and \(sample)_2\(ext) as reads "
                        + "whose mate is missing, because its first two reads, \(sample).\(firstPair)/1 and "
                        + "\(sample).\(firstPair)/2, belong to one fragment, so the file looks like a copy of the pair. "
                        + "The pair imports without it, and \(sample)\(ext) is a separate sample named \(sample), "
                        + "which the import skips once the pair's bundle exists."
                ),
                run.output
            )
            let headers = try Self.headers(in: try importedBundle(sample))
            XCTAssertEqual(headers.count, 8, "\(sample): each read is stored once, not twice")
            XCTAssertEqual(Set(headers).count, 8, sample)
        }
        // As the warning says, each copy is a sample of its own that the
        // pair's bundle keeps out.
        let skips = Self.jsonEvents(in: run.output).filter { $0["event"] as? String == "sampleSkip" }
        XCTAssertEqual(skips.compactMap { $0["sample"] as? String }, ["S", "T"], run.output)
        XCTAssertEqual(Set(skips.compactMap { $0["reason"] as? String }), ["Bundle already exists"])
    }

    func testACopyOfThePairThatStartsWithHalfAPairIsNotJoinedSoEachReadIsStoredOnce() async throws {
        // A filter that judged one read at a time dropped U.1/1, U.1/2 and
        // U.2/1, so the copy starts with U.2/2 and then holds whole pairs
        // (F11-N1). It joined and stored those reads a second time.
        let folder = try writeRun("U", files: [
            "U_1.fastq": Self.records((1...4).map { ("U.\($0)/1", $0) }, bases: "ACGTACGT"),
            "U_2.fastq": Self.records((1...4).map { ("U.\($0)/2", $0) }, bases: "TTGGCCAA"),
            "U.fastq": Self.records([("U.2/2", 2)], bases: "TTGGCCAA")
                + [3, 4].map {
                    Self.records([("U.\($0)/1", $0)], bases: "ACGTACGT") + Self.records([("U.\($0)/2", $0)], bases: "TTGGCCAA")
                }.joined(),
        ])

        let run = try await runImport([folder.path])

        XCTAssertNil(run.error, run.output)
        XCTAssertTrue(
            run.output.contains(
                "U.fastq was not joined to U_1.fastq and U_2.fastq as reads whose mate is missing, because its reads "
                    + "2 and 3, U.3/1 and U.3/2, belong to one fragment, so the file looks like a copy of the pair."
            ),
            run.output
        )
        let headers = try Self.headers(in: try importedBundle("U"))
        XCTAssertEqual(headers.count, 8, "each read is stored once, not twice")
        XCTAssertEqual(Set(headers).count, 8)
    }

    // MARK: - What the warning says follows (F10-N2)

    func testAWarningAboutAMateFileDoesNotPromiseThatThePairImports() async throws {
        // The download of SRR130_1.fastq stopped before its first read.
        let folder = try writeRun("SRR130", files: [
            "SRR130_1.fastq": "",
            "SRR130_2.fastq": Self.records([("SRR130.1", 1), ("SRR130.2", 2)], bases: "TTGGCCAA"),
            "SRR130.fastq": Self.records([("SRR130.3", 3)], bases: "GATTACAG"),
        ])

        let run = try await runImport([folder.path])

        XCTAssertTrue(
            run.output.contains(
                "SRR130: SRR130.fastq was not joined to SRR130_1.fastq and SRR130_2.fastq as reads whose mate is "
                    + "missing, because SRR130_1.fastq holds no reads. The pair and SRR130.fastq are imported as "
                    + "separate samples, as they were before the join."
            ),
            run.output
        )
        XCTAssertFalse(run.output.contains("The pair imports without it"), run.output)
        // What follows is what the warning says. The pair fails on its empty
        // mate file, and SRR130.fastq imports as a sample of its own.
        XCTAssertNotNil(run.error, "the pair is a failed sample. Output:\n\(run.output)")
        let failures = Self.jsonEvents(in: run.output).filter { $0["event"] as? String == "sampleFailed" }
        XCTAssertEqual(failures.count, 1, run.output)
        XCTAssertTrue((failures.first?["error"] as? String)?.contains("SRR130_1.fastq") == true, run.output)
        let bundle = try importedBundle("SRR130")
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))))
        XCTAssertEqual(metadata.ingestion?.originalFilenames, ["SRR130.fastq"])
        XCTAssertEqual(try Self.headers(in: bundle), ["SRR130.3 3 length=8"])
    }

    // MARK: - A third file with no whole record

    func testAnEmptyThirdFileIsNotJoined() async throws {
        let folder = try writeRun("SRR127", files: [
            "SRR127_1.fastq": Self.records([("SRR127.1", 1), ("SRR127.2", 2)], bases: "ACGTACGT"),
            "SRR127_2.fastq": Self.records([("SRR127.1", 1), ("SRR127.2", 2)], bases: "TTGGCCAA"),
            "SRR127.fastq": "",
        ])
        let files = ["SRR127_1.fastq", "SRR127_2.fastq", "SRR127.fastq"].map { folder.appendingPathComponent($0).path }

        let run = try await runImport(files)

        XCTAssertNil(run.error, run.output)
        XCTAssertTrue(
            run.output.contains("SRR127.fastq was not joined to SRR127_1.fastq and SRR127_2.fastq as reads whose mate is missing, because it holds no reads."),
            run.output
        )
        let bundle = try importedBundle("SRR127")
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))))
        XCTAssertEqual(metadata.ingestion?.originalFilenames, ["SRR127_1.fastq", "SRR127_2.fastq"])
        XCTAssertNil(metadata.readClassification)
        XCTAssertEqual(try Self.headers(in: bundle).count, 4)
    }

    func testAThirdFileWhoseFirstRecordIsCutShortIsNotJoined() async throws {
        let folder = try writeRun("SRR128", files: [
            "SRR128_1.fastq": Self.records([("SRR128.1", 1), ("SRR128.2", 2)], bases: "ACGTACGT"),
            "SRR128_2.fastq": Self.records([("SRR128.1", 1), ("SRR128.2", 2)], bases: "TTGGCCAA"),
            // The download stopped inside the first record.
            "SRR128.fastq": "@SRR128.3 3 length=8\nGATTACAG\n+\nIII",
        ])

        let run = try await runImport([folder.path])

        XCTAssertNil(run.error, "the pair imports and the command exits 0. Output:\n\(run.output)")
        XCTAssertTrue(
            run.output.contains(
                "SRR128.fastq was not joined to SRR128_1.fastq and SRR128_2.fastq as reads whose mate is missing, "
                    + "because it does not start with a complete FASTQ record."
            ),
            run.output
        )
        XCTAssertEqual(try Self.headers(in: try importedBundle("SRR128")).count, 4)
    }

    // MARK: - A run ENA lists as three files

    func testAThreeFileRunWithIdenticalMateNamesIsStillJoinedFromGzipFiles() async throws {
        let paired = [1, 2, 4, 5]
        let unpaired = [3, 6]
        let folder = try writeRun("SRR129", files: [
            "SRR129_1.fastq.gz": Self.records(paired.map { ("SRR129.\($0)", $0) }, bases: "ACGTACGT"),
            "SRR129_2.fastq.gz": Self.records(paired.map { ("SRR129.\($0)", $0) }, bases: "TTGGCCAA"),
            "SRR129.fastq.gz": Self.records(unpaired.map { ("SRR129.\($0)", $0) }, bases: "GATTACAG"),
        ])

        let run = try await runImport([folder.path])

        XCTAssertNil(run.error, run.output)
        XCTAssertFalse(run.output.contains("was not joined"), run.output)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports.path), ["SRR129.lungfishfastq"])
        let bundle = try importedBundle("SRR129")
        XCTAssertEqual(
            try Self.headers(in: bundle),
            ["1", "1", "2", "2", "4", "4", "5", "5", "3", "6"].map { "SRR129.\($0) \($0) length=8" }
        )
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))))
        XCTAssertEqual(metadata.readClassification?.pairedReadCount, 8)
        XCTAssertEqual(metadata.readClassification?.unpairedReadCount, 2)
        XCTAssertEqual(metadata.ingestion?.originalFilenames, ["SRR129_1.fastq.gz", "SRR129_2.fastq.gz", "SRR129.fastq.gz"])
        XCTAssertEqual(metadata.ingestion?.pairingMode, .singleEnd, "labelled by its count, which holds single reads")
    }

    // MARK: - Helpers

    private struct ImportRun {
        let output: String
        let error: Error?
    }

    /// Runs `import fastq` in process and returns what it printed and the
    /// error it threw, if any. A thrown error is a non-zero exit status.
    private func runImport(_ inputs: [String], _ extra: [String] = []) async throws -> ImportRun {
        let command = try ImportCommand.FastqSubcommand.parse(inputs + [
            "--project", project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage", "--no-color",
        ] + extra)
        let outputFile = root.appendingPathComponent("stdout-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputFile)
        fflush(stdout)
        let savedStdout = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        var thrown: Error?
        do {
            try await command.run()
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(savedStdout, STDOUT_FILENO)
        close(savedStdout)
        try handle.close()
        return ImportRun(output: String(decoding: try Data(contentsOf: outputFile), as: UTF8.self), error: thrown)
    }

    private func importedBundle(_ sample: String) throws -> URL {
        let bundle = project.appendingPathComponent("Imports/\(sample).lungfishfastq", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "no bundle for \(sample)")
        return bundle
    }

    /// Writes one run's files into their own folder. A name ending in `.gz`
    /// is gzip compressed.
    private func writeRun(_ run: String, files: [String: String]) throws -> URL {
        let folder = root.appendingPathComponent("download-\(run)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files {
            let url = folder.appendingPathComponent(name)
            guard name.hasSuffix(".gz") else {
                try Data(text.utf8).write(to: url)
                continue
            }
            let plain = root.appendingPathComponent("\(run)-\(name).plain")
            try Data(text.utf8).write(to: plain)
            try KrakenOutputCompactor.gzipCopy(source: plain, destination: url)
            try FileManager.default.removeItem(at: plain)
        }
        return folder
    }

    /// FASTQ records named as fasterq-dump names them, `@<id> <spot> length=8`.
    private static func records(_ reads: [(id: String, spot: Int)], bases: String) -> String {
        reads.map { "@\($0.id) \($0.spot) length=\(bases.count)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n" }.joined()
    }

    /// Every record header of the bundle's FASTQ, in file order.
    private static func headers(in bundle: URL) throws -> [String] {
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        return try FASTQReadLayoutClassifier.readHeaders(from: fastq, limit: 1_000).headers
    }

    /// The JSON objects among the printed lines.
    private static func jsonEvents(in output: String) -> [[String: Any]] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("{"),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { return nil }
            return object
        }
    }
}
