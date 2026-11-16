// RNASeqQuantPlanCommandChainTests.swift - `lungfish-cli rnaseq quant --write-plan --chain`, the STAR chains on an index an
// earlier Linux run staged (Phase 5.3 lane EX-PLAN-STAR milestone 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The plan's own bytes are `STARPlanTests`. These cases read what the option picks, that a chain pins the adopted index of
// its STAR version, and that each refusal names the way out and writes nothing.

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishPortable
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqQuantPlanCommandChainTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-quant-chain-cli").resolvingSymlinksInPath() }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static let staging = "/staging/groups/g/1/lge"
    static let figures = ["--request-memory-mib", "4096", "--request-cpus", "2", "--request-disk-gib", "20"]

    /// The executor's `manifest.json`, an image whose tool manifest holds both STARs, pigz, salmon, Trim Galore and
    /// featureCounts, and the `image.json` that pins it.
    func writeImageFiles() throws -> (executor: URL, image: URL, tools: URL) {
        let files = try RNASeqQuantPlanCommandTests.writeImageFiles(in: root)
        let tools = [("STAR", "2.7.11b", "h5814d7d_9"), ("STAR", "2.7.3a", "h5ca1c30_1"), ("pigz", "2.8", "h421ea60_1"),
                     ("salmon", "2.11.0", "hfa8f182_0"), ("trim_galore", "2.3.0", "hf1b6044_0"), ("featureCounts", "2.1.1", "h577a1d6_0")]
        let manifest = try ImageToolManifest(platform: .linux64, tools: tools.map {
            ImageTool(id: $0.0, version: $0.1, build: $0.2, path: "/opt/conda/envs/\($0.0)-\($0.1)/bin/\($0.0)", condaPackage: $0.0.lowercased())
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

    /// The small set and a stand-in record of a STAR `version` index that `rnaseq index-adopt` wrote, whose three files the
    /// index batch `m-index` left in the staging folder.
    func setWithAdoptedIndex(star version: String = "2.7.11b") async throws -> (storage: URL, id: String) {
        let (storage, setFolder) = try await RNASeqIndexPlanCommandTests.builtSet(in: root)
        let manifest = try ReferenceSetManifest.load(from: setFolder)
        let star = PlanToolPin(id: "STAR", version: version, build: version == "2.7.3a" ? "h5ca1c30_1" : "h5814d7d_9")
        let key = STARIndexKey.folderName(star: version, nbases: 4, sparseD: 2)
        let files = ["Genome", "SA", "chrName.txt"].map { name -> STARIndexRecord.File in
            let data = Data("\(name) of \(key)\n".utf8)
            return STARIndexRecord.File(path: name, planPath: "star-index/\(name)",
                                        stagingPath: "\(Self.staging)/batches/m-index/index/staged/star-index/\(name)",
                                        bytes: UInt64(data.count), sha256: PortableDigest.sha256Hex(of: data))
        }
        let record = STARIndexRecord(setID: manifest.id, key: STARIndexKey(
            folderName: key, setID: manifest.id, referenceSetSHA256: String(repeating: "d", count: 64), star: star,
            genomeSAindexNbases: 4, genomeSAsparseD: 2, sjdbOverhang: 100, genomeFastaFiles: [manifest.genome.path],
            countingGTFSHA256: manifest.derived.countingGTF?.sha256 ?? ""), tool: star, files: files)
        _ = try STARIndexRecordStore(storageRoot: storage).write(record)
        return (storage, manifest.id)
    }

    func pairBundle() throws -> URL {
        let bundle = root.appendingPathComponent("imports/sample1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for mate in [1, 2] {
            let text = (1...4).map { "@r\($0) \(mate):N:0:1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n" }.joined()
            try Data(text.utf8).write(to: bundle.appendingPathComponent("sample1_R\(mate).fastq"))
        }
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .pairedEnd, pairingSource: .detected, recipeApplied: nil)),
            for: bundle.appendingPathComponent("sample1_R1.fastq"))
        return bundle
    }

    func arguments(_ chain: String, set: (storage: URL, id: String), out: URL, files: (executor: URL, image: URL, tools: URL)) throws -> [String] {
        [try pairBundle().path, "--set", set.id, "--storage-root", set.storage.path, "--write-plan", out.path,
         "--staging-folder", Self.staging, "--executor-manifest", files.executor.path, "--image", files.image.path,
         "--image-tool-manifest", files.tools.path, "--quiet", "--chain", chain] + Self.figures
    }

    // MARK: - The option (M3 item 2)

    /// `--chain` parses to the same value at the root and at the leaf, salmon is the default, and every value is one the
    /// help lists.
    func testTheChainParsesAtTheRootAndAtTheLeafAndSalmonIsTheDefault() async throws {
        let set = try await setWithAdoptedIndex(), files = try writeImageFiles()
        let given = try arguments("star-salmon-errormodel", set: set, out: root.appendingPathComponent("out/q"), files: files)
        let leaf = try RNASeqCommand.QuantSubcommand.parse(given)
        let atRoot = try XCTUnwrap(try LungfishCLI.parseAsRoot(["rnaseq", "quant"] + given) as? RNASeqCommand.QuantSubcommand)
        XCTAssertEqual(leaf.planOptions.chain, .starSalmonErrorModel)
        XCTAssertEqual(atRoot.planOptions.chain, leaf.planOptions.chain)
        XCTAssertEqual(RNASeqQuantPlanChain.allCases.map(\.rawValue), [
            "salmon", "star-salmon", "star-salmon-errormodel", "star-2.7.11b-genecounts", "star-2.7.3a-genecounts",
            "star-2.7.11b-featurecounts"])
        let plain = Array(given.dropLast(Self.figures.count + 2)) + Self.figures
        XCTAssertNil(try RNASeqCommand.QuantSubcommand.parse(plain).planOptions.chain)
    }

    /// The default route's chain writes one plan a sample: STAR on the adopted 2.7.11b index read where it was staged, then
    /// salmon with `--errorModel`, and a replay gives the same plan.
    func testTheDefaultRouteChainPinsTheAdoptedIndexWhereItWasStaged() async throws {
        let set = try await setWithAdoptedIndex(), files = try writeImageFiles()
        let out = root.appendingPathComponent("out/quant")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await RNASeqCommand.QuantSubcommand.parse(try arguments("star-salmon-errormodel", set: set, out: out, files: files)).run()
        let plan = try ExecutionPlan.decode(Data(contentsOf: out.appendingPathComponent("sample1/plan.json")))
        XCTAssertEqual(plan.steps.map { $0.tool?.id }, ["STAR", "salmon"])
        XCTAssertEqual(plan.steps.last?.arguments.last, "--errorModel")
        XCTAssertEqual(plan.pipeline?.route?.id, "star-salmon")
        XCTAssertEqual(plan.pipeline?.route?.settings["alignmentScoring"], "errorModel")
        let argv = try XCTUnwrap(plan.steps.first?.arguments)
        XCTAssertEqual(argv.firstIndex(of: "--runThreadN").map { argv[$0 + 1] }, "2", "STAR's threads equal --request-cpus")
        let staged = try String(contentsOf: out.appendingPathComponent("staging-files.json"), encoding: .utf8)
        XCTAssertTrue(staged.contains("\(Self.staging)/batches/m-index/index/staged/star-index/Genome"), staged)
    }

    // MARK: - Refusals

    /// A chain whose STAR version has no adopted index is refused in words that name `rnaseq index-plan` and
    /// `rnaseq index-adopt`, and `--chain` with no `--write-plan` or with a salmon index option is refused before a file is
    /// read.
    func testAChainWithNoAdoptedIndexOfItsVersionIsRefusedInWordsAndWritesNothing() async throws {
        let set = try await setWithAdoptedIndex(), files = try writeImageFiles()
        let out = root.appendingPathComponent("refused")
        let command = try RNASeqCommand.QuantSubcommand.parse(try arguments("star-2.7.3a-genecounts", set: set, out: out, files: files))
        var words = ""
        do {
            try await command.run()
            XCTFail("the plan was written")
        } catch let code as ExitCode {
            XCTAssertEqual(code, CLIExitCode.inputError.exitCode)
            do { _ = try await command.writePlanFolder() } catch { words = CLIFailureWords.describe(error) }
        }
        XCTAssertTrue(words.contains("rnaseq index-plan --set \(set.id) --star 2.7.3a") && words.contains("rnaseq index-adopt"), words)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), words)
        let cases: [(String, [String], String)] = [
            ("--chain with no --write-plan", [try pairBundle().path, "--set", set.id, "--project", root.path, "--chain", "star-salmon"],
             "--chain is an option of --write-plan"),
            ("--k with a STAR chain", try arguments("star-salmon", set: set, out: out, files: files) + ["--k", "25"],
             "--k and --decoys"),
        ]
        for (what, argv, expected) in cases {
            XCTAssertThrowsError(try RNASeqCommand.QuantSubcommand.parse(argv), what) { error in
                let message = RNASeqCommand.QuantSubcommand.message(for: error)
                XCTAssertTrue(message.contains(expected), "\(what): \(message)")
            }
        }
    }
}
