// ExecutorPlanFolderWriterTests.swift - The plan folder writer stages regular files and cleans up after a refusal (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

// `ExecutorPlanTestSupport`, the request a plan test hands the emitter, is in LungfishTestSupport, so the CLI's process
// tests of `import fastq --adopt` build the same plan.
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
    /// Lane EX-TOOL and BIO-NOTHOST-BARCODE Q2: a schema 2 folder stages its reference in shared mode, and neither mode
    /// holds a barcode list. The image's list is in no `staging.json`, and the person places a list they supplied, which
    /// `staging.json` names and the writer's words locate. A FASTQ plan keeps schema version 1.
    func testSchemaTwoFolderStagesReferencesAndHoldsNoBarcodeListBytes() throws {
        let fastq = try emission(try ExecutorPlanTestSupport.writePair(root: root, "F"))
        XCTAssertTrue(String(decoding: try fastq.plan.encoded(), as: UTF8.self).contains("\"schemaVersion\" : 1"))
        func file(_ name: String, _ text: String) throws -> (URL, String, Int64) {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return (url, PortableDigest.sha256Hex(of: Data(text.utf8)), Int64(text.utf8.count))
        }
        let (executor, executorSHA, executorSize) = try file("executor", "binary")
        let (reads, readsSHA, readsSize) = try file("reads.fastq", "@r\nA\n+\nI\n")
        let (fasta, fastaSHA, fastaSize) = try file("transcripts.fa", ">t\nA\n")
        let listText = "AAACCCAAGAAACACT\n"
        let listSHA = PortableDigest.sha256Hex(of: Data(listText.utf8))
        let set = "stand-in-set-0001"
        let tool = PlanToolPin(id: "quant", version: "1.0", build: "t0")
        let settings = ["duplicates": "Duplicates: kept. LGE removes duplicates only with UMIs.", "trimming": "Reads not trimmed"]
        let plan = ExecutionPlan(
            entries: [
                PlanEntry(role: .executor, relativePath: "bin/lungfish-executor", sha256: executorSHA, size: executorSize),
                PlanEntry(role: .input, relativePath: "inputs/R1.fastq", sha256: readsSHA, size: readsSize),
                PlanEntry(role: .reference, relativePath: "references/\(set)/derived/transcripts.fa", sha256: fastaSHA, size: fastaSize,
                          reference: PlanReferenceIdentity(setID: set, path: "derived/transcripts.fa")),
                PlanEntry(role: .barcodeList, relativePath: "barcodes/image.txt", sha256: listSHA, size: 17,
                          barcodeList: PlanBarcodeListIdentity(name: "3M-february-2018", source: .image)),
                PlanEntry(role: .barcodeList, relativePath: "barcodes/mine.txt", sha256: listSHA, size: 17,
                          barcodeList: PlanBarcodeListIdentity(name: "3M-february-2018", source: .supplied)),
            ],
            executor: fastq.plan.executor, imageManifest: fastq.plan.imageManifest, tools: [tool], recipe: nil,
            pipeline: PlanPipeline(
                id: "stand-in", version: 1, preset: PlanPipelinePreset(id: "bulk", name: "Stand-in"), modality: .bulk,
                route: PlanPipelineRoute(id: "stand-in", tool: "quant", toolVersion: "1.0", settings: settings),
                referenceSet: PlanPipelineReferenceSet(id: set, layout: .lge),
                settings: settings.keys.sorted().map { PlanPipelineSetting(id: $0, label: $0, value: settings[$0] ?? "", source: .default) }
            ),
            sample: PlanSampleValues(sampleName: "S", originalFilenames: ["reads.fastq"], originalSizeBytes: readsSize),
            storage: nil, clumping: nil, graceSeconds: 5,
            steps: [PlanStep(id: "quant", title: "Count", kind: .tool, tool: tool, arguments: [], deadlineSeconds: 60,
                             inputs: ["inputs/R1.fastq"], outputs: ["out/quant.sf"], outputPolicy: ["out/quant.sf": .home])]
        )
        let sources = ["bin/lungfish-executor": executor, "inputs/R1.fastq": reads, "references/\(set)/derived/transcripts.fa": fasta]
        let emitted = ExecutorPlanEmission(plan: plan, sources: sources)
        let image = ExecutorPlanImageFile(fileName: "lge.sif", sha256: String(repeating: "f", count: 64), size: 9)
        let shared = try ExecutorPlanFolderWriter.writeShared(emitted, image: image, into: root.appendingPathComponent("shared")).deletingLastPathComponent()
        let replay = try ExecutorPlanFolderWriter.write(emitted, into: root.appendingPathComponent("replay")).deletingLastPathComponent()
        let staging = try JSONDecoder().decode(
            ExecutorPlanStaging.self, from: Data(contentsOf: shared.appendingPathComponent(ExecutorPlanStaging.fileName))
        )
        XCTAssertEqual(staging.sharedFiles.map(\.relativePath), ["bin/lungfish-executor", "references/\(set)/derived/transcripts.fa", "barcodes/mine.txt"])
        XCTAssertEqual(staging.schemaVersion, 1)
        for folder in [shared, replay] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("barcodes").path), folder.path)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("plan.json")), try plan.encoded())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("references").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replay.appendingPathComponent("references/\(set)/derived/transcripts.fa").path))
        XCTAssertEqual(ExecutorPlanFolderWriter.placements(of: plan, shared: false), [
            "This plan pins the barcode list 3M-february-2018 you supplied, SHA-256 \(listSHA), 17 bytes. LGE does not copy a list you supplied, so put the file at barcodes/mine.txt in the plan folder before the run.",
        ])
        XCTAssertTrue(ExecutorPlanFolderWriter.placements(of: plan, shared: true)[0].contains("in the group's staging folder as shared/\(listSHA)-mine.txt"))
    }

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

    /// QA fix 9 (c) of the K4 part A review: a recipe step with no plan form refuses the plan by the `steps` field.
    /// RiboDetector has none (a lone trim has one since C5 lane BF, D18).
    func testPlanEmitterRefusesAStepWithNoPlanForm() throws {
        let pair = try ExecutorPlanTestSupport.writePair(root: root, "S")
        let lone = Recipe(formatVersion: 1, id: "lone-ribodetector", name: "Lone RiboDetector", platforms: [.illumina],
                          requiredInput: .paired, steps: [RecipeStep(type: "ribodetector-filter")])
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
