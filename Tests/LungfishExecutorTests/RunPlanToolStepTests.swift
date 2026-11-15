// RunPlanToolStepTests.swift - A schema 2 plan with a stand-in tool runs through the built executor (Phase 5.3 lane
// EX-TOOL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable
import XCTest
@testable import LungfishExecutor

/// The proof of milestone 2: a stand-in schema 2 plan with a stand-in counting tool in a stand-in manifest, a
/// `reference` entry, a barcode list and one output of each policy, run as `run --plan --image-manifest`.
final class RunPlanToolStepTests: XCTestCase {
    private static let setID = "stand-in-set-0001"
    private static let list = "AAACCCAAGAAACACT\nAAACCCAAGAAACCAT\n"

    private struct Folder {
        var fixture: RunPlanFixture
        var tool: PlanToolPin
        var listFile: ImageDataFile
    }

    /// A tool `quant` that reads the reference and the list by their work-root paths and writes three files.
    private func folder() throws -> Folder {
        var fixture = try RunPlanFixture()
        let tool = try fixture.addTool("quant", """
        cat "$1" "$2" "$3" > out/quant.sf
        printf index > out/index.bin
        cat "$1" > out/reads.bam
        echo "counted" >&2
        """)
        try FileManager.default.createDirectory(atPath: fixture.planFolder + "/references/\(Self.setID)/derived", withIntermediateDirectories: true)
        try RunPlanFixture.write(">t1\nACGT\n", to: fixture.planFolder + "/references/\(Self.setID)/derived/transcripts.fa")
        let listPath = fixture.toolsFolder + "/3M-february-2018.txt"
        try RunPlanFixture.write(Self.list, to: listPath)
        let file = ImageDataFile(path: listPath, role: "barcodeList", sha256: PortableDigest.sha256Hex(of: Data(Self.list.utf8)), size: Int64(Self.list.utf8.count))
        return Folder(fixture: fixture, tool: tool, listFile: file)
    }

    private func manifest(_ folder: Folder, files: [ImageDataFile]?) throws -> (path: String, pin: PlanImageManifestPin) {
        let data = try ImageToolManifest(platform: ImageToolPlatform.current ?? .linux64, tools: folder.fixture.tools, files: files).encoded()
        let path = folder.fixture.toolsFolder + "/image-manifest.json"
        try data.write(to: URL(fileURLWithPath: path))
        return (path, PlanImageManifestPin(sha256: PortableDigest.sha256Hex(of: data), size: Int64(data.count)))
    }

    private func entry(_ folder: Folder, _ role: PlanEntryRole, _ path: String) throws -> PlanEntry {
        let data = try Data(contentsOf: URL(fileURLWithPath: folder.fixture.planFolder + "/" + path))
        return PlanEntry(role: role, relativePath: path, sha256: PortableDigest.sha256Hex(of: data), size: Int64(data.count))
    }

    private func writePlan(_ folder: Folder, pin: PlanImageManifestPin, source: PlanBarcodeListSource) throws -> String {
        let referencePath = "references/\(Self.setID)/derived/transcripts.fa"
        var reference = try entry(folder, .reference, referencePath)
        reference.reference = PlanReferenceIdentity(setID: Self.setID, path: "derived/transcripts.fa")
        let list = PlanEntry(
            role: .barcodeList, relativePath: "barcodes/3M-february-2018.txt", sha256: folder.listFile.sha256,
            size: folder.listFile.size, barcodeList: PlanBarcodeListIdentity(name: "3M-february-2018", source: source)
        )
        let settings = ["duplicates": "Duplicates: kept. LGE removes duplicates only with UMIs.", "trimming": "Reads not trimmed"]
        let plan = ExecutionPlan(
            entries: [folder.fixture.executorEntry, try entry(folder, .input, "inputs/R1.fastq"), reference, list],
            executor: PlanExecutorBuild(
                lgeVersion: "test", lgeCommit: RunPlanFixture.zeros, targetTriple: "test", toolchainID: "test",
                toolchainSHA256: RunPlanFixture.zeros, staticLinuxSDKID: "test", staticLinuxSDKSHA256: RunPlanFixture.zeros
            ),
            imageManifest: pin, tools: [folder.tool], recipe: nil,
            pipeline: PlanPipeline(
                id: "stand-in", version: 1, preset: PlanPipelinePreset(id: "bulk", name: "Stand-in counts"), modality: .bulk,
                route: PlanPipelineRoute(id: "stand-in", tool: "quant", toolVersion: "1.0", settings: settings),
                referenceSet: PlanPipelineReferenceSet(id: Self.setID, layout: .lge),
                settings: settings.keys.sorted().map { PlanPipelineSetting(id: $0, label: $0, value: settings[$0] ?? "", source: .default) }
            ),
            sample: PlanSampleValues(sampleName: "sample", originalFilenames: ["R1.fastq"], originalSizeBytes: 15),
            storage: nil, clumping: nil, graceSeconds: 5,
            steps: [PlanStep(
                id: "quant", title: "Count", kind: .tool, tool: folder.tool,
                arguments: [referencePath, list.relativePath, "inputs/R1.fastq"], deadlineSeconds: ExecutionPlan.maximumDeadlineSeconds,
                inputs: ["inputs/R1.fastq"], outputs: ["out/quant.sf", "out/index.bin", "out/reads.bam"],
                outputPolicy: ["out/quant.sf": .home, "out/index.bin": .staged, "out/reads.bam": .stays]
            )]
        )
        let path = folder.fixture.planFolder + "/plan.json"
        try plan.encoded().write(to: URL(fileURLWithPath: path))
        return path
    }

