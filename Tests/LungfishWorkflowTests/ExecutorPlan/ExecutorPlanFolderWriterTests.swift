// ExecutorPlanFolderWriterTests.swift - The plan folder writer stages regular files and cleans up after a refusal (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// The request a plan test hands the emitter: no database, threads 1, a 4 GB heap, illumina4, an executor stand-in.
enum ExecutorPlanTestSupport {
    static let digest = String(repeating: "b", count: 64)
    static let mac24 = ExecutorPlanHostFacts(physicalMemoryBytes: 24 * 1_073_741_824, processorCount: 4)
    static let pins = [
        PlanToolPin(id: "fastp", version: "1.0.1", build: "h43da1c4_0"),
        PlanToolPin(id: "clumpify.sh", version: "39.13", build: "he5f24ec_0"),
        PlanToolPin(id: "reformat.sh", version: "39.13", build: "he5f24ec_0"),
        PlanToolPin(id: "seqkit", version: "2.10.0", build: "h9ee0642_0"),
        PlanToolPin(id: "gzip", version: "1.13", build: "h8359307_0"),
        PlanToolPin(id: "bgzip", version: "1.21", build: "h3ff9d97_0"),
        PlanToolPin(id: "java", version: "25.0.2", build: "h1602c4f_26"),
        PlanToolPin(id: "pigz", version: "2.8", build: "h421ea60_1"),
        PlanToolPin(id: "deacon", version: "0.13.2", build: "h4349ce8_0"),
        PlanToolPin(id: "trim_galore", version: "2.3.0", build: "h48b4a6d_0"),
    ]

