// RNASeqQuantPlanCommandUMITests.swift - `lungfish-cli rnaseq quant --write-plan` with the sample sheet's kit column, the
// UMI branch (Phase 5.3 lane EX-UMI, milestone 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The plan's own bytes are `UMIPlanTests`. These cases read that the kit column picks the UMI branch on the adopted STAR
// 2.7.11b index, that a sheet with no kit writes the plans it wrote before, and that each refusal names the way out.

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqQuantPlanCommandUMITests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-quant-umi-cli").resolvingSymlinksInPath() }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static let staging = RNASeqQuantPlanCommandTests.staging
    static let figures = ["--request-memory-mib", "4096", "--request-cpus", "2", "--request-disk-gib", "20"]
    static let reads = RNASeqQuantPlanCommandTests.stagedReads

    /// The executor's `manifest.json`, an image whose tool manifest holds STAR 2.7.11b, pigz, featureCounts, samtools,
    /// umi_tools and the python3 beside it, and the `image.json` that pins it.
    func writeImageFiles() throws -> (executor: URL, image: URL, tools: URL) {
        let files = try RNASeqQuantPlanCommandTests.writeImageFiles(in: root)
        let tools = [("STAR", "2.7.11b", "h5814d7d_9", "star"), ("pigz", "2.8", "h421ea60_1", "pigz"),
                     ("featureCounts", "2.1.1", "h577a1d6_0", "subread"), ("samtools", "1.24", "h9dcdb79_1", "samtools"),
                     ("umi_tools", "1.1.6", "py311haab0aaa_0", "umi_tools"), ("python3", "3.11.18", "h5f976f7_0_cpython", "python"),
                     ("salmon", "2.11.0", "hfa8f182_0", "salmon"), ("trim_galore", "2.3.0", "hf1b6044_0", "trim-galore")]
        let manifest = try ImageToolManifest(platform: .linux64, tools: tools.map {
            let folder = $0.0 == "umi_tools" || $0.0 == "python3" ? "umi" : $0.0
            return ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/envs/\(folder)/bin/\($0.0)", condaPackage: $0.3)
        }).encoded()
        try manifest.write(to: files.tools)
        let image: [String: Any] = [
            "schemaVersion": 1,
            "sif": ["fileName": "lge-tools-test.sif", "sha256": String(repeating: "e", count: 64), "size": 396_402_688],
            "imageManifest": ["sha256": PortableDigest.sha256Hex(of: manifest), "size": manifest.count],
        ]
        try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys]).write(to: files.image)
        return files
    }

    /// The small set and a stand-in record of a STAR 2.7.11b index that `rnaseq index-adopt` wrote, whose three files the
    /// index batch `m-index` left in the staging folder.
    func setWithAdoptedIndex() async throws -> (storage: URL, id: String) {
        let (storage, setFolder) = try await RNASeqIndexPlanCommandTests.builtSet(in: root)
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let star = PlanToolPin(id: "STAR", version: "2.7.11b", build: "h5814d7d_9")
        let key = STARIndexKey.folderName(star: "2.7.11b", nbases: 4, sparseD: 2)
        let files = ["Genome", "SA", "chrName.txt"].map { name -> STARIndexRecord.File in
            let data = Data("\(name) of \(key)\n".utf8)
            return STARIndexRecord.File(path: name, planPath: "star-index/\(name)",
                                        stagingPath: "\(Self.staging)/batches/m-index/index/staged/star-index/\(name)",
                                        bytes: UInt64(data.count), sha256: PortableDigest.sha256Hex(of: data))
        }
        _ = try STARIndexRecordStore(storageRoot: storage).write(STARIndexRecord(setID: manifest.id, key: STARIndexKey(
            folderName: key, setID: manifest.id, referenceSetSHA256: String(repeating: "d", count: 64), star: star,
            genomeSAindexNbases: 4, genomeSAsparseD: 2, sjdbOverhang: 100, genomeFastaFiles: [manifest.genome.path],
            countingGTFSHA256: manifest.derived.countingGTF?.sha256 ?? ""), tool: star, files: files))
        return (storage, manifest.id)
    }

    /// The staged-reads list of the two samples and a sheet of `header` and one row a sample, each row's last cell given.
    func writeStaged(_ name: String, header: String = "sample,r1,r2,kit", cells: [String?]) throws -> (list: URL, sheet: URL) {
        let (list, sheet) = (root.appendingPathComponent("\(name).tsv"), root.appendingPathComponent("\(name).csv"))
        let lines = ["file\tbytes\tsha256"] + Self.reads.map { "\($0.path)\t\($0.size)\t\($0.sha256)" }
        try (lines.joined(separator: "\n") + "\n").write(to: list, atomically: true, encoding: .utf8)
        let rows = cells.enumerated().map { n, cell in
            "S\(n + 1),\(Self.reads[2 * n].path),\(Self.reads[2 * n + 1].path)" + (cell.map { ",\($0)" } ?? "")
        }
        try (([header] + rows).joined(separator: "\n") + "\n").write(to: sheet, atomically: true, encoding: .utf8)
        return (list, sheet)
    }

    func arguments(
        _ staged: (list: URL, sheet: URL), set: (storage: URL, id: String), out: URL, files: (executor: URL, image: URL, tools: URL),
        extra: [String] = []
    ) -> [String] {
        ["--set", set.id, "--storage-root", set.storage.path, "--write-plan", out.path, "--staging-folder", Self.staging,
         "--executor-manifest", files.executor.path, "--image", files.image.path, "--image-tool-manifest", files.tools.path,
         "--quiet", "--staged-reads", staged.list.path, "--samplesheet", staged.sheet.path] + Self.figures + extra
    }

    func plan(_ folder: URL, _ sample: String) throws -> ExecutionPlan {
        try ExecutionPlan.decode(Data(contentsOf: folder.appendingPathComponent("\(sample)/plan.json")))
    }

    // MARK: - The kit column (item 2)

    /// Red first (item 2): a sheet whose kit column names the preset, in any case, writes one plan a sample of the UMI branch
    /// on the adopted STAR 2.7.11b index, with STAR's threads from --request-cpus, and the summary states the request rule.
    func testTheKitColumnWritesTheUMIBranchOnTheAdoptedSTARIndex() async throws {
        let set = try await setWithAdoptedIndex(), files = try writeImageFiles()
        let staged = try writeStaged("umi", cells: ["quartz-seq2-x910", "Quartz-Seq2-X910"])
        let out = root.appendingPathComponent("out/umi")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let summary = try await RNASeqCommand.QuantSubcommand.parse(arguments(staged, set: set, out: out, files: files)).writePlanFolder()
        for sample in ["S1", "S2"] {
            let made = try plan(out, sample)
            XCTAssertEqual(made.steps.map(\.id), [
                "umi-layout-check-pair1", "umi-extract-pair1", "star-align", "featurecounts", "samtools-sort", "samtools-index",
                "umi-count",
            ], sample)
            XCTAssertEqual(made.pipeline?.route?.id, "umi-counts", sample)
            XCTAssertEqual(made.pipeline?.preset.id, "quartz-seq2-x910", sample)
            let star = try XCTUnwrap(made.steps.first { $0.id == "star-align" }?.arguments)
            // "none", never a character (EX-UMI-M3-BIO blocker 1): a one-character separator cuts a MiSeq name at its flowcell id.
            XCTAssertEqual(star.firstIndex(of: "--readNameSeparator").map { star[$0 + 1] }, "none", sample)
            XCTAssertEqual(star.firstIndex(of: "--runThreadN").map { star[$0 + 1] }, "2", "STAR's threads equal --request-cpus")
        }
        let stagedFiles = try String(contentsOf: out.appendingPathComponent("staging-files.json"), encoding: .utf8)
        XCTAssertTrue(stagedFiles.contains("\(Self.staging)/batches/m-index/index/staged/star-index/Genome"), stagedFiles)
        XCTAssertTrue(summary.lines.contains("The job of S1 asks for 4096 MiB of memory, 2 CPUs and 20 GiB of disk."), "\(summary.lines)")
        let rule = summary.lines.filter { $0.contains("8,000,000,000 bytes (--limitBAMsortRAM)") && $0.contains("768 MiB") }
        XCTAssertEqual(rule.count, 1, "the request rule of a UMI job, once: \(summary.lines)")
    }

    /// A sheet with no kit column, or with one whose cells are empty, writes the plans of the chain --chain names that it
    /// wrote before the column, byte for byte.
    func testASheetWithNoKitOrEmptyKitCellsWritesThePlansOfTheChain() async throws {
        let set = try await setWithAdoptedIndex(), files = try writeImageFiles()
        let chain = ["--chain", "star-2.7.11b-featurecounts"]
        let plain = try writeStaged("plain", header: "sample,r1,r2", cells: [nil, nil])
        let empty = try writeStaged("empty", cells: ["", " "])
        let (a, b) = (root.appendingPathComponent("a/quant"), root.appendingPathComponent("b/quant"))
        for (folder, staged) in [(a, plain), (b, empty)] {
            try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await RNASeqCommand.QuantSubcommand.parse(arguments(staged, set: set, out: folder, files: files, extra: chain)).run()
        }
        for sample in ["S1", "S2"] {
            let bytes = try Data(contentsOf: a.appendingPathComponent("\(sample)/plan.json"))
            XCTAssertEqual(bytes, try Data(contentsOf: b.appendingPathComponent("\(sample)/plan.json")), sample)
            XCTAssertEqual(try plan(a, sample).pipeline?.route?.id, "star-featurecounts-exon", sample)
        }
    }

    /// The kit column's refusals, each in words that name the way out, with the input code and no folder: a sheet that
    /// names a kit for some samples only, a kit LGE has no preset for, and --chain, --trim or --k beside a kit.
    func testTheKitColumnsRefusalsNameTheWayOutAndWriteNothing() async throws {
        let set = try await setWithAdoptedIndex(), files = try writeImageFiles()
        let out = root.appendingPathComponent("refused")
        let umi = try writeStaged("umi", cells: ["quartz-seq2-x910", "quartz-seq2-x910"])
        let cases: [(String, (list: URL, sheet: URL), [String], String)] = [
            ("a kit for S1 only", try writeStaged("mixed", cells: ["quartz-seq2-x910", ""]), [],
             "The sample sheet names a UMI kit for S1 and none for S2."),
            ("an unknown kit", try writeStaged("unknown", cells: ["10x-3prime-v3", "10x-3prime-v3"]), [],
             "which LGE has no UMI preset for"),
            ("--chain beside a kit", umi, ["--chain", "star-2.7.11b-featurecounts"], "so leave out --chain."),
            ("--trim beside a kit", umi, ["--trim"], "so leave out --trim."),
            ("--k beside a kit", umi, ["--k", "25"], "so leave out --k and --decoys."),
        ]
        for (what, staged, extra, expected) in cases {
            let command = try RNASeqCommand.QuantSubcommand.parse(arguments(staged, set: set, out: out, files: files, extra: extra))
            var words = ""
            do {
                _ = try await command.writePlanFolder()
                XCTFail("\(what): the plan was written")
            } catch {
                words = CLIFailureWords.describe(error)
            }
            XCTAssertTrue(words.contains(expected), "\(what): \(words)")
            do {
                try await command.run()
                XCTFail("\(what): the leaf did not refuse")
            } catch let code as ExitCode {
                XCTAssertEqual(code, CLIExitCode.inputError.exitCode, what)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), what)
        }
    }
}