    /// EX-SCHEMA-ARCH B1: the list is found in the manifest's `files`, copied to its plan path and checked, and the
    /// record's inputs repeat the entry with its source.
    func testImageBarcodeListIsFoundInManifestFiles() throws {
        let folder = try folder()
        let manifest = try manifest(folder, files: [folder.listFile])
        let plan = try writePlan(folder, pin: manifest.pin, source: .image)
        let run = try folder.fixture.run(plan, ["--image-manifest", manifest.path])
        let record = try XCTUnwrap(run.record, run.stderr)
        XCTAssertEqual(record.outcome, .succeeded, record.reason ?? run.stderr)
        XCTAssertEqual(record.schemaVersion, 1)
        XCTAssertEqual(folder.fixture.text("barcodes/3M-february-2018.txt"), Self.list)
        XCTAssertEqual(record.inputs.last?.barcodeList, PlanBarcodeListIdentity(name: "3M-february-2018", source: .image))
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(step.kind, .tool)
        XCTAssertNil(step.inputReadCount)
        XCTAssertNil(step.outputReadCount)
        XCTAssertEqual(step.outputs.map(\.path), ["out/quant.sf", "out/index.bin", "out/reads.bam"])
        XCTAssertEqual(step.outputs.map(\.policy), [.home, .staged, .stays])
        XCTAssertEqual(record.payloads.map(\.relativePath), ["out/quant.sf"])
        XCTAssertNil(record.payloads.first?.recordCount)
        XCTAssertEqual(folder.fixture.text("out/quant.sf"), ">t1\nACGT\n" + Self.list + "@r1\nACGT\n+\nIIII\n")
    }

    func testManifestWithoutTheListRefusesBeforeAnyTool() throws {
        let folder = try folder()
        let manifest = try manifest(folder, files: nil)
        let plan = try writePlan(folder, pin: manifest.pin, source: .image)
        let record = try XCTUnwrap(try folder.fixture.run(plan, ["--image-manifest", manifest.path]).record)
        XCTAssertEqual(record.outcome, .refused)
        XCTAssertEqual(record.refusedField, "entries[3]")
        XCTAssertEqual(record.reason, "The tool image holds no barcode list with SHA-256 \(folder.listFile.sha256), which this plan pins. No tool ran.")
        XCTAssertTrue(record.steps.isEmpty)
        XCTAssertFalse(folder.fixture.exists("barcodes/3M-february-2018.txt"))
    }

    /// BIO-NOTHOST-BARCODE Q2: LGE never copies a supplied list. The run refuses until the person puts it in place.
    func testSuppliedListIsCheckedWhereThePersonPutIt() throws {
        let folder = try folder()
        let manifest = try manifest(folder, files: [folder.listFile])
        let plan = try writePlan(folder, pin: manifest.pin, source: .supplied)
        let refused = try XCTUnwrap(try folder.fixture.run(plan, ["--image-manifest", manifest.path]).record)
        XCTAssertEqual(refused.refusedField, "entries[3]")
        XCTAssertTrue(refused.reason?.contains("LGE does not copy a barcode list you supplied. Put the list 3M-february-2018 with SHA-256 \(folder.listFile.sha256) at barcodes/3M-february-2018.txt before the run. No tool ran.") == true, refused.reason ?? "")
        XCTAssertFalse(folder.fixture.exists("barcodes/3M-february-2018.txt"))
        try FileManager.default.createDirectory(atPath: folder.fixture.planFolder + "/barcodes", withIntermediateDirectories: true)
        try RunPlanFixture.write(Self.list, to: folder.fixture.planFolder + "/barcodes/3M-february-2018.txt")
        let ran = try XCTUnwrap(try folder.fixture.run(plan, ["--image-manifest", manifest.path]).record)
        XCTAssertEqual(ran.outcome, .succeeded, ran.reason ?? "")
        XCTAssertEqual(ran.inputs.last?.barcodeList?.source, .supplied)
    }

    /// The same refusal and the same words for a list that is in place with other bytes (review EX-TOOL SWIFT, fix SF2).
    /// The other bytes have the list's size, so the size check passes and the SHA-256 check refuses.
    func testSuppliedListWithOtherBytesIsRefusedWithTheSameWords() throws {
        let folder = try folder()
        let manifest = try manifest(folder, files: [folder.listFile])
        let plan = try writePlan(folder, pin: manifest.pin, source: .supplied)
        try FileManager.default.createDirectory(atPath: folder.fixture.planFolder + "/barcodes", withIntermediateDirectories: true)
        try RunPlanFixture.write("AAACCCAAGAAACACX\nAAACCCAAGAAACCAT\n", to: folder.fixture.planFolder + "/barcodes/3M-february-2018.txt")
        let record = try XCTUnwrap(try folder.fixture.run(plan, ["--image-manifest", manifest.path]).record)
        XCTAssertEqual(record.outcome, .refused)
        XCTAssertEqual(record.refusedField, "entries[3]")
        XCTAssertTrue(record.reason?.hasPrefix("The plan's file barcodes/3M-february-2018.txt has SHA-256 ") == true, record.reason ?? "")
        XCTAssertTrue(record.reason?.contains("LGE does not copy a barcode list you supplied. Put the list 3M-february-2018 with SHA-256 \(folder.listFile.sha256) at barcodes/3M-february-2018.txt before the run. No tool ran.") == true, record.reason ?? "")
        XCTAssertTrue(record.steps.isEmpty)
    }
}