    /// A small R1/R2 pair named for `sample` in its own folder under `root`.
    static func writePair(root: URL, _ sample: String) throws -> [URL] {
        let folder = root.appendingPathComponent(sample, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r1 = folder.appendingPathComponent("\(sample)_R1.fastq")
        let r2 = folder.appendingPathComponent("\(sample)_R2.fastq")
        try "@pair1/1\nACGTACGTAC\n+\nIIIIIIIIII\n@pair2/1\nTTGGCCAATT\n+\nIIIIIIIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@pair1/2\nGTACGTACGT\n+\nIIIIIIIIII\n@pair2/2\nAATTGGCCAA\n+\nIIIIIIIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        return [r1, r2]
    }

    /// A stand-in for a recipe's file, which a plan pins as its `recipe` entry.
    static func recipeSource(root: URL) throws -> ExecutorPlanSourceFile {
        let file = root.appendingPathComponent("recipe-source.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data("{\"recipe\":\"stand-in\"}\n".utf8).write(to: file)
        }
        return try ExecutorPlanSourceFile.measuring(file)
    }

    static func request(
        root: URL, _ sample: String, inputs: [URL], clumping: ClumpingTool, compressor: PlanCompressor = .bgzip,
        recipe: Recipe? = nil
    ) throws -> ExecutorPlanRequest {
        let executor = root.appendingPathComponent("lungfish-executor")
        if !FileManager.default.fileExists(atPath: executor.path) {
            try Data("executor stand-in".utf8).write(to: executor)
        }
        let files = try inputs.map { try ExecutorPlanSourceFile.measuring($0) }
        return ExecutorPlanRequest(
            sample: PlanSampleValues(sampleName: sample, originalFilenames: inputs.map(\.lastPathComponent),
                                     originalSizeBytes: files.reduce(0) { $0 + $1.size }),
            inputs: files, inputFormat: .pairedR1R2, recipe: recipe,
            recipeFile: try recipe.map { _ in try recipeSource(root: root) },
            storage: ExecutorPlanStorageRequest(
                requestedClumpingTool: clumping, clumpifyHeapGB: 4, threads: 1,
                compressor: compressor, qualityBinning: .illumina4, compressionLevel: 4, threadsSource: .option,
                clumpifyHeapSource: .option, compressorSource: .default, qualityBinningSource: .default
            ),
            executorFile: try ExecutorPlanSourceFile.measuring(executor),
            executorBuild: PlanExecutorBuild(
                lgeVersion: "2026.10.22", lgeCommit: "74ae0db3400d6b7519550e33dafc369e081fa114",
                targetTriple: "x86_64-swift-linux-musl", toolchainID: "swift-6.2", toolchainSHA256: digest,
                staticLinuxSDKID: "swift-6.2-static-linux", staticLinuxSDKSHA256: digest
            ),
            imageManifest: PlanImageManifestPin(sha256: digest, size: 4096), imageTools: pins,
            deadlines: ExecutorPlanDeadlines(recipeStepSeconds: 3600, storageSeconds: 7200, statisticsSeconds: 1800, graceSeconds: 30)
        )
    }
}

final class ExecutorPlanFolderWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "ExecutorPlanFolderWriter")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func emission(_ inputs: [URL], clumping: ClumpingTool = .bbtools) throws -> ExecutorPlanEmission {
        try ExecutorPlanEmitter.emission(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: inputs, clumping: clumping), host: ExecutorPlanTestSupport.mac24
        )
    }

    /// SWIFT fix 4 of the K4 part A review: an input given as a symbolic link is staged as the regular file it names,
    /// with equal bytes, and the node's resolver accepts every entry of the written folder.
    func testFolderWriterStagesRegularFilesAndCleansUp() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let link = root.appendingPathComponent("S_R1_link.fastq")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pair[0])
        let emitted = try emission([link, pair[1]])
        let file = try ExecutorPlanFolderWriter.write(emitted, into: root.appendingPathComponent("linked-plan", isDirectory: true))
        let staged = file.deletingLastPathComponent().appendingPathComponent("inputs/R1.fastq")
        let type = try FileManager.default.attributesOfItem(atPath: staged.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: pair[0]))
        let resolver = try PlanResourceResolver(planFile: file)
        for entry in emitted.plan.entries {
            XCTAssertNoThrow(try resolver.verify(entry), entry.relativePath)
        }
    }

    /// QA fix 9 (a) and SWIFT fix 4 of the K4 part A review: a Mac file changed after the plan was made refuses the write
    /// with the node's words for its entry, and the folder the writer made is gone.
    func testPlanFolderWriterRemovesItsFolderWhenASourceChanges() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let emitted = try emission(pair)
        var bytes = try Data(contentsOf: pair[1])
        bytes[1] = UInt8(ascii: "X")
        try bytes.write(to: pair[1])
        let folder = root.appendingPathComponent("changed-plan", isDirectory: true)
        XCTAssertThrowsError(try ExecutorPlanFolderWriter.write(emitted, into: folder)) { error in
            let refusal = error as? ExecutorPlanError
            XCTAssertEqual(refusal?.field, "entries[2]")
            XCTAssertTrue(refusal?.reason.hasPrefix("The plan's file inputs/R2.fastq has SHA-256 ") ?? false, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    /// QA fix 9 (b) and SWIFT fix 4 of the K4 part A review: a folder that exists is refused and keeps its contents.
    func testPlanFolderWriterRefusesAnExistingFolder() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let emitted = try emission(pair)
        let folder = root.appendingPathComponent("existing-plan", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: folder.appendingPathComponent("marker.txt"))
        XCTAssertThrowsError(try ExecutorPlanFolderWriter.write(emitted, into: folder)) { error in
            XCTAssertEqual((error as? ExecutorPlanError)?.field, "folder")
        }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("marker.txt"), encoding: .utf8), "marker")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["marker.txt"])
    }

    /// QA fix 9 (c) of the K4 part A review: a recipe step with no plan form refuses the plan by the `steps` field. A lone
    /// trim is not fused, so it plans as a single step with no plan form yet.
    func testPlanEmitterRefusesAStepWithNoPlanForm() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let lone = Recipe(formatVersion: 1, id: "lone-trim", name: "Lone Trim", platforms: [.illumina], requiredInput: .paired,
                          steps: [RecipeStep(type: "fastp-trim")])
        XCTAssertThrowsError(try ExecutorPlanEmitter.emission(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: pair, clumping: .bbtools, recipe: lone),
            host: ExecutorPlanTestSupport.mac24
        )) { error in
            let refusal = error as? ExecutorPlanError
            XCTAssertEqual(refusal?.field, "steps")
            XCTAssertTrue(refusal?.reason.hasSuffix("has no plan form yet, so this recipe cannot run from a plan.") ?? false, "\(error)")
        }
    }

    /// QA fix 9 (d) of the K4 part A review (tally-r2 K4-13, writer half): the Mac refuses pigz beside BBTools with the
    /// decoder's own sentence.
    func testPlanEmitterRefusesPigzForBBTools() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        XCTAssertThrowsError(try ExecutorPlanEmitter.emit(
            ExecutorPlanTestSupport.request(root: root, "S", inputs: pair, clumping: .bbtools, compressor: .pigz),
            host: ExecutorPlanTestSupport.mac24
        )) { error in
            let refusal = error as? PlanDecodeError
            XCTAssertEqual(refusal?.field, "storage.compressor")
            XCTAssertEqual(refusal?.reason, "This plan names pigz as the compressor for step storage, which runs clumpify.sh. BBTools compresses its output with bgzip, so the plan must name bgzip.")
        }
    }
}
