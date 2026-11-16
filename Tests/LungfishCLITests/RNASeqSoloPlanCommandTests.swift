// RNASeqSoloPlanCommandTests.swift - `lungfish-cli rnaseq solo-plan`, the STARsolo plan of 10x libraries whose reads are
// staged, on the index an earlier Linux run staged (Phase 5.3 lane SOLO-PLAN M3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The plan's own bytes are `SoloPlanTests`. These cases read what the options pick: the adopted index of the list
// `--tenx-filter` names, the image's list or the person's, the expected cells and the request figures, and that each
// refusal says what to do and writes nothing.

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqSoloPlanCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-solo-plan-cli").resolvingSymlinksInPath() }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static let staging = "/staging/groups/g/1/lge"
    static let figures = ["--request-memory-mib", "4096", "--request-cpus", "2", "--request-disk-gib", "20"]
    static let sha3M = "843a6f7038db8cb3c06f3dc21cc69d04139ffa10689780518d7a9e42dc2e819b"

    /// The executor's `manifest.json`, an image whose tool manifest holds STAR 2.7.11b, pigz and the 3M list, and the
    /// `image.json` that pins it.
    func writeImageFiles() throws -> (executor: URL, image: URL, tools: URL) {
        let files = try RNASeqQuantPlanCommandTests.writeImageFiles(in: root)
        let tools = [("STAR", "2.7.11b", "h5814d7d_9"), ("pigz", "2.8", "h421ea60_1")]
        let manifest = try ImageToolManifest(
            platform: .linux64,
            tools: tools.map { ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/envs/\($0.0)/bin/\($0.0)", condaPackage: $0.0.lowercased()) },
            files: [ImageDataFile(path: "/opt/lge/barcodes/3M-february-2018.txt", role: "barcodeList", sha256: Self.sha3M, size: 115_512_960)]
        ).encoded()
        try manifest.write(to: files.tools)
        let image: [String: Any] = [
            "schemaVersion": 1,
            "sif": ["fileName": "lge-tools-test.sif", "sha256": String(repeating: "e", count: 64), "size": 396_402_688],
            "imageManifest": ["sha256": PortableDigest.sha256Hex(of: manifest), "size": manifest.count],
        ]
        try JSONSerialization.data(withJSONObject: image, options: [.sortedKeys]).write(to: files.image)
        return files
    }

    /// The small set and a stand-in record of the `mkgtf-3.0.0` variant of its STAR 2.7.11b index that `rnaseq
    /// index-adopt` wrote, whose files the batch `solo-index` left in the staging folder.
    func setWithAdoptedVariant() async throws -> (storage: URL, id: String) {
        let (storage, setFolder) = try await RNASeqIndexPlanCommandTests.builtSet(in: root)
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let star = PlanToolPin(id: "STAR", version: "2.7.11b", build: "h5814d7d_9")
        let made = try TenxGTFFilter.make(from: setFolder, manifest: manifest, list: .mkgtf300)
        let key = STARIndexKey.folderName(star: "2.7.11b", nbases: 4, sparseD: 2, filter: .mkgtf300)
        let files = ["Genome", "SA", "chrName.txt"].map { name -> STARIndexRecord.File in
            let data = Data("\(name) of \(key)\n".utf8)
            return STARIndexRecord.File(path: name, planPath: "star-index/\(name)",
                                        stagingPath: "\(Self.staging)/batches/solo-index/index/staged/star-index/\(name)",
                                        bytes: UInt64(data.count), sha256: PortableDigest.sha256Hex(of: data))
        }
        let record = STARIndexRecord(setID: manifest.id, key: STARIndexKey(
            folderName: key, setID: manifest.id, referenceSetSHA256: String(repeating: "d", count: 64), star: star,
            genomeSAindexNbases: 4, genomeSAsparseD: 2, sjdbOverhang: 100, genomeFastaFiles: [manifest.genome.path],
            countingGTFSHA256: try manifest.requireCountingGTF().sha256, gtfFilter: STARIndexKey.GTFFilter(made)), tool: star, files: files)
        _ = try STARIndexRecordStore(storageRoot: storage).write(record)
        return (storage, manifest.id)
    }

    /// One library of two lanes staged under `input/`: the staged-reads list and the sample sheet, a row a lane.
    func stagedLibrary() throws -> (reads: URL, sheet: URL) {
        var list = "file\tbytes\tsha256\n", sheet = "sample,r1,r2\n"
        for lane in ["L001", "L002"] {
            let paths = ["R1", "R2"].map { "\(Self.staging)/input/pbmc_\(lane)_\($0)_001.fastq.gz" }
            for (index, path) in paths.enumerated() {
                list += "\(path)\t\(1000 + index)\t\(String(repeating: index == 0 ? "1" : "2", count: 63) + (lane == "L001" ? "a" : "b"))\n"
            }
            sheet += "pbmc,\(paths[0]),\(paths[1])\n"
        }
        let (reads, sheetURL) = (root.appendingPathComponent("staged.tsv"), root.appendingPathComponent("sheet.csv"))
        try Data(list.utf8).write(to: reads)
        try Data(sheet.utf8).write(to: sheetURL)
        return (reads, sheetURL)
    }

    func arguments(set: (storage: URL, id: String), out: URL, files: (executor: URL, image: URL, tools: URL),
                   preset: String = "tenx-3p-v3", list: String? = "mkgtf-3.0.0") throws -> [String] {
        let library = try stagedLibrary()
        return ["--set", set.id, "--storage-root", set.storage.path, "--preset", preset, "--output", out.path,
                "--staged-reads", library.reads.path, "--samplesheet", library.sheet.path, "--staging-folder", Self.staging,
                "--executor-manifest", files.executor.path, "--image", files.image.path, "--image-tool-manifest", files.tools.path,
                "--quiet"] + (list.map { ["--tenx-filter", $0] } ?? []) + Self.figures
    }

    /// The words a refused run would print, after it exits with the input error and writes nothing at `out`.
    func refusal(_ given: [String], out: URL, line: UInt = #line) async throws -> String {
        let command = try RNASeqSoloPlanSubcommand.parse(given)
        do {
            try await command.run()
            XCTFail("the plan was written", line: line)
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), line: line)
        do { _ = try await command.writePlan() } catch { return CLIFailureWords.describe(error) }
        return ""
    }

    // MARK: - Item 1, the leaf

    /// The leaf parses alike at the root and as itself, and its plan of one library of two lanes pins the adopted
    /// `mkgtf-3.0.0` index where it was staged, the image's 3M list, the expected cells and the CPUs as STAR's threads.
    func testThePlanPinsTheAdoptedVariantTheImageListAndTheExpectedCells() async throws {
        let set = try await setWithAdoptedVariant(), files = try writeImageFiles()
        let out = root.appendingPathComponent("out/solo")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let given = try arguments(set: set, out: out, files: files) + ["--expected-cells", "1000"]
        let atRoot = try XCTUnwrap(try LungfishCLI.parseAsRoot(["rnaseq", "solo-plan"] + given) as? RNASeqSoloPlanSubcommand)
        XCTAssertEqual(atRoot.canonicalArgv(), try RNASeqSoloPlanSubcommand.parse(given).canonicalArgv())
        try await RNASeqSoloPlanSubcommand.parse(given).run()
        let plan = try ExecutionPlan.decode(Data(contentsOf: out.appendingPathComponent("pbmc/plan.json")))
        XCTAssertEqual(plan.pipeline?.modality, .singleCell)
        XCTAssertEqual(plan.pipeline?.route?.id, "starsolo-gene")
        XCTAssertEqual(plan.pipeline?.route?.settings["index"], "star-2.7.11b-sa4-sparse2-tenx1-mkgtf-3.0.0")
        XCTAssertEqual(plan.pipeline?.route?.settings["barcodeList"], "3M-february-2018, SHA-256 \(Self.sha3M)")
        XCTAssertTrue(plan.pipeline?.route?.settings["cellFilter"]?.hasPrefix("EmptyDrops_CR with 1000 expected cells") == true)
        let argv = try XCTUnwrap(plan.steps.first?.arguments)
        XCTAssertEqual(argv.firstIndex(of: "--runThreadN").map { argv[$0 + 1] }, "2", "STAR's threads equal --request-cpus")
        XCTAssertEqual(argv.firstIndex(of: "--soloCellFilter").map { Array(argv[$0 + 1...$0 + 2]) }, ["EmptyDrops_CR", "1000"])
        let reads = try XCTUnwrap(argv.firstIndex(of: "--readFilesIn").map { Array(argv[$0 + 1...$0 + 2]) })
        XCTAssertEqual(reads.map { $0.components(separatedBy: ",").count }, [2, 2], "each lane's read 2, then each lane's read 1")
        // The frame names each staged read by its lane's pair, in the sheet's order (L001 is pair 1).
        XCTAssertEqual(reads, ["inputs/pair1_R2.fastq.gz,inputs/pair2_R2.fastq.gz", "inputs/pair1_R1.fastq.gz,inputs/pair2_R1.fastq.gz"])
        let staged = try String(contentsOf: out.appendingPathComponent("staging-files.json"), encoding: .utf8)
        XCTAssertTrue(staged.contains("\(Self.staging)/batches/solo-index/index/staged/star-index/Genome"), staged)
    }

    /// `--dry-run` makes every refusal of the run and writes no folder.
    func testTheDryRunWritesNothing() async throws {
        let set = try await setWithAdoptedVariant(), files = try writeImageFiles()
        let out = root.appendingPathComponent("dry")
        try await RNASeqSoloPlanSubcommand.parse(try arguments(set: set, out: out, files: files) + ["--dry-run"]).run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    /// The plan of the introns preset says at plan time that `import rnaseq --adopt` reads `Solo.out/Gene` only and will
    /// refuse the folder the plan returns, since the run takes hours. The plan of an exon preset says nothing of it (review
    /// SOLO-PLAN-M2-M3-BIO SF1).
    func testTheIntronsPresetSaysAtPlanTimeThatTheAdoptReadsSoloOutGeneOnly() async throws {
        let set = try await setWithAdoptedVariant(), files = try writeImageFiles()
        let out = root.appendingPathComponent("introns")
        func lines(_ preset: String) async throws -> [String] {
            try await RNASeqSoloPlanSubcommand.parse(try arguments(set: set, out: out, files: files, preset: preset) + ["--dry-run"]).writePlan().lines
        }
        let introns = try await lines("tenx-3p-v3-introns")
        XCTAssertTrue(
            introns.contains { $0.contains("import rnaseq --adopt") && $0.contains("Solo.out/Gene") && $0.contains("<result folder>/solo") },
            "\(introns)")
        let exons = try await lines("tenx-3p-v3")
        XCTAssertFalse(exons.contains { $0.contains("import rnaseq --adopt") }, "\(exons)")
    }

    // MARK: - Refusals in words

    /// An index of another list, a 5' v2 plan with no list in the image or given, and a cut list are each refused in words
    /// that say what to do, and nothing is written.
    func testEachRefusalSaysWhatToDoAndWritesNothing() async throws {
        let set = try await setWithAdoptedVariant(), files = try writeImageFiles()
        let out = root.appendingPathComponent("refused")
        let other = try await refusal(try arguments(set: set, out: out, files: files, list: "gencode-2020-A"), out: out)
        XCTAssertTrue(other.contains("rnaseq index-plan --set \(set.id) --star 2.7.11b --tenx-filter gencode-2020-A"), other)
        XCTAssertTrue(other.contains("rnaseq index-adopt"), other)
        let bulk = try await refusal(try arguments(set: set, out: out, files: files, list: nil), out: out)
        XCTAssertTrue(bulk.contains("no 10x filter rule") && bulk.contains("--tenx-filter mkgtf-3.0.0"), bulk)
        let fivePrime = try await refusal(try arguments(set: set, out: out, files: files, preset: "tenx-5p-v2"), out: out)
        XCTAssertTrue(fivePrime.contains("737K-august-2016") && fivePrime.contains("--barcode-list"), fivePrime)
        let cut = root.appendingPathComponent("cut-3M.txt")
        try Data("AAACCCAAGAAACACT\nAAACCCAAGAAACCAT\n".utf8).write(to: cut)
        let cutWords = try await refusal(try arguments(set: set, out: out, files: files) + ["--barcode-list", cut.path], out: out)
        XCTAssertTrue(cutWords.contains("neither known list") && cutWords.contains("cut-3M.txt"), cutWords)
        let threads = try await refusal(try arguments(set: set, out: out, files: files) + ["--threads", "4"], out: out)
        XCTAssertTrue(threads.contains("--request-cpus"), threads)
    }
}
