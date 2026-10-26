// ImportFastqStagedReadsTests.swift - `import fastq --staged-reads`: a plan of reads in the Linux staging folder (CHTC C6 lane STAGED)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
import Foundation
import LungfishCore
import LungfishPortable
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// A plan of reads that exist only in the Linux staging folder (O59, ruling STAGED). The reads these tests name do not
/// exist on this Mac, which is the point: the plan takes each read's size and SHA-256 from the `--staged-reads` list and
/// never opens the read. Each assertion reads a written file, an event, an error or an exit code (QA 2).
final class ImportFastqStagedReadsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ImportFastqStagedReads")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private struct StagedRead {
        var path: String
        var size: Int64
        var sha256: String
        var name: String { (path as NSString).lastPathComponent }
    }

    private static let staging = "/staging/groups/g/1/lge-chtc-test"
    private static let casper = "\(staging)/input-casper"
    /// R1 and R2 of S1, then of S2, in the list's order.
    private static let reads = [
        StagedRead(path: "\(casper)/S1_1.fastq.gz", size: 5_000_000_000, sha256: String(repeating: "a", count: 64)),
        StagedRead(path: "\(casper)/S1_2.fastq.gz", size: 5_100_000_000, sha256: String(repeating: "b", count: 64)),
        StagedRead(path: "\(casper)/S2_1.fastq.gz", size: 6_000_000_000, sha256: String(repeating: "c", count: 64)),
        StagedRead(path: "\(casper)/S2_2.fastq.gz", size: 6_100_000_000, sha256: String(repeating: "d", count: 64)),
    ]
    private static let digest = String(repeating: "e", count: 64)

    /// The SHA-256 of `README.txt` that the base `61c4fe041` writes for a batch of reads on the Mac named `batch`, in
    /// the staging folder above, with the image `lge-tools-test.sif`.
    private static let baseReadmeSHA256 = "d549cc1fd3978f22263e96c31a118aa4f98f96d754171f0fcf4e600f8594c02d"

    // MARK: What a staged plan writes

    /// The plan pins each read by the list's SHA-256 and size and names it by its own file name, and the sample's original
    /// size is their sum. No list value reaches the sample sheet's labels, which keep the sheet's own column.
    func testStagedPlanPinsListValuesAndOpensNoRead() async throws {
        let fixture = try writeFixture()
        for read in Self.reads {
            XCTAssertFalse(FileManager.default.fileExists(atPath: read.path), "\(read.path) must not exist on this Mac")
        }
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try await ImportCommand.FastqSubcommand.parse(fixture.stagedArguments(folder: folder)).run()
        for (sample, reads) in [("S1", Array(Self.reads[0...1])), ("S2", Array(Self.reads[2...3]))] {
            let plan = try ExecutionPlan.decode(Data(contentsOf: folder.appendingPathComponent("\(sample)/plan.json")))
            let inputs = plan.entries.filter { $0.role == .input }
            XCTAssertEqual(inputs.map(\.sha256), reads.map(\.sha256), sample)
            XCTAssertEqual(inputs.map(\.size), reads.map(\.size), sample)
            XCTAssertEqual(plan.sample.originalSizeBytes, reads.reduce(Int64(0)) { $0 + $1.size }, sample)
            XCTAssertEqual(plan.sample.originalFilenames, reads.map(\.name), sample)
            XCTAssertEqual(plan.sample.sampleSheet, [PlanKeyValue(key: "site", value: "madison")], sample)
        }
    }

    /// Two files measured on this Mac and the same bytes declared in a list at staging paths give one `plan.json` for
    /// each sample, byte for byte: a staged plan is the plan of those bytes.
    func testStagedPlanEqualsMeasuredPlanOfSameBytes() async throws {
        let fixture = try writeFixture()
        let macReads = root.appendingPathComponent("mac-reads", isDirectory: true)
        try FileManager.default.createDirectory(at: macReads, withIntermediateDirectories: true)
        var list = ["file\tbytes\tsha256"]
        var macRows: [[String]] = []
        var stagedRows: [[String]] = []
        for sample in ["S1", "S2"] {
            var mac: [String] = []
            var staged: [String] = []
            for mate in [1, 2] {
                let name = "\(sample)_\(mate).fastq"
                let url = macReads.appendingPathComponent(name)
                try "@\(sample)a/\(mate)\nACGTACGTAC\n+\nIIIIIIIIII\n@\(sample)b/\(mate)\nTTGGCCAATT\n+\nIIIIIIIIII\n"
                    .write(to: url, atomically: true, encoding: .utf8)
                let data = try Data(contentsOf: url)
                list.append("\(Self.casper)/\(name)\t\(data.count)\t\(PortableDigest.sha256Hex(of: data))")
                mac.append(url.path)
                staged.append("\(Self.casper)/\(name)")
            }
            macRows.append([sample] + mac)
            stagedRows.append([sample] + staged)
        }
        let macFolder = root.appendingPathComponent("mac/batch", isDirectory: true)
        let stagedFolder = root.appendingPathComponent("staged/batch", isDirectory: true)
        try FileManager.default.createDirectory(at: macFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let macSheet = try writeSheet(macRows, name: "mac.csv")
        try await ImportCommand.FastqSubcommand.parse(
            ["--samplesheet", macSheet.path] + fixture.planArguments(folder: macFolder) + ["--platform", "illumina"] + Fixture.settings
        ).run()
        try await ImportCommand.FastqSubcommand.parse(fixture.stagedArguments(
            folder: stagedFolder, sheet: try writeSheet(stagedRows, name: "staged.csv"), list: try writeList(list, name: "same.tsv")
        )).run()
        for sample in ["S1", "S2"] {
            let mac = try Data(contentsOf: macFolder.appendingPathComponent("\(sample)/plan.json"))
            let staged = try Data(contentsOf: stagedFolder.appendingPathComponent("\(sample)/plan.json"))
            XCTAssertEqual(staged, mac, "\(sample): the staged plan differs from the plan of the same bytes measured on this Mac")
        }
    }

    /// `staging-files.json` names each read where it sits in the staging folder, with the list's size and SHA-256 and no
    /// `source`, as it names the image, and the write lines say the read is there already. The result folders are as a
    /// batch of reads on the Mac has them.
    func testStagedFilesListNamesReadInPlaceWithNoSource() throws {
        let cli = try cliBinary()
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let run = try runCLI(cli, ["import", "fastq"] + fixture.stagedArguments(folder: folder))
        XCTAssertEqual(run.status, 0, run.stderr)
        for read in Self.reads {
            XCTAssertTrue(run.stdout.contains("  \(read.size) bytes  \(read.path)  already in the staging folder\n"), run.stdout)
        }
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("staging-files.json"))
        ) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        let inputs = files.filter { $0["role"] as? String == "input" }
        XCTAssertEqual(inputs.map { $0["stagingPath"] as? String }, Self.reads.map(\.path))
        XCTAssertEqual(inputs.map { $0["sample"] as? String }, ["S1", "S1", "S2", "S2"])
        XCTAssertEqual(inputs.map { ($0["size"] as? NSNumber)?.int64Value }, Self.reads.map(\.size))
        XCTAssertEqual(inputs.map { $0["sha256"] as? String }, Self.reads.map(\.sha256))
        for input in inputs {
            XCTAssertNil(input["source"], "a staged read has no file on the Mac: \(input)")
        }
        XCTAssertNotNil(files.first { $0["role"] as? String == "executor" }?["source"], "the executor still has its Mac file")
        let folders = try XCTUnwrap(object["folders"] as? [[String: String]])
        XCTAssertEqual(folders.map { $0["stagingPath"] }, ["S1/result", "S1/result/out", "S2/result", "S2/result/out"]
            .map { "\(Self.staging)/batches/batch/\($0)" })
    }

    /// Each job reads its reads where they sit: `run.dag` names them by `file://` and their own path and places each by
    /// its file name at its plan slot, `jobs.tsv` places each by its path below the staging folder at its plan slot, and
    /// D17's disk rule runs on the list's sizes.
    func testStagedDAGAndJobsTableReadInPlace() async throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try await ImportCommand.FastqSubcommand.parse(fixture.stagedArguments(folder: folder)).run()
        let dag = try String(contentsOf: folder.appendingPathComponent("run.dag"), encoding: .utf8)
        let jobs = try String(contentsOf: folder.appendingPathComponent("jobs.tsv"), encoding: .utf8)
        for (sample, reads) in [("S1", Array(Self.reads[0...1])), ("S2", Array(Self.reads[2...3]))] {
            let vars = try XCTUnwrap(dag.split(separator: "\n").first { $0.hasPrefix("VARS \(sample) ") }.map(String.init), dag)
            let urls = reads.map { "file://\($0.path)" }.joined(separator: ", ")
            XCTAssertTrue(vars.contains("sample_inputs=\"plan.tar, \(urls)\""), vars)
            let plan = try ExecutionPlan.decode(Data(contentsOf: folder.appendingPathComponent("\(sample)/plan.json")))
            let slots = plan.entries.filter { $0.role == .input }.map(\.relativePath)
            let row = try XCTUnwrap(jobs.split(separator: "\n").first { $0.hasPrefix("\(sample)\t") }, jobs)
            let fields = row.split(separator: "\t").map(String.init)
            for (read, slot) in zip(reads, slots) {
                XCTAssertTrue(fields.contains("input-casper/\(read.name)=\(slot)"), "\(fields)")
            }
            // The wrapper takes a transferred file by its name, so the sample's VARS line places each read by its own file
            // name at its plan slot, whatever the slot calls the file.
            let placed = zip(reads, slots).map { "\($0.name)=\($1)" }.joined(separator: " ")
            XCTAssertTrue(vars.contains("sample_placements=\"\(placed)\""), vars)
            let tar = try XCTUnwrap(try FileManager.default.attributesOfItem(
                atPath: folder.appendingPathComponent("\(sample)/plan.tar").path
            )[.size] as? NSNumber).int64Value
            let shared = plan.entries.filter { $0.role == .executor || $0.role == .database }.reduce(Int64(0)) { $0 + $1.size }
            let disk = ExecutorPlanBatchWriter.requestDiskGiB(
                inputBytes: reads.reduce(Int64(0)) { $0 + $1.size }, imageBytes: 396_402_688, planTarBytes: tar, sharedBytes: shared
            )
            XCTAssertTrue(vars.contains("request_disk=\"\(disk)GB\""), "\(disk) GB expected: \(vars)")
        }
    }

    /// The three sentences a README of staged reads says in place of the base's.
    private static let stagedReadmeSentences = [
        "staging-files.json lists the files the jobs read, each with its size and its SHA-256, and each file except the image and the reads with the file on the Mac to copy or link. The image and the reads are in the staging folder already, and each job checks each read against its size and SHA-256 before any step runs.",
        "1. Copy or link each file staging-files.json lists with a file on the Mac to its stagingPath, below \(staging).",
        "That gives the folders shared/ and the folders that hold the reads, and images/ for Apptainer.",
    ]
    private static let macReadmeSentences = [
        "staging-files.json lists the files the jobs read, each with its size and its SHA-256, and each file except the image with the file on the Mac to copy or link. The image is staged already.",
        "1. Copy or link each file staging-files.json lists to its stagingPath, below \(staging).",
        "That gives the folders shared/ and batches/batch/, and images/ for Apptainer.",
    ]

    func testStagedReadmeSaysReadsAreStaged() async throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try await ImportCommand.FastqSubcommand.parse(fixture.stagedArguments(folder: folder)).run()
        let readme = Self.collapsed(try String(contentsOf: folder.appendingPathComponent("README.txt"), encoding: .utf8))
        for sentence in Self.stagedReadmeSentences {
            XCTAssertTrue(readme.contains(sentence), "The README lacks: \(sentence)\n\(readme)")
        }
        XCTAssertFalse(readme.contains("The image is staged already."), readme)
        XCTAssertFalse(readme.contains("1. Copy or link each file staging-files.json lists to its stagingPath"), readme)
    }

    /// ARCH 7. A batch of reads on the Mac keeps the base's README byte for byte, and a batch of staged reads differs from
    /// it only in the three sentences.
    func testReadmeWithoutStagedReadsIsUnchanged() async throws {
        let fixture = try writeFixture()
        let macReads = try writeMacPair("S1")
        let macFolder = root.appendingPathComponent("mac/batch", isDirectory: true)
        try FileManager.default.createDirectory(at: macFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ImportCommand.FastqSubcommand.parse(
            macReads.map(\.path) + fixture.planArguments(folder: macFolder) + Fixture.settings
        ).run()
        let mac = try Data(contentsOf: macFolder.appendingPathComponent("README.txt"))
        XCTAssertEqual(PortableDigest.sha256Hex(of: mac), Self.baseReadmeSHA256, "The README of a batch of Mac reads moved")

        let stagedFolder = root.appendingPathComponent("staged/batch", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ImportCommand.FastqSubcommand.parse(fixture.stagedArguments(folder: stagedFolder)).run()
        var staged = Self.collapsed(try String(contentsOf: stagedFolder.appendingPathComponent("README.txt"), encoding: .utf8))
        for (new, old) in zip(Self.stagedReadmeSentences, Self.macReadmeSentences) {
            XCTAssertTrue(staged.contains(new), new)
            staged = staged.replacingOccurrences(of: new, with: old)
        }
        XCTAssertEqual(staged, Self.collapsed(String(decoding: mac, as: UTF8.self)))
    }

    /// The dry run names each read by its full staging path, says in the line before its last that each job checks the
    /// reads against the list, and writes nothing.
    func testStagedDryRunPrintsPathsAndWritesNothing() throws {
        let cli = try cliBinary()
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let run = try runCLI(cli, ["import", "fastq"] + fixture.stagedArguments(folder: folder) + ["--dry-run"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let lines = run.stdout.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("  S1 in folder S1: \(Self.reads[0].path), \(Self.reads[1].path)"), run.stdout)
        XCTAssertTrue(lines.contains("  S2 in folder S2: \(Self.reads[2].path), \(Self.reads[3].path)"), run.stdout)
        XCTAssertEqual(Array(lines.suffix(2)), [
            "The reads are in the staging folder already, and each job checks each read against the size and SHA-256 that \(fixture.list.path) gives.",
            "This was a dry run, so no plan folder was written.",
        ], run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Refusals of the options

    /// A Mac import never ignores the list: without `--write-plan` the parse refuses it.
    func testStagedReadsWithoutWritePlanIsRefused() throws {
        let fixture = try writeFixture()
        let project = root.appendingPathComponent("p.lungfish").path
        for extra in [["--project", project], []] {
            let arguments = ["--samplesheet", fixture.sheet.path, "--staged-reads", fixture.list.path] + extra
            XCTAssertThrowsError(try ImportCommand.FastqSubcommand.parse(arguments)) { error in
                XCTAssertEqual(ImportCommand.FastqSubcommand.message(for: error),
                               "--staged-reads names reads in a Linux staging folder, so use it with --write-plan.")
                XCTAssertEqual(ImportCommand.FastqSubcommand.exitCode(for: error), ExitCode.validationFailure)
            }
        }
    }

    func testStagedReadsWithoutSampleSheetIsRefused() throws {
        let fixture = try writeFixture()
        let macReads = try writeMacPair("S1").map(\.path)
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let staged = ["--staged-reads", fixture.list.path] + fixture.planArguments(folder: folder) + ["--platform", "illumina"]
            + Fixture.settings
        for arguments in [macReads + staged, macReads + ["--samplesheet", fixture.sheet.path] + staged] {
            try assertRefused(arguments, folder: folder, says: "A plan of staged reads takes its samples from a sample sheet, so pass --samplesheet and no input paths.")
        }
    }

    func testStagedReadsWithPlatformAutoIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        for platform in [[], ["--platform", "auto"]] {
            try assertRefused(fixture.stagedArguments(folder: folder, platform: platform), folder: folder,
                              says: "Lungfish does not read reads in the staging folder, so it cannot infer their platform. Pass --platform, such as --platform illumina.")
        }
    }

    /// A name that is no platform is refused as the Mac import refuses it, with `auto` left out of the list since a plan
    /// of staged reads cannot infer a platform. A plan that carried it would run on CHTC, and the adopt would then
    /// refuse every sample, because it cannot read a platform from reads that never came back.
    func testStagedReadsWithUnknownPlatformIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try assertRefused(fixture.stagedArguments(folder: folder, platform: ["--platform", "illumnia"]), folder: folder,
                          says: "Unknown platform 'illumnia'. Valid: illumina, ont, pacbio, element, mgi, ultima, unknown")
    }

    // MARK: Refusals of the list

    func testUnreadableStagedReadsListIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let notText = root.appendingPathComponent("not-text.tsv")
        try Data([0x66, 0x69, 0x6c, 0x65, 0xff, 0xfe, 0x0a]).write(to: notText)
        for list in [root.appendingPathComponent("missing.tsv"), notText] {
            try assertRefused(fixture.stagedArguments(folder: folder, list: list), folder: folder,
                              says: "The file \(list.path) given to --staged-reads cannot be read as text.")
        }
    }

    func testCommaSeparatedStagedReadsListIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let list = try writeList(["file,bytes,sha256", "\(Self.reads[0].path),\(Self.reads[0].size),\(Self.reads[0].sha256)"], name: "comma.tsv")
        try assertRefused(fixture.stagedArguments(folder: folder, list: list), folder: folder,
                          says: "The staged-reads list \(list.path) is comma-separated. Write it tab-separated, with the columns file, bytes and sha256.")
    }

    func testStagedReadsListWithoutAColumnIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let list = try writeList(["file\tbytes\tmd5"] + Self.reads.map { "\($0.path)\t\($0.size)\tffff" }, name: "no-sha.tsv")
        try assertRefused(fixture.stagedArguments(folder: folder, list: list), folder: folder,
                          says: "The staged-reads list \(list.path) has no sha256 column. Its first line names the columns file, bytes and sha256, separated by tabs.")
    }

    /// Blank lines are skipped and still counted, so the number is the line an editor shows.
    func testStagedReadsListLineWithAnEmptyValueIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let list = try writeList(["file\tbytes\tsha256", Self.line(Self.reads[0]), "", "\(Self.reads[1].path)\t\t\(Self.reads[1].sha256)"],
                                 name: "empty.tsv")
        try assertRefused(fixture.stagedArguments(folder: folder, list: list), folder: folder,
                          says: "Line 4 of the staged-reads list has no bytes value.")
    }

    func testStagedReadsListDigestThatIsNotLowercaseHexIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        for value in [String(repeating: "A", count: 64), String(repeating: "a", count: 63), String(repeating: "g", count: 64)] {
            let list = try writeList(["file\tbytes\tsha256", "\(Self.reads[0].path)\t\(Self.reads[0].size)\t\(value)"], name: "digest.tsv")
            try assertRefused(fixture.stagedArguments(folder: folder, list: list), folder: folder,
                              says: "Line 2 of the staged-reads list gives the SHA-256 \(value), which is not 64 lowercase hexadecimal characters. Copy it from the output of sha256sum.")
        }
    }

    func testStagedReadsListSizeThatIsNotAWholeNumberAboveZeroIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        for value in ["0", "-5", "12.5", "5GB", "9223372036854775808"] {
            let list = try writeList(["file\tbytes\tsha256", "\(Self.reads[0].path)\t\(value)\t\(Self.reads[0].sha256)"], name: "size.tsv")
            try assertRefused(fixture.stagedArguments(folder: folder, list: list), folder: folder,
                              says: "Line 2 of the staged-reads list gives the size \(value), which is not a whole number of bytes above 0. Copy it from the output of stat -c %s.")
        }
    }

    func testStagedReadsListFileThatIsNotAbsoluteIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let list = try writeList(["file\tbytes\tsha256", "input-casper/S1_1.fastq.gz\t\(Self.reads[0].size)\t\(Self.reads[0].sha256)"],
                                 name: "relative.tsv")
        try assertRefused(fixture.stagedArguments(folder: folder, list: list), folder: folder,
                          says: "Line 2 of the staged-reads list names input-casper/S1_1.fastq.gz, which is not an absolute path. Name each read by its absolute path on the Linux machine.")
    }

    /// A file listed twice is refused even with equal values.
    func testStagedReadsListNamingAFileTwiceIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let list = try writeList(["file\tbytes\tsha256", Self.line(Self.reads[0]), Self.line(Self.reads[1]), Self.line(Self.reads[0])],
                                 name: "twice.tsv")
        try assertRefused(fixture.stagedArguments(folder: folder, list: list), folder: folder,
                          says: "The staged-reads list names \(Self.reads[0].path) on lines 2 and 4. List each read once.")
    }

    // MARK: Refusals of a sheet row

    /// `/staging/x/lge-other/` is outside `/staging/x/lge`, a `..` name leaves the folder, a relative sheet path is read
    /// from the sheet's folder on this Mac, and a file on this Mac in a staged sheet would make a mixed batch. Each gets
    /// the words for a read outside the staging folder, even with a list line for it.
    func testReadOutsideTheStagingFolderIsRefused() throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let staging = "/staging/x/lge"
        let r2 = "\(staging)/S1_2.fastq.gz"
        let outside = "/staging/x/lge-other/S1_1.fastq.gz"
        let dotted = "\(staging)/../lge-other/S1_1.fastq.gz"
        let relativeSheet = try writeSheet([["S1", "S1_1.fastq.gz", r2]], name: "relative.csv")
        let macPair = try writeMacPair("S2")
        let cases: [(sheet: URL, path: String, sample: String)] = [
            (try writeSheet([["S1", outside, r2]], name: "outside.csv"), outside, "S1"),
            (try writeSheet([["S1", dotted, r2]], name: "dotted.csv"), URL(fileURLWithPath: dotted).path, "S1"),
            (relativeSheet, relativeSheet.deletingLastPathComponent().appendingPathComponent("S1_1.fastq.gz").path, "S1"),
            (try writeSheet([["S1", "\(staging)/S1_1.fastq.gz", r2], ["S2"] + macPair.map(\.path)], name: "mixed.csv"),
             macPair[0].path, "S2"),
        ]
        let listed = [outside, dotted, "\(staging)/S1_1.fastq.gz", r2] + macPair.map(\.path)
        let list = try writeList(["file\tbytes\tsha256"] + listed.map { "\($0)\t1000\t\(Self.digest)" }, name: "outside.tsv")
        for item in cases {
            try assertRefused(fixture.stagedArguments(folder: folder, sheet: item.sheet, list: list, staging: staging), folder: folder,
                              says: "The read \(item.path) of sample \(item.sample) is not inside the staging folder \(staging). With --staged-reads every read is a file in the staging folder, named by its absolute path, so plan reads on this Mac in a batch of their own.")
        }
    }

    func testReadNameWithAnotherCharacterIsRefused() throws {
        try assertRowRefused(r1: "\(Self.staging)/input casper/S1_1.fastq.gz", r2: Self.reads[1].path) { r1, _ in
            "The read \(r1) of sample S1 has a name with a character other than letters, digits, _, . and -, which a job's file transfer cannot hold, so rename it."
        }
    }

    func testReadInsideTheBatchFolderIsRefused() throws {
        try assertRowRefused(r1: "\(Self.staging)/batches/batch/S1/S1_1.fastq.gz", r2: Self.reads[1].path) { r1, _ in
            "The read \(r1) of sample S1 is inside the folder \(Self.staging)/batches/batch, where this batch's jobs write, so keep the reads outside it."
        }
    }

    func testSheetReadWithNoListLineIsRefused() throws {
        try assertRowRefused(r1: Self.reads[0].path, r2: "\(Self.casper)/S1_2b.fastq.gz", listed: [Self.reads[0].path]) { _, r2 in
            "The sample sheet names \(r2) as the R2 of S1, and the staged-reads list has no line for it. Add its size and SHA-256 to the list, or correct the path."
        }
    }

    func testR1AndR2WithOneFileNameAreRefused() throws {
        try assertRowRefused(r1: "\(Self.staging)/run-a/S1.fastq.gz", r2: "\(Self.staging)/run-b/S1.fastq.gz") { _, _ in
            "The R1 and R2 of sample S1 are both named S1.fastq.gz, and a job takes each file by its name, so rename one."
        }
    }

    // MARK: Fixture

    /// One sheet row S1 of `r1` and `r2`, with a list line for each path of `listed` (both reads when nil), is refused in
    /// the words `words` gives.
    private func assertRowRefused(r1: String, r2: String, listed: [String]? = nil, file: StaticString = #filePath,
                                  line: UInt = #line, _ words: (String, String) -> String) throws {
        let fixture = try writeFixture()
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        let sheet = try writeSheet([["S1", r1, r2]], name: "row.csv")
        let list = try writeList(["file\tbytes\tsha256"] + (listed ?? [r1, r2]).map { "\($0)\t1000\t\(Self.digest)" }, name: "row.tsv")
        try assertRefused(fixture.stagedArguments(folder: folder, sheet: sheet, list: list), folder: folder,
                          says: words(r1, r2), file: file, line: line)
    }

    /// The built CLI's run of `arguments` with JSON events ends with the input error exit code, a `failed` event that says
    /// `words`, and no plan folder.
    private func assertRefused(_ arguments: [String], folder: URL, says words: String, file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let run = try runCLI(try cliBinary(), ["import", "fastq"] + arguments + ["--format", "json"])
        let events = run.stdout.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let failed = try XCTUnwrap(events.first { $0["event"] as? String == "failed" }, "\(run.stdout)\n\(run.stderr)",
                                   file: file, line: line)
        XCTAssertEqual(failed["error"] as? String, words, file: file, line: line)
        XCTAssertEqual(run.status, 3, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a refused plan writes no folder", file: file, line: line)
    }

    private static func line(_ read: StagedRead) -> String { "\(read.path)\t\(read.size)\t\(read.sha256)" }

    private static func collapsed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private func cliBinary() throws -> URL {
        guard let cli = CLISIGTERMHarness.cliBinaryURL(for: Self.self) else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        return cli
    }

    private func runCLI(_ cli: URL, _ arguments: [String]) throws -> (status: Int, stdout: String, stderr: String) {
        let result = try ToolProcess.start(ToolProcessSpec(
            executableURL: cli, arguments: arguments, environment: CLISIGTERMHarness.childEnvironment(overriding: [:]),
            timeout: .seconds(120), label: "staged-reads"
        )).waitBlocking()
        return (Int(result.status), result.stdoutText, result.stderrText)
    }

    /// A comma-separated sheet with the columns sample, r1 and r2.
    private func writeSheet(_ rows: [[String]], name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try ((["sample,r1,r2"] + rows.map { $0.joined(separator: ",") }).joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeList(_ lines: [String], name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// An R1 and an R2 file on this Mac for `sample`, in a folder of their own.
    private func writeMacPair(_ sample: String) throws -> [URL] {
        let folder = root.appendingPathComponent("reads-\(sample)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try [1, 2].map { mate in
            let url = folder.appendingPathComponent("\(sample)_R\(mate).fastq")
            try "@\(sample)a/\(mate)\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// An executor stand-in with its `manifest.json`, a tool manifest and the `image.json` that pins it, the sheet of S1
    /// and S2 with a `site` label and an empty `request_disk`, and the list of their four reads. The list's header names
    /// its columns in another case with lane FETCH's `md5` column beside them, and it holds a blank line and a read no
    /// sheet row names.
    private struct Fixture {
        var executorManifest: URL
        var image: URL
        var toolManifest: URL
        var sheet: URL
        var list: URL

        static let settings = ["--threads", "1", "--clumpify-heap-gb", "4", "--clumping-tool", "bbtools"]

        func planArguments(folder: URL, staging: String = ImportFastqStagedReadsTests.staging) -> [String] {
            ["--write-plan", folder.path, "--executor-manifest", executorManifest.path, "--image", image.path,
             "--image-tool-manifest", toolManifest.path, "--staging-folder", staging]
        }

        func stagedArguments(folder: URL, sheet: URL? = nil, list: URL? = nil, platform: [String] = ["--platform", "illumina"],
                             staging: String = ImportFastqStagedReadsTests.staging) -> [String] {
            ["--samplesheet", (sheet ?? self.sheet).path, "--staged-reads", (list ?? self.list).path]
                + planArguments(folder: folder, staging: staging) + platform + Self.settings
        }
    }

    private func writeFixture() throws -> Fixture {
        let executorFolder = root.appendingPathComponent("executor", isDirectory: true)
        try FileManager.default.createDirectory(at: executorFolder, withIntermediateDirectories: true)
        let executor = Data("executor stand-in".utf8)
        try executor.write(to: executorFolder.appendingPathComponent("lungfish-executor"))
        let digest = String(repeating: "b", count: 64)
        let manifest: [String: Any] = [
            "sha256": PortableDigest.sha256Hex(of: executor), "size": executor.count,
            "lgeVersion": "2026.10.22", "lgeCommit": "74ae0db3400d6b7519550e33dafc369e081fa114",
            "targetTriple": "x86_64-swift-linux-musl", "toolchainID": "swift-6.2", "toolchainSHA256": digest,
            "staticLinuxSDKID": "swift-6.2-static-linux", "staticLinuxSDKSHA256": digest,
        ]
        let manifestURL = executorFolder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        let tools = [("clumpify.sh", "39.13", "he5f24ec_0", "bbmap"), ("reformat.sh", "39.13", "he5f24ec_0", "bbmap"),
                     ("java", "25.0.2", "h1602c4f_26", "openjdk"), ("bgzip", "1.21", "h3ff9d97_0", "htslib"),
                     ("pigz", "2.8", "h421ea60_1", "pigz"), ("seqkit", "2.10.0", "h9ee0642_0", "seqkit"),
                     ("gzip", "1.13", "h8359307_0", "gzip"), ("fastp", "1.0.1", "h43da1c4_0", "fastp")]
        let toolManifest = try ImageToolManifest(platform: .linux64, tools: tools.map {
            ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/bin/\($0.0)", condaPackage: $0.3)
        }).encoded()
        let toolManifestURL = root.appendingPathComponent("image-manifest.json")
        try toolManifest.write(to: toolManifestURL)
        let image: [String: Any] = [
            "schemaVersion": 1,
            "sif": ["fileName": "lge-tools-test.sif", "sha256": String(repeating: "e", count: 64), "size": 396_402_688],
            "imageManifest": ["sha256": PortableDigest.sha256Hex(of: toolManifest), "size": toolManifest.count],
        ]
        let imageURL = root.appendingPathComponent("image.json")
        try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys]).write(to: imageURL)
        let sheetURL = root.appendingPathComponent("samples.csv")
        try ("sample,r1,r2,request_disk,site\n"
            + "S1,\(Self.reads[0].path),\(Self.reads[1].path),,madison\n"
            + "S2,\(Self.reads[2].path),\(Self.reads[3].path),,madison\n").write(to: sheetURL, atomically: true, encoding: .utf8)
        let md5 = String(repeating: "f", count: 32)
        let list = try writeList(["file\tBytes\tSHA256\tmd5"] + Self.reads.map { Self.line($0) + "\t\(md5)" }
            + ["", "\(Self.casper)/S3_1.fastq.gz\t7000\t\(Self.digest)\t\(md5)"], name: "staged-reads.tsv")
        return Fixture(executorManifest: manifestURL, image: imageURL, toolManifest: toolManifestURL, sheet: sheetURL, list: list)
    }
}
