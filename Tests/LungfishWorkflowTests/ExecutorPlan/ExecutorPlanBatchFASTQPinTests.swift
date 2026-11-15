// ExecutorPlanBatchFASTQPinTests.swift - Every file of a FASTQ submit folder, byte for byte (Phase 5.3 lane EX-SUBMIT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// The pin of lane EX-SUBMIT (ruling ARCH-SCHEMA-SPIKE item 3). Every file of a FASTQ submit folder, `run.dag`,
/// `sample.sub`, `lge-job.sh`, `jobs.tsv`, `run-local.sh`, `staging-files.json`, `README.txt` and each sample's plan
/// folder, keeps the SHA-256 it had at fb435868, before the batch writer took schema 2 plans. The test folder's own path,
/// which `staging-files.json` names as each Mac file's source, reads `<root>` before the hash.
final class ExecutorPlanBatchFASTQPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanBatchFASTQPin")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private let image = ExecutorPlanImageRecord(
        sif: ExecutorPlanImageFile(fileName: "lge-tools-eae819829358.sif", sha256: String(repeating: "e", count: 64), size: 396_402_688),
        imageManifest: PlanImageManifestPin(sha256: ExecutorPlanTestSupport.digest, size: 4096)
    )
    private static let staging = "/staging/groups/g/1/lge-chtc-test"
    private let layout = ExecutorPlanStagingLayout(folder: staging, batch: "batch")

    /// The SHA-256 of each regular file below `folder`, by its path in the folder, with the test folder's path as
    /// `<root>` in every file that names it.
    private func digests(of folder: URL) throws -> [String: String] {
        let base = folder.resolvingSymlinksInPath().path + "/"
        let roots = [root.resolvingSymlinksInPath().path, root.path]
        var result: [String: String] = [:]
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in walk where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            var data = try Data(contentsOf: file)
            if var text = String(data: data, encoding: .utf8), roots.contains(where: { text.contains($0) }) {
                for path in roots { text = text.replacingOccurrences(of: path, with: "<root>") }
                data = Data(text.utf8)
            }
            result[file.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")] = PortableDigest.sha256Hex(of: data)
        }
        return result
    }

    private func assertPinned(_ folder: URL, _ expected: [String: String], file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try digests(of: folder)
        let literal = actual.keys.sorted().map { "\"\($0)\": \"\(actual[$0] ?? "")\"," }.joined(separator: "\n")
        XCTAssertEqual(actual, expected, "the files now hash as:\n\(literal)", file: file, line: line)
    }

    private func row(_ sample: String, disk: Int? = nil) throws -> ExecutorPlanSampleRow {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, sample)
        return ExecutorPlanSampleRow(sampleName: sample, inputs: try pair.map { try ExecutorPlanSourceFile.measuring($0) },
                                     requestDiskGiB: disk)
    }

    /// Two samples of the bbtools template, one with the sheet's disk and one with the rule's.
    func testPlainBatchKeepsEveryFileByteForByte() throws {
        let request = try ExecutorPlanTestSupport.request(
            root: root, "S1", inputs: ExecutorPlanTestSupport.writePair(root: root, "S1"), clumping: .bbtools
        ).templateRequest
        let template = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try ExecutorPlanBatchWriter.write(template, request: request, rows: [try row("S1", disk: 40), try row("S2")],
                                          image: image, layout: layout, into: folder)
        try assertPinned(folder, Self.plain)
    }

    /// The VSP2 recipe with duplicates kept, a deacon database, its reports, the preset's work root factor and a
    /// `--job-requirements` value.
    func testDatabaseReportsAndRequirementsBatchKeepsEveryFileByteForByte() async throws {
        let index = root.appendingPathComponent("databases/test-panhuman/panhuman-1.k31w15.idx")
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("deacon index test-panhuman".utf8).write(to: index)
        let database = ExecutorPlanDatabaseFile(
            record: try await RecipeDatabaseIdentity().record(databaseID: "test-panhuman", at: index)
        )
        var kept = try XCTUnwrap(RecipeResolver.resolve(
            "vsp2-target-enrichment", in: RecipeRegistryV2.builtinRecipes(), switchOptions: ["removeDuplicates": false]
        ))
        for step in kept.steps.indices where kept.steps[step].type == "deacon-scrub" {
            kept.steps[step].params?["database"] = .string("test-panhuman")
        }
        var request = try ExecutorPlanTestSupport.request(
            root: root, "S1", inputs: ExecutorPlanTestSupport.writePair(root: root, "S1"), clumping: .bbtools, recipe: kept
        ).templateRequest
        request.databases = ["test-panhuman": database]
        let template = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        XCTAssertTrue(template.template.entries.contains { $0.role == .database })
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try ExecutorPlanBatchWriter.write(template, request: request, rows: [try row("S1"), try row("S2", disk: 12)],
                                          image: image, layout: layout,
                                          requirements: #"(TARGET.HasCHTCStaging == true) && (TARGET.Arch == "X86_64")"#,
                                          into: folder)
        try assertPinned(folder, Self.database)
    }

    /// Reads already in the staging folder (C6 ruling STAGED).
    func testStagedReadsBatchKeepsEveryFileByteForByte() throws {
        let request = try ExecutorPlanTestSupport.request(
            root: root, "S1", inputs: ExecutorPlanTestSupport.writePair(root: root, "S1"), clumping: .bbtools
        ).templateRequest
        let template = try ExecutorPlanEmitter.template(request, host: ExecutorPlanTestSupport.mac24)
        let paths = ["\(Self.staging)/input/S1_R1.fastq", "\(Self.staging)/input/S1_R2.fastq"]
        let row = ExecutorPlanSampleRow(
            sampleName: "S1",
            inputs: paths.map { ExecutorPlanSourceFile(url: URL(fileURLWithPath: $0), sha256: ExecutorPlanTestSupport.digest, size: 1_000) },
            stagedPaths: paths
        )
        let folder = root.appendingPathComponent("batch", isDirectory: true)
        try ExecutorPlanBatchWriter.write(template, request: request, rows: [row], image: image, layout: layout, into: folder)
        try assertPinned(folder, Self.staged)
    }

    // The SHA-256 of each file at fb435868034607467d7a7835af0319758691cfc6, from this test's own report of them.
    private static let plain: [String: String] = [
        "README.txt": "3259dc1d16f0e40eb2bbe327dd218477cd6d0576f0baf072ba2a2bde3c281fbf",
        "S1/plan.json": "2f402919567864d3e3b57f0a7789497ba6db5ad40278a1e54f9f0bc6cedbabc0",
        "S1/plan.tar": "e2871b860f0552a875ee068683334cdcce36ae35901f1a6c4a84b4815d67fe7d",
        "S1/staging.json": "98115a002dd73982b0bae6c000605657be24a7fc58ef4a83fb1726c452160a7f",
        "S2/plan.json": "5907564504a470a6dfb1489320c17eb1a560bc1ce73f4fc2539cfbf1d1ff5635",
        "S2/plan.tar": "c316ec0bf0d8725f1cd78dabe07a905bf78b77a7f089d9e6d30c8d253f52fc0c",
        "S2/staging.json": "98115a002dd73982b0bae6c000605657be24a7fc58ef4a83fb1726c452160a7f",
        "jobs.tsv": "ea2a010d5fd33f1af4bd875d59d2baa035bc00c511f1f5244d5f6058bf5b7b4f",
        "lge-job.sh": "7f3773bc974b135e0dc60f43eb1d4c0ec04ea6cc0a9fed47b45f9b1399064d1c",
        "run-local.sh": "f25f0ea06e193bec4e90d44323960188ebd0bd8ab86067728633c9e96268f188",
        "run.dag": "ec34faf91a75ed53e70561b7f29f5bf99a53cec36ca7b0c90dd85d4daad9a248",
        "sample.sub": "b607c8dd97bd3f7a21acdff24bca004a86bb9c8e87dc42cae2b028f6f6c01910",
        "staging-files.json": "aaf8f39ad8a3e3c118b0dfdfc0bd36bd4aac1f8ee2d62e8a4920f8b8c0044987",
    ]
    private static let database: [String: String] = [
        "README.txt": "3259dc1d16f0e40eb2bbe327dd218477cd6d0576f0baf072ba2a2bde3c281fbf",
        "S1/plan.json": "27e23353e03ded992ef3c7ed7230c42e612e0c1d738c01b76c4c98d7903e1b57",
        "S1/plan.tar": "b5841739f0d0ec0b667280a63d4f6b1a7c6054aa58aad0d1b746f28a71c91f6a",
        "S1/recipe/illumina-paired-cleanup.recipe.json": "a6b777604652c79a7a815ad34106b44e5cbefc106808c104ad7c74d558fc6a8c",
        "S1/staging.json": "b3f3867c03b744192cbcdf2d0069cd5aa728c8bbe27a8a779593c3f74d9e999f",
        "S2/plan.json": "22f167fb3c601e45f3d717a86be804fe4bc7a430165b7d078e7d7c601192fec5",
        "S2/plan.tar": "531cbf9b69f27bf0e54d8583b4a17b7d09087dfea719c95bbfb5c04d268d0483",
        "S2/recipe/illumina-paired-cleanup.recipe.json": "a6b777604652c79a7a815ad34106b44e5cbefc106808c104ad7c74d558fc6a8c",
        "S2/staging.json": "b3f3867c03b744192cbcdf2d0069cd5aa728c8bbe27a8a779593c3f74d9e999f",
        "jobs.tsv": "a895ea201de749904c0b5bd2f1ae330aea5983d5bb37bbbcc8d8fe0bc8b62fec",
        "lge-job.sh": "7f3773bc974b135e0dc60f43eb1d4c0ec04ea6cc0a9fed47b45f9b1399064d1c",
        "run-local.sh": "7b1b2cc45690db7c52853cf16eda97391b579f746242aca4a68d0dd4e223e959",
        "run.dag": "c5045f5c06e761c50157df2e86009dc67cb4e1bc9daa55533c3af528801cd552",
        "sample.sub": "60fa84fc64c946c63ebed410c895bc76c4f8d24a4296584477dc389864406fbc",
        "staging-files.json": "1277a49c1a8357c37fef2deb453a173a9092090a365e8526f2c42924b98244e4",
    ]
    private static let staged: [String: String] = [
        "README.txt": "75c8bdd0e5b5f29642e62f8c3bdf5c0e9e53c850688891873fc15f6d87b73429",
        "S1/plan.json": "c35435548681225d1dea64b38e522590bfd8efa121caa92ff3afae737ab1495a",
        "S1/plan.tar": "fdcb69a2199d1c346df0ef9dfd64d5686fb2cea41733959f4684a1ba34ebe394",
        "S1/staging.json": "885b3c6eac5eb422991ba63b7e0480bb40c41423ddcd2e396ac97735e04ef125",
        "jobs.tsv": "9ab7eb6ad2951a7701571e4f8761414d1591444d30b95081854dfc2d99c02838",
        "lge-job.sh": "7f3773bc974b135e0dc60f43eb1d4c0ec04ea6cc0a9fed47b45f9b1399064d1c",
        "run-local.sh": "f25f0ea06e193bec4e90d44323960188ebd0bd8ab86067728633c9e96268f188",
        "run.dag": "9ca159d1726a8b609ab72bb29c6737ff84f1a83a3116ea184d96c3844108fd29",
        "sample.sub": "b607c8dd97bd3f7a21acdff24bca004a86bb9c8e87dc42cae2b028f6f6c01910",
        "staging-files.json": "e87cb07a08364ca86ff7e26228d6c86ca1055573cd8e1580d1c730e8cd80b4c9",
    ]
}
